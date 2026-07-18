# zent Benchmark & Hot-Path Optimization Design

## Goal

Add a lightweight, maintainable benchmark suite to zent so that future
performance work is data-driven. The first milestone measures the three
hottest CPU paths in normal ORM usage and applies obvious, low-risk
optimizations surfaced by the numbers.

## Scope

- **In scope**
  - A single `bench/main.zig` runner registered in `build.zig` as
    `zig build benchmark`.
  - Micro-benchmarks for:
    1. SQL builder: simple SELECT and complex WHERE/ORDER/GROUP/LIMIT query.
    2. Row scanner: scanning a single entity and a batch of entities.
    3. Connection pool: borrow/release round-trip with health check.
  - Measurement using `std.Io.Clock.now(io, .awake)` timestamps,
    fixed-duration runs, and ops/second reporting.
  - Targeted optimizations of the most obvious hotspots revealed by the
    benchmarks (e.g., excess allocations in `Builder.arg`, per-row
    allocator use in `scanRow`, mutex/health-check overhead in the pool).

- **Out of scope (for this milestone)**
  - End-to-end load testing against a real database server.
  - Prepared-statement caching (may be proposed later if benchmarks show
    it is the dominant cost).
  - Large refactorings of the codegen or query APIs.

## Architecture

```
bench/
├── main.zig          # runner, result formatting, CLI
├── builder.zig       # SQL builder benchmarks
├── scan.zig          # row scanning benchmarks
└── pool.zig          # connection pool benchmarks
```

`bench/main.zig` exposes a small registry:

```zig
const Benchmark = struct {
    name: []const u8,
    run: *const fn (allocator: Allocator, io: std.Io) anyerror!Result,
};
```

The runner iterates over the registry, runs each benchmark for a fixed
duration (default 1 second), and prints a Markdown-friendly table:

```
Benchmark                          Iterations    ns/op
---------------------------------------------------------
builder/simple_select              1_234_567     810
builder/complex_where              654_321       1_529
scan/single_entity                 987_654       1_012
scan/batch_100                     12_345        81_000
pool/borrow_release                456_789       2_190
```

## Benchmark Cases

### builder/simple_select

Construct a `SELECT "users"."id", "users"."name" FROM "users"` query
using the low-level `Builder` API.

### builder/complex_where

Construct a query with multiple predicates, `ORDER BY`, `GROUP BY`,
`HAVING`, `LIMIT`, and `OFFSET` to stress string concatenation and
argument binding.

### scan/single_entity

Use `scanRow` to populate a struct with int/string/time fields from a
mock `driver.Row` (a fake implementation that returns constant values).

### scan/batch_100

Call `scanRow` 100 times in a loop to simulate fetching a page of
results. This highlights per-row allocation cost for string fields.

### pool/borrow_release

Warm up a `ConnPool(SQLiteDriver)` with `min_connections = max_connections
= 4`, then repeatedly `borrow()` and `release()` a connection with health
 checking enabled.

## Optimization Candidates (measure first)

The following are suspected hotspots; the actual implementation will only
change those that the benchmarks confirm are expensive:

1. **`Builder.arg`**: Currently allocates/format-prints every argument.
   For common scalar types (`i64`, `f64`, `bool`), formatting can be
   done into a small stack buffer or pre-allocated formatter.
2. **`scanRow` string fields**: Every `[]const u8` field calls
   `allocator.dupe`. For read-only query results this may be unavoidable,
   but we can avoid the allocator parameter entirely for primitive-only
   scans by providing a `scanRowNoAlloc` variant.
3. **Pool health check on borrow**: `ping()` runs `SELECT 1` every time a
   connection is handed out. A configurable `health_check_interval` could
   skip pings for recently-checked connections.
4. **Builder buffer growth**: `init` falls back to a zero-capacity list
   if allocation fails. We can make `initCapacity` infallible for small
   default capacities or expose a recommended capacity per dialect.

## Success Criteria

- `zig build benchmark` compiles and runs in both Debug and ReleaseFast.
- Each benchmark prints stable results across two consecutive runs
  (within 10% on an idle machine).
- At least one measurable optimization lands with a before/after number
  in the commit message or PR description.
- Existing tests continue to pass:
  - `zig build test`
  - `zig build test-integration`
  - `zig fmt --check`

## Error Handling

- Benchmark failures are reported as non-fatal: the runner prints the
  error, skips the case, and continues with the next one. The final exit
  code is non-zero only if a benchmark panics or the runner itself fails.
- Allocator failures during a benchmark are propagated and logged.

## Results

Measured on an Apple Silicon Mac, Zig 0.17.0-dev.813+2153f8143.

### ReleaseFast baseline (after optimization)

```
Benchmark                          Iterations    ns/op
---------------------------------------------------------
builder/simple_select              17_952_938    55
builder/complex_where               9_419_133    106
scan/single_entity                    211_636    4725
scan/batch_100                          1_801    555338
scan/batch_100_no_alloc              40_825_067   24
pool/borrow_release                   1_393_756   717
pool/borrow_release_no_health        22_865_309   43
```

The highest ns/op case was `scan/batch_100`, dominated by per-row
`allocator.dupe` for the `name` field. Adding `scanRowNoAlloc` for
primitive-only structs dropped the same workload to 24 ns/op, a
~23,000x improvement for rows that do not require allocations.

### Debug baseline (after optimization)

```
Benchmark                          Iterations    ns/op
---------------------------------------------------------
builder/simple_select               2_153_248    464
builder/complex_where                 893_017    1119
scan/single_entity                     15_619    64027
scan/batch_100                            146    6855991
scan/batch_100_no_alloc                 271755    3679
pool/borrow_release                   1_251_849   798
pool/borrow_release_no_health         6_655_819   150
```

## Future Work

- Add `zig build benchmark --release-fast` variant for CI tracking.
- Store results to a JSON/CSV file for trend analysis.
- Add prepared-statement caching benchmarks once a cache exists.

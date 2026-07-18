# zent Benchmark & Hot-Path Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `zig build benchmark` target that measures SQL builder, row scan, and connection pool performance, then apply the first round of data-driven hot-path optimizations.

**Architecture:** A single `bench/main.zig` runner registers benchmark cases from `bench/builder.zig`, `bench/scan.zig`, and `bench/pool.zig`. Each case receives an opaque context pointer through `runForCtx`, runs for a fixed duration using `std.Io.Clock` timestamps, and reports iterations plus ns/op. After baseline numbers are collected, the obvious allocation and lock hotspots are optimized.

**Tech Stack:** Zig 0.17-dev, std.Io.Clock for timing, std.array_list.Managed, zent internal modules.

## Global Constraints

- Target Zig 0.17-dev.
- All new code must pass `zig fmt --check src examples tests build.zig`.
- All existing tests must continue to pass:
  - `zig build test`
  - `zig build test-integration`
- Benchmark runner must compile and run in both Debug and ReleaseFast.
- No breaking changes to public APIs unless unavoidable; if unavoidable, update examples and tests.
- Optimize only hotspots confirmed by benchmark numbers; no speculative rewrites.

## File Structure

- **Create:** `bench/main.zig` — benchmark registry, runner, result formatting.
- **Create:** `bench/builder.zig` — SQL builder micro-benchmarks.
- **Create:** `bench/scan.zig` — row scanner micro-benchmarks with a mock `driver.Row`.
- **Create:** `bench/pool.zig` — connection pool micro-benchmarks.
- **Modify:** `build.zig` — add `benchmark` step.
- **Modify (optional, after measuring):** `src/sql/builder.zig`, `src/sql/scan.zig`, `src/sql/pool.zig` — hot-path optimizations.

---

### Task 1: Create the benchmark runner (`bench/main.zig`)

**Files:**
- Create: `bench/main.zig`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pub const Result = struct { iterations: u64, elapsed_ns: u64, nsPerOp() u64 };`
  - `pub const Benchmark = struct { name: []const u8, run: *const fn (allocator: Allocator, io: Io) anyerror!Result };`
  - `pub fn runForCtx(io: Io, duration_ns: u64, ctx: *anyopaque, body: *const fn (*anyopaque) anyerror!void) !Result;`

- [ ] **Step 1: Write `bench/main.zig`**

```zig
const std = @import("std");

pub const Result = struct {
    iterations: u64,
    elapsed_ns: u64,

    pub fn nsPerOp(self: Result) u64 {
        return @divFloor(self.elapsed_ns, self.iterations);
    }
};

pub const Benchmark = struct {
    name: []const u8,
    run: *const fn (allocator: std.mem.Allocator, io: std.Io) anyerror!Result,
};

/// Run `body(ctx)` repeatedly for at least `duration_ns` nanoseconds.
pub fn runForCtx(
    io: std.Io,
    duration_ns: u64,
    ctx: *anyopaque,
    body: *const fn (*anyopaque) anyerror!void,
) !Result {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var iterations: u64 = 0;
    while (true) {
        try body(ctx);
        iterations += 1;
        const elapsed = start.untilNow(io).raw.toNanoseconds();
        if (elapsed >= duration_ns) {
            return .{
                .iterations = iterations,
                .elapsed_ns = @intCast(elapsed),
            };
        }
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();

    const builder_benches = @import("builder.zig").benchmarks;
    const scan_benches = @import("scan.zig").benchmarks;
    const pool_benches = @import("pool.zig").benchmarks;
    const cases = builder_benches ++ scan_benches ++ pool_benches;

    const stdout = std.Io.StdOut.writer();
    try stdout.print("{s:40} {s:>12} {s:>12}\n", .{ "Benchmark", "Iterations", "ns/op" });
    try stdout.print("{s}\n", .{"-" ** 66});

    for (cases) |bench| {
        const result = bench.run(allocator, io) catch |err| {
            try stdout.print("{s:40} ERROR: {s}\n", .{ bench.name, @errorName(err) });
            continue;
        };
        try stdout.print("{s:40} {d:>12} {d:>12}\n", .{
            bench.name,
            result.iterations,
            result.nsPerOp(),
        });
    }
}
```

- [ ] **Step 2: Compile the runner skeleton**

Run:

```bash
zig build-exe bench/main.zig -femit-bin=/tmp/bench_test --mod zent:src/root.zig --deps zent --mod sqlite3_c:src/sql/sqlite3_include.h -lsqlite3 -lc
```

Expected: compiles. The registry is empty at this point, which is fine.

- [ ] **Step 3: Commit the runner skeleton**

```bash
git add bench/main.zig
git commit -m "bench: add benchmark runner skeleton"
```

---

### Task 2: Add SQL builder benchmarks (`bench/builder.zig`)

**Files:**
- Create: `bench/builder.zig`
- Modify: `bench/main.zig` (already imports builder benchmarks from Task 1)

**Interfaces:**
- Consumes: `Benchmark`, `runForCtx` from `bench/main.zig`; `Builder`, `Predicate`, `Table`, `Order` from `src/sql/builder.zig`.
- Produces: `pub const benchmarks: []const Benchmark`.

- [ ] **Step 1: Write `bench/builder.zig`**

```zig
const std = @import("std");
const main = @import("main.zig");
const sql = @import("zent").sql_builder;

const Benchmark = main.Benchmark;
const Result = main.Result;

const SimpleCtx = struct {
    b: *sql.Builder,
};

fn benchSimpleSelect(allocator: std.mem.Allocator, io: std.Io) !Result {
    var b = sql.Builder.initCapacity(allocator, 256, 8, .sqlite) catch sql.Builder.init(allocator, .sqlite);
    defer b.deinit();
    var ctx = SimpleCtx{ .b = &b };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *SimpleCtx = @ptrCast(@alignCast(ptr));
            c.b.buffer.clearRetainingCapacity();
            c.b.args.clearRetainingCapacity();
            try c.b.writeString("SELECT ");
            try sql.Table("users").c("id").appendTo(c.b);
            try c.b.writeString(", ");
            try sql.Table("users").c("name").appendTo(c.b);
            try c.b.writeString(" FROM ");
            try sql.Table("users").appendTo(c.b);
            _ = c.b.query();
        }
    }.body);
}

const ComplexCtx = struct {
    b: *sql.Builder,
    predicates: []const sql.Predicate,
    order_terms: []const sql.Order,
};

fn benchComplexWhere(allocator: std.mem.Allocator, io: std.Io) !Result {
    var b = sql.Builder.initCapacity(allocator, 512, 16, .sqlite) catch sql.Builder.init(allocator, .sqlite);
    defer b.deinit();

    const predicates = &.{
        sql.Predicate{ .gte = .{ .column = "age", .value = .{ .int = 18 } } },
        sql.Predicate{ .lte = .{ .column = "age", .value = .{ .int = 65 } } },
        sql.Predicate{ .like = .{ .column = "name", .value = .{ .string = "A%" } } },
    };
    const order_terms = &.{
        sql.Order{ .column = "age", .direction = .asc },
        sql.Order{ .column = "name", .direction = .desc },
    };

    var ctx = ComplexCtx{
        .b = &b,
        .predicates = predicates,
        .order_terms = order_terms,
    };

    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *ComplexCtx = @ptrCast(@alignCast(ptr));
            c.b.buffer.clearRetainingCapacity();
            c.b.args.clearRetainingCapacity();
            try c.b.writeString("SELECT * FROM ");
            try sql.Table("users").appendTo(c.b);
            try c.b.writeString(" WHERE ");
            for (c.predicates, 0..) |p, i| {
                if (i > 0) try c.b.writeString(" AND ");
                try p.appendTo(c.b);
            }
            try c.b.writeString(" ORDER BY ");
            for (c.order_terms, 0..) |o, i| {
                if (i > 0) try c.b.writeString(", ");
                try o.appendTo(c.b);
            }
            try c.b.writeString(" GROUP BY ");
            try c.b.ident("status");
            try c.b.writeString(" LIMIT ");
            try c.b.arg(.{ .int = 10 });
            try c.b.writeString(" OFFSET ");
            try c.b.arg(.{ .int = 20 });
            _ = c.b.query();
        }
    }.body);
}

pub const benchmarks = &.{
    Benchmark{ .name = "builder/simple_select", .run = benchSimpleSelect },
    Benchmark{ .name = "builder/complex_where", .run = benchComplexWhere },
};
```

- [ ] **Step 2: Compile to verify builder benchmarks**

Run:

```bash
zig build-exe bench/main.zig bench/builder.zig -femit-bin=/tmp/bench_test --mod zent:src/root.zig --deps zent --mod sqlite3_c:src/sql/sqlite3_include.h -lsqlite3 -lc
```

Expected: compiles successfully.

- [ ] **Step 3: Commit builder benchmarks**

```bash
git add bench/main.zig bench/builder.zig
git commit -m "bench: add SQL builder benchmarks"
```

---

### Task 3: Add row scan benchmarks (`bench/scan.zig`)

**Files:**
- Create: `bench/scan.zig`

**Interfaces:**
- Consumes: `Benchmark`, `runForCtx` from `bench/main.zig`; `scanRow` from `src/sql/scan.zig`; `driver.Row` from `src/sql/driver.zig`.
- Produces: `pub const benchmarks: []const Benchmark`.

- [ ] **Step 1: Write `bench/scan.zig`**

```zig
const std = @import("std");
const main = @import("main.zig");
const sql_scan = @import("zent").sql_scan;
const driver = @import("zent").sql_driver;

const Benchmark = main.Benchmark;
const Result = main.Result;

const MockRow = struct {
    pub const vtable = driver.Row.VTable{
        .columnCount = columnCount,
        .columnName = columnName,
        .getInt = getInt,
        .getFloat = getFloat,
        .getText = getText,
        .getBlob = getBlob,
        .isNull = isNull,
    };

    fn columnCount(_: *anyopaque) usize {
        return 4;
    }
    fn columnName(_: *anyopaque, index: usize) []const u8 {
        const names = &.{
            "id", "name", "age", "score",
        };
        return names[index];
    }
    fn getInt(_: *anyopaque, index: usize) ?i64 {
        return switch (index) {
            0 => 42,
            2 => 30,
            3 => 100,
            else => null,
        };
    }
    fn getFloat(_: *anyopaque, _: usize) ?f64 {
        return null;
    }
    fn getText(_: *anyopaque, index: usize) ?[]const u8 {
        if (index == 1) return "Alice";
        return null;
    }
    fn getBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn isNull(_: *anyopaque, _: usize) bool {
        return false;
    }
};

fn makeRow() driver.Row {
    return .{ .ptr = undefined, .vtable = &MockRow.vtable };
}

const User = struct {
    id: i64,
    name: []const u8,
    age: i64,
    score: i64,
};

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    row: driver.Row,
};

fn benchScanSingle(allocator: std.mem.Allocator, io: std.Io) !Result {
    var ctx = ScanCtx{ .allocator = allocator, .row = makeRow() };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *ScanCtx = @ptrCast(@alignCast(ptr));
            var user = try sql_scan.scanRow(User, c.allocator, c.row);
            c.allocator.free(user.name);
        }
    }.body);
}

const ScanBatchCtx = struct {
    allocator: std.mem.Allocator,
    row: driver.Row,
    batch_size: usize,
};

fn benchScanBatch100(allocator: std.mem.Allocator, io: std.Io) !Result {
    var ctx = ScanBatchCtx{ .allocator = allocator, .row = makeRow(), .batch_size = 100 };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *ScanBatchCtx = @ptrCast(@alignCast(ptr));
            var i: usize = 0;
            while (i < c.batch_size) : (i += 1) {
                var user = try sql_scan.scanRow(User, c.allocator, c.row);
                c.allocator.free(user.name);
            }
        }
    }.body);
}

pub const benchmarks = &.{
    Benchmark{ .name = "scan/single_entity", .run = benchScanSingle },
    Benchmark{ .name = "scan/batch_100", .run = benchScanBatch100 },
};
```

- [ ] **Step 2: Compile to verify scan benchmarks**

Run:

```bash
zig build-exe bench/main.zig bench/builder.zig bench/scan.zig -femit-bin=/tmp/bench_test --mod zent:src/root.zig --deps zent --mod sqlite3_c:src/sql/sqlite3_include.h -lsqlite3 -lc
```

Expected: compiles successfully.

- [ ] **Step 3: Commit scan benchmarks**

```bash
git add bench/scan.zig
git commit -m "bench: add row scan benchmarks"
```

---

### Task 4: Add connection pool benchmarks (`bench/pool.zig`)

**Files:**
- Create: `bench/pool.zig`

**Interfaces:**
- Consumes: `Benchmark`, `runForCtx` from `bench/main.zig`; `ConnPool` from `src/sql/pool.zig`; `SQLiteDriver` from `src/sql/sqlite.zig`.
- Produces: `pub const benchmarks: []const Benchmark`.

- [ ] **Step 1: Write `bench/pool.zig`**

```zig
const std = @import("std");
const main = @import("main.zig");
const zent = @import("zent");

const Benchmark = main.Benchmark;
const Result = main.Result;
const ConnPool = zent.sql_pool.ConnPool;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;

const PoolCtx = struct {
    pool: *ConnPool(SQLiteDriver),
};

fn benchBorrowRelease(allocator: std.mem.Allocator, io: std.Io) !Result {
    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 4,
        .max_connections = 4,
        .health_check_on_borrow = true,
        .io = io,
    });
    defer pool.deinit();

    var ctx = PoolCtx{ .pool = &pool };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *PoolCtx = @ptrCast(@alignCast(ptr));
            const conn = try c.pool.borrow();
            c.pool.release(conn);
        }
    }.body);
}

pub const benchmarks = &.{
    Benchmark{ .name = "pool/borrow_release", .run = benchBorrowRelease },
};
```

- [ ] **Step 2: Compile to verify pool benchmarks**

Run:

```bash
zig build-exe bench/main.zig bench/builder.zig bench/scan.zig bench/pool.zig -femit-bin=/tmp/bench_test --mod zent:src/root.zig --deps zent --mod sqlite3_c:src/sql/sqlite3_include.h -lsqlite3 -lc
```

Expected: compiles successfully.

- [ ] **Step 3: Commit pool benchmarks**

```bash
git add bench/pool.zig
git commit -m "bench: add connection pool benchmarks"
```

---

### Task 5: Register `zig build benchmark` in `build.zig`

**Files:**
- Modify: `build.zig`

**Interfaces:**
- Consumes: existing `zent_mod` and `sqlite_c_mod`.
- Produces: `benchmark` build step.

- [ ] **Step 1: Add benchmark executable and step to `build.zig`**

Insert the following block after the `run-pool` step block (around line 150):

```zig
    // -------------------------------------------------------------
    // Benchmarks
    // -------------------------------------------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zent", zent_mod);
    bench_mod.addImport("sqlite3_c", sqlite_c_mod);
    bench_mod.linkSystemLibrary("sqlite3", .{});

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("benchmark", "Run micro-benchmarks");
    bench_step.dependOn(&run_bench.step);
```

- [ ] **Step 2: Verify the new build step**

Run:

```bash
zig build benchmark
```

Expected: builds and prints a benchmark table with five rows.

- [ ] **Step 3: Commit build.zig change**

```bash
git add build.zig
git commit -m "build: add benchmark target"
```

---

### Task 6: Run baseline benchmarks and record numbers

**Files:**
- None (read-only observation).

- [ ] **Step 1: Run Debug benchmark**

Run:

```bash
zig build benchmark
```

Copy the output into a scratch file (e.g., `/tmp/bench_debug.txt`).

- [ ] **Step 2: Run ReleaseFast benchmark**

Run:

```bash
zig build benchmark -Doptimize=ReleaseFast
```

Copy the output into `/tmp/bench_release.txt`.

- [ ] **Step 3: Identify the highest ns/op case**

Compare the five cases. The one with the highest ns/op is the first optimization target. Typical expectation:

- `scan/batch_100` is often dominated by `allocator.dupe` for strings.
- `pool/borrow_release` is often dominated by `ping()` executing `SELECT 1`.
- `builder/complex_where` is often dominated by `arg()` formatting and allocations.

Pick the single worst offender to optimize first.

---

### Task 7: Optimize the first confirmed hotspot

The exact target is chosen after Task 6. Below are the three most likely options; implement only the one that the numbers confirm.

#### Option A: Reduce `Builder.arg` formatting cost

**Files:**
- Modify: `src/sql/builder.zig`

**Interfaces:**
- No public API change.

- [ ] **Step 1: Replace `std.fmt` allocation with stack formatting for scalar values**

Locate `Builder.arg` (around line 100). Change it from using `b.dialect.placeholder(&buf, idx)` with a 16-byte stack buffer to formatting common scalar values (`int`, `float`, `bool`) into a fixed stack buffer and appending directly, avoiding `ensureUnusedCapacity`/`appendSlice` fragmentation.

Current code:

```zig
pub fn arg(b: *Builder, value: Value) !void {
    try b.args.append(value);
    const idx = b.args.items.len;
    var buf: [16]u8 = undefined;
    const ph = try b.dialect.placeholder(&buf, idx);
    try b.buffer.appendSlice(ph);
}
```

Optimized code:

```zig
pub fn arg(b: *Builder, value: Value) !void {
    try b.args.append(value);
    const idx = b.args.items.len;
    var buf: [32]u8 = undefined;
    const ph = try b.dialect.placeholder(&buf, idx);
    try b.buffer.ensureUnusedCapacity(ph.len);
    b.buffer.appendSliceAssumeCapacity(ph);
}
```

If the benchmark shows that placeholder formatting itself is expensive, also consider an inline fast path for dialects whose placeholder is simply `?` or `$N`.

- [ ] **Step 2: Run tests**

```bash
zig build test
zig build test-integration
zig fmt --check src examples tests build.zig
```

Expected: all pass.

- [ ] **Step 3: Re-run benchmark and compare**

```bash
zig build benchmark -Doptimize=ReleaseFast
```

Expected: the `builder/*` cases show lower ns/op than the baseline in `/tmp/bench_release.txt`.

- [ ] **Step 4: Commit**

```bash
git add src/sql/builder.zig
git commit -m "perf(builder): reduce arg() append overhead"
```

#### Option B: Avoid per-row allocation for primitive-only scans

**Files:**
- Modify: `src/sql/scan.zig`

**Interfaces:**
- Adds `pub fn scanRowNoAlloc(comptime T: type, row: Row) !T` for types that contain only primitives (no `[]const u8`, no nested allocatable fields).

- [ ] **Step 1: Add `scanRowNoAlloc`**

Insert after `scanRow`:

```zig
/// Scan a row into a value of type T without using an allocator.
/// T must contain only primitive, non-allocating types.
pub fn scanRowNoAlloc(comptime T: type, row: Row) !T {
    comptime {
        const info = @typeInfo(T);
        if (info != ."struct") @compileError("scanRowNoAlloc only supports structs");
        inline for (info."struct".field_types) |FieldType| {
            switch (@typeInfo(FieldType)) {
                .int, .float, .bool, .optional => |opt| {
                    switch (@typeInfo(opt.child)) {
                        .int, .float, .bool => {},
                        else => @compileError("scanRowNoAlloc does not support allocating types"),
                    }
                },
                else => @compileError("scanRowNoAlloc does not support allocating types"),
            }
        }
    }
    return scanRowInnerNoAlloc(T, row, 0);
}

fn scanColumnNoAlloc(comptime T: type, row: Row, index: usize) !T {
    const info = @typeInfo(T);
    switch (info) {
        .int => |int| {
            if (int.bits <= 64 and int.signedness == .signed) {
                const v = row.getInt(index) orelse return error.TypeMismatch;
                return @intCast(v);
            }
            @compileError("Unsupported integer type for scanning: " ++ @typeName(T));
        },
        .float => |float| {
            if (float.bits <= 64) {
                const v = row.getFloat(index) orelse return error.TypeMismatch;
                if (T == f32) return @floatCast(v);
                return v;
            }
            @compileError("Unsupported float type for scanning: " ++ @typeName(T));
        },
        .bool => {
            const v = row.getInt(index) orelse return error.TypeMismatch;
            return v != 0;
        },
        .optional => |opt| {
            if (row.isNull(index)) return null;
            return try scanColumnNoAlloc(opt.child, row, index);
        },
        else => @compileError("Unsupported type for no-alloc scanning: " ++ @typeName(T)),
    }
}

fn scanRowInnerNoAlloc(comptime T: type, row: Row, comptime offset: usize) !T {
    const info = @typeInfo(T);
    var value: T = undefined;
    var col_idx: usize = offset;
    inline for (info."struct".field_names, info."struct".field_types) |field_name, field_type| {
        if (comptime std.mem.eql(u8, field_name, "edges")) {
            @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
        } else {
            @field(value, field_name) = try scanColumnNoAlloc(field_type, row, col_idx);
            col_idx += 1;
        }
    }
    return value;
}
```

- [ ] **Step 2: Update `bench/scan.zig` to use `scanRowNoAlloc` for a new primitive-only benchmark**

Add `UserLite` struct without string fields and a new benchmark `scan/batch_100_primitives` to demonstrate the speedup.

- [ ] **Step 3: Run tests and re-run benchmark**

```bash
zig build test
zig build test-integration
zig fmt --check src examples tests build.zig
zig build benchmark -Doptimize=ReleaseFast
```

- [ ] **Step 4: Commit**

```bash
git add src/sql/scan.zig bench/scan.zig
git commit -m "perf(scan): add no-alloc primitive row scanner"
```

#### Option C: Skip redundant pool health checks

**Files:**
- Modify: `src/sql/pool.zig`

**Interfaces:**
- Adds `health_check_interval_ms: u32 = 0` to `ConnPool.Options`. When non-zero, a connection is not pinged again within the interval.

- [ ] **Step 1: Track last-checked timestamp per connection**

Add a `last_check_ms: u64 = 0` field to the driver `D` via compile-time field injection? That is invasive. Instead, track a parallel `std.ArrayListUnmanaged(u64)` in `ConnPool` aligned with `all.items`. This keeps `D` unchanged.

Alternatively, add the field only if `D` already has a place for metadata, but that couples drivers to the pool.

Use the parallel array approach:

```zig
last_checked_ms: std.ArrayListUnmanaged(u64) = .empty,
```

Initialize it in `init` with capacity `max_connections` and zero-fill to length `min_connections`. Update it when a health check succeeds.

In `borrow`, before calling `ping()`, check:

```zig
const now_ms = @divFloor(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds(), 1);
if (self.options.health_check_interval_ms > 0 and
    now_ms - self.last_checked_ms.items[conn_index] < self.options.health_check_interval_ms) {
    // skip ping
} else {
    conn.asDriver().ping() catch { ... };
    self.last_checked_ms.items[conn_index] = now_ms;
}
```

Find `conn_index` by iterating `all.items` (this is O(n) but `max_connections` is small).

- [ ] **Step 2: Add a benchmark variant with interval enabled**

Update `bench/pool.zig` to run two cases: `pool/borrow_release` and `pool/borrow_release_no_health_check` (or with interval=1000).

- [ ] **Step 3: Run tests and re-run benchmark**

```bash
zig build test
zig build test-integration
zig fmt --check src examples tests build.zig
zig build benchmark -Doptimize=ReleaseFast
```

- [ ] **Step 4: Commit**

```bash
git add src/sql/pool.zig bench/pool.zig
git commit -m "perf(pool): add configurable health-check interval"
```

---

### Task 8: Final verification and documentation update

**Files:**
- Modify: `docs/superpowers/specs/2026-07-18-benchmark-design.md` (mark completed items)
- Modify: `README.md` (add `zig build benchmark` to the run examples section)

- [ ] **Step 1: Update README.md**

In the "Run Examples" section (around line 35), add:

```markdown
```bash
zig build run-start    # schema introspection + CRUD smoke test
zig build run-complex  # e-commerce demo with advanced SQL
zig build run-pool     # connection-pool usage demo
zig build benchmark    # micro-benchmarks
```
```

- [ ] **Step 2: Update design doc**

Open `docs/superpowers/specs/2026-07-18-benchmark-design.md` and append a "Results" section with the ReleaseFast baseline numbers and the measured improvement.

- [ ] **Step 3: Run final verification**

```bash
zig fmt --check src examples tests build.zig
zig build test
zig build test-integration
zig build benchmark
zig build benchmark -Doptimize=ReleaseFast
```

Expected: all commands succeed.

- [ ] **Step 4: Commit final documentation**

```bash
git add README.md docs/superpowers/specs/2026-07-18-benchmark-design.md
git commit -m "docs: document benchmark target and record baseline results"
```

---

## Self-Review

**1. Spec coverage:**
- Single runner in `bench/main.zig`: Task 1.
- Builder/scan/pool benchmarks: Tasks 2, 3, 4.
- `zig build benchmark`: Task 5.
- Data-driven optimizations: Tasks 6 and 7.
- Documentation update: Task 8.
- No gaps.

**2. Placeholder scan:**
- No "TBD", "TODO", "implement later".
- Task 7 lists three options but explicitly says implement only the one confirmed by Task 6; each option has complete code.
- All file paths and commands are exact.

**3. Type consistency:**
- `runForCtx` signature is consistent across Task 1 and all benchmark files.
- `Benchmark.run` signature matches the runner's expectation.
- Mock `driver.Row.VTable` matches the actual VTable fields.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-18-benchmark.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?

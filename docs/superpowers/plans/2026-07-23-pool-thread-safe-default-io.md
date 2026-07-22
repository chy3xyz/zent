# Pool Default Thread-Safe Io Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change `ConnPool` so that when `options.io` is omitted it creates and owns a thread-safe `std.Io.Threaded` instance, instead of using the single-threaded global Io.

**Architecture:** Add an `owned_io: ?*std.Io.Threaded` field to the generated pool struct. In `init`, allocate and initialize a threaded Io when no external Io is provided. In `deinit`, destroy the owned Io after closing connections. Update doc comments and add a multi-threaded borrow/release test.

**Tech Stack:** Zig 0.17-dev, existing `zent.sql.pool`, `std.Io.Threaded`.

## Global Constraints

- Target Zig 0.17-dev.
- All public APIs keep the existing fluent/chainable style.
- Every allocation must have a matching `defer`/`errdefer` per project conventions.
- Tests must use `std.testing.allocator` and `std.Thread` where needed.
- Run `zig fmt --check src examples tests build.zig` before each commit.
- Run `zig build test` and `zig build test-integration` before claiming done.

---

## Task 1: Default to Owned Thread-Safe Io

**Files:**
- Modify: `src/sql/pool.zig:115-170` (struct fields, `init`, `deinit`)
- Test: `src/sql/pool.zig` test section

**Interfaces:**
- Consumes: `std.Io.Threaded.init(allocator, .{})`, `std.Io.Threaded.io()`, `std.Io.Threaded.deinit()`
- Produces: `ConnPool.owned_io: ?*std.Io.Threaded`, updated `init`/`deinit` behavior

- [ ] **Step 1: Add `owned_io` field and update `init`**

In `src/sql/pool.zig`, inside the generated `ConnPool(D)` struct, add:

```zig
owned_io: ?*std.Io.Threaded = null,
```

Then replace the Io assignment in `init`:

```zig
if (options.io) |io| {
    self.io = io;
} else {
    const threaded = try allocator.create(std.Io.Threaded);
    errdefer allocator.destroy(threaded);
    threaded.* = std.Io.Threaded.init(allocator, .{});
    self.owned_io = threaded;
    self.io = threaded.io();
}
```

Remove the old line:

```zig
const io = options.io orelse std.Io.Threaded.global_single_threaded.io();
```

- [ ] **Step 2: Update `deinit` to destroy owned Io**

In `src/sql/pool.zig` `deinit`, after releasing connections and freeing arrays, add:

```zig
if (self.owned_io) |t| {
    t.deinit();
    self.allocator.destroy(t);
}
```

Place this after `self.mutex.unlock(io)` and before `self.* = undefined`.

- [ ] **Step 3: Update doc comment for `Options.io`**

Change the comment from warning about single-threaded default to:

```zig
/// I/O abstraction used for blocking synchronization. When omitted, the pool
/// creates and owns a thread-safe `std.Io.Threaded` instance. Applications that
/// want to share an `Io` across multiple pools or use a custom implementation
/// can provide an explicit `std.Io` here.
```

- [ ] **Step 4: Run unit tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/sql/pool.zig
git commit -m "feat(pool): default to thread-safe owned Io

When options.io is null, ConnPool now creates and owns a
std.Io.Threaded instance instead of using the single-threaded
global Io. The owned instance is destroyed in deinit."
```

---

## Task 2: Multi-Threaded Borrow/Release Test

**Files:**
- Modify: `src/sql/pool.zig` test section

**Interfaces:**
- Consumes: `ConnPool.init`, `ConnPool.borrow`, `ConnPool.release`, `ConnPool.deinit`, `std.Thread`
- Produces: passing test verifying cross-thread pool usage

- [ ] **Step 1: Add multi-threaded borrow/release test**

Append to the test section in `src/sql/pool.zig`:

```zig
test "ConnPool supports concurrent borrow and release across threads" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                var drv = try SQLiteDriver.open(a, ":memory:");
                _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});
                return drv;
            }
        }.f,
        .min_connections = 1,
        .max_connections = 4,
        .health_check_on_borrow = false,
        .max_retries = 0,
    });
    defer pool.deinit();

    const Ctx = struct {
        pool: *ConnPool(SQLiteDriver),
        done: std.atomic.Value(usize),

        fn run(ctx: *@This()) void {
            for (0..50) |_| {
                const conn = ctx.pool.borrow() catch unreachable;
                _ = conn.asDriver().exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 1 }}) catch unreachable;
                ctx.pool.release(conn);
            }
            _ = ctx.done.fetchAdd(1, .monotonic);
        }
    };

    var ctx = Ctx{
        .pool = &pool,
        .done = std.atomic.Value(usize).init(0),
    };

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, Ctx.run, .{&ctx}) catch unreachable;
    }
    for (&threads) |*t| {
        t.join();
    }

    try std.testing.expectEqual(@as(usize, thread_count), ctx.done.load(.monotonic));

    var rows = try pool.asDriver().query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 50 * thread_count), row.getInt(0).?);
}
```

- [ ] **Step 2: Run unit tests**

Run: `zig build test`
Expected: PASS (including the new test)

- [ ] **Step 3: Commit**

```bash
git add src/sql/pool.zig
git commit -m "test(pool): concurrent borrow/release across threads"
```

---

## Task 3: Final Verification

- [ ] **Step 1: Run formatting check**

Run: `zig fmt --check src examples tests build.zig`
Expected: PASS

- [ ] **Step 2: Run unit tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 3: Run integration tests**

Run: `zig build test-integration`
Expected: PASS

- [ ] **Step 4: Run example sanity checks**

Run: `zig build run-start` and `zig build run-complex`
Expected: both PASS

- [ ] **Step 5: Optional commit if any fixes were needed**

If any of the above required changes, commit them. Otherwise no commit is needed.

---

## Spec Coverage Check

| Spec Section | Implementing Task |
|---|---|
| Pool owns threaded Io by default | Task 1 |
| Explicit `options.io` still overrides | Task 1 |
| `deinit` destroys owned Io | Task 1 |
| Updated `Options.io` doc comment | Task 1 |
| Multi-threaded borrow/release test | Task 2 |

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-23-pool-thread-safe-default-io.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** - Dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?

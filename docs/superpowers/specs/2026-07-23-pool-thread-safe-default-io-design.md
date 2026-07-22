# Pool Default Thread-Safe Io Design

## Goal
Make `zent.sql.pool.ConnPool` safe to use from multiple threads by default, removing the current foot-gun where `options.io == null` selects a single-threaded `std.Io` that cannot perform cross-thread blocking waits.

## Background
`src/sql/pool.zig` currently defaults to:

```zig
const io = options.io orelse std.Io.Threaded.global_single_threaded.io();
```

`global_single_threaded` explicitly does **not** support concurrency or cancellation. In a multi-threaded application that forgets to pass `options.io = some_threaded_io`, pool borrow/release can misbehave when threads block on the condition variable.

## Design

### 1. ConnPool owns a threaded Io when none is supplied

Add an `owned_io` field to the generated `ConnPool(D)` struct:

```zig
owned_io: ?*std.Io.Threaded = null,
```

In `init`:

```zig
if (options.io) |io| {
    self.io = io;
} else {
    const threaded = try allocator.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(allocator, .{});
    self.owned_io = threaded;
    self.io = threaded.io();
}
```

In `deinit`:

```zig
if (self.owned_io) |t| {
    t.deinit();
    self.allocator.destroy(t);
}
```

### 2. Explicit `options.io` still overrides the default

Callers that already create and manage their own `std.Io` can continue to pass it in. The pool will not create an owned Io in that case and will not destroy the external one.

### 3. Allocator requirements

`std.Io.Threaded.init` requires a thread-safe allocator for async/concurrent operations. The pool already receives `allocator: std.mem.Allocator`; callers should pass a thread-safe allocator (e.g. `std.heap.page_allocator`, `std.heap.c_allocator`, or a guarded arena) when using the pool from multiple threads.

### 4. Documentation

Update the doc comment above `Options.io` to say that the default is now a thread-safe Io owned by the pool, and that an explicit Io is only needed for custom threading models or sharing an Io across pools.

### 5. Testing

Add a test that spawns multiple threads, each borrowing and releasing a connection from the same pool, to verify the condition variable and mutex work correctly with the default Io.

## Compatibility

- API: unchanged. `ConnPool.init(allocator, options)` signature stays the same.
- Behavior: changes for callers that relied on the single-threaded default. Such callers can restore the old behavior by passing `std.Io.Threaded.global_single_threaded.io()` explicitly.
- Performance: one `std.Io.Threaded` instance per pool; acceptable for typical applications. A future optimization could share one Io across pools.

## Files

- `src/sql/pool.zig` — primary implementation.
- `src/sql/pool.zig` tests — add multi-threaded borrow/release test.

## Acceptance Criteria

- `zig build test` passes.
- `zig build test-integration` passes.
- New multi-threaded pool test passes on macOS and Linux.
- Existing callers that pass `options.io` continue to work unchanged.

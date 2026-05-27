const std = @import("std");
const reflect = @import("zevy_reflect");
const Mutex = @import("../lock/mutex.zig").Mutex;
const RwLock = @import("../lock/rwlock.zig").RwLock;
const Allocator = std.mem.Allocator;

/// Atomic reference counted pointer.
///
/// Not thread-safe for mutation of the contained data; only the reference counting is atomic.
/// This is purposefully designed this way to give control to the user for how to handle data access
///
/// Use `Arc(T).initWithMutex` for thread-safe data access.
pub fn Arc(comptime T: type) type {
    return opaque {
        const Self = @This();

        const Inner = struct {
            value: T,
            ref_count: std.atomic.Value(usize),
            allocator: Allocator,

            fn deinit(self: *Inner) void {
                // Only call deinit if the type structurally requires cleanup
                @import("../lock/mutex.zig").cleanup(T, &self.value, self.allocator);
            }
        };

        /// The value type wrapped by this Arc.
        pub const Child = T;

        /// Create a new Arc with initial value
        pub fn init(allocator: Allocator, value: T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = value,
                .ref_count = std.atomic.Value(usize).init(1),
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Create a new ArcMutex wrapping the given value.
        /// Prefer `ArcMutex(T).init` directly; this is a convenience alias.
        pub fn initWithMutex(allocator: Allocator, value: T) !*ArcMutex(T) {
            return ArcMutex(T).init(allocator, value);
        }

        /// Create a new ArcRwLock wrapping the given value.
        /// Prefer `ArcRwLock(T).init` directly; this is a convenience alias.
        pub fn initWithRwLock(allocator: Allocator, value: T) !*ArcRwLock(T) {
            return ArcRwLock(T).init(allocator, value);
        }

        /// Clone the Arc, atomically incrementing the reference count
        pub fn clone(self: *Self) *Self {
            const inner: *Inner = @ptrCast(@alignCast(self));
            _ = inner.ref_count.fetchAdd(1, .monotonic);
            return self;
        }

        /// Get a pointer to the contained value
        pub fn get(self: *Self) *T {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return &inner.value;
        }

        /// Get the current reference count
        pub fn strongCount(self: *Self) usize {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.ref_count.load(.monotonic);
        }

        /// Transfer the contained value into a newly allocated owned pointer.
        ///
        /// Fails with `error.NotUnique` if this Arc has more than one strong reference.
        /// The returned pointer is allocated with the same allocator used to create the Arc.
        /// The caller becomes responsible for calling `deinit` on the value when needed and
        /// destroying the returned pointer with that allocator.
        pub fn toOwned(self: *Self) !*T {
            const inner: *Inner = @ptrCast(@alignCast(self));
            if (inner.ref_count.load(.acquire) != 1) return error.NotUnique;

            const allocator = inner.allocator;
            const owned = try allocator.create(T);
            owned.* = inner.value;
            allocator.destroy(inner);
            return owned;
        }

        /// Atomically decrement reference count and free if it reaches zero
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));
            const old_count = inner.ref_count.fetchSub(1, .release);
            if (old_count == 1) {
                // Acquire fence to ensure all previous writes are visible
                _ = inner.ref_count.load(.acquire);

                inner.deinit();

                const allocator = inner.allocator;
                allocator.destroy(inner);
            }
        }

        /// Create a new Arc from an existing value pointer (takes ownership)
        pub fn fromOwned(allocator: Allocator, value_ptr: *T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = value_ptr.*,
                .ref_count = std.atomic.Value(usize).init(1),
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }
    };
}

/// Atomic reference-counted handle wrapping a `Mutex`-protected value.
/// Prefer this over `Arc(*Mutex(T))` — call `lock()`/`tryLock()` directly to access the value.
///
/// Example:
/// ```zig
/// const ref = try ArcMutex(i32).init(allocator, 42);
/// defer ref.deinit();
/// var guard = ref.lock();
/// defer guard.deinit();
/// guard.get().* += 1;
/// ```
pub fn ArcMutex(comptime T: type) type {
    return opaque {
        const Self = @This();

        const Inner = struct {
            value: *Mutex(T),
            ref_count: std.atomic.Value(usize),
            allocator: Allocator,
        };

        /// The value type wrapped by this ArcMutex.
        pub fn Child(self: *Self) type {
            _ = self;
            return T;
        }

        /// Create a new ArcMutex with the given initial value.
        pub fn init(allocator: Allocator, value: T) !*Self {
            const mutex_ptr = try Mutex(T).init(allocator, value);
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = mutex_ptr,
                .ref_count = std.atomic.Value(usize).init(1),
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Atomically increment the reference count and return a second handle.
        pub fn clone(self: *Self) *Self {
            const inner: *Inner = @ptrCast(@alignCast(self));
            _ = inner.ref_count.fetchAdd(1, .monotonic);
            return self;
        }

        /// Lock the mutex, returning a scoped guard.
        /// Call `guard.get()` to access the value; call `guard.deinit()` to release the lock.
        pub fn lock(self: *Self) Mutex(T).Guard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.value.lock();
        }

        /// Try to lock without blocking. Returns `null` if already locked.
        pub fn tryLock(self: *Self) ?Mutex(T).Guard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.value.tryLock();
        }

        /// Return the current reference count.
        pub fn strongCount(self: *Self) usize {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.ref_count.load(.monotonic);
        }

        /// Decrement the reference count; free all resources when it reaches zero.
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));
            const old_count = inner.ref_count.fetchSub(1, .release);
            if (old_count == 1) {
                _ = inner.ref_count.load(.acquire);
                inner.value.deinit();
                inner.allocator.destroy(inner);
            }
        }
    };
}

/// Atomic reference-counted handle wrapping an `RwLock`-protected value.
/// Prefer this over `Arc(*RwLock(T))` — call `lockRead()`/`lockWrite()` directly to access the value.
///
/// Example:
/// ```zig
/// const ref = try ArcRwLock(u32).init(allocator, 0);
/// defer ref.deinit();
/// var rg = ref.lockRead();
/// defer rg.deinit();
/// std.debug.print("{}", .{rg.get().*});
/// ```
pub fn ArcRwLock(comptime T: type) type {
    return opaque {
        const Self = @This();

        const Inner = struct {
            value: *RwLock(T),
            ref_count: std.atomic.Value(usize),
            allocator: Allocator,
        };

        /// The value type wrapped by this ArcRwLock.
        pub fn Child(self: *Self) type {
            _ = self;
            return T;
        }

        /// Create a new ArcRwLock with the given initial value.
        pub fn init(allocator: Allocator, value: T) !*Self {
            const rwlock_ptr = try RwLock(T).init(allocator, value);
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = rwlock_ptr,
                .ref_count = std.atomic.Value(usize).init(1),
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Atomically increment the reference count and return a second handle.
        pub fn clone(self: *Self) *Self {
            const inner: *Inner = @ptrCast(@alignCast(self));
            _ = inner.ref_count.fetchAdd(1, .monotonic);
            return self;
        }

        /// Acquire a shared read lock. Multiple readers may hold simultaneously.
        pub fn lockRead(self: *Self) RwLock(T).ReadGuard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.value.lockRead();
        }

        /// Try to acquire a shared read lock without blocking.
        pub fn tryLockRead(self: *Self) ?RwLock(T).ReadGuard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.value.tryLockRead();
        }

        /// Acquire an exclusive write lock.
        pub fn lockWrite(self: *Self) RwLock(T).WriteGuard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.value.lockWrite();
        }

        /// Try to acquire an exclusive write lock without blocking.
        pub fn tryLockWrite(self: *Self) ?RwLock(T).WriteGuard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.value.tryLockWrite();
        }

        /// Return the current reference count.
        pub fn strongCount(self: *Self) usize {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return inner.ref_count.load(.monotonic);
        }

        /// Decrement the reference count; free all resources when it reaches zero.
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));
            const old_count = inner.ref_count.fetchSub(1, .release);
            if (old_count == 1) {
                _ = inner.ref_count.load(.acquire);
                inner.value.deinit();
                inner.allocator.destroy(inner);
            }
        }
    };
}

test "Arc basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arc = try Arc(i32).init(allocator, 42);
    defer arc.deinit();

    const arcType = Arc(i32).Child;
    try testing.expectEqual(42, arc.get().*);
    try testing.expectEqual(1, arc.strongCount());
    try testing.expectEqual(@typeInfo(i32), @typeInfo(arcType));
}

test "Arc clone and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const arc1 = try Arc(i32).init(allocator, 100);
    defer arc1.deinit();

    const arc2 = arc1.clone();
    defer arc2.deinit();

    try testing.expectEqual(2, arc1.strongCount());
    try testing.expectEqual(2, arc2.strongCount());
    try testing.expectEqual(100, arc1.get().*);
    try testing.expectEqual(100, arc2.get().*);
}

test "Arc with struct type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Point = struct {
        x: f32,
        y: f32,
    };

    const arc = try Arc(Point).init(allocator, .{ .x = 1.0, .y = 2.0 });
    defer arc.deinit();

    try testing.expectEqual(1.0, arc.get().x);
    try testing.expectEqual(2.0, arc.get().y);

    arc.get().x = 3.0;
    try testing.expectEqual(3.0, arc.get().x);
}

test "Arc memory cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const arc1 = try Arc(i32).init(allocator, 999);
    const arc2 = arc1.clone();
    const arc3 = arc1.clone();

    try testing.expectEqual(3, arc1.strongCount());

    arc1.deinit();
    try testing.expectEqual(2, arc2.strongCount());

    arc2.deinit();
    try testing.expectEqual(1, arc3.strongCount());

    arc3.deinit();
    // Memory should be freed at this point
}

test "Arc thread safety - clone and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const arc = try Arc(i32).init(allocator, 0);
    defer arc.deinit();

    const ThreadContext = struct {
        arc_ptr: *Arc(i32),
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: ThreadContext) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const local_arc = ctx.arc_ptr.clone();
                defer local_arc.deinit();
                // Do some work with the arc
                _ = local_arc.get();
            }
        }
    }.run;

    const thread_count = 4;
    const iterations = 1000;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ThreadContext{
            .arc_ptr = arc,
            .iterations = iterations,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    try testing.expectEqual(1, arc.strongCount());
}

test "Arc thread safety - concurrent mutation with mutex" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Counter = struct {
        count: std.atomic.Value(i32),

        fn init(val: i32) @This() {
            return .{ .count = std.atomic.Value(i32).init(val) };
        }

        fn increment(self: *@This()) void {
            _ = self.count.fetchAdd(1, .monotonic);
        }

        fn get(self: *@This()) i32 {
            return self.count.load(.monotonic);
        }
    };

    const arc = try Arc(Counter).init(allocator, Counter.init(0));
    defer arc.deinit();

    const ThreadContext = struct {
        arc_ptr: *Arc(Counter),
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: ThreadContext) void {
            const local_arc = ctx.arc_ptr.clone();
            defer local_arc.deinit();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                local_arc.get().increment();
            }
        }
    }.run;

    const thread_count = 4;
    const iterations = 1000;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ThreadContext{
            .arc_ptr = arc,
            .iterations = iterations,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    const final_count = arc.get().get();
    try testing.expectEqual(thread_count * iterations, final_count);
    try testing.expectEqual(1, arc.strongCount());
}

test "Arc thread safety - concurrent reads and writes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Data = struct {
        a: std.atomic.Value(i32),
        b: std.atomic.Value(i32),
        c: std.atomic.Value(i32),

        fn init() @This() {
            return .{
                .a = std.atomic.Value(i32).init(0),
                .b = std.atomic.Value(i32).init(0),
                .c = std.atomic.Value(i32).init(0),
            };
        }
    };

    const arc = try Arc(Data).init(allocator, Data.init());
    defer arc.deinit();

    const WriterContext = struct {
        arc_ptr: *Arc(Data),
        iterations: usize,
        field_id: u8,
    };

    const ReaderContext = struct {
        arc_ptr: *Arc(Data),
        iterations: usize,
    };

    const writer = struct {
        fn run(ctx: WriterContext) void {
            const local_arc = ctx.arc_ptr.clone();
            defer local_arc.deinit();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const data = local_arc.get();
                switch (ctx.field_id) {
                    0 => _ = data.a.fetchAdd(1, .monotonic),
                    1 => _ = data.b.fetchAdd(1, .monotonic),
                    2 => _ = data.c.fetchAdd(1, .monotonic),
                    else => unreachable,
                }
            }
        }
    }.run;

    const reader = struct {
        fn run(ctx: ReaderContext) void {
            const local_arc = ctx.arc_ptr.clone();
            defer local_arc.deinit();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const data = local_arc.get();
                // Just read the values to ensure no data races
                _ = data.a.load(.monotonic);
                _ = data.b.load(.monotonic);
                _ = data.c.load(.monotonic);
            }
        }
    }.run;

    const writer_count = 3;
    const reader_count = 2;
    const iterations = 500;
    var threads: [writer_count + reader_count]std.Thread = undefined;

    // Spawn writers
    var i: usize = 0;
    while (i < writer_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, writer, .{WriterContext{
            .arc_ptr = arc,
            .iterations = iterations,
            .field_id = @intCast(i),
        }});
    }

    // Spawn readers
    while (i < writer_count + reader_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, reader, .{ReaderContext{
            .arc_ptr = arc,
            .iterations = iterations * 2,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    const data = arc.get();
    try testing.expectEqual(iterations, data.a.load(.monotonic));
    try testing.expectEqual(iterations, data.b.load(.monotonic));
    try testing.expectEqual(iterations, data.c.load(.monotonic));
    try testing.expectEqual(1, arc.strongCount());
}

test "Arc thread safety - stress test with heavy cloning" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const SharedState = struct {
        operations: std.atomic.Value(usize),

        fn init() @This() {
            return .{ .operations = std.atomic.Value(usize).init(0) };
        }

        fn recordOp(self: *@This()) void {
            _ = self.operations.fetchAdd(1, .monotonic);
        }

        fn getOps(self: *@This()) usize {
            return self.operations.load(.monotonic);
        }
    };

    const arc = try Arc(SharedState).init(allocator, SharedState.init());
    defer arc.deinit();

    const ThreadContext = struct {
        arc_ptr: *Arc(SharedState),
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: ThreadContext) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                // Clone multiple times
                const arc1 = ctx.arc_ptr.clone();
                const arc2 = ctx.arc_ptr.clone();
                const arc3 = arc1.clone();

                // Do some work
                arc1.get().recordOp();
                arc2.get().recordOp();
                arc3.get().recordOp();

                // Release in different order
                arc2.deinit();
                arc1.deinit();
                arc3.deinit();
            }
        }
    }.run;

    const thread_count = 8;
    const iterations = 100;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ThreadContext{
            .arc_ptr = arc,
            .iterations = iterations,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    const final_ops = arc.get().getOps();
    try testing.expectEqual(thread_count * iterations * 3, final_ops);
    try testing.expectEqual(1, arc.strongCount());
}

test "Arc thread safety - data race demonstration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const UnsafeCounter = struct {
        count: i32, // Non-atomic - will cause data races

        fn init(val: i32) @This() {
            return .{ .count = val };
        }

        fn increment(self: *@This()) void {
            self.count += 1; // This is not thread-safe
        }

        fn get(self: *@This()) i32 {
            return self.count;
        }
    };

    const arc = try Arc(UnsafeCounter).init(allocator, UnsafeCounter.init(0));
    defer arc.deinit();

    const ThreadContext = struct {
        arc_ptr: *Arc(UnsafeCounter),
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: ThreadContext) void {
            const local_arc = ctx.arc_ptr.clone();
            defer local_arc.deinit();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                local_arc.get().increment();
            }
        }
    }.run;

    const thread_count = 4;
    const iterations = 1000;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ThreadContext{
            .arc_ptr = arc,
            .iterations = iterations,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    const final_count = arc.get().get();
    // Due to data races, the final count may be less than expected
    // This demonstrates that Arc only protects reference counting, not the contained data
    try testing.expect(final_count <= thread_count * iterations);
    try testing.expect(final_count >= 0); // At least it should be non-negative
    try testing.expectEqual(1, arc.strongCount());
}

test "Arc calls deinit on contained value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestType = struct {
        deinit_called: *bool,

        fn init(deinit_flag: *bool) @This() {
            return .{ .deinit_called = deinit_flag };
        }

        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };

    var deinit_flag = false;
    const value = TestType.init(&deinit_flag);
    const arc = try Arc(TestType).init(allocator, value);

    // Deinit should call the deinit method on the contained value
    arc.deinit();

    try testing.expectEqual(true, deinit_flag);
}

test "Arc calls deinit on contained pointer value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestType = struct {
        deinit_called: *bool,

        fn init(deinit_flag: *bool) @This() {
            return .{ .deinit_called = deinit_flag };
        }

        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };

    var deinit_flag = false;

    const arc = try Arc(TestType).init(allocator, TestType.init(&deinit_flag));

    // Deinit should call the deinit method on the pointed-to value
    // Note: Arc frees the pointer itself, but the pointed-to TestType's deinit is called
    arc.deinit();

    try testing.expect(deinit_flag);
}

test "Arc with Mutex - thread-safe data access" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create Arc containing a pointer to the Mutex
    const arc = try ArcMutex(i32).init(allocator, 0);
    defer arc.deinit();

    const ThreadContext = struct {
        arc_ptr: *ArcMutex(i32),
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: ThreadContext) void {
            const local_arc = ctx.arc_ptr.clone();
            defer local_arc.deinit();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var guard = local_arc.lock();
                defer guard.deinit();
                guard.get().* += 1;
            }
        }
    }.run;

    const thread_count = 10;
    const iterations = 1000;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ThreadContext{
            .arc_ptr = arc,
            .iterations = iterations,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    // Check the final value - should be exactly correct due to mutex protection
    {
        var guard = arc.lock();
        defer guard.deinit();
        const final_count = guard.get().*;
        try testing.expectEqual(thread_count * iterations, final_count);
    }
    try testing.expectEqual(1, arc.strongCount());
}

test "Arc initWithMutex" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const arc = try ArcMutex(i32).init(allocator, 42);
    defer arc.deinit();

    // Access the value through the mutex
    {
        var guard = arc.lock();
        defer guard.deinit();
        try testing.expectEqual(42, guard.get().*);

        // Modify the value
        guard.get().* = 100;
    }

    // Check the modified value
    {
        var guard = arc.lock();
        defer guard.deinit();
        try testing.expectEqual(100, guard.get().*);
    }

    try testing.expectEqual(1, arc.strongCount());
}

test "Arc toOwned transfers unique value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const arc = try Arc(i32).init(allocator, 42);
    const owned = arc.toOwned() catch |err| {
        arc.deinit();
        return err;
    };
    defer allocator.destroy(owned);

    try testing.expectEqual(42, owned.*);
}

test "Arc toOwned preserves cleanup responsibility" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestType = struct {
        deinit_called: *bool,

        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };

    var deinit_called = false;
    const arc = try Arc(TestType).init(allocator, .{ .deinit_called = &deinit_called });
    const owned = arc.toOwned() catch |err| {
        arc.deinit();
        return err;
    };
    defer allocator.destroy(owned);

    try testing.expect(!deinit_called);

    owned.deinit();
    try testing.expect(deinit_called);
}

test "Arc toOwned fails when shared" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const arc1 = try Arc(i32).init(allocator, 7);
    defer arc1.deinit();

    const arc2 = arc1.clone();
    defer arc2.deinit();

    try testing.expectError(error.NotUnique, arc1.toOwned());
    try testing.expectEqual(2, arc1.strongCount());
}

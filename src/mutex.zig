const std = @import("std");
const Allocator = std.mem.Allocator;

/// Thread-safe mutex-protected pointer.
pub fn Mutex(comptime T: type) type {
    return opaque {
        const Self = @This();

        /// The inner type wrapped by this Mutex
        pub const Child = T;

        const Inner = struct {
            value: T,
            mutex: std.Thread.Mutex,
            allocator: Allocator,
        };

        /// Guard for scoped mutex access
        pub const Guard = struct {
            inner: *Inner,
            value_ptr: *T,

            /// Release the mutex lock
            ///
            /// Must be called when done with the protected value
            pub fn deinit(self: Guard) void {
                self.inner.mutex.unlock();
            }

            /// Get the protected value
            pub fn get(self: Guard) *T {
                return self.value_ptr;
            }

            pub fn getConst(self: Guard) *const T {
                return self.value_ptr;
            }
        };

        /// Create a new Mutex with initial value
        ///
        /// Call `deinit` on the Guard when done with the protected value
        pub fn init(allocator: Allocator, value: T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = value,
                .mutex = .{},
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Lock and get a guard for scoped access
        pub fn lock(self: *Self) Guard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            inner.mutex.lock();
            return Guard{
                .inner = inner,
                .value_ptr = &inner.value,
            };
        }

        /// Try to lock, returns null if already locked
        ///
        /// Difference between `tryLock` and `lock` is that `tryLock` will not block if the mutex is already held by another thread.
        /// But, keep in mind, that if `tryLock` returns null, you did not get the lock and should not access the protected value.
        pub fn tryLock(self: *Self) ?Guard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            if (inner.mutex.tryLock()) {
                return Guard{
                    .inner = inner,
                    .value_ptr = &inner.value,
                };
            }
            return null;
        }

        /// Free the mutex
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));

            // Call deinit if the type has one
            const type_info = @typeInfo(T);
            if ((type_info == .@"struct" or type_info == .@"union" or type_info == .@"enum" or type_info == .@"opaque") and @hasDecl(T, "deinit")) {
                inner.value.deinit();
            }

            const allocator = inner.allocator;
            allocator.destroy(inner);
        }
    };
}

test "Mutex basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const mtx = try Mutex(i32).init(allocator, 42);
    defer mtx.deinit();

    const guard = mtx.lock();
    defer guard.deinit();

    try testing.expectEqual(42, guard.get().*);
    guard.get().* = 100;
    try testing.expectEqual(100, guard.get().*);
}

test "Mutex tryLock" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const mtx = try Mutex(i32).init(allocator, 0);
    defer mtx.deinit();

    const guard1 = mtx.tryLock();
    try testing.expect(guard1 != null);
    defer if (guard1) |g| g.deinit();

    const guard2 = mtx.tryLock();
    try testing.expect(guard2 == null);
}

test "Mutex thread safety" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Counter = struct {
        count: i32 = 0,
    };

    const mtx = try Mutex(Counter).init(allocator, .{});
    defer mtx.deinit();

    const ThreadContext = struct {
        mtx_ptr: *Mutex(Counter),
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: ThreadContext) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var guard = ctx.mtx_ptr.lock();
                defer guard.deinit();
                guard.get().count += 1;
            }
        }
    }.run;

    const thread_count = 4;
    const iterations = 250;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ThreadContext{
            .mtx_ptr = mtx,
            .iterations = iterations,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    const final_guard = mtx.lock();
    defer final_guard.deinit();
    const final_count = final_guard.get().count;

    try testing.expectEqual(thread_count * iterations, final_count);
}

test "Mutex with struct type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Point = struct {
        x: f32,
        y: f32,

        fn distance(self: *@This()) f32 {
            return @sqrt(self.x * self.x + self.y * self.y);
        }
    };

    const mtx = try Mutex(Point).init(allocator, .{ .x = 3.0, .y = 4.0 });
    defer mtx.deinit();

    var dist: f32 = 0.0;
    if (mtx.tryLock()) |g| {
        defer g.deinit();
        g.get().x = 6.0;
        g.get().y = 8.0;
        dist = g.get().distance();
    }

    try testing.expectEqual(10.0, dist);
}
test "Mutex deinit calls inner deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const DeinitType = struct {
        deinit_called: *bool,
        
        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };

    const flag = try allocator.create(bool);
    flag.* = false;
    defer allocator.destroy(flag);

    const mtx = try Mutex(DeinitType).init(allocator, .{ .deinit_called = flag });
    mtx.deinit();

    try testing.expect(flag.*);
}

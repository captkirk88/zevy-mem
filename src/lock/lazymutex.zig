const std = @import("std");
const reflect = @import("zevy_reflect");
const Allocator = std.mem.Allocator;

/// Lazy initialization mutex.
/// The value is initialized only once, on first access, in a thread-safe manner.
///
/// Note: The lifetime of the LazyMutex is tied to the allocator passed to init().
/// The LazyMutex and its contained value become invalid when the allocator is no longer valid.
pub fn LazyMutex(comptime T: type) type {
    return opaque {
        const Self = @This();

        /// The inner type wrapped by this LazyMutex
        pub const Child = T;

        const Inner = struct {
            state: enum { uninit, init },
            value: T,
            mutex: std.Thread.Mutex,
            init_fn: *const fn (Allocator) T,
            allocator: Allocator,

            fn deinit(self: *Inner) void {
                if (self.state == .init) {
                    // Call deinit if the type has one
                    switch (comptime reflect.getReflectInfo(T)) {
                        .type => |ti| {
                            if (ti.hasFunc("deinit")) {
                                self.value.deinit();
                            }
                        },
                        .raw => |ty| {
                            if (reflect.hasFunc(ty, "deinit")) {
                                self.value.deinit();
                            }
                        },
                        else => {},
                    }
                }
            }
        };

        /// Create a new LazyMutex with an initialization function
        ///
        /// The init_fn will be called exactly once, on first access, in a thread-safe manner.
        /// The init_fn receives the allocator that was passed to LazyMutex.init.
        ///
        /// Note: The returned LazyMutex's lifetime is tied to the provided allocator.
        /// It becomes invalid when the allocator is deallocated or goes out of scope.
        pub fn init(allocator: Allocator, init_fn: *const fn (Allocator) T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .state = .uninit,
                .value = undefined,
                .mutex = .{},
                .init_fn = init_fn,
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Get the lazily initialized value
        ///
        /// If this is the first access, the initialization function will be called.
        /// Subsequent calls return the cached value directly.
        pub fn get(self: *Self) *T {
            const inner: *Inner = @ptrCast(@alignCast(self));

            inner.mutex.lock();
            defer inner.mutex.unlock();

            if (inner.state == .uninit) {
                inner.value = inner.init_fn(inner.allocator);
                inner.state = .init;
            }

            return &inner.value;
        }

        /// Get a const pointer to the value (assumes it's initialized)
        ///
        /// Panics if not initialized - use get() first to ensure initialization.
        pub fn getConst(self: *const Self) *const T {
            const inner: *const Inner = @ptrCast(@alignCast(self));
            std.debug.assert(inner.state == .init); // Must be initialized first
            return &inner.value;
        }

        /// Check if the value has been initialized
        pub fn isInitialized(self: *const Self) bool {
            const inner: *const Inner = @ptrCast(@alignCast(self));
            return inner.state == .init;
        }

        /// Force initialization (useful for pre-initializing before concurrent access)
        pub fn initialize(self: *Self) void {
            _ = self.get(); // This will initialize if needed
        }

        /// Free the LazyMutex
        ///
        /// This will call deinit on the inner value if it was initialized and has a deinit method.
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));

            inner.deinit();

            const allocator = inner.allocator;
            allocator.destroy(inner);
        }
    };
}

// Tests
test "LazyMutex basic lazy initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_fn = struct {
        fn init(alloc: Allocator) i32 {
            _ = alloc;
            return 42;
        }
    }.init;

    const lazy = try LazyMutex(i32).init(allocator, init_fn);
    defer lazy.deinit();

    // Not initialized yet
    try testing.expect(!lazy.isInitialized());

    // First access initializes
    const value = lazy.get();
    try testing.expectEqual(42, value.*);
    try testing.expect(lazy.isInitialized());

    // Second access doesn't re-initialize
    const value2 = lazy.get();
    try testing.expectEqual(42, value2.*);
}

test "LazyMutex thread safety" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_fn = struct {
        fn init(alloc: Allocator) i32 {
            _ = alloc;
            // Simulate expensive initialization
            std.Thread.sleep(10 * std.time.ns_per_ms);
            return 100;
        }
    }.init;

    const lazy = try LazyMutex(i32).init(allocator, init_fn);
    defer lazy.deinit();

    const ThreadContext = struct {
        lazy_ptr: *LazyMutex(i32),
        results_ptr: *usize,
        mutex_ptr: *std.Thread.Mutex,
    };

    const worker = struct {
        fn run(ctx: ThreadContext) void {
            const value = ctx.lazy_ptr.get();
            ctx.mutex_ptr.lock();
            ctx.results_ptr.* += @intCast(value.*);
            ctx.mutex_ptr.unlock();
        }
    }.run;

    var results: usize = 0;
    var results_mutex: std.Thread.Mutex = .{};
    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ThreadContext{
            .lazy_ptr = lazy,
            .results_ptr = &results,
            .mutex_ptr = &results_mutex,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    // All threads should get the same value
    try testing.expectEqual(100 * thread_count, results);
}

test "LazyMutex with struct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Point = struct {
        x: f32,
        y: f32,

        fn distance(self: *@This()) f32 {
            return @sqrt(self.x * self.x + self.y * self.y);
        }
    };

    const init_fn = struct {
        fn init(alloc: Allocator) Point {
            _ = alloc;
            return .{ .x = 3.0, .y = 4.0 };
        }
    }.init;

    const lazy = try LazyMutex(Point).init(allocator, init_fn);
    defer lazy.deinit();

    const point = lazy.get();
    try testing.expectEqual(3.0, point.x);
    try testing.expectEqual(4.0, point.y);

    const dist = point.distance();
    try testing.expectEqual(5.0, dist);
}

test "LazyMutex force initialize" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_fn = struct {
        fn init(alloc: Allocator) i32 {
            _ = alloc;
            return 123;
        }
    }.init;

    const lazy = try LazyMutex(i32).init(allocator, init_fn);
    defer lazy.deinit();

    try testing.expect(!lazy.isInitialized());

    lazy.initialize();

    try testing.expect(lazy.isInitialized());

    // Subsequent get doesn't re-init
    const value = lazy.get();
    try testing.expectEqual(123, value.*);
}

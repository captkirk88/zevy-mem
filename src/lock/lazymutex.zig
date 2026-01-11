const Lazy = @import("../lazy.zig").Lazy;
const std = @import("std");
const reflect = @import("zevy_reflect");
const Allocator = std.mem.Allocator;

/// Lazy initialization mutex.
/// The value is initialized only once, on first access, in a thread-safe manner.
///
/// Note: The lifetime of the LazyMutex is tied to the allocator passed to init().
/// The LazyMutex and its contained value become invalid when the allocator is no longer valid.
pub fn LazyMutex(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The inner type wrapped by this LazyMutex
        pub const Child = T;

        lazy: Lazy(T),
        mutex: std.Thread.Mutex,

        /// Create a new LazyMutex with an initialization function
        ///
        /// The init_fn will be called exactly once, on first access, in a thread-safe manner.
        /// The init_fn receives the allocator that was passed to LazyMutex.init.
        ///
        /// Note: The returned LazyMutex's lifetime is tied to the provided allocator.
        /// It becomes invalid when the allocator is deallocated or goes out of scope.
        pub fn init(allocator: std.mem.Allocator, init_fn: *const fn (std.mem.Allocator) T) Self {
            return .{
                .lazy = Lazy(T).init(allocator, init_fn),
                .mutex = .{},
            };
        }

        /// Get the lazily initialized value
        ///
        /// If this is the first access, the initialization function will be called.
        /// Subsequent calls return the cached value directly.
        pub fn get(self: *Self) *T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.lazy.get();
        }

        /// Get a const pointer to the value (assumes it's initialized)
        ///
        /// Panics if not initialized - use get() first to ensure initialization.
        pub fn getConst(self: *const Self) *const T {
            return self.lazy.getConst();
        }

        /// Check if the value has been initialized
        pub fn isInitialized(self: *const Self) bool {
            return self.lazy.isInitialized();
        }

        /// Force initialization (useful for pre-initializing before concurrent access)
        pub fn initialize(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.lazy.initialize();
        }

        /// Free the LazyMutex
        ///
        /// This will call deinit on the inner value if it was initialized and has a deinit method.
        pub fn deinit(self: *Self) void {
            self.lazy.deinit();
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

    var lazy = LazyMutex(i32).init(allocator, init_fn);
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

    var lazy = LazyMutex(i32).init(allocator, init_fn);
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
            .lazy_ptr = &lazy,
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

    var lazy = LazyMutex(Point).init(allocator, init_fn);
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

    var lazy = LazyMutex(i32).init(allocator, init_fn);
    defer lazy.deinit();

    try testing.expect(!lazy.isInitialized());

    lazy.initialize();

    try testing.expect(lazy.isInitialized());

    // Subsequent get doesn't re-init
    const value = lazy.get();
    try testing.expectEqual(123, value.*);
}

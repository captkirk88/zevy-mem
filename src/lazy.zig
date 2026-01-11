const std = @import("std");
const reflect = @import("zevy_reflect");
const Allocator = std.mem.Allocator;

/// Lazy initialization without synchronization.
/// The value is initialized only once, on first access.
///
/// Note: This type is not thread-safe. It should only be used in single-threaded
/// contexts or when external synchronization is provided.
///
/// Note: The lifetime of the Lazy is tied to the allocator passed to init().
/// The Lazy and its contained value become invalid when the allocator is no longer valid.
pub fn Lazy(comptime T: type) type {
    return opaque {
        const Self = @This();

        /// The inner type wrapped by this Lazy
        pub const Child = T;

        const Inner = struct {
            state: enum { uninit, init },
            value: T,
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

        /// Create a new Lazy with an initialization function
        ///
        /// The init_fn will be called exactly once, on first access.
        /// The init_fn receives the allocator that was passed to Lazy.init.
        ///
        /// Note: The returned Lazy's lifetime is tied to the provided allocator.
        /// It becomes invalid when the allocator is deallocated or goes out of scope.
        pub fn init(allocator: Allocator, init_fn: *const fn (Allocator) T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .state = .uninit,
                .value = undefined,
                .init_fn = init_fn,
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Get the lazily initialized value
        ///
        /// If this is the first access, the initialization function will be called.
        /// Subsequent calls return the cached value directly.
        ///
        /// Note: This method is not thread-safe. Ensure single-threaded access
        /// or provide external synchronization.
        pub fn get(self: *Self) *T {
            const inner: *Inner = @ptrCast(@alignCast(self));

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
            if (inner.state == .init) std.debug.panic("Lazy value not initialized", .{});
            return &inner.value;
        }

        /// Check if the value has been initialized
        pub fn isInitialized(self: *const Self) bool {
            const inner: *const Inner = @ptrCast(@alignCast(self));
            return inner.state == .init;
        }

        /// Force initialization (useful for pre-initializing)
        pub fn initialize(self: *Self) void {
            _ = self.get(); // This will initialize if needed
        }

        /// Free the Lazy
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
test "Lazy basic lazy initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_fn = struct {
        fn init(alloc: Allocator) i32 {
            _ = alloc;
            return 42;
        }
    }.init;

    const lazy = try Lazy(i32).init(allocator, init_fn);
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

test "Lazy with struct" {
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

    const lazy = try Lazy(Point).init(allocator, init_fn);
    defer lazy.deinit();

    const point = lazy.get();
    try testing.expectEqual(3.0, point.x);
    try testing.expectEqual(4.0, point.y);

    const dist = point.distance();
    try testing.expectEqual(5.0, dist);
}

test "Lazy force initialize" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_fn = struct {
        fn init(alloc: Allocator) i32 {
            _ = alloc;
            return 123;
        }
    }.init;

    const lazy = try Lazy(i32).init(allocator, init_fn);
    defer lazy.deinit();

    try testing.expect(!lazy.isInitialized());

    lazy.initialize();

    try testing.expect(lazy.isInitialized());

    // Subsequent get doesn't re-init
    const value = lazy.get();
    try testing.expectEqual(123, value.*);
}

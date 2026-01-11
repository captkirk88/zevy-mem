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
    return struct {
        const Self = @This();

        /// The inner type wrapped by this Lazy
        pub const Child = T;

        allocator: std.mem.Allocator,
        init_fn: *const fn (std.mem.Allocator) T,
        inner: ?*Inner,

        const Inner = opaque {
            const InnerStruct = struct {
                state: enum { uninit, init },
                value: T,
                init_fn: *const fn (std.mem.Allocator) T,
                allocator: std.mem.Allocator,

                fn deinit(self: *InnerStruct) void {
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
        };

        /// Create a new Lazy with an initialization function
        ///
        /// The init_fn will be called exactly once, on first access.
        /// The init_fn receives the allocator that was passed to Lazy.init.
        ///
        /// Note: The returned Lazy's lifetime is tied to the provided allocator.
        /// It becomes invalid when the allocator is deallocated or goes out of scope.
        pub fn init(allocator: std.mem.Allocator, init_fn: *const fn (std.mem.Allocator) T) Self {
            return .{
                .allocator = allocator,
                .init_fn = init_fn,
                .inner = null,
            };
        }

        /// Get the lazily initialized value
        ///
        /// If this is the first access, the initialization function will be called.
        /// Subsequent calls return the cached value directly.
        ///
        /// Note: This method is not thread-safe. Ensure single-threaded access
        /// or provide external synchronization.
        pub fn get(self: *Self) *T {
            if (self.inner == null) {
                const ptr = self.allocator.create(Inner.InnerStruct) catch |err| std.debug.panic("Failed to allocate Lazy: {s}", .{@errorName(err)});
                ptr.* = .{
                    .state = .uninit,
                    .value = undefined,
                    .init_fn = self.init_fn,
                    .allocator = self.allocator,
                };
                self.inner = @ptrCast(ptr);
            }

            const inner_struct: *Inner.InnerStruct = @ptrCast(@alignCast(self.inner.?));

            if (inner_struct.state == .uninit) {
                inner_struct.value = inner_struct.init_fn(inner_struct.allocator);
                inner_struct.state = .init;
            }

            return &inner_struct.value;
        }

        /// Get a const pointer to the value (assumes it's initialized)
        ///
        /// Panics if not initialized - use get() first to ensure initialization.
        pub fn getConst(self: *const Self) *const T {
            const inner_struct: *const Inner.InnerStruct = @ptrCast(@alignCast(self.inner orelse std.debug.panic("Lazy value not initialized", .{})));
            if (inner_struct.state != .init) std.debug.panic("Lazy value not initialized", .{});
            return &inner_struct.value;
        }

        /// Check if the value has been initialized
        pub fn isInitialized(self: *const Self) bool {
            return if (self.inner) |inner| blk: {
                const inner_struct: *const Inner.InnerStruct = @ptrCast(@alignCast(inner));
                break :blk inner_struct.state == .init;
            } else false;
        }

        /// Force initialization (useful for pre-initializing)
        pub fn initialize(self: *Self) void {
            _ = self.get(); // This will initialize if needed
        }

        /// Free the Lazy
        ///
        /// This will call deinit on the inner value if it was initialized and has a deinit method.
        pub fn deinit(self: *Self) void {
            if (self.inner) |inner| {
                const inner_struct: *Inner.InnerStruct = @ptrCast(@alignCast(inner));
                inner_struct.deinit();
                self.allocator.destroy(@as(*Inner.InnerStruct, @ptrCast(@alignCast(inner))));
            }
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

    var lazy = Lazy(i32).init(allocator, init_fn);
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

    var lazy = Lazy(Point).init(allocator, init_fn);
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

    var lazy = Lazy(i32).init(allocator, init_fn);
    defer lazy.deinit();

    try testing.expect(!lazy.isInitialized());

    lazy.initialize();

    try testing.expect(lazy.isInitialized());

    // Subsequent get doesn't re-init
    const value = lazy.get();
    try testing.expectEqual(123, value.*);
}

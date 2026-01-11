const std = @import("std");
const reflect = @import("zevy_reflect");
const Allocator = std.mem.Allocator;

/// Pin prevents moving a value out of its memory location after initialization.
/// This is useful for self-referential structures or data that must maintain a stable address.
/// Unlike Rust, Zig doesn't have built-in move semantics, but Pin provides a safety mechanism
/// to ensure values aren't accidentally relocated while pointers to them exist.
pub fn Pin(comptime T: type) type {
    return opaque {
        const Self = @This();

        /// The inner type wrapped by this Pin
        pub const Child = T;

        const Inner = struct {
            value: T,
            allocator: Allocator,

            fn deinit(self: *Inner) void {
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
        };

        /// Create a new pinned value with initial value
        ///
        /// The value is allocated and its address becomes stable.
        /// Call `deinit` when done to free the memory.
        pub fn init(allocator: Allocator, value: T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = value,
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Get a pointer to the pinned value
        ///
        /// This ensures the value can only be accessed through its stable address.
        pub fn get(self: *Self) *T {
            const inner: *Inner = @ptrCast(@alignCast(self));
            return &inner.value;
        }

        /// Get a const pointer to the pinned value
        pub fn getConst(self: *const Self) *const T {
            const inner: *const Inner = @ptrCast(@alignCast(self));
            return &inner.value;
        }

        /// Free the pinned value
        ///
        /// This will call deinit on the inner value if it has one.
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));

            inner.deinit();

            const allocator = inner.allocator;
            allocator.destroy(inner);
        }
    };
}

// Tests
test "Pin basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const pin = try Pin(i32).init(allocator, 42);
    defer pin.deinit();

    try testing.expectEqual(42, pin.get().*);

    pin.get().* = 100;
    try testing.expectEqual(100, pin.get().*);

    try testing.expectEqual(100, pin.getConst().*);
}

test "Pin with struct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Point = struct {
        x: f32,
        y: f32,

        pub fn distance(self: *@This()) f32 {
            return @sqrt(self.x * self.x + self.y * self.y);
        }
    };

    const pin = try Pin(Point).init(allocator, .{ .x = 3.0, .y = 4.0 });
    defer pin.deinit();

    try testing.expectEqual(3.0, pin.get().x);
    try testing.expectEqual(4.0, pin.get().y);

    const dist = pin.get().distance();
    try testing.expectEqual(5.0, dist);
}

test "Pin deinit calls inner deinit" {
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

    const pin = try Pin(DeinitType).init(allocator, .{ .deinit_called = flag });
    pin.deinit();

    try testing.expect(flag.*);
}

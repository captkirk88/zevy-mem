const std = @import("std");
const reflect = @import("zevy_reflect");
const Allocator = std.mem.Allocator;

/// Reference counted pointer (non-atomic, single-threaded).
pub fn Rc(comptime T: type) type {
    return opaque {
        const Self = @This();

        /// The inner type wrapped by this Rc
        pub const Child = T;

        const Inner = struct {
            value: T,
            ref_count: usize,
            allocator: Allocator,

            fn deinit(self: *Inner) void {
                // Call deinit if the type has one
                switch (comptime reflect.getReflectInfo(T)) {
                    .type => |ti| {
                        if (ti.hasFunc("deinit")) {
                            if (reflect.hasFuncWithArgs(T, "deinit", &[_]type{Allocator})) {
                                self.value.deinit(self.allocator);
                            } else {
                                self.value.deinit();
                            }
                        }
                    },
                    .raw => |ty| {
                        if (reflect.hasFunc(ty, "deinit")) {
                            if (reflect.hasFuncWithArgs(T, "deinit", &[_]type{Allocator})) {
                                self.value.deinit(self.allocator);
                            } else {
                                self.value.deinit();
                            }
                        }
                    },
                    else => {},
                }
            }
        };

        /// Create a new Rc with initial value
        pub fn init(allocator: Allocator, value: T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = value,
                .ref_count = 1,
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Clone the Rc, incrementing the reference count
        pub fn clone(self: *Self) *Self {
            const inner: *Inner = @ptrCast(@alignCast(self));
            inner.ref_count += 1;
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
            return inner.ref_count;
        }

        /// Decrement reference count and free if it reaches zero
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));
            inner.ref_count -= 1;
            if (inner.ref_count == 0) {
                inner.deinit();

                const allocator = inner.allocator;
                allocator.destroy(inner);
            }
        }

        /// Create a new Rc from an existing value pointer (takes ownership)
        pub fn fromOwned(allocator: Allocator, value_ptr: *T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = value_ptr.*,
                .ref_count = 1,
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }
    };
}

test "Rc basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rc = try Rc(i32).init(allocator, 42);
    defer rc.deinit();

    try testing.expectEqual(42, rc.get().*);
    try testing.expectEqual(1, rc.strongCount());
}

test "Rc clone and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rc1 = try Rc(i32).init(allocator, 100);
    defer rc1.deinit();

    const rc2 = rc1.clone();
    defer rc2.deinit();

    try testing.expectEqual(2, rc1.strongCount());
    try testing.expectEqual(2, rc2.strongCount());
    try testing.expectEqual(100, rc1.get().*);
    try testing.expectEqual(100, rc2.get().*);
}

test "Rc with struct type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Point = struct {
        x: f32,
        y: f32,
    };

    const rc = try Rc(Point).init(allocator, .{ .x = 1.0, .y = 2.0 });
    defer rc.deinit();

    try testing.expectEqual(1.0, rc.get().x);
    try testing.expectEqual(2.0, rc.get().y);

    rc.get().x = 3.0;
    try testing.expectEqual(3.0, rc.get().x);
}

test "Rc memory cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rc1 = try Rc(i32).init(allocator, 999);
    const rc2 = rc1.clone();
    const rc3 = rc1.clone();

    try testing.expectEqual(3, rc1.strongCount());

    rc1.deinit();
    try testing.expectEqual(2, rc2.strongCount());

    rc2.deinit();
    try testing.expectEqual(1, rc3.strongCount());

    rc3.deinit();
    // Memory should be freed at this point
}

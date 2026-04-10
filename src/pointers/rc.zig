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
                // Only call deinit if the type structurally requires cleanup
                @import("../lock/mutex.zig").cleanup(T, &self.value, self.allocator);
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

        /// Transfer the contained value into a newly allocated owned pointer.
        ///
        /// Fails with `error.NotUnique` if this Rc has more than one strong reference.
        /// The returned pointer is allocated with the same allocator used to create the Rc.
        /// The caller becomes responsible for calling `deinit` on the value when needed and
        /// destroying the returned pointer with that allocator.
        pub fn toOwned(self: *Self) !*T {
            const inner: *Inner = @ptrCast(@alignCast(self));
            if (inner.ref_count != 1) return error.NotUnique;

            const allocator = inner.allocator;
            const owned = try allocator.create(T);
            owned.* = inner.value;
            allocator.destroy(inner);
            return owned;
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

test "Rc toOwned transfers unique value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rc = try Rc(i32).init(allocator, 42);
    const owned = rc.toOwned() catch |err| {
        rc.deinit();
        return err;
    };
    defer allocator.destroy(owned);

    try testing.expectEqual(42, owned.*);
}

test "Rc toOwned preserves cleanup responsibility" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestType = struct {
        deinit_called: *bool,

        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };

    var deinit_called = false;
    const rc = try Rc(TestType).init(allocator, .{ .deinit_called = &deinit_called });
    const owned = rc.toOwned() catch |err| {
        rc.deinit();
        return err;
    };
    defer allocator.destroy(owned);

    try testing.expect(!deinit_called);

    owned.deinit();
    try testing.expect(deinit_called);
}

test "Rc toOwned fails when shared" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rc1 = try Rc(i32).init(allocator, 7);
    defer rc1.deinit();

    const rc2 = rc1.clone();
    defer rc2.deinit();

    try testing.expectError(error.NotUnique, rc1.toOwned());
    try testing.expectEqual(2, rc1.strongCount());
}

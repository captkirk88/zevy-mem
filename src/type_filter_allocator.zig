const std = @import("std");
const Allocator = std.mem.Allocator;

/// TypeFilterAllocator dispatches allocations based on the type.
/// If the type is in the specified array of types, it uses the specific allocator.
/// Otherwise, it uses the fallback allocator.
///
/// This is useful for scenarios such as:
/// - Using a fast allocator for frequently used types, and a general-purpose allocator for others.
/// - Using a debug allocator for certain types to track memory usage.
/// - Big structs with lots of data can use a different allocator than small structs.
pub fn TypeFilterAllocator(comptime types: []const type) type {
    return struct {
        const Self = @This();
        specific_allocator: Allocator,
        fallback_allocator: Allocator,

        pub fn init(specific: Allocator, fallback: Allocator) Self {
            return .{
                .specific_allocator = specific,
                .fallback_allocator = fallback,
            };
        }

        /// Allocate for a specific type, choosing the allocator based on whether the type is in the filter.
        pub fn allocForType(self: *Self, comptime T: type, len: usize) Allocator.Error![]T {
            const chosen_allocator = if (comptime isTypeInList(T, types)) self.specific_allocator else self.fallback_allocator;
            return chosen_allocator.alloc(T, len);
        }

        /// Free for a specific type.
        pub fn freeForType(self: *Self, comptime T: type, slice: []T) void {
            const chosen_allocator = if (comptime isTypeInList(T, types)) self.specific_allocator else self.fallback_allocator;
            chosen_allocator.free(slice);
        }

        /// Resize for a specific type.
        pub fn resizeForType(self: *Self, comptime T: type, slice: []T, new_len: usize) ?[]T {
            const chosen_allocator = if (comptime isTypeInList(T, types)) self.specific_allocator else self.fallback_allocator;
            return chosen_allocator.resize(slice, new_len);
        }

        /// Get a standard Allocator for a specific type.
        pub fn allocator(self: *Self, comptime T: type) Allocator {
            const chosen_allocator = if (comptime isTypeInList(T, types)) self.specific_allocator else self.fallback_allocator;
            return chosen_allocator;
        }

        fn isTypeInList(comptime T: type, comptime list: []const type) bool {
            for (list) |Type| {
                if (T == Type) return true;
            }
            return false;
        }
    };
}

test "TypeFilterAllocator basic usage" {
    const allocator = std.testing.allocator;
    var filter = TypeFilterAllocator(&[_]type{ i32, f64 }).init(allocator, allocator);

    // i32 should use specific (same as fallback in this test)
    const arr_i32 = try filter.allocForType(i32, 10);
    try std.testing.expect(arr_i32.len == 10);
    filter.freeForType(i32, arr_i32);

    // u8 not in list, uses fallback
    const arr_u8 = try filter.allocForType(u8, 5);
    try std.testing.expect(arr_u8.len == 5);
    filter.freeForType(u8, arr_u8);

    // Test allocator(T)
    const i32_allocator = filter.allocator(i32);
    const arr2 = try i32_allocator.alloc(i32, 3);
    try std.testing.expect(arr2.len == 3);
    i32_allocator.free(arr2);
}

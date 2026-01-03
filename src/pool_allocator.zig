const std = @import("std");

/// A fixed-size pool allocator for objects of uniform size.
/// Provides O(1) allocation and deallocation with no fragmentation.
pub fn PoolAllocator(comptime T: type) type {
    // Ensure slot size is at least pointer-sized for the free list
    const slot_size = @max(@sizeOf(T), @sizeOf(?*anyopaque));
    const slot_align = @max(@alignOf(T), @alignOf(?*anyopaque));

    return struct {
        const Self = @This();

        /// A single slot in the pool.
        pub const Slot = struct {
            data: [slot_size]u8 align(slot_align),

            fn asValue(self: *Slot) *T {
                return @ptrCast(@alignCast(&self.data));
            }

            fn getNextFree(self: *Slot) ?*Slot {
                const ptr: *?*Slot = @ptrCast(@alignCast(&self.data));
                return ptr.*;
            }

            fn setNextFree(self: *Slot, next: ?*Slot) void {
                const ptr: *?*Slot = @ptrCast(@alignCast(&self.data));
                ptr.* = next;
            }
        };

        buffer: []Slot,
        free_list: ?*Slot,
        allocated_count: usize,

        /// Initialize with a given number of slots
        pub fn init(comptime slot_count: usize) Self {
            var buffer: [slot_count]PoolAllocator(T).Slot = undefined;
            var self = Self{
                .buffer = buffer[0..slot_count],
                .free_list = null,
                .allocated_count = 0,
            };

            // Build free list
            if (slot_count > 0) {
                for (0..slot_count - 1) |i| {
                    self.buffer[i].setNextFree(&self.buffer[i + 1]);
                }
                self.buffer[slot_count - 1].setNextFree(null);
                self.free_list = &self.buffer[0];
            }

            return self;
        }
        /// Initialize with an external buffer (no heap allocations).
        pub fn initBuffer(buffer: []Slot) Self {
            var self = Self{
                .buffer = buffer,
                .free_list = null,
                .allocated_count = 0,
            };

            // Build free list
            if (buffer.len > 0) {
                for (0..buffer.len - 1) |i| {
                    buffer[i].setNextFree(&buffer[i + 1]);
                }
                buffer[buffer.len - 1].setNextFree(null);
                self.free_list = &buffer[0];
            }

            return self;
        }

        /// Allocate a slot, returning a pointer to the value.
        pub fn alloc(self: *Self) ?*T {
            const slot = self.free_list orelse return null;
            self.free_list = slot.getNextFree();
            self.allocated_count += 1;
            return slot.asValue();
        }

        /// Allocate and initialize with a value.
        pub fn create(self: *Self, value: T) ?*T {
            const ptr = self.alloc() orelse return null;
            ptr.* = value;
            return ptr;
        }

        /// Free a previously allocated slot.
        pub fn free(self: *Self, ptr: *T) void {
            // Calculate slot from value pointer
            const ptr_addr = @intFromPtr(ptr);
            const buffer_start = @intFromPtr(self.buffer.ptr);

            if (ptr_addr < buffer_start) return;

            const offset = ptr_addr - buffer_start;
            const slot_stride = @sizeOf(Slot);

            if (slot_stride > 0 and offset % slot_stride != 0) return;

            const index = if (slot_stride > 0) offset / slot_stride else 0;
            if (index >= self.buffer.len) return;

            const slot = &self.buffer[index];
            slot.setNextFree(self.free_list);
            self.free_list = slot;
            self.allocated_count -= 1;
        }

        /// Returns the number of currently allocated slots.
        pub fn count(self: *const Self) usize {
            return self.allocated_count;
        }

        /// Returns the total capacity.
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        /// Returns the number of available slots.
        pub fn available(self: *const Self) usize {
            return self.buffer.len - self.allocated_count;
        }

        /// Check if a pointer is currently allocated by this allocator.
        pub fn isAllocated(self: *const Self, ptr: *const anyopaque) bool {
            const ptr_addr = @intFromPtr(ptr);
            const buffer_start = @intFromPtr(self.buffer.ptr);

            if (ptr_addr < buffer_start) return false;

            const offset = ptr_addr - buffer_start;
            const slot_stride = @sizeOf(Slot);

            if (slot_stride > 0 and offset % slot_stride != 0) return false;

            const index = if (slot_stride > 0) offset / slot_stride else 0;
            if (index >= self.buffer.len) return false;

            // Check if the slot is in the free list
            var current = self.free_list;
            while (current) |slot| {
                const slot_index = (@intFromPtr(slot) - @intFromPtr(self.buffer.ptr)) / @sizeOf(Slot);
                if (slot_index == index) return false;
                current = slot.getNextFree();
            }
            return true;
        }

        /// Reset the pool, freeing all allocations.
        pub fn reset(self: *Self) void {
            if (self.buffer.len > 0) {
                for (0..self.buffer.len - 1) |i| {
                    self.buffer[i].setNextFree(&self.buffer[i + 1]);
                }
                self.buffer[self.buffer.len - 1].setNextFree(null);
                self.free_list = &self.buffer[0];
            }
            self.allocated_count = 0;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const TestStruct = struct {
    x: i32,
    y: i32,
    name: [16]u8,
};

test "basic pool allocation" {
    var buffer: [10]PoolAllocator(TestStruct).Slot = undefined;
    var pool = PoolAllocator(TestStruct).initBuffer(&buffer);

    try std.testing.expectEqual(@as(usize, 10), pool.capacity());
    try std.testing.expectEqual(@as(usize, 0), pool.count());

    const item1 = pool.alloc();
    try std.testing.expect(item1 != null);
    try std.testing.expectEqual(@as(usize, 1), pool.count());

    const item2 = pool.create(.{ .x = 10, .y = 20, .name = undefined });
    try std.testing.expect(item2 != null);
    try std.testing.expectEqual(@as(i32, 10), item2.?.x);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "pool exhaustion" {
    var buffer: [2]PoolAllocator(u32).Slot = undefined;
    var pool = PoolAllocator(u32).initBuffer(&buffer);

    _ = pool.alloc();
    _ = pool.alloc();

    const exhausted = pool.alloc();
    try std.testing.expect(exhausted == null);
}

test "pool free and reuse" {
    var buffer: [2]PoolAllocator(u32).Slot = undefined;
    var pool = PoolAllocator(u32).initBuffer(&buffer);

    const a = pool.create(42).?;
    const b = pool.create(99).?;

    try std.testing.expectEqual(@as(usize, 0), pool.available());

    pool.free(a);
    try std.testing.expectEqual(@as(usize, 1), pool.available());

    const c = pool.create(123).?;
    try std.testing.expectEqual(@as(u32, 123), c.*);
    try std.testing.expectEqual(@as(usize, 0), pool.available());

    // b should still be valid
    try std.testing.expectEqual(@as(u32, 99), b.*);
}

test "pool reset" {
    var buffer: [5]PoolAllocator(i32).Slot = undefined;
    var pool = PoolAllocator(i32).initBuffer(&buffer);

    _ = pool.alloc();
    _ = pool.alloc();
    _ = pool.alloc();

    try std.testing.expectEqual(@as(usize, 3), pool.count());

    pool.reset();

    try std.testing.expectEqual(@as(usize, 0), pool.count());
    try std.testing.expectEqual(@as(usize, 5), pool.available());
}

test "pool init with zero slots" {
    var pool = PoolAllocator(u8).init(0);

    try std.testing.expectEqual(@as(usize, 0), pool.capacity());
    try std.testing.expectEqual(@as(usize, 0), pool.count());

    const result = pool.alloc();
    try std.testing.expect(result == null);
}

test "pool init with size" {
    var pool = PoolAllocator(u8).init(3);

    try std.testing.expectEqual(@as(usize, 3), pool.capacity());
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    _ = pool.alloc();
    try std.testing.expectEqual(@as(usize, 1), pool.count());
}

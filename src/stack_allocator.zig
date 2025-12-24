const std = @import("std");
const Allocator = std.mem.Allocator;

/// A stack-based allocator that uses a fixed buffer (no heap allocations).
pub const StackAllocator = struct {
    /// Allocated buffer
    buffer: ?[]u8,
    /// Index of the end of used memory in the buffer
    end_index: usize,

    /// Initialize with no buffer. Must call `setBuffer` or `growBuffer` before allocating.
    pub fn init(comptime size: usize) StackAllocator {
        var buffer: [size]u8 = undefined;
        return .{
            .buffer = buffer[0..size],
            .end_index = 0,
        };
    }

    /// Initialize with a pre-supplied buffer.
    pub fn initBuffer(buffer: []u8) StackAllocator {
        return .{
            .buffer = buffer,
            .end_index = 0,
        };
    }

    /// Set or replace the buffer. Copies existing data if growing.
    /// New buffer must be at least as large as current `end_index`.
    pub fn growBuffer(self: *StackAllocator, new_buffer: []u8) error{BufferTooSmall}!void {
        if (new_buffer.len < self.end_index) {
            return error.BufferTooSmall;
        }

        if (self.buffer) |old_buffer| {
            if (self.end_index > 0) {
                @memcpy(new_buffer[0..self.end_index], old_buffer[0..self.end_index]);
            }
        }

        self.buffer = new_buffer;
    }

    /// Set a new buffer, resetting the allocator state.
    pub fn setBuffer(self: *StackAllocator, buffer: []u8) void {
        self.buffer = buffer;
        self.end_index = 0;
    }

    pub fn allocator(self: *StackAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Reset the allocator, invalidating all previous allocations.
    pub fn reset(self: *StackAllocator) void {
        self.end_index = 0;
    }

    /// Rewind the allocator to a previous index.
    pub fn rewind(self: *StackAllocator, bytes: usize) usize {
        if (bytes > self.end_index) {
            const rewound = self.end_index;
            self.end_index = 0;
            return rewound;
        } else {
            self.end_index = self.end_index - bytes;
            return bytes;
        }
    }

    /// Returns the number of bytes currently allocated.
    pub fn bytesUsed(self: *const StackAllocator) usize {
        return self.end_index;
    }

    /// Returns the number of bytes remaining.
    pub fn bytesRemaining(self: *const StackAllocator) usize {
        const buf = self.buffer orelse return 0;
        return buf.len - self.end_index;
    }

    /// Returns the total buffer capacity.
    pub fn capacity(self: *const StackAllocator) usize {
        const buf = self.buffer orelse return 0;
        return buf.len;
    }
};

pub fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, _: usize) ?[*]u8 {
    const self: *StackAllocator = @ptrCast(@alignCast(ctx));
    const buf = self.buffer orelse return null;

    const aligned_index = ptr_align.forward(self.end_index);
    const new_end = aligned_index + len;

    if (new_end > buf.len) {
        return null; // Out of memory
    }

    self.end_index = new_end;
    return buf.ptr + aligned_index;
}

pub fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, _: usize) bool {
    const self: *StackAllocator = @ptrCast(@alignCast(ctx));
    const backing = self.buffer orelse return false;

    const buf_start = @intFromPtr(buf.ptr) - @intFromPtr(backing.ptr);
    const buf_end = buf_start + buf.len;

    // Can only resize the most recent allocation
    if (buf_end != self.end_index) {
        return false;
    }

    if (new_len > buf.len) {
        // Growing
        const new_end = buf_start + new_len;
        if (new_end > backing.len) {
            return false;
        }
        self.end_index = new_end;
    } else {
        // Shrinking
        self.end_index = buf_start + new_len;
    }

    _ = buf_align;
    return true;
}

/// Stack allocator cannot remap memory to a different location
pub fn remap(
    _: *anyopaque,
    _: []u8,
    _: std.mem.Alignment,
    _: usize,
    _: usize,
) ?[*]u8 {
    return null;
}

pub fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, _: usize) void {
    const self: *StackAllocator = @ptrCast(@alignCast(ctx));
    const backing = self.buffer orelse return;

    const buf_start = @intFromPtr(buf.ptr) - @intFromPtr(backing.ptr);
    const buf_end = buf_start + buf.len;

    // Can only free the most recent allocation (LIFO)
    if (buf_end == self.end_index) {
        self.end_index = buf_start;
    }
    // Otherwise, the memory is leaked (expected behavior for stack allocator)

    _ = buf_align;
}
// ============================================================================
// Tests
// ============================================================================

test "init without buffer" {
    var stack = StackAllocator.init(0);
    try std.testing.expectEqual(@as(usize, 0), stack.capacity());
    try std.testing.expectEqual(@as(usize, 0), stack.bytesRemaining());

    // Allocation should fail without buffer
    const alloca = stack.allocator();
    const result = alloca.alloc(u8, 10);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "setBuffer" {
    var stack = StackAllocator.init(0);
    var buffer: [1024]u8 = undefined;

    stack.setBuffer(&buffer);
    try std.testing.expectEqual(@as(usize, 1024), stack.capacity());

    const alloca = stack.allocator();
    const slice = try alloca.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), slice.len);
}

test "growBuffer" {
    var small_buffer: [100]u8 = undefined;
    var large_buffer: [500]u8 = undefined;

    var stack = StackAllocator.initBuffer(&small_buffer);
    const alloca = stack.allocator();

    // Allocate some data
    const slice = try alloca.alloc(u8, 50);
    @memset(slice, 0xAB);

    // Grow buffer
    try stack.growBuffer(&large_buffer);
    try std.testing.expectEqual(@as(usize, 500), stack.capacity());
    try std.testing.expectEqual(@as(usize, 50), stack.bytesUsed());

    // Verify data was copied
    try std.testing.expectEqual(@as(u8, 0xAB), large_buffer[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), large_buffer[49]);
}

test "growBuffer too small" {
    var buffer: [100]u8 = undefined;
    var small_buffer: [30]u8 = undefined;

    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    _ = try alloca.alloc(u8, 50);

    // Try to grow to smaller buffer
    const result = stack.growBuffer(&small_buffer);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "basic allocation" {
    var buffer: [1024]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    const slice = try alloca.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), slice.len);
    try std.testing.expectEqual(@as(usize, 100), stack.bytesUsed());
}

test "multiple allocations" {
    var buffer: [1024]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    const a = try alloca.alloc(u8, 50);
    const b = try alloca.alloc(u8, 50);
    const c = try alloca.alloc(u8, 50);

    try std.testing.expectEqual(@as(usize, 50), a.len);
    try std.testing.expectEqual(@as(usize, 50), b.len);
    try std.testing.expectEqual(@as(usize, 50), c.len);

    // Pointers should be different
    try std.testing.expect(a.ptr != b.ptr);
    try std.testing.expect(b.ptr != c.ptr);
}

test "LIFO free" {
    var buffer: [1024]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    const a = try alloca.alloc(u8, 100);
    const used_after_a = stack.bytesUsed();

    const b = try alloca.alloc(u8, 100);

    // Free b (LIFO - should work)
    alloca.free(b);
    try std.testing.expectEqual(used_after_a, stack.bytesUsed());

    // Free a (now it's the top)
    alloca.free(a);
    try std.testing.expectEqual(@as(usize, 0), stack.bytesUsed());
}

test "out of memory" {
    var buffer: [100]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    const result = alloca.alloc(u8, 200);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "reset" {
    var buffer: [1024]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    _ = try alloca.alloc(u8, 500);
    try std.testing.expectEqual(@as(usize, 500), stack.bytesUsed());

    stack.reset();
    try std.testing.expectEqual(@as(usize, 0), stack.bytesUsed());
    try std.testing.expectEqual(@as(usize, 1024), stack.bytesRemaining());
}

test "alignment" {
    var buffer: [1024]u8 align(16) = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    _ = try alloca.alloc(u8, 1); // 1 byte, may not be aligned

    const aligned = try alloca.alloc(u64, 1); // Should be 8-byte aligned
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % @alignOf(u64));
}

test "resize grow" {
    var buffer: [1024]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    var slice = try alloca.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 50), slice.len);

    // Resize to larger
    const resized = alloca.resize(slice, 100);
    try std.testing.expect(resized);
    slice.len = 100;
    try std.testing.expectEqual(@as(usize, 100), stack.bytesUsed());
}

test "resize shrink" {
    var buffer: [1024]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    const alloca = stack.allocator();

    const slice = try alloca.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), slice.len);

    // Resize to smaller
    const resized = alloca.resize(slice, 50);
    try std.testing.expect(resized);
    try std.testing.expectEqual(@as(usize, 50), stack.bytesUsed());
}

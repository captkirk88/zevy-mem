const std = @import("std");
const TrackingAllocator = @import("interface.zig").TrackingAllocator;
/// Simple counting allocator for tracking allocations and memory usage
pub const CountingAllocator = struct {
    inner_allocator: std.mem.Allocator,
    bytes_allocated: usize,
    allocs_count: usize,

    /// Get the underlying allocator interface.
    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    pub fn init(base_allocator: std.mem.Allocator) CountingAllocator {
        return CountingAllocator{
            .inner_allocator = base_allocator,
            .bytes_allocated = 0,
            .allocs_count = 0,
        };
    }

    pub fn bytesUsed(self: *CountingAllocator) usize {
        return self.bytes_allocated;
    }

    pub fn reset(self: *CountingAllocator) void {
        self.bytes_allocated = 0;
        self.allocs_count = 0;
    }
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    const result = self.inner_allocator.rawAlloc(len, alignment, ret_addr);
    if (result) |_| {
        self.bytes_allocated += len;
        self.allocs_count += 1;
    }
    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    const old_len = buf.len;
    const ok = self.inner_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    if (ok and new_len > old_len) {
        self.bytes_allocated += (new_len - old_len);
        self.allocs_count += 1;
    }
    return ok;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    self.inner_allocator.rawFree(buf, buf_align, ret_addr);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    // Delegate to inner allocator's remap
    return self.inner_allocator.rawRemap(memory, alignment, new_len, ret_addr);
}

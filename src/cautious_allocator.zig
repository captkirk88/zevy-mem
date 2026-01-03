const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = @import("utils/root.zig");

/// CautiousAllocator
/// A wrapper around any `std.mem.Allocator` that tracks current bytes used
/// and enforces a soft and hard limit. The allocator will refuse allocations
/// that would exceed the hard limit. When the soft limit is crossed it will
/// optionally abort allocations (controlled via `abort_on_soft`) and will
/// invoke the warnFn the first time the soft limit is approached.
pub const CautiousAllocator = struct {
    inner: Allocator,
    soft_limit: usize,
    hard_limit: usize,
    bytes_used: usize,
    abort_on_soft: bool,
    warned: bool,
    warnFn: *const fn (projected: usize, hard_limit: usize) void,

    /// Initialize a CautiousAllocator
    ///
    /// - `backing`: The underlying allocator to wrap
    /// - `soft_limit`: The soft limit in bytes
    /// - `hard_limit`: The hard limit in bytes
    /// - `abort_on_soft`: If true, allocations that exceed the soft limit will be aborted
    /// - `warnFn`: Function to call when soft limit is first exceeded, takes projected bytes and hard limit
    pub fn init(backing: Allocator, soft_limit: usize, hard_limit: usize, abort_on_soft: bool, warnFn: *const fn (projected: usize, hard_limit: usize) void) CautiousAllocator {
        return CautiousAllocator{
            .inner = backing,
            .soft_limit = soft_limit,
            .hard_limit = hard_limit,
            .bytes_used = 0,
            .abort_on_soft = abort_on_soft,
            .warned = false,
            .warnFn = warnFn,
        };
    }

    pub fn allocator(self: *CautiousAllocator) Allocator {
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

    pub fn bytesUsed(self: *CautiousAllocator) usize {
        return self.bytes_used;
    }

    pub fn getLimits(self: *CautiousAllocator) struct { soft: usize, hard: usize } {
        return .{ .soft = self.soft_limit, .hard = self.hard_limit };
    }

    fn willAllow(self: *CautiousAllocator, additional: usize) bool {
        // check hard limit first
        const projected = self.bytes_used + additional;
        if (projected > self.hard_limit) return false;

        if (projected > self.soft_limit) {
            if (!self.warned) {
                self.warnFn(projected, self.hard_limit);
                self.warned = true;
            }
            if (self.abort_on_soft) return false;
        }

        return true;
    }
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *CautiousAllocator = @ptrCast(@alignCast(ctx));

    if (!self.willAllow(len)) return null;

    const result = self.inner.rawAlloc(len, alignment, ret_addr);
    if (result) |_| {
        self.bytes_used += len;
    }
    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *CautiousAllocator = @ptrCast(@alignCast(ctx));

    const old_len = buf.len;
    if (new_len > old_len) {
        const extra = new_len - old_len;
        if (!self.willAllow(extra)) return false;
    }

    const ok = self.inner.rawResize(buf, buf_align, new_len, ret_addr);
    if (ok) {
        if (new_len > old_len) {
            self.bytes_used += (new_len - old_len);
        } else if (old_len > new_len) {
            const dec = old_len - new_len;
            if (dec > self.bytes_used) {
                self.bytes_used = 0;
            } else {
                self.bytes_used -= dec;
            }
        }
    }
    return ok;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *CautiousAllocator = @ptrCast(@alignCast(ctx));

    const old_len = memory.len;
    if (new_len > old_len) {
        const extra = new_len - old_len;
        if (!self.willAllow(extra)) return null;
    }

    const result = self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    if (result) |_| {
        if (new_len > old_len) {
            self.bytes_used += (new_len - old_len);
        } else if (old_len > new_len) {
            const dec = old_len - new_len;
            if (dec > self.bytes_used) {
                self.bytes_used = 0;
            } else {
                self.bytes_used -= dec;
            }
        }
    }
    return result;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    const self: *CautiousAllocator = @ptrCast(@alignCast(ctx));

    // adjust accounting first (ensure we don't underflow)
    if (buf.len > self.bytes_used) {
        self.bytes_used = 0;
    } else {
        self.bytes_used -= buf.len;
    }

    self.inner.rawFree(buf, buf_align, ret_addr);
}

test "CautiousAllocator enforces limits" {
    const backing_allocator = std.testing.allocator;
    var cautious = CautiousAllocator.init(backing_allocator, 1024, 2048, false, struct {
        fn warn(_: usize, _: usize) void {}
    }.warn);
    const allocator = cautious.allocator();

    // Allocate within soft limit
    const buf1 = try allocator.alloc(u8, 512);
    try std.testing.expect(cautious.bytesUsed() == 512);

    // Allocate to exceed soft limit but within hard limit
    const buf2 = try allocator.alloc(u8, 600);
    try std.testing.expect(cautious.bytesUsed() == 1112);

    // Allocate to exceed hard limit
    const buf3 = allocator.alloc(u8, 1000);
    try std.testing.expectError(error.OutOfMemory, buf3);
    try std.testing.expect(cautious.bytesUsed() == 1112);

    // Free previous allocations
    allocator.free(buf1);
    allocator.free(buf2);
    try std.testing.expect(cautious.bytesUsed() == 0);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = @import("utils/root.zig");

/// CautiousAllocator
/// An allocator that enforces soft and hard memory limits,
/// with optional fallback and warning mechanisms.
///
/// - Soft limit: When exceeded, a warning function is called.
/// - Hard limit: When exceeded, allocations can either be denied or
///   redirected to a fallback allocator.
/// - Abort on soft limit: If true, allocations that exceed the soft limit will be denied.
/// - Fallback allocator: Used when hard limit is exceeded.
pub const CautiousAllocator = struct {
    inner: Allocator,
    fallback: Allocator,
    soft_limit: usize,
    hard_limit: usize,
    bytes_used: usize,
    abort_on_soft: bool,
    warned: bool,
    warnFn: *const fn (projected: usize, hard_limit: usize) void,

    /// Initialize a CautiousAllocator
    ///
    /// - `backing`: The underlying allocator to wrap
    /// - `fallback`: The fallback allocator to use when hard limit is reached
    /// - `soft_limit`: The soft limit in bytes
    /// - `hard_limit`: The hard limit in bytes
    /// - `abort_on_soft`: If true, allocations that exceed the soft limit will be aborted
    /// - `warnFn`: Function to call when soft limit is first exceeded, takes projected bytes and hard limit
    pub fn init(backing: Allocator, fallback: Allocator, soft_limit: usize, hard_limit: usize, abort_on_soft: bool, warnFn: *const fn (projected: usize, hard_limit: usize) void) CautiousAllocator {
        return CautiousAllocator{
            .inner = backing,
            .fallback = fallback,
            .soft_limit = soft_limit,
            .hard_limit = hard_limit,
            .bytes_used = 0,
            .abort_on_soft = abort_on_soft,
            .warned = false,
            .warnFn = warnFn,
        };
    }

    const AllocResult = enum { allow, use_fallback, deny };

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

    fn willAllow(self: *CautiousAllocator, additional: usize) AllocResult {
        const projected = self.bytes_used + additional;
        if (projected > self.hard_limit) return .use_fallback;
        if (projected > self.soft_limit) {
            if (!self.warned) {
                self.warnFn(projected, self.hard_limit);
                self.warned = true;
            }
            if (self.abort_on_soft) return .deny;
        }
        return .allow;
    }
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *CautiousAllocator = @ptrCast(@alignCast(ctx));

    const result = self.willAllow(len);

    switch (result) {
        .allow => {
            const ptr = self.inner.rawAlloc(len, alignment, ret_addr);
            if (ptr) |_| self.bytes_used += len;
            return ptr;
        },
        .use_fallback => return self.fallback.rawAlloc(len, alignment, ret_addr),
        .deny => return null,
    }
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *CautiousAllocator = @ptrCast(@alignCast(ctx));

    const old_len = buf.len;
    const additional = if (new_len > old_len) new_len - old_len else 0;
    const result = self.willAllow(additional);
    switch (result) {
        .allow => {
            const ok = self.inner.rawResize(buf, buf_align, new_len, ret_addr);
            if (ok) {
                if (new_len > old_len) {
                    self.bytes_used += additional;
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
        },
        .use_fallback => return false,
        .deny => return false,
    }
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *CautiousAllocator = @ptrCast(@alignCast(ctx));

    const old_len = memory.len;
    const additional = if (new_len > old_len) new_len - old_len else 0;
    const result = self.willAllow(additional);
    switch (result) {
        .allow => {
            const ptr = self.inner.rawRemap(memory, alignment, new_len, ret_addr);
            if (ptr) |_| {
                if (new_len > old_len) {
                    self.bytes_used += additional;
                } else if (old_len > new_len) {
                    const dec = old_len - new_len;
                    if (dec > self.bytes_used) {
                        self.bytes_used = 0;
                    } else {
                        self.bytes_used -= dec;
                    }
                }
            }
            return ptr;
        },
        .use_fallback => return null,
        .deny => return null,
    }
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
    var cautious = CautiousAllocator.init(backing_allocator, backing_allocator, 1024, 2048, false, struct {
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
    const buf3 = try allocator.alloc(u8, 1000);
    try std.testing.expect(cautious.bytesUsed() == 1112);

    // Free previous allocations
    allocator.free(buf1);
    allocator.free(buf2);
    allocator.free(buf3);
    try std.testing.expect(cautious.bytesUsed() == 0);
}

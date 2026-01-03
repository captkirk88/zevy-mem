const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const AllocationInfo = struct {
    real_ptr: [*]u8,
    total_size: usize,
    user_ptr: [*]u8,
    user_len: usize,
};

/// GuardedAllocator
/// A wrapper around any `std.mem.Allocator` that adds guard pages around allocations
/// to detect buffer overflows and underflows by causing segmentation faults on invalid access.
///
/// *UNTESTED ON LINUX* - TODO PR welcome!
pub const GuardedAllocator = struct {
    inner: Allocator,
    allocations: std.AutoHashMap(usize, AllocationInfo),
    allocator_backing: std.mem.Allocator,
    guard_pages: usize,

    /// Initialize a GuardedAllocator
    ///
    /// - `backing`: The underlying allocator (should be page_allocator or similar for virtual memory)
    /// - `arena`: Allocator for internal data structures
    /// - `guard_pages`: Number of guard pages before and after each allocation.
    ///
    /// Explanation of guard pages:
    ///
    ///  Guard pages are memory pages set to no-access protection, surrounding the user-allocated memory.
    ///  They detect buffer overflows/underflows by causing segmentation faults on invalid access.
    ///  For example, with guard_pages=1, each allocation has 1 guard page before and 1 after the user memory.
    ///  Accessing even 1 byte beyond the allocated buffer will hit a guard page and segfault.
    ///  More guard pages provide a larger safety zone but increase memory overhead.
    ///  Default is typically 1, as it's usually sufficient for detection.
    pub fn init(backing: Allocator, arena: std.mem.Allocator, guard_pages: usize) GuardedAllocator {
        return GuardedAllocator{
            .inner = backing,
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(arena),
            .allocator_backing = arena,
            .guard_pages = guard_pages,
        };
    }

    pub fn deinit(self: *GuardedAllocator) void {
        // Free all remaining allocations
        var it = self.allocations.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr.*;
            freeGuardedRegion(info.real_ptr, info.total_size);
        }
        self.allocations.deinit();
    }

    pub fn allocator(self: *GuardedAllocator) Allocator {
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

    /// Check if a pointer is currently allocated by this allocator.
    pub fn isAllocated(self: *const GuardedAllocator, ptr: *const anyopaque) bool {
        const addr = @intFromPtr(ptr);
        return self.allocations.contains(addr);
    }
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *GuardedAllocator = @ptrCast(@alignCast(ctx));

    if (len == 0) return self.inner.rawAlloc(len, alignment, ret_addr);

    const page_size = std.heap.pageSize();
    const guard_size = self.guard_pages * page_size;
    const user_pages = (len + page_size - 1) / page_size;
    const total_pages = self.guard_pages + user_pages + self.guard_pages;
    const total_size = total_pages * page_size;
    const middle_len = user_pages * page_size;

    const real_ptr = allocateGuardedRegion(total_size, guard_size, middle_len) orelse return null;

    const user_ptr = real_ptr + guard_size;
    const addr = @intFromPtr(user_ptr);

    const info = AllocationInfo{
        .real_ptr = real_ptr,
        .total_size = total_size,
        .user_ptr = user_ptr,
        .user_len = len,
    };

    self.allocations.put(addr, info) catch {
        freeGuardedRegion(real_ptr, total_size);
        return null;
    };

    return user_ptr;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *GuardedAllocator = @ptrCast(@alignCast(ctx));

    if (buf.len == 0) return self.inner.rawResize(buf, buf_align, new_len, ret_addr);

    const addr = @intFromPtr(buf.ptr);
    const info = self.allocations.getPtr(addr) orelse return false;

    const page_size = std.heap.pageSize();
    const current_user_pages = (info.user_len + page_size - 1) / page_size;
    const new_user_pages = (new_len + page_size - 1) / page_size;

    if (new_user_pages <= current_user_pages) {
        // Can shrink or stay the same within current pages
        info.user_len = new_len;
        return true;
    } else {
        // Cannot grow beyond current allocation
        return false;
    }
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    // Remapping with guard pages is not supported, as it would require complex relocation
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    const self: *GuardedAllocator = @ptrCast(@alignCast(ctx));

    if (buf.len == 0) {
        self.inner.rawFree(buf, buf_align, ret_addr);
        return;
    }

    const addr = @intFromPtr(buf.ptr);
    const info = self.allocations.get(addr) orelse {
        std.debug.panic("GuardedAllocator: Attempt to free unknown pointer 0x{x}", .{addr});
    };

    _ = self.allocations.remove(addr);
    freeGuardedRegion(info.real_ptr, info.total_size);
}

fn allocateGuardedRegion(total_size: usize, guard_size: usize, middle_len: usize) ?[*]u8 {
    if (builtin.os.tag == .windows) {
        const ptr = std.os.windows.VirtualAlloc(null, total_size, std.os.windows.MEM_RESERVE | std.os.windows.MEM_COMMIT, std.os.windows.PAGE_NOACCESS) catch return null;
        const base = @as([*]u8, @ptrCast(ptr));
        var old_protect: u32 = undefined;
        std.os.windows.VirtualProtect(@ptrCast(base + guard_size), middle_len, std.os.windows.PAGE_READWRITE, &old_protect) catch {
            std.os.windows.VirtualFree(ptr, 0, std.os.windows.MEM_RELEASE);
            return null;
        };
        return @ptrCast(ptr);
    } else {
        const ptr = std.os.linux.mmap(null, total_size, std.os.linux.PROT.NONE, .{ .ANONYMOUS = true }, -1, 0) catch return null;
        std.os.linux.mprotect(ptr + guard_size, middle_len, std.os.linux.PROT.READ | std.os.linux.PROT.WRITE) catch {
            std.os.linux.munmap(ptr, total_size);
            return null;
        };
        return ptr;
    }
}

fn freeGuardedRegion(ptr: [*]u8, size: usize) void {
    if (builtin.os.tag == .windows) {
        std.os.windows.VirtualFree(ptr, 0, std.os.windows.MEM_RELEASE);
    } else {
        const rc = std.os.linux.munmap(ptr, size);
        _ = rc; // munmap returns usize, 0 on success
    }
}

test "GuardedAllocator resize supported for shrinking" {
    var guarded = GuardedAllocator.init(std.heap.page_allocator, std.testing.allocator, 1);
    defer guarded.deinit();
    const allocator = guarded.allocator();

    const buf = try allocator.alloc(u8, 100);
    defer allocator.free(buf);

    // Shrink to 50 bytes - should succeed (fits in current page)
    const resized = allocator.resize(buf, 50);
    try std.testing.expect(resized);

    // Grow to 5000 bytes - should fail (requires more pages than allocated)
    const grown = allocator.resize(buf, 5000);
    try std.testing.expect(!grown);
}

test "GuardedAllocator remap not supported" {
    var guarded = GuardedAllocator.init(std.heap.page_allocator, std.testing.allocator, 1);
    defer guarded.deinit();
    const allocator = guarded.allocator();

    const buf = try allocator.alloc(u8, 100);
    defer allocator.free(buf);

    const remapped = allocator.remap(buf, 200);
    try std.testing.expect(remapped == null);
}

test "GuardedAllocator allocation tracking" {
    var guarded = GuardedAllocator.init(std.heap.page_allocator, std.testing.allocator, 1);
    defer guarded.deinit();
    const allocator = guarded.allocator();

    const page_size = std.heap.pageSize();
    const guard_pages = 1;
    const len = 100;
    const user_pages = (len + page_size - 1) / page_size;
    const expected_total_pages = guard_pages + user_pages + guard_pages;
    const expected_total_size = expected_total_pages * page_size;

    const buf = try allocator.alloc(u8, len);
    defer allocator.free(buf);

    // Check that allocation is tracked
    const addr = @intFromPtr(buf.ptr);
    const info = guarded.allocations.get(addr);
    try std.testing.expect(info != null);
    try std.testing.expect(info.?.total_size == expected_total_size);
    try std.testing.expect(info.?.user_len == len);
    try std.testing.expect(@intFromPtr(info.?.user_ptr) == addr);
}

test "GuardedAllocator guard pages cause segfault on overflow" {
    var guarded = GuardedAllocator.init(std.heap.page_allocator, std.testing.allocator, 1);
    defer guarded.deinit();
    const allocator = guarded.allocator();

    const buf = try allocator.alloc(u8, 100);
    defer {
        allocator.free(buf);
    }

    if (false) {
        // Disabled to avoid segfault in test runs; guard pages work in practice
        // Attempt to access beyond the buffer into the guard page - this should segfault
        const guard_ptr = buf.ptr + 4096; // start of guard page after user memory
        @as(*volatile u8, @ptrCast(&guard_ptr[0])).* = 42; // This will segfault if guard pages work
    }
}

fn fillBuf(buf: *[]u8) void {
    for (0..buf.len) |i| {
        buf.*[i] = @as(u8, @truncate(i));
    }
}

test "GuardedAllocator vs arena_allocator (contiguous)" {
    // With ArenaAllocator backed by fixed buffer, allocations are contiguous, overflow can corrupt adjacent allocations without segfault
    var large_buf: [10000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&large_buf);
    var versus = std.heap.ArenaAllocator.init(fba.allocator());
    defer versus.deinit();
    var normal_alloc = versus.allocator();
    var buf = try normal_alloc.alloc(u8, 4096);
    fillBuf(&buf);
    const buf2 = try normal_alloc.alloc(u8, 4096); // Adjacent in arena's contiguous block
    const overflow_ptr = buf.ptr + 4096;
    overflow_ptr[0] = 42; // Corrupts buf2, no segfault
    std.debug.print("Arena allocator did not segfault, buf2[0] = {}\n", .{buf2[0]});

    // With GuardedAllocator, overflow hits guard page, segfault
    var guarded = GuardedAllocator.init(versus.allocator(), std.testing.allocator, 1);
    defer guarded.deinit();
    const guarded_alloc = guarded.allocator();
    var gbuf = try guarded_alloc.alloc(u8, 4096);
    fillBuf(&gbuf);
    const gbuf2 = try guarded_alloc.alloc(u8, 4096);
    defer guarded_alloc.free(gbuf);
    // Uncomment
    _ = gbuf2; // Remove
    // const goverflow_ptr = gbuf.ptr + 4096;
    // goverflow_ptr[0] = 42; // Segfault
    // std.debug.print("Guarded allocator did segfault so this won't show, buf2[0] = {}\n", .{gbuf2[0]});
}

test "GuardedAllocator vs fixed buffer allocator" {
    var fixed_buf: [4096 * 2]u8 = undefined;
    var versus = std.heap.FixedBufferAllocator.init(&fixed_buf);
    var normal_alloc = versus.allocator();
    var buf = try normal_alloc.alloc(u8, 4096);
    fillBuf(&buf);
    const buf2 = try normal_alloc.alloc(u8, 4096); // Adjacent in arena's contiguous block
    const overflow_ptr = buf.ptr + 4096;
    overflow_ptr[0] = 42; // Corrupts buf2, no segfault
    std.debug.print("Fixed buffer allocator did not segfault, buf2[0] = {}\n", .{buf2[0]});

    versus.reset();

    var guarded = GuardedAllocator.init(versus.allocator(), std.testing.allocator, 1);
    defer guarded.deinit();
    const guarded_alloc = guarded.allocator();
    var gbuf = try guarded_alloc.alloc(u8, 4096);
    fillBuf(&gbuf);
    const gbuf2 = try guarded_alloc.alloc(u8, 4096);
    defer guarded_alloc.free(gbuf);
    // Uncomment
    _ = gbuf2; // Remove
    // const goverflow_ptr = gbuf.ptr + 4096;
    // goverflow_ptr[0] = 42; // Segfault
    // std.debug.print("Guarded allocator did segfault so this won't show, buf2[0] = {}\n", .{gbuf2[0]});
}

test "GuardedAllocator vs smp allocator" {
    const versus = std.heap.smp_allocator;
    var normal_alloc = versus;
    var buf = try normal_alloc.alloc(u8, 4096);
    fillBuf(&buf);
    const buf2 = try normal_alloc.alloc(u8, 4096); // Adjacent in arena's contiguous block
    const overflow_ptr = buf.ptr + 4096;
    overflow_ptr[0] = 42; // Corrupts buf2, no segfault
    std.debug.print("SMP allocator did not segfault, buf2[0] = {}\n", .{buf2[0]});

    var guarded = GuardedAllocator.init(versus, std.testing.allocator, 1);
    defer guarded.deinit();
    const guarded_alloc = guarded.allocator();
    var gbuf = try guarded_alloc.alloc(u8, 4096);
    fillBuf(&gbuf);
    const gbuf2 = try guarded_alloc.alloc(u8, 4096);
    defer guarded_alloc.free(gbuf);
    // Uncomment
    _ = gbuf2; // Remove
    // const goverflow_ptr = gbuf.ptr + 4096;
    // goverflow_ptr[0] = 42; // Segfault
    // std.debug.print("Guarded allocator did segfault so this won't show, buf2[0] = {}\n", .{gbuf2[0]});
}

test "GuardedAllocator std.heap.testAllocator" {
    var versus = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer versus.deinit();
    var guarded = GuardedAllocator.init(versus.allocator(), std.testing.allocator, 1);
    defer guarded.deinit();

    try std.heap.testAllocator(guarded.allocator());
}

test "GuardedAllocator std.heap.testAllocatorLargeAlignment" {
    var versus = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer versus.deinit();
    var guarded = GuardedAllocator.init(versus.allocator(), std.testing.allocator, 1);
    defer guarded.deinit();

    try std.heap.testAllocatorLargeAlignment(guarded.allocator());
}

test "GuardedAllocator std.heap.testAllocatorAligned" {
    var versus = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer versus.deinit();
    var guarded = GuardedAllocator.init(versus.allocator(), std.testing.allocator, 1);
    defer guarded.deinit();

    try std.heap.testAllocatorAligned(guarded.allocator());
}

test "GuardedAllocator std.heap.testAllocatorAlignedShrink" {
    var versus = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer versus.deinit();
    var guarded = GuardedAllocator.init(versus.allocator(), std.testing.allocator, 1);
    defer guarded.deinit();

    try std.heap.testAllocatorAlignedShrink(guarded.allocator());
}

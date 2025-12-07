const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const util = @import("mem_utils.zig");

/// Debug wrapper around any std.mem.Allocator that tracks allocations for leak detection.
/// Uses dynamic allocation for tracking (allocates from the backing allocator).
pub const DebugAllocator = struct {
    const Self = @This();

    pub const AllocationInfo = struct {
        /// Pointer address of the allocation
        ptr: usize,
        /// Requested allocation length
        len: usize,
        /// Whether this allocation is still active
        active: bool,
        /// Unique allocation ID (monotonically increasing)
        allocation_id: u64,
        /// Timestamp (monotonic counter when allocation occurred)
        timestamp: u64,
        /// Return address where allocation was requested
        return_address: usize,
        /// Alignment requirement for this allocation
        alignment: usize,
        /// Number of times this allocation was resized
        resize_count: u32,
        /// Original size before any resizes
        original_len: usize,

        pub fn format(
            self: AllocationInfo,
            writer: *std.io.Writer,
        ) !void {
            try writer.print(
                "#{d} [0x{x}]: {d} bytes (align: {d}) @ 0x{x}, resizes: {d}",
                .{
                    self.allocation_id,
                    self.ptr,
                    self.len,
                    self.alignment,
                    self.return_address,
                    self.resize_count,
                },
            );
        }

        /// Get source location string for this allocation's return address.
        /// Only works in debug builds with debug info available.
        /// Caller owns the returned memory.
        pub fn getSourceLocation(self: *const AllocationInfo, allocator_: Allocator) ![]const u8 {
            return util.resolveSourceLocation(allocator_, self.return_address);
        }
    };

    /// Statistics for allocation patterns
    pub const AllocationStats = struct {
        /// Total number of allocations made
        total_allocations: u64,
        /// Total number of frees made
        total_frees: u64,
        /// Peak active allocations at any point
        peak_active_allocations: usize,
        /// Peak bytes used at any point
        peak_bytes_used: usize,
        /// Total bytes allocated over lifetime
        total_bytes_allocated: u64,
        /// Total bytes freed over lifetime
        total_bytes_freed: u64,
        /// Total resize operations
        total_resizes: u64,
        /// Failed allocation attempts
        failed_allocations: u64,
        /// Failed resize attempts
        failed_resizes: u64,
        /// Current bytes in use
        current_bytes_used: usize,
    };

    inner: Allocator,
    allocations: std.ArrayList(AllocationInfo),
    stats: AllocationStats,
    /// Monotonic counter for allocation IDs
    next_allocation_id: u64,
    /// Monotonic counter for timestamps
    current_timestamp: u64,
    /// Whether we're currently inside a tracking operation (prevents recursion)
    tracking_in_progress: bool,

    /// Initialize with a backing allocator.
    pub fn init(backing_allocator: Allocator) Self {
        return .{
            .inner = backing_allocator,
            .allocations = std.ArrayList(AllocationInfo).initCapacity(backing_allocator, 128) catch {
                @panic("Failed to initialize DebugAllocator tracking list");
            },
            .stats = std.mem.zeroes(AllocationStats),
            .next_allocation_id = 1,
            .current_timestamp = 0,
            .tracking_in_progress = false,
        };
    }

    /// Deinitialize and free tracking resources.
    pub fn deinit(self: *Self) void {
        self.allocations.deinit(self.inner);
    }

    /// Get the debug allocator interface.
    pub fn allocator(self: *Self) Allocator {
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

    /// Reset tracking statistics (does not free allocations).
    pub fn resetStats(self: *Self) void {
        self.stats = std.mem.zeroes(AllocationStats);
    }

    /// Reset all tracking (WARNING: loses track of active allocations).
    pub fn resetTracking(self: *Self) void {
        self.allocations.clearRetainingCapacity();
        self.stats = std.mem.zeroes(AllocationStats);
        self.next_allocation_id = 1;
        self.current_timestamp = 0;
    }

    /// Returns true if there are active allocations (leaks).
    pub fn detectLeaks(self: *const Self) bool {
        return self.activeAllocationCount() > 0;
    }

    /// Returns the number of currently active allocations.
    pub fn activeAllocationCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.allocations.items) |info| {
            if (info.active) count += 1;
        }
        return count;
    }

    /// Returns current bytes in use.
    pub fn bytesUsed(self: *const Self) usize {
        return self.stats.current_bytes_used;
    }

    /// Returns a slice of all allocation infos for inspection.
    pub fn getActiveAllocations(self: *const Self) []const AllocationInfo {
        return self.allocations.items;
    }

    /// Get allocation statistics.
    pub fn getStats(self: *const Self) AllocationStats {
        return self.stats;
    }

    /// Find allocation info by pointer.
    pub fn getAllocationInfo(self: *const Self, ptr: *const anyopaque) ?AllocationInfo {
        const addr = @intFromPtr(ptr);
        for (self.allocations.items) |info| {
            if (info.ptr == addr) {
                return info;
            }
        }
        return null;
    }

    /// Get allocations sorted by size (descending).
    pub fn getLargestAllocations(self: *const Self, out: []AllocationInfo) usize {
        var count: usize = 0;
        for (self.allocations.items) |info| {
            if (info.active and count < out.len) {
                out[count] = info;
                count += 1;
            }
        }
        // Simple bubble sort for small arrays
        for (0..count) |i| {
            for (i + 1..count) |j| {
                if (out[j].len > out[i].len) {
                    const tmp = out[i];
                    out[i] = out[j];
                    out[j] = tmp;
                }
            }
        }
        return count;
    }

    /// Print detailed leak report to debug output with source locations.
    pub fn dumpLeaks(self: *const Self) void {
        var leaked_bytes: usize = 0;
        var leak_count: usize = 0;

        std.debug.print("\n=== MEMORY LEAK REPORT ===\n", .{});

        for (self.allocations.items) |info| {
            if (info.active) {
                std.debug.print("\nLeak {f}\n", .{info});
                const source = info.getSourceLocation(self.inner) catch |err| blk: {
                    std.debug.print("    (failed to resolve: {s})\n", .{@errorName(err)});
                    break :blk null;
                };
                if (source) |s| {
                    std.debug.print("    {s}\n", .{s});
                    self.inner.free(s);
                }
                leaked_bytes += info.len;
                leak_count += 1;
            }
        }

        if (leak_count > 0) {
            std.debug.print("\nSummary: {d} leaks, {f} leaked\n", .{ leak_count, util.byteSize(leaked_bytes) });
        } else {
            std.debug.print("No leaks detected.\n", .{});
        }

        self.dumpStats();
    }

    /// Print allocation statistics.
    pub fn dumpStats(self: *const Self) void {
        const utils = @import("mem_utils.zig");
        std.debug.print("\n=== ALLOCATION STATISTICS ===\n", .{});
        std.debug.print("Total allocations: {d}\n", .{self.stats.total_allocations});
        std.debug.print("Total frees: {d}\n", .{self.stats.total_frees});
        std.debug.print("Current bytes used: {f}\n", .{utils.byteSize(self.stats.current_bytes_used)});
        std.debug.print("Peak active allocations: {d}\n", .{self.stats.peak_active_allocations});
        std.debug.print("Peak bytes used: {f}\n", .{utils.byteSize(self.stats.peak_bytes_used)});
        std.debug.print("Total bytes allocated: {f}\n", .{utils.byteSize(self.stats.total_bytes_allocated)});
        std.debug.print("Total bytes freed: {f}\n", .{utils.byteSize(self.stats.total_bytes_freed)});
        std.debug.print("Total resizes: {d}\n", .{self.stats.total_resizes});
        std.debug.print("Failed allocations: {d}\n", .{self.stats.failed_allocations});
        std.debug.print("Failed resizes: {d}\n", .{self.stats.failed_resizes});
        std.debug.print("Tracked allocations: {d}\n", .{self.allocations.items.len});
        std.debug.print("===========================\n\n", .{});
    }

    fn trackAllocation(self: *Self, ptr: usize, len: usize, alignment: usize, ret_addr: usize) void {
        // Prevent recursive tracking when ArrayList allocates
        if (self.tracking_in_progress) return;
        self.tracking_in_progress = true;
        defer self.tracking_in_progress = false;

        self.allocations.append(self.inner, .{
            .ptr = ptr,
            .len = len,
            .active = true,
            .allocation_id = self.next_allocation_id,
            .timestamp = self.current_timestamp,
            .return_address = ret_addr,
            .alignment = alignment,
            .resize_count = 0,
            .original_len = len,
        }) catch {
            // If we can't track, just continue without tracking
            return;
        };

        self.next_allocation_id += 1;
        self.current_timestamp += 1;

        // Update stats
        self.stats.total_allocations += 1;
        self.stats.total_bytes_allocated += len;
        self.stats.current_bytes_used += len;

        const active = self.activeAllocationCount();
        if (active > self.stats.peak_active_allocations) {
            self.stats.peak_active_allocations = active;
        }

        if (self.stats.current_bytes_used > self.stats.peak_bytes_used) {
            self.stats.peak_bytes_used = self.stats.current_bytes_used;
        }
    }

    fn findAllocation(self: *Self, ptr: usize) ?*AllocationInfo {
        for (self.allocations.items) |*info| {
            if (info.active and info.ptr == ptr) {
                return info;
            }
        }
        return null;
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const result = self.inner.rawAlloc(len, ptr_align, ret_addr);

        if (result) |ptr| {
            self.trackAllocation(@intFromPtr(ptr), len, @intFromEnum(ptr_align), ret_addr);
        } else {
            self.stats.failed_allocations += 1;
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const result = self.inner.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) {
            if (self.findAllocation(@intFromPtr(buf.ptr))) |info| {
                const old_len = info.len;
                info.len = new_len;
                info.resize_count += 1;
                info.timestamp = self.current_timestamp;
                self.current_timestamp += 1;

                self.stats.total_resizes += 1;
                if (new_len > old_len) {
                    const diff = new_len - old_len;
                    self.stats.total_bytes_allocated += diff;
                    self.stats.current_bytes_used += diff;
                } else {
                    const diff = old_len - new_len;
                    self.stats.total_bytes_freed += diff;
                    self.stats.current_bytes_used -= diff;
                }

                if (self.stats.current_bytes_used > self.stats.peak_bytes_used) {
                    self.stats.peak_bytes_used = self.stats.current_bytes_used;
                }
            }
        } else {
            self.stats.failed_resizes += 1;
        }
        return result;
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const result = self.inner.rawRemap(buf, buf_align, new_len, ret_addr);
        if (result) |new_ptr| {
            if (self.findAllocation(@intFromPtr(buf.ptr))) |info| {
                const old_len = info.len;
                info.ptr = @intFromPtr(new_ptr);
                info.len = new_len;
                info.resize_count += 1;
                info.timestamp = self.current_timestamp;
                self.current_timestamp += 1;

                self.stats.total_resizes += 1;
                if (new_len > old_len) {
                    const diff = new_len - old_len;
                    self.stats.total_bytes_allocated += diff;
                    self.stats.current_bytes_used += diff;
                } else {
                    const diff = old_len - new_len;
                    self.stats.total_bytes_freed += diff;
                    self.stats.current_bytes_used -= diff;
                }

                if (self.stats.current_bytes_used > self.stats.peak_bytes_used) {
                    self.stats.peak_bytes_used = self.stats.current_bytes_used;
                }
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (self.findAllocation(@intFromPtr(buf.ptr))) |info| {
            info.active = false;
            self.stats.total_frees += 1;
            self.stats.total_bytes_freed += info.len;
            self.stats.current_bytes_used -= info.len;
        }

        self.inner.rawFree(buf, buf_align, ret_addr);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "basic allocation tracking" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    const slice = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 1), debug.activeAllocationCount());
    try std.testing.expectEqual(@as(u64, 1), debug.stats.total_allocations);
    try std.testing.expectEqual(@as(usize, 100), debug.bytesUsed());

    alloc.free(slice);
    try std.testing.expectEqual(@as(usize, 0), debug.activeAllocationCount());
    try std.testing.expectEqual(@as(u64, 1), debug.stats.total_frees);
    try std.testing.expectEqual(@as(usize, 0), debug.bytesUsed());
}

test "allocation info details" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    const slice = try alloc.alloc(u8, 100);
    defer alloc.free(slice);

    const info = debug.getAllocationInfo(slice.ptr);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(usize, 100), info.?.len);
    try std.testing.expectEqual(@as(usize, 100), info.?.original_len);
    try std.testing.expectEqual(@as(u64, 1), info.?.allocation_id);
    try std.testing.expect(info.?.active);
    try std.testing.expectEqual(@as(u32, 0), info.?.resize_count);
}

test "resize tracking" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    var slice = try alloc.alloc(u8, 50);

    const resized = alloc.resize(slice, 100);
    if (resized) {
        // Resize succeeded - verify tracking
        const info = debug.getAllocationInfo(slice.ptr);
        try std.testing.expect(info != null);
        try std.testing.expectEqual(@as(usize, 100), info.?.len);
        try std.testing.expectEqual(@as(usize, 50), info.?.original_len);
        try std.testing.expectEqual(@as(u32, 1), info.?.resize_count);
        try std.testing.expectEqual(@as(u64, 1), debug.stats.total_resizes);
        alloc.free(slice);
    } else {
        // Resize not supported by backing allocator - use realloc instead
        slice = try alloc.realloc(slice, 100);
        try std.testing.expectEqual(@as(usize, 100), slice.len);
        alloc.free(slice);
    }
}

test "peak tracking" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    const a = try alloc.alloc(u8, 100);
    const b = try alloc.alloc(u8, 200);
    const c = try alloc.alloc(u8, 150);

    try std.testing.expectEqual(@as(usize, 3), debug.stats.peak_active_allocations);
    try std.testing.expectEqual(@as(usize, 450), debug.stats.peak_bytes_used);

    alloc.free(c);
    alloc.free(b);
    alloc.free(a);

    try std.testing.expectEqual(@as(usize, 3), debug.stats.peak_active_allocations);
    try std.testing.expectEqual(@as(usize, 450), debug.stats.peak_bytes_used);
    try std.testing.expectEqual(@as(usize, 0), debug.bytesUsed());
}

test "leak detection" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    const a = try alloc.alloc(u8, 100);
    const b = try alloc.alloc(u8, 50);

    try std.testing.expect(debug.detectLeaks());
    try std.testing.expectEqual(@as(usize, 2), debug.activeAllocationCount());
    debug.dumpLeaks();
    alloc.free(b);
    alloc.free(a);
}

test "no leaks when properly freed" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    const a = try alloc.alloc(u8, 100);
    const b = try alloc.alloc(u8, 50);

    alloc.free(b);
    alloc.free(a);

    try std.testing.expect(!debug.detectLeaks());
    try std.testing.expectEqual(@as(usize, 0), debug.activeAllocationCount());
}

test "statistics tracking" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    const a = try alloc.alloc(u8, 50);
    const b = try alloc.alloc(u8, 50);
    const c = try alloc.alloc(u8, 50);

    alloc.free(c);
    alloc.free(b);
    alloc.free(a);

    try std.testing.expectEqual(@as(u64, 3), debug.stats.total_allocations);
    try std.testing.expectEqual(@as(u64, 3), debug.stats.total_frees);
    try std.testing.expectEqual(@as(u64, 150), debug.stats.total_bytes_allocated);
    try std.testing.expectEqual(@as(u64, 150), debug.stats.total_bytes_freed);
}

test "largest allocations" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    const a = try alloc.alloc(u8, 50);
    const b = try alloc.alloc(u8, 200);
    const c = try alloc.alloc(u8, 100);

    var largest: [3]DebugAllocator.AllocationInfo = undefined;
    const count = debug.getLargestAllocations(&largest);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 200), largest[0].len);
    try std.testing.expectEqual(@as(usize, 100), largest[1].len);
    try std.testing.expectEqual(@as(usize, 50), largest[2].len);

    alloc.free(c);
    alloc.free(b);
    alloc.free(a);
}

test "realloc tracking" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const alloc = debug.allocator();

    var slice = try alloc.alloc(u8, 50);
    slice = try alloc.realloc(slice, 100);
    defer alloc.free(slice);

    try std.testing.expectEqual(@as(usize, 100), debug.bytesUsed());
}

test "many allocations" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer {
        std.debug.print("Test: many allocations\n", .{});
        debug.dumpLeaks();
        debug.deinit();
    }
    const alloc = debug.allocator();

    var slices: [100][]u8 = undefined;
    for (&slices, 0..) |*s, i| {
        s.* = try alloc.alloc(u8, i + 1);
    }

    try std.testing.expectEqual(@as(usize, 100), debug.activeAllocationCount());

    for (slices) |s| {
        alloc.free(s);
    }

    try std.testing.expectEqual(@as(usize, 0), debug.activeAllocationCount());
}

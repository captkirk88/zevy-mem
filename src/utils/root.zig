const std = @import("std");
const builtin = @import("builtin");
const zevy_reflect = @import("zevy_reflect");
const interfaces = @import("../interfaces.zig");
const mem = @import("mem.zig");

pub const TrackingAllocator = interfaces.TrackingAllocator;

pub const getMemoryInfo = mem.getMemoryInfo;
pub const MemoryInfo = mem.MemoryInfo;

/// Check if a pointer is aligned to the given alignment
pub fn isAligned(ptr: anytype, alignment: std.mem.Alignment) bool {
    const addr = switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => @intFromPtr(ptr),
        .int, .comptime_int => ptr,
        else => @compileError("Expected pointer or integer"),
    };
    return addr % alignment.toByteUnits() == 0;
}

/// Calculate the aligned size for a given size and alignment
pub fn alignedSize(size: usize, alignment: std.mem.Alignment) usize {
    return alignment.forward(size);
}

/// Calculate padding needed to align a size
pub fn alignmentPadding(size: usize, alignment: std.mem.Alignment) usize {
    return alignedSize(size, alignment) - size;
}

/// Memory region descriptor with utility methods for memory analysis
pub const MemoryRegion = struct {
    start: usize,
    len: usize,

    /// Create an empty region
    pub const empty: MemoryRegion = .{ .start = 0, .len = 0 };

    /// Get the end address of the region (exclusive)
    pub fn end(self: MemoryRegion) usize {
        return self.start + self.len;
    }

    /// Get the size of the region
    pub fn size(self: MemoryRegion) usize {
        return self.len;
    }

    /// Check if the region is empty
    pub fn isEmpty(self: MemoryRegion) bool {
        return self.len == 0;
    }

    /// Check if an address is contained within this region
    pub fn contains(self: MemoryRegion, addr: usize) bool {
        return addr >= self.start and addr < self.end();
    }

    /// Check if this region fully contains another region
    pub fn containsRegion(self: MemoryRegion, other: MemoryRegion) bool {
        if (other.isEmpty()) return true;
        return other.start >= self.start and other.end() <= self.end();
    }

    /// Check if this region overlaps with another region
    pub fn overlaps(self: MemoryRegion, other: MemoryRegion) bool {
        if (self.isEmpty() or other.isEmpty()) return false;
        return self.start < other.end() and other.start < self.end();
    }

    /// Get the intersection of two regions (the overlapping part)
    pub fn intersection(self: MemoryRegion, other: MemoryRegion) MemoryRegion {
        if (!self.overlaps(other)) return empty;
        const new_start = @max(self.start, other.start);
        const new_end = @min(self.end(), other.end());
        return .{ .start = new_start, .len = new_end - new_start };
    }

    /// Get the union of two regions (smallest region containing both)
    /// Note: This includes any gap between non-overlapping regions
    pub fn unionWith(self: MemoryRegion, other: MemoryRegion) MemoryRegion {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;
        const new_start = @min(self.start, other.start);
        const new_end = @max(self.end(), other.end());
        return .{ .start = new_start, .len = new_end - new_start };
    }

    /// Check if the region start is aligned to a given alignment
    pub fn isStartAligned(self: MemoryRegion, alignment: std.mem.Alignment) bool {
        return isAligned(self.start, alignment);
    }

    /// Check if both start and length are aligned
    pub fn isFullyAligned(self: MemoryRegion, alignment: std.mem.Alignment) bool {
        return isAligned(self.start, alignment) and isAligned(self.len, alignment);
    }

    /// Get the distance (gap) between two non-overlapping regions
    /// Returns null if regions overlap
    pub fn distanceTo(self: MemoryRegion, other: MemoryRegion) ?usize {
        if (self.overlaps(other)) return null;
        if (self.end() <= other.start) {
            return other.start - self.end();
        } else {
            return self.start - other.end();
        }
    }

    /// Split the region at a given offset from the start
    /// Returns null if offset is out of bounds
    pub fn splitAt(self: MemoryRegion, offset: usize) ?struct { left: MemoryRegion, right: MemoryRegion } {
        if (offset > self.len) return null;
        return .{
            .left = .{ .start = self.start, .len = offset },
            .right = .{ .start = self.start + offset, .len = self.len - offset },
        };
    }

    /// Shrink the region from the start
    pub fn shrinkStart(self: MemoryRegion, amount: usize) MemoryRegion {
        if (amount >= self.len) return empty;
        return .{ .start = self.start + amount, .len = self.len - amount };
    }

    /// Shrink the region from the end
    pub fn shrinkEnd(self: MemoryRegion, amount: usize) MemoryRegion {
        if (amount >= self.len) return empty;
        return .{ .start = self.start, .len = self.len - amount };
    }

    /// Expand the region from the start (decreases start address)
    pub fn expandStart(self: MemoryRegion, amount: usize) MemoryRegion {
        if (amount > self.start) return .{ .start = 0, .len = self.len + self.start };
        return .{ .start = self.start - amount, .len = self.len + amount };
    }

    /// Expand the region from the end
    pub fn expandEnd(self: MemoryRegion, amount: usize) MemoryRegion {
        return .{ .start = self.start, .len = self.len + amount };
    }

    /// Align the region start up to the given alignment (shrinks region)
    ///
    /// Moves the start address up to the next aligned address.
    pub fn alignStartUp(self: MemoryRegion, alignment: std.mem.Alignment) MemoryRegion {
        const aligned_start = alignment.forward(self.start);
        if (aligned_start >= self.end()) return empty;
        return .{ .start = aligned_start, .len = self.end() - aligned_start };
    }

    /// Align the region end down to the given alignment (shrinks region)
    ///
    /// Moves the end address down to the previous aligned address.
    pub fn alignEndDown(self: MemoryRegion, alignment: std.mem.Alignment) MemoryRegion {
        const aligned_end = alignment.backward(self.end());
        if (aligned_end <= self.start) return empty;
        return .{ .start = self.start, .len = aligned_end - self.start };
    }

    /// Create a MemoryRegion from a slice
    pub fn fromSlice(slice: []const u8) MemoryRegion {
        return .{
            .start = @intFromPtr(slice.ptr),
            // Length in bytes: number of elements * size of each element
            .len = slice.len * @sizeOf(@TypeOf(slice[0])),
        };
    }

    /// Convert the MemoryRegion to a slice
    pub fn toSlice(self: MemoryRegion) []u8 {
        const ptr: [*]u8 = @ptrFromInt(self.start);
        return ptr[0..self.len];
    }

    /// Create a MemoryRegion from a pointer
    ///
    /// Size is determined by the type size of the pointer.
    pub fn fromPtr(ptr: [*]u8) MemoryRegion {
        return .{
            .start = @intFromPtr(ptr),
            .len = @sizeOf(@TypeOf(ptr)),
        };
    }

    pub fn fromRawPtr(ptr: [*]u8) MemoryRegion {
        const bytes = std.mem.asBytes(ptr[0..@sizeOf(@TypeOf(ptr))]);
        return .{
            .start = @intFromPtr(ptr),
            .len = bytes.len,
        };
    }

    pub fn toPtr(self: MemoryRegion) [*]u8 {
        return @ptrFromInt(self.start);
    }

    /// Create a MemoryRegion from a pointer with explicit length.
    /// Use this when you need to preserve the region length through pointer conversions.
    pub fn fromPtrWithLen(ptr: [*]u8, len: usize) MemoryRegion {
        return .{
            .start = @intFromPtr(ptr),
            .len = len,
        };
    }

    /// Create a MemoryRegion from any typed pointer
    pub fn fromTypedPtr(comptime T: type, ptr: *const T) MemoryRegion {
        return .{
            .start = @intFromPtr(ptr),
            .len = @sizeOf(T),
        };
    }

    /// Create a MemoryRegion from a range of addresses
    pub fn fromRange(start_addr: usize, end_addr: usize) MemoryRegion {
        if (end_addr <= start_addr) return empty;
        return .{ .start = start_addr, .len = end_addr - start_addr };
    }

    /// Format the region as a human-readable string.
    /// Caller owns returned memory.
    pub fn formatRegion(self: MemoryRegion, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{f}", .{self});
    }

    /// Std formatter support
    pub fn format(
        self: MemoryRegion,
        writer: *std.io.Writer,
    ) !void {
        try writer.print("0x{x}..0x{x} ({f})", .{
            self.start,
            self.end(),
            byteSize(self.len),
        });
    }
};

/// Scope marker for stack allocators - enables save/restore patterns
pub fn ScopeMarker(comptime AllocatorType: type) type {
    return struct {
        allocator: TrackingAllocator,
        saved_index: usize = 0,
        last_index: usize = 0,

        const Self = @This();
        pub fn init(alloc: *AllocatorType) Self {
            var iface: interfaces.TrackingAllocatorTemplate.Interface = undefined;
            interfaces.TrackingAllocatorTemplate.populate(&iface, alloc);
            return Self{
                .allocator = iface,
                .saved_index = iface.vtable.bytesUsed(iface.ptr),
            };
        }

        pub fn save(self: *Self) *Self {
            self.last_index = self.saved_index;
            self.saved_index = self.allocator.vtable.bytesUsed(self.allocator.ptr);
            return self;
        }

        pub fn restore(self: *Self) void {
            const current_index = self.allocator.vtable.bytesUsed(self.allocator.ptr);
            if (self.saved_index < current_index) {
                // Reset the allocator to the saved index
                self.last_index = self.saved_index;
                const new_index: usize = self.allocator.vtable.rewind(self.allocator.ptr, current_index - self.saved_index);
                self.saved_index = new_index;
            }
        }
    };
}

const KB = 1024;
const MB = 1024 * KB;
const GB = 1024 * MB;
const TB = 1024 * GB;
const PB = 1024 * TB;

/// Human-readable byte size formatting
pub const ByteSize = struct {
    bytes: usize,

    /// Format the byte size into human-readable form using std.fmt
    pub fn format(
        self: ByteSize,
        writer: *std.io.Writer,
    ) !void {
        // If you ever come across a Petabyte of data in Zig, please let me know :)
        if (self.bytes >= PB) {
            try writer.print("{d:.2} PiB", .{@as(f64, @floatFromInt(self.bytes)) / @as(f64, PB)});
        } else if (self.bytes >= TB) {
            try writer.print("{d:.2} TiB", .{@as(f64, @floatFromInt(self.bytes)) / @as(f64, TB)});
        } else if (self.bytes >= GB) {
            try writer.print("{d:.2} GiB", .{@as(f64, @floatFromInt(self.bytes)) / @as(f64, GB)});
        } else if (self.bytes >= MB) {
            try writer.print("{d:.2} MiB", .{@as(f64, @floatFromInt(self.bytes)) / @as(f64, MB)});
        } else if (self.bytes >= KB) {
            try writer.print("{d:.2} KiB", .{@as(f64, @floatFromInt(self.bytes)) / @as(f64, KB)});
        } else {
            try writer.print("{d} B", .{self.bytes});
        }
    }

    /// Format to an allocated string. Caller owns returned memory.
    pub fn formatAlloc(self: ByteSize, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        return std.fmt.allocPrint(allocator, "{f}", .{self});
    }
};

pub fn byteSize(bytes: usize) ByteSize {
    return ByteSize{ .bytes = bytes };
}

/// Format a symbol address into a human-readable source location string.
/// Returns the formatted string, or a fallback if debug info is unavailable.
/// Caller owns the returned memory.
pub fn formatSymbolAddress(allocator: std.mem.Allocator, debug_info: *std.debug.SelfInfo, address: usize) ![]const u8 {
    const module = debug_info.getModuleForAddress(address) catch {
        return std.fmt.allocPrint(allocator, "0x{x} (no module)", .{address});
    };

    const symbol = module.getSymbolAtAddress(debug_info.allocator, address) catch {
        return std.fmt.allocPrint(allocator, "0x{x} (no symbol)", .{address});
    };

    if (symbol.source_location) |loc| {
        const file_name = loc.file_name;
        return std.fmt.allocPrint(allocator, "{s}:{d}:{d} in {s}", .{ file_name, loc.line, loc.column, symbol.name });
    }
    return std.fmt.allocPrint(allocator, "{s} (0x{x})", .{ symbol.name, address });
}

/// Resolve a return address to a human-readable source location string.
/// Caller owns the returned memory.
pub fn resolveSourceLocation(allocator: std.mem.Allocator, address: usize) ![]const u8 {
    if (address == 0) {
        return try allocator.dupe(u8, "(no return address)");
    }
    const debug_info = std.debug.getSelfDebugInfo() catch {
        return std.fmt.allocPrint(allocator, "0x{x}\n", .{address});
    };

    return formatSymbolAddress(allocator, debug_info, address);
}

// ============================================================================
// Tests
// ============================================================================

test "isAligned" {
    const align4 = std.mem.Alignment.@"4";
    try std.testing.expect(isAligned(@as(usize, 0), align4));
    try std.testing.expect(isAligned(@as(usize, 4), align4));
    try std.testing.expect(isAligned(@as(usize, 8), align4));
    try std.testing.expect(!isAligned(@as(usize, 1), align4));
    try std.testing.expect(!isAligned(@as(usize, 3), align4));
}

test "alignedSize" {
    const align4 = std.mem.Alignment.@"4";
    const align8 = std.mem.Alignment.@"8";
    try std.testing.expectEqual(@as(usize, 4), alignedSize(1, align4));
    try std.testing.expectEqual(@as(usize, 4), alignedSize(4, align4));
    try std.testing.expectEqual(@as(usize, 8), alignedSize(5, align4));
    try std.testing.expectEqual(@as(usize, 16), alignedSize(13, align8));
}

test "alignmentPadding" {
    const align4 = std.mem.Alignment.@"4";
    try std.testing.expectEqual(@as(usize, 3), alignmentPadding(1, align4));
    try std.testing.expectEqual(@as(usize, 0), alignmentPadding(4, align4));
    try std.testing.expectEqual(@as(usize, 3), alignmentPadding(5, align4));
}

test "ByteSize formatting" {
    var buf: [64]u8 = undefined;

    const small = std.fmt.bufPrint(&buf, "{f}", .{byteSize(512)}) catch unreachable;
    try std.testing.expectEqualStrings("512 B", small);

    const kib = std.fmt.bufPrint(&buf, "{f}", .{byteSize(2048)}) catch unreachable;
    try std.testing.expectEqualStrings("2.00 KiB", kib);

    const mib = std.fmt.bufPrint(&buf, "{f}", .{byteSize(1024 * 1024 * 3)}) catch unreachable;
    try std.testing.expectEqualStrings("3.00 MiB", mib);
}

test "MemoryRegion" {
    const region1 = MemoryRegion{ .start = 100, .len = 50 };
    const region2 = MemoryRegion{ .start = 120, .len = 50 };
    const region3 = MemoryRegion{ .start = 200, .len = 50 };

    try std.testing.expect(region1.contains(100));
    try std.testing.expect(region1.contains(149));
    try std.testing.expect(!region1.contains(150));

    try std.testing.expect(region1.overlaps(region2));
    try std.testing.expect(!region1.overlaps(region3));
}

test "MemoryRegion empty" {
    const empty = MemoryRegion.empty;
    try std.testing.expect(empty.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), empty.size());
}

test "MemoryRegion containsRegion" {
    const outer = MemoryRegion{ .start = 100, .len = 100 };
    const inner = MemoryRegion{ .start = 120, .len = 30 };
    const partial = MemoryRegion{ .start = 150, .len = 100 };

    try std.testing.expect(outer.containsRegion(inner));
    try std.testing.expect(!outer.containsRegion(partial));
    try std.testing.expect(outer.containsRegion(MemoryRegion.empty));
}

test "MemoryRegion intersection" {
    const r1 = MemoryRegion{ .start = 100, .len = 50 };
    const r2 = MemoryRegion{ .start = 120, .len = 50 };
    const r3 = MemoryRegion{ .start = 200, .len = 50 };

    const inter = r1.intersection(r2);
    try std.testing.expectEqual(@as(usize, 120), inter.start);
    try std.testing.expectEqual(@as(usize, 30), inter.len);

    const no_inter = r1.intersection(r3);
    try std.testing.expect(no_inter.isEmpty());
}

test "MemoryRegion unionWith" {
    const r1 = MemoryRegion{ .start = 100, .len = 50 };
    const r2 = MemoryRegion{ .start = 120, .len = 50 };

    const u = r1.unionWith(r2);
    try std.testing.expectEqual(@as(usize, 100), u.start);
    try std.testing.expectEqual(@as(usize, 70), u.len);
}

test "MemoryRegion splitAt" {
    const region = MemoryRegion{ .start = 100, .len = 100 };

    const split = region.splitAt(30).?;
    try std.testing.expectEqual(@as(usize, 100), split.left.start);
    try std.testing.expectEqual(@as(usize, 30), split.left.len);
    try std.testing.expectEqual(@as(usize, 130), split.right.start);
    try std.testing.expectEqual(@as(usize, 70), split.right.len);

    try std.testing.expect(region.splitAt(200) == null);
}

test "MemoryRegion shrink and expand" {
    const region = MemoryRegion{ .start = 100, .len = 100 };

    const shrunk_start = region.shrinkStart(20);
    try std.testing.expectEqual(@as(usize, 120), shrunk_start.start);
    try std.testing.expectEqual(@as(usize, 80), shrunk_start.len);

    const shrunk_end = region.shrinkEnd(20);
    try std.testing.expectEqual(@as(usize, 100), shrunk_end.start);
    try std.testing.expectEqual(@as(usize, 80), shrunk_end.len);

    const expanded_end = region.expandEnd(50);
    try std.testing.expectEqual(@as(usize, 100), expanded_end.start);
    try std.testing.expectEqual(@as(usize, 150), expanded_end.len);
}

test "MemoryRegion alignment" {
    const region = MemoryRegion{ .start = 100, .len = 100 };

    try std.testing.expect(!region.isStartAligned(std.mem.Alignment.@"16"));
    try std.testing.expect(region.isStartAligned(std.mem.Alignment.@"4"));

    const aligned = region.alignStartUp(std.mem.Alignment.@"16");
    try std.testing.expectEqual(@as(usize, 112), aligned.start);
    try std.testing.expect(aligned.isStartAligned(std.mem.Alignment.@"16"));
}

test "MemoryRegion distanceTo" {
    const r1 = MemoryRegion{ .start = 100, .len = 50 };
    const r2 = MemoryRegion{ .start = 200, .len = 50 };
    const r3 = MemoryRegion{ .start = 120, .len = 50 };

    try std.testing.expectEqual(@as(?usize, 50), r1.distanceTo(r2));
    try std.testing.expect(r1.distanceTo(r3) == null); // overlapping
}

test "MemoryRegion format" {
    const region = MemoryRegion{ .start = 0x1000, .len = 256 };
    var buf: [128]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{f}", .{region});
    std.debug.print("Formatted region: {s}\n", .{str});
    try std.testing.expect(std.mem.indexOf(u8, str, "0x1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "256 B") != null);
}

test "MemoryRegion fromPtr" {
    var data: [100]u8 = undefined;
    const ptr = &data;
    const region = MemoryRegion.fromPtr(&data);
    try std.testing.expectEqual(@intFromPtr(ptr), region.start);
    // fromPtr records the size of the pointer type (can't recover the pointee size
    // from an untyped pointer), so expect pointer size (e.g. 8 bytes on x86_64).
    try std.testing.expectEqual(@as(usize, @sizeOf(@TypeOf(ptr))), region.len);
    try std.testing.expect(!region.isEmpty());

    // Verify the region contains the data's address
    try std.testing.expect(region.contains(@intFromPtr(ptr)));
    try std.testing.expect(!region.contains(@intFromPtr(ptr) + @sizeOf(@TypeOf(data))));
    try std.testing.expect(!region.contains(@intFromPtr(ptr) + 100)); // end is exclusive
}

test "MemoryRegion fromTypedPtr" {
    const TestStruct = struct {
        a: u32,
        b: u64,
        c: bool,
    };

    const instance = TestStruct{ .a = 42, .b = 123, .c = true };
    const region = MemoryRegion.fromTypedPtr(TestStruct, &instance);

    try std.testing.expectEqual(@intFromPtr(&instance), region.start);
    try std.testing.expectEqual(@sizeOf(TestStruct), region.len);
    try std.testing.expect(!region.isEmpty());
}

test "MemoryRegion fromRange" {
    // Normal range
    const region = MemoryRegion.fromRange(0x1000, 0x2000);
    try std.testing.expectEqual(@as(usize, 0x1000), region.start);
    try std.testing.expectEqual(@as(usize, 0x1000), region.len);
    try std.testing.expectEqual(@as(usize, 0x2000), region.end());
    try std.testing.expect(!region.isEmpty());

    // Empty range (start == end)
    const empty1 = MemoryRegion.fromRange(0x1000, 0x1000);
    try std.testing.expect(empty1.isEmpty());

    // Invalid range (end < start) should return empty
    const empty2 = MemoryRegion.fromRange(0x2000, 0x1000);
    try std.testing.expect(empty2.isEmpty());

    // Zero range
    const zero_region = MemoryRegion.fromRange(0, 100);
    try std.testing.expectEqual(@as(usize, 0), zero_region.start);
    try std.testing.expectEqual(@as(usize, 100), zero_region.len);
}

test "MemoryRegion fromSlice" {
    var buffer: [256]u8 = undefined;
    const slice: []u8 = buffer[50..150];
    const region = MemoryRegion.fromSlice(slice);

    try std.testing.expectEqual(@intFromPtr(slice.ptr), region.start);
    try std.testing.expectEqual(@as(usize, 100), region.len);

    // Empty slice
    const empty_slice: []u8 = buffer[0..0];
    const empty_region = MemoryRegion.fromSlice(empty_slice);
    try std.testing.expect(empty_region.isEmpty());
}

test "MemoryRegion toSlice and toPtr" {
    var buffer: [256]u8 = undefined;
    // Initialize just the endpoints we'll check to avoid integer-cast narrowing issues
    buffer[50] = 0x11;
    buffer[149] = 0x22;

    const slice: []u8 = buffer[50..150];
    const region_slice = MemoryRegion.fromSlice(slice);

    const s = region_slice.toSlice();
    const p = region_slice.toPtr();
    const back_to_region_from_slice = MemoryRegion.fromSlice(s);
    const back_to_region_from_ptr = MemoryRegion.fromPtrWithLen(p, region_slice.len);

    std.debug.print("Original region (slice): {f}, New region (slice): {f}\n", .{ region_slice, back_to_region_from_slice });
    std.debug.print("Original region (slice): {f}, New region (ptr): {f}\n", .{ region_slice, back_to_region_from_ptr });
    try std.testing.expectEqual(@intFromPtr(slice.ptr), @intFromPtr(s.ptr));
    try std.testing.expectEqual(@sizeOf(@TypeOf(slice)), @sizeOf(@TypeOf(s)));
    try std.testing.expectEqual(slice[0], s[0]);
    // `s.len` is the number of bytes returned by `toSlice` (which uses `sizeOf`); only
    // compare values that exist within that range.
    try std.testing.expectEqual(slice[s.len - 1], s[s.len - 1]);

    // Round-trip via slice preserves the full region
    try std.testing.expectEqual(region_slice.start, back_to_region_from_slice.start);
    try std.testing.expectEqual(region_slice.len, back_to_region_from_slice.len);

    // Round-trip via pointer with explicit length preserves the full region
    try std.testing.expectEqual(@intFromPtr(s.ptr), @intFromPtr(p));
    try std.testing.expectEqual(region_slice.start, back_to_region_from_ptr.start);
    try std.testing.expectEqual(region_slice.len, back_to_region_from_ptr.len);
}

test "ScopeMarker save and restore" {
    const StackAllocator = @import("../stack_allocator.zig").StackAllocator;

    var stack = StackAllocator.init(1024);
    var Marker = ScopeMarker(StackAllocator).init(&stack);
    const alloc = stack.allocator();

    // Initial state
    try std.testing.expectEqual(@as(usize, 0), stack.bytesUsed());

    // Allocate some memory
    const data1 = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), stack.bytesUsed());

    // Save the marker
    const marker = Marker.save();
    try std.testing.expectEqual(@as(usize, 100), marker.saved_index);

    // Allocate more memory
    const data2 = try alloc.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 150), stack.bytesUsed());

    _ = data1;
    _ = data2;

    // Restore to the saved state
    marker.restore();
    try std.testing.expectEqual(@as(usize, 100), stack.bytesUsed());

    // Can allocate again from the restored position
    const data3 = try alloc.alloc(u8, 25);
    try std.testing.expectEqual(@as(usize, 125), stack.bytesUsed());

    _ = data3;
}

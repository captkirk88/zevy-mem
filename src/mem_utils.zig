const std = @import("std");
const builtin = @import("builtin");

/// Check if a pointer is aligned to the given alignment
pub fn isAligned(ptr: anytype, alignment: usize) bool {
    const addr = switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => @intFromPtr(ptr),
        .int, .comptime_int => ptr,
        else => @compileError("Expected pointer or integer"),
    };
    return addr % alignment == 0;
}

/// Calculate the aligned size for a given size and alignment
pub fn alignedSize(size: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, size, alignment);
}

/// Calculate padding needed to align a size
pub fn alignmentPadding(size: usize, alignment: usize) usize {
    return alignedSize(size, alignment) - size;
}

const KB = 1024;
const MB = 1024 * KB;
const GB = 1024 * MB;
const TB = 1024 * GB;
const PB = 1024 * TB;

/// Human-readable byte size formatting
pub const ByteSize = struct {
    bytes: usize,

    /// Format the byte size into human-readable form.
    /// Examples: "512 B", "2.00 KiB", "3.00 MiB", "1.50 GiB"
    ///
    pub fn format(
        self: ByteSize,
        writer: *std.io.Writer,
    ) !void {
        if (self.bytes >= PB) {
            try writer.print("{d:.2} PiB", .{@as(f64, @floatFromInt(self.bytes)) / (PB)});
        } else if (self.bytes >= TB) {
            try writer.print("{d:.2} TiB", .{@as(f64, @floatFromInt(self.bytes)) / (TB)});
        } else if (self.bytes >= GB) {
            try writer.print("{d:.2} GiB", .{@as(f64, @floatFromInt(self.bytes)) / (GB)});
        } else if (self.bytes >= MB) {
            try writer.print("{d:.2} MiB", .{@as(f64, @floatFromInt(self.bytes)) / (MB)});
        } else if (self.bytes >= KB) {
            try writer.print("{d:.2} KiB", .{@as(f64, @floatFromInt(self.bytes)) / (KB)});
        } else {
            try writer.print("{d} B", .{self.bytes});
        }
    }
};

/// Create a human-readable ByteSize from a number of bytes
pub fn byteSize(bytes: usize) ByteSize {
    return .{ .bytes = bytes };
}

/// Memory region descriptor
pub const MemoryRegion = struct {
    start: usize,
    len: usize,

    /// Get the end address of the region
    pub fn end(self: MemoryRegion) usize {
        return self.start + self.len;
    }

    pub fn size(self: MemoryRegion) usize {
        return self.len;
    }

    /// Check if an address is contained within this region
    pub fn contains(self: MemoryRegion, addr: usize) bool {
        return addr >= self.start and addr < self.end();
    }

    /// Check if this region overlaps with another region
    pub fn overlaps(self: MemoryRegion, other: MemoryRegion) bool {
        return self.start < other.end() and other.start < self.end();
    }

    /// Create a MemoryRegion from a slice
    pub fn fromSlice(slice: []const u8) MemoryRegion {
        return .{
            .start = @intFromPtr(slice.ptr),
            .len = slice.len,
        };
    }

    /// Create a MemoryRegion from a pointer and length
    pub fn fromPtr(ptr: *const u8, len: usize) MemoryRegion {
        return .{
            .start = @intFromPtr(ptr),
            .len = len,
        };
    }
};

/// Scope marker for stack allocators - enables save/restore patterns
pub fn ScopeMarker(comptime AllocatorType: type) type {
    return struct {
        allocator: *AllocatorType,
        saved_index: usize,

        const Self = @This();

        pub fn save(alloc: *AllocatorType) Self {
            return .{
                .allocator = alloc,
                .saved_index = alloc.bytesUsed(),
            };
        }

        pub fn restore(self: Self) void {
            self.allocator.end_index = self.saved_index;
        }
    };
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
/// Only works in debug builds with debug info available.
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
    try std.testing.expect(isAligned(@as(usize, 0), 4));
    try std.testing.expect(isAligned(@as(usize, 4), 4));
    try std.testing.expect(isAligned(@as(usize, 8), 4));
    try std.testing.expect(!isAligned(@as(usize, 1), 4));
    try std.testing.expect(!isAligned(@as(usize, 3), 4));
}

test "alignedSize" {
    try std.testing.expectEqual(@as(usize, 4), alignedSize(1, 4));
    try std.testing.expectEqual(@as(usize, 4), alignedSize(4, 4));
    try std.testing.expectEqual(@as(usize, 8), alignedSize(5, 4));
    try std.testing.expectEqual(@as(usize, 16), alignedSize(13, 8));
}

test "alignmentPadding" {
    try std.testing.expectEqual(@as(usize, 3), alignmentPadding(1, 4));
    try std.testing.expectEqual(@as(usize, 0), alignmentPadding(4, 4));
    try std.testing.expectEqual(@as(usize, 3), alignmentPadding(5, 4));
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

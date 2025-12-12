const std = @import("std");
const interface = @import("interface").Interface;

/// An interface for an allocator that tracks the number of bytes used.
pub const TrackingAllocator = struct {
    pub fn bytesUsed(_: *const @This()) usize {
        return 0; // Default implementation returns 0
    }

    pub fn allocator(_: *const @This()) std.mem.Allocator {
        unreachable;
    }
};

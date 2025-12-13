const std = @import("std");

/// An interface for an allocator that tracks the number of bytes used.
pub const TrackingAllocator = struct {
    ptr: *anyopaque,

    pub fn bytesUsed(self: *const @This()) usize {
        return self.ptr.bytesUsed();
    }

    pub fn rewind(self: *const @This(), bytes: usize) void {
        self.ptr.rewind(bytes);
    }

    pub fn allocator(self: *const @This()) std.mem.Allocator {
        return self.ptr.allocator();
    }
};

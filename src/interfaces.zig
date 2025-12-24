const std = @import("std");
const reflect = @import("zevy_reflect");

pub const TrackingAllocatorTemplate = reflect.Template(struct {
    pub const Name: []const u8 = "TrackingAllocator";

    pub fn bytesUsed(_: *const @This()) usize {
        unreachable;
    }

    pub fn rewind(_: *@This(), _: usize) usize {
        unreachable;
    }

    pub fn allocator(_: *const @This()) std.mem.Allocator {
        unreachable;
    }
});

/// An interface for an allocator that tracks the number of bytes used.
pub const TrackingAllocator = TrackingAllocatorTemplate.Interface;

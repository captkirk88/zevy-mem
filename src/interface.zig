const std = @import("std");
const interface = @import("interface").Interface;

/// An interface for an allocator that tracks the number of bytes used.
pub const TrackingAllocator = interface(.{
    .bytesUsed = fn () usize,
    .allocator = fn () std.mem.Allocator,
    .end = fn () usize,
}, null);

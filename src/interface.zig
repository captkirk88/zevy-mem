const std = @import("std");
const interface = @import("interface").Interface;

pub const TrackingAllocator = interface(.{
    .bytesUsed = fn () usize,
    .allocator = fn () std.mem.Allocator,
}, null);

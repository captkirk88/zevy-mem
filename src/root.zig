//! zevy-mem: Memory allocators for Zig with no heap dependencies.
const std = @import("std");

pub const StackAllocator = @import("stack_allocator.zig").StackAllocator;
pub const DebugAllocator = @import("debug_allocator.zig").DebugAllocator;
pub const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
pub const PoolAllocator = @import("pool_allocator.zig").PoolAllocator;
pub const ScopedAllocator = @import("scoped_allocator.zig").ScopedAllocator;
pub const NestedScope = @import("scoped_allocator.zig").NestedScope;
pub const ThreadSafeAllocator = @import("threadsafe_allocator.zig").ThreadSafeAllocator;

pub const utils = @import("mem_utils.zig");
pub const isAligned = utils.isAligned;
pub const alignedSize = utils.alignedSize;
pub const alignmentPadding = utils.alignmentPadding;
pub const byteSize = utils.byteSize;
pub const ByteSize = utils.ByteSize;
pub const MemoryRegion = utils.MemoryRegion;

test {
    std.testing.refAllDeclsRecursive(@This());
}

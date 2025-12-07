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

pub fn toThreadSafe(allocator: anytype) ThreadSafeAllocator {
    const allocator_type = @TypeOf(allocator);
    if (allocator_type == std.mem.Allocator) {
        return ThreadSafeAllocator.init(allocator);
    } else if (@typeInfo(allocator_type) == .@"struct" and @hasDecl(allocator_type, "allocator")) {
        const decl_type_info = @typeInfo(@TypeOf(@field(allocator_type, "allocator")));
        if (decl_type_info == .@"fn" and decl_type_info.@"fn".return_type == std.mem.Allocator) {
            return ThreadSafeAllocator.init(@constCast(&allocator).allocator());
        }
    }
    @compileError("Unsupported allocator type: " ++ @typeName(allocator_type));
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "toThreadSafe works with various allocator types" {
    const sa = StackAllocator.init(1024);
    const tsa1 = toThreadSafe(sa);
    _ = tsa1;

    const da = DebugAllocator.init(std.heap.page_allocator);
    const tsa2 = toThreadSafe(da);
    _ = tsa2;

    const ca = CountingAllocator.init(std.heap.page_allocator);
    const tsa3 = toThreadSafe(ca);
    _ = tsa3;

    const tsa4 = ThreadSafeAllocator.init(std.heap.page_allocator);
    const tsa5 = toThreadSafe(tsa4);
    _ = tsa5;
}

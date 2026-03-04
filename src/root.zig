//! zevy-mem: Memory allocators for Zig with no heap dependencies.
const std = @import("std");
const builtin = @import("builtin");
const reflect = @import("zevy_reflect");
const mem = @import("utils/root.zig");

pub const interfaces = @import("interfaces.zig");

pub const allocators = struct {
    const stack_allocator_impl = struct {
        pub var stack_allocator: StackAllocator = undefined;
    };
    /// A global StackAllocator instance for general use
    ///
    /// Size: 10 MB
    pub const stack_allocator = StackAllocator.init(10 * 1024 * 1024).allocator(); // 10 MiB stack allocator

    /// Utility function to create a TypeFilterAllocator with the given types.
    pub fn typeFilter(comptime types: []const type, specific: std.mem.Allocator, fallback: std.mem.Allocator) allocators.TypeFilterAllocator(types) {
        return allocators.TypeFilterAllocator(types).init(specific, fallback);
    }

    pub const StackAllocator = @import("stack_allocator.zig").StackAllocator;
    pub const DebugAllocator = @import("debug_allocator.zig").DebugAllocator;
    pub const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
    pub const PoolAllocator = @import("pool_allocator.zig").PoolAllocator;
    pub const ScopedAllocator = @import("scoped_allocator.zig").ScopedAllocator;
    pub const NestedScope = @import("scoped_allocator.zig").NestedScope;
    pub const CautiousAllocator = @import("cautious_allocator.zig").CautiousAllocator;
    pub const SafeAllocator = @import("safe_allocator.zig").SafeAllocator;
    pub const GuardedAllocator = @import("guarded_allocator.zig").GuardedAllocator;
    pub const MmapAllocator = @import("mmap_allocator.zig").MmapAllocator;
    pub const TypeFilterAllocator = @import("type_filter_allocator.zig").TypeFilterAllocator;
};
pub const mmap = @import("platform_mmap.zig");

pub const utils = @import("utils/root.zig");

/// Synchronization primitives
pub const lock = struct {
    pub const RwLock = @import("lock/rwlock.zig").RwLock;
    pub const Mutex = @import("lock/mutex.zig").Mutex;
    pub const Pin = @import("lock/pin.zig").Pin;
    pub const LazyMutex = @import("lock/lazymutex.zig").LazyMutex;
};

pub const Lazy = @import("lazy.zig").Lazy;

/// Pointer types
pub const pointers = struct {
    pub const Rc = @import("pointers/rc.zig").Rc;
    pub const Arc = @import("pointers/arc.zig").Arc;
    pub const ArcMutex = @import("pointers/arc.zig").ArcMutex;
    pub const ArcRwLock = @import("pointers/arc.zig").ArcRwLock;
};

test {
    std.testing.refAllDecls(@This());
}

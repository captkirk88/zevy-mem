//! zevy-mem: Memory allocators for Zig with no heap dependencies.
const std = @import("std");
const builtin = @import("builtin");
const reflect = @import("zevy_reflect");
const mem = @import("utils/root.zig");

pub const interfaces = @import("interfaces.zig");

pub const allocators = struct {
    /// A global StackAllocator instance for general use
    ///
    /// Size: 10 MB
    pub const stack_allocator = StackAllocator.init(10 * 1024 * 1024); // 10 MiB stack allocator

    const cautiousWarnFn = struct {
        fn warn(projected: usize, hard_limit: usize) void {
            std.debug.print("CautiousAllocator: soft memory limit reached ({f}/{f})\n", .{ mem.byteSize(projected), mem.byteSize(hard_limit) });
        }
    }.warn;
    /// A global CautiousAllocator instance for general use
    ///
    /// Soft limit: 20 MB
    ///
    /// Hard limit: 30 MB
    ///
    /// Abort on soft limit: false
    pub const cautious_allocator = CautiousAllocator.init(std.heap.page_allocator, 20 * 1024 * 1024, 30 * 1024 * 1024, false, cautiousWarnFn);

    /// A global CountingAllocator instance for general use
    pub const counting_allocator = CountingAllocator.init(std.heap.page_allocator);

    pub const guarded_allocator = GuardedAllocator.init(std.heap.page_allocator, std.heap.c_allocator, 1);

    pub const safe_allocator = SafeAllocator.init(std.heap.page_allocator, std.heap.page_allocator);

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

pub const Mutex = @import("mutex.zig").Mutex;

pub const pointers = struct {
    pub const Rc = @import("pointers/rc.zig").Rc;
    pub const Arc = @import("pointers/arc.zig").Arc;

    pub fn initArcWithMutex(allocator: std.mem.Allocator, value: anytype) !*Arc(*Mutex(@TypeOf(value))) {
        const ValueType = @TypeOf(value);
        const mutex_ptr = try Mutex(ValueType).init(allocator, value);
        return Arc(*Mutex(ValueType)).init(allocator, mutex_ptr);
    }
};

pub fn toThreadSafe(allocator: anytype) std.heap.ThreadSafeAllocator {
    const allocator_type = @TypeOf(allocator);
    if (allocator_type == std.mem.Allocator) {
        return std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
    } else {
        if (reflect.hasFunc(allocator_type, "allocator")) {
            const child_alloc = @constCast(allocator).allocator();
            return std.heap.ThreadSafeAllocator{ .child_allocator = child_alloc };
        }
    }
    @compileError("Unsupported allocator type: " ++ @typeName(allocator_type));
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "toThreadSafe works with various allocator types" {
    var sa = allocators.StackAllocator.init(1024);
    defer sa.reset();
    const tsa1 = toThreadSafe(&sa);
    _ = tsa1;

    var da = allocators.DebugAllocator.init(std.heap.page_allocator);
    defer da.deinit();
    const tsa2 = toThreadSafe(&da);
    _ = tsa2;

    var ca = allocators.CountingAllocator.init(std.heap.page_allocator);
    defer ca.reset();
    const tsa3 = toThreadSafe(&ca);
    _ = tsa3;
}

test "initArcWithMutex - multithreaded mutation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_value: i32 = 0;
    const arc = try pointers.initArcWithMutex(allocator, init_value);
    defer arc.deinit();

    const ThreadContext = struct {
        arc_ptr: *pointers.Arc(*Mutex(i32)),
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: ThreadContext) void {
            const local_arc = ctx.arc_ptr.clone();
            defer local_arc.deinit();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var guard = local_arc.get().*.lock();
                guard.get().* += 1;
                // release the lock early so we can sleep outside the critical section
                guard.deinit();

                // occasionally sleep to increase thread interleavings and help expose race conditions
                if (i % 17 == 0) {
                    // sleep for ~1ms
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                }
            }
        }
    }.run;

    const thread_count = 8;
    const iterations = 1000;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ThreadContext{
            .arc_ptr = arc,
            .iterations = iterations,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    // Verify the final value
    {
        const guard = arc.get().*.lock();
        defer guard.deinit();
        const final_count = guard.get().*;
        try testing.expectEqual(thread_count * iterations, final_count);
    }

    try testing.expectEqual(1, arc.strongCount());
}

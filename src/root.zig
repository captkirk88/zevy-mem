//! zevy-mem: Memory allocators for Zig with no heap dependencies.
const std = @import("std");
const builtin = @import("builtin");

pub const StackAllocator = @import("stack_allocator.zig").StackAllocator;
pub const DebugAllocator = @import("debug_allocator.zig").DebugAllocator;
pub const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
pub const PoolAllocator = @import("pool_allocator.zig").PoolAllocator;
pub const ScopedAllocator = @import("scoped_allocator.zig").ScopedAllocator;
pub const NestedScope = @import("scoped_allocator.zig").NestedScope;
pub const CautiousAllocator = @import("cautious_allocator.zig").CautiousAllocator;
pub const SafeAllocator = @import("safe_allocator.zig").SafeAllocator;
pub const GuardedAllocator = @import("guarded_allocator.zig").GuardedAllocator;
pub const FileAllocator = @import("file_allocator.zig").FileAllocator;

pub const utils = @import("utils/root.zig");

pub const Mutex = @import("mutex.zig").Mutex;

// Safe Pointers
pub const Rc = @import("pointers/rc.zig").Rc;
pub const Arc = @import("pointers/arc.zig").Arc;

pub fn initArcWithMutex(allocator: std.mem.Allocator, value: anytype) !*Arc(*Mutex(@TypeOf(value))) {
    const ValueType = @TypeOf(value);
    const mutex_ptr = try Mutex(ValueType).init(allocator, value);
    return Arc(*Mutex(ValueType)).init(allocator, mutex_ptr);
}

pub fn toThreadSafe(allocator: anytype) std.heap.ThreadSafeAllocator {
    const allocator_type = @TypeOf(allocator);
    if (allocator_type == std.mem.Allocator) {
        return std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
    } else if (allocator_type == *StackAllocator or allocator_type == *const StackAllocator) {
        const sa: *StackAllocator = @ptrCast(@constCast(allocator));
        return std.heap.ThreadSafeAllocator{
            .child_allocator = sa.allocator(),
        };
    } else if (allocator_type == *DebugAllocator or allocator_type == *const DebugAllocator) {
        const da: *DebugAllocator = @ptrCast(@constCast(allocator));
        return std.heap.ThreadSafeAllocator{
            .child_allocator = da.allocator(),
        };
    } else if (allocator_type == *CountingAllocator or allocator_type == *const CountingAllocator) {
        const ca: *CountingAllocator = @ptrCast(@constCast(allocator));
        return std.heap.ThreadSafeAllocator{
            .child_allocator = ca.allocator(),
        };
    } else if (allocator_type == *CautiousAllocator or allocator_type == *const CautiousAllocator) {
        const ca: *CautiousAllocator = @ptrCast(@constCast(allocator));
        return std.heap.ThreadSafeAllocator{
            .child_allocator = ca.allocator(),
        };
    } else if (allocator_type == *SafeAllocator or allocator_type == *const SafeAllocator) {
        const sa: *SafeAllocator = @ptrCast(@constCast(allocator));
        return std.heap.ThreadSafeAllocator{
            .child_allocator = sa.allocator(),
        };
    } else if (allocator_type == *GuardedAllocator or allocator_type == *const GuardedAllocator) {
        const ga: *GuardedAllocator = @ptrCast(@constCast(allocator));
        return std.heap.ThreadSafeAllocator{
            .child_allocator = ga.allocator(),
        };
    } else if (allocator_type == *FileAllocator or allocator_type == *const FileAllocator) {
        const fa: *FileAllocator = @ptrCast(@constCast(allocator));
        return std.heap.ThreadSafeAllocator{
            .child_allocator = fa.allocator(),
        };
    }
    @compileError("Unsupported allocator type: " ++ @typeName(allocator_type));
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "toThreadSafe works with various allocator types" {
    const sa = StackAllocator.init(1024);
    const tsa1 = toThreadSafe(&sa);
    _ = tsa1;

    const da = DebugAllocator.init(std.heap.page_allocator);
    const tsa2 = toThreadSafe(&da);
    _ = tsa2;

    const ca = CountingAllocator.init(std.heap.page_allocator);
    const tsa3 = toThreadSafe(&ca);
    _ = tsa3;
}

test "initArcWithMutex - multithreaded mutation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_value: i32 = 0;
    const arc = try initArcWithMutex(allocator, init_value);
    defer arc.deinit();

    const ThreadContext = struct {
        arc_ptr: *Arc(*Mutex(i32)),
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

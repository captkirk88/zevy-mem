const std = @import("std");
const Allocator = std.mem.Allocator;

/// A thread-safe allocator wrapper that protects an underlying allocator with a mutex.
/// All allocation operations are serialized through the mutex.
pub const ThreadSafeAllocator = struct {
    const Self = @This();

    inner: Allocator,
    mutex: std.Thread.Mutex,

    /// Initialize with a backing allocator.
    pub fn init(backing_allocator: Allocator) Self {
        return .{
            .inner = backing_allocator,
            .mutex = .{},
        };
    }

    /// Get the thread-safe allocator interface.
    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Get direct access to the underlying allocator (not thread-safe).
    /// Use with caution - only when you know no other threads are accessing.
    pub fn getInner(self: *Self) Allocator {
        return self.inner;
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        return self.inner.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        return self.inner.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        return self.inner.rawRemap(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        self.inner.rawFree(buf, buf_align, ret_addr);
    }
};

// ============================================================================
// Tests
// ============================================================================

/// Helper for running concurrent allocation tests.
/// Spawns worker threads and also runs operations on the main thread.
fn runConcurrentTest(
    comptime num_worker_threads: usize,
    alloc: Allocator,
    comptime WorkerFn: fn (Allocator, usize) anyerror!void,
) !void {
    var threads: [num_worker_threads]std.Thread = undefined;

    // Spawn worker threads (IDs 0 to num_worker_threads-1)
    for (&threads, 0..) |*t, thread_id| {
        t.* = try std.Thread.spawn(.{}, WorkerFn, .{ alloc, thread_id });
    }

    // Run operations on main thread (ID = num_worker_threads)
    try WorkerFn(alloc, num_worker_threads);

    // Wait for all worker threads to complete
    for (&threads) |*t| {
        t.join();
    }
}

test "basic thread-safe allocation" {
    var ts_alloc = ThreadSafeAllocator.init(std.testing.allocator);
    const alloc = ts_alloc.allocator();

    const slice = try alloc.alloc(u8, 100);
    defer alloc.free(slice);

    try std.testing.expectEqual(@as(usize, 100), slice.len);
}

test "thread-safe resize" {
    var ts_alloc = ThreadSafeAllocator.init(std.testing.allocator);
    const alloc = ts_alloc.allocator();

    const slice = try alloc.alloc(u8, 50);
    defer alloc.free(slice);

    // Try to resize (may or may not succeed depending on allocator)
    if (alloc.resize(slice, 100)) {
        try std.testing.expectEqual(@as(usize, 100), slice.len);
    }
}

test "thread-safe realloc" {
    var ts_alloc = ThreadSafeAllocator.init(std.testing.allocator);
    const alloc = ts_alloc.allocator();

    var slice = try alloc.alloc(u8, 50);
    slice = try alloc.realloc(slice, 100);
    defer alloc.free(slice);

    try std.testing.expectEqual(@as(usize, 100), slice.len);
}

test "concurrent allocations with main thread" {
    var ts_alloc = ThreadSafeAllocator.init(std.testing.allocator);
    const alloc = ts_alloc.allocator();

    const allocs_per_thread = 50;

    try runConcurrentTest(3, alloc, struct {
        fn worker(a: Allocator, thread_id: usize) !void {
            var slices: [allocs_per_thread][]u8 = undefined;

            // Allocate with thread-specific sizes
            for (&slices, 0..) |*s, i| {
                const size = ((thread_id + 1) * 8) + (i * 4);
                s.* = a.alloc(u8, size) catch unreachable;
                @memset(s.*, @truncate(thread_id));
            }

            // Verify data integrity
            for (slices, 0..) |s, i| {
                _ = i;
                for (s) |byte| {
                    try std.testing.expect(byte == @as(u8, @truncate(thread_id)));
                }
            }

            // Free in reverse order
            var i: usize = allocs_per_thread;
            while (i > 0) {
                i -= 1;
                a.free(slices[i]);
            }
        }
    }.worker);
}

test "concurrent mixed operations with main thread" {
    var ts_alloc = ThreadSafeAllocator.init(std.testing.allocator);
    const alloc = ts_alloc.allocator();

    try runConcurrentTest(3, alloc, struct {
        fn worker(a: Allocator, thread_id: usize) !void {
            var prng = std.Random.DefaultPrng.init(thread_id);
            const random = prng.random();

            var i: usize = 0;
            while (i < 30) : (i += 1) {
                const size = random.intRangeAtMost(usize, 1, 256);
                const slice = a.alloc(u8, size) catch unreachable;
                @memset(slice, @truncate(thread_id));

                // Verify our data wasn't corrupted by other threads
                for (slice) |byte| {
                    try std.testing.expect(byte == @as(u8, @truncate(thread_id)));
                }

                // Sometimes realloc
                if (random.boolean()) {
                    const new_size = random.intRangeAtMost(usize, 1, 512);
                    const new_slice = a.realloc(slice, new_size) catch unreachable;
                    // Fill new portion if grown
                    @memset(new_slice, @truncate(thread_id));
                    a.free(new_slice);
                } else {
                    a.free(slice);
                }
            }
        }
    }.worker);
}

test "concurrent rapid alloc-free cycles with main thread" {
    var ts_alloc = ThreadSafeAllocator.init(std.testing.allocator);
    const alloc = ts_alloc.allocator();

    try runConcurrentTest(4, alloc, struct {
        fn worker(a: Allocator, thread_id: usize) !void {
            // Rapid alloc-free cycles to stress the mutex
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const size = (thread_id + 1) * 16 + i;
                const slice = a.alloc(u8, size) catch unreachable;
                @memset(slice, 0xCD);
                a.free(slice);
            }
        }
    }.worker);
}

test "concurrent varying sizes with main thread" {
    var ts_alloc = ThreadSafeAllocator.init(std.testing.allocator);
    const alloc = ts_alloc.allocator();

    try runConcurrentTest(2, alloc, struct {
        fn worker(a: Allocator, thread_id: usize) !void {
            // Test with varying allocation sizes
            const sizes = [_]usize{ 1, 7, 16, 64, 128, 255, 512, 1024 };

            for (sizes) |size| {
                const actual_size = size + thread_id;
                const slice = a.alloc(u8, actual_size) catch unreachable;
                @memset(slice, @truncate(thread_id));

                // Verify
                for (slice) |byte| {
                    try std.testing.expect(byte == @as(u8, @truncate(thread_id)));
                }

                a.free(slice);
            }
        }
    }.worker);
}

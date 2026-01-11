const std = @import("std");
const reflect = @import("zevy_reflect");
const Allocator = std.mem.Allocator;

/// Internal read-write lock state (writers-preference to avoid starvation)
const RwLockState = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    readers: usize = 0,
    writers_waiting: usize = 0,
    writing: bool = false,

    pub fn lockRead(self: *RwLockState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.writing or self.writers_waiting > 0) {
            self.cond.wait(&self.mutex);
        }
        self.readers += 1;
    }

    pub fn tryLockRead(self: *RwLockState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.writing or self.writers_waiting > 0) return false;
        self.readers += 1;
        return true;
    }

    pub fn unlockRead(self: *RwLockState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.readers -= 1;
        if (self.readers == 0) {
            self.cond.signal();
        }
    }

    pub fn lockWrite(self: *RwLockState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.writers_waiting += 1;
        while (self.readers > 0 or self.writing) {
            self.cond.wait(&self.mutex);
        }
        self.writers_waiting -= 1;
        self.writing = true;
    }

    pub fn tryLockWrite(self: *RwLockState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.readers > 0 or self.writing) return false;
        self.writing = true;
        return true;
    }

    pub fn unlockWrite(self: *RwLockState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.writing = false;
        self.cond.broadcast();
    }
};

/// Thread-safe read-write lock protected pointer.
pub fn RwLock(comptime T: type) type {
    return opaque {
        const Self = @This();

        /// The inner type wrapped by this RwLock
        pub const Child = T;

        const Inner = struct {
            value: T,
            rwlock: RwLockState,
            allocator: Allocator,

            fn deinit(self: *Inner) void {
                // Call deinit if the type has one
                switch (comptime reflect.getReflectInfo(T)) {
                    .type => |ti| {
                        if (ti.hasFunc("deinit")) {
                            self.value.deinit();
                        }
                    },
                    .raw => |ty| {
                        if (reflect.hasFunc(ty, "deinit")) {
                            self.value.deinit();
                        }
                    },
                    else => {},
                }
            }
        };

        /// Guard for scoped read access
        pub const ReadGuard = struct {
            inner: *Inner,
            value_ptr: *const T,

            /// Release the read lock
            ///
            /// Must be called when done with the protected value
            pub fn deinit(self: ReadGuard) void {
                self.inner.rwlock.unlockRead();
            }

            /// Get the protected value
            pub fn get(self: ReadGuard) *const T {
                return self.value_ptr;
            }
        };

        /// Guard for scoped write access
        pub const WriteGuard = struct {
            inner: *Inner,
            value_ptr: *T,

            /// Release the write lock
            ///
            /// Must be called when done with the protected value
            pub fn deinit(self: WriteGuard) void {
                self.inner.rwlock.unlockWrite();
            }

            /// Get the protected value
            pub fn get(self: WriteGuard) *T {
                return self.value_ptr;
            }
        };

        /// Create a new RwLock with initial value
        ///
        /// Call `deinit` on the Guards when done with the protected value
        pub fn init(allocator: Allocator, value: T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = value,
                .rwlock = .{},
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Lock for read access and get a guard
        pub fn lockRead(self: *Self) ReadGuard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            inner.rwlock.lockRead();
            return ReadGuard{
                .inner = inner,
                .value_ptr = &inner.value,
            };
        }

        /// Try to lock for read access and get a guard
        pub fn tryLockRead(self: *Self) ?ReadGuard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            if (inner.rwlock.tryLockRead()) {
                return ReadGuard{
                    .inner = inner,
                    .value_ptr = &inner.value,
                };
            }
            return null;
        }

        /// Lock for write access and get a guard
        pub fn lockWrite(self: *Self) WriteGuard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            inner.rwlock.lockWrite();
            return WriteGuard{
                .inner = inner,
                .value_ptr = &inner.value,
            };
        }

        /// Try to lock for write access and get a guard
        pub fn tryLockWrite(self: *Self) ?WriteGuard {
            const inner: *Inner = @ptrCast(@alignCast(self));
            if (inner.rwlock.tryLockWrite()) {
                return WriteGuard{
                    .inner = inner,
                    .value_ptr = &inner.value,
                };
            }
            return null;
        }

        /// Free the RwLock
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));

            inner.deinit();

            const allocator = inner.allocator;
            allocator.destroy(inner);
        }
    };
}
// Tests
test "RwLock concurrent readers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const lock = try RwLock(i32).init(allocator, 42);
    defer lock.deinit();

    const ThreadContext = struct {
        lock_ptr: *RwLock(i32),
        concurrent_ptr: *usize,
        max_concurrent_ptr: *usize,
        cnt_mutex_ptr: *std.Thread.Mutex,
    };

    const reader = struct {
        fn run(ctx: ThreadContext) void {
            var g = ctx.lock_ptr.lockRead();

            // increment concurrent and update max under mutex
            ctx.cnt_mutex_ptr.lock();
            ctx.concurrent_ptr.* += 1;
            if (ctx.concurrent_ptr.* > ctx.max_concurrent_ptr.*) {
                ctx.max_concurrent_ptr.* = ctx.concurrent_ptr.*;
            }
            ctx.cnt_mutex_ptr.unlock();

            // hold the read lock for a short while to increase chance of overlap
            std.Thread.sleep(5 * std.time.ns_per_ms);

            _ = g.get().*; // read
            g.deinit();

            ctx.cnt_mutex_ptr.lock();
            ctx.concurrent_ptr.* -= 1;
            ctx.cnt_mutex_ptr.unlock();
        }
    }.run;

    var concurrent: usize = 0;
    var max_concurrent: usize = 0;
    var cnt_mutex: std.Thread.Mutex = .{};

    const thread_count = 8;
    var threads: [thread_count]std.Thread = undefined;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, reader, .{ThreadContext{
            .lock_ptr = lock,
            .concurrent_ptr = &concurrent,
            .max_concurrent_ptr = &max_concurrent,
            .cnt_mutex_ptr = &cnt_mutex,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    const observed_max = max_concurrent;
    try testing.expect(observed_max > 1);
}

test "RwLock writer progress with busy readers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const lock = try RwLock(i32).init(allocator, 0);
    defer lock.deinit();

    var stop_flag: bool = false;
    var stop_mutex: std.Thread.Mutex = .{};
    var write_count: usize = 0;

    const reader = struct {
        fn run(lock_ptr: *RwLock(i32), stop_ptr: *bool, stop_mutex_ptr: *std.Thread.Mutex) void {
            while (true) {
                stop_mutex_ptr.lock();
                const s = stop_ptr.*;
                stop_mutex_ptr.unlock();
                if (s) break;

                var g = lock_ptr.lockRead();
                std.Thread.sleep(2 * std.time.ns_per_ms);
                _ = g.get().*;
                g.deinit();
                std.Thread.yield() catch {};
            }
        }
    }.run;

    const writer = struct {
        fn run(lock_ptr: *RwLock(i32), write_count_ptr: *usize, target: usize) void {
            while (write_count_ptr.* < target) {
                var g = lock_ptr.lockWrite();
                g.get().* += 1;
                g.deinit();
                write_count_ptr.* += 1;
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }.run;

    const reader_threads = 4;
    var rthreads: [reader_threads]std.Thread = undefined;
    var i: usize = 0;
    while (i < reader_threads) : (i += 1) {
        rthreads[i] = try std.Thread.spawn(.{}, reader, .{ lock, &stop_flag, &stop_mutex });
    }

    const target_writes: usize = 3;
    var wthread = try std.Thread.spawn(.{}, writer, .{ lock, &write_count, target_writes });

    // wait for writer to finish
    wthread.join();

    // signal readers to stop
    stop_mutex.lock();
    stop_flag = true;
    stop_mutex.unlock();

    for (rthreads) |thread| {
        thread.join();
    }

    const writes_done = write_count;
    try testing.expectEqual(target_writes, writes_done);
}

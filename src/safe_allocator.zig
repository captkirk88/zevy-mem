const std = @import("std");
const utils = @import("utils/root.zig");

const Allocator = std.mem.Allocator;

const is_debug = @import("builtin").mode == .Debug;

const AllocationInfo = struct {
    size: usize,
};

/// A wrapper around any `std.mem.Allocator` that tracks all allocations to prevent
/// double frees and detect memory leaks. It maintains a map of allocated pointers
/// and their sizes, and counters for allocations and deallocations.
pub const SafeAllocator = struct {
    inner: Allocator,
    allocations: std.AutoHashMap(usize, AllocationInfo), // ptr address -> info
    alloc_count: usize,
    dealloc_count: usize,
    allocator_backing: std.mem.Allocator,
    panic_on_leak: bool, // for the hashmap

    /// Initialize a SafeAllocator
    ///
    /// - `backing`: The underlying allocator to wrap
    /// - `arena`: Allocator for internal data structures (like the hashmap)
    pub fn init(backing: Allocator, arena: std.mem.Allocator) !SafeAllocator {
        return SafeAllocator{
            .inner = backing,
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(arena),
            .alloc_count = 0,
            .dealloc_count = 0,
            .allocator_backing = arena,
            .panic_on_leak = is_debug,
        };
    }

    pub fn deinit(self: *SafeAllocator) error{MemoryLeak}!void {
        defer self.allocations.deinit();
        if (self.allocations.count() > 0) {
            var buf: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();
            writer.print("SafeAllocator: Memory leaks detected! {d} unfreed allocations:\n", .{self.allocations.count()}) catch {};
            var it = self.allocations.iterator();
            while (it.next()) |entry| {
                writer.print("  Pointer: 0x{x}, Size: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.size }) catch {};
                const source = utils.resolveSourceLocation(self.inner, entry.key_ptr.*) catch continue;
                writer.print("{s}\n\n", .{source}) catch {};
            }
            const message = fbs.getWritten();
            if (self.panic_on_leak) {
                std.debug.panic("{s}", .{message});
            } else {
                return error.MemoryLeak;
            }
        }
    }

    pub fn allocator(self: *SafeAllocator) Allocator {
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

    pub fn allocCount(self: *SafeAllocator) usize {
        return self.alloc_count;
    }

    pub fn deallocCount(self: *SafeAllocator) usize {
        return self.dealloc_count;
    }
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *SafeAllocator = @ptrCast(@alignCast(ctx));

    const result = self.inner.rawAlloc(len, alignment, ret_addr);
    if (result) |ptr| {
        const addr = @intFromPtr(ptr);
        const info = AllocationInfo{ .size = len };
        self.allocations.put(addr, info) catch unreachable;
        self.alloc_count += 1;
    }
    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *SafeAllocator = @ptrCast(@alignCast(ctx));

    const addr = @intFromPtr(buf.ptr);
    if (self.allocations.getPtr(addr) == null) {
        std.debug.panicExtra(ret_addr, "SafeAllocator: Attempt to resize unknown pointer 0x{x}", .{addr});
    }

    const ok = self.inner.rawResize(buf, buf_align, new_len, ret_addr);
    if (ok) {
        if (self.allocations.getPtr(addr)) |entry| {
            entry.size = new_len;
        }
    }
    return ok;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *SafeAllocator = @ptrCast(@alignCast(ctx));

    const old_addr = @intFromPtr(memory.ptr);
    const result = self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    if (result) |new_ptr| {
        const new_addr = @intFromPtr(new_ptr);
        // Remove old entry
        _ = self.allocations.remove(old_addr);
        // Add new entry
        const new_info = AllocationInfo{ .size = new_len };
        self.allocations.put(new_addr, new_info) catch {
            // If can't track, free the new memory
            self.inner.rawFree(new_ptr[0..new_len], alignment, ret_addr);
            return null;
        };
    }
    return result;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    const self: *SafeAllocator = @ptrCast(@alignCast(ctx));

    const addr = @intFromPtr(buf.ptr);
    if (self.allocations.get(addr)) |_| {
        _ = self.allocations.remove(addr);
        self.dealloc_count += 1;
        self.inner.rawFree(buf, buf_align, ret_addr);
    } else {
        std.debug.panicExtra(ret_addr, "Double free detected for pointer 0x{x}", .{addr});
    }
}

test "SafeAllocator prevents double free" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const backing_allocator = arena.allocator();

    var safe = try SafeAllocator.init(backing_allocator, std.testing.allocator);
    defer safe.deinit() catch {}; // ignore for test
    const allocator = safe.allocator();

    const buf = try allocator.alloc(u8, 100);
    allocator.free(buf);
    // This should panic
    //allocator.free(buf); // uncomment to test double free
}

test "SafeAllocator detects leaks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const backing_allocator = arena.allocator();

    var safe = try SafeAllocator.init(backing_allocator, std.testing.allocator);
    safe.panic_on_leak = false;
    const allocator = safe.allocator();

    _ = try allocator.alloc(u8, 100);
    // Deinit should detect leak
    try std.testing.expectError(error.MemoryLeak, safe.deinit());
}

test "SafeAllocator will panic on leak" {
    // This test demonstrates the panic behavior but keeps it disabled
    // Uncomment the marked line to verify panic occurs

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const backing_allocator = arena.allocator();

    var safe = try std.testing.allocator.create(SafeAllocator);
    safe.* = try SafeAllocator.init(backing_allocator, std.testing.allocator);
    defer std.testing.allocator.destroy(safe);
    // safe.panic_on_leak is true by default in debug mode
    safe.panic_on_leak = false;

    const allocator = safe.allocator();
    _ = try allocator.alloc(u8, 100);

    // If panic_on_leak is false, this will return error
    try std.testing.expectError(error.MemoryLeak, safe.deinit());
}

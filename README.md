# zevy-mem

A collection of memory allocators and utilities for Zig.

[license]: https://img.shields.io/github/license/captkirk88/zevy-mem?style=for-the-badge&logo=opensourcehardware&label=License&logoColor=C0CAF5&labelColor=414868&color=8c73cc

[![][license]](https://github.com/captkirk88/zevy-mem/blob/main/LICENSE)

[![Zig Version](https://img.shields.io/badge/zig-0.15.1+-blue.svg)](https://ziglang.org/)

## Features

- **Stack Allocator**: Fast bump allocator with LIFO freeing, supports heap-free operation with external buffers
- **Debug Allocator**: Full allocation tracking with leak detection, statistics, and source location resolution
- **Pool Allocator**: O(1) fixed-size object allocation with zero fragmentation
- **Scoped Allocator**: RAII-style allocation scopes with automatic cleanup
- **Counting Allocator**: Simple wrapper for tracking allocation counts and bytes
- **Thread-Safe Allocator**: Mutex-protected wrapper for any allocator
- **Memory Utilities**: Alignment helpers, byte formatting, and memory region tools
- **Zero External Dependencies**: Pure Zig implementation with no external dependencies

## Installation

Add to your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/captkirk88/zevy-mem
```

Then in your `build.zig`:

```zig
const zevy_mem = b.dependency("zevy_mem", .{});
exe.root_module.addImport("zevy_mem", zevy_mem.module("zevy_mem"));
```

## Quick Start

### Stack Allocator

```zig
const mem = @import("zevy_mem");

// Create with external buffer (no heap)
var buffer: [4096]u8 = undefined;
var stack = mem.StackAllocator.initBuffer(&buffer);
const allocator = stack.allocator();

// Allocate memory
const data = try allocator.alloc(u8, 100);
defer allocator.free(data);

// Check usage
std.debug.print("Used: {} bytes, Remaining: {} bytes\n", .{
    stack.bytesUsed(),
    stack.bytesRemaining(),
});
```

### Debug Allocator (Leak Detection)

```zig
const mem = @import("zevy_mem");

var debug = mem.DebugAllocator(64).init(std.heap.page_allocator);
const allocator = debug.allocator();

const a = try allocator.alloc(u8, 100);
const b = try allocator.alloc(u8, 200);

// Intentionally leak 'a'
allocator.free(b);

// Check for leaks
if (debug.detectLeaks()) {
    debug.dumpLeaks(); // Prints detailed leak report
}

// Get statistics
const stats = debug.getStats();
std.debug.print("Peak allocations: {}\n", .{stats.peak_active_allocations});
```

### Pool Allocator

```zig
const mem = @import("zevy_mem");

const Entity = struct {
    id: u32,
    x: f32,
    y: f32,
    active: bool,
};

// Create pool with external buffer
var buffer: [100]mem.PoolAllocator(Entity).Slot = undefined;
var pool = mem.PoolAllocator(Entity).initBuffer(&buffer); // .initHeap(...) for heap allocation

// O(1) allocation
const entity = pool.create(.{
    .id = 1,
    .x = 0.0,
    .y = 0.0,
    .active = true,
}).?;

// O(1) deallocation
pool.free(entity);

std.debug.print("Pool: {}/{} slots used\n", .{pool.count(), pool.capacity()});
```

### Scoped Allocator

```zig
const mem = @import("zevy_mem");

var buffer: [4096]u8 = undefined;
var stack = mem.StackAllocator.initBuffer(&buffer);

// Permanent allocation
const permanent = try stack.allocator().alloc(u8, 100);

// Scoped temporary allocations
{
    var scope = mem.ScopedAllocator.begin(&stack); // Save current state
    defer scope.end() catch {}; // Restore state, freeing all scope allocations

    const temp1 = try scope.allocator().alloc(u8, 500);
    const temp2 = try scope.allocator().alloc(u8, 300);
    // Use temp1 and temp2...
    _ = temp1;
    _ = temp2;
}

// Only 'permanent' remains allocated
std.debug.print("Bytes used: {}\n", .{stack.bytesUsed()}); // 100
_ = permanent;
```

### Nested Scopes

```zig
const mem = @import("zevy_mem");

var buffer: [4096]u8 = undefined;
var stack = mem.StackAllocator.initBuffer(&buffer);
var nested = mem.NestedScope(8).init(&stack);

// Level 0
_ = try nested.allocator().alloc(u8, 100);

// Push level 1
try nested.push();
_ = try nested.allocator().alloc(u8, 200);

// Push level 2
try nested.push();
_ = try nested.allocator().alloc(u8, 300);

// Pop back to level 1 (frees 300 bytes from level 2)
try nested.pop();
std.debug.print("Depth: {}, Bytes: {}\n", .{nested.currentDepth(), stack.bytesUsed()});

// Pop back to level 0 (frees 200 bytes from level 1)
try nested.pop();
```

### Thread-Safe Allocator

```zig
const mem = @import("zevy_mem");

// Wrap any allocator to make it thread-safe
var ts_alloc = mem.ThreadSafeAllocator.init(std.heap.page_allocator);
const allocator = ts_alloc.allocator();

// Safe to use from multiple threads
const data = try allocator.alloc(u8, 100);
defer allocator.free(data);
```

## Examples

### Game Frame Allocator Pattern

```zig
const mem = @import("zevy_mem");

const FrameAllocator = struct {
    stack: mem.StackAllocator,
    buffer: [1024 * 1024]u8, // 1MB per frame

    pub fn init() FrameAllocator {
        var self = FrameAllocator{
            .stack = undefined,
            .buffer = undefined,
        };
        self.stack = mem.StackAllocator.initBuffer(&self.buffer);
        return self;
    }

    pub fn allocator(self: *FrameAllocator) std.mem.Allocator {
        return self.stack.allocator();
    }

    pub fn reset(self: *FrameAllocator) void {
        self.stack.reset();
    }
};

// Usage in game loop
var frame_alloc = FrameAllocator.init();

while (running) {
    // All frame allocations automatically cleaned up
    defer frame_alloc.reset();

    const temp_data = try frame_alloc.allocator().alloc(u8, 1000);
    // Use temp_data for this frame...
    _ = temp_data;
}
```

### Component Pool for ECS

```zig
const mem = @import("zevy_mem");

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };

const ComponentPools = struct {
    positions: mem.PoolAllocator(Position),
    velocities: mem.PoolAllocator(Velocity),
    pos_buffer: [1000]mem.PoolAllocator(Position).Slot,
    vel_buffer: [1000]mem.PoolAllocator(Velocity).Slot,

    pub fn init() ComponentPools {
        var self: ComponentPools = undefined;
        self.positions = mem.PoolAllocator(Position).initBuffer(&self.pos_buffer);
        self.velocities = mem.PoolAllocator(Velocity).initBuffer(&self.vel_buffer);
        return self;
    }
};

var pools = ComponentPools.init();
const pos = pools.positions.create(.{ .x = 0, .y = 0, .z = 0 }).?;
const vel = pools.velocities.create(.{ .x = 1, .y = 0, .z = 0 }).?;
_ = pos;
_ = vel;
```

### Debug Memory Tracking

```zig
const mem = @import("zevy_mem");

pub fn runWithMemoryTracking() !void {
    var buffer: [64 * 1024]u8 = undefined;
    var debug = mem.DebugStackAllocator(256).initBuffer(&buffer);
    defer {
        if (debug.detectLeaks()) {
            debug.dumpLeaks();
            @panic("Memory leaks detected!");
        }
    }

    const allocator = debug.allocator();

    // Your code here...
    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);

    // Print final stats
    const stats = debug.getStats();
    std.debug.print("Peak memory: {} bytes\n", .{stats.peak_bytes_used});
    std.debug.print("Total allocations: {}\n", .{stats.total_allocations});
}
```

## Performance

| Allocator | Alloc | Free | Memory Overhead |
|-----------|-------|------|-----------------|
| StackAllocator | O(1) | O(1)* | 0 bytes |
| DebugAllocator | O(1) | O(n)** | ~72 bytes/allocation |
| PoolAllocator | O(1) | O(1) | max(sizeof(T), 8) per slot*** |
| ScopedAllocator | O(1) | O(1) | 24 bytes per scope |
| NestedScope | O(1) | O(1) | 16 bytes per depth level |
| CountingAllocator | O(1) | O(1) | 24 bytes (wrapper state) |
| ThreadSafeAllocator | O(1)**** | O(1)**** | ~40 bytes (mutex, platform-dependent) |

\* Only LIFO frees reclaim memory  
\** n = number of tracked allocations (linear search in `findAllocation`)  
\*** Slot size is `@max(@sizeOf(T), @sizeOf(?*anyopaque))` to accommodate the free list pointer  
\**** Plus mutex lock/unlock overhead; may block on contention

## Limitations

- **LIFO Freeing**: Stack allocators only reclaim memory for the most recent allocation
- **Fixed Capacity**: Pool and debug allocators have compile-time limits
- **No Thread Safety**: All allocators are single-threaded unless wrapped in ThreadSafeAllocator
- **Buffer Ownership**: Caller manages buffer lifetime

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request

## Related Projects

- [zevy-ecs](https://github.com/captkirk88/zevy-ecs) - Entity Component System framework
- [zevy-reflect](https://github.com/captkirk88/zevy-reflect) - Reflection and change detection

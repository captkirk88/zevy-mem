const std = @import("std");
const StackAllocator = @import("stack_allocator.zig").StackAllocator;

/// A scoped allocator that automatically restores to a saved state.
/// Useful for temporary allocations within a defined scope.
///
/// WARNING: Do not call `growBuffer` on the underlying StackAllocator
/// while a scope is active. This will cause undefined behavior.
pub const ScopedAllocator = struct {
    inner: *StackAllocator,
    saved_index: usize,
    saved_buffer_ptr: ?[*]u8,

    /// Create a new scope, saving the current allocation state.
    pub fn begin(base_allocator: *StackAllocator) ScopedAllocator {
        return .{
            .inner = base_allocator,
            .saved_index = base_allocator.bytesUsed(),
            .saved_buffer_ptr = if (base_allocator.buffer) |buf| buf.ptr else null,
        };
    }

    /// End the scope, restoring to the saved state.
    /// All allocations made within this scope are invalidated.
    ///
    /// Returns an error if the underlying buffer has changed.
    pub fn end(self: *ScopedAllocator) error{BufferChanged}!void {
        // Validate buffer hasn't changed
        const current_ptr: ?[*]u8 = if (self.inner.buffer) |buf| buf.ptr else null;

        if (self.saved_buffer_ptr != current_ptr) {
            // Buffer was changed during scope - this is a misuse
            return error.BufferChanged;
        }

        self.inner.end_index = self.saved_index;
    }

    /// Get the underlying allocator interface for making allocations.
    pub fn allocator(self: *ScopedAllocator) std.mem.Allocator {
        return self.inner.allocator();
    }

    /// Returns bytes allocated within this scope.
    pub fn scopeBytes(self: *const ScopedAllocator) usize {
        return self.inner.bytesUsed() - self.saved_index;
    }

    /// Check if the buffer has changed since scope began.
    pub fn bufferChanged(self: *const ScopedAllocator) bool {
        const current_ptr: ?[*]u8 = if (self.inner.buffer) |buf| buf.ptr else null;
        return self.saved_buffer_ptr != current_ptr;
    }
};

/// Nested scope support - allows hierarchical temporary allocations.
/// Supports automatic state restoration when popping scopes.
///
/// **WARNING: Do not call `growBuffer` on the underlying StackAllocator
/// while scopes are active. This will cause undefined behavior.**
///
/// Example:
/// ```zig
/// var buffer: [1024]u8 = undefined;
/// var stack = StackAllocator.initBuffer(&buffer);
/// var nested = NestedScope(4).init(&stack);
///
/// // Level 0
/// _ = try nested.allocator().alloc(u8, 50);
///
/// // Push level 1
/// try nested.push();
/// _ = try nested.allocator().alloc(u8, 100);
///
/// // Push level 2
/// try nested.push();
/// _ = try nested.allocator().alloc(u8, 200);
///
/// // Pop level 2 - restores to level 1 state
/// try nested.pop();
///
/// // Pop level 1 - restores to level 0 state
/// try nested.pop();
/// ```
pub fn NestedScope(comptime max_depth: usize) type {
    return struct {
        const Self = @This();

        const ScopeState = struct {
            index: usize,
            buffer_ptr: ?[*]u8,
        };

        inner: *StackAllocator,
        stack: [max_depth]ScopeState,
        depth: usize,

        pub fn init(stack_allocator: *StackAllocator) Self {
            return .{
                .inner = stack_allocator,
                .stack = [_]ScopeState{.{ .index = 0, .buffer_ptr = null }} ** max_depth,
                .depth = 0,
            };
        }

        /// Push a new scope level, saving the current allocation state.
        pub fn push(self: *Self) error{ScopeOverflow}!void {
            if (self.depth >= max_depth) {
                return error.ScopeOverflow;
            }
            self.stack[self.depth] = .{
                .index = self.inner.bytesUsed(),
                .buffer_ptr = if (self.inner.buffer) |buf| buf.ptr else null,
            };
            self.depth += 1;
        }

        /// Pop the current scope level, restoring allocations to the saved state.
        /// All allocations made since the last push are invalidated.
        pub fn pop(self: *Self) error{ ScopeUnderflow, BufferChanged }!void {
            if (self.depth == 0) {
                return error.ScopeUnderflow;
            }
            self.depth -= 1;

            const saved = self.stack[self.depth];
            const current_ptr: ?[*]u8 = if (self.inner.buffer) |buf| buf.ptr else null;

            if (saved.buffer_ptr != current_ptr) {
                return error.BufferChanged;
            }

            self.inner.end_index = saved.index;
        }

        /// Get the allocator interface.
        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.inner.allocator();
        }

        /// Current nesting depth.
        pub fn currentDepth(self: *const Self) usize {
            return self.depth;
        }

        /// Bytes used at current scope level (since last push).
        pub fn currentScopeBytes(self: *const Self) usize {
            if (self.depth == 0) {
                return self.inner.bytesUsed();
            }
            return self.inner.bytesUsed() - self.stack[self.depth - 1].index;
        }

        /// Check if buffer changed at current depth.
        pub fn bufferChanged(self: *const Self) bool {
            if (self.depth == 0) {
                return false;
            }
            const saved = self.stack[self.depth - 1];
            const current_ptr: ?[*]u8 = if (self.inner.buffer) |buf| buf.ptr else null;
            return saved.buffer_ptr != current_ptr;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "basic scoped allocation" {
    var buffer: [1024]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);

    // Allocate outside scope
    const outer = try stack.allocator().alloc(u8, 100);
    _ = outer;
    try std.testing.expectEqual(@as(usize, 100), stack.bytesUsed());

    // Begin scope
    var scope = ScopedAllocator.begin(&stack);

    // Allocate inside scope
    const inner = try scope.allocator().alloc(u8, 200);
    _ = inner;
    try std.testing.expectEqual(@as(usize, 300), stack.bytesUsed());
    try std.testing.expectEqual(@as(usize, 200), scope.scopeBytes());

    // End scope - inner allocation freed
    try scope.end();
    try std.testing.expectEqual(@as(usize, 100), stack.bytesUsed());
}

test "nested scopes" {
    var buffer: [1024]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    var nested = NestedScope(4).init(&stack);

    // Level 0
    _ = try nested.allocator().alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 50), stack.bytesUsed());

    // Push level 1
    try nested.push();
    _ = try nested.allocator().alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 150), stack.bytesUsed());
    try std.testing.expectEqual(@as(usize, 1), nested.currentDepth());
    try std.testing.expectEqual(@as(usize, 100), nested.currentScopeBytes());

    // Push level 2
    try nested.push();
    _ = try nested.allocator().alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 350), stack.bytesUsed());
    try std.testing.expectEqual(@as(usize, 2), nested.currentDepth());
    try std.testing.expectEqual(@as(usize, 200), nested.currentScopeBytes());

    // Pop level 2 - restores to 150 bytes
    try nested.pop();
    try std.testing.expectEqual(@as(usize, 150), stack.bytesUsed());

    // Pop level 1 - restores to 50 bytes
    try nested.pop();
    try std.testing.expectEqual(@as(usize, 50), stack.bytesUsed());
}

test "scope overflow" {
    var buffer: [256]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    var nested = NestedScope(2).init(&stack);

    try nested.push();
    try nested.push();
    try std.testing.expectError(error.ScopeOverflow, nested.push());
}

test "scope underflow" {
    var buffer: [256]u8 = undefined;
    var stack = StackAllocator.initBuffer(&buffer);
    var nested = NestedScope(4).init(&stack);

    try std.testing.expectError(error.ScopeUnderflow, nested.pop());
}

test "end detects buffer change" {
    var small_buffer: [100]u8 = undefined;
    var large_buffer: [500]u8 = undefined;

    var stack = StackAllocator.initBuffer(&small_buffer);
    var scope = ScopedAllocator.begin(&stack);

    // Allocate within scope
    _ = try scope.allocator().alloc(u8, 20);

    // Change buffer during scope (BAD!)
    try stack.growBuffer(&large_buffer);

    // Should detect the change
    try std.testing.expect(scope.bufferChanged());
    try std.testing.expectError(error.BufferChanged, scope.end());
}

test "nested scope detects buffer change" {
    var small_buffer: [100]u8 = undefined;
    var large_buffer: [500]u8 = undefined;

    var stack = StackAllocator.initBuffer(&small_buffer);
    var nested = NestedScope(4).init(&stack);

    try nested.push();
    _ = try nested.allocator().alloc(u8, 20);

    // Change buffer during scope
    try stack.growBuffer(&large_buffer);

    try std.testing.expect(nested.bufferChanged());
    try std.testing.expectError(error.BufferChanged, nested.pop());
}

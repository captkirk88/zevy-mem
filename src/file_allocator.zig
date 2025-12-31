const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FileAllocator = struct {
    const Self = @This();

    const FileHeader = struct {
        magic: [4]u8,
        version: u32,
        free_head: u64, // offset to first free block (0 == none)
        next_append: u64, // offset where to append a new block
    };

    const AllocationInfo = struct {
        offset: u64,
        len: usize,
        block_size: usize,
    };

    const FreeBlock = struct {
        offset: u64,
        size: usize,
    };

    file: std.fs.File,
    allocations: std.AutoHashMap(usize, AllocationInfo),
    free_list: std.ArrayList(FreeBlock),
    map_allocator: Allocator,
    header_cache: FileHeader,

    // Initialize with an already-opened file (read/write). If the file is empty, it will
    // initialize a header. The backing allocator is used to allocate returned buffers.
    pub fn init(file: std.fs.File, map_allocator: Allocator) !FileAllocator {
        var fa = FileAllocator{
            .file = file,
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(map_allocator),
            .free_list = try std.ArrayList(FreeBlock).initCapacity(map_allocator, 0),
            .map_allocator = map_allocator,
            .header_cache = FileHeader{ .magic = .{ 0, 0, 0, 0 }, .version = 0, .free_head = 0, .next_append = 0 },
        };

        // attempt to initialize header; if it fails, clean up created structures
        fa.ensureHeader() catch |err| {
            _ = fa.allocations.deinit();
            _ = fa.free_list.deinit(map_allocator);
            return err;
        };

        // populate in-memory header cache
        fa.header_cache = try fa.readHeader();
        return fa;
    }

    pub fn deinit(self: *FileAllocator) void {
        // free any remaining in-memory buffers tracked in allocations
        var it = self.allocations.iterator();
        while (it.next()) |entry| {
            const key_addr = entry.key_ptr.*;
            const info = entry.value_ptr.*;
            // rebuild slice to free using a pointer type that supports runtime slices
            const ptr: [*]u8 = @ptrFromInt(key_addr);
            const s: []u8 = ptr[0..info.len];
            _ = std.heap.page_allocator.free(s);
        }

        // deinit maps/lists
        self.allocations.deinit();
        _ = self.free_list.deinit(self.map_allocator);

        // Note: the file handle was provided by the caller; do not close it here.
    }

    pub fn allocator(self: *FileAllocator) Allocator {
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

    /// For testing / introspection: how many free blocks are tracked in-memory
    pub fn freeCount(self: *const FileAllocator) usize {
        return self.free_list.items.len;
    }

    fn ensureHeader(self: *FileAllocator) !void {
        const file = &self.file;
        // Try stat; if stat fails (access issues), fall back to attempting to read a header.
        const stat_res = file.stat() catch null;
        if (stat_res == null or stat_res.?.size == 0) {
            // either new file or unable to stat; try reading header bytes
            var header: FileHeader = undefined;
            var header_buf: [@sizeOf(FileHeader)]u8 = undefined;
            _ = file.seekTo(0) catch null;
            const got = file.read(header_buf[0..]) catch 0;
            if (got == 0) {
                // write initial header
                header = FileHeader{
                    .magic = .{ 'Z', 'V', 'M', '1' },
                    .version = 1,
                    .free_head = 0,
                    .next_append = @as(u64, @sizeOf(FileHeader)),
                };
                const hdr_slice = std.mem.asBytes(&header);
                _ = file.seekTo(0) catch return Errors.InvalidFile;
                _ = file.write(hdr_slice) catch return Errors.InvalidFile;
                return;
            }
            // copy into struct and validate
            const dest: *[@sizeOf(FileHeader)]u8 = @ptrCast(&header);
            var i: usize = 0;
            while (i < @sizeOf(FileHeader)) : (i += 1) {
                dest.*[i] = header_buf[i];
            }
            if (header.magic[0] != 'Z' or header.magic[1] != 'V' or header.magic[2] != 'M' or header.magic[3] != '1') {
                return Errors.InvalidFile;
            }
        } else {
            // stat reported an existing file; read and validate header normally
            var header: FileHeader = undefined;
            var header_buf: [@sizeOf(FileHeader)]u8 = undefined;
            _ = try file.seekTo(0);
            const got = try file.read(header_buf[0..]);
            if (got != header_buf.len) return Errors.InvalidFile;
            const dest: *[@sizeOf(FileHeader)]u8 = @ptrCast(&header);
            var j: usize = 0;
            while (j < @sizeOf(FileHeader)) : (j += 1) {
                dest.*[j] = header_buf[j];
            }
            if (header.magic[0] != 'Z' or header.magic[1] != 'V' or header.magic[2] != 'M' or header.magic[3] != '1') {
                return Errors.InvalidFile;
            }
        }
    }

    fn readHeader(self: *FileAllocator) !FileHeader {
        // Prefer the in-memory cached header for speed and consistency. Fall back to reading
        // from disk only if cache is not populated.
        // Note: cache is populated during init and kept consistent on writes.
        if (self.header_cache.magic[0] == 'Z' and self.header_cache.magic[1] == 'V' and self.header_cache.magic[2] == 'M' and self.header_cache.magic[3] == '1') {
            return self.header_cache;
        }

        // Cache not populated — read header from disk
        var header: FileHeader = undefined;
        var header_buf: [@sizeOf(FileHeader)]u8 = undefined;
        _ = try self.file.seekTo(0);
        const got = try self.file.read(header_buf[0..]);
        if (got != header_buf.len) return Errors.InvalidFile;
        const dest: *[@sizeOf(FileHeader)]u8 = @ptrCast(&header);
        var i: usize = 0;
        while (i < @sizeOf(FileHeader)) : (i += 1) {
            dest.*[i] = header_buf[i];
        }
        if (header.magic[0] != 'Z' or header.magic[1] != 'V' or header.magic[2] != 'M' or header.magic[3] != '1') {
            return Errors.InvalidFile;
        }
        // populate cache
        self.header_cache = header;
        return header;
    }

    fn writeHeader(self: *FileAllocator, header: *const FileHeader) !void {
        // Copy header into a byte buffer and write it (avoid std.mem.asBytes on union/generic types)
        var hdr_buf: [@sizeOf(FileHeader)]u8 = undefined;
        var header_copy: FileHeader = header.*;
        const src: *[@sizeOf(FileHeader)]u8 = @ptrCast(&header_copy);
        var i: usize = 0;
        while (i < @sizeOf(FileHeader)) : (i += 1) {
            hdr_buf[i] = src.*[i];
        }
        _ = try self.file.seekTo(0);
        _ = try self.file.write(hdr_buf[0..]);
        // update in-memory cache
        self.header_cache = header.*;
    }

    // In-memory free-block list replaces on-disk linked free blocks. This keeps
    // lookup and insertion fast and avoids random file seeks.

    fn findFreeBlock(self: *FileAllocator, need: usize) !?struct { index: usize, fb: FreeBlock } {
        // Best-fit: find smallest free block that satisfies need to reduce fragmentation and
        // increase the chance of reuse for equal-size allocations.
        var best_index: isize = -1;
        var best_size: usize = 0;
        var i: usize = 0;
        while (i < self.free_list.items.len) : (i += 1) {
            const fb = self.free_list.items[i];
            if (fb.size >= need) {
                if (best_index == -1 or fb.size < best_size) {
                    best_index = @intCast(i);
                    best_size = fb.size;
                }
            }
        }
        if (best_index != -1) {
            const idx: usize = @intCast(best_index);
            return .{ .index = idx, .fb = self.free_list.items[idx] };
        }
        return null;
    }

    fn removeFreeAt(self: *FileAllocator, index: usize) void {
        // swap remove
        const last = self.free_list.items.len - 1;
        if (index != last) self.free_list.items[index] = self.free_list.items[last];
        _ = self.free_list.pop();
    }

    fn pushFree(self: *FileAllocator, offset: u64, size: usize) !void {
        try self.free_list.append(self.map_allocator, FreeBlock{ .offset = offset, .size = size });
    }

    // Allocate a block in file (on-disk) and return its offset and block_size.
    fn allocateBlock(self: *FileAllocator, len: usize) !struct { offset: u64, block_size: usize } {
        if (len == 0) return Errors.InvalidRequest;
        // Search in-memory free list for a fit
        const found = try self.findFreeBlock(len);
        if (found) |res| {
            // use this free block; maybe split
            const fb = res.fb;
            if (fb.size >= len + 8) {
                const used_offset = fb.offset;
                const rem_offset = fb.offset + @as(u64, len);
                const rem_size = fb.size - len;
                // replace current entry with remainder
                self.free_list.items[res.index] = FreeBlock{ .offset = rem_offset, .size = rem_size };
                return .{ .offset = used_offset, .block_size = len };
            } else {
                // take whole block
                const used_offset = fb.offset;
                self.removeFreeAt(res.index);
                return .{ .offset = used_offset, .block_size = fb.size };
            }
        } else {
            // append at EOF
            _ = try self.readHeader();
        }

        // append at EOF
        const header = try self.readHeader();
        const offset = header.next_append;
        var new_header = header;
        new_header.next_append = offset + @as(u64, len);
        try self.writeHeader(&new_header);
        return .{ .offset = offset, .block_size = len };
    }

    fn alloc(ctx: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *FileAllocator = @ptrCast(@alignCast(ctx));
        if (len == 0) return null;

        // allocate in-file block
        const res = self.allocateBlock(len) catch return null;
        const payload_offset = res.offset;

        // allocate transient in-memory buffer from page allocator for the caller
        const buf = std.heap.page_allocator.alloc(u8, len) catch return null;
        // zero buffer
        var zi: usize = 0;
        while (zi < buf.len) : (zi += 1) {
            buf[zi] = 0;
        }

        // write zeroed payload to file at payload_offset
        _ = self.file.seekTo(@as(usize, payload_offset)) catch return null;
        _ = self.file.write(buf) catch return null;
        // Ensure header was advanced by allocateBlock; some platforms may require a second write
        const header = self.readHeader() catch return null;
        if (header.next_append <= payload_offset) {
            var new_header = header;
            new_header.next_append = payload_offset + @as(u64, res.block_size);
            self.writeHeader(&new_header) catch return null;
        }
        // store allocation mapping
        const key = @intFromPtr(buf.ptr);
        _ = self.allocations.put(key, AllocationInfo{ .offset = payload_offset, .len = len, .block_size = res.block_size }) catch {
            // on failure, cleanup
            _ = std.heap.page_allocator.free(buf);
            return null;
        };

        const p: ?[*]u8 = @ptrCast(buf.ptr);
        return p;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FileAllocator = @ptrCast(@alignCast(ctx));
        const key = @intFromPtr(buf.ptr);
        const entry = self.allocations.get(key) orelse return false;
        const info = entry;

        if (new_len == info.len) return true;

        if (new_len < info.len) {
            // shrink in place, create a new free block for the remainder (in-memory)
            const remainder = info.len - new_len;
            if (remainder > 0) {
                const rem_offset = info.offset + @as(u64, new_len);
                self.pushFree(rem_offset, remainder) catch return false;
            }
            var new_info = info;
            new_info.len = new_len;
            _ = self.allocations.put(key, new_info) catch {};
            // shrink backing buffer
            return std.heap.page_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        }

        // grow: allocate new block in file and new backing buffer, copy data
        const new_block = self.allocateBlock(new_len) catch return false;
        const new_payload = new_block.offset;

        const new_buf = std.heap.page_allocator.alloc(u8, new_len) catch return false;
        const min_len = if (new_len < info.len) new_len else info.len;
        var ci: usize = 0;
        while (ci < min_len) : (ci += 1) {
            new_buf[ci] = buf[ci];
        }

        // write new payload to file
        _ = self.file.seekTo(@as(usize, new_payload)) catch return false;
        _ = self.file.write(new_buf) catch return false;
        // free old block
        const old_block_offset = info.offset;
        self.pushFree(old_block_offset, info.len) catch return false;

        // update mapping
        _ = self.allocations.remove(key);
        const new_key = @intFromPtr(new_buf.ptr);
        _ = self.allocations.put(new_key, AllocationInfo{ .offset = new_payload, .len = new_len, .block_size = new_block.block_size }) catch {
            // rollback
            _ = std.heap.page_allocator.free(new_buf);
            return false;
        };

        // free old backing buffer
        _ = std.heap.page_allocator.free(buf);
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FileAllocator = @ptrCast(@alignCast(ctx));
        const key = @intFromPtr(buf.ptr);
        if (self.allocations.get(key) == null) return null;

        const ok = resize(ctx, buf, buf_align, new_len, ret_addr);
        if (!ok) return null;

        // After resize, the mapping may have changed; find new pointer by scanning the map for the new offset
        const old_entry = self.allocations.get(key);
        if (old_entry != null) {
            // if mapping still exists for same key, then buffer stayed in place
            return buf.ptr;
        }

        // Otherwise find the allocation that has the same offset as old block (best-effort)
        // Note: this is a less-than-ideal search but remap is infrequent.
        var it = self.allocations.iterator();
        while (it.next()) |entry| {
            // return the first allocation whose len == new_len and treat its key as new pointer
            if (entry.value_ptr.*.len == new_len) {
                return @as(?[*]u8, @ptrFromInt(entry.key_ptr.*));
            }
        }
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *FileAllocator = @ptrCast(@alignCast(ctx));
        const key = @intFromPtr(buf.ptr);
        // If we have a mapping, push the file region to free list and remove mapping.
        if (self.allocations.get(key) != null) {
            const info = self.allocations.get(key) orelse return;
            const block_offset = info.offset;
            self.pushFree(block_offset, info.len) catch std.debug.panic("FileAllocator.pushFree failed\n", .{});
            _ = self.allocations.remove(key);
        }
        // Always free the in-memory buffer to avoid leaks even if mapping missing
        _ = std.heap.page_allocator.free(buf);
    }

    pub const Errors = error{ InvalidFile, InvalidRequest };
};

// ============================================================================
// Tests
// ============================================================================

test "file allocator basic alloc and free" {
    const file_path = "zvm_test_tmp1.bin";
    _ = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    var file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    defer file.close();

    var fa = try FileAllocator.init(file, std.testing.allocator);
    defer fa.deinit();

    const alloc = fa.allocator();

    const buf = try alloc.alloc(u8, 128);
    try std.testing.expect(buf.len == 128);
    // zero buffer
    var zi: usize = 0;
    while (zi < buf.len) : (zi += 1) {
        buf[zi] = 0;
    }

    // ensure data was checkpointed into file
    const header = try fa.readHeader();
    try std.testing.expect(header.next_append > @as(u64, @sizeOf(FileAllocator.FileHeader)));

    alloc.free(buf);

    // after free, in-memory free list should have at least one entry
    try std.testing.expect(fa.freeCount() != 0);
}

test "file allocator reuses freed blocks" {
    const file_path = "zvm_test_tmp2.bin";
    _ = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    var file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    defer file.close();

    var fa = try FileAllocator.init(file, std.testing.allocator);
    defer fa.deinit();

    const alloc = fa.allocator();

    const a = try alloc.alloc(u8, 64);
    try std.testing.expect(a.len == 64);

    // record header after first allocation
    const header_after_alloc = try fa.readHeader();

    alloc.free(a);

    // ensure free entry created
    try std.testing.expect(fa.freeCount() != 0);

    const b = try alloc.alloc(u8, 64);
    try std.testing.expect(b.len == 64);

    // The allocator should reuse the freed block and not append more data; next_append should be unchanged
    const hdr = try fa.readHeader();
    try std.testing.expect(hdr.next_append == header_after_alloc.next_append);

    // cleanup: free the allocation we created so tests don't leak
    alloc.free(b);
}

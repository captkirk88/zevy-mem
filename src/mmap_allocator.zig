const std = @import("std");
const memory_utils = @import("utils/mem.zig");

fn deleteFileZ(io: std.Io, path: [:0]const u8) void {
    // Ignore errors; this helper is only used by tests for cleanup.
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, path) catch {};
}

fn openOrCreateFile(io: std.Io, path: [:0]const u8) !std.Io.File {
    const dir = std.Io.Dir.cwd();
    const open_flags: std.Io.File.OpenFlags = .{ .mode = .read_write, .allow_directory = false };

    const file = dir.openFile(io, path, open_flags) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(io, path, .{ .read = true, .truncate = false }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => dir.openFile(io, path, open_flags),
            else => |other_err| return other_err,
        },
        else => return err,
    };

    return file;
}

const header_magic = 0x4d4d4150; // "MMAP"
const header_version: u32 = 1;

const FileHeader = packed struct {
    magic: u32,
    version: u32,
    page_size: u32,
    total_pages: u64,
    meta_pages: u32,
    data_start_page: u32,
};

const AllocHeader = packed struct {
    pages: u32,
    page_offset: u32,
    size: u64,
    alignment: u32,
};

/// Metadata about a single allocation in the file.
pub const AllocationInfo = struct {
    page_offset: u32,
    pages: u32,
    size: u64,
    alignment: u32,
};

/// Inspect a memory-mapped file without modifying it.
pub const FileInspection = struct {
    header: FileHeader,
    allocations: []AllocationInfo,

    pub fn deinit(self: *FileInspection, allocator: std.mem.Allocator) void {
        allocator.free(self.allocations);
    }
};

/// Allocator that serves memory out of a memory-mapped file.
/// Only the mapping slice and a few pointers live in RAM; all allocation
/// metadata is persisted inside the mapped region.
pub const MmapAllocator = struct {
    io: std.Io,
    file: std.Io.File,
    mm: std.Io.File.MemoryMap,
    map: []u8,
    header: *FileHeader,
    bitset: []u8,
    preserve: bool,

    pub const InitOptions = struct {
        /// Path to the backing file. Must be zero-terminated to avoid extra allocations.
        path: [:0]const u8,
        /// Requested mapping size. Rounded up to the system page size.
        size: usize,

        /// Preserve existing file contents/metadata instead of resetting. When false,
        /// a fresh header and free list are written. Default is false.
        preserve: bool = false,

        /// Return size rounded up to the system minimum page size.
        pub fn alignSize(size: usize) usize {
            return std.mem.alignForward(usize, size, std.heap.pageSize());
        }

        /// Construct InitOptions with size already aligned to the system minimum page size.
        pub fn fromPathZ(path: [:0]const u8, size: usize) InitOptions {
            return .{ .path = path, .size = alignSize(size) };
        }

        /// Construct InitOptions by specifying the number of pages to reserve.
        pub fn withPages(path: [:0]const u8, pages: usize) InitOptions {
            const page_size = std.heap.pageSize();
            return .{ .path = path, .size = pages * page_size };
        }

        /// Duplicate a path slice into a zero-terminated buffer.
        /// Caller owns the returned buffer and must free it if not using an arena.
        pub fn dupePathZ(path_allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
            return try path_allocator.dupeZ(u8, path);
        }
    };

    pub fn init(io: std.Io, options: InitOptions) MmapAllocator {
        const page_size = std.heap.pageSize();
        const requested_size = std.mem.alignForward(usize, options.size, page_size);
        if (requested_size < page_size * 2)
            std.debug.panic("File too small for MmapAllocator: requested {d}, minimum {d}", .{ requested_size, page_size * 2 });

        const file = openOrCreateFile(io, options.path) catch std.debug.panic("Failed to open file: {s}", .{options.path});
        var cleanup_close = true;
        errdefer if (cleanup_close) std.Io.File.close(file, io);

        const existing_size = std.Io.File.length(file, io) catch std.debug.panic("Failed to get file stats: {s}", .{options.path});

        var mapped_size = requested_size;
        if (options.preserve and existing_size > 0) {
            mapped_size = std.mem.alignForward(usize, existing_size, page_size);
            if (mapped_size < requested_size) mapped_size = requested_size;
        }

        if (!options.preserve or existing_size < mapped_size) {
            std.Io.File.setLength(file, io, @intCast(mapped_size)) catch std.debug.panic("Failed to set length of file: {s}", .{options.path});
        }

        var mm = std.Io.File.MemoryMap.create(io, file, .{
            .len = mapped_size,
            .protection = .{ .read = true, .write = true },
            .populate = true,
        }) catch std.debug.panic("Failed to memory-map file: {s}", .{options.path});
        var cleanup_unmap = true;
        errdefer if (cleanup_unmap) std.Io.File.MemoryMap.destroy(&mm, io);

        var self = MmapAllocator{
            .io = io,
            .file = file,
            .mm = mm,
            .map = @as([]u8, mm.memory),
            .header = undefined,
            .bitset = &[_]u8{},
            .preserve = options.preserve,
        };

        if (!options.preserve or !self.tryLoadExisting(page_size)) {
            self.initializeLayout(page_size) catch std.debug.panic("Failed to initialize layout: {s}", .{options.path});
        }

        std.Io.File.sync(file, io) catch |err| std.debug.panic("Failed to sync file: {s}, error: {s}", .{ options.path, @errorName(err) });

        cleanup_unmap = false;
        cleanup_close = false;
        return self;
    }

    pub const DeinitStatus = enum { ok, leak };

    pub fn deinit(self: *MmapAllocator) DeinitStatus {
        var status: DeinitStatus = .ok;

        var p: usize = self.header.data_start_page;
        while (p < self.header.total_pages) : (p += 1) {
            if (self.pageUsed(p)) {
                status = .leak;
                break;
            }
        }

        if (!self.preserve) {
            @memset(self.map, 0);
        }

        self.mm.write(self.io) catch {};
        self.mm.destroy(self.io);
        self.file.close(self.io);
        return status;
    }

    pub fn allocator(self: *MmapAllocator) std.mem.Allocator {
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

    fn initializeLayout(self: *MmapAllocator, page_size: usize) !void {
        const total_pages = self.map.len / page_size;

        const bitset_bytes = std.math.divCeil(usize, total_pages, 8) catch return error.SizeOverflow;
        const meta_bytes = @sizeOf(FileHeader) + bitset_bytes;
        const meta_pages = std.math.divCeil(usize, meta_bytes, page_size) catch return error.SizeOverflow;
        if (meta_pages >= total_pages) return error.FileTooSmall;

        self.header = @ptrCast(@alignCast(self.map.ptr));
        self.header.* = .{
            .magic = header_magic,
            .version = header_version,
            .page_size = @intCast(page_size),
            .total_pages = total_pages,
            .meta_pages = @intCast(meta_pages),
            .data_start_page = @intCast(meta_pages),
        };

        self.bitset = self.map[@sizeOf(FileHeader)..][0..bitset_bytes];
        @memset(self.bitset, 0);

        self.markRange(0, meta_pages, true);
    }

    /// Attempt to load an existing header/bitset layout. Returns true on success.
    fn tryLoadExisting(self: *MmapAllocator, page_size: usize) bool {
        const hdr: *FileHeader = @ptrCast(@alignCast(self.map.ptr));
        if (hdr.magic != header_magic or hdr.version != header_version) return false;
        if (hdr.page_size != page_size) return false;
        if (hdr.total_pages == 0) return false;
        if (hdr.total_pages * page_size > self.map.len) return false;

        const expected_bitset = std.math.divCeil(usize, hdr.total_pages, 8) catch return false;
        const meta_bytes = @as(usize, hdr.meta_pages) * page_size;
        if (meta_bytes < @sizeOf(FileHeader)) return false;
        const available_bitset = meta_bytes - @sizeOf(FileHeader);
        if (available_bitset < expected_bitset) return false;
        if (hdr.data_start_page != hdr.meta_pages) return false;

        self.header = hdr;
        self.bitset = self.map[@sizeOf(FileHeader)..][0..expected_bitset];
        return true;
    }

    /// Find a run of free pages of the requested length.
    fn findFreeRun(self: *MmapAllocator, pages_needed: usize) ?usize {
        var run_len: usize = 0;
        var run_start: usize = 0;

        var page = @as(usize, self.header.data_start_page);
        while (page < self.header.total_pages) : (page += 1) {
            if (!self.pageUsed(page)) {
                if (run_len == 0) run_start = page;
                run_len += 1;
                if (run_len >= pages_needed) return run_start;
            } else {
                run_len = 0;
            }
        }
        return null;
    }

    /// Mark a range of pages as used or free.
    fn markRange(self: *MmapAllocator, start: usize, count: usize, used: bool) void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.setPageUsed(start + i, used);
        }
    }

    /// Set or clear the used bit for a specific page.
    fn setPageUsed(self: *MmapAllocator, page: usize, used: bool) void {
        const idx = page / 8;
        const bit_index: u3 = @intCast(page % 8);
        const mask: u8 = @as(u8, 1) << bit_index;
        if (used) {
            self.bitset[idx] |= mask;
        } else {
            self.bitset[idx] &= ~mask;
        }
    }

    /// Check if a specific page is marked as used.
    fn pageUsed(self: *MmapAllocator, page: usize) bool {
        const idx = page / 8;
        const bit_index: u3 = @intCast(page % 8);
        const mask: u8 = @as(u8, 1) << bit_index;
        return (self.bitset[idx] & mask) != 0;
    }

    fn pageSize(self: *MmapAllocator) usize {
        return self.header.page_size;
    }

    fn baseAddress(self: *MmapAllocator) usize {
        return @intFromPtr(self.map.ptr);
    }

    /// Get the offset of a pointer within the mapped file.
    pub fn offsetFromPtr(self: *MmapAllocator, buf: []const u8) usize {
        return @intFromPtr(buf.ptr) - self.baseAddress();
    }

    /// Get a pointer from an offset within the mapped file.
    pub fn ptrFromOffset(self: *MmapAllocator, offset: usize) [*]u8 {
        return @as([*]u8, @ptrFromInt(self.baseAddress() + offset));
    }

    /// List all allocations currently in the file. Caller owns the returned slice.
    pub fn listAllocations(self: *MmapAllocator, list_allocator: std.mem.Allocator) ![]AllocationInfo {
        var list = try std.ArrayList(AllocationInfo).initCapacity(list_allocator, 16);
        defer list.deinit(list_allocator);

        var page: usize = self.header.data_start_page;
        while (page < self.header.total_pages) : (page += 1) {
            if (self.pageUsed(page)) {
                const block_addr = self.baseAddress() + page * self.pageSize();
                const alloc_header: *AllocHeader = @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(block_addr))));
                try list.append(list_allocator, .{
                    .page_offset = alloc_header.page_offset,
                    .pages = alloc_header.pages,
                    .size = alloc_header.size,
                    .alignment = alloc_header.alignment,
                });
                page += alloc_header.pages - 1;
            }
        }

        return try list.toOwnedSlice(list_allocator);
    }
};

/// Inspect a memory-mapped allocator file
pub fn inspectFile(io: std.Io, inspect_allocator: std.mem.Allocator, path: [:0]const u8) !FileInspection {
    const page_size = std.heap.pageSize();
    const handle = try openOrCreateFile(io, path);
    defer handle.close(io);

    const file_stat = try std.Io.File.stat(handle, io);
    const file_size = file_stat.size;

    var mapped = try std.Io.File.MemoryMap.create(io, handle, .{
        .len = file_size,
        .protection = .{ .read = true },
        .populate = true,
    });
    defer mapped.destroy(io);

    const file_header = @as(*const FileHeader, @ptrCast(@alignCast(mapped.memory.ptr)));
    if (file_header.magic != header_magic or file_header.version != header_version) {
        return error.InvalidFile;
    }

    var alloc_list = try std.ArrayList(AllocationInfo).initCapacity(inspect_allocator, 16);
    defer alloc_list.deinit(inspect_allocator);

    var page: u64 = file_header.data_start_page;
    while (page < file_header.total_pages) : (page += 1) {
        const byte_idx = page / 8;
        const bit_idx: u3 = @intCast(page % 8);
        const mask: u8 = @as(u8, 1) << bit_idx;
        const bitset_start = @sizeOf(FileHeader);
        const is_used = if (bitset_start + byte_idx < mapped.memory.len) (mapped.memory[bitset_start + byte_idx] & mask) != 0 else false;

        if (is_used) {
            const block_addr = @intFromPtr(mapped.memory.ptr) + page * page_size;
            const alloc_hdr = @as(*const AllocHeader, @ptrCast(@alignCast(@as([*]const u8, @ptrFromInt(block_addr)))));
            alloc_list.appendAssumeCapacity(.{
                .page_offset = alloc_hdr.page_offset,
                .pages = alloc_hdr.pages,
                .size = alloc_hdr.size,
                .alignment = alloc_hdr.alignment,
            });
            page += alloc_hdr.pages - 1;
        }
    }

    return .{
        .header = file_header.*,
        .allocations = try alloc_list.toOwnedSlice(inspect_allocator),
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *MmapAllocator = @ptrCast(@alignCast(ctx));

    const align_bytes = alignment.toByteUnits();
    const header_size = @sizeOf(AllocHeader);
    const worst_case = header_size + len + (align_bytes - 1);
    const pages_needed = std.math.divCeil(usize, worst_case, self.pageSize()) catch return null;

    const start_page = self.findFreeRun(pages_needed) orelse return null;
    self.markRange(start_page, pages_needed, true);

    const base_addr = self.baseAddress() + start_page * self.pageSize();
    const payload_addr = std.mem.alignForward(usize, base_addr + header_size, align_bytes);
    const header_addr = payload_addr - header_size;
    const block_end = base_addr + pages_needed * self.pageSize();
    if (payload_addr + len > block_end) {
        self.markRange(start_page, pages_needed, false);
        return null;
    }

    const header_ptr = @as(*AllocHeader, @ptrFromInt(header_addr));
    header_ptr.* = .{
        .pages = @intCast(pages_needed),
        .page_offset = @intCast(header_addr - base_addr),
        .size = len,
        .alignment = @intCast(align_bytes),
    };

    return @as([*]u8, @ptrFromInt(payload_addr));
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = buf_align;
    _ = ret_addr;
    const self: *MmapAllocator = @ptrCast(@alignCast(ctx));
    if (buf.len == 0) return new_len == 0;

    const header_addr = @intFromPtr(buf.ptr) - @sizeOf(AllocHeader);
    const header = @as(*AllocHeader, @ptrFromInt(header_addr));

    const base_addr = header_addr - header.page_offset;
    const block_end = base_addr + header.pages * self.pageSize();
    const capacity = block_end - @intFromPtr(buf.ptr);

    if (new_len <= capacity) {
        header.size = new_len;
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *MmapAllocator = @ptrCast(@alignCast(ctx));

    if (new_len == 0) {
        if (memory.len != 0) {
            free(ctx, memory, alignment, ret_addr);
        }
        return null;
    }

    if (memory.len == 0) {
        return alloc(ctx, new_len, alignment, ret_addr);
    }

    const header_addr = @intFromPtr(memory.ptr) - @sizeOf(AllocHeader);
    const header = @as(*AllocHeader, @ptrFromInt(header_addr));
    const base_addr = header_addr - header.page_offset;
    const block_end = base_addr + header.pages * self.pageSize();
    const capacity = block_end - @intFromPtr(memory.ptr);

    if (new_len <= capacity) {
        header.size = new_len;
        return @as([*]u8, memory.ptr);
    }

    const new_buf = alloc(ctx, new_len, alignment, ret_addr) orelse return null;
    const copy_len = if (memory.len < new_len) memory.len else new_len;
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        new_buf[i] = memory[i];
    }
    free(ctx, memory, alignment, ret_addr);
    return new_buf;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    _ = buf_align;
    _ = ret_addr;
    if (buf.len == 0) return;

    const self: *MmapAllocator = @ptrCast(@alignCast(ctx));
    const header_addr = @intFromPtr(buf.ptr) - @sizeOf(AllocHeader);
    const header = @as(*AllocHeader, @ptrFromInt(header_addr));

    const base_addr = header_addr - header.page_offset;
    const start_page = (base_addr - self.baseAddress()) / self.pageSize();
    self.markRange(start_page, header.pages, false);
}

test "MmapAllocator can allocate and free" {
    const test_allocator = std.testing.allocator;
    const path: [:0]const u8 = "mmap_allocator_test.bin";
    defer deleteFileZ(std.testing.io, path);

    var mmap_alloc = MmapAllocator.init(std.testing.io, .{ .path = path, .size = 64 * 1024 });
    defer _ = mmap_alloc.deinit();

    const allocator = mmap_alloc.allocator();

    const buf1 = try allocator.alloc(u8, 512);
    const buf2 = try allocator.alloc(u8, 1024);

    allocator.free(buf1);
    allocator.free(buf2);

    const buf3 = try allocator.alloc(u8, 512);
    defer allocator.free(buf3);
    try std.testing.expect(buf3.len == 512);

    // Inspect allocations in the current instance
    const allocs = try mmap_alloc.listAllocations(test_allocator);
    defer test_allocator.free(allocs);
    try std.testing.expectEqual(@as(usize, 1), allocs.len);

    for (allocs) |i| {
        try std.testing.expectEqual(@as(u64, 512), i.size);
        std.debug.print("Allocation: offset={}, pages={}, size={}, alignment={}\n", .{ i.page_offset, i.pages, i.size, i.alignment });
    }
}

test "InitOptions helpers align and dupe" {
    const page = std.heap.pageSize();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const duped = try MmapAllocator.InitOptions.dupePathZ(arena.allocator(), "mmap_opts.bin");
    const opts = MmapAllocator.InitOptions.fromPathZ(duped, page + 123);
    try std.testing.expectEqual(MmapAllocator.InitOptions.alignSize(page + 123), opts.size);
    try std.testing.expect(duped[duped.len] == 0);
}

test "MmapAllocator alignment and resize behavior" {
    const page = std.heap.pageSize();
    const path: [:0]const u8 = "mmap_allocator_align.bin";
    defer deleteFileZ(std.testing.io, path);

    var mmap_alloc = MmapAllocator.init(std.testing.io, .withPages(path, 4));
    defer _ = mmap_alloc.deinit();
    const allocator = mmap_alloc.allocator();

    const Aligned64 = struct { value: u8 align(64) };
    const aligned = try allocator.alloc(Aligned64, 8);
    defer allocator.free(aligned);
    try std.testing.expect(@intFromPtr(aligned.ptr) % 64 == 0);

    const buf = try allocator.alloc(u8, page / 2);
    const header_addr = @intFromPtr(buf.ptr) - @sizeOf(AllocHeader);
    const header = @as(*AllocHeader, @ptrFromInt(header_addr));
    const payload_offset = header.page_offset + @sizeOf(AllocHeader);
    const capacity = header.pages * mmap_alloc.pageSize() - payload_offset;

    const shrink_ok = allocator.resize(buf, buf.len / 2);
    try std.testing.expect(shrink_ok);

    const grow_ok = allocator.resize(buf, capacity + 16);
    try std.testing.expect(!grow_ok);

    allocator.free(buf);
}

test "MmapAllocator reuses freed space" {
    const path: [:0]const u8 = "mmap_allocator_reuse.bin";
    defer deleteFileZ(std.testing.io, path);

    var mmap_alloc = MmapAllocator.init(std.testing.io, .withPages(path, 4));
    defer _ = mmap_alloc.deinit();
    const allocator = mmap_alloc.allocator();

    const buf1 = try allocator.alloc(u8, 128);
    const addr1 = @intFromPtr(buf1.ptr);
    allocator.free(buf1);

    const buf2 = try allocator.alloc(u8, 128);
    const addr2 = @intFromPtr(buf2.ptr);
    try std.testing.expectEqual(addr1, addr2);

    allocator.free(buf2);
}

test "MmapAllocator preserve keeps data" {
    const path: [:0]const u8 = "mmap_allocator_preserve.bin";
    defer deleteFileZ(std.testing.io, path);

    var first_opts = MmapAllocator.InitOptions.withPages(path, 4);
    first_opts.preserve = true;
    var first = MmapAllocator.init(std.testing.io, first_opts);
    const alloc1 = first.allocator();

    const buf = try alloc1.alloc(u8, 32);
    buf[0] = 0xAB;
    const rel_off = first.offsetFromPtr(buf);

    _ = first.deinit();

    var second_opts = MmapAllocator.InitOptions.withPages(path, 4);
    second_opts.preserve = true;
    var second = MmapAllocator.init(std.testing.io, second_opts);
    defer _ = second.deinit();

    const restored_ptr = second.ptrFromOffset(rel_off);
    try std.testing.expectEqual(@as(u8, 0xAB), restored_ptr[0]);

    // Inspect the file to verify allocations
    var inspection = try inspectFile(std.testing.io, std.testing.allocator, path);
    defer inspection.deinit(std.testing.allocator);
    try std.testing.expect(inspection.allocations.len > 0);
}

test "MmapAllocator remap grows and copies data" {
    const path: [:0]const u8 = "mmap_allocator_remap_grow.bin";
    defer deleteFileZ(std.testing.io, path);

    var mmap_alloc = MmapAllocator.init(std.testing.io, MmapAllocator.InitOptions.withPages(path, 8));
    defer _ = mmap_alloc.deinit();
    const allocator = mmap_alloc.allocator();

    const initial = try allocator.alloc(u8, 32);
    for (initial) |*byte| byte.* = 0x3C;

    const expanded = try allocator.realloc(initial, 128);
    defer allocator.free(expanded);

    try std.testing.expectEqual(@as(u8, 0x3C), expanded[0]);
    try std.testing.expectEqual(@as(u8, 0x3C), expanded[31]);
}

test "MmapAllocator remap to zero frees allocation" {
    const path: [:0]const u8 = "mmap_allocator_remap_zero.bin";
    defer deleteFileZ(std.testing.io, path);

    var mmap_alloc = MmapAllocator.init(std.testing.io, MmapAllocator.InitOptions.withPages(path, 4));
    defer _ = mmap_alloc.deinit();
    const allocator = mmap_alloc.allocator();

    const buf = try allocator.alloc(u8, 64);
    buf[0] = 0x55;

    const freed = try allocator.realloc(buf, 0);
    try std.testing.expectEqual(@as(usize, 0), freed.len);
}

test "MmapAllocator multi-write preserve file" {
    const path: [:0]const u8 = "mmap_allocator_multi_write.bin";
    defer deleteFileZ(std.testing.io, path);

    var first_opts = MmapAllocator.InitOptions.withPages(path, 8);
    first_opts.preserve = true;
    var first = MmapAllocator.init(std.testing.io, first_opts);
    const allocator = first.allocator();

    const chunk1 = try allocator.alloc(u8, 64);
    const chunk2 = try allocator.alloc(u8, 128);

    const chunk1_label = "chunk1";
    const chunk2_label = "chunk2";
    var idx: usize = 0;
    while (idx < chunk1.len) : (idx += 1) {
        chunk1[idx] = chunk1_label[idx % chunk1_label.len];
    }
    idx = 0;
    while (idx < chunk2.len) : (idx += 1) {
        chunk2[idx] = chunk2_label[idx % chunk2_label.len];
    }

    const off1 = first.offsetFromPtr(chunk1);
    const off2 = first.offsetFromPtr(chunk2);

    _ = first.deinit();

    var second_opts = MmapAllocator.InitOptions.withPages(path, 8);
    second_opts.preserve = true;
    var second = MmapAllocator.init(std.testing.io, second_opts);
    defer _ = second.deinit();

    const restored1 = second.ptrFromOffset(off1)[0..chunk1.len];
    const restored2 = second.ptrFromOffset(off2)[0..chunk2.len];

    idx = 0;
    while (idx < restored1.len) : (idx += 1) {
        try std.testing.expectEqual(chunk1_label[idx % chunk1_label.len], restored1[idx]);
    }
    idx = 0;
    while (idx < restored2.len) : (idx += 1) {
        try std.testing.expectEqual(chunk2_label[idx % chunk2_label.len], restored2[idx]);
    }
}

test "MmapAllocator runtime-vs-page allocator usage" {
    const path: [:0]const u8 = "mmap_allocator_runtime_vs_mmap.bin";
    defer deleteFileZ(std.testing.io, path);

    const runtime_size = std.heap.pageSize() * 4;

    const before_runtime = try memory_utils.getMemoryInfo();
    const runtime_chunk = try std.heap.page_allocator.alloc(u8, runtime_size);
    for (runtime_chunk) |*byte| {
        byte.* = 0xAA;
    }
    const after_runtime = try memory_utils.getMemoryInfo();
    const runtime_delta = after_runtime.current_usage - before_runtime.current_usage;
    try std.testing.expect(runtime_delta > 0);
    std.heap.page_allocator.free(runtime_chunk);

    const before_mmap = try memory_utils.getMemoryInfo();
    var mmap_alloc = MmapAllocator.init(std.testing.io, .{ .path = path, .size = runtime_size });
    defer _ = mmap_alloc.deinit();
    const mmap_chunk = try mmap_alloc.allocator().alloc(u8, 1);
    mmap_chunk[0] = 0xBB;
    const after_mmap = try memory_utils.getMemoryInfo();
    const mmap_delta = after_mmap.current_usage - before_mmap.current_usage;
    mmap_alloc.allocator().free(mmap_chunk);

    try std.testing.expect(runtime_delta > mmap_delta);
    std.debug.print(
        "Runtime delta={d} bytes vs mmap delta={d} bytes\n",
        .{ runtime_delta, mmap_delta },
    );
}

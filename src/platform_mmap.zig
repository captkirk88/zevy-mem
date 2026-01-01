//! Memory-mapped file abstraction for cross-platform usage (Windows and POSIX)

const std = @import("std");
const builtin = @import("builtin");
const winbase = if (builtin.os.tag == .windows) @cImport(@cInclude("windows.h")) else struct {};

// Windows API declarations for file mapping
const w = std.os.windows;
pub const page_size = std.heap.pageSize();

const MapError = error{
    CreateFileMappingFailed,
    MapViewOfFileFailed,
};

/// Cross-platform file handle abstraction.
pub const FileHandle = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t;

/// Cross-platform memory-mapped region.
/// On Windows: file_handle is the file, handle is the section.
/// On POSIX: file_handle is the fd, handle is unused.
pub const MappedRegion = struct {
    ptr: [*]u8,
    len: usize,
    handle: FileHandle, // Section handle on Windows, unused on POSIX
    file_handle: FileHandle, // File handle (only used on Windows)
};
/// Open or create a file for memory mapping.
pub fn openFile(path: [:0]const u8, create_if_missing: bool) !FileHandle {
    if (builtin.os.tag == .windows) {
        // Try to open existing file first; only create if it doesn't exist
        const file = std.fs.cwd().openFileZ(path, .{ .mode = .read_write }) catch |err| {
            if (err == error.FileNotFound and create_if_missing) {
                // File doesn't exist and we should create it
                const created_file = try std.fs.cwd().createFileZ(path, .{ .truncate = true, .read = true });
                return created_file.handle;
            }
            return err;
        };
        return file.handle;
    }
    const flags: std.posix.O = .{
        .ACCMODE = .RDWR,
        .CREAT = create_if_missing,
        .TRUNC = false,
    };
    return try std.posix.openatZ(std.posix.AT.FDCWD, path, flags, 0o644);
}

/// Close a file handle.
pub fn closeFile(handle: FileHandle) void {
    if (builtin.os.tag == .windows) {
        w.CloseHandle(handle);
    } else {
        std.posix.close(handle);
    }
}

/// Get file statistics (size, etc).
pub fn fileStats(handle: FileHandle) !struct { size: u64 } {
    if (builtin.os.tag == .windows) {
        const size = try w.GetFileSizeEx(handle);
        return .{ .size = size };
    }
    var stat: std.posix.Stat = undefined;
    try std.posix.fstat(handle, &stat);
    return .{ .size = @intCast(stat.size) };
}

/// Resize file to a specific size.
pub fn truncateFile(handle: FileHandle, size: u64) !void {
    if (builtin.os.tag == .windows) {
        const ntdll = w.ntdll;

        try w.SetFilePointerEx_BEGIN(handle, size);

        // Use NtSetInformationFile to set end of file
        var io_status_block: w.IO_STATUS_BLOCK = undefined;
        var eof_info: w.FILE_END_OF_FILE_INFORMATION = undefined;
        eof_info.EndOfFile = @intCast(size);

        const status = ntdll.NtSetInformationFile(
            handle,
            &io_status_block,
            &eof_info,
            @sizeOf(w.FILE_END_OF_FILE_INFORMATION),
            .FileEndOfFileInformation,
        );
        if (status != .SUCCESS) return error.SetEndOfFileFailed;
    } else {
        try std.posix.ftruncate(handle, size);
    }
}

/// Sync file to disk.
pub fn syncFile(handle: FileHandle) void {
    if (builtin.os.tag == .windows) {
        _ = w.kernel32.FlushFileBuffers(handle);
    } else {
        _ = std.posix.fsync(handle) catch {};
    }
}

/// Memory-map a file - uses CreateFileMapping/MapViewOfFile on Windows, mmap on POSIX
pub fn mapFile(handle: FileHandle, size: usize) !MappedRegion {
    if (builtin.os.tag == .windows) {
        // Flush file buffers before creating a mapping so the section reflects the on-disk state
        _ = w.kernel32.FlushFileBuffers(handle);

        const size64: u64 = @intCast(size);
        const size_high: u32 = @intCast(size64 >> 32);
        const size_low: u32 = @intCast(size64 & 0xFFFFFFFF);

        const map_handle = winbase.CreateFileMappingA(
            handle,
            null,
            w.PAGE_READWRITE,
            size_high,
            size_low,
            null,
        ) orelse {
            return MapError.CreateFileMappingFailed;
        };

        const map_size: winbase.SIZE_T = @intCast(size);
        const view = winbase.MapViewOfFile(
            map_handle,
            winbase.FILE_MAP_ALL_ACCESS,
            0,
            0,
            map_size,
        ) orelse {
            _ = winbase.CloseHandle(map_handle);
            return MapError.MapViewOfFileFailed;
        };

        return .{
            .ptr = @ptrCast(view),
            .len = size,
            .handle = map_handle,
            .file_handle = handle,
        };
    }
    const map = try std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        handle,
        0,
    );
    return .{
        .ptr = @as([*]u8, map.ptr),
        .len = size,
        .handle = handle,
        .file_handle = handle,
    };
}

/// Unmap a memory-mapped region
pub fn unmapFile(region: MappedRegion) void {
    if (builtin.os.tag == .windows) {
        const flush_base: winbase.LPCVOID = @ptrCast(region.ptr);
        _ = winbase.FlushViewOfFile(flush_base, @intCast(region.len));

        const view_base: winbase.LPVOID = @ptrCast(region.ptr);
        _ = winbase.UnmapViewOfFile(view_base);
        _ = winbase.CloseHandle(region.handle);
    } else {
        const aligned_slice: []align(page_size) u8 = @alignCast(region.ptr[0..region.len]);
        std.posix.munmap(aligned_slice);
    }
}

pub fn alignSize(size: usize) usize {
    return std.mem.alignForward(usize, size, page_size);
}

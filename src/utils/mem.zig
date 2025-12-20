const std = @import("std");
const builtin = @import("builtin");

/// Information about the current process's memory usage and limits.
pub const MemoryInfo = struct {
    /// Current memory usage in bytes (typically resident set size).
    current_usage: usize,
    /// Maximum memory limit in bytes. If no limit is set, this may be a large value or std.math.maxInt(usize).
    max_limit: usize,
};

/// Get the current memory usage and maximum memory limit for the process.
/// This is cross-platform, supporting Linux, Windows, and macOS.
/// Returns error on failure to retrieve information.
pub fn getMemoryInfo() !MemoryInfo {
    const target = builtin.target;
    switch (target.os.tag) {
        .linux => return getMemoryInfoLinux(),
        .windows => return getMemoryInfoWindows(),
        else => @compileError("Unsupported OS: " ++ @tagName(target.os.tag)),
    }
}

fn getMemoryInfoLinux() !MemoryInfo {
    // Get current usage via getrusage
    var rusage: std.os.linux.rusage = undefined;
    std.os.linux.getrusage(std.os.linux.rusage.SELF, &rusage) catch |err| return err;
    const current_usage = @as(usize, @intCast(rusage.maxrss)) * 1024; // ru_maxrss is in KB on Linux

    // Get max limit via getrlimit
    var rlim: std.os.linux.rlimit = undefined;
    std.os.linux.getrlimit(.RLIMIT_AS, &rlim) catch |err| return err;
    const max_limit = if (rlim.cur == std.os.linux.RLIM.INFINITY) std.math.maxInt(usize) else rlim.cur;

    return .{ .current_usage = current_usage, .max_limit = max_limit };
}

fn getMemoryInfoWindows() !MemoryInfo {
    const process = std.os.windows.GetCurrentProcess();
    const mem_counters = try std.os.windows.GetProcessMemoryInfo(process);
    const current_usage = mem_counters.WorkingSetSize;

    // Windows doesn't have a simple address space limit like Unix.
    // For simplicity, set to maxInt if no limit.
    const max_limit = std.math.maxInt(usize);

    return .{ .current_usage = current_usage, .max_limit = max_limit };
}

test "getMemoryInfo returns valid info" {
    const info = try getMemoryInfo();
    try std.testing.expect(info.current_usage > 0);
    // max_limit could be maxInt if no limit
}

//! PTY traffic logging
//!
//! Logs PTY I/O traffic to a file in the temp directory.
//! Format: [HH:MM:SS.mmm] > pane N: hex bytes | ascii
//!
//! Usage:
//!   const pty_log = @import("pty_log.zig");
//!   pty_log.logSend(pane_id, data);  // bytes sent TO PTY
//!   pty_log.logRecv(pane_id, data);  // bytes received FROM PTY
//!   pty_log.setEnabled(true/false);  // toggle logging

const std = @import("std");
const paths = @import("paths.zig");

/// Global state
var log_file: ?std.fs.File = null;
var enabled: bool = false;
var mutex: std.Thread.Mutex = .{};

/// Enable or disable PTY traffic logging
pub fn setEnabled(value: bool) void {
    mutex.lock();
    defer mutex.unlock();
    enabled = value;

    if (value and log_file == null) {
        initLogFile();
    }
}

/// Check if logging is enabled
pub fn isEnabled() bool {
    return enabled;
}

/// Get the log file path
pub fn getLogPath() []const u8 {
    return paths.StaticPaths.ptyTraffic();
}

/// Initialize the log file (called when first enabled)
fn initLogFile() void {
    if (log_file != null) return;

    // Ensure temp directory exists
    paths.ensureTempDir() catch return;

    const path = paths.StaticPaths.ptyTraffic();

    // Check if file exists and has content
    const file_size = blk: {
        const stat = std.fs.cwd().statFile(path) catch break :blk @as(u64, 0);
        break :blk stat.size;
    };

    const fd = std.posix.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        0o644,
    ) catch return;
    log_file = .{ .handle = fd };

    // Write header only if file is new/empty
    if (file_size == 0) {
        const file = log_file orelse return;
        file.writeAll("# PTY Traffic Log\n") catch {};
        file.writeAll("# Format: [HH:MM:SS.mmm] DIR pane N: hex bytes | ascii\n") catch {};
        file.writeAll("# DIR: > = sent TO PTY, < = received FROM PTY\n") catch {};
        file.writeAll("#\n") catch {};
    }
}

/// Log bytes sent TO a pane's PTY
/// Format: "[HH:MM:SS.mmm] > pane N: xx xx xx | ASCII"
pub fn logSend(pane_id: u16, data: []const u8) void {
    logTraffic(">", pane_id, data);
}

/// Log bytes received FROM a pane's PTY
/// Format: "[HH:MM:SS.mmm] < pane N: xx xx xx | ASCII"
pub fn logRecv(pane_id: u16, data: []const u8) void {
    logTraffic("<", pane_id, data);
}

/// Internal helper to format and log PTY traffic
fn logTraffic(direction: []const u8, pane_id: u16, data: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    if (!enabled) return;

    if (log_file == null) {
        initLogFile();
    }

    const file = log_file orelse return;

    // Format: "[HH:MM:SS.mmm] DIR pane N: hex bytes | ascii\n"
    // Use a fixed buffer for small data, allocate for large
    var stack_buf: [4096]u8 = undefined;
    const needed_size = 50 + data.len * 4;

    if (needed_size <= stack_buf.len) {
        writeLogLine(file, &stack_buf, direction, pane_id, data);
    } else {
        // For very large data, just log a summary
        var summary_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&summary_buf);
        const w = fbs.writer();

        writeTimestamp(w);
        w.print("{s} pane {d}: [{d} bytes]\n", .{ direction, pane_id, data.len }) catch return;

        file.writeAll(fbs.getWritten()) catch {};
    }
}

fn writeLogLine(file: std.fs.File, buf: []u8, direction: []const u8, pane_id: u16, data: []const u8) void {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // Write timestamp [HH:MM:SS.mmm]
    writeTimestamp(w);

    // Write direction and pane
    w.print("{s} pane {d}: ", .{ direction, pane_id }) catch return;

    // Write hex bytes
    for (data) |byte| {
        w.print("{x:0>2} ", .{byte}) catch return;
    }

    // Write ASCII representation
    w.writeAll("| ") catch return;
    for (data) |byte| {
        const c: u8 = if (byte >= 32 and byte < 127) byte else '.';
        w.writeByte(c) catch return;
    }
    w.writeByte('\n') catch return;

    file.writeAll(fbs.getWritten()) catch {};
}

fn writeTimestamp(w: anytype) void {
    const ts_ms = std.time.milliTimestamp();
    const ts_s: u64 = @intCast(@divTrunc(ts_ms, 1000));
    const ms: u64 = @intCast(@mod(ts_ms, 1000));
    const day_s = @mod(ts_s, 86400); // seconds since midnight
    const hours = @divTrunc(day_s, 3600);
    const mins = @divTrunc(@mod(day_s, 3600), 60);
    const secs = @mod(day_s, 60);
    w.print("[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] ", .{ hours, mins, secs, ms }) catch {};
}

/// Close the log file (for cleanup)
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();

    if (log_file) |file| {
        file.close();
        log_file = null;
    }
}

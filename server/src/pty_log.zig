//! PTY traffic logging
//!
//! Logs PTY I/O traffic to a file in the temp directory.
//! Format: JSONL (one JSON object per line).
//!
//! Usage:
//!   const pty_log = @import("pty_log.zig");
//!   pty_log.logSend(pane_id, data);  // bytes sent TO PTY (origin=response)
//!   pty_log.logRecv(pane_id, data);  // bytes received FROM PTY (origin=program)
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
/// Truncates any existing log file.
fn initLogFile() void {
    if (log_file != null) return;

    // Ensure temp directory exists
    paths.ensureTempDir() catch return;

    const path = paths.StaticPaths.ptyTraffic();

    // Open with truncation - each enable starts fresh
    const fd = std.posix.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    ) catch return;
    log_file = .{ .handle = fd };
}

/// Log bytes sent TO a pane's PTY
pub fn logSend(pane_id: u16, data: []const u8) void {
    logTraffic(.send, pane_id, data);
}

/// Log bytes received FROM a pane's PTY
pub fn logRecv(pane_id: u16, data: []const u8) void {
    logTraffic(.recv, pane_id, data);
}

const Direction = enum {
    send,
    recv,
};

const max_logged_bytes: usize = 512;

/// Internal helper to format and log PTY traffic
fn logTraffic(direction: Direction, pane_id: u16, data: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    if (!enabled) return;

    if (log_file == null) {
        initLogFile();
    }

    const file = log_file orelse return;

    file.seekFromEnd(0) catch {};

    writeLogLine(file, direction, pane_id, data);

    var escape_offsets: [32]u16 = undefined;
    var escape_bytes: [32]u8 = undefined;
    const escape_info = detectEscapeOffsets(data, &escape_offsets, &escape_bytes);
    if (escape_info.count > 0) {
        writeEscapeLine(
            file,
            direction,
            pane_id,
            data,
            escape_offsets[0..escape_info.count],
            escape_bytes[0..escape_info.count],
            escape_info,
        );
    }
}

fn writeLogLine(file: std.fs.File, direction: Direction, pane_id: u16, data: []const u8) void {
    var buf: [8192]u8 = undefined;
    const fw = file.writerStreaming(&buf);
    var w = fw.interface;
    defer w.flush() catch {};
    const origin = if (direction == .send) "response" else "program";
    const dir_str = if (direction == .send) "send" else "recv";
    const ts_ms = std.time.milliTimestamp();
    const truncated = data.len > max_logged_bytes;
    const slice = data[0..@min(data.len, max_logged_bytes)];

    w.print(
        "{{\"ts_ms\":{d},\"event\":\"pty_io\",\"pane_id\":{d},\"origin\":\"{s}\",\"direction\":\"{s}\",\"len\":{d}",
        .{ ts_ms, pane_id, origin, dir_str, data.len },
    ) catch return;

    if (truncated) {
        w.writeAll(",\"truncated\":true") catch return;
    }

    w.writeAll(",\"bytes\":[") catch return;
    writeBytesArray(&w, slice) catch return;
    w.writeAll("],\"text\":\"") catch return;
    writeHumanString(&w, slice) catch return;
    if (truncated) {
        w.writeAll("\",\"text_truncated\":true}") catch return;
    } else {
        w.writeAll("\"}") catch return;
    }
    w.writeByte('\n') catch return;
}

fn writeEscapeLine(
    file: std.fs.File,
    direction: Direction,
    pane_id: u16,
    data: []const u8,
    offsets: []const u16,
    bytes: []const u8,
    info: EscapeInfo,
) void {
    var buf: [8192]u8 = undefined;
    const fw = file.writerStreaming(&buf);
    var w = fw.interface;
    defer w.flush() catch {};
    const origin = if (direction == .send) "response" else "program";
    const dir_str = if (direction == .send) "send" else "recv";
    const ts_ms = std.time.milliTimestamp();
    const truncated = data.len > max_logged_bytes;
    const slice = data[0..@min(data.len, max_logged_bytes)];

    w.print(
        "{{\"ts_ms\":{d},\"event\":\"escape_detected\",\"pane_id\":{d},\"origin\":\"{s}\",\"direction\":\"{s}\",\"len\":{d},\"escape_total\":{d}",
        .{ ts_ms, pane_id, origin, dir_str, data.len, info.total },
    ) catch return;

    if (truncated) {
        w.writeAll(",\"truncated\":true") catch return;
    }
    if (info.truncated) {
        w.writeAll(",\"escape_truncated\":true") catch return;
    }

    w.writeAll(",\"indices\":[") catch return;
    writeU16Array(&w, offsets) catch return;
    w.writeAll("],\"escape_bytes\":[") catch return;
    writeBytesArray(&w, bytes) catch return;
    w.writeAll("],\"bytes\":[") catch return;
    writeBytesArray(&w, slice) catch return;
    w.writeAll("],\"text\":\"") catch return;
    writeHumanString(&w, slice) catch return;
    w.writeAll("\"}") catch return;
    w.writeByte('\n') catch return;
}

fn writeBytesArray(w: *std.Io.Writer, data: []const u8) !void {
    for (data, 0..) |byte, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.print("\"0x{x:0>2}\"", .{byte});
    }
}

fn writeU16Array(w: *std.Io.Writer, data: []const u16) !void {
    for (data, 0..) |value, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.print("{d}", .{value});
    }
}

fn writeHumanString(w: *std.Io.Writer, data: []const u8) !void {
    for (data) |byte| {
        switch (byte) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (byte >= 32 and byte < 127) {
                    try w.writeByte(byte);
                } else {
                    try w.print("\\x{x:0>2}", .{byte});
                }
            },
        }
    }
}

const EscapeInfo = struct {
    count: usize,
    total: usize,
    truncated: bool,
};

fn detectEscapeOffsets(data: []const u8, offsets: []u16, bytes: []u8) EscapeInfo {
    var count: usize = 0;
    var total: usize = 0;
    var truncated = false;

    for (data, 0..) |byte, idx| {
        if (byte == 0x1b or byte == 0x9b or byte == 0x9d or byte == 0x90 or byte == 0x9e or byte == 0x9f) {
            total += 1;
            if (count >= offsets.len or count >= bytes.len) {
                truncated = true;
                continue;
            }
            offsets[count] = @intCast(@min(idx, std.math.maxInt(u16)));
            bytes[count] = byte;
            count += 1;
        }
    }

    return .{
        .count = count,
        .total = total,
        .truncated = truncated,
    };
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

//! PTY traffic logging
//!
//! Logs PTY I/O traffic to a file in the temp directory.
//! Format: JSONL (one JSON object per line).
//!
//! Usage:
//!   const pty_log = @import("pty_log.zig");
//!   pty_log.logSendInput(pane_id, data);    // bytes sent TO PTY (origin=input)
//!   pty_log.logSendResponse(pane_id, data); // bytes sent TO PTY (origin=response)
//!   pty_log.logRecv(pane_id, data);         // bytes received FROM PTY (origin=program)
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
    if (log_file != null) {
        writeControlEvent(if (value) "pty_log_enabled" else "pty_log_disabled");
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

const Direction = enum {
    send,
    recv,
};

const Origin = enum {
    program,
    input,
    response,
};

const max_logged_bytes: usize = 512;

/// Log bytes sent TO a pane's PTY from user input.
pub fn logSendInput(pane_id: u16, data: []const u8) void {
    logTraffic(.send, .input, pane_id, data);
}

/// Log bytes sent TO a pane's PTY as escape/code responses.
pub fn logSendResponse(pane_id: u16, data: []const u8) void {
    logTraffic(.send, .response, pane_id, data);
}

/// Log bytes received FROM a pane's PTY.
pub fn logRecv(pane_id: u16, data: []const u8) void {
    logTraffic(.recv, .program, pane_id, data);
}

/// Internal helper to format and log PTY traffic
fn logTraffic(direction: Direction, origin: Origin, pane_id: u16, data: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    if (!enabled) return;

    if (log_file == null) {
        initLogFile();
    }

    const file = log_file orelse return;

    file.seekFromEnd(0) catch {};

    writeLogLine(file, direction, origin, pane_id, data);
}

fn writeControlEvent(event: []const u8) void {
    const file = log_file orelse return;
    var buf: [512]u8 = undefined;
    var fw = file.writerStreaming(&buf);
    var w = &fw.interface;
    defer w.flush() catch {};

    const ts_ms = std.time.milliTimestamp();
    w.print("{{\"ts_ms\":{d},\"event\":\"{s}\"}}\n", .{ ts_ms, event }) catch return;
}

fn writeLogLine(file: std.fs.File, direction: Direction, origin: Origin, pane_id: u16, data: []const u8) void {
    var buf: [8192]u8 = undefined;
    var fw = file.writerStreaming(&buf);
    var w = &fw.interface;
    defer w.flush() catch {};
    const dir_str = if (direction == .send) "send" else "recv";
    const origin_str = switch (origin) {
        .program => "program",
        .input => "input",
        .response => "response",
    };
    const ts_ms = std.time.milliTimestamp();
    const truncated = data.len > max_logged_bytes;
    const slice = data[0..@min(data.len, max_logged_bytes)];

    w.print(
        "{{\"ts_ms\":{d},\"event\":\"pty_io\",\"pane_id\":{d},\"origin\":\"{s}\",\"direction\":\"{s}\",\"len\":{d}",
        .{ ts_ms, pane_id, origin_str, dir_str, data.len },
    ) catch return;

    if (truncated) {
        w.writeAll(",\"truncated\":true") catch return;
    }

    w.writeAll(",\"bytes\":[") catch return;
    writeBytesArray(w, slice) catch return;
    w.writeAll("],\"text\":\"") catch return;
    writeHumanString(w, slice) catch return;
    if (truncated) {
        w.writeAll("\",\"text_truncated\":true}") catch return;
    } else {
        w.writeAll("\"}") catch return;
    }
    w.writeByte('\n') catch return;
}

fn writeBytesArray(w: *std.Io.Writer, data: []const u8) !void {
    for (data, 0..) |byte, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.print("\"0x{x:0>2}\"", .{byte});
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

/// Close the log file (for cleanup)
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();

    if (log_file) |file| {
        file.close();
        log_file = null;
    }
}

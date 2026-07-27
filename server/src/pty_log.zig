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
var app_io: ?std.Io = null;
var log_writer: ?std.Io.File.Writer = null;
var log_buffer: [8192]u8 = undefined;
var enabled: bool = false;
var mutex: std.Io.Mutex = .init;

pub fn init(io: std.Io) void {
    app_io = io;
}

fn currentIo() std.Io {
    return app_io orelse std.Io.Threaded.global_single_threaded.io();
}

/// Enable or disable PTY traffic logging
pub fn setEnabled(value: bool) void {
    const io = currentIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    enabled = value;

    if (value and log_writer == null) {
        initLogFile(io);
    }
    if (log_writer != null) {
        writeControlEvent(io, if (value) "pty_log_enabled" else "pty_log_disabled");
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
fn initLogFile(io: std.Io) void {
    if (log_writer != null) return;

    // Ensure temp directory exists
    paths.ensureTempDir(io) catch return;

    const path = paths.StaticPaths.ptyTraffic();
    const file = std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = true,
        .permissions = @enumFromInt(0o644),
    }) catch return;
    log_writer = file.writer(io, &log_buffer);
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
    const io = currentIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (!enabled) return;

    if (log_writer == null) {
        initLogFile(io);
    }

    writeLogLine(io, direction, origin, pane_id, data);
}

fn writeControlEvent(io: std.Io, event: []const u8) void {
    const writer = if (log_writer) |*writer| writer else return;
    const w = &writer.interface;
    const ts_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    w.print("{{\"ts_ms\":{d},\"event\":\"{s}\"}}\n", .{ ts_ms, event }) catch return;
    w.flush() catch {};
}

fn writeLogLine(io: std.Io, direction: Direction, origin: Origin, pane_id: u16, data: []const u8) void {
    const writer = if (log_writer) |*writer| writer else return;
    const w = &writer.interface;
    const dir_str = if (direction == .send) "send" else "recv";
    const origin_str = switch (origin) {
        .program => "program",
        .input => "input",
        .response => "response",
    };
    const ts_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const slice = data;

    w.print(
        "{{\"ts_ms\":{d},\"event\":\"pty_io\",\"pane_id\":{d},\"origin\":\"{s}\",\"direction\":\"{s}\",\"len\":{d}",
        .{ ts_ms, pane_id, origin_str, dir_str, data.len },
    ) catch return;

    w.writeAll(",\"bytes\":[") catch return;
    writeBytesArray(w, slice) catch return;
    w.writeAll("],\"text\":\"") catch return;
    writeHumanString(w, slice) catch return;
    w.writeAll("\"}") catch return;
    w.writeByte('\n') catch return;
    w.flush() catch {};
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
    const io = currentIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (log_writer) |*writer| {
        writer.interface.flush() catch {};
        writer.file.close(io);
        log_writer = null;
    }
    app_io = null;
}

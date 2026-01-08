//! Dullahan unified logging system
//!
//! Provides logging to three channels:
//! 1. Log file (/tmp/dullahan.log) - always
//! 2. Debug console (pane 0) - when session is set
//! 3. Stderr - for errors and unimplemented features
//!
//! Usage:
//!   const dlog = @import("dlog.zig");
//!   dlog.info("Connected client", .{});
//!   dlog.err("Failed to bind: {any}", .{e});
//!   dlog.missing("DSR mode {d}", .{mode});  // unimplemented feature

const std = @import("std");
const Pane = @import("pane.zig").Pane;

/// Log file path (separate from main.zig's log to avoid conflicts)
const log_file_path = "/tmp/dullahan-dlog.log";

/// Global state for logging
var log_file: ?std.fs.File = null;
var debug_pane: ?*Pane = null;
var debug_pane_mutex: std.Thread.Mutex = .{};

/// Initialize the log file (called automatically on first log)
fn initLogFile() void {
    if (log_file != null) return;
    // Open with append mode via posix
    const fd = std.posix.open(
        log_file_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        0o644,
    ) catch return;
    log_file = .{ .handle = fd };
}

/// Set the debug pane for console logging
/// Call this after session is initialized
pub fn setDebugPane(pane: ?*Pane) void {
    debug_pane_mutex.lock();
    defer debug_pane_mutex.unlock();
    debug_pane = pane;
}

/// Get current timestamp string [HH:MM:SS.mmm]
fn getTimestamp(buf: []u8) []const u8 {
    const ts_ms = std.time.milliTimestamp();
    const ts_s: u64 = @intCast(@divTrunc(ts_ms, 1000));
    const ms: u64 = @intCast(@mod(ts_ms, 1000));
    const day_s = @mod(ts_s, 86400);
    const hours = @divTrunc(day_s, 3600);
    const mins = @divTrunc(@mod(day_s, 3600), 60);
    const secs = @mod(day_s, 60);
    return std.fmt.bufPrint(buf, "[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}]", .{ hours, mins, secs, ms }) catch "[??:??:??.???]";
}

/// Core logging function
fn logImpl(
    comptime level: Level,
    comptime format: []const u8,
    args: anytype,
    to_stderr: bool,
) void {
    // Format the message
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch return;

    // Get timestamp
    var ts_buf: [16]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Format full line for file
    var line_buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s} {s}: {s}\n", .{ timestamp, level.asText(), msg }) catch return;

    // 1. Always log to file
    initLogFile();
    if (log_file) |file| {
        file.writeAll(line) catch {};
    }

    // 2. Log to debug console if available
    debug_pane_mutex.lock();
    const pane = debug_pane;
    debug_pane_mutex.unlock();

    if (pane) |p| {
        // Format with color for terminal
        var term_buf: [4096]u8 = undefined;
        const term_line = std.fmt.bufPrint(&term_buf, "\x1b[90m{s}\x1b[0m {s}{s}\x1b[0m: {s}\r\n", .{
            timestamp,
            level.color(),
            level.asText(),
            msg,
        }) catch return;
        p.feedDirect(term_line) catch {};
    }

    // 3. Log to stderr if requested (errors, missing features)
    if (to_stderr) {
        std.debug.print("{s} {s}: {s}\n", .{ timestamp, level.asText(), msg });
    }
}

/// Log levels
pub const Level = enum {
    debug,
    info,
    warn,
    err,
    missing, // Unimplemented features

    pub fn asText(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .missing => "MISSING",
        };
    }

    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // cyan
            .info => "\x1b[32m", // green
            .warn => "\x1b[33m", // yellow
            .err => "\x1b[31m", // red
            .missing => "\x1b[35m", // magenta
        };
    }
};

/// Log debug message (file + console)
pub fn debug(comptime format: []const u8, args: anytype) void {
    logImpl(.debug, format, args, false);
}

/// Log info message (file + console)
pub fn info(comptime format: []const u8, args: anytype) void {
    logImpl(.info, format, args, false);
}

/// Log warning (file + console)
pub fn warn(comptime format: []const u8, args: anytype) void {
    logImpl(.warn, format, args, false);
}

/// Log error (file + console + stderr)
pub fn err(comptime format: []const u8, args: anytype) void {
    logImpl(.err, format, args, true);
}

/// Log unimplemented/missing feature (file + console + stderr)
/// Use this when encountering escape sequences or features we don't handle
pub fn missing(comptime format: []const u8, args: anytype) void {
    logImpl(.missing, format, args, true);
}

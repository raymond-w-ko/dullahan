//! Dullahan unified logging system with Wine-style category support
//!
//! Provides logging to three channels:
//! 1. Log file (/tmp/dullahan-<uid>/dullahan-<port>.log) - always (shared)
//! 2. Debug console (pane 0) - when session is set
//! 3. Stderr - for errors, unimplemented features, AND all logs in debug builds
//!
//! In debug builds (zig build without -Doptimize), ALL logs go to stderr
//! for easier development. In release builds, only errors go to stderr.
//!
//! Category-scoped logging (preferred):
//!   const log = @import("dlog.zig").scoped(.clipboard);
//!   log.info("OSC 52 received", .{});  // Only logs if clipboard category enabled
//!
//! Uncategorized logging (always logs):
//!   const dlog = @import("dlog.zig");
//!   dlog.info("Server started", .{});
//!   dlog.err("Failed to bind: {any}", .{e});
//!   dlog.missing("DSR mode {d}", .{mode});  // unimplemented feature
//!
//! Configure at runtime:
//!   DULLAHAN_DEBUG=+all,-mouse  (environment variable)
//!   dullahan debug-log +all,-delta  (IPC command)

const std = @import("std");
const builtin = @import("builtin");
const Pane = @import("pane.zig").Pane;
const paths = @import("paths.zig");
const debug_config = @import("debug_config.zig");
const posix_compat = @import("posix_compat.zig");

/// Comptime check: are we in a debug build?
/// In debug builds, all logs go to stderr for easier development.
const is_debug_build = builtin.mode == .Debug;

pub const Category = debug_config.Category;

/// Global state for logging
var app_io: ?std.Io = null;
var log_writer: ?std.Io.File.Writer = null;
var log_buffer: [8192]u8 = undefined;
var log_mutex: std.Io.Mutex = .init;
var debug_pane: ?*Pane = null;
var debug_pane_mutex: std.Io.Mutex = .init;
var initialized: bool = false;

/// Initialize logging system (load env config, open log file)
pub fn init(io: std.Io, debug_env: ?[]const u8) void {
    if (initialized) return;
    app_io = io;
    initialized = true;
    debug_config.init(io, debug_env);

    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);
    initLogFile(io);
}

pub fn deinit() void {
    const io = app_io orelse return;
    log_mutex.lockUncancelable(io);
    if (log_writer) |*writer| {
        writer.interface.flush() catch {};
        writer.file.close(io);
        log_writer = null;
    }
    log_mutex.unlock(io);
    debug_config.deinit();
    initialized = false;
    app_io = null;
}

fn currentIo() std.Io {
    return app_io orelse std.Io.Threaded.global_single_threaded.io();
}

/// Initialize the log file (called automatically on first log)
fn initLogFile(io: std.Io) void {
    if (log_writer != null) return;

    // Ensure temp directory exists
    paths.ensureTempDir(io) catch return;

    const log_file_path = paths.StaticPaths.log();
    const fd = posix_compat.openAppend(log_file_path, 0o644) catch return;
    const file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    log_writer = file.writerStreaming(io, &log_buffer);
}

/// Set the debug pane for console logging
/// Call this after session is initialized
pub fn setDebugPane(pane: ?*Pane) void {
    const io = currentIo();
    debug_pane_mutex.lockUncancelable(io);
    defer debug_pane_mutex.unlock(io);
    debug_pane = pane;
}

/// Get current timestamp string [HH:MM:SS.mmm]
fn getTimestamp(io: std.Io, buf: []u8) []const u8 {
    const ts_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
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
    comptime category: ?Category,
    comptime format: []const u8,
    args: anytype,
    to_stderr: bool,
) void {
    // Format the message
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch return;
    writeLine(level, if (category) |c| c.asText() else "", msg, to_stderr);
}

fn writeLine(
    comptime level: Level,
    category: []const u8,
    msg: []const u8,
    to_stderr: bool,
) void {
    const io = currentIo();

    // Get timestamp
    var ts_buf: [16]u8 = undefined;
    const timestamp = getTimestamp(io, &ts_buf);

    // Format full line for file
    var line_buf: [4096]u8 = undefined;
    const line = if (category.len > 0)
        std.fmt.bufPrint(&line_buf, "{s} {s} ({s}): {s}\n", .{ timestamp, level.asText(), category, msg }) catch return
    else
        std.fmt.bufPrint(&line_buf, "{s} {s}: {s}\n", .{ timestamp, level.asText(), msg }) catch return;

    // 1. Always log to file
    log_mutex.lockUncancelable(io);
    initLogFile(io);
    if (log_writer) |*writer| {
        writer.interface.writeAll(line) catch {};
        writer.interface.flush() catch {};
    }
    log_mutex.unlock(io);

    // 2. Log to debug console if available
    debug_pane_mutex.lockUncancelable(io);
    const pane = debug_pane;
    debug_pane_mutex.unlock(io);

    if (pane) |p| {
        // Format with color for terminal
        var term_buf: [4096]u8 = undefined;
        const term_line = if (category.len > 0)
            std.fmt.bufPrint(&term_buf, "\x1b[90m{s}\x1b[0m {s}{s}\x1b[0m \x1b[90m({s})\x1b[0m: {s}\r\n", .{
                timestamp,
                level.color(),
                level.asText(),
                category,
                msg,
            }) catch return
        else
            std.fmt.bufPrint(&term_buf, "\x1b[90m{s}\x1b[0m {s}{s}\x1b[0m: {s}\r\n", .{
                timestamp,
                level.color(),
                level.asText(),
                msg,
            }) catch return;
        p.feedDirect(term_line) catch {};
    }

    // 3. Log to stderr if requested (errors, missing features) or in debug builds
    if (to_stderr or is_debug_build) {
        if (category.len > 0) {
            std.debug.print("{s} {s} ({s}): {s}\n", .{ timestamp, level.asText(), category, msg });
        } else {
            std.debug.print("{s} {s}: {s}\n", .{ timestamp, level.asText(), msg });
        }
    }
}

pub fn stdLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch return;
    const mapped_level: Level = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
    writeLine(mapped_level, if (scope == .default) "" else @tagName(scope), msg, level == .err);
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

// ============================================================================
// Uncategorized logging (always logs, for critical messages)
// ============================================================================

/// Log debug message (file + console)
pub fn debug(comptime format: []const u8, args: anytype) void {
    logImpl(.debug, null, format, args, false);
}

/// Log info message (file + console)
pub fn info(comptime format: []const u8, args: anytype) void {
    logImpl(.info, null, format, args, false);
}

/// Log warning (file + console)
pub fn warn(comptime format: []const u8, args: anytype) void {
    logImpl(.warn, null, format, args, false);
}

/// Log error (file + console + stderr)
pub fn err(comptime format: []const u8, args: anytype) void {
    logImpl(.err, null, format, args, true);
}

/// Log unimplemented/missing feature (file + console + stderr)
/// Use this when encountering escape sequences or features we don't handle
pub fn missing(comptime format: []const u8, args: anytype) void {
    logImpl(.missing, null, format, args, true);
}

// ============================================================================
// Category-scoped logging (respects debug config)
// ============================================================================

/// Scoped logger that respects category configuration
pub fn ScopedLogger(comptime category: Category) type {
    return struct {
        /// Log debug message if category enabled
        pub fn debug(comptime format: []const u8, args: anytype) void {
            if (!debug_config.isEnabled(category)) return;
            logImpl(.debug, category, format, args, false);
        }

        /// Log info message if category enabled
        pub fn info(comptime format: []const u8, args: anytype) void {
            if (!debug_config.isEnabled(category)) return;
            logImpl(.info, category, format, args, false);
        }

        /// Log warning if category enabled
        pub fn warn(comptime format: []const u8, args: anytype) void {
            if (!debug_config.isEnabled(category)) return;
            logImpl(.warn, category, format, args, false);
        }

        /// Log error (always logs, regardless of category - errors are important)
        pub fn err(comptime format: []const u8, args: anytype) void {
            logImpl(.err, category, format, args, true);
        }
    };
}

/// Create a category-scoped logger
/// Usage: const log = dlog.scoped(.clipboard);
pub fn scoped(comptime category: Category) type {
    return ScopedLogger(category);
}

// ============================================================================
// Config access (re-exported from debug_config)
// ============================================================================

/// Set debug config from string (e.g., "+all,-mouse")
pub const setConfig = debug_config.setConfigString;

/// Get current config string
pub const getConfigString = debug_config.getConfigString;

/// Check if any logging is enabled
pub const isAnyEnabled = debug_config.isAnyEnabled;

/// List all categories
pub const ALL_CATEGORIES = debug_config.ALL_CATEGORIES;

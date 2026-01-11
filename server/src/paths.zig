//! Path utilities for dullahan
//!
//! Provides runtime directory and file paths that include the user's UID
//! to prevent conflicts between users on shared systems.
//!
//! All temp files are placed in /tmp/dullahan-<uid>/ directory.

const std = @import("std");
const posix = std.posix;

/// Get the UID-specific temp directory path: /tmp/dullahan-<uid>
/// Returns a static buffer that is valid for the lifetime of the program.
pub fn getTempDir() []const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        var initialized: bool = false;
    };

    if (!S.initialized) {
        const uid = posix.getuid();
        S.len = (std.fmt.bufPrint(&S.buf, "/tmp/dullahan-{d}", .{uid}) catch "/tmp/dullahan-0").len;
        S.initialized = true;
    }

    return S.buf[0..S.len];
}

/// Ensure the temp directory exists, creating it if necessary.
/// Returns error if directory cannot be created.
pub fn ensureTempDir() !void {
    const dir_path = getTempDir();
    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

/// Get full path for a file in the temp directory.
/// Caller owns the returned slice and must free it with the provided allocator.
pub fn getTempPath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const dir = getTempDir();
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
}

/// Static paths for commonly used files.
/// These use static buffers and don't require allocation.
pub const StaticPaths = struct {
    var socket_buf: [80]u8 = undefined;
    var socket_len: usize = 0;
    var socket_initialized: bool = false;

    var pid_buf: [80]u8 = undefined;
    var pid_len: usize = 0;
    var pid_initialized: bool = false;

    var log_buf: [80]u8 = undefined;
    var log_len: usize = 0;
    var log_initialized: bool = false;

    var dlog_buf: [80]u8 = undefined;
    var dlog_len: usize = 0;
    var dlog_initialized: bool = false;

    var capture_buf: [80]u8 = undefined;
    var capture_len: usize = 0;
    var capture_initialized: bool = false;

    var keytest_log_buf: [80]u8 = undefined;
    var keytest_log_len: usize = 0;
    var keytest_log_initialized: bool = false;

    var pty_traffic_buf: [80]u8 = undefined;
    var pty_traffic_len: usize = 0;
    var pty_traffic_initialized: bool = false;

    /// Socket path: /tmp/dullahan-<uid>/dullahan.sock
    pub fn socket() []const u8 {
        if (!socket_initialized) {
            const dir = getTempDir();
            socket_len = (std.fmt.bufPrint(&socket_buf, "{s}/dullahan.sock", .{dir}) catch
                return "/tmp/dullahan.sock").len;
            socket_initialized = true;
        }
        return socket_buf[0..socket_len];
    }

    /// PID file path: /tmp/dullahan-<uid>/dullahan.pid
    pub fn pid() []const u8 {
        if (!pid_initialized) {
            const dir = getTempDir();
            pid_len = (std.fmt.bufPrint(&pid_buf, "{s}/dullahan.pid", .{dir}) catch
                return "/tmp/dullahan.pid").len;
            pid_initialized = true;
        }
        return pid_buf[0..pid_len];
    }

    /// Main log file path: /tmp/dullahan-<uid>/dullahan.log
    pub fn log() []const u8 {
        if (!log_initialized) {
            const dir = getTempDir();
            log_len = (std.fmt.bufPrint(&log_buf, "{s}/dullahan.log", .{dir}) catch
                return "/tmp/dullahan.log").len;
            log_initialized = true;
        }
        return log_buf[0..log_len];
    }

    /// Debug log file path: /tmp/dullahan-<uid>/dullahan-dlog.log
    pub fn dlog() []const u8 {
        if (!dlog_initialized) {
            const dir = getTempDir();
            dlog_len = (std.fmt.bufPrint(&dlog_buf, "{s}/dullahan-dlog.log", .{dir}) catch
                return "/tmp/dullahan-dlog.log").len;
            dlog_initialized = true;
        }
        return dlog_buf[0..dlog_len];
    }

    /// Capture hex file path: /tmp/dullahan-<uid>/dullahan-capture.hex
    pub fn capture() []const u8 {
        if (!capture_initialized) {
            const dir = getTempDir();
            capture_len = (std.fmt.bufPrint(&capture_buf, "{s}/dullahan-capture.hex", .{dir}) catch
                return "/tmp/dullahan-capture.hex").len;
            capture_initialized = true;
        }
        return capture_buf[0..capture_len];
    }

    /// Keytest log file path: /tmp/dullahan-<uid>/keytest-kitty.log
    pub fn keytestLog() []const u8 {
        if (!keytest_log_initialized) {
            const dir = getTempDir();
            keytest_log_len = (std.fmt.bufPrint(&keytest_log_buf, "{s}/keytest-kitty.log", .{dir}) catch
                return "/tmp/keytest-kitty.log").len;
            keytest_log_initialized = true;
        }
        return keytest_log_buf[0..keytest_log_len];
    }

    /// PTY traffic log file path: /tmp/dullahan-<uid>/pty-traffic.log
    pub fn ptyTraffic() []const u8 {
        if (!pty_traffic_initialized) {
            const dir = getTempDir();
            pty_traffic_len = (std.fmt.bufPrint(&pty_traffic_buf, "{s}/pty-traffic.log", .{dir}) catch
                return "/tmp/pty-traffic.log").len;
            pty_traffic_initialized = true;
        }
        return pty_traffic_buf[0..pty_traffic_len];
    }
};

test "getTempDir returns valid path" {
    const dir = getTempDir();
    try std.testing.expect(std.mem.startsWith(u8, dir, "/tmp/dullahan-"));
}

test "StaticPaths returns valid paths" {
    const socket = StaticPaths.socket();
    try std.testing.expect(std.mem.endsWith(u8, socket, "/dullahan.sock"));

    const pid = StaticPaths.pid();
    try std.testing.expect(std.mem.endsWith(u8, pid, "/dullahan.pid"));
}

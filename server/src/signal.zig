//! Signal handling for graceful shutdown
//!
//! Provides a global shutdown flag that can be set by signal handlers
//! and checked by the main loop and worker threads.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.signal);

/// Global atomic shutdown flag
/// Set to true when SIGINT/SIGTERM is received
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Check if shutdown has been requested
pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

/// Request shutdown (can be called from any thread)
pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

/// Signal handler function (called in signal context)
/// Must use C calling convention for POSIX signal handling
fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    // Set the atomic flag - this is async-signal-safe
    shutdown_requested.store(true, .release);
}

/// Install signal handlers for SIGINT and SIGTERM
pub fn install() void {
    // Setup signal action struct
    const sa = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART, // Restart interrupted syscalls
    };

    // Install handler for SIGINT (Ctrl+C)
    posix.sigaction(posix.SIG.INT, &sa, null);
    log.info("Installed SIGINT handler", .{});

    // Install handler for SIGTERM (kill command)
    posix.sigaction(posix.SIG.TERM, &sa, null);
    log.info("Installed SIGTERM handler", .{});

    // Set SIGCHLD to SIG_IGN with SA_NOCLDWAIT to auto-reap child processes
    // This prevents zombie processes when shell children exit
    const sa_chld = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.NOCLDWAIT,
    };
    posix.sigaction(posix.SIG.CHLD, &sa_chld, null);
    log.info("Installed SIGCHLD handler (auto-reap)", .{});
}

/// Reset signal handlers to default
pub fn reset() void {
    const sa = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.CHLD, &sa, null);
}

test "shutdown flag starts false" {
    try std.testing.expect(!isShutdownRequested());
}

test "requestShutdown sets flag" {
    // Reset for test
    shutdown_requested.store(false, .release);
    try std.testing.expect(!isShutdownRequested());

    requestShutdown();
    try std.testing.expect(isShutdownRequested());

    // Reset after test
    shutdown_requested.store(false, .release);
}

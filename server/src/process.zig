//! Process utilities
//!
//! Helper functions for child process management that aren't
//! specific to terminal/pane functionality.

const std = @import("std");
const posix = std.posix;
const constants = @import("constants.zig");

const log = std.log.scoped(.process);

/// Try non-blocking waitpid, returns true if child exited/reaped or doesn't exist.
/// Uses C library waitpid directly to handle ECHILD (std.posix.waitpid panics on it).
pub fn tryWaitpid(pid: posix.pid_t) bool {
    const c = @cImport({
        @cInclude("sys/wait.h");
    });
    var status: c_int = 0;
    const ret = c.waitpid(pid, &status, c.WNOHANG);
    if (ret == -1) {
        // ECHILD or other error means child doesn't exist
        log.debug("waitpid returned -1, assuming child gone", .{});
        return true;
    }
    return ret != 0;
}

/// Try to reap a child process with timeout, handling all error cases.
/// Sends SIGTERM first, waits for grace period, then SIGKILL if needed.
pub fn reapChild(pid: posix.pid_t) void {
    // Check if already exited
    if (tryWaitpid(pid)) return;

    // Child still running, send SIGTERM
    log.debug("Child still running, sending SIGTERM", .{});
    _ = posix.kill(pid, posix.SIG.TERM) catch {};

    // Wait for graceful exit
    var waited: usize = 0;
    while (waited < constants.timeout.sigterm_grace_ms) : (waited += constants.process.poll_interval_ms) {
        std.Thread.sleep(constants.process.poll_interval_ms * std.time.ns_per_ms);
        if (tryWaitpid(pid)) return;
    }

    // Still running, send SIGKILL
    log.debug("Child did not exit, sending SIGKILL", .{});
    _ = posix.kill(pid, posix.SIG.KILL) catch {};

    // Wait for SIGKILL to take effect
    var kill_waited: usize = 0;
    while (kill_waited < constants.timeout.sigkill_wait_ms) : (kill_waited += constants.process.sigkill_poll_interval_ms) {
        std.Thread.sleep(constants.process.sigkill_poll_interval_ms * std.time.ns_per_ms);
        if (tryWaitpid(pid)) return;
    }

    // Give up - process may be in uninterruptible sleep
    log.warn("Child {d} did not exit after SIGKILL, abandoning", .{pid});
}

test "tryWaitpid returns true for non-existent pid" {
    // Use a PID that's very unlikely to exist
    // Note: This test is somewhat fragile as it depends on system state
    const unlikely_pid: posix.pid_t = 999999;
    const result = tryWaitpid(unlikely_pid);
    // Should return true because the process doesn't exist
    try std.testing.expect(result);
}

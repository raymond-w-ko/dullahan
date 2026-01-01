//! NotifyPipe - Cross-thread notification via self-pipe trick
//!
//! Used to wake up WS threads when PTY reader has new data.
//! Works on Linux and macOS. Windows would need socket pair instead.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const log = std.log.scoped(.notify_pipe);

pub const NotifyPipe = struct {
    /// Read end - WS threads poll on this
    read_fd: posix.fd_t,
    /// Write end - PTY reader signals via this
    write_fd: posix.fd_t,

    /// Create a new notification pipe with both ends non-blocking
    pub fn init() !NotifyPipe {
        const fds = try posix.pipe();

        // Set both ends to non-blocking
        setNonBlocking(fds[0]) catch |e| {
            posix.close(fds[0]);
            posix.close(fds[1]);
            return e;
        };
        setNonBlocking(fds[1]) catch |e| {
            posix.close(fds[0]);
            posix.close(fds[1]);
            return e;
        };

        log.debug("NotifyPipe created: read_fd={d}, write_fd={d}", .{ fds[0], fds[1] });

        return .{
            .read_fd = fds[0],
            .write_fd = fds[1],
        };
    }

    /// Close both ends of the pipe
    pub fn deinit(self: *NotifyPipe) void {
        posix.close(self.read_fd);
        posix.close(self.write_fd);
        log.debug("NotifyPipe closed", .{});
    }

    /// Signal waiting threads by writing a byte to the pipe.
    /// Safe to call from any thread. Ignores errors (pipe full = already signaled).
    pub fn signal(self: *NotifyPipe) void {
        const byte = [_]u8{'x'};
        _ = posix.write(self.write_fd, &byte) catch |e| {
            // EAGAIN/WouldBlock means pipe is full - that's fine, already signaled
            if (e != error.WouldBlock) {
                log.warn("NotifyPipe signal failed: {any}", .{e});
            }
        };
    }

    /// Drain all bytes from the pipe (call after waking up).
    /// This clears the "signaled" state so poll() will block again.
    pub fn drain(self: *NotifyPipe) void {
        var buf: [64]u8 = undefined;
        while (true) {
            _ = posix.read(self.read_fd, &buf) catch |e| {
                // WouldBlock means pipe is empty - we're done
                if (e == error.WouldBlock) break;
                log.warn("NotifyPipe drain failed: {any}", .{e});
                break;
            };
        }
    }

    /// Get the read fd for polling
    pub fn getFd(self: *const NotifyPipe) posix.fd_t {
        return self.read_fd;
    }

    /// Set O_NONBLOCK on a file descriptor
    fn setNonBlocking(fd: posix.fd_t) !void {
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        // O_NONBLOCK is a u32 packed struct, flags is usize - combine properly
        const o_nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        const new_flags = flags | @as(usize, o_nonblock);
        _ = try posix.fcntl(fd, posix.F.SETFL, new_flags);
    }
};

test "notify pipe signal and drain" {
    var pipe = try NotifyPipe.init();
    defer pipe.deinit();

    // Signal should not block
    pipe.signal();
    pipe.signal();
    pipe.signal();

    // Drain should clear all signals
    pipe.drain();

    // Poll should return immediately if signaled
    var fds = [_]posix.pollfd{
        .{ .fd = pipe.getFd(), .events = posix.POLL.IN, .revents = 0 },
    };

    // Should timeout (no signal)
    const ready1 = try posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 0), ready1);

    // Signal and poll again
    pipe.signal();
    const ready2 = try posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 1), ready2);
    try std.testing.expect(fds[0].revents & posix.POLL.IN != 0);
}

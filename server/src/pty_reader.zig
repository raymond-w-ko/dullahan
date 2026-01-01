//! PTY Reader - I/O multiplexer for reading from multiple PTYs
//!
//! Runs in a dedicated thread, polls all PTY master fds, and feeds
//! output to the corresponding panes.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const Session = @import("session.zig").Session;
const Pane = @import("pane.zig").Pane;
const NotifyPipe = @import("notify_pipe.zig").NotifyPipe;

const log = std.log.scoped(.pty_reader);

pub const PtyReader = struct {
    allocator: std.mem.Allocator,
    running: bool = true,
    session: *Session,

    pub fn init(allocator: std.mem.Allocator, session: *Session) PtyReader {
        return .{
            .allocator = allocator,
            .session = session,
        };
    }

    /// Run the PTY reader loop (call from dedicated thread)
    pub fn run(self: *PtyReader) void {
        log.info("PTY reader starting", .{});

        var buf: [4096]u8 = undefined;

        while (self.running) {
            // Collect all PTY fds from all panes
            var fds: [64]posix.pollfd = undefined;
            var pane_ptrs: [64]*Pane = undefined;
            var nfds: usize = 0;

            // Iterate through all windows and panes
            var window_it = self.session.windows.valueIterator();
            while (window_it.next()) |window| {
                var pane_it = window.panes.valueIterator();
                while (pane_it.next()) |pane| {
                    if (pane.getPtyFd()) |fd| {
                        if (nfds < fds.len) {
                            fds[nfds] = .{
                                .fd = fd,
                                .events = posix.POLL.IN,
                                .revents = 0,
                            };
                            pane_ptrs[nfds] = pane;
                            nfds += 1;
                        }
                    }
                }
            }

            if (nfds == 0) {
                // No PTYs to poll, sleep and retry
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }

            // Poll with 1s timeout (just for shutdown check, data wakes immediately)
            const ready = posix.poll(fds[0..nfds], 1000) catch |e| {
                log.err("poll error: {any}", .{e});
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };

            if (ready == 0) {
                // Timeout, no data
                continue;
            }

            // Read from ready fds
            for (0..nfds) |i| {
                if (fds[i].revents & posix.POLL.IN != 0) {
                    const pane = pane_ptrs[i];
                    if (pane.pty) |*pty| {
                        const n = pty.read(&buf) catch |e| {
                            if (e == error.InputOutput or e == error.BrokenPipe) {
                                // PTY closed (child exited)
                                log.info("PTY closed for pane {d}", .{pane.id});
                                _ = pane.isAlive(); // This will reap the child
                            } else {
                                log.err("PTY read error: {any}", .{e});
                            }
                            continue;
                        };

                        if (n > 0) {
                            pane.feed(buf[0..n]) catch |e| {
                                log.err("Failed to feed pane: {any}", .{e});
                            };
                            // Signal WS threads that new data is available
                            self.session.notify_pipe.signal();
                        }
                    }
                }

                // Check for hangup/error
                if (fds[i].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                    const pane = pane_ptrs[i];
                    log.info("PTY hangup/error for pane {d}", .{pane.id});
                    _ = pane.isAlive(); // Reap child
                }
            }
        }

        log.info("PTY reader stopped", .{});
    }

    pub fn stop(self: *PtyReader) void {
        self.running = false;
    }
};

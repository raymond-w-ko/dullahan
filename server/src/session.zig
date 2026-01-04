//! Session - the top-level container for windows
//!
//! A session represents a dullahan server instance with one or more windows.
//! Each window contains one or more panes.
//!
//! Addressing: (window_id, pane_id) provides 2D indexing into terminal panes.
//!
//! Pane layout:
//!   - Pane 0: Debug pane (virtual, no PTY) - shows PTY I/O traffic
//!   - Pane 1: Shell terminal 1
//!   - Pane 2: Shell terminal 2

const std = @import("std");
const posix = std.posix;
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const Pty = @import("pty.zig").Pty;
const NotifyPipe = @import("notify_pipe.zig").NotifyPipe;

/// Debug pane ID (virtual pane for debug output, no shell)
pub const DEBUG_PANE_ID: u16 = 0;

/// First shell pane ID
pub const SHELL_PANE_1_ID: u16 = 1;

/// Second shell pane ID
pub const SHELL_PANE_2_ID: u16 = 2;

pub const Session = struct {
    /// Windows in this session, indexed by window ID
    windows: std.AutoHashMap(u16, Window),

    /// The currently active window ID
    active_window_id: u16,

    /// Next window ID to assign
    next_window_id: u16 = 0,

    /// Default dimensions for new windows/panes
    default_cols: u16,
    default_rows: u16,

    /// Allocator
    allocator: std.mem.Allocator,

    /// Notification pipe for PTY reader -> WS threads signaling
    notify_pipe: NotifyPipe,

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Session {
        var session = Session{
            .windows = std.AutoHashMap(u16, Window).init(allocator),
            .active_window_id = 0,
            .default_cols = opts.cols,
            .default_rows = opts.rows,
            .allocator = allocator,
            .notify_pipe = try NotifyPipe.init(),
        };

        // Create window without auto-creating pane (we'll create 3 manually)
        const window_id = session.next_window_id;
        session.next_window_id += 1;

        var window = try Window.initWithOptions(allocator, .{
            .cols = opts.cols,
            .rows = opts.rows,
            .id = window_id,
        }, .{ .create_initial_pane = false });

        // Create pane 0: Debug pane (no shell)
        _ = try window.createPane();
        // Create pane 1: Shell terminal 1
        _ = try window.createPane();
        // Create pane 2: Shell terminal 2
        _ = try window.createPane();

        // Set active pane to first shell (pane 1), not debug pane
        window.active_pane_id = SHELL_PANE_1_ID;

        try session.windows.put(window_id, window);
        session.active_window_id = window_id;

        // Initialize debug pane with welcome message
        if (session.getDebugPane()) |debug_pane| {
            try debug_pane.feedDirect("\x1b[1;36m=== Dullahan Debug Console ===\x1b[0m\r\n");
            try debug_pane.feedDirect("PTY I/O traffic will be logged here.\r\n");
            try debug_pane.feedDirect("\x1b[31m> pane N: bytes sent TO pty (red)\x1b[0m\r\n");
            try debug_pane.feedDirect("\x1b[34m< pane N: bytes recv FROM pty (blue)\x1b[0m\r\n\r\n");
        }

        return session;
    }

    pub fn deinit(self: *Session) void {
        self.notify_pipe.deinit();
        var it = self.windows.valueIterator();
        while (it.next()) |window| {
            window.deinit();
        }
        self.windows.deinit();
    }

    /// Create a new window
    pub fn createWindow(self: *Session) !u16 {
        const window_id = self.next_window_id;
        self.next_window_id += 1;

        const window = try Window.init(self.allocator, .{
            .cols = self.default_cols,
            .rows = self.default_rows,
            .id = window_id,
        });

        try self.windows.put(window_id, window);
        self.active_window_id = window_id;

        return window_id;
    }

    /// Get a window by ID
    pub fn getWindow(self: *Session, window_id: u16) ?*Window {
        return self.windows.getPtr(window_id);
    }

    /// Get the active window
    pub fn activeWindow(self: *Session) ?*Window {
        return self.getWindow(self.active_window_id);
    }

    /// Get a pane by (window_id, pane_id) - the 2D index
    pub fn getPane(self: *Session, window_id: u16, pane_id: u16) ?*Pane {
        const window = self.getWindow(window_id) orelse return null;
        return window.getPane(pane_id);
    }

    /// Get the currently active pane (in the active window)
    pub fn activePane(self: *Session) ?*Pane {
        const window = self.activeWindow() orelse return null;
        return window.activePane();
    }

    /// Get the debug pane (pane 0 in the active window)
    pub fn getDebugPane(self: *Session) ?*Pane {
        return self.getPane(self.active_window_id, DEBUG_PANE_ID);
    }

    /// Get shell pane 1
    pub fn getShellPane1(self: *Session) ?*Pane {
        return self.getPane(self.active_window_id, SHELL_PANE_1_ID);
    }

    /// Get shell pane 2
    pub fn getShellPane2(self: *Session) ?*Pane {
        return self.getPane(self.active_window_id, SHELL_PANE_2_ID);
    }

    /// Log bytes sent TO a pane's PTY (shown in red)
    /// Format: "> pane N: xx xx xx | ASCII"
    pub fn logPtySend(self: *Session, pane_id: u16, data: []const u8) void {
        const debug_pane = self.getDebugPane() orelse return;
        self.logPtyTraffic(debug_pane, ">", pane_id, data, "\x1b[31m"); // red
    }

    /// Log bytes received FROM a pane's PTY (shown in blue)
    /// Format: "< pane N: xx xx xx | ASCII"
    pub fn logPtyRecv(self: *Session, pane_id: u16, data: []const u8) void {
        const debug_pane = self.getDebugPane() orelse return;
        self.logPtyTraffic(debug_pane, "<", pane_id, data, "\x1b[34m"); // blue
    }

    /// Internal helper to format and log PTY traffic
    fn logPtyTraffic(self: *Session, debug_pane: *Pane, direction: []const u8, pane_id: u16, data: []const u8, color: []const u8) void {
        // Format: "[HH:MM:SS.mmm] COLOR> pane N: RESET hex bytes | ascii\r\n"
        // Use dynamic allocation to handle any size

        // Calculate buffer size: timestamp(14) + header(~20) + hex(3*len) + separator(3) + ascii(len) + newline(2)
        const buf_size = 50 + data.len * 4;
        const buf = self.allocator.alloc(u8, buf_size) catch return;
        defer self.allocator.free(buf);

        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();

        // Write timestamp [HH:MM:SS.mmm]
        const ts_ms = std.time.milliTimestamp();
        const ts_s: u64 = @intCast(@divTrunc(ts_ms, 1000));
        const ms: u64 = @intCast(@mod(ts_ms, 1000));
        const day_s = @mod(ts_s, 86400); // seconds since midnight
        const hours = @divTrunc(day_s, 3600);
        const mins = @divTrunc(@mod(day_s, 3600), 60);
        const secs = @mod(day_s, 60);
        w.print("\x1b[90m[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}]\x1b[0m ", .{ hours, mins, secs, ms }) catch return;

        // Write color and direction
        w.writeAll(color) catch return;
        w.print("{s} pane {d}:\x1b[0m ", .{ direction, pane_id }) catch return;

        // Write ALL hex bytes
        for (data) |byte| {
            w.print("{x:0>2} ", .{byte}) catch return;
        }

        // Write ASCII representation
        w.writeAll("| ") catch return;
        for (data) |byte| {
            const c: u8 = if (byte >= 32 and byte < 127) byte else '.';
            w.print("{c}", .{c}) catch return;
        }
        w.writeAll("\r\n") catch return;

        // Feed to debug pane
        debug_pane.feedDirect(fbs.getWritten()) catch {};

        // Signal that debug pane has new content
        self.notify_pipe.signal();
    }

    /// Get window count
    pub fn windowCount(self: *const Session) usize {
        return self.windows.count();
    }

    /// Run a command in the active pane and feed output to terminal
    pub fn runCommand(self: *Session, argv: []const []const u8) !void {
        const pane = self.activePane() orelse return error.NoActivePane;

        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Read stdout and feed to terminal
        if (child.stdout) |stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stdout.read(&buf) catch break;
                if (n == 0) break;
                try pane.feed(buf[0..n]);
            }
        }

        // Read stderr and feed to terminal
        if (child.stderr) |stderr| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stderr.read(&buf) catch break;
                if (n == 0) break;
                try pane.feed(buf[0..n]);
            }
        }

        _ = try child.wait();
    }

    /// Run a command in the active pane using a PTY (passes isatty() checks)
    pub fn runCommandPty(self: *Session, argv: []const [:0]const u8) !void {
        const pane = self.activePane() orelse return error.NoActivePane;

        // Open PTY with pane dimensions
        var pty = try Pty.open(.{
            .ws_row = pane.rows,
            .ws_col = pane.cols,
        });
        defer pty.deinit();

        // Spawn child process
        const pid = try pty.spawn(argv, null);

        // Read from PTY master and feed to terminal
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = pty.read(&buf) catch |err| switch (err) {
                error.InputOutput => break, // Child closed PTY
                else => break,
            };
            if (n == 0) break;
            try pane.feed(buf[0..n]);
        }

        // Wait for child to exit
        _ = posix.waitpid(pid, 0);
    }

    /// Dump session state in compact human-readable format
    pub fn dump(self: *Session, writer: anytype) !void {
        try writer.print("Session: {d} window(s), active={d}, default={d}x{d}\n", .{
            self.windowCount(),
            self.active_window_id,
            self.default_cols,
            self.default_rows,
        });

        // Dump each window
        var it = self.windows.valueIterator();
        while (it.next()) |window| {
            try window.dump(writer);
        }
    }
};

// Tests
test "session creates with one window and three panes" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 1), session.windowCount());

    const window = session.activeWindow();
    try std.testing.expect(window != null);
    // Session now creates 3 panes: debug (0), shell 1 (1), shell 2 (2)
    try std.testing.expectEqual(@as(usize, 3), window.?.paneCount());

    // Debug pane should exist
    try std.testing.expect(session.getDebugPane() != null);
    // Shell panes should exist
    try std.testing.expect(session.getShellPane1() != null);
    try std.testing.expect(session.getShellPane2() != null);
    // Active pane should be shell 1 (not debug)
    try std.testing.expectEqual(SHELL_PANE_1_ID, window.?.active_pane_id);
}

test "session 2D indexing works" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    // Default session has window 0, pane 0
    const pane = session.getPane(0, 0);
    try std.testing.expect(pane != null);

    // Non-existent indices return null
    try std.testing.expect(session.getPane(99, 0) == null);
    try std.testing.expect(session.getPane(0, 99) == null);
}

test "session can run command" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    // Run a simple command
    try session.runCommand(&.{ "echo", "hello" });

    const pane = session.activePane().?;
    const str = try pane.plainString();
    defer std.testing.allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "hello") != null);
}

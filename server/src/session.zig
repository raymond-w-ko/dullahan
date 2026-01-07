//! Session - the top-level container for windows
//!
//! A session represents a dullahan server instance with one or more windows.
//! Windows track layout, while panes are owned by the global PaneRegistry.
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
const pane_registry_mod = @import("pane_registry.zig");
const PaneRegistry = pane_registry_mod.PaneRegistry;

// Re-export pane IDs from registry for backwards compatibility
pub const DEBUG_PANE_ID = pane_registry_mod.DEBUG_PANE_ID;
pub const SHELL_PANE_1_ID = pane_registry_mod.SHELL_PANE_1_ID;
pub const SHELL_PANE_2_ID = pane_registry_mod.SHELL_PANE_2_ID;

pub const Session = struct {
    /// Global pane registry (owned externally, session has pointer)
    pane_registry: *PaneRegistry,

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

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
    };

    /// Initialize session with an external pane registry
    pub fn init(allocator: std.mem.Allocator, pane_registry: *PaneRegistry, opts: Options) !Session {
        var session = Session{
            .pane_registry = pane_registry,
            .windows = std.AutoHashMap(u16, Window).init(allocator),
            .active_window_id = 0,
            .default_cols = opts.cols,
            .default_rows = opts.rows,
            .allocator = allocator,
        };

        // Create window (without creating panes - registry owns them)
        const window_id = session.next_window_id;
        session.next_window_id += 1;

        var window = try Window.initWithOptions(allocator, .{
            .cols = opts.cols,
            .rows = opts.rows,
            .id = window_id,
        }, .{ .create_initial_pane = false });

        // Set active pane to first shell (pane 1), not debug pane
        window.active_pane_id = SHELL_PANE_1_ID;

        try session.windows.put(window_id, window);
        session.active_window_id = window_id;

        return session;
    }

    pub fn deinit(self: *Session) void {
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

    /// Get a pane by ID from the global registry
    /// The window_id parameter is kept for API compatibility but ignored
    /// (panes are now globally unique)
    pub fn getPane(self: *Session, _: u16, pane_id: u16) ?*Pane {
        return self.pane_registry.get(pane_id);
    }

    /// Get a pane by ID directly from registry
    pub fn getPaneById(self: *Session, pane_id: u16) ?*Pane {
        return self.pane_registry.get(pane_id);
    }

    /// Get the currently active pane (in the active window)
    pub fn activePane(self: *Session) ?*Pane {
        const window = self.activeWindow() orelse return null;
        return self.pane_registry.get(window.active_pane_id);
    }

    /// Get the debug pane (pane 0)
    pub fn getDebugPane(self: *Session) ?*Pane {
        return self.pane_registry.getDebugPane();
    }

    /// Get shell pane 1
    pub fn getShellPane1(self: *Session) ?*Pane {
        return self.pane_registry.getShellPane1();
    }

    /// Get shell pane 2
    pub fn getShellPane2(self: *Session) ?*Pane {
        return self.pane_registry.getShellPane2();
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
test "session creates with one window" {
    // Create registry with 3 panes
    var registry = PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();
    _ = try registry.create(); // pane 0
    _ = try registry.create(); // pane 1
    _ = try registry.create(); // pane 2

    var session = try Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 1), session.windowCount());

    const window = session.activeWindow();
    try std.testing.expect(window != null);

    // Panes come from registry now
    try std.testing.expectEqual(@as(usize, 3), registry.count());

    // Debug pane should exist
    try std.testing.expect(session.getDebugPane() != null);
    // Shell panes should exist
    try std.testing.expect(session.getShellPane1() != null);
    try std.testing.expect(session.getShellPane2() != null);
    // Active pane should be shell 1 (not debug)
    try std.testing.expectEqual(SHELL_PANE_1_ID, window.?.active_pane_id);
}

test "session pane lookup works" {
    var registry = PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();
    _ = try registry.create(); // pane 0

    var session = try Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    // Pane 0 exists in registry
    const pane = session.getPane(0, 0);
    try std.testing.expect(pane != null);

    // Non-existent pane returns null
    try std.testing.expect(session.getPane(0, 99) == null);
}

test "session can run command" {
    var registry = PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();
    _ = try registry.create(); // pane 0
    _ = try registry.create(); // pane 1 (active)

    var session = try Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    // Run a simple command
    try session.runCommand(&.{ "echo", "hello" });

    const pane = session.activePane().?;
    const str = try pane.plainString();
    defer std.testing.allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "hello") != null);
}

//! Session - the top-level container for windows
//!
//! A session represents a dullahan server instance with one or more windows.
//! Each window contains one or more panes.
//!
//! Addressing: (window_id, pane_id) provides 2D indexing into terminal panes.

const std = @import("std");
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;

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
        };

        // Create the initial window
        _ = try session.createWindow();

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
};

// Tests
test "session creates with one window and one pane" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 1), session.windowCount());

    const window = session.activeWindow();
    try std.testing.expect(window != null);
    try std.testing.expectEqual(@as(usize, 1), window.?.paneCount());
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

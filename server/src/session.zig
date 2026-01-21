//! Session - the top-level container for windows
//!
//! A session represents a dullahan server instance with one or more windows.
//! Windows track layout, while panes are owned by the global PaneRegistry.
//!
//! Pane layout:
//!   - Pane 0: Debug pane (virtual, no PTY) - shows server logs
//!   - Pane 1: Shell terminal 1
//!   - Pane 2: Shell terminal 2
//!
//! PTY traffic logging can be enabled via 'dullahan pty-log-on'
//! and writes to /tmp/dullahan-<uid>/pty-traffic.log

const std = @import("std");
const posix = std.posix;
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const Pty = @import("pty.zig").Pty;
const pty_log = @import("pty_log.zig");
const pane_registry_mod = @import("pane_registry.zig");
const PaneRegistry = pane_registry_mod.PaneRegistry;

// Re-export debug pane ID from registry (pane 0 in window 0)
pub const DEBUG_PANE_ID = pane_registry_mod.DEBUG_PANE_ID;

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

    /// Whether to log PTY traffic (hex + ASCII) to file
    /// Use setPtyLogging() to change this at runtime
    pty_logging_enabled: bool = false,

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
    };

    /// Initialize session with an external pane registry.
    /// Does NOT create any windows or panes - use createWindowWithPanes() for that.
    pub fn init(allocator: std.mem.Allocator, pane_registry: *PaneRegistry, opts: Options) !Session {
        return Session{
            .pane_registry = pane_registry,
            .windows = std.AutoHashMap(u16, Window).init(allocator),
            .active_window_id = 0,
            .default_cols = opts.cols,
            .default_rows = opts.rows,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Session) void {
        var it = self.windows.valueIterator();
        while (it.next()) |window| {
            window.deinit();
        }
        self.windows.deinit();
    }

    /// Create a new window (empty, no panes)
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

    /// Create a new window with a debug pane and three shell panes.
    /// This is the standard window layout for window 0: [debug, shell1, shell2, shell3]
    /// Returns { window_id, debug_pane_id, shell1_pane_id, shell2_pane_id, shell3_pane_id }
    pub fn createWindowWithPanes(self: *Session) !struct { window_id: u16, debug_pane_id: u16, shell1_pane_id: u16, shell2_pane_id: u16, shell3_pane_id: u16 } {
        // Create window
        const window_id = self.next_window_id;
        self.next_window_id += 1;

        var window = try Window.init(self.allocator, .{
            .cols = self.default_cols,
            .rows = self.default_rows,
            .id = window_id,
        });
        errdefer window.deinit();

        // Create panes using registry
        const debug_pane_id = try self.pane_registry.createDebugPane();
        errdefer self.pane_registry.destroy(debug_pane_id);

        const shell1_pane_id = try self.pane_registry.createShellPane();
        errdefer self.pane_registry.destroy(shell1_pane_id);

        const shell2_pane_id = try self.pane_registry.createShellPane();
        errdefer self.pane_registry.destroy(shell2_pane_id);

        const shell3_pane_id = try self.pane_registry.createShellPane();
        errdefer self.pane_registry.destroy(shell3_pane_id);

        // Add panes to window
        try window.addPane(debug_pane_id);
        try window.addPane(shell1_pane_id);
        try window.addPane(shell2_pane_id);
        try window.addPane(shell3_pane_id);

        // Set active pane to first shell (not debug)
        window.active_pane_id = shell1_pane_id;

        try self.windows.put(window_id, window);
        self.active_window_id = window_id;

        return .{
            .window_id = window_id,
            .debug_pane_id = debug_pane_id,
            .shell1_pane_id = shell1_pane_id,
            .shell2_pane_id = shell2_pane_id,
            .shell3_pane_id = shell3_pane_id,
        };
    }

    /// Create a new window with three shell panes (no debug pane).
    /// Used for additional windows created after window 0.
    /// Returns { window_id, shell1_pane_id, shell2_pane_id, shell3_pane_id }
    pub fn createShellWindow(self: *Session) !struct { window_id: u16, shell1_pane_id: u16, shell2_pane_id: u16, shell3_pane_id: u16 } {
        // Create window
        const window_id = self.next_window_id;
        self.next_window_id += 1;

        var window = try Window.init(self.allocator, .{
            .cols = self.default_cols,
            .rows = self.default_rows,
            .id = window_id,
        });
        errdefer window.deinit();

        // Create 3 shell panes
        const shell1_pane_id = try self.pane_registry.createShellPane();
        errdefer self.pane_registry.destroy(shell1_pane_id);

        const shell2_pane_id = try self.pane_registry.createShellPane();
        errdefer self.pane_registry.destroy(shell2_pane_id);

        const shell3_pane_id = try self.pane_registry.createShellPane();
        errdefer self.pane_registry.destroy(shell3_pane_id);

        // Add panes to window
        try window.addPane(shell1_pane_id);
        try window.addPane(shell2_pane_id);
        try window.addPane(shell3_pane_id);

        // Set active pane to first shell
        window.active_pane_id = shell1_pane_id;

        try self.windows.put(window_id, window);
        self.active_window_id = window_id;

        return .{
            .window_id = window_id,
            .shell1_pane_id = shell1_pane_id,
            .shell2_pane_id = shell2_pane_id,
            .shell3_pane_id = shell3_pane_id,
        };
    }

    /// Create a new window with a specified number of shell panes.
    /// Returns the window ID and a list of pane IDs (caller must free).
    pub fn createWindowWithPaneCount(self: *Session, pane_count: usize) !struct { window_id: u16, pane_ids: []u16 } {
        if (pane_count == 0) return error.InvalidPaneCount;

        // Create window
        const window_id = self.next_window_id;
        self.next_window_id += 1;

        var window = try Window.init(self.allocator, .{
            .cols = self.default_cols,
            .rows = self.default_rows,
            .id = window_id,
        });
        errdefer window.deinit();

        // Create the requested number of shell panes
        var pane_ids = try self.allocator.alloc(u16, pane_count);
        errdefer self.allocator.free(pane_ids);

        var created_count: usize = 0;
        errdefer {
            // Clean up any panes we created if we fail
            for (pane_ids[0..created_count]) |pid| {
                self.pane_registry.destroy(pid);
            }
        }

        for (0..pane_count) |i| {
            const pane_id = try self.pane_registry.createShellPane();
            pane_ids[i] = pane_id;
            created_count += 1;
            try window.addPane(pane_id);
        }

        // Set active pane to first shell
        window.active_pane_id = pane_ids[0];

        try self.windows.put(window_id, window);
        self.active_window_id = window_id;

        return .{
            .window_id = window_id,
            .pane_ids = pane_ids,
        };
    }

    /// Close a window and destroy all its panes.
    /// If this was the active window, switches to another window.
    /// Returns error.WindowNotFound if the window doesn't exist.
    pub fn closeWindow(self: *Session, window_id: u16) !void {
        // Get the window
        const window_ptr = self.windows.getPtr(window_id) orelse return error.WindowNotFound;

        // Destroy all panes in the window
        for (window_ptr.pane_ids.items) |pane_id| {
            self.pane_registry.destroy(pane_id);
        }

        // Deinit and remove the window
        window_ptr.deinit();
        _ = self.windows.remove(window_id);

        // If this was the active window, switch to another
        if (self.active_window_id == window_id) {
            // Pick any remaining window
            var it = self.windows.keyIterator();
            if (it.next()) |next_window_id| {
                self.active_window_id = next_window_id.*;
            }
        }
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

    /// Get the debug pane (pane 0 in window 0)
    pub fn getDebugPane(self: *Session) ?*Pane {
        return self.pane_registry.getDebugPane();
    }

    /// Enable or disable PTY traffic logging to file
    pub fn setPtyLogging(self: *Session, enabled: bool) void {
        self.pty_logging_enabled = enabled;
        pty_log.setEnabled(enabled);
    }

    /// Check if PTY logging is enabled
    pub fn isPtyLoggingEnabled(self: *const Session) bool {
        _ = self;
        return pty_log.isEnabled();
    }

    /// Get the PTY log file path
    pub fn getPtyLogPath(self: *const Session) []const u8 {
        _ = self;
        return pty_log.getLogPath();
    }

    /// Log bytes sent TO a pane's PTY
    /// Format: "[HH:MM:SS.mmm] > pane N: xx xx xx | ASCII"
    pub fn logPtySend(self: *Session, pane_id: u16, data: []const u8) void {
        _ = self;
        pty_log.logSend(pane_id, data);
    }

    /// Log bytes received FROM a pane's PTY
    /// Format: "[HH:MM:SS.mmm] < pane N: xx xx xx | ASCII"
    pub fn logPtyRecv(self: *Session, pane_id: u16, data: []const u8) void {
        _ = self;
        pty_log.logRecv(pane_id, data);
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
test "session init creates empty session" {
    var registry = PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    var session = try Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    // Session starts with no windows
    try std.testing.expectEqual(@as(usize, 0), session.windowCount());
}

test "session createWindow works" {
    var registry = PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    var session = try Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    // Create a window and add panes manually (without spawning shells)
    const window_id = try session.createWindow();
    try std.testing.expectEqual(@as(u16, 0), window_id);
    try std.testing.expectEqual(@as(usize, 1), session.windowCount());

    // Create panes and add to window
    const pane_id = try registry.create();
    const window = session.getWindow(window_id).?;
    try window.addPane(pane_id);
    window.active_pane_id = pane_id;

    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
    try std.testing.expect(window.hasPane(pane_id));
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

    var session = try Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    // Create a window with a pane
    const window_id = try session.createWindow();
    const pane_id = try registry.create();
    const window = session.getWindow(window_id).?;
    try window.addPane(pane_id);
    window.active_pane_id = pane_id;

    // Run a simple command
    try session.runCommand(&.{ "echo", "hello" });

    const pane = session.activePane().?;
    const str = try pane.plainString();
    defer std.testing.allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "hello") != null);
}

//! Pane - a single terminal pane with an associated process
//!
//! A pane represents one terminal emulator instance connected to a shell
//! or command. Panes are contained within Windows.

const std = @import("std");
const posix = std.posix;
const ghostty = @import("ghostty-vt");
const Terminal = ghostty.Terminal;
const Pty = @import("pty.zig").Pty;

const log = std.log.scoped(.pane);

pub const Pane = struct {
    /// The terminal emulator state
    terminal: Terminal,

    /// Pane dimensions in cells
    cols: u16,
    rows: u16,

    /// Unique pane ID within the window
    id: u16,

    /// Allocator used for this pane
    allocator: std.mem.Allocator,

    /// Whether this pane is active/focused
    active: bool = true,

    /// Version counter - increments on any content change
    /// Used to detect when clients need snapshot updates
    version: u64 = 0,

    /// PTY for this pane (null if no shell spawned)
    pty: ?Pty = null,

    /// Child process ID (null if no shell spawned)
    child_pid: ?posix.pid_t = null,

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        id: u16 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Pane {
        var terminal = try Terminal.init(allocator, .{
            .cols = opts.cols,
            .rows = opts.rows,
        });

        // Enable LNM (Line Feed/New Line Mode) so \n does CR+LF
        // Without this, \n only moves down, not back to column 0
        terminal.modes.set(.linefeed, true);

        return .{
            .terminal = terminal,
            .cols = opts.cols,
            .rows = opts.rows,
            .id = opts.id,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pane) void {
        // Kill child process if running
        if (self.child_pid) |pid| {
            _ = posix.kill(pid, posix.SIG.TERM) catch {};
            // Give it a moment, then force kill
            std.Thread.sleep(100 * std.time.ns_per_ms);
            _ = posix.kill(pid, posix.SIG.KILL) catch {};
            _ = posix.waitpid(pid, 0);
        }

        // Close PTY
        if (self.pty) |*pty| {
            pty.deinit();
        }

        self.terminal.deinit(self.allocator);
    }

    /// Spawn a shell in this pane
    pub fn spawnShell(self: *Pane) !void {
        if (self.pty != null) return error.AlreadySpawned;

        // Open PTY with pane dimensions
        var pty = Pty.open(.{
            .ws_row = self.rows,
            .ws_col = self.cols,
        }) catch return error.PtyOpenFailed;
        errdefer pty.deinit();

        // Get user's shell from environment, fallback to /bin/sh
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        
        // Create null-terminated shell path
        var shell_buf: [256:0]u8 = undefined;
        const shell_z = std.fmt.bufPrintZ(&shell_buf, "{s}", .{shell}) catch "/bin/sh";

        // Spawn shell
        const pid = pty.spawn(&.{shell_z}, null) catch return error.SpawnFailed;

        self.pty = pty;
        self.child_pid = pid;

        log.info("Spawned shell (pid={d}) in pane {d}", .{ pid, self.id });
    }

    /// Write input to the PTY (stdin to child process)
    pub fn writeInput(self: *Pane, data: []const u8) !void {
        if (self.pty) |*pty| {
            _ = try pty.write(data);
        } else {
            return error.NoPty;
        }
    }

    /// Get the PTY master fd for polling (returns null if no PTY)
    pub fn getPtyFd(self: *Pane) ?posix.fd_t {
        if (self.pty) |pty| {
            return pty.master;
        }
        return null;
    }

    /// Check if child process is still alive
    pub fn isAlive(self: *Pane) bool {
        if (self.child_pid) |pid| {
            const result = posix.waitpid(pid, posix.W.NOHANG);
            if (result.pid != 0) {
                // Child exited
                self.child_pid = null;
                return false;
            }
            return true;
        }
        return false;
    }

    /// Feed raw bytes into the terminal (e.g., from process stdout)
    /// This processes VT escape sequences including colors, cursor movement, etc.
    pub fn feed(self: *Pane, data: []const u8) !void {
        // Create a VT stream to process the input
        // vtStream() handles ANSI escape sequences properly
        var stream = self.terminal.vtStream();
        defer stream.deinit();
        try stream.nextSlice(data);

        // Increment version to signal clients need update
        self.version +%= 1;
    }

    /// Get a plain string representation of the terminal contents
    pub fn plainString(self: *Pane) ![]const u8 {
        return self.terminal.plainString(self.allocator);
    }

    /// Resize the pane
    pub fn resize(self: *Pane, cols: u16, rows: u16) !void {
        self.cols = cols;
        self.rows = rows;
        try self.terminal.resize(self.allocator, cols, rows);

        // Resize PTY if we have one
        if (self.pty) |*pty| {
            pty.setSize(.{ .ws_row = rows, .ws_col = cols }) catch |e| {
                log.warn("Failed to resize PTY: {any}", .{e});
            };
        }

        // Increment version to signal clients need update
        self.version +%= 1;
    }

    /// Dump pane state in compact human-readable format
    pub fn dump(self: *Pane, writer: anytype) !void {
        const screen = self.terminal.screens.active;
        const cursor = screen.cursor;

        try writer.print("Pane[{d}] {d}x{d}", .{ self.id, self.cols, self.rows });
        if (self.child_pid) |pid| {
            try writer.print(" pid={d}", .{pid});
        }
        try writer.print(" cur=({d},{d})", .{ cursor.x, cursor.y });

        // Cursor style
        const style_char: u8 = switch (cursor.cursor_style) {
            .block => 'B',
            .block_hollow => 'O',
            .underline => 'U',
            .bar => 'I',
        };
        try writer.print(" style={c}", .{style_char});

        if (cursor.pending_wrap) try writer.writeAll(" wrap");
        try writer.writeAll("\n");

        // Dump terminal content (non-empty rows only)
        try writer.writeAll("---content---\n");

        const content = self.terminal.plainString(self.allocator) catch |e| {
            try writer.print("(error: {})\n", .{e});
            return;
        };
        defer self.allocator.free(content);

        // Trim trailing empty lines and output
        var end = content.len;
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == ' ')) {
            end -= 1;
        }

        if (end > 0) {
            try writer.writeAll(content[0..end]);
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("(empty)\n");
        }
        try writer.writeAll("---end---\n");
    }
};

// Tests
test "pane can be created" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    try std.testing.expectEqual(@as(u16, 80), pane.cols);
    try std.testing.expectEqual(@as(u16, 24), pane.rows);
}

test "pane can feed data" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    try pane.feed("Hello, World!\r\n");

    const str = try pane.plainString();
    defer std.testing.allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "Hello") != null);
}

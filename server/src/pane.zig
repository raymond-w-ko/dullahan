//! Pane - a single terminal pane with an associated process
//!
//! A pane represents one terminal emulator instance connected to a shell
//! or command. Panes are contained within Windows.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const Terminal = ghostty.Terminal;

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

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        id: u16 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Pane {
        const terminal = try Terminal.init(allocator, .{
            .cols = opts.cols,
            .rows = opts.rows,
        });

        return .{
            .terminal = terminal,
            .cols = opts.cols,
            .rows = opts.rows,
            .id = opts.id,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pane) void {
        self.terminal.deinit(self.allocator);
    }

    /// Feed raw bytes into the terminal (e.g., from process stdout)
    /// This processes VT escape sequences including colors, cursor movement, etc.
    pub fn feed(self: *Pane, data: []const u8) !void {
        // Create a VT stream to process the input
        // vtStream() handles ANSI escape sequences properly
        var stream = self.terminal.vtStream();
        defer stream.deinit();
        try stream.nextSlice(data);
    }

    /// Get a plain string representation of the terminal contents
    pub fn plainString(self: *Pane) ![]const u8 {
        return self.terminal.plainString(self.allocator);
    }

    /// Resize the pane
    pub fn resize(self: *Pane, cols: u16, rows: u16) !void {
        self.cols = cols;
        self.rows = rows;
        try self.terminal.resize(.{ .cols = cols, .rows = rows });
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

//! Window - a layout container for pane arrangement
//!
//! A window tracks which panes are visible and their layout positions.
//! Panes themselves are owned by the global PaneRegistry.
//! For now, we only support a single active pane.
//! TODO: Implement pane layouts (splits, etc.)

const std = @import("std");

pub const Window = struct {
    /// The currently active/focused pane ID
    active_pane_id: u16,

    /// Window ID
    id: u16,

    /// Window dimensions (used for layout calculations)
    cols: u16,
    rows: u16,

    /// Allocator
    allocator: std.mem.Allocator,

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        id: u16 = 0,
    };

    pub const InitOptions = struct {
        /// If true, create an initial pane automatically (default: true for backward compat)
        /// Note: This option is deprecated - pane creation is now handled by PaneRegistry
        create_initial_pane: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Window {
        return initWithOptions(allocator, opts, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, opts: Options, _: InitOptions) !Window {
        return Window{
            .active_pane_id = 0,
            .id = opts.id,
            .cols = opts.cols,
            .rows = opts.rows,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Window) void {
        // Window no longer owns panes - nothing to deinit
        _ = self;
    }

    /// Set the active pane by ID
    /// Returns true if the pane ID was set (does not validate existence)
    pub fn setActivePane(self: *Window, pane_id: u16) bool {
        self.active_pane_id = pane_id;
        return true;
    }

    /// Resize the window dimensions
    /// Note: This only updates the window's stored dimensions.
    /// Actual pane resizing should be done via PaneRegistry.resizeAll()
    pub fn resize(self: *Window, cols: u16, rows: u16) void {
        self.cols = cols;
        self.rows = rows;
    }

    /// Dump window state in compact human-readable format
    pub fn dump(self: *Window, writer: anytype) !void {
        try writer.print("Window[{d}] {d}x{d} active={d}\n", .{
            self.id,
            self.cols,
            self.rows,
            self.active_pane_id,
        });
    }
};

// Tests
test "window creates with default options" {
    var window = try Window.init(std.testing.allocator, .{});
    defer window.deinit();

    try std.testing.expectEqual(@as(u16, 0), window.active_pane_id);
    try std.testing.expectEqual(@as(u16, 80), window.cols);
    try std.testing.expectEqual(@as(u16, 24), window.rows);
}

test "window can set active pane" {
    var window = try Window.init(std.testing.allocator, .{});
    defer window.deinit();

    try std.testing.expect(window.setActivePane(5));
    try std.testing.expectEqual(@as(u16, 5), window.active_pane_id);
}

test "window can resize" {
    var window = try Window.init(std.testing.allocator, .{});
    defer window.deinit();

    window.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), window.cols);
    try std.testing.expectEqual(@as(u16, 40), window.rows);
}

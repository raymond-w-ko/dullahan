//! Window - a collection of panes
//!
//! A window contains one or more panes arranged in a layout.
//! For now, we only support a single full-screen pane.
//! TODO: Implement pane layouts (splits, etc.)

const std = @import("std");
const Pane = @import("pane.zig").Pane;

pub const Window = struct {
    /// Panes in this window, indexed by pane ID
    panes: std.AutoHashMap(u16, Pane),

    /// The currently active/focused pane ID
    active_pane_id: u16,

    /// Window ID
    id: u16,

    /// Next pane ID to assign
    next_pane_id: u16 = 0,

    /// Window dimensions (all panes share this for now)
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
        create_initial_pane: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Window {
        return initWithOptions(allocator, opts, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, opts: Options, init_opts: InitOptions) !Window {
        var window = Window{
            .panes = std.AutoHashMap(u16, Pane).init(allocator),
            .active_pane_id = 0,
            .id = opts.id,
            .cols = opts.cols,
            .rows = opts.rows,
            .allocator = allocator,
        };

        // Create the initial pane (unless disabled)
        if (init_opts.create_initial_pane) {
            _ = try window.createPane();
        }

        return window;
    }

    pub fn deinit(self: *Window) void {
        var it = self.panes.valueIterator();
        while (it.next()) |pane| {
            pane.deinit();
        }
        self.panes.deinit();
    }

    /// Create a new pane in this window
    pub fn createPane(self: *Window) !u16 {
        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;

        const pane = try Pane.init(self.allocator, .{
            .cols = self.cols,
            .rows = self.rows,
            .id = pane_id,
        });

        try self.panes.put(pane_id, pane);
        self.active_pane_id = pane_id;

        return pane_id;
    }

    /// Get a pane by ID
    pub fn getPane(self: *Window, pane_id: u16) ?*Pane {
        return self.panes.getPtr(pane_id);
    }

    /// Get the active pane
    pub fn activePane(self: *Window) ?*Pane {
        return self.getPane(self.active_pane_id);
    }

    /// Set the active pane by ID
    /// Returns true if the pane exists and was activated, false otherwise
    pub fn setActivePane(self: *Window, pane_id: u16) bool {
        if (self.panes.contains(pane_id)) {
            self.active_pane_id = pane_id;
            return true;
        }
        return false;
    }

    /// Get pane count
    pub fn paneCount(self: *const Window) usize {
        return self.panes.count();
    }

    /// Resize all panes (TODO: layout-aware resizing)
    pub fn resize(self: *Window, cols: u16, rows: u16) !void {
        self.cols = cols;
        self.rows = rows;

        var it = self.panes.valueIterator();
        while (it.next()) |pane| {
            try pane.resize(cols, rows);
        }
    }

    /// Dump window state in compact human-readable format
    pub fn dump(self: *Window, writer: anytype) !void {
        try writer.print("Window[{d}] {d}x{d} panes={d} active={d}\n", .{
            self.id,
            self.cols,
            self.rows,
            self.paneCount(),
            self.active_pane_id,
        });

        // Dump each pane
        var it = self.panes.valueIterator();
        while (it.next()) |pane| {
            try writer.writeAll("  ");
            try pane.dump(writer);
        }
    }
};

// Tests
test "window creates with one pane" {
    var window = try Window.init(std.testing.allocator, .{});
    defer window.deinit();

    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
}

test "window can create additional panes" {
    var window = try Window.init(std.testing.allocator, .{});
    defer window.deinit();

    const pane_id = try window.createPane();
    try std.testing.expectEqual(@as(u16, 1), pane_id);
    try std.testing.expectEqual(@as(usize, 2), window.paneCount());
}

test "window active pane is accessible" {
    var window = try Window.init(std.testing.allocator, .{});
    defer window.deinit();

    const pane = window.activePane();
    try std.testing.expect(pane != null);
}

//! Window - a layout container for pane arrangement
//!
//! A window tracks which panes are visible and their layout positions.
//! Panes themselves are owned by the global PaneRegistry.
//! Layout is a tree structure defining pane sizes and arrangement.

const std = @import("std");
const layout_db = @import("layout_db.zig");
const dlog = @import("dlog.zig");
pub const LayoutNode = layout_db.LayoutNode;

const log = std.log.scoped(.window);
const wlog = dlog.scoped(.window);

pub const Window = struct {
    /// The currently active/focused pane ID
    active_pane_id: u16,

    /// Window ID
    id: u16,

    /// Window dimensions (used for layout calculations)
    cols: u16,
    rows: u16,

    /// Pane IDs belonging to this window (order matters for layout)
    pane_ids: std.ArrayListUnmanaged(u16) = .{},

    /// Layout template ID (e.g., "3-col", "2x2")
    template_id: ?[]const u8 = null,

    /// Layout tree (with pane IDs assigned)
    /// Null until a layout is set
    layout_nodes: ?[]LayoutNode = null,

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
            .pane_ids = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Window) void {
        self.pane_ids.deinit(self.allocator);
        // Free template_id if allocated
        if (self.template_id) |id| {
            self.allocator.free(id);
        }
        // Free layout nodes if allocated
        if (self.layout_nodes) |nodes| {
            freeLayoutNodes(self.allocator, nodes);
        }
    }

    /// Free layout nodes recursively
    fn freeLayoutNodes(allocator: std.mem.Allocator, nodes: []LayoutNode) void {
        for (nodes) |*node| {
            if (node.* == .container) {
                freeLayoutNodes(allocator, node.container.children);
            }
        }
        allocator.free(nodes);
    }

    /// Add a pane to this window
    pub fn addPane(self: *Window, pane_id: u16) !void {
        try self.pane_ids.append(self.allocator, pane_id);
        log.debug("Assigned pane {d} to window {d}", .{ pane_id, self.id });
        wlog.debug("Assigned pane {d} to window {d}", .{ pane_id, self.id });
    }

    /// Remove a pane from this window
    pub fn removePane(self: *Window, pane_id: u16) void {
        var i: usize = 0;
        while (i < self.pane_ids.items.len) {
            if (self.pane_ids.items[i] == pane_id) {
                _ = self.pane_ids.orderedRemove(i);
                log.debug("Removed pane {d} from window {d}", .{ pane_id, self.id });
                wlog.debug("Removed pane {d} from window {d}", .{ pane_id, self.id });
                return;
            }
            i += 1;
        }
    }

    /// Check if window contains a pane
    pub fn hasPane(self: *const Window, pane_id: u16) bool {
        for (self.pane_ids.items) |id| {
            if (id == pane_id) return true;
        }
        return false;
    }

    /// Swap two panes' positions in the pane list
    /// Returns true if successful, false if either pane is not in this window
    pub fn swapPanePositions(self: *Window, pane_id1: u16, pane_id2: u16) bool {
        var idx1: ?usize = null;
        var idx2: ?usize = null;

        for (self.pane_ids.items, 0..) |id, i| {
            if (id == pane_id1) idx1 = i;
            if (id == pane_id2) idx2 = i;
        }

        if (idx1 == null or idx2 == null) {
            return false;
        }

        // Swap the positions
        const index1 = idx1.?;
        const index2 = idx2.?;
        const tmp = self.pane_ids.items[index1];
        self.pane_ids.items[index1] = self.pane_ids.items[index2];
        self.pane_ids.items[index2] = tmp;

        return true;
    }

    /// Get pane count
    pub fn paneCount(self: *const Window) usize {
        return self.pane_ids.items.len;
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

    /// Set layout from a template, assigning pane IDs from pane_ids list
    /// Clones the template nodes and assigns pane IDs in order
    pub fn setLayoutFromTemplate(self: *Window, template: *const layout_db.LayoutTemplate) !void {
        // Free existing layout if any
        if (self.template_id) |id| {
            self.allocator.free(id);
        }
        if (self.layout_nodes) |nodes| {
            freeLayoutNodes(self.allocator, nodes);
        }

        // Clone template nodes
        const cloned = try cloneNodes(self.allocator, template.nodes);
        errdefer freeLayoutNodes(self.allocator, cloned);

        // Assign pane IDs
        var pane_idx: usize = 0;
        assignPaneIds(cloned, self.pane_ids.items, &pane_idx);

        // Store
        self.template_id = try self.allocator.dupe(u8, template.id);
        self.layout_nodes = cloned;
    }

    /// Clone layout nodes recursively
    fn cloneNodes(allocator: std.mem.Allocator, nodes: []const LayoutNode) ![]LayoutNode {
        var result = try allocator.alloc(LayoutNode, nodes.len);
        errdefer allocator.free(result);

        for (nodes, 0..) |node, i| {
            result[i] = switch (node) {
                .container => |c| blk: {
                    const children = try cloneNodes(allocator, c.children);
                    break :blk LayoutNode{ .container = .{
                        .width = c.width,
                        .height = c.height,
                        .children = children,
                    } };
                },
                .pane => |p| LayoutNode{ .pane = .{
                    .width = p.width,
                    .height = p.height,
                    .pane_id = null,
                } },
            };
        }
        return result;
    }

    /// Assign pane IDs to pane nodes in order
    fn assignPaneIds(nodes: []LayoutNode, pane_ids: []const u16, idx: *usize) void {
        for (nodes) |*node| {
            switch (node.*) {
                .container => |*c| assignPaneIds(c.children, pane_ids, idx),
                .pane => |*p| {
                    if (idx.* < pane_ids.len) {
                        p.pane_id = pane_ids[idx.*];
                        idx.* += 1;
                    }
                },
            }
        }
    }

    /// Get layout info for serialization
    pub fn getLayout(self: *const Window) ?struct { template_id: []const u8, nodes: []const LayoutNode } {
        if (self.template_id) |tid| {
            if (self.layout_nodes) |nodes| {
                return .{ .template_id = tid, .nodes = nodes };
            }
        }
        return null;
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

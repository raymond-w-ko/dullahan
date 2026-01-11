//! Layout Database
//!
//! Manages layout templates stored in ~/.config/dullahan/layouts.json.
//! Provides default layouts if file doesn't exist.
//!
//! Layout structure matches protocol/schema/layout.ts:
//!   - LayoutNode: container or pane
//!   - Split direction implicit from nesting (level 0=horizontal, 1=vertical, etc.)

const std = @import("std");
const paths = @import("paths.zig");

/// A layout node - either a container or a pane
pub const LayoutNode = union(enum) {
    container: Container,
    pane: Pane,

    pub const Container = struct {
        width: f32, // Percentage (0-100)
        height: f32,
        children: []LayoutNode,
    };

    pub const Pane = struct {
        width: f32,
        height: f32,
        pane_id: ?u16 = null, // Assigned when window is created
    };

    /// Create a pane node
    pub fn createPane(width: f32, height: f32) LayoutNode {
        return .{ .pane = .{ .width = width, .height = height } };
    }

    /// Create a container node (allocates children array)
    pub fn createContainer(allocator: std.mem.Allocator, width: f32, height: f32, children: []const LayoutNode) !LayoutNode {
        const owned_children = try allocator.alloc(LayoutNode, children.len);
        @memcpy(owned_children, children);
        return .{ .container = .{ .width = width, .height = height, .children = owned_children } };
    }

    /// Deep clone a node
    pub fn clone(self: LayoutNode, allocator: std.mem.Allocator) !LayoutNode {
        return switch (self) {
            .pane => |p| .{ .pane = .{ .width = p.width, .height = p.height, .pane_id = null } },
            .container => |c| blk: {
                const children = try allocator.alloc(LayoutNode, c.children.len);
                for (c.children, 0..) |child, i| {
                    children[i] = try child.clone(allocator);
                }
                break :blk .{ .container = .{ .width = c.width, .height = c.height, .children = children } };
            },
        };
    }

    /// Free a node's memory
    pub fn deinit(self: *LayoutNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .container => |*c| {
                for (c.children) |*child| {
                    child.deinit(allocator);
                }
                allocator.free(c.children);
            },
            .pane => {},
        }
    }

    /// Count panes in this node (recursively)
    pub fn countPanes(self: LayoutNode) usize {
        return switch (self) {
            .pane => 1,
            .container => |c| {
                var count: usize = 0;
                for (c.children) |child| {
                    count += child.countPanes();
                }
                return count;
            },
        };
    }
};

/// A named layout template
pub const LayoutTemplate = struct {
    id: []const u8,
    name: []const u8,
    nodes: []LayoutNode,

    /// Count total panes in this template
    pub fn countPanes(self: LayoutTemplate) usize {
        var count: usize = 0;
        for (self.nodes) |node| {
            count += node.countPanes();
        }
        return count;
    }

    /// Deep clone the template's nodes (for creating window layouts)
    pub fn cloneNodes(self: LayoutTemplate, allocator: std.mem.Allocator) ![]LayoutNode {
        const nodes = try allocator.alloc(LayoutNode, self.nodes.len);
        for (self.nodes, 0..) |node, i| {
            nodes[i] = try node.clone(allocator);
        }
        return nodes;
    }

    /// Free template memory
    pub fn deinit(self: *LayoutTemplate, allocator: std.mem.Allocator) void {
        for (self.nodes) |*node| {
            var n = node;
            n.deinit(allocator);
        }
        allocator.free(self.nodes);
        if (self.id.len > 0) allocator.free(self.id);
        if (self.name.len > 0) allocator.free(self.name);
    }
};

/// Layout database
pub const LayoutDb = struct {
    allocator: std.mem.Allocator,
    templates: std.ArrayListUnmanaged(LayoutTemplate) = .{},
    loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator) LayoutDb {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LayoutDb) void {
        for (self.templates.items) |*t| {
            t.deinit(self.allocator);
        }
        self.templates.deinit(self.allocator);
    }

    /// Load layouts from file or create defaults
    pub fn load(self: *LayoutDb) !void {
        if (self.loaded) return;

        // Try to load from file
        const loaded = self.loadFromFile() catch false;
        if (!loaded) {
            // Create default layouts
            try self.createDefaults();
            // Save to file for future edits
            self.saveToFile() catch |e| {
                std.log.warn("Failed to save default layouts: {}", .{e});
            };
        }

        self.loaded = true;
    }

    /// Get a template by ID
    pub fn get(self: *LayoutDb, id: []const u8) ?*LayoutTemplate {
        for (self.templates.items) |*t| {
            if (std.mem.eql(u8, t.id, id)) {
                return t;
            }
        }
        return null;
    }

    /// Get all templates (for listing)
    pub fn getAll(self: *LayoutDb) []LayoutTemplate {
        return self.templates.items;
    }

    /// Load layouts from JSON file
    fn loadFromFile(self: *LayoutDb) !bool {
        const path = paths.StaticPaths.layouts();

        const file = std.fs.openFileAbsolute(path, .{}) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return e,
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        try self.parseJson(content);
        return true;
    }

    /// Parse JSON content into templates
    fn parseJson(self: *LayoutDb, content: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidFormat;

        const templates_val = root.object.get("templates") orelse return error.InvalidFormat;
        if (templates_val != .array) return error.InvalidFormat;

        for (templates_val.array.items) |template_val| {
            const template = try self.parseTemplate(template_val);
            try self.templates.append(self.allocator, template);
        }
    }

    /// Parse a single template from JSON
    fn parseTemplate(self: *LayoutDb, val: std.json.Value) !LayoutTemplate {
        if (val != .object) return error.InvalidFormat;

        const id_val = val.object.get("id") orelse return error.InvalidFormat;
        const name_val = val.object.get("name") orelse return error.InvalidFormat;
        const nodes_val = val.object.get("nodes") orelse return error.InvalidFormat;

        if (id_val != .string or name_val != .string or nodes_val != .array) {
            return error.InvalidFormat;
        }

        const id = try self.allocator.dupe(u8, id_val.string);
        errdefer self.allocator.free(id);

        const name = try self.allocator.dupe(u8, name_val.string);
        errdefer self.allocator.free(name);

        const nodes = try self.parseNodes(nodes_val.array.items);

        return .{ .id = id, .name = name, .nodes = nodes };
    }

    /// Parse an array of nodes from JSON
    fn parseNodes(self: *LayoutDb, items: []const std.json.Value) ![]LayoutNode {
        const nodes = try self.allocator.alloc(LayoutNode, items.len);
        errdefer self.allocator.free(nodes);

        for (items, 0..) |item, i| {
            nodes[i] = try self.parseNode(item);
        }

        return nodes;
    }

    /// Parse a single node from JSON
    fn parseNode(self: *LayoutDb, val: std.json.Value) !LayoutNode {
        if (val != .object) return error.InvalidFormat;

        const type_val = val.object.get("type") orelse return error.InvalidFormat;
        if (type_val != .string) return error.InvalidFormat;

        const width = self.getNumber(val.object.get("width")) orelse return error.InvalidFormat;
        const height = self.getNumber(val.object.get("height")) orelse return error.InvalidFormat;

        if (std.mem.eql(u8, type_val.string, "pane")) {
            return .{ .pane = .{ .width = width, .height = height } };
        } else if (std.mem.eql(u8, type_val.string, "container")) {
            const children_val = val.object.get("children") orelse return error.InvalidFormat;
            if (children_val != .array) return error.InvalidFormat;

            const children = try self.parseNodes(children_val.array.items);
            return .{ .container = .{ .width = width, .height = height, .children = children } };
        } else {
            return error.InvalidFormat;
        }
    }

    /// Get a number from a JSON value (handles both int and float)
    fn getNumber(self: *LayoutDb, val: ?std.json.Value) ?f32 {
        _ = self;
        const v = val orelse return null;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => null,
        };
    }

    /// Save layouts to JSON file
    fn saveToFile(self: *LayoutDb) !void {
        try paths.ensureConfigDir();

        const path = paths.StaticPaths.layouts();

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        const writer = file.writer();
        try self.writeJson(writer);
    }

    /// Write layouts as JSON
    fn writeJson(self: *LayoutDb, writer: anytype) !void {
        try writer.writeAll("{\n  \"templates\": [\n");

        for (self.templates.items, 0..) |template, i| {
            if (i > 0) try writer.writeAll(",\n");
            try self.writeTemplate(writer, template, 2);
        }

        try writer.writeAll("\n  ]\n}\n");
    }

    /// Write a single template as JSON
    fn writeTemplate(self: *LayoutDb, writer: anytype, template: LayoutTemplate, indent: usize) !void {
        try self.writeIndent(writer, indent);
        try writer.writeAll("{\n");

        try self.writeIndent(writer, indent + 1);
        try writer.print("\"id\": \"{s}\",\n", .{template.id});

        try self.writeIndent(writer, indent + 1);
        try writer.print("\"name\": \"{s}\",\n", .{template.name});

        try self.writeIndent(writer, indent + 1);
        try writer.writeAll("\"nodes\": ");
        try self.writeNodes(writer, template.nodes, indent + 1);
        try writer.writeAll("\n");

        try self.writeIndent(writer, indent);
        try writer.writeAll("}");
    }

    /// Write an array of nodes as JSON
    fn writeNodes(self: *LayoutDb, writer: anytype, nodes: []const LayoutNode, indent: usize) !void {
        try writer.writeAll("[\n");

        for (nodes, 0..) |node, i| {
            if (i > 0) try writer.writeAll(",\n");
            try self.writeNode(writer, node, indent + 1);
        }

        try writer.writeAll("\n");
        try self.writeIndent(writer, indent);
        try writer.writeAll("]");
    }

    /// Write a single node as JSON
    fn writeNode(self: *LayoutDb, writer: anytype, node: LayoutNode, indent: usize) !void {
        try self.writeIndent(writer, indent);

        switch (node) {
            .pane => |p| {
                try writer.print("{{ \"type\": \"pane\", \"width\": {d:.2}, \"height\": {d:.2} }}", .{ p.width, p.height });
            },
            .container => |c| {
                try writer.writeAll("{\n");
                try self.writeIndent(writer, indent + 1);
                try writer.writeAll("\"type\": \"container\",\n");
                try self.writeIndent(writer, indent + 1);
                try writer.print("\"width\": {d:.2},\n", .{c.width});
                try self.writeIndent(writer, indent + 1);
                try writer.print("\"height\": {d:.2},\n", .{c.height});
                try self.writeIndent(writer, indent + 1);
                try writer.writeAll("\"children\": ");
                try self.writeNodes(writer, c.children, indent + 1);
                try writer.writeAll("\n");
                try self.writeIndent(writer, indent);
                try writer.writeAll("}");
            },
        }
    }

    fn writeIndent(self: *LayoutDb, writer: anytype, level: usize) !void {
        _ = self;
        for (0..level) |_| {
            try writer.writeAll("  ");
        }
    }

    /// Create default layout templates
    fn createDefaults(self: *LayoutDb) !void {
        // Single pane
        try self.addDefault("single", "Single Pane", &.{
            LayoutNode.createPane(100, 100),
        });

        // Two columns
        try self.addDefault("2-col", "Two Columns", &.{
            LayoutNode.createPane(50, 100),
            LayoutNode.createPane(50, 100),
        });

        // Two rows (container with vertical children)
        const two_rows_children = try self.allocator.alloc(LayoutNode, 2);
        two_rows_children[0] = LayoutNode.createPane(100, 50);
        two_rows_children[1] = LayoutNode.createPane(100, 50);
        try self.addDefault("2-row", "Two Rows", &.{
            .{ .container = .{ .width = 100, .height = 100, .children = two_rows_children } },
        });

        // 2x2 grid
        const grid_col1 = try self.allocator.alloc(LayoutNode, 2);
        grid_col1[0] = LayoutNode.createPane(100, 50);
        grid_col1[1] = LayoutNode.createPane(100, 50);
        const grid_col2 = try self.allocator.alloc(LayoutNode, 2);
        grid_col2[0] = LayoutNode.createPane(100, 50);
        grid_col2[1] = LayoutNode.createPane(100, 50);
        try self.addDefault("2x2", "2×2 Grid", &.{
            .{ .container = .{ .width = 50, .height = 100, .children = grid_col1 } },
            .{ .container = .{ .width = 50, .height = 100, .children = grid_col2 } },
        });

        // Main + sidebar
        try self.addDefault("main-side", "Main + Sidebar", &.{
            LayoutNode.createPane(70, 100),
            LayoutNode.createPane(30, 100),
        });

        // Main + 2 sidebars
        const side_col = try self.allocator.alloc(LayoutNode, 2);
        side_col[0] = LayoutNode.createPane(100, 50);
        side_col[1] = LayoutNode.createPane(100, 50);
        try self.addDefault("main-2side", "Main + 2 Sidebars", &.{
            LayoutNode.createPane(50, 100),
            .{ .container = .{ .width = 50, .height = 100, .children = side_col } },
        });

        // Three columns
        try self.addDefault("3-col", "Three Columns", &.{
            LayoutNode.createPane(33.33, 100),
            LayoutNode.createPane(33.34, 100),
            LayoutNode.createPane(33.33, 100),
        });

        // Three rows
        const three_rows_children = try self.allocator.alloc(LayoutNode, 3);
        three_rows_children[0] = LayoutNode.createPane(100, 33.33);
        three_rows_children[1] = LayoutNode.createPane(100, 33.34);
        three_rows_children[2] = LayoutNode.createPane(100, 33.33);
        try self.addDefault("3-row", "Three Rows", &.{
            .{ .container = .{ .width = 100, .height = 100, .children = three_rows_children } },
        });
    }

    /// Add a default template
    fn addDefault(self: *LayoutDb, id: []const u8, name: []const u8, nodes_slice: []const LayoutNode) !void {
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);

        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);

        const nodes = try self.allocator.alloc(LayoutNode, nodes_slice.len);
        @memcpy(nodes, nodes_slice);

        try self.templates.append(self.allocator, .{
            .id = id_owned,
            .name = name_owned,
            .nodes = nodes,
        });
    }
};

// Tests
test "LayoutNode.pane creates pane" {
    const node = LayoutNode.createPane(50, 100);
    try std.testing.expectEqual(node.pane.width, 50);
    try std.testing.expectEqual(node.pane.height, 100);
}

test "LayoutNode.countPanes" {
    const alloc = std.testing.allocator;

    // Single pane
    const p = LayoutNode.createPane(100, 100);
    try std.testing.expectEqual(p.countPanes(), 1);

    // Container with 2 panes
    const children = try alloc.alloc(LayoutNode, 2);
    defer alloc.free(children);
    children[0] = LayoutNode.createPane(50, 100);
    children[1] = LayoutNode.createPane(50, 100);
    const c: LayoutNode = .{ .container = .{ .width = 100, .height = 100, .children = children } };
    try std.testing.expectEqual(c.countPanes(), 2);
}

test "LayoutDb creates defaults" {
    var db = LayoutDb.init(std.testing.allocator);
    defer db.deinit();

    try db.createDefaults();

    try std.testing.expect(db.templates.items.len >= 6);

    // Check single layout
    const single = db.get("single");
    try std.testing.expect(single != null);
    try std.testing.expectEqual(single.?.countPanes(), 1);

    // Check 2x2 layout
    const grid = db.get("2x2");
    try std.testing.expect(grid != null);
    try std.testing.expectEqual(grid.?.countPanes(), 4);
}

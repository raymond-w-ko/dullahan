//! Layout Helpers
//!
//! Standalone utilities for parsing, validating, and manipulating layout nodes.
//! Extracted from event_loop.zig to reduce file size and improve modularity.
//!
//! These functions work with std.json.Value inputs from the wire protocol
//! and provide detailed error types for debugging.

const std = @import("std");
const layout_db = @import("layout_db.zig");
const dlog = @import("dlog.zig");

const log = dlog.scoped(.layout);

pub const LayoutNode = layout_db.LayoutNode;

/// Error type for layout parsing - detailed for debugging wire protocol issues
pub const LayoutParseError = error{
    InvalidLayoutNodes,
    InvalidLayoutNode,
    MissingType,
    InvalidType,
    MissingWidth,
    MissingHeight,
    InvalidWidth,
    InvalidHeight,
    MissingChildren,
    InvalidNodeType,
    OutOfMemory,
};

/// Error type for layout dimension operations
pub const LayoutDimensionError = error{
    LayoutMismatch,
    LayoutTypeMismatch,
};

/// Parse layout nodes from JSON value
pub fn parseLayoutNodesFromJson(allocator: std.mem.Allocator, json_nodes: std.json.Value) LayoutParseError![]LayoutNode {
    if (json_nodes != .array) return error.InvalidLayoutNodes;

    const nodes = allocator.alloc(LayoutNode, json_nodes.array.items.len) catch return error.OutOfMemory;
    errdefer allocator.free(nodes);

    for (json_nodes.array.items, 0..) |item, i| {
        nodes[i] = try parseLayoutNodeFromJson(allocator, item);
    }

    return nodes;
}

/// Parse a single layout node from JSON
pub fn parseLayoutNodeFromJson(allocator: std.mem.Allocator, json_node: std.json.Value) LayoutParseError!LayoutNode {
    if (json_node != .object) return error.InvalidLayoutNode;

    const obj = json_node.object;
    const type_val = obj.get("type") orelse return error.MissingType;
    if (type_val != .string) return error.InvalidType;

    const width_val = obj.get("width") orelse return error.MissingWidth;
    const height_val = obj.get("height") orelse return error.MissingHeight;

    const width: f32 = switch (width_val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => return error.InvalidWidth,
    };

    const height: f32 = switch (height_val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => return error.InvalidHeight,
    };

    if (std.mem.eql(u8, type_val.string, "pane")) {
        const pane_id: ?u16 = if (obj.get("paneId")) |pid| blk: {
            if (pid != .integer) break :blk null;
            break :blk @intCast(pid.integer);
        } else null;

        return .{ .pane = .{
            .width = width,
            .height = height,
            .pane_id = pane_id,
        } };
    } else if (std.mem.eql(u8, type_val.string, "container")) {
        const children_val = obj.get("children") orelse return error.MissingChildren;
        const children = try parseLayoutNodesFromJson(allocator, children_val);

        return .{ .container = .{
            .width = width,
            .height = height,
            .children = children,
        } };
    }

    return error.InvalidNodeType;
}

/// Free layout nodes recursively
pub fn freeLayoutNodes(allocator: std.mem.Allocator, nodes: []LayoutNode) void {
    for (nodes) |*node| {
        if (node.* == .container) {
            freeLayoutNodes(allocator, node.container.children);
        }
    }
    allocator.free(nodes);
}

/// Validate layout percentages (each sibling group should sum close to 100%)
pub fn validateLayoutPercentages(nodes: []const LayoutNode) bool {
    return validateLayoutPercentagesImpl(nodes);
}

fn validateLayoutPercentagesImpl(nodes: []const LayoutNode) bool {
    if (nodes.len == 0) return true;

    // Check width/height percentages
    var width_sum: f32 = 0;
    var height_sum: f32 = 0;

    for (nodes) |node| {
        switch (node) {
            .pane => |p| {
                width_sum += p.width;
                height_sum += p.height;
                // Validate min size (5%)
                if (p.width < 5 or p.height < 5) return false;
            },
            .container => |c| {
                width_sum += c.width;
                height_sum += c.height;
                // Validate min size
                if (c.width < 5 or c.height < 5) return false;
                // Recursively validate children
                if (!validateLayoutPercentagesImpl(c.children)) return false;
            },
        }
    }

    // At least one dimension should sum close to 100% (allow 5% tolerance)
    const width_ok = @abs(width_sum - 100.0) < 5.0;
    const height_ok = @abs(height_sum - 100.0) < 5.0;

    // Width sums for horizontal splits, height sums for vertical splits
    // (depends on nesting level, so we allow either to be valid)
    return width_ok or height_ok;
}

/// Copy dimensions from new_nodes to old_nodes in place, preserving pane IDs
pub fn copyLayoutDimensions(old_nodes: []LayoutNode, new_nodes: []const LayoutNode) LayoutDimensionError!void {
    if (old_nodes.len != new_nodes.len) return error.LayoutMismatch;

    for (old_nodes, new_nodes) |*old, new| {
        switch (old.*) {
            .pane => |*p| {
                if (new != .pane) return error.LayoutTypeMismatch;
                // Update dimensions, keep pane_id
                p.width = new.pane.width;
                p.height = new.pane.height;
            },
            .container => |*c| {
                if (new != .container) return error.LayoutTypeMismatch;
                // Update dimensions
                c.width = new.container.width;
                c.height = new.container.height;
                // Recursively update children
                try copyLayoutDimensions(c.children, new.container.children);
            },
        }
    }
}

/// Log layout dimensions for debugging (info level for visibility)
pub fn logLayoutDimensions(nodes: []const LayoutNode, indent: usize) void {
    for (nodes) |node| {
        switch (node) {
            .pane => |p| {
                log.info("{s}pane: width={d:.1}% height={d:.1}% id={?}", .{
                    indentStr(indent),
                    p.width,
                    p.height,
                    p.pane_id,
                });
            },
            .container => |c| {
                log.info("{s}container: width={d:.1}% height={d:.1}%", .{
                    indentStr(indent),
                    c.width,
                    c.height,
                });
                logLayoutDimensions(c.children, indent + 1);
            },
        }
    }
}

fn indentStr(indent: usize) []const u8 {
    const spaces = "                ";
    const len = @min(indent * 2, spaces.len);
    return spaces[0..len];
}

// Tests
test "parseLayoutNodeFromJson pane" {
    const allocator = std.testing.allocator;

    const json =
        \\{"type": "pane", "width": 50, "height": 100}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const node = try parseLayoutNodeFromJson(allocator, parsed.value);
    try std.testing.expectEqual(node.pane.width, 50);
    try std.testing.expectEqual(node.pane.height, 100);
    try std.testing.expectEqual(node.pane.pane_id, null);
}

test "parseLayoutNodeFromJson container" {
    const allocator = std.testing.allocator;

    const json =
        \\{"type": "container", "width": 100, "height": 100, "children": [{"type": "pane", "width": 50, "height": 100}, {"type": "pane", "width": 50, "height": 100}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const node = try parseLayoutNodeFromJson(allocator, parsed.value);
    defer freeLayoutNodes(allocator, node.container.children);

    try std.testing.expectEqual(node.container.width, 100);
    try std.testing.expectEqual(node.container.height, 100);
    try std.testing.expectEqual(node.container.children.len, 2);
}

test "validateLayoutPercentages valid" {
    const allocator = std.testing.allocator;

    // Two 50% panes should be valid
    const nodes = try allocator.alloc(LayoutNode, 2);
    defer allocator.free(nodes);
    nodes[0] = .{ .pane = .{ .width = 50, .height = 100 } };
    nodes[1] = .{ .pane = .{ .width = 50, .height = 100 } };

    try std.testing.expect(validateLayoutPercentages(nodes));
}

test "validateLayoutPercentages invalid - too small" {
    const allocator = std.testing.allocator;

    // Pane with 3% width should be invalid (min is 5%)
    const nodes = try allocator.alloc(LayoutNode, 2);
    defer allocator.free(nodes);
    nodes[0] = .{ .pane = .{ .width = 3, .height = 100 } };
    nodes[1] = .{ .pane = .{ .width = 97, .height = 100 } };

    try std.testing.expect(!validateLayoutPercentages(nodes));
}

test "copyLayoutDimensions preserves pane_id" {
    const allocator = std.testing.allocator;

    // Old nodes with pane IDs
    const old = try allocator.alloc(LayoutNode, 2);
    defer allocator.free(old);
    old[0] = .{ .pane = .{ .width = 50, .height = 100, .pane_id = 1 } };
    old[1] = .{ .pane = .{ .width = 50, .height = 100, .pane_id = 2 } };

    // New nodes with different dimensions, no IDs
    const new = try allocator.alloc(LayoutNode, 2);
    defer allocator.free(new);
    new[0] = .{ .pane = .{ .width = 30, .height = 100 } };
    new[1] = .{ .pane = .{ .width = 70, .height = 100 } };

    try copyLayoutDimensions(old, new);

    // Dimensions should be updated
    try std.testing.expectEqual(old[0].pane.width, 30);
    try std.testing.expectEqual(old[1].pane.width, 70);

    // Pane IDs should be preserved
    try std.testing.expectEqual(old[0].pane.pane_id, 1);
    try std.testing.expectEqual(old[1].pane.pane_id, 2);
}

test "copyLayoutDimensions mismatch length" {
    const allocator = std.testing.allocator;

    const old = try allocator.alloc(LayoutNode, 2);
    defer allocator.free(old);
    old[0] = .{ .pane = .{ .width = 50, .height = 100 } };
    old[1] = .{ .pane = .{ .width = 50, .height = 100 } };

    const new = try allocator.alloc(LayoutNode, 3);
    defer allocator.free(new);
    new[0] = .{ .pane = .{ .width = 33, .height = 100 } };
    new[1] = .{ .pane = .{ .width = 33, .height = 100 } };
    new[2] = .{ .pane = .{ .width = 34, .height = 100 } };

    try std.testing.expectError(error.LayoutMismatch, copyLayoutDimensions(old, new));
}

//! Terminal snapshot generation
//!
//! Converts terminal state to JSON for transmission to clients.

const std = @import("std");
const Pane = @import("pane.zig").Pane;

const log = std.log.scoped(.snapshot);

/// Generate a JSON snapshot of the terminal state
/// For now, this sends the plain text content. Full cell data can be added later.
pub fn generateSnapshot(allocator: std.mem.Allocator, pane: *Pane) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    const screen = pane.terminal.screens.active;
    const cursor = screen.cursor;

    // Get plain text content
    const content = try pane.terminal.plainString(allocator);
    defer allocator.free(content);

    // Start JSON object
    try writer.writeAll("{\"type\":\"snapshot\",\"data\":{");

    // Dimensions
    try writer.print("\"cols\":{d},\"rows\":{d},", .{ pane.cols, pane.rows });

    // Cursor
    const cursor_visible = pane.terminal.modes.get(.cursor_visible);
    try writer.writeAll("\"cursor\":{");
    try writer.print("\"x\":{d},\"y\":{d},", .{ cursor.x, cursor.y });
    try writer.print("\"visible\":{s},", .{if (cursor_visible) "true" else "false"});

    const style_str = switch (cursor.cursor_style) {
        .block, .block_hollow => "block",
        .underline => "underline",
        .bar => "bar",
    };
    try writer.print("\"style\":\"{s}\"", .{style_str});
    try writer.writeAll("},");

    // Alt screen
    const is_alt = pane.terminal.screens.active_key == .alternate;
    try writer.print("\"altScreen\":{s},", .{if (is_alt) "true" else "false"});

    // Plain text content (escaped for JSON)
    try writer.writeAll("\"content\":\"");
    for (content) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u00{x:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeAll("\"");

    try writer.writeAll("}}");

    return buf.toOwnedSlice(allocator);
}

/// Generate a simple text output message (for incremental updates)
pub fn generateOutputMessage(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"type\":\"output\",\"data\":\"");

    // Escape the data for JSON
    for (data) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u00{x:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }

    try writer.writeAll("\"}");

    return buf.toOwnedSlice(allocator);
}

test "generate empty snapshot" {
    const allocator = std.testing.allocator;

    var pane = try Pane.init(allocator, .{ .cols = 10, .rows = 5 });
    defer pane.deinit();

    const json = try generateSnapshot(allocator, &pane);
    defer allocator.free(json);

    // Should be valid JSON starting with our expected structure
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"type\":\"snapshot\""));
}

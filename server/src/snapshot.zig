//! Terminal snapshot generation
//!
//! Converts terminal state to JSON for transmission to clients.
//! Cell data is sent as raw binary (base64-encoded in JSON).

const std = @import("std");
const Pane = @import("pane.zig").Pane;
const ghostty = @import("ghostty-vt");
const Page = ghostty.terminal.page.Page;
const Cell = ghostty.terminal.page.Cell;
const point = ghostty.terminal.point;

const log = std.log.scoped(.snapshot);

/// Base64 encoding table
const base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Encode bytes to base64
fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out_len = ((data.len + 2) / 3) * 4;
    var out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var i: usize = 0;
    var j: usize = 0;
    while (i < data.len) {
        const b0: u32 = data[i];
        const b1: u32 = if (i + 1 < data.len) data[i + 1] else 0;
        const b2: u32 = if (i + 2 < data.len) data[i + 2] else 0;

        const triple = (b0 << 16) | (b1 << 8) | b2;

        out[j] = base64_chars[@as(usize, @intCast((triple >> 18) & 0x3F))];
        out[j + 1] = base64_chars[@as(usize, @intCast((triple >> 12) & 0x3F))];
        out[j + 2] = if (i + 1 < data.len) base64_chars[@as(usize, @intCast((triple >> 6) & 0x3F))] else '=';
        out[j + 3] = if (i + 2 < data.len) base64_chars[@as(usize, @intCast(triple & 0x3F))] else '=';

        i += 3;
        j += 4;
    }

    return out;
}

/// Get raw cell bytes for the visible screen area
fn getCellBytes(allocator: std.mem.Allocator, pane: *Pane) ![]u8 {
    const cols = pane.cols;
    const rows = pane.rows;
    const total_cells = @as(usize, cols) * @as(usize, rows);
    const byte_size = total_cells * 8; // 8 bytes per cell

    var bytes = try allocator.alloc(u8, byte_size);
    errdefer allocator.free(bytes);

    // Get the pages from the terminal
    const pages = &pane.terminal.screens.active.pages;

    // Iterate over each row in the visible screen
    var byte_offset: usize = 0;
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        // Get a pin at the start of this row
        const row_pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(y) } }) orelse {
            // Row doesn't exist, fill with zeros
            @memset(bytes[byte_offset .. byte_offset + cols * 8], 0);
            byte_offset += cols * 8;
            continue;
        };

        // Get cells for this row
        const cells = row_pin.cells(.all);

        // Copy each cell as raw bytes
        for (cells) |cell| {
            const cell_bytes: *const [8]u8 = @ptrCast(&cell);
            @memcpy(bytes[byte_offset .. byte_offset + 8], cell_bytes);
            byte_offset += 8;
        }

        // If row is shorter than expected cols, pad with zeros
        const cells_copied = cells.len;
        if (cells_copied < cols) {
            const padding = (cols - cells_copied) * 8;
            @memset(bytes[byte_offset .. byte_offset + padding], 0);
            byte_offset += padding;
        }
    }

    return bytes;
}

/// Generate a JSON snapshot of the terminal state with raw cell data
pub fn generateSnapshot(allocator: std.mem.Allocator, pane: *Pane) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    const screen = pane.terminal.screens.active;
    const cursor = screen.cursor;

    // Get raw cell bytes and encode to base64
    const cell_bytes = try getCellBytes(allocator, pane);
    defer allocator.free(cell_bytes);

    const cells_base64 = try base64Encode(allocator, cell_bytes);
    defer allocator.free(cells_base64);

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

    // Raw cell data (base64 encoded)
    try writer.writeAll("\"cells\":\"");
    try writer.writeAll(cells_base64);
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
    // Should contain cells field
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cells\":\"") != null);
}

test "base64 encode" {
    const allocator = std.testing.allocator;

    // Test basic encoding
    const encoded = try base64Encode(allocator, "Hello");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("SGVsbG8=", encoded);

    // Test empty
    const empty = try base64Encode(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

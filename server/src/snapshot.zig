//! Terminal snapshot generation
//!
//! Converts terminal state to JSON for transmission to clients.
//! Cell data and styles are sent as raw binary (base64-encoded in JSON).

const std = @import("std");
const Pane = @import("pane.zig").Pane;
const ghostty = @import("ghostty-vt");
const Page = ghostty.page.Page;
const Cell = ghostty.page.Cell;
const point = ghostty.point;

const log = std.log.scoped(.snapshot);

/// Base64 encoding table
const base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Encode bytes to base64
fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return try allocator.alloc(u8, 0);

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

/// Color tag values for wire format
const ColorTag = enum(u8) {
    none = 0,
    palette = 1,
    rgb = 2,
};

/// Encode a color to 4 bytes [tag, v0, v1, v2]
/// Works with any tagged union that has none, palette, and rgb variants
fn encodeColor(c: anytype) [4]u8 {
    return switch (c) {
        .none => .{ @intFromEnum(ColorTag.none), 0, 0, 0 },
        .palette => |idx| .{ @intFromEnum(ColorTag.palette), idx, 0, 0 },
        .rgb => |rgb| .{ @intFromEnum(ColorTag.rgb), rgb.r, rgb.g, rgb.b },
    };
}

/// Encode style flags to u16 (matching protocol/schema/style.ts)
fn encodeFlags(flags: anytype) u16 {
    var result: u16 = 0;
    if (flags.bold) result |= 0x01;
    if (flags.italic) result |= 0x02;
    if (flags.faint) result |= 0x04;
    if (flags.blink) result |= 0x08;
    if (flags.inverse) result |= 0x10;
    if (flags.invisible) result |= 0x20;
    if (flags.strikethrough) result |= 0x40;
    if (flags.overline) result |= 0x80;
    result |= @as(u16, @intFromEnum(flags.underline)) << 8;
    return result;
}

/// Encode a single Style to 14 bytes
/// Works with any struct that has fg_color, bg_color, underline_color, flags
fn encodeStyle(style: anytype) [14]u8 {
    var bytes: [14]u8 = undefined;

    // fg_color (bytes 0-3)
    const fg = encodeColor(style.fg_color);
    bytes[0..4].* = fg;

    // bg_color (bytes 4-7)
    const bg = encodeColor(style.bg_color);
    bytes[4..8].* = bg;

    // underline_color (bytes 8-11)
    const ul = encodeColor(style.underline_color);
    bytes[8..12].* = ul;

    // flags (bytes 12-13, little-endian)
    const flags = encodeFlags(style.flags);
    bytes[12] = @truncate(flags & 0xFF);
    bytes[13] = @truncate((flags >> 8) & 0xFF);

    return bytes;
}

/// Result from getCellBytesAndStyles
const CellsAndStyles = struct {
    cell_bytes: []u8,
    style_bytes: []u8,

    pub fn deinit(self: *CellsAndStyles, allocator: std.mem.Allocator) void {
        allocator.free(self.cell_bytes);
        allocator.free(self.style_bytes);
    }
};

/// Get raw cell bytes and style table for the visible screen area
fn getCellBytesAndStyles(allocator: std.mem.Allocator, pane: *Pane) !CellsAndStyles {
    const cols = pane.cols;
    const rows = pane.rows;
    const total_cells = @as(usize, cols) * @as(usize, rows);
    const byte_size = total_cells * 8; // 8 bytes per cell

    var cell_bytes = try allocator.alloc(u8, byte_size);
    errdefer allocator.free(cell_bytes);

    // Track unique style_ids we encounter
    var style_ids = std.AutoHashMap(u16, void).init(allocator);
    defer style_ids.deinit();

    // Get the pages from the terminal
    const pages = &pane.terminal.screens.active.pages;

    // Iterate over each row in the visible screen
    var byte_offset: usize = 0;
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        // Get a pin at the start of this row
        const row_pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(y) } }) orelse {
            // Row doesn't exist, fill with zeros
            @memset(cell_bytes[byte_offset .. byte_offset + cols * 8], 0);
            byte_offset += cols * 8;
            continue;
        };

        // Get cells for this row
        const cells = row_pin.cells(.all);

        // Copy each cell as raw bytes and track style_ids
        for (cells) |cell| {
            const cell_bytes_ptr: *const [8]u8 = @ptrCast(&cell);
            @memcpy(cell_bytes[byte_offset .. byte_offset + 8], cell_bytes_ptr);
            byte_offset += 8;

            // Track non-zero style_ids
            if (cell.style_id > 0) {
                try style_ids.put(cell.style_id, {});
            }
        }

        // If row is shorter than expected cols, pad with zeros
        const cells_copied = cells.len;
        if (cells_copied < cols) {
            const padding = (cols - cells_copied) * 8;
            @memset(cell_bytes[byte_offset .. byte_offset + padding], 0);
            byte_offset += padding;
        }
    }

    // Now build the style table
    // Format: [count: u16] [id: u16, style: 14 bytes] ...
    const style_count = style_ids.count();
    const style_table_size = 2 + style_count * (2 + 14);
    var style_bytes = try allocator.alloc(u8, style_table_size);
    errdefer allocator.free(style_bytes);

    // Write count (little-endian)
    style_bytes[0] = @truncate(style_count & 0xFF);
    style_bytes[1] = @truncate((style_count >> 8) & 0xFF);

    // Get the page to look up styles
    // Use the first pin's page (they should all be the same for visible area)
    const first_pin = pages.pin(.{ .screen = .{ .x = 0, .y = 0 } });

    var style_offset: usize = 2;
    var it = style_ids.keyIterator();
    while (it.next()) |style_id_ptr| {
        const style_id = style_id_ptr.*;

        // Write style_id (little-endian)
        style_bytes[style_offset] = @truncate(style_id & 0xFF);
        style_bytes[style_offset + 1] = @truncate((style_id >> 8) & 0xFF);
        style_offset += 2;

        // Look up the style and encode it
        if (first_pin) |pin| {
            const page = &pin.node.data;
            const style = page.styles.get(page.memory, style_id);
            const encoded = encodeStyle(style);
            @memcpy(style_bytes[style_offset .. style_offset + 14], &encoded);
        } else {
            // No page, write default style (all zeros)
            @memset(style_bytes[style_offset .. style_offset + 14], 0);
        }
        style_offset += 14;
    }

    return .{
        .cell_bytes = cell_bytes,
        .style_bytes = style_bytes,
    };
}

/// Generate a JSON snapshot of the terminal state with raw cell data
pub fn generateSnapshot(allocator: std.mem.Allocator, pane: *Pane) ![]u8 {
    // Lock pane to prevent concurrent modification during snapshot
    pane.lock();
    defer pane.unlock();
    
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    const screen = pane.terminal.screens.active;
    const cursor = screen.cursor;

    // Get raw cell bytes and styles, encode to base64
    var cells_and_styles = try getCellBytesAndStyles(allocator, pane);
    defer cells_and_styles.deinit(allocator);

    const cells_base64 = try base64Encode(allocator, cells_and_styles.cell_bytes);
    defer allocator.free(cells_base64);

    const styles_base64 = try base64Encode(allocator, cells_and_styles.style_bytes);
    defer allocator.free(styles_base64);

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
    try writer.writeAll("\",");

    // Style table (base64 encoded)
    try writer.writeAll("\"styles\":\"");
    try writer.writeAll(styles_base64);
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
    // Should contain styles field
    try std.testing.expect(std.mem.indexOf(u8, json, "\"styles\":\"") != null);
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

//! Terminal snapshot generation
//!
//! Converts terminal state to binary msgpack for transmission to clients.
//! Cell data and styles are sent as raw binary bytes within msgpack.
//! Output is compressed with Snappy for efficient transmission.

const std = @import("std");
const msgpack = @import("msgpack");
const snappy = @import("snappy");
const Pane = @import("pane.zig").Pane;
const ghostty = @import("ghostty-vt");
const Page = ghostty.page.Page;
const Cell = ghostty.page.Cell;
const point = ghostty.point;

const log = std.log.scoped(.snapshot);

// ============================================================================
// Buffer Stream for msgpack encoding
// ============================================================================
// 
// The zig-msgpack compat layer uses std.io.FixedBufferStream for Zig < 0.16,
// which can return PARTIAL writes when buffer fills. msgpack expects all-or-nothing
// writes and returns LengthWriting error on partial writes.
//
// This custom BufferStream returns error.NoSpaceLeft instead of partial writes.

const BufferStream = struct {
    buffer: []u8,
    pos: usize,

    const Self = @This();

    pub const WriteError = error{NoSpaceLeft};
    pub const ReadError = error{EndOfStream};

    pub fn init(buffer: []u8) Self {
        return .{ .buffer = buffer, .pos = 0 };
    }

    pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
        const available = self.buffer.len - self.pos;
        if (bytes.len > available) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
        return bytes.len;
    }

    pub fn read(self: *Self, dest: []u8) ReadError!usize {
        const available = self.buffer.len - self.pos;
        if (available == 0) return 0;
        const to_read = @min(dest.len, available);
        @memcpy(dest[0..to_read], self.buffer[self.pos..][0..to_read]);
        self.pos += to_read;
        return to_read;
    }
};

// ============================================================================
// Row ID Computation (for delta sync protocol)
// ============================================================================

/// Page size for row_id computation. Matches ghostty's typical page size.
/// row_id = (page_serial * PAGE_SIZE) + row_index_in_page
/// See docs/delta-sync-design.md for details.
pub const PAGE_SIZE: u64 = 1000;

/// Minimum payload size before compression is applied.
/// Smaller payloads don't benefit from compression overhead.
/// See docs/delta-sync-design.md for rationale.
pub const COMPRESSION_THRESHOLD: usize = 256;

/// Compute stable row_id from a pin's page serial and row index.
/// Returns a unique, monotonic ID that persists until the row is pruned.
pub fn computeRowId(pin: anytype) u64 {
    return pin.node.serial * PAGE_SIZE + pin.y;
}

/// Conditionally compress data with Snappy.
/// Skips compression for small payloads where overhead exceeds benefit.
/// Returns owned slice that caller must free.
fn maybeCompress(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (data.len < COMPRESSION_THRESHOLD) {
        // Small payload - return uncompressed copy with 1-byte header
        const result = try allocator.alloc(u8, data.len + 1);
        result[0] = 0; // Header: not compressed
        @memcpy(result[1..], data);
        return result;
    }

    // Compress with Snappy
    const compressed_max = snappy.raw.maxCompressedLength(data.len);
    const compressed_buf = try allocator.alloc(u8, compressed_max + 1);
    errdefer allocator.free(compressed_buf);

    compressed_buf[0] = 1; // Header: compressed
    const compressed_len = snappy.raw.compress(data, compressed_buf[1..]) catch |e| {
        log.err("Failed to compress: {any}", .{e});
        return error.CompressionFailed;
    };

    // Trim to actual size
    const result = try allocator.realloc(compressed_buf, compressed_len + 1);
    return result;
}

// ============================================================================
// JSON Message Types
// ============================================================================

/// Cursor info for snapshot
const CursorInfo = struct {
    x: usize,
    y: usize,
    visible: bool,
    style: []const u8,
};

/// Scrollback info for client-side scrolling
const ScrollbackInfo = struct {
    totalRows: usize,      // Total rows including scrollback
    viewportTop: usize,    // Current viewport offset from top
};

/// Snapshot data payload
const SnapshotData = struct {
    cols: u16,
    rows: u16,
    cursor: CursorInfo,
    altScreen: bool,
    scrollback: ScrollbackInfo,
    cells: []const u8, // base64 encoded
    styles: []const u8, // base64 encoded
};

/// Snapshot message wrapper
const SnapshotMessage = struct {
    type: []const u8 = "snapshot",
    data: SnapshotData,
};

/// Output message for incremental updates
const OutputMessage = struct {
    type: []const u8 = "output",
    data: []const u8,
};

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
    row_ids: []u64, // Stable row IDs for delta sync

    pub fn deinit(self: *CellsAndStyles, allocator: std.mem.Allocator) void {
        allocator.free(self.cell_bytes);
        allocator.free(self.style_bytes);
        allocator.free(self.row_ids);
    }
};

/// Get raw cell bytes, style table, and row IDs for the visible screen area
fn getCellBytesAndStyles(allocator: std.mem.Allocator, pane: *Pane) !CellsAndStyles {
    const cols = pane.cols;
    const rows = pane.rows;
    const total_cells = @as(usize, cols) * @as(usize, rows);
    const byte_size = total_cells * 8; // 8 bytes per cell

    var cell_bytes = try allocator.alloc(u8, byte_size);
    errdefer allocator.free(cell_bytes);

    // Allocate row_ids array
    var row_ids = try allocator.alloc(u64, rows);
    errdefer allocator.free(row_ids);

    // Track unique styles we encounter (keyed by style_id)
    // We store the encoded style bytes directly to avoid cross-page lookup issues
    var styles_map = std.AutoHashMap(u16, [14]u8).init(allocator);
    defer styles_map.deinit();

    // Get the pages from the terminal
    const pages = &pane.terminal.screens.active.pages;

    // Iterate over each row in the visible screen
    var byte_offset: usize = 0;
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        // Get a pin at the start of this row (viewport-relative coordinates)
        const row_pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }) orelse {
            // Row doesn't exist, fill with zeros
            @memset(cell_bytes[byte_offset .. byte_offset + cols * 8], 0);
            row_ids[y] = 0; // Invalid row_id for non-existent rows
            byte_offset += cols * 8;
            continue;
        };

        // Compute stable row_id for this row
        row_ids[y] = computeRowId(row_pin);

        // Get cells for this row
        const cells = row_pin.cells(.all);

        // Get page for style lookups (must use THIS row's page, not first row's)
        const page = &row_pin.node.data;

        // Copy each cell as raw bytes and collect styles
        for (cells) |cell| {
            const cell_bytes_ptr: *const [8]u8 = @ptrCast(&cell);
            @memcpy(cell_bytes[byte_offset .. byte_offset + 8], cell_bytes_ptr);
            byte_offset += 8;

            // Collect non-zero styles (encode immediately from correct page)
            if (cell.style_id > 0 and !styles_map.contains(cell.style_id)) {
                const style = page.styles.get(page.memory, cell.style_id);
                const encoded = encodeStyle(style);
                try styles_map.put(cell.style_id, encoded);
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

    // Now build the style table from collected styles
    // Format: [count: u16] [id: u16, style: 14 bytes] ...
    const style_count = styles_map.count();
    const style_table_size = 2 + style_count * (2 + 14);
    var style_bytes = try allocator.alloc(u8, style_table_size);
    errdefer allocator.free(style_bytes);

    // Write count (little-endian)
    style_bytes[0] = @truncate(style_count & 0xFF);
    style_bytes[1] = @truncate((style_count >> 8) & 0xFF);

    var style_offset: usize = 2;
    var it = styles_map.iterator();
    while (it.next()) |entry| {
        const style_id = entry.key_ptr.*;
        const encoded = entry.value_ptr.*;

        // Write style_id (little-endian)
        style_bytes[style_offset] = @truncate(style_id & 0xFF);
        style_bytes[style_offset + 1] = @truncate((style_id >> 8) & 0xFF);
        style_offset += 2;

        // Write pre-encoded style
        @memcpy(style_bytes[style_offset .. style_offset + 14], &encoded);
        style_offset += 14;
    }

    return .{
        .cell_bytes = cell_bytes,
        .style_bytes = style_bytes,
        .row_ids = row_ids,
    };
}

/// Generate a JSON snapshot of the terminal state with raw cell data
pub fn generateSnapshot(allocator: std.mem.Allocator, pane: *Pane) ![]u8 {
    // Lock pane to prevent concurrent modification during snapshot
    pane.lock();
    defer pane.unlock();

    const screen = pane.terminal.screens.active;
    const cursor = screen.cursor;

    // Get raw cell bytes and styles, encode to base64
    var cells_and_styles = try getCellBytesAndStyles(allocator, pane);
    defer cells_and_styles.deinit(allocator);

    const cells_base64 = try base64Encode(allocator, cells_and_styles.cell_bytes);
    defer allocator.free(cells_base64);

    const styles_base64 = try base64Encode(allocator, cells_and_styles.style_bytes);
    defer allocator.free(styles_base64);

    // Build cursor style string
    const cursor_style_str = switch (cursor.cursor_style) {
        .block, .block_hollow => "block",
        .underline => "underline",
        .bar => "bar",
    };

    // Get scrollback info
    const pages = &screen.pages;
    const scrollbar = pages.scrollbar();

    // Build the message struct
    const message = SnapshotMessage{
        .data = .{
            .cols = pane.cols,
            .rows = pane.rows,
            .cursor = .{
                .x = cursor.x,
                .y = cursor.y,
                .visible = pane.terminal.modes.get(.cursor_visible),
                .style = cursor_style_str,
            },
            .altScreen = pane.terminal.screens.active_key == .alternate,
            .scrollback = .{
                .totalRows = scrollbar.total,
                .viewportTop = scrollbar.offset,
            },
            .cells = cells_base64,
            .styles = styles_base64,
        },
    };

    // Serialize to JSON using std.json
    return std.json.Stringify.valueAlloc(allocator, message, .{});
}

/// Generate a simple text output message (for incremental updates)
pub fn generateOutputMessage(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const message = OutputMessage{
        .data = data,
    };

    // Serialize to JSON using std.json
    return std.json.Stringify.valueAlloc(allocator, message, .{});
}

// ============================================================================
// Binary Msgpack Snapshot
// ============================================================================

/// Generate a binary msgpack snapshot of the terminal state
pub fn generateBinarySnapshot(allocator: std.mem.Allocator, pane: *Pane) ![]u8 {
    // Lock pane to prevent concurrent modification during snapshot
    pane.lock();
    defer pane.unlock();

    const screen = pane.terminal.screens.active;
    const cursor = screen.cursor;

    // Get raw cell bytes and styles (no base64)
    var cells_and_styles = try getCellBytesAndStyles(allocator, pane);
    defer cells_and_styles.deinit(allocator);

    // Build cursor style string
    const cursor_style_str = switch (cursor.cursor_style) {
        .block, .block_hollow => "block",
        .underline => "underline",
        .bar => "bar",
    };

    // Get scrollback info
    const pages = &screen.pages;
    const scrollbar = pages.scrollbar();

    // Build msgpack payload
    var payload = msgpack.Payload.mapPayload(allocator);
    errdefer payload.free(allocator);

    try payload.mapPut("type", try msgpack.Payload.strToPayload("snapshot", allocator));
    try payload.mapPut("gen", msgpack.Payload{ .uint = pane.generation }); // Generation counter for delta sync
    try payload.mapPut("cols", msgpack.Payload{ .uint = pane.cols });
    try payload.mapPut("rows", msgpack.Payload{ .uint = pane.rows });

    // Cursor object
    var cursor_map = msgpack.Payload.mapPayload(allocator);
    try cursor_map.mapPut("x", msgpack.Payload{ .uint = cursor.x });
    try cursor_map.mapPut("y", msgpack.Payload{ .uint = cursor.y });
    try cursor_map.mapPut("visible", msgpack.Payload{ .bool = pane.terminal.modes.get(.cursor_visible) });
    try cursor_map.mapPut("style", try msgpack.Payload.strToPayload(cursor_style_str, allocator));
    try payload.mapPut("cursor", cursor_map);

    // Alt screen flag
    try payload.mapPut("altScreen", msgpack.Payload{ .bool = pane.terminal.screens.active_key == .alternate });

    // Scrollback info
    var scrollback_map = msgpack.Payload.mapPayload(allocator);
    try scrollback_map.mapPut("totalRows", msgpack.Payload{ .uint = scrollbar.total });
    try scrollback_map.mapPut("viewportTop", msgpack.Payload{ .uint = scrollbar.offset });
    try payload.mapPut("scrollback", scrollback_map);

    // Raw binary cell data (no base64!)
    try payload.mapPut("cells", try msgpack.Payload.binToPayload(cells_and_styles.cell_bytes, allocator));
    try payload.mapPut("styles", try msgpack.Payload.binToPayload(cells_and_styles.style_bytes, allocator));

    // Row IDs for delta sync (as binary packed u64 array, little-endian)
    const row_ids_bytes = std.mem.sliceAsBytes(cells_and_styles.row_ids);
    try payload.mapPut("rowIds", try msgpack.Payload.binToPayload(row_ids_bytes, allocator));

    // Encode to msgpack bytes
    // Use a buffer large enough for typical terminal snapshots
    // 80x24 terminal = 1920 cells * 8 bytes = ~15KB cells + styles + overhead
    const max_size = 4 * 1024 * 1024; // 4MB for up to 500x500 terminals
    const buffer = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buffer);

    var write_stream = BufferStream.init(buffer);
    var read_stream = BufferStream.init(buffer);

    const BufferType = BufferStream;
    var packer = msgpack.Pack(
        *BufferType,
        *BufferType,
        BufferType.WriteError,
        BufferType.ReadError,
        BufferType.write,
        BufferType.read,
    ).init(&write_stream, &read_stream);

    packer.write(payload) catch |e| {
        log.err("Failed to encode msgpack: {any}", .{e});
        return error.MsgpackEncodeFailed;
    };

    // Free payload after encoding
    payload.free(allocator);

    // Conditionally compress
    const msgpack_len = write_stream.pos;
    const msgpack_data = buffer[0..msgpack_len];

    const result = try maybeCompress(msgpack_data, allocator);

    // Free the uncompressed buffer
    allocator.free(buffer);

    return result;
}

/// Generate a binary msgpack pong message
pub fn generateBinaryPong(allocator: std.mem.Allocator) ![]u8 {
    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);

    try payload.mapPut("type", try msgpack.Payload.strToPayload("pong", allocator));

    const max_size = 64;
    const buffer = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buffer);

    var write_stream = BufferStream.init(buffer);
    var read_stream = BufferStream.init(buffer);

    const BufferType = BufferStream;
    var packer = msgpack.Pack(
        *BufferType,
        *BufferType,
        BufferType.WriteError,
        BufferType.ReadError,
        BufferType.write,
        BufferType.read,
    ).init(&write_stream, &read_stream);

    packer.write(payload) catch |e| {
        log.err("Failed to encode msgpack pong: {any}", .{e});
        return error.MsgpackEncodeFailed;
    };

    // Conditionally compress (pong is small, likely won't compress)
    const msgpack_len = write_stream.pos;
    const msgpack_data = buffer[0..msgpack_len];

    const result = try maybeCompress(msgpack_data, allocator);
    allocator.free(buffer);

    return result;
}

/// Generate a delta update message with only dirty rows
/// If empty is true, generates a minimal delta with no row changes
pub fn generateDelta(allocator: std.mem.Allocator, pane: *Pane, empty: bool) ![]u8 {
    pane.lock();
    defer pane.unlock();

    const screen = pane.terminal.screens.active;
    const pages = &screen.pages;
    const scrollbar = pages.scrollbar();

    const cursor = screen.cursor;

    var payload = msgpack.Payload.mapPayload(allocator);
    errdefer payload.free(allocator);

    try payload.mapPut("type", try msgpack.Payload.strToPayload("delta", allocator));
    try payload.mapPut("gen", msgpack.Payload{ .uint = pane.generation });

    // Viewport info
    var vp_map = msgpack.Payload.mapPayload(allocator);
    try vp_map.mapPut("totalRows", msgpack.Payload{ .uint = scrollbar.total });
    try vp_map.mapPut("viewportTop", msgpack.Payload{ .uint = scrollbar.offset });
    try payload.mapPut("vp", vp_map);

    // Dimensions
    try payload.mapPut("cols", msgpack.Payload{ .uint = pane.cols });
    try payload.mapPut("rows", msgpack.Payload{ .uint = pane.rows });

    // Cursor object (same as snapshot)
    const cursor_style_str = switch (cursor.cursor_style) {
        .block, .block_hollow => "block",
        .underline => "underline",
        .bar => "bar",
    };
    var cursor_map = msgpack.Payload.mapPayload(allocator);
    try cursor_map.mapPut("x", msgpack.Payload{ .uint = cursor.x });
    try cursor_map.mapPut("y", msgpack.Payload{ .uint = cursor.y });
    try cursor_map.mapPut("visible", msgpack.Payload{ .bool = pane.terminal.modes.get(.cursor_visible) });
    try cursor_map.mapPut("style", try msgpack.Payload.strToPayload(cursor_style_str, allocator));
    try payload.mapPut("cursor", cursor_map);

    // Alt screen flag
    try payload.mapPut("altScreen", msgpack.Payload{ .bool = pane.terminal.screens.active_key == .alternate });

    // Build list of dirty rows, prioritizing visible viewport rows
    // Viewport rows come first for faster perceived rendering
    const DirtyEntry = struct {
        id: u64,
        y: i32, // viewport y, or -1 for off-screen rows
    };
    var viewport_dirty: std.ArrayListUnmanaged(DirtyEntry) = .{};
    defer viewport_dirty.deinit(allocator);
    var offscreen_dirty: std.ArrayListUnmanaged(DirtyEntry) = .{};
    defer offscreen_dirty.deinit(allocator);

    if (!empty) {
        const dirty_rows = pane.getDirtyRows();

        // Track which row IDs we've added to viewport list (for O(1) lookup)
        var viewport_row_ids = std.AutoHashMap(u64, void).init(allocator);
        defer viewport_row_ids.deinit();

        // First pass: find dirty rows visible in viewport
        var y: usize = 0;
        while (y < pane.rows) : (y += 1) {
            const pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }) orelse continue;
            const row_id = computeRowId(pin);
            if (dirty_rows.contains(row_id)) {
                try viewport_dirty.append(allocator, .{ .id = row_id, .y = @intCast(y) });
                try viewport_row_ids.put(row_id, {});
            }
        }

        // Second pass: find dirty rows in scrollback (off-screen)
        // O(dirty_rows) with O(1) lookup instead of O(dirty_rows × viewport_dirty)
        var it = dirty_rows.keyIterator();
        while (it.next()) |row_id_ptr| {
            const row_id = row_id_ptr.*;
            if (!viewport_row_ids.contains(row_id)) {
                try offscreen_dirty.append(allocator, .{ .id = row_id, .y = -1 });
            }
        }
    }

    // Track styles used by dirty rows (store encoded bytes to avoid cross-page issues)
    var styles_map = std.AutoHashMap(u16, [14]u8).init(allocator);
    defer styles_map.deinit();

    // Collect row payloads into a list first (since some may be skipped)
    var row_payloads: std.ArrayListUnmanaged(msgpack.Payload) = .{};
    defer row_payloads.deinit(allocator);

    // Add viewport rows first (visible, high priority)
    for (viewport_dirty.items) |item| {
        const pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(item.y) } }) orelse continue;

        // Get page for style lookups (must use THIS row's page)
        const page = &pin.node.data;

        // Encode the row
        var row_map = msgpack.Payload.mapPayload(allocator);
        try row_map.mapPut("id", msgpack.Payload{ .uint = item.id });

        // Get cells for this row
        const cells = pin.cells(.all);
        const cell_bytes = try allocator.alloc(u8, cells.len * 8);
        defer allocator.free(cell_bytes);

        for (cells, 0..) |cell, i| {
            const cell_bytes_ptr: *const [8]u8 = @ptrCast(&cell);
            @memcpy(cell_bytes[i * 8 .. (i + 1) * 8], cell_bytes_ptr);

            // Collect style (encode immediately from correct page)
            if (cell.style_id > 0 and !styles_map.contains(cell.style_id)) {
                const style = page.styles.get(page.memory, cell.style_id);
                const encoded = encodeStyle(style);
                try styles_map.put(cell.style_id, encoded);
            }
        }

        try row_map.mapPut("cells", try msgpack.Payload.binToPayload(cell_bytes, allocator));
        try row_payloads.append(allocator, row_map);
    }

    // Add off-screen rows (lower priority, for scrollback consistency)
    for (offscreen_dirty.items) |item| {
        // Find this row by iterating pages - off-screen rows need screen coordinates
        // For now, skip off-screen rows since we don't have an efficient lookup
        // TODO(du-ipx): Implement proper off-screen row lookup when upgrading dirty tracking
        _ = item;
    }

    // Build the final array with exact size
    var rows_array = try msgpack.Payload.arrPayload(row_payloads.items.len, allocator);
    for (row_payloads.items, 0..) |row_map, i| {
        try rows_array.setArrElement(i, row_map);
    }

    try payload.mapPut("dirtyRows", rows_array);

    // Build row IDs array for current viewport (same as snapshot)
    // This tells the client which row IDs are in each viewport position
    var row_ids = try allocator.alloc(u64, pane.rows);
    defer allocator.free(row_ids);

    for (0..pane.rows) |y| {
        const pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } });
        if (pin) |p| {
            row_ids[y] = computeRowId(p);
        } else {
            row_ids[y] = 0;
        }
    }

    const row_ids_bytes = std.mem.sliceAsBytes(row_ids);
    try payload.mapPut("rowIds", try msgpack.Payload.binToPayload(row_ids_bytes, allocator));

    log.debug("Delta: {d} dirty rows, {d} row IDs ({d} bytes), first rowId={d}", .{
        row_payloads.items.len,
        pane.rows,
        row_ids_bytes.len,
        if (pane.rows > 0) row_ids[0] else 0,
    });

    // Build style table for dirty rows from collected styles
    // Format: [count: u16] [id: u16, style: 14 bytes] ...
    const style_count = styles_map.count();
    const style_table_size = 2 + style_count * (2 + 14);
    var style_bytes = try allocator.alloc(u8, style_table_size);
    defer allocator.free(style_bytes);

    // Write count (little-endian)
    style_bytes[0] = @truncate(style_count & 0xFF);
    style_bytes[1] = @truncate((style_count >> 8) & 0xFF);

    var style_offset: usize = 2;
    var style_it = styles_map.iterator();
    while (style_it.next()) |entry| {
        const style_id = entry.key_ptr.*;
        const encoded = entry.value_ptr.*;

        // Write style_id (little-endian)
        style_bytes[style_offset] = @truncate(style_id & 0xFF);
        style_bytes[style_offset + 1] = @truncate((style_id >> 8) & 0xFF);
        style_offset += 2;

        // Write pre-encoded style
        @memcpy(style_bytes[style_offset .. style_offset + 14], &encoded);
        style_offset += 14;
    }

    try payload.mapPut("styles", try msgpack.Payload.binToPayload(style_bytes, allocator));

    // Encode and compress
    const max_size = 4 * 1024 * 1024;
    const buffer = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buffer);

    var write_stream = BufferStream.init(buffer);
    var read_stream = BufferStream.init(buffer);

    const BufferType = BufferStream;
    var packer = msgpack.Pack(
        *BufferType,
        *BufferType,
        BufferType.WriteError,
        BufferType.ReadError,
        BufferType.write,
        BufferType.read,
    ).init(&write_stream, &read_stream);

    packer.write(payload) catch |e| {
        log.err("Failed to encode msgpack delta: {any}", .{e});
        return error.MsgpackEncodeFailed;
    };

    payload.free(allocator);

    // Conditionally compress
    const msgpack_len = write_stream.pos;
    const msgpack_data = buffer[0..msgpack_len];

    const result = try maybeCompress(msgpack_data, allocator);
    allocator.free(buffer);

    return result;
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

test "row_id computation" {
    // Test the row_id formula: (page_serial * PAGE_SIZE) + row_index
    // PAGE_SIZE = 1000

    // Mock pin structure for testing
    const MockNode = struct {
        serial: u64,
    };
    const MockPin = struct {
        node: *const MockNode,
        y: u32,
    };

    const node1 = MockNode{ .serial = 0 };
    const pin1 = MockPin{ .node = &node1, .y = 0 };
    try std.testing.expectEqual(@as(u64, 0), computeRowId(pin1));

    const node2 = MockNode{ .serial = 0 };
    const pin2 = MockPin{ .node = &node2, .y = 42 };
    try std.testing.expectEqual(@as(u64, 42), computeRowId(pin2));

    const node3 = MockNode{ .serial = 5 };
    const pin3 = MockPin{ .node = &node3, .y = 0 };
    try std.testing.expectEqual(@as(u64, 5000), computeRowId(pin3));

    const node4 = MockNode{ .serial = 5 };
    const pin4 = MockPin{ .node = &node4, .y = 123 };
    try std.testing.expectEqual(@as(u64, 5123), computeRowId(pin4));

    // Test larger serials
    const node5 = MockNode{ .serial = 1000000 };
    const pin5 = MockPin{ .node = &node5, .y = 999 };
    try std.testing.expectEqual(@as(u64, 1000000999), computeRowId(pin5));
}

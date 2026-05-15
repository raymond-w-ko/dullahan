//! Kitty graphics image manifest and HTTP helpers.

const std = @import("std");
const msgpack = @import("msgpack");
const Pane = @import("pane.zig").Pane;
const png_decoder = @import("png_decoder.zig");

const log = std.log.scoped(.image);

const ImageFormat = enum {
    rgb,
    rgba,
    png,
    gray_alpha,
    gray,
    unknown,
};

pub const ImageResponse = struct {
    data: []const u8,
    mime_type: []const u8,
    format: []const u8,
    width: u32,
    height: u32,
    owned: bool = false,
};

fn imageFormat(format: anytype) ImageFormat {
    const name = @tagName(format);
    if (std.mem.eql(u8, name, "rgb")) return .rgb;
    if (std.mem.eql(u8, name, "rgba")) return .rgba;
    if (std.mem.eql(u8, name, "png")) return .png;
    if (std.mem.eql(u8, name, "gray_alpha")) return .gray_alpha;
    if (std.mem.eql(u8, name, "gray")) return .gray;
    return .unknown;
}

fn imageFormatString(format: ImageFormat) []const u8 {
    return switch (format) {
        .rgb => "rgb",
        .rgba => "rgba",
        .png => "png",
        .gray_alpha => "gray_alpha",
        .gray => "gray",
        .unknown => "unknown",
    };
}

fn pointFromPlacement(
    pane: *Pane,
    placement: anytype,
    image: anytype,
) ?struct { col: i32, row: i32, visible: bool } {
    const pin = switch (placement.location) {
        .pin => |pin| pin,
        .virtual => return null,
    };

    const pages = &pane.terminal.screens.active.pages;
    const pin_screen = pages.pointFromPin(.screen, pin.*) orelse return null;
    const vp_tl = pages.getTopLeft(.viewport);
    const vp_screen = pages.pointFromPin(.screen, vp_tl) orelse return null;

    const grid_size = placement.gridSize(image.*, &pane.terminal);
    const vp_row: i32 = @as(i32, @intCast(pin_screen.screen.y)) -
        @as(i32, @intCast(vp_screen.screen.y));
    const rows_i32: i32 = @intCast(grid_size.rows);
    const term_rows: i32 = @intCast(pane.rows);
    const visible = vp_row + rows_i32 > 0 and vp_row < term_rows;

    return .{
        .col = @intCast(pin_screen.screen.x),
        .row = vp_row,
        .visible = visible,
    };
}

fn writeImageKey(writer: anytype, pane_id: u16, image_id: u32, data_len: usize) !void {
    try writer.print("{d}-{d}-{d}", .{ pane_id, image_id, data_len });
}

pub fn appendImageKey(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    pane_id: u16,
    image_id: u32,
    data_len: usize,
) ![]const u8 {
    const start = out.items.len;
    try writeImageKey(out.writer(allocator), pane_id, image_id, data_len);
    return out.items[start..];
}

pub fn allocImageKey(
    allocator: std.mem.Allocator,
    pane_id: u16,
    image_id: u32,
    data_len: usize,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    try writeImageKey(out.writer(allocator), pane_id, image_id, data_len);
    return out.toOwnedSlice(allocator);
}

fn parseImageKey(raw: []const u8) ?struct { pane_id: u16, image_id: u32, data_len: usize } {
    var it = std.mem.splitScalar(u8, raw, '-');
    const pane_str = it.next() orelse return null;
    const image_str = it.next() orelse return null;
    const len_str = it.next() orelse return null;
    if (it.next() != null) return null;

    return .{
        .pane_id = std.fmt.parseInt(u16, pane_str, 10) catch return null,
        .image_id = std.fmt.parseInt(u32, image_str, 10) catch return null,
        .data_len = std.fmt.parseInt(usize, len_str, 10) catch return null,
    };
}

fn writePngChunk(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    chunk_type: *const [4]u8,
    data: []const u8,
) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, chunk_type);
    try out.appendSlice(allocator, data);

    var crc_data = try allocator.alloc(u8, chunk_type.len + data.len);
    defer allocator.free(crc_data);
    @memcpy(crc_data[0..chunk_type.len], chunk_type);
    @memcpy(crc_data[chunk_type.len..], data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, std.hash.crc.Crc32.hash(crc_data), .big);
    try out.appendSlice(allocator, &crc_buf);
}

fn pngFromRaw(
    allocator: std.mem.Allocator,
    data: []const u8,
    format: ImageFormat,
    width: u32,
    height: u32,
) ![]u8 {
    const bpp: usize = switch (format) {
        .rgb => 3,
        .rgba => 4,
        else => return error.UnsupportedFormat,
    };
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (data.len != pixel_count * bpp) return error.InvalidData;

    const row_len = 1 + @as(usize, width) * 4;
    const filtered = try allocator.alloc(u8, row_len * @as(usize, height));
    defer allocator.free(filtered);

    for (0..@as(usize, height)) |y| {
        const row_start = y * row_len;
        filtered[row_start] = 0;
        for (0..@as(usize, width)) |x| {
            const src = (y * @as(usize, width) + x) * bpp;
            const dst = row_start + 1 + x * 4;
            filtered[dst] = data[src];
            filtered[dst + 1] = data[src + 1];
            filtered[dst + 2] = data[src + 2];
            filtered[dst + 3] = if (format == .rgba) data[src + 3] else 255;
        }
    }

    var zlib: std.ArrayListUnmanaged(u8) = .{};
    defer zlib.deinit(allocator);
    try zlib.appendSlice(allocator, &.{ 0x78, 0x01 });
    var remaining = filtered;
    while (remaining.len > 0) {
        const block_len = @min(remaining.len, 65535);
        const final: u8 = if (block_len == remaining.len) 1 else 0;
        try zlib.append(allocator, final);
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(block_len), .little);
        try zlib.appendSlice(allocator, &len_buf);
        std.mem.writeInt(u16, &len_buf, ~@as(u16, @intCast(block_len)), .little);
        try zlib.appendSlice(allocator, &len_buf);
        try zlib.appendSlice(allocator, remaining[0..block_len]);
        remaining = remaining[block_len..];
    }
    var adler_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_buf, std.hash.Adler32.hash(filtered), .big);
    try zlib.appendSlice(allocator, &adler_buf);

    var png: std.ArrayListUnmanaged(u8) = .{};
    errdefer png.deinit(allocator);
    try png.appendSlice(allocator, "\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writePngChunk(&png, allocator, "IHDR", &ihdr);
    try writePngChunk(&png, allocator, "IDAT", zlib.items);
    try writePngChunk(&png, allocator, "IEND", "");

    return png.toOwnedSlice(allocator);
}

pub fn getImageResponse(
    allocator: std.mem.Allocator,
    pane: *Pane,
    image_key: []const u8,
) ?ImageResponse {
    const key = parseImageKey(image_key) orelse return null;
    if (key.pane_id != pane.id) return null;

    const storage = &pane.terminal.screens.active.kitty_images;
    const image = storage.images.getPtr(key.image_id) orelse return null;
    if (image.data.len != key.data_len) return null;

    const format = imageFormat(image.format);
    if (format != .png) {
        const png = pngFromRaw(allocator, image.data, format, image.width, image.height) catch |err| {
            log.warn("failed to encode raw image as PNG: {}", .{err});
            return .{
                .data = image.data,
                .mime_type = "",
                .format = imageFormatString(format),
                .width = image.width,
                .height = image.height,
            };
        };
        return .{
            .data = png,
            .mime_type = "image/png",
            .format = imageFormatString(format),
            .width = image.width,
            .height = image.height,
            .owned = true,
        };
    }

    return .{
        .data = image.data,
        .mime_type = "image/png",
        .format = "png",
        .width = image.width,
        .height = image.height,
    };
}

pub fn putManifest(
    allocator: std.mem.Allocator,
    payload: *msgpack.Payload,
    pane: *Pane,
) !void {
    var list: std.ArrayListUnmanaged(ManifestEntry) = .{};
    defer list.deinit(allocator);

    const storage = &pane.terminal.screens.active.kitty_images;
    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        const placement = entry.value_ptr;
        const image = storage.images.getPtr(entry.key_ptr.image_id) orelse continue;
        const point = pointFromPlacement(pane, placement.*, image) orelse continue;
        if (!point.visible) continue;

        const pixel_size = placement.pixelSize(image.*, &pane.terminal);
        const grid_size = placement.gridSize(image.*, &pane.terminal);
        const sx = @min(placement.source_x, image.width);
        const sy = @min(placement.source_y, image.height);

        const image_key = try allocImageKey(
            allocator,
            pane.id,
            entry.key_ptr.image_id,
            image.data.len,
        );
        errdefer allocator.free(image_key);

        const url = try std.fmt.allocPrint(
            allocator,
            "/api/images/{d}/{s}",
            .{ pane.id, image_key },
        );
        errdefer allocator.free(url);

        try list.append(allocator, .{
            .image_key = image_key,
            .url = url,
            .pane_id = pane.id,
            .image_id = entry.key_ptr.image_id,
            .placement_id = entry.key_ptr.placement_id.id,
            .viewport_col = point.col,
            .viewport_row = point.row,
            .grid_cols = grid_size.cols,
            .grid_rows = grid_size.rows,
            .image_width = image.width,
            .image_height = image.height,
            .pixel_width = pixel_size.width,
            .pixel_height = pixel_size.height,
            .source_x = sx,
            .source_y = sy,
            .source_width = @min(if (placement.source_width > 0) placement.source_width else image.width, image.width - sx),
            .source_height = @min(if (placement.source_height > 0) placement.source_height else image.height, image.height - sy),
            .x_offset = placement.x_offset,
            .y_offset = placement.y_offset,
            .z = placement.z,
            .format = imageFormatString(imageFormat(image.format)),
            .generation = pane.generation,
        });
    }

    defer for (list.items) |entry| {
        allocator.free(entry.image_key);
        allocator.free(entry.url);
    };

    var arr = try msgpack.Payload.arrPayload(list.items.len, allocator);
    errdefer arr.free(allocator);
    for (list.items, 0..) |entry, idx| {
        var item = msgpack.Payload.mapPayload(allocator);
        errdefer item.free(allocator);
        try item.mapPut("imageKey", try msgpack.Payload.strToPayload(entry.image_key, allocator));
        try item.mapPut("url", try msgpack.Payload.strToPayload(entry.url, allocator));
        try item.mapPut("paneId", .{ .uint = entry.pane_id });
        try item.mapPut("imageId", .{ .uint = entry.image_id });
        try item.mapPut("placementId", .{ .uint = entry.placement_id });
        try item.mapPut("viewportCol", .{ .int = entry.viewport_col });
        try item.mapPut("viewportRow", .{ .int = entry.viewport_row });
        try item.mapPut("gridCols", .{ .uint = entry.grid_cols });
        try item.mapPut("gridRows", .{ .uint = entry.grid_rows });
        try item.mapPut("imageWidth", .{ .uint = entry.image_width });
        try item.mapPut("imageHeight", .{ .uint = entry.image_height });
        try item.mapPut("pixelWidth", .{ .uint = entry.pixel_width });
        try item.mapPut("pixelHeight", .{ .uint = entry.pixel_height });
        try item.mapPut("sourceX", .{ .uint = entry.source_x });
        try item.mapPut("sourceY", .{ .uint = entry.source_y });
        try item.mapPut("sourceWidth", .{ .uint = entry.source_width });
        try item.mapPut("sourceHeight", .{ .uint = entry.source_height });
        try item.mapPut("xOffset", .{ .uint = entry.x_offset });
        try item.mapPut("yOffset", .{ .uint = entry.y_offset });
        try item.mapPut("z", .{ .int = entry.z });
        try item.mapPut("format", try msgpack.Payload.strToPayload(entry.format, allocator));
        try item.mapPut("generation", .{ .uint = entry.generation });
        try arr.setArrElement(idx, item);
    }
    try payload.mapPut("images", arr);
}

pub const ManifestEntry = struct {
    image_key: []const u8,
    url: []const u8,
    pane_id: u16,
    image_id: u32,
    placement_id: u32,
    viewport_col: i32,
    viewport_row: i32,
    grid_cols: u32,
    grid_rows: u32,
    image_width: u32,
    image_height: u32,
    pixel_width: u32,
    pixel_height: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    x_offset: u32,
    y_offset: u32,
    z: i32,
    format: []const u8,
    generation: u64,
};

test "parse image key" {
    const key = parseImageKey("7-42-1024").?;
    try std.testing.expectEqual(@as(u16, 7), key.pane_id);
    try std.testing.expectEqual(@as(u32, 42), key.image_id);
    try std.testing.expectEqual(@as(usize, 1024), key.data_len);
    try std.testing.expect(parseImageKey("bad") == null);
}

test "kitty rgb transmit and display produces manifest entry" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 9, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("\x1b_Ga=T,t=d,f=24,s=1,v=1,i=1,p=1,c=3,r=2,q=1;");
    try pane.feed("/wAA");
    try pane.feed("\x1b\\");

    const storage = &pane.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());

    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);
    try putManifest(allocator, &payload, &pane);
}

test "kitty png transmit and display produces manifest entry" {
    png_decoder.install();

    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 10, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("\x1b_Ga=T,t=d,f=100,i=1,p=1,c=3,r=2,q=1;");
    try pane.feed("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==");
    try pane.feed("\x1b\\");

    const storage = &pane.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    const image = storage.images.getPtr(1).?;
    try std.testing.expectEqualStrings("rgba", imageFormatString(imageFormat(image.format)));

    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);
    try putManifest(allocator, &payload, &pane);

    const key = try allocImageKey(allocator, pane.id, 1, image.data.len);
    defer allocator.free(key);
    const response = getImageResponse(allocator, &pane, key).?;
    defer if (response.owned) allocator.free(response.data);
    try std.testing.expectEqualStrings("image/png", response.mime_type);
    const decoded = try png_decoder.decodePng(allocator, response.data);
    defer allocator.free(decoded.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, decoded.data);
}

test "kitty rgba transmit and display produces manifest entry" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 11, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("\x1b_Ga=T,t=d,f=32,s=1,v=1,i=1,p=1,c=3,r=2,q=1;");
    try pane.feed("/wAAgA==");
    try pane.feed("\x1b\\");

    const storage = &pane.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
}

test "raw RGB image response is served as PNG" {
    const data = [_]u8{ 255, 0, 0 };
    const png = try pngFromRaw(std.testing.allocator, &data, .rgb, 1, 1);
    defer std.testing.allocator.free(png);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);
    const decoded = try png_decoder.decodePng(std.testing.allocator, png);
    defer std.testing.allocator.free(decoded.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, decoded.data);
}

test "raw RGBA image response preserves alpha in PNG" {
    const data = [_]u8{ 255, 0, 0, 128 };
    const png = try pngFromRaw(std.testing.allocator, &data, .rgba, 1, 1);
    defer std.testing.allocator.free(png);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);
    const decoded = try png_decoder.decodePng(std.testing.allocator, png);
    defer std.testing.allocator.free(decoded.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, decoded.data);
}

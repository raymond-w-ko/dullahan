//! Terminal image manifest and HTTP helpers.

const std = @import("std");
const msgpack = @import("msgpack");
const Pane = @import("pane.zig").Pane;
const iterm2_images = @import("iterm2_images.zig");
const png_decoder = @import("png_decoder.zig");
const png_encoder = @import("png_encoder.zig");

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

fn imageFormatFromString(raw: []const u8) ?ImageFormat {
    inline for (@typeInfo(ImageFormat).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn rawPngFormat(format: ImageFormat) ?png_encoder.RawFormat {
    return switch (format) {
        .rgb => .rgb,
        .rgba => .rgba,
        else => null,
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

const ImageKey = struct {
    pane_id: u16,
    image_id: u32,
    format: ImageFormat,
    width: u32,
    height: u32,
    content_hash: u64,
};

fn imageContentHash(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

fn writeImageKey(
    writer: anytype,
    pane_id: u16,
    image_id: u32,
    format: ImageFormat,
    width: u32,
    height: u32,
    data: []const u8,
) !void {
    try writer.print(
        "{d}-{d}-{s}-{d}x{d}-{x}",
        .{ pane_id, image_id, imageFormatString(format), width, height, imageContentHash(data) },
    );
}

pub fn allocImageKey(
    allocator: std.mem.Allocator,
    pane_id: u16,
    image_id: u32,
    raw_format: anytype,
    width: u32,
    height: u32,
    data: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    try writeImageKey(out.writer(allocator), pane_id, image_id, imageFormat(raw_format), width, height, data);
    return out.toOwnedSlice(allocator);
}

fn parseImageKey(raw: []const u8) ?ImageKey {
    var it = std.mem.splitScalar(u8, raw, '-');
    const pane_str = it.next() orelse return null;
    const image_str = it.next() orelse return null;
    const format_str = it.next() orelse return null;
    const dimensions_str = it.next() orelse return null;
    const hash_str = it.next() orelse return null;
    if (it.next() != null) return null;

    var dimensions = std.mem.splitScalar(u8, dimensions_str, 'x');
    const width_str = dimensions.next() orelse return null;
    const height_str = dimensions.next() orelse return null;
    if (dimensions.next() != null) return null;

    return .{
        .pane_id = std.fmt.parseInt(u16, pane_str, 10) catch return null,
        .image_id = std.fmt.parseInt(u32, image_str, 10) catch return null,
        .format = imageFormatFromString(format_str) orelse return null,
        .width = std.fmt.parseInt(u32, width_str, 10) catch return null,
        .height = std.fmt.parseInt(u32, height_str, 10) catch return null,
        .content_hash = std.fmt.parseInt(u64, hash_str, 16) catch return null,
    };
}

fn keyMatches(
    key: ImageKey,
    pane_id: u16,
    image_id: u32,
    format: ImageFormat,
    width: u32,
    height: u32,
    data: []const u8,
) bool {
    return key.pane_id == pane_id and
        key.image_id == image_id and
        key.format == format and
        key.width == width and
        key.height == height and
        key.content_hash == imageContentHash(data);
}

pub fn getImageResponse(
    allocator: std.mem.Allocator,
    pane: *Pane,
    image_key: []const u8,
) ?ImageResponse {
    if (pane.iterm2_image_store.getImageResponse(pane.id, image_key)) |response| {
        return .{
            .data = response.data,
            .mime_type = response.mime_type,
            .format = response.format,
            .width = response.width,
            .height = response.height,
        };
    }

    const key = parseImageKey(image_key) orelse return null;
    if (key.pane_id != pane.id) return null;

    const screen_keys = [_]@TypeOf(pane.terminal.screens.active_key){
        pane.terminal.screens.active_key,
        .primary,
        .alternate,
    };
    for (screen_keys, 0..) |screen_key, idx| {
        if (idx > 0 and screen_key == pane.terminal.screens.active_key) continue;
        const screen = pane.terminal.screens.get(screen_key) orelse continue;
        if (getKittyImageResponse(allocator, pane, key, &screen.kitty_images)) |response| {
            return response;
        }
    }

    return null;
}

fn getKittyImageResponse(
    allocator: std.mem.Allocator,
    pane: *Pane,
    key: ImageKey,
    storage: anytype,
) ?ImageResponse {
    const image = storage.images.getPtr(key.image_id) orelse return null;
    const format = imageFormat(image.format);
    if (!keyMatches(key, pane.id, key.image_id, format, image.width, image.height, image.data)) return null;

    if (format != .png) {
        const raw_format = rawPngFormat(format) orelse return .{
            .data = image.data,
            .mime_type = "",
            .format = imageFormatString(format),
            .width = image.width,
            .height = image.height,
        };
        const png = png_encoder.encodeRgba(allocator, image.data, raw_format, image.width, image.height) catch |err| {
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
            image.format,
            image.width,
            image.height,
            image.data,
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
            .protocol = "kitty",
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

    try appendIterm2Manifest(allocator, &list, pane);

    defer for (list.items) |entry| {
        allocator.free(entry.image_key);
        allocator.free(entry.url);
    };
    sortManifestEntries(list.items);

    var arr = try msgpack.Payload.arrPayload(list.items.len, allocator);
    errdefer arr.free(allocator);
    for (list.items, 0..) |entry, idx| {
        var item = msgpack.Payload.mapPayload(allocator);
        errdefer item.free(allocator);
        try item.mapPut("imageKey", try msgpack.Payload.strToPayload(entry.image_key, allocator));
        try item.mapPut("url", try msgpack.Payload.strToPayload(entry.url, allocator));
        try item.mapPut("protocol", try msgpack.Payload.strToPayload(entry.protocol, allocator));
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
    protocol: []const u8,
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

fn appendIterm2Manifest(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ManifestEntry),
    pane: *Pane,
) !void {
    for (pane.iterm2_image_store.entries.items) |*entry| {
        const point = iterm2_images.pointFromAnchor(
            &pane.terminal,
            entry.anchor,
            entry.grid_rows,
            pane.rows,
        ) orelse continue;
        if (!point.visible) continue;

        const image_key = try iterm2_images.allocImageKey(allocator, pane.id, entry);
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
            .protocol = "iterm2",
            .pane_id = pane.id,
            .image_id = entry.id,
            .placement_id = entry.placement_id,
            .viewport_col = point.col,
            .viewport_row = point.row,
            .grid_cols = entry.grid_cols,
            .grid_rows = entry.grid_rows,
            .image_width = entry.natural_width,
            .image_height = entry.natural_height,
            .pixel_width = entry.pixel_width,
            .pixel_height = entry.pixel_height,
            .source_x = 0,
            .source_y = 0,
            .source_width = entry.natural_width,
            .source_height = entry.natural_height,
            .x_offset = 0,
            .y_offset = 0,
            .z = 0,
            .format = entry.mime.formatString(),
            .generation = entry.generation,
        });
    }
}

fn manifestLessThan(_: void, lhs: ManifestEntry, rhs: ManifestEntry) bool {
    if (lhs.z != rhs.z) return lhs.z < rhs.z;
    if (lhs.viewport_row != rhs.viewport_row) return lhs.viewport_row < rhs.viewport_row;
    if (lhs.viewport_col != rhs.viewport_col) return lhs.viewport_col < rhs.viewport_col;
    if (lhs.image_id != rhs.image_id) return lhs.image_id < rhs.image_id;
    return lhs.placement_id < rhs.placement_id;
}

fn sortManifestEntries(entries: []ManifestEntry) void {
    std.mem.sort(ManifestEntry, entries, {}, manifestLessThan);
}

test "parse image key" {
    const data = [_]u8{ 1, 2, 3, 4 };
    const raw_key = try allocImageKey(std.testing.allocator, 7, 42, ImageFormat.rgba, 1, 1, &data);
    defer std.testing.allocator.free(raw_key);
    const key = parseImageKey(raw_key).?;
    try std.testing.expectEqual(@as(u16, 7), key.pane_id);
    try std.testing.expectEqual(@as(u32, 42), key.image_id);
    try std.testing.expectEqual(ImageFormat.rgba, key.format);
    try std.testing.expectEqual(@as(u32, 1), key.width);
    try std.testing.expectEqual(@as(u32, 1), key.height);
    try std.testing.expectEqual(imageContentHash(&data), key.content_hash);
    try std.testing.expect(parseImageKey("bad") == null);
}

test "image key changes when content changes at same length" {
    const first = [_]u8{ 255, 0, 0, 255 };
    const second = [_]u8{ 0, 255, 0, 255 };
    const key1 = try allocImageKey(std.testing.allocator, 1, 2, ImageFormat.rgba, 1, 1, &first);
    defer std.testing.allocator.free(key1);
    const key2 = try allocImageKey(std.testing.allocator, 1, 2, ImageFormat.rgba, 1, 1, &second);
    defer std.testing.allocator.free(key2);
    try std.testing.expect(!std.mem.eql(u8, key1, key2));
}

fn testManifestEntry(key: []const u8, z: i32, col: i32, image_id: u32, placement_id: u32) ManifestEntry {
    return .{
        .image_key = key,
        .url = "",
        .protocol = "kitty",
        .pane_id = 1,
        .image_id = image_id,
        .placement_id = placement_id,
        .viewport_col = col,
        .viewport_row = 1,
        .grid_cols = 1,
        .grid_rows = 1,
        .image_width = 1,
        .image_height = 1,
        .pixel_width = 1,
        .pixel_height = 1,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .x_offset = 0,
        .y_offset = 0,
        .z = z,
        .format = "rgba",
        .generation = 1,
    };
}

test "manifest entries sort deterministically" {
    var entries = [_]ManifestEntry{
        testManifestEntry("c", 1, 4, 2, 2),
        testManifestEntry("a", 0, 0, 1, 1),
        testManifestEntry("b", 0, 2, 3, 3),
    };
    sortManifestEntries(&entries);
    try std.testing.expectEqualStrings("a", entries[0].image_key);
    try std.testing.expectEqualStrings("b", entries[1].image_key);
    try std.testing.expectEqualStrings("c", entries[2].image_key);
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

    const key = try allocImageKey(allocator, pane.id, 1, image.format, image.width, image.height, image.data);
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
    const image = storage.images.getPtr(1).?;

    const key = try allocImageKey(allocator, pane.id, 1, image.format, image.width, image.height, image.data);
    defer allocator.free(key);
    const response = getImageResponse(allocator, &pane, key).?;
    defer if (response.owned) allocator.free(response.data);
    try std.testing.expectEqualStrings("image/png", response.mime_type);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", response.data[0..8]);
    const decoded = try png_decoder.decodePng(allocator, response.data);
    defer allocator.free(decoded.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, decoded.data);
}

test "kitty image response survives active screen switch" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 18, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("\x1b_Ga=T,t=d,f=24,s=1,v=1,i=1,p=1,c=3,r=2,q=1;");
    try pane.feed("/wAA");
    try pane.feed("\x1b\\");

    const storage = &pane.terminal.screens.active.kitty_images;
    const image = storage.images.getPtr(1).?;
    const key = try allocImageKey(allocator, pane.id, 1, image.format, image.width, image.height, image.data);
    defer allocator.free(key);

    try pane.feed("\x1b[?1049h");
    try std.testing.expectEqual(.alternate, pane.terminal.screens.active_key);

    const response = getImageResponse(allocator, &pane, key).?;
    defer if (response.owned) allocator.free(response.data);
    try std.testing.expectEqualStrings("image/png", response.mime_type);
}

const test_iterm2_png_b64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";

fn feedTestIterm2Image(pane: *Pane) !void {
    try pane.feed("\x1b]1337;File=inline=1;width=2;height=1;preserveAspectRatio=0:");
    try pane.feed(test_iterm2_png_b64);
    try pane.feed("\x1b\\");
}

test "iterm2 single file ST anchors after preceding text and serves png" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 12, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("A\x1b]1337;File=inline=1;width=2;height=1;preserveAspectRatio=0:");
    try pane.feed(test_iterm2_png_b64);
    try pane.feed("\x1b\\B");

    try std.testing.expectEqual(@as(usize, 1), pane.iterm2_image_store.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), pane.terminal.screens.active.cursor.y);
    try std.testing.expectEqual(@as(usize, 2), pane.terminal.screens.active.cursor.x);

    const entry = &pane.iterm2_image_store.entries.items[0];
    try std.testing.expectEqual(@as(u32, 2), entry.grid_cols);
    try std.testing.expectEqual(@as(u32, 1), entry.grid_rows);
    const point = iterm2_images.pointFromAnchor(&pane.terminal, entry.anchor, entry.grid_rows, pane.rows).?;
    try std.testing.expectEqual(@as(i32, 1), point.col);
    try std.testing.expectEqual(@as(i32, 0), point.row);

    const key = try iterm2_images.allocImageKey(allocator, pane.id, entry);
    defer allocator.free(key);
    const response = getImageResponse(allocator, &pane, key).?;
    try std.testing.expectEqualStrings("image/png", response.mime_type);
    try std.testing.expectEqualStrings("png", response.format);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", response.data[0..8]);
}

test "iterm2 multipart image creates one placement" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 13, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("\x1b]1337;MultipartFile=inline=1;width=3;height=2;preserveAspectRatio=0\x07");
    try pane.feed("\x1b]1337;FilePart=");
    try pane.feed(test_iterm2_png_b64);
    try pane.feed("\x07");
    try pane.feed("\x1b]1337;FileEnd\x07");

    try std.testing.expectEqual(@as(usize, 1), pane.iterm2_image_store.entries.items.len);
    const entry = pane.iterm2_image_store.entries.items[0];
    try std.testing.expectEqual(@as(u32, 3), entry.grid_cols);
    try std.testing.expectEqual(@as(u32, 2), entry.grid_rows);
}

test "iterm2 invalid image payloads are ignored" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 14, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("\x1b]1337;File=inline=1;width=2;height=1:not-base64\x07");
    try std.testing.expectEqual(@as(usize, 0), pane.iterm2_image_store.entries.items.len);

    try pane.feed("\x1b]1337;File=inline=1;size=1;width=2;height=1:");
    try pane.feed(test_iterm2_png_b64);
    try pane.feed("\x07");
    try std.testing.expectEqual(@as(usize, 0), pane.iterm2_image_store.entries.items.len);
}

test "iterm2 images are cleared by erase display complete" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 15, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try feedTestIterm2Image(&pane);
    try std.testing.expectEqual(@as(usize, 1), pane.iterm2_image_store.entries.items.len);

    try pane.feed("\x1b[H\x1b[2J");
    try std.testing.expectEqual(@as(usize, 0), pane.iterm2_image_store.entries.items.len);
}

test "iterm2 images are cleared by common clear sequence" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 16, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try feedTestIterm2Image(&pane);
    try std.testing.expectEqual(@as(usize, 1), pane.iterm2_image_store.entries.items.len);

    try pane.feed("\x1b[H\x1b[2J\x1b[3J");
    try std.testing.expectEqual(@as(usize, 0), pane.iterm2_image_store.entries.items.len);
}

test "iterm2 images are cleared by full reset" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 17, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try feedTestIterm2Image(&pane);
    try std.testing.expectEqual(@as(usize, 1), pane.iterm2_image_store.entries.items.len);

    try pane.feed("\x1bc");
    try std.testing.expectEqual(@as(usize, 0), pane.iterm2_image_store.entries.items.len);
}

test "iterm2 pending multipart is aborted by erase display complete" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 19, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("\x1b]1337;MultipartFile=inline=1;width=3;height=2;preserveAspectRatio=0\x07");
    try pane.feed("\x1b]1337;FilePart=");
    try pane.feed(test_iterm2_png_b64);
    try pane.feed("\x07");
    try pane.feed("\x1b[H\x1b[2J");
    try pane.feed("\x1b]1337;FileEnd\x07");

    try std.testing.expectEqual(@as(usize, 0), pane.iterm2_image_store.entries.items.len);
}

test "iterm2 pending multipart is aborted by full reset" {
    const allocator = std.testing.allocator;
    var pane = try Pane.init(allocator, .{ .id = 20, .cols = 80, .rows = 24 });
    defer pane.deinit();

    try pane.feed("\x1b]1337;MultipartFile=inline=1;width=3;height=2;preserveAspectRatio=0\x07");
    try pane.feed("\x1b]1337;FilePart=");
    try pane.feed(test_iterm2_png_b64);
    try pane.feed("\x07");
    try pane.feed("\x1bc");
    try pane.feed("\x1b]1337;FileEnd\x07");

    try std.testing.expectEqual(@as(usize, 0), pane.iterm2_image_store.entries.items.len);
}

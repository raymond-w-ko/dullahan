//! Minimal uncompressed RGBA PNG encoder for browser image responses.

const std = @import("std");
const png_decoder = @import("png_decoder.zig");

pub const RawFormat = enum {
    rgb,
    rgba,

    fn bytesPerPixel(self: RawFormat) usize {
        return switch (self) {
            .rgb => 3,
            .rgba => 4,
        };
    }
};

fn writeChunk(
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

    var crc = std.hash.crc.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(allocator, &crc_buf);
}

fn appendStoredZlib(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    try out.appendSlice(allocator, &.{ 0x78, 0x01 });

    var remaining = data;
    while (remaining.len > 0) {
        const block_len = @min(remaining.len, 65535);
        const final: u8 = if (block_len == remaining.len) 1 else 0;
        try out.append(allocator, final);

        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(block_len), .little);
        try out.appendSlice(allocator, &len_buf);
        std.mem.writeInt(u16, &len_buf, ~@as(u16, @intCast(block_len)), .little);
        try out.appendSlice(allocator, &len_buf);

        try out.appendSlice(allocator, remaining[0..block_len]);
        remaining = remaining[block_len..];
    }

    var adler_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_buf, std.hash.Adler32.hash(data), .big);
    try out.appendSlice(allocator, &adler_buf);
}

fn rgbaScanlines(
    allocator: std.mem.Allocator,
    data: []const u8,
    format: RawFormat,
    width: u32,
    height: u32,
) ![]u8 {
    const bpp = format.bytesPerPixel();
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidData;
    if (data.len != pixel_count * bpp) return error.InvalidData;

    const row_len = 1 + @as(usize, width) * 4;
    const filtered = try allocator.alloc(u8, row_len * @as(usize, height));
    errdefer allocator.free(filtered);

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

    return filtered;
}

pub fn encodeRgba(
    allocator: std.mem.Allocator,
    data: []const u8,
    format: RawFormat,
    width: u32,
    height: u32,
) ![]u8 {
    const filtered = try rgbaScanlines(allocator, data, format, width, height);
    defer allocator.free(filtered);

    var zlib: std.ArrayListUnmanaged(u8) = .{};
    defer zlib.deinit(allocator);
    try appendStoredZlib(&zlib, allocator, filtered);

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

    try writeChunk(&png, allocator, "IHDR", &ihdr);
    try writeChunk(&png, allocator, "IDAT", zlib.items);
    try writeChunk(&png, allocator, "IEND", "");

    return png.toOwnedSlice(allocator);
}

fn expectRoundTrip(data: []const u8, format: RawFormat, expected: []const u8, width: u32, height: u32) !void {
    const png = try encodeRgba(std.testing.allocator, data, format, width, height);
    defer std.testing.allocator.free(png);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);

    const decoded = try png_decoder.decodePng(std.testing.allocator, png);
    defer std.testing.allocator.free(decoded.data);
    try std.testing.expectEqual(width, decoded.width);
    try std.testing.expectEqual(height, decoded.height);
    try std.testing.expectEqualSlices(u8, expected, decoded.data);
}

test "encodes RGB as opaque RGBA PNG" {
    const data = [_]u8{ 255, 0, 0 };
    try expectRoundTrip(&data, .rgb, &.{ 255, 0, 0, 255 }, 1, 1);
}

test "encodes RGBA and preserves alpha" {
    const data = [_]u8{ 255, 0, 0, 128 };
    try expectRoundTrip(&data, .rgba, &.{ 255, 0, 0, 128 }, 1, 1);
}

test "encodes multiple rows" {
    const data = [_]u8{
        255, 0, 0,
        0, 255, 0,
        0, 0, 255,
        255, 255, 255,
    };
    try expectRoundTrip(&data, .rgb, &.{
        255, 0, 0, 255,
        0, 255, 0, 255,
        0, 0, 255, 255,
        255, 255, 255, 255,
    }, 2, 2);
}

test "splits zlib stored blocks beyond 64k" {
    const width = 300;
    const height = 80;
    const data = try std.testing.allocator.alloc(u8, width * height * 4);
    defer std.testing.allocator.free(data);
    @memset(data, 127);

    const png = try encodeRgba(std.testing.allocator, data, .rgba, width, height);
    defer std.testing.allocator.free(png);

    const decoded = try png_decoder.decodePng(std.testing.allocator, png);
    defer std.testing.allocator.free(decoded.data);
    try std.testing.expectEqual(@as(u32, width), decoded.width);
    try std.testing.expectEqual(@as(u32, height), decoded.height);
    try std.testing.expectEqual(@as(usize, width * height * 4), decoded.data.len);
}

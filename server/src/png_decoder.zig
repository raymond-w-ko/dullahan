const std = @import("std");
const ghostty = @import("ghostty-vt");

const constants = @import("constants.zig");

const log = std.log.scoped(.png_decoder);

const c = @cImport({
    for (wuffs_defines) |d| @cDefine(d, "1");
    @cInclude("wuffs-v0.4.c");
});

const wuffs_defines = [_][]const u8{
    "WUFFS_CONFIG__MODULES",
    "WUFFS_CONFIG__MODULE__AUX__BASE",
    "WUFFS_CONFIG__MODULE__AUX__IMAGE",
    "WUFFS_CONFIG__MODULE__BASE",
    "WUFFS_CONFIG__MODULE__ADLER32",
    "WUFFS_CONFIG__MODULE__CRC32",
    "WUFFS_CONFIG__MODULE__DEFLATE",
    "WUFFS_CONFIG__MODULE__PNG",
    "WUFFS_CONFIG__MODULE__ZLIB",
};

pub fn install() void {
    ghostty.sys.decode_png = decodePng;
}

pub const Dimensions = struct {
    width: u32,
    height: u32,
    rgba_bytes: usize,
};

fn check(status: *const c.struct_wuffs_base__status__struct) error{InvalidData}!void {
    if (!c.wuffs_base__status__is_ok(status)) {
        const msg = c.wuffs_base__status__message(status);
        log.warn("png decode failed: {s}", .{msg});
        return error.InvalidData;
    }
}

const Decoder = struct {
    buffer: []align(16) u8,
    ptr: *c.wuffs_png__decoder,

    fn deinit(self: Decoder, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

fn initDecoder(allocator: std.mem.Allocator) ghostty.sys.DecodeError!Decoder {
    const decoder_buf = try allocator.alignedAlloc(u8, .@"16", c.sizeof__wuffs_png__decoder());
    errdefer allocator.free(decoder_buf);
    const decoder: *c.wuffs_png__decoder = @ptrCast(decoder_buf.ptr);

    const status = c.wuffs_png__decoder__initialize(
        decoder,
        c.sizeof__wuffs_png__decoder(),
        c.WUFFS_VERSION,
        0,
    );
    try check(&status);
    return .{
        .buffer = decoder_buf,
        .ptr = decoder,
    };
}

fn decodeImageConfig(
    decoder: *c.wuffs_png__decoder,
    data: []const u8,
) ghostty.sys.DecodeError!struct {
    image_config: c.wuffs_base__image_config,
    source_buffer: c.wuffs_base__io_buffer,
} {
    var source_buffer: c.wuffs_base__io_buffer = .{
        .data = .{ .ptr = @ptrCast(@constCast(data.ptr)), .len = data.len },
        .meta = .{
            .wi = data.len,
            .ri = 0,
            .pos = 0,
            .closed = true,
        },
    };

    var image_config: c.wuffs_base__image_config = undefined;
    {
        const status = c.wuffs_png__decoder__decode_image_config(
            decoder,
            &image_config,
            &source_buffer,
        );
        try check(&status);
    }

    return .{
        .image_config = image_config,
        .source_buffer = source_buffer,
    };
}

fn validateDimensions(width: u32, height: u32) ghostty.sys.DecodeError!Dimensions {
    if (width == 0 or height == 0) return error.InvalidData;
    if (width > constants.images.max_decoded_dimension) return error.InvalidData;
    if (height > constants.images.max_decoded_dimension) return error.InvalidData;

    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidData;
    const rgba_bytes = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
    if (rgba_bytes > constants.images.max_decoded_rgba_bytes) return error.InvalidData;

    return .{
        .width = width,
        .height = height,
        .rgba_bytes = rgba_bytes,
    };
}

pub fn decodePngDimensions(
    allocator: std.mem.Allocator,
    data: []const u8,
) ghostty.sys.DecodeError!Dimensions {
    const decoder = try initDecoder(allocator);
    defer decoder.deinit(allocator);

    const config = try decodeImageConfig(decoder.ptr, data);
    return validateDimensions(
        c.wuffs_base__pixel_config__width(&config.image_config.pixcfg),
        c.wuffs_base__pixel_config__height(&config.image_config.pixcfg),
    );
}

pub fn decodePng(
    allocator: std.mem.Allocator,
    data: []const u8,
) ghostty.sys.DecodeError!ghostty.sys.Image {
    const decoder = try initDecoder(allocator);
    defer decoder.deinit(allocator);

    const config = try decodeImageConfig(decoder.ptr, data);
    var image_config = config.image_config;
    var source_buffer = config.source_buffer;

    const width = c.wuffs_base__pixel_config__width(&image_config.pixcfg);
    const height = c.wuffs_base__pixel_config__height(&image_config.pixcfg);
    const dimensions = try validateDimensions(width, height);

    c.wuffs_base__pixel_config__set(
        &image_config.pixcfg,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
        c.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
        width,
        height,
    );

    const destination = try allocator.alloc(u8, dimensions.rgba_bytes);
    errdefer allocator.free(destination);

    const work_len = std.math.cast(
        usize,
        c.wuffs_png__decoder__workbuf_len(decoder.ptr).max_incl,
    ) orelse return error.OutOfMemory;
    const work_buffer = try allocator.alloc(u8, work_len);
    defer allocator.free(work_buffer);

    const work_slice = c.wuffs_base__make_slice_u8(work_buffer.ptr, work_buffer.len);

    var pixel_buffer: c.wuffs_base__pixel_buffer = undefined;
    {
        const status = c.wuffs_base__pixel_buffer__set_from_slice(
            &pixel_buffer,
            &image_config.pixcfg,
            c.wuffs_base__make_slice_u8(destination.ptr, destination.len),
        );
        try check(&status);
    }

    {
        const status = c.wuffs_png__decoder__decode_frame(
            decoder.ptr,
            &pixel_buffer,
            &source_buffer,
            c.WUFFS_BASE__PIXEL_BLEND__SRC,
            work_slice,
            null,
        );
        try check(&status);
    }

    return .{
        .width = width,
        .height = height,
        .data = destination,
    };
}

test "decode opaque png" {
    const png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
    const image = try decodePng(std.testing.allocator, png);
    defer std.testing.allocator.free(image.data);

    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.data);
}

test "install registers ghostty png decoder hook" {
    install();
    try std.testing.expect(ghostty.sys.decode_png != null);
}

test "decode alpha png" {
    const png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\xd0\x00\x00\x04\x81\x01\x80\x2c\x55\xce\xb0\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
    const image = try decodePng(std.testing.allocator, png);
    defer std.testing.allocator.free(image.data);

    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, image.data);
}

fn appendTestPngChunk(
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

fn appendTestStoredZlib(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
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

fn allocTestPngHeader(allocator: std.mem.Allocator, width: u32, height: u32) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;

    try appendTestPngChunk(&out, allocator, "IHDR", &ihdr);

    const raw_len = try std.math.add(usize, 1, try std.math.mul(usize, @as(usize, width), 4));
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    @memset(raw, 0);

    var idat: std.ArrayListUnmanaged(u8) = .{};
    defer idat.deinit(allocator);
    try appendTestStoredZlib(&idat, allocator, raw);
    try appendTestPngChunk(&out, allocator, "IDAT", idat.items);

    try appendTestPngChunk(&out, allocator, "IEND", "");
    return out.toOwnedSlice(allocator);
}

test "rejects oversized png dimensions before pixel allocation" {
    const png = try allocTestPngHeader(
        std.testing.allocator,
        constants.images.max_decoded_dimension + 1,
        1,
    );
    defer std.testing.allocator.free(png);

    try std.testing.expectError(error.InvalidData, decodePngDimensions(std.testing.allocator, png));
    try std.testing.expectError(error.InvalidData, decodePng(std.testing.allocator, png));
}

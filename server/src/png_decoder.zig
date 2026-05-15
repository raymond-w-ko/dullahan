const std = @import("std");
const ghostty = @import("ghostty-vt");

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

fn check(status: *const c.struct_wuffs_base__status__struct) error{InvalidData}!void {
    if (!c.wuffs_base__status__is_ok(status)) {
        const msg = c.wuffs_base__status__message(status);
        log.warn("png decode failed: {s}", .{msg});
        return error.InvalidData;
    }
}

pub fn decodePng(
    allocator: std.mem.Allocator,
    data: []const u8,
) ghostty.sys.DecodeError!ghostty.sys.Image {
    const decoder_buf = try allocator.alloc(u8, c.sizeof__wuffs_png__decoder());
    defer allocator.free(decoder_buf);

    const decoder: ?*c.wuffs_png__decoder = @ptrCast(decoder_buf);
    {
        const status = c.wuffs_png__decoder__initialize(
            decoder,
            c.sizeof__wuffs_png__decoder(),
            c.WUFFS_VERSION,
            0,
        );
        try check(&status);
    }

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

    const width = c.wuffs_base__pixel_config__width(&image_config.pixcfg);
    const height = c.wuffs_base__pixel_config__height(&image_config.pixcfg);

    c.wuffs_base__pixel_config__set(
        &image_config.pixcfg,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
        c.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
        width,
        height,
    );

    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidData;
    const size = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
    const destination = try allocator.alloc(u8, size);
    errdefer allocator.free(destination);

    const work_len = std.math.cast(
        usize,
        c.wuffs_png__decoder__workbuf_len(decoder).max_incl,
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
            decoder,
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

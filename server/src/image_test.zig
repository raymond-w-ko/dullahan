//! Kitty graphics visual test stream generator.

const std = @import("std");
const posix = std.posix;

fn firstArg(args: ?[]const u8) []const u8 {
    const raw = args orelse return "/tmp/dullahan-image-test.png";
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    return it.next() orelse "/tmp/dullahan-image-test.png";
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = try posix.write(fd, bytes[offset..]);
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
}

const KittyImageFormat = enum {
    rgb,
    rgba,
    png,

    fn code(self: KittyImageFormat) u16 {
        return switch (self) {
            .rgb => 24,
            .rgba => 32,
            .png => 100,
        };
    }
};

const KittyImageSpec = struct {
    format: KittyImageFormat,
    width: usize = 0,
    height: usize = 0,
    image_id: u32,
    placement_id: u32,
    cols: u32,
    rows: u32,
    z: i32 = 0,
};

fn kittyImageChunkHeader(buf: []u8, first: bool, more: bool, spec: KittyImageSpec) ![]const u8 {
    if (!first) {
        return std.fmt.bufPrint(buf, "\x1b_Ga=t,q=1{s};", .{if (more) ",m=1" else ""});
    }

    if (spec.format == .png) {
        return std.fmt.bufPrint(
            buf,
            "\x1b_Ga=T,t=d,f={d},i={d},p={d},c={d},r={d},z={d},q=1{s};",
            .{ spec.format.code(), spec.image_id, spec.placement_id, spec.cols, spec.rows, spec.z, if (more) ",m=1" else "" },
        );
    }

    return std.fmt.bufPrint(
        buf,
        "\x1b_Ga=T,t=d,f={d},s={d},v={d},i={d},p={d},c={d},r={d},z={d},q=1{s};",
        .{ spec.format.code(), spec.width, spec.height, spec.image_id, spec.placement_id, spec.cols, spec.rows, spec.z, if (more) ",m=1" else "" },
    );
}

fn writeKittyImageChunks(fd: posix.fd_t, encoded: []const u8, spec: KittyImageSpec) !void {
    const chunk_size = 4096;
    var offset: usize = 0;

    while (offset < encoded.len) {
        const end = @min(offset + chunk_size, encoded.len);
        const more = end < encoded.len;

        var header_buf: [192]u8 = undefined;
        const header = try kittyImageChunkHeader(&header_buf, offset == 0, more, spec);

        try writeAllFd(fd, header);
        try writeAllFd(fd, encoded[offset..end]);
        try writeAllFd(fd, "\x1b\\");

        offset = end;
    }
}

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return encoded;
}

fn writeEncodedImage(fd: posix.fd_t, encoded: []const u8, spec: KittyImageSpec) !void {
    try writeKittyImageChunks(fd, encoded, spec);
}

fn writeRawImage(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    data: []const u8,
    spec: KittyImageSpec,
) !void {
    const encoded = try encodeBase64(allocator, data);
    defer allocator.free(encoded);
    try writeEncodedImage(fd, encoded, spec);
}

fn writeBlankLines(fd: posix.fd_t, count: usize) !void {
    for (0..count) |_| try writeAllFd(fd, "\n");
}

fn writeCursorRows(fd: posix.fd_t, rows: u32, comptime direction: u8) !void {
    var buf: [32]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&buf, "\x1b[{d}{c}", .{ rows, direction });
    try writeAllFd(fd, bytes);
}

fn fillRgbTestPattern(data: []u8, width: usize, height: usize, seed_data: []const u8) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const i = (y * width + x) * 3;
            const seed = seed_data[(x + y * width) % seed_data.len];
            data[i] = @intCast((x * 255) / (width - 1));
            data[i + 1] = @intCast((y * 255) / (height - 1));
            data[i + 2] = seed;
        }
    }
}

fn fillRgbaTestPattern(data: []u8, width: usize, height: usize, seed_data: []const u8) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const i = (y * width + x) * 4;
            const seed = seed_data[(x * 7 + y * 13) % seed_data.len];
            data[i] = seed;
            data[i + 1] = @intCast(255 - ((x * 255) / (width - 1)));
            data[i + 2] = @intCast((y * 255) / (height - 1));
            data[i + 3] = if (((x / 16) + (y / 16)) % 2 == 0) 96 else 192;
        }
    }
}

const ImageTestCase = struct {
    label: []const u8,
    spec: KittyImageSpec,
    source: union(enum) {
        rgb,
        rgba,
        png: []const u8,
    },
    blank_after: u32,
};

pub fn run(allocator: std.mem.Allocator, args: ?[]const u8) !void {
    const path = firstArg(args);
    const stdout_fd = posix.STDOUT_FILENO;

    const seed_data = std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024) catch |e| {
        std.debug.print("image-test: failed to read {s}: {}\n", .{ path, e });
        std.debug.print("Try: wget -O /tmp/dullahan-image-test.png https://upload.wikimedia.org/wikipedia/commons/3/3f/PNG_icon.png\n", .{});
        return e;
    };
    defer allocator.free(seed_data);

    const image_width = 240;
    const image_height = 96;
    const cols = 20;
    const rows = 8;

    const rgb_data = try allocator.alloc(u8, image_width * image_height * 3);
    defer allocator.free(rgb_data);
    fillRgbTestPattern(rgb_data, image_width, image_height, seed_data);

    const rgba_data = try allocator.alloc(u8, image_width * image_height * 4);
    defer allocator.free(rgba_data);
    fillRgbaTestPattern(rgba_data, image_width, image_height, seed_data);

    const opaque_png_b64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
    const alpha_png_b64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DQAAAEgQGALFXOsAAAAABJRU5ErkJggg==";

    const cases = [_]ImageTestCase{
        .{
            .label = "RGB raw f=24. Expected: opaque 20x8 cell gradient.\n",
            .spec = .{ .format = .rgb, .width = image_width, .height = image_height, .image_id = 1, .placement_id = 1, .cols = cols, .rows = rows },
            .source = .rgb,
            .blank_after = rows + 2,
        },
        .{
            .label = "RGBA raw f=32. Expected: checker transparency over terminal background.\n",
            .spec = .{ .format = .rgba, .width = image_width, .height = image_height, .image_id = 2, .placement_id = 2, .cols = cols, .rows = rows },
            .source = .rgba,
            .blank_after = rows + 2,
        },
        .{
            .label = "PNG opaque f=100. Expected: opaque red sample scaled to 20x8 cells.\n",
            .spec = .{ .format = .png, .image_id = 3, .placement_id = 3, .cols = cols, .rows = rows },
            .source = .{ .png = opaque_png_b64 },
            .blank_after = rows + 2,
        },
        .{
            .label = "PNG alpha f=100. Expected: translucent red sample blending with background.\n",
            .spec = .{ .format = .png, .image_id = 4, .placement_id = 4, .cols = cols, .rows = rows },
            .source = .{ .png = alpha_png_b64 },
            .blank_after = rows + 2,
        },
    };

    try writeAllFd(stdout_fd,
        \\Dullahan Kitty Image Test
        \\=========================
        \\
    );

    for (cases) |case| {
        try writeAllFd(stdout_fd, case.label);
        try writeAllFd(stdout_fd, "\n");
        switch (case.source) {
            .rgb => try writeRawImage(allocator, stdout_fd, rgb_data, case.spec),
            .rgba => try writeRawImage(allocator, stdout_fd, rgba_data, case.spec),
            .png => |encoded| try writeEncodedImage(stdout_fd, encoded, case.spec),
        }
        try writeBlankLines(stdout_fd, case.blank_after);
    }

    try writeAllFd(stdout_fd,
        \\Overlap. Expected: translucent PNG on top of raw RGB in same cell region.
        \\
    );
    try writeRawImage(allocator, stdout_fd, rgb_data, .{
        .format = .rgb,
        .width = image_width,
        .height = image_height,
        .image_id = 5,
        .placement_id = 5,
        .cols = cols,
        .rows = rows,
        .z = 0,
    });
    try writeAllFd(stdout_fd, "\r");
    try writeCursorRows(stdout_fd, rows - 1, 'A');
    try writeEncodedImage(stdout_fd, alpha_png_b64, .{
        .format = .png,
        .image_id = 6,
        .placement_id = 6,
        .cols = cols,
        .rows = rows,
        .z = 1,
    });
    try writeBlankLines(stdout_fd, rows + 2);

    try writeAllFd(stdout_fd,
        \\Text after images. Resize and scroll to verify cell-relative placement.
        \\
    );
}

test "kitty image chunk headers" {
    var buf: [160]u8 = undefined;
    const spec = KittyImageSpec{
        .format = .rgb,
        .width = 240,
        .height = 120,
        .image_id = 1,
        .placement_id = 1,
        .cols = 20,
        .rows = 10,
    };
    try std.testing.expectEqualStrings(
        "\x1b_Ga=T,t=d,f=24,s=240,v=120,i=1,p=1,c=20,r=10,z=0,q=1,m=1;",
        try kittyImageChunkHeader(&buf, true, true, spec),
    );
    try std.testing.expectEqualStrings(
        "\x1b_Ga=t,q=1,m=1;",
        try kittyImageChunkHeader(&buf, false, true, spec),
    );
    try std.testing.expectEqualStrings(
        "\x1b_Ga=t,q=1;",
        try kittyImageChunkHeader(&buf, false, false, spec),
    );
}

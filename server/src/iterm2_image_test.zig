//! iTerm2 OSC 1337 inline image visual test stream generator.

const std = @import("std");
const posix = std.posix;
const png_encoder = @import("png_encoder.zig");

const default_path = "/tmp/dullahan-image-test.png";
const max_seed_bytes = 64 * 1024;

const Terminator = enum {
    bel,
    st,

    fn bytes(self: Terminator) []const u8 {
        return switch (self) {
            .bel => "\x07",
            .st => "\x1b\\",
        };
    }
};

fn firstArg(args: ?[]const u8) []const u8 {
    const raw = args orelse return default_path;
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    return it.next() orelse default_path;
}

fn readSeed(allocator: std.mem.Allocator, args: ?[]const u8) ![]u8 {
    const path = firstArg(args);
    return std.fs.cwd().readFileAlloc(allocator, path, max_seed_bytes) catch
        try allocator.dupe(u8, "dullahan-iterm2-image-test");
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = try posix.write(fd, bytes[offset..]);
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
}

fn fillRgbaTestPattern(data: []u8, width: usize, height: usize, seed_data: []const u8) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const i = (y * width + x) * 4;
            const seed = seed_data[(x * 7 + y * 13) % seed_data.len];
            data[i] = seed;
            data[i + 1] = @intCast((x * 255) / (width - 1));
            data[i + 2] = @intCast((y * 255) / (height - 1));
            data[i + 3] = if (((x / 16) + (y / 16)) % 2 == 0) 255 else 180;
        }
    }
}

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return encoded;
}

fn writeBlankLines(fd: posix.fd_t, count: usize) !void {
    for (0..count) |_| try writeAllFd(fd, "\n");
}

fn writeSingleFile(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    encoded: []const u8,
    raw_len: usize,
    args: []const u8,
    terminator: Terminator,
) !void {
    const header = try std.fmt.allocPrint(
        allocator,
        "\x1b]1337;File=size={d};{s}:",
        .{ raw_len, args },
    );
    defer allocator.free(header);
    try writeAllFd(fd, header);
    try writeAllFd(fd, encoded);
    try writeAllFd(fd, terminator.bytes());
}

fn writeMultipartFile(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    encoded: []const u8,
    raw_len: usize,
    args: []const u8,
) !void {
    const start = try std.fmt.allocPrint(
        allocator,
        "\x1b]1337;MultipartFile=size={d};{s}\x07",
        .{ raw_len, args },
    );
    defer allocator.free(start);
    try writeAllFd(fd, start);

    const chunk_size = 4096;
    var offset: usize = 0;
    while (offset < encoded.len) {
        const end = @min(offset + chunk_size, encoded.len);
        try writeAllFd(fd, "\x1b]1337;FilePart=");
        try writeAllFd(fd, encoded[offset..end]);
        try writeAllFd(fd, "\x07");
        offset = end;
    }

    try writeAllFd(fd, "\x1b]1337;FileEnd\x07");
}

pub fn run(allocator: std.mem.Allocator, args: ?[]const u8) !void {
    const stdout_fd = posix.STDOUT_FILENO;

    const seed_data = try readSeed(allocator, args);
    defer allocator.free(seed_data);

    const image_width = 160;
    const image_height = 64;
    const rgba_data = try allocator.alloc(u8, image_width * image_height * 4);
    defer allocator.free(rgba_data);
    fillRgbaTestPattern(rgba_data, image_width, image_height, seed_data);

    const pattern_png = try png_encoder.encodeRgba(allocator, rgba_data, .rgba, image_width, image_height);
    defer allocator.free(pattern_png);
    const pattern_b64 = try encodeBase64(allocator, pattern_png);
    defer allocator.free(pattern_b64);

    const opaque_png_b64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
    const alpha_png_b64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DQAAAEgQGALFXOsAAAAABJRU5ErkJggg==";
    const opaque_len = try std.base64.standard.Decoder.calcSizeForSlice(opaque_png_b64);
    const alpha_len = try std.base64.standard.Decoder.calcSizeForSlice(alpha_png_b64);

    try writeAllFd(stdout_fd,
        \\Dullahan iTerm2 Image Test
        \\==========================
        \\
    );

    try writeAllFd(stdout_fd, "Single File ST. Expected: generated PNG stretched to 20x8 cells.\n\n");
    try writeSingleFile(
        allocator,
        stdout_fd,
        pattern_b64,
        pattern_png.len,
        "inline=1;width=20;height=8;preserveAspectRatio=0",
        .st,
    );
    try writeBlankLines(stdout_fd, 10);

    try writeAllFd(stdout_fd, "MultipartFile BEL. Expected: generated PNG via multipart, 20x8 cells.\n\n");
    try writeMultipartFile(
        allocator,
        stdout_fd,
        pattern_b64,
        pattern_png.len,
        "inline=1;width=20;height=8;preserveAspectRatio=0",
    );
    try writeBlankLines(stdout_fd, 10);

    try writeAllFd(stdout_fd, "Alpha PNG File. Expected: translucent red blending with background.\n\n");
    try writeSingleFile(
        allocator,
        stdout_fd,
        alpha_png_b64,
        alpha_len,
        "inline=1;width=20;height=8;preserveAspectRatio=0",
        .bel,
    );
    try writeBlankLines(stdout_fd, 10);

    try writeAllFd(stdout_fd, "Explicit pixel sizing. Expected: opaque red sample near 20x4 cells.\n\n");
    try writeSingleFile(
        allocator,
        stdout_fd,
        opaque_png_b64,
        opaque_len,
        "inline=1;width=160px;height=64px;preserveAspectRatio=0",
        .bel,
    );
    try writeBlankLines(stdout_fd, 6);

    try writeAllFd(stdout_fd,
        \\Text after images. Resize and scroll to verify iTerm2 cell-relative placement.
        \\
    );
}

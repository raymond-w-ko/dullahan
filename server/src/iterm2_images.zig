//! iTerm2 OSC 1337 inline image support.
//!
//! Ghostty parses OSC 1337, but currently treats File/MultipartFile image
//! commands as unimplemented. Dullahan captures those commands before they
//! reach ghostty-vt, stores image bytes per pane, and exposes placements via
//! the existing terminal image manifest.

const std = @import("std");
const ghostty = @import("ghostty-vt");

const constants = @import("constants.zig");
const dlog = @import("dlog.zig");
const png_decoder = @import("png_decoder.zig");

const Terminal = ghostty.Terminal;
const Pin = ghostty.Pin;
const ScreenKey = @TypeOf(@as(Terminal, undefined).screens.active_key);

const log = dlog.scoped(.pane);

const esc = 0x1b;
const bel = 0x07;
const max_osc_bytes = constants.images.iterm2_osc_sequence_limit;
const default_cols: u32 = 20;
const default_rows: u32 = 8;

pub const Mime = enum {
    png,
    jpeg,
    gif,
    webp,
    unsupported,

    pub fn contentType(self: Mime) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
            .unsupported => "",
        };
    }

    pub fn formatString(self: Mime) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpeg",
            .gif => "gif",
            .webp => "webp",
            .unsupported => "unsupported",
        };
    }
};

pub const Anchor = struct {
    screen_key: ScreenKey,
    pin: *Pin,
};

pub const Entry = struct {
    id: u32,
    placement_id: u32,
    data: []u8,
    mime: Mime,
    natural_width: u32,
    natural_height: u32,
    grid_cols: u32,
    grid_rows: u32,
    pixel_width: u32,
    pixel_height: u32,
    anchor: Anchor,
    generation: u64,

    fn deinit(self: *Entry, allocator: std.mem.Allocator, terminal: *Terminal) void {
        untrackAnchor(terminal, self.anchor);
        allocator.free(self.data);
    }
};

pub const ImageKey = struct {
    pane_id: u16,
    image_id: u32,
    format: Mime,
    width: u32,
    height: u32,
    content_hash: u64,
};

pub const ImageResponse = struct {
    data: []const u8,
    mime_type: []const u8,
    format: []const u8,
    width: u32,
    height: u32,
};

pub const Store = struct {
    entries: std.ArrayListUnmanaged(Entry) = .{},
    next_id: u32 = 1,
    next_placement_id: u32 = 1,
    total_bytes: usize = 0,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator, terminal: *Terminal) void {
        self.clearAll(allocator, terminal);
        self.* = .{};
    }

    pub fn clearAll(self: *Store, allocator: std.mem.Allocator, terminal: *Terminal) void {
        for (self.entries.items) |*entry| entry.deinit(allocator, terminal);
        self.entries.clearAndFree(allocator);
        self.total_bytes = 0;
    }

    pub fn clearScreen(
        self: *Store,
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        screen_key: ScreenKey,
    ) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].anchor.screen_key != screen_key) {
                i += 1;
                continue;
            }

            var old = self.entries.orderedRemove(i);
            self.total_bytes -= old.data.len;
            old.deinit(allocator, terminal);
        }
    }

    pub fn addImageAtCursor(
        self: *Store,
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        data: []u8,
        options: DisplayOptions,
        generation: u64,
    ) !void {
        const anchor = trackCurrentCursor(terminal) catch |err| {
            allocator.free(data);
            return err;
        };
        try self.addAnchoredImage(allocator, terminal, data, options, anchor, generation);
    }

    fn addAnchoredImage(
        self: *Store,
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        data: []u8,
        options: DisplayOptions,
        anchor: Anchor,
        generation: u64,
    ) !void {
        errdefer allocator.free(data);
        errdefer untrackAnchor(terminal, anchor);

        const mime = sniffMime(data);
        if (mime == .unsupported) return error.UnsupportedImageFormat;
        if (data.len > constants.images.iterm2_storage_limit) return error.ImageTooLarge;
        try self.pruneForCapacity(allocator, terminal, data.len);

        const natural = imageDimensions(allocator, mime, data);
        const grid = resolveGrid(options, terminal, natural.width, natural.height);
        const cell = cellSize(terminal);

        try self.entries.append(allocator, .{
            .id = self.next_id,
            .placement_id = self.next_placement_id,
            .data = data,
            .mime = mime,
            .natural_width = natural.width,
            .natural_height = natural.height,
            .grid_cols = grid.cols,
            .grid_rows = grid.rows,
            .pixel_width = grid.cols * cell.width,
            .pixel_height = grid.rows * cell.height,
            .anchor = anchor,
            .generation = generation,
        });
        self.total_bytes += data.len;
        self.next_id +%= 1;
        self.next_placement_id +%= 1;
    }

    fn pruneForCapacity(
        self: *Store,
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        incoming: usize,
    ) !void {
        while (self.total_bytes + incoming > constants.images.iterm2_storage_limit) {
            if (self.entries.items.len == 0) return error.ImageTooLarge;
            var old = self.entries.orderedRemove(0);
            self.total_bytes -= old.data.len;
            old.deinit(allocator, terminal);
        }
    }

    pub fn getImageResponse(
        self: *Store,
        pane_id: u16,
        image_key: []const u8,
    ) ?ImageResponse {
        const key = parseImageKey(image_key) orelse return null;
        if (key.pane_id != pane_id) return null;

        for (self.entries.items) |*entry| {
            if (entry.id != key.image_id) continue;
            if (keyMatches(key, pane_id, entry)) {
                return .{
                    .data = entry.data,
                    .mime_type = entry.mime.contentType(),
                    .format = entry.mime.formatString(),
                    .width = entry.natural_width,
                    .height = entry.natural_height,
                };
            }
        }
        return null;
    }
};

const State = enum {
    normal,
    esc,
    osc,
    osc_esc,
    osc_discard,
    osc_discard_esc,
};

const CommandKey = enum {
    file,
    multipart_file,
    file_part,
    file_end,
};

const ParsedCommand = struct {
    key: CommandKey,
    value: []const u8,
};

const Dimension = union(enum) {
    unspecified,
    auto,
    cells: u32,
    pixels: u32,
    percent: u32,
};

pub const DisplayOptions = struct {
    display_inline: bool = false,
    width: Dimension = .unspecified,
    height: Dimension = .unspecified,
    preserve_aspect_ratio: bool = true,
    declared_size: ?usize = null,
};

const Multipart = struct {
    options: DisplayOptions,
    data: std.ArrayListUnmanaged(u8) = .{},
    anchor: ?Anchor = null,

    fn deinit(self: *Multipart, allocator: std.mem.Allocator, terminal: *Terminal) void {
        if (self.anchor) |anchor| untrackAnchor(terminal, anchor);
        self.data.deinit(allocator);
        self.* = undefined;
    }
};

pub const Parser = struct {
    state: State = .normal,
    osc_buf: std.ArrayListUnmanaged(u8) = .{},
    multipart: ?Multipart = null,

    pub fn deinit(self: *Parser, allocator: std.mem.Allocator, terminal: *Terminal) void {
        if (self.multipart) |*multipart| multipart.deinit(allocator, terminal);
        self.osc_buf.deinit(allocator);
        self.* = .{};
    }

    pub fn abortMultipartForScreen(
        self: *Parser,
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        screen_key: ScreenKey,
    ) void {
        const should_abort = if (self.multipart) |multipart|
            if (multipart.anchor) |anchor| anchor.screen_key == screen_key else false
        else
            false;
        if (!should_abort) return;

        if (self.multipart) |*multipart| multipart.deinit(allocator, terminal);
        self.multipart = null;
    }

    pub fn abortMultipartAll(self: *Parser, allocator: std.mem.Allocator, terminal: *Terminal) void {
        if (self.multipart) |*multipart| multipart.deinit(allocator, terminal);
        self.multipart = null;
    }

    pub fn process(
        self: *Parser,
        allocator: std.mem.Allocator,
        store: *Store,
        terminal: *Terminal,
        stream: anytype,
        data: []const u8,
        pane_id: u16,
        generation: u64,
    ) !void {
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(allocator);

        for (data) |byte| {
            switch (self.state) {
                .normal => {
                    if (byte == esc) {
                        self.state = .esc;
                    } else {
                        try out.append(allocator, byte);
                    }
                },
                .esc => {
                    if (byte == ']') {
                        self.state = .osc;
                        self.osc_buf.clearRetainingCapacity();
                    } else {
                        try out.append(allocator, esc);
                        try out.append(allocator, byte);
                        self.state = .normal;
                    }
                },
                .osc => {
                    if (byte == bel) {
                        try self.finishOsc(allocator, store, terminal, stream, &out, .bel, pane_id, generation);
                    } else if (byte == esc) {
                        self.state = .osc_esc;
                    } else {
                        try self.appendOscByte(allocator, byte);
                    }
                },
                .osc_esc => {
                    if (byte == '\\') {
                        try self.finishOsc(allocator, store, terminal, stream, &out, .st, pane_id, generation);
                    } else {
                        try self.appendOscByte(allocator, esc);
                        try self.appendOscByte(allocator, byte);
                        self.state = .osc;
                    }
                },
                .osc_discard => {
                    if (byte == bel) {
                        self.state = .normal;
                    } else if (byte == esc) {
                        self.state = .osc_discard_esc;
                    }
                },
                .osc_discard_esc => {
                    self.state = if (byte == '\\') .normal else .osc_discard;
                },
            }
        }

        try flushOut(stream, &out);
    }

    const Terminator = enum { bel, st };

    fn appendOscByte(self: *Parser, allocator: std.mem.Allocator, byte: u8) !void {
        if (self.osc_buf.items.len >= max_osc_bytes) {
            log.warn("dropping oversized OSC 1337/image candidate sequence", .{});
            self.osc_buf.clearRetainingCapacity();
            self.state = .osc_discard;
            return;
        }
        try self.osc_buf.append(allocator, byte);
    }

    fn finishOsc(
        self: *Parser,
        allocator: std.mem.Allocator,
        store: *Store,
        terminal: *Terminal,
        stream: anytype,
        out: *std.ArrayListUnmanaged(u8),
        terminator: Terminator,
        pane_id: u16,
        generation: u64,
    ) !void {
        self.state = .normal;

        if (parseIterm2ImageCommand(self.osc_buf.items)) |cmd| {
            try flushOut(stream, out);
            self.handleCommand(allocator, store, terminal, cmd, pane_id, generation) catch |err| {
                log.warn("ignored invalid iTerm2 image command pane={d} err={}", .{ pane_id, err });
            };
            self.osc_buf.clearRetainingCapacity();
            return;
        }

        try out.appendSlice(allocator, "\x1b]");
        try out.appendSlice(allocator, self.osc_buf.items);
        switch (terminator) {
            .bel => try out.append(allocator, bel),
            .st => try out.appendSlice(allocator, "\x1b\\"),
        }
        self.osc_buf.clearRetainingCapacity();
    }

    fn handleCommand(
        self: *Parser,
        allocator: std.mem.Allocator,
        store: *Store,
        terminal: *Terminal,
        cmd: ParsedCommand,
        pane_id: u16,
        generation: u64,
    ) !void {
        _ = pane_id;
        switch (cmd.key) {
            .file => try self.handleFile(allocator, store, terminal, cmd.value, generation),
            .multipart_file => try self.handleMultipartFile(allocator, terminal, cmd.value),
            .file_part => try self.handleFilePart(allocator, cmd.value),
            .file_end => try self.handleFileEnd(allocator, store, terminal, generation),
        }
    }

    fn handleFile(
        self: *Parser,
        allocator: std.mem.Allocator,
        store: *Store,
        terminal: *Terminal,
        value: []const u8,
        generation: u64,
    ) !void {
        _ = self;
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidData;
        const options = parseOptions(value[0..colon]);
        if (!options.display_inline) return;
        const data = try decodeBase64Alloc(allocator, value[colon + 1 ..]);
        validateSize(options, data.len) catch |err| {
            allocator.free(data);
            return err;
        };
        try store.addImageAtCursor(allocator, terminal, data, options, generation);
    }

    fn handleMultipartFile(
        self: *Parser,
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        value: []const u8,
    ) !void {
        if (self.multipart) |*multipart| multipart.deinit(allocator, terminal);
        self.multipart = null;

        const options = parseOptions(value);
        const anchor = if (options.display_inline) try trackCurrentCursor(terminal) else null;
        self.multipart = .{
            .options = options,
            .anchor = anchor,
        };
    }

    fn handleFilePart(
        self: *Parser,
        allocator: std.mem.Allocator,
        value: []const u8,
    ) !void {
        const multipart = if (self.multipart) |*multipart| multipart else return;
        if (!multipart.options.display_inline) return;

        const decoded = try decodeBase64Alloc(allocator, value);
        defer allocator.free(decoded);
        if (multipart.data.items.len + decoded.len > constants.images.iterm2_storage_limit) {
            return error.ImageTooLarge;
        }
        if (multipart.options.declared_size) |declared| {
            if (multipart.data.items.len + decoded.len > declared) return error.ImageTooLarge;
        }
        try multipart.data.appendSlice(allocator, decoded);
    }

    fn handleFileEnd(
        self: *Parser,
        allocator: std.mem.Allocator,
        store: *Store,
        terminal: *Terminal,
        generation: u64,
    ) !void {
        var multipart = self.multipart orelse return;
        self.multipart = null;
        errdefer multipart.deinit(allocator, terminal);

        if (!multipart.options.display_inline) {
            multipart.deinit(allocator, terminal);
            return;
        }

        const anchor = multipart.anchor orelse return error.InvalidData;
        multipart.anchor = null;
        const data = try multipart.data.toOwnedSlice(allocator);
        multipart.data = .{};
        validateSize(multipart.options, data.len) catch |err| {
            allocator.free(data);
            untrackAnchor(terminal, anchor);
            return err;
        };
        try store.addAnchoredImage(allocator, terminal, data, multipart.options, anchor, generation);
    }
};

fn flushOut(stream: anytype, out: *std.ArrayListUnmanaged(u8)) !void {
    if (out.items.len == 0) return;
    stream.nextSlice(out.items);
    out.clearRetainingCapacity();
}

fn parseIterm2ImageCommand(content: []const u8) ?ParsedCommand {
    if (!startsWithIgnoreCase(content, "1337;")) return null;
    const rest = content["1337;".len..];
    const eq = std.mem.indexOfScalar(u8, rest, '=');
    const key_raw = if (eq) |idx| rest[0..idx] else rest;
    const value = if (eq) |idx| rest[idx + 1 ..] else "";

    if (std.ascii.eqlIgnoreCase(key_raw, "File")) return .{ .key = .file, .value = value };
    if (std.ascii.eqlIgnoreCase(key_raw, "MultipartFile")) return .{ .key = .multipart_file, .value = value };
    if (std.ascii.eqlIgnoreCase(key_raw, "FilePart")) return .{ .key = .file_part, .value = value };
    if (std.ascii.eqlIgnoreCase(key_raw, "FileEnd")) return .{ .key = .file_end, .value = value };
    return null;
}

fn parseOptions(raw: []const u8) DisplayOptions {
    var options: DisplayOptions = .{};
    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = std.mem.trim(u8, part[0..eq], " \t\r\n");
        const value = std.mem.trim(u8, part[eq + 1 ..], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(key, "inline")) {
            options.display_inline = std.mem.eql(u8, value, "1");
        } else if (std.ascii.eqlIgnoreCase(key, "width")) {
            options.width = parseDimension(value);
        } else if (std.ascii.eqlIgnoreCase(key, "height")) {
            options.height = parseDimension(value);
        } else if (std.ascii.eqlIgnoreCase(key, "preserveAspectRatio")) {
            options.preserve_aspect_ratio = !std.mem.eql(u8, value, "0");
        } else if (std.ascii.eqlIgnoreCase(key, "size")) {
            options.declared_size = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return options;
}

fn parseDimension(value: []const u8) Dimension {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    if (std.mem.endsWith(u8, value, "%")) {
        const n = std.fmt.parseInt(u32, value[0 .. value.len - 1], 10) catch return .unspecified;
        return .{ .percent = n };
    }
    if (std.mem.endsWith(u8, value, "px")) {
        const n = std.fmt.parseInt(u32, value[0 .. value.len - 2], 10) catch return .unspecified;
        return .{ .pixels = n };
    }
    const n = std.fmt.parseInt(u32, value, 10) catch return .unspecified;
    return .{ .cells = n };
}

fn validateSize(options: DisplayOptions, len: usize) !void {
    if (len > constants.images.iterm2_storage_limit) return error.ImageTooLarge;
    if (options.declared_size) |declared| {
        if (len > declared) return error.ImageTooLarge;
    }
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return error.InvalidBase64;
    return decoded;
}

fn trackCurrentCursor(terminal: *Terminal) !Anchor {
    const screen_key = terminal.screens.active_key;
    const pin = try terminal.screens.active.pages.trackPin(terminal.screens.active.cursor.page_pin.*);
    return .{ .screen_key = screen_key, .pin = pin };
}

fn untrackAnchor(terminal: *Terminal, anchor: Anchor) void {
    const screen = terminal.screens.get(anchor.screen_key) orelse return;
    screen.pages.untrackPin(anchor.pin);
}

pub fn pointFromAnchor(
    terminal: *Terminal,
    anchor: Anchor,
    grid_rows: u32,
    term_rows: u16,
) ?struct { col: i32, row: i32, visible: bool } {
    if (anchor.screen_key != terminal.screens.active_key) return null;
    if (anchor.pin.garbage) return null;

    const screen = terminal.screens.get(anchor.screen_key) orelse return null;
    const pin_screen = screen.pages.pointFromPin(.screen, anchor.pin.*) orelse return null;
    const vp_tl = screen.pages.getTopLeft(.viewport);
    const vp_screen = screen.pages.pointFromPin(.screen, vp_tl) orelse return null;

    const vp_row: i32 = @as(i32, @intCast(pin_screen.screen.y)) -
        @as(i32, @intCast(vp_screen.screen.y));
    const rows_i32: i32 = @intCast(grid_rows);
    const term_rows_i32: i32 = @intCast(term_rows);
    return .{
        .col = @intCast(pin_screen.screen.x),
        .row = vp_row,
        .visible = vp_row + rows_i32 > 0 and vp_row < term_rows_i32,
    };
}

const Dimensions = struct { width: u32 = 0, height: u32 = 0 };
const Grid = struct { cols: u32, rows: u32 };
const CellSize = struct { width: u32, height: u32 };

fn imageDimensions(allocator: std.mem.Allocator, mime: Mime, data: []const u8) Dimensions {
    if (mime != .png) return .{};
    const dimensions = png_decoder.decodePngDimensions(allocator, data) catch return .{};
    return .{ .width = dimensions.width, .height = dimensions.height };
}

fn cellSize(terminal: *Terminal) CellSize {
    const width = if (terminal.cols > 0 and terminal.width_px > 0)
        @max(@as(u32, 1), terminal.width_px / @as(u32, terminal.cols))
    else
        constants.terminal.default_cell_width_px;
    const height = if (terminal.rows > 0 and terminal.height_px > 0)
        @max(@as(u32, 1), terminal.height_px / @as(u32, terminal.rows))
    else
        constants.terminal.default_cell_height_px;
    return .{ .width = width, .height = height };
}

fn resolveGrid(options: DisplayOptions, terminal: *Terminal, natural_width: u32, natural_height: u32) Grid {
    const cell = cellSize(terminal);
    const requested_cols = dimensionToCells(options.width, terminal.cols, cell.width);
    const requested_rows = dimensionToCells(options.height, terminal.rows, cell.height);
    const has_natural = natural_width > 0 and natural_height > 0;

    if (requested_cols == null and requested_rows == null) {
        if (has_natural) {
            return clampGrid(.{
                .cols = ceilDivU32(natural_width, cell.width),
                .rows = ceilDivU32(natural_height, cell.height),
            }, terminal);
        }
        return fallbackGrid(terminal);
    }

    if (requested_cols != null and requested_rows == null) {
        const cols = requested_cols.?;
        if (has_natural) {
            const width_px = cols * cell.width;
            const height_px = ceilDivU64(
                @as(u64, width_px) * @as(u64, natural_height),
                natural_width,
            );
            return clampGrid(.{ .cols = cols, .rows = ceilDivU32(@intCast(height_px), cell.height) }, terminal);
        }
        return clampGrid(.{ .cols = cols, .rows = default_rows }, terminal);
    }

    if (requested_cols == null and requested_rows != null) {
        const rows = requested_rows.?;
        if (has_natural) {
            const height_px = rows * cell.height;
            const width_px = ceilDivU64(
                @as(u64, height_px) * @as(u64, natural_width),
                natural_height,
            );
            return clampGrid(.{ .cols = ceilDivU32(@intCast(width_px), cell.width), .rows = rows }, terminal);
        }
        return clampGrid(.{ .cols = default_cols, .rows = rows }, terminal);
    }

    const cols = requested_cols.?;
    const rows = requested_rows.?;
    if (!options.preserve_aspect_ratio or !has_natural) {
        return clampGrid(.{ .cols = cols, .rows = rows }, terminal);
    }

    const box_w = @as(u64, cols) * cell.width;
    const box_h = @as(u64, rows) * cell.height;
    if (@as(u64, natural_width) * box_h > @as(u64, natural_height) * box_w) {
        const height_px = ceilDivU64(box_w * natural_height, natural_width);
        return clampGrid(.{ .cols = cols, .rows = ceilDivU32(@intCast(height_px), cell.height) }, terminal);
    }
    const width_px = ceilDivU64(box_h * natural_width, natural_height);
    return clampGrid(.{ .cols = ceilDivU32(@intCast(width_px), cell.width), .rows = rows }, terminal);
}

fn dimensionToCells(dim: Dimension, terminal_cells: u16, cell_px: u32) ?u32 {
    return switch (dim) {
        .unspecified, .auto => null,
        .cells => |n| @max(@as(u32, 1), n),
        .pixels => |n| @max(@as(u32, 1), ceilDivU32(n, cell_px)),
        .percent => |n| @max(@as(u32, 1), ceilDivU32(@as(u32, terminal_cells) * n, 100)),
    };
}

fn fallbackGrid(terminal: *Terminal) Grid {
    return clampGrid(.{ .cols = default_cols, .rows = default_rows }, terminal);
}

fn clampGrid(grid: Grid, terminal: *Terminal) Grid {
    return .{
        .cols = @max(@as(u32, 1), @min(grid.cols, @max(@as(u32, 1), terminal.cols))),
        .rows = @max(@as(u32, 1), @min(grid.rows, @max(@as(u32, 1), terminal.rows))),
    };
}

fn ceilDivU32(n: u32, d: u32) u32 {
    return @intCast(ceilDivU64(n, d));
}

fn ceilDivU64(n: u64, d: u64) u64 {
    if (d == 0) return 1;
    return (n + d - 1) / d;
}

pub fn sniffMime(data: []const u8) Mime {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (data.len >= 3 and data[0] == 0xff and data[1] == 0xd8 and data[2] == 0xff) return .jpeg;
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return .gif;
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return .webp;
    return .unsupported;
}

fn imageContentHash(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

pub fn allocImageKey(
    allocator: std.mem.Allocator,
    pane_id: u16,
    entry: *const Entry,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "iterm2-{d}-{d}-{s}-{d}x{d}-{x}",
        .{
            pane_id,
            entry.id,
            entry.mime.formatString(),
            entry.natural_width,
            entry.natural_height,
            imageContentHash(entry.data),
        },
    );
}

fn parseImageKey(raw: []const u8) ?ImageKey {
    if (!std.mem.startsWith(u8, raw, "iterm2-")) return null;
    var it = std.mem.splitScalar(u8, raw["iterm2-".len..], '-');
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
        .format = mimeFromString(format_str) orelse return null,
        .width = std.fmt.parseInt(u32, width_str, 10) catch return null,
        .height = std.fmt.parseInt(u32, height_str, 10) catch return null,
        .content_hash = std.fmt.parseInt(u64, hash_str, 16) catch return null,
    };
}

fn mimeFromString(raw: []const u8) ?Mime {
    inline for (@typeInfo(Mime).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn keyMatches(key: ImageKey, pane_id: u16, entry: *const Entry) bool {
    return key.pane_id == pane_id and
        key.image_id == entry.id and
        key.format == entry.mime and
        key.width == entry.natural_width and
        key.height == entry.natural_height and
        key.content_hash == imageContentHash(entry.data);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

test "parse iTerm2 image commands" {
    const file = parseIterm2ImageCommand("1337;File=inline=1:abc").?;
    try std.testing.expectEqual(CommandKey.file, file.key);
    try std.testing.expectEqualStrings("inline=1:abc", file.value);

    const end = parseIterm2ImageCommand("1337;FileEnd").?;
    try std.testing.expectEqual(CommandKey.file_end, end.key);
    try std.testing.expectEqualStrings("", end.value);

    try std.testing.expect(parseIterm2ImageCommand("1337;Copy=:abc") == null);
}

test "parse iTerm2 display options" {
    const options = parseOptions("inline=1;width=20;height=48px;preserveAspectRatio=0;size=99");
    try std.testing.expect(options.display_inline);
    try std.testing.expectEqual(@as(?usize, 99), options.declared_size);
    try std.testing.expect(!options.preserve_aspect_ratio);
    try std.testing.expectEqual(@as(u32, 20), options.width.cells);
    try std.testing.expectEqual(@as(u32, 48), options.height.pixels);
}

test "sniff browser image mime types" {
    try std.testing.expectEqual(Mime.png, sniffMime("\x89PNG\r\n\x1a\nabc"));
    try std.testing.expectEqual(Mime.jpeg, sniffMime("\xff\xd8\xffabc"));
    try std.testing.expectEqual(Mime.gif, sniffMime("GIF89aabc"));
    try std.testing.expectEqual(Mime.webp, sniffMime("RIFFxxxxWEBP"));
    try std.testing.expectEqual(Mime.unsupported, sniffMime("nope"));
}

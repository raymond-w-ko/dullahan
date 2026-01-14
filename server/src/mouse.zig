//! Mouse event encoding for terminal mouse protocols
//!
//! Supports multiple mouse encoding formats:
//! - SGR (mode 1006): ESC [ < button ; x ; y M/m (1-indexed cells)
//! - SGR-Pixels (mode 1016): ESC [ < button ; px ; py M/m (0-indexed pixels)
//! - X10 (mode 9/1000): ESC [ M <button+32> <x+33> <y+33>
//! - URXVT (mode 1015): ESC [ <button+32> ; <x+1> ; <y+1> M
//! - UTF-8 (mode 1005): ESC [ M <button+32> <utf8(x+33)> <utf8(y+33)>

const std = @import("std");

const log = std.log.scoped(.mouse);

/// Mouse format from terminal mode settings
pub const MouseFormat = @import("pane.zig").MouseFormat;

/// Mouse event state
pub const MouseState = enum {
    down,
    up,
    move,

    pub fn fromString(s: []const u8) ?MouseState {
        if (std.mem.eql(u8, s, "down")) return .down;
        if (std.mem.eql(u8, s, "up")) return .up;
        if (std.mem.eql(u8, s, "move")) return .move;
        return null;
    }

    pub fn isRelease(self: MouseState) bool {
        return self == .up;
    }

    pub fn isMotion(self: MouseState) bool {
        return self == .move;
    }
};

/// Modifier keys for mouse events
pub const Modifiers = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,

    /// Calculate modifier bits for button encoding
    /// shift=+4, alt=+8, ctrl=+16
    pub fn toBits(self: Modifiers) u8 {
        var bits: u8 = 0;
        if (self.shift) bits += 4;
        if (self.alt) bits += 8;
        if (self.ctrl) bits += 16;
        return bits;
    }
};

/// Mouse event data for encoding
pub const MouseEvent = struct {
    button: u8, // 0=left, 1=middle, 2=right, 64+=wheel
    x: u16, // Cell X coordinate (0-indexed)
    y: u16, // Cell Y coordinate (0-indexed)
    px: ?u32 = null, // Pixel X coordinate (for SGR-Pixels)
    py: ?u32 = null, // Pixel Y coordinate (for SGR-Pixels)
    state: MouseState,
    modifiers: Modifiers = .{},
};

/// Result of encoding a mouse event
pub const EncodeResult = struct {
    data: []const u8,
    len: usize,

    pub fn slice(self: EncodeResult) []const u8 {
        return self.data[0..self.len];
    }
};

/// Encode a mouse event to SGR format (mode 1006)
/// Format: ESC [ < button ; x ; y M/m
/// Coordinates are 1-indexed
pub fn encodeSgr(event: MouseEvent, buf: []u8) ?EncodeResult {
    if (buf.len < 32) return null;

    var button_code: u8 = event.button;
    button_code += event.modifiers.toBits();
    if (event.state.isMotion()) button_code += 32;

    // Coordinates are 1-indexed in SGR
    const x = event.x + 1;
    const y = event.y + 1;

    // Terminator: 'M' for press/motion, 'm' for release
    const terminator: u8 = if (event.state.isRelease()) 'm' else 'M';

    const seq = std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
        button_code,
        x,
        y,
        terminator,
    }) catch return null;

    return .{ .data = buf, .len = seq.len };
}

/// Encode a mouse event to SGR-Pixels format (mode 1016)
/// Format: ESC [ < button ; px ; py M/m
/// Coordinates are 0-indexed pixels
pub fn encodeSgrPixels(event: MouseEvent, buf: []u8) ?EncodeResult {
    if (buf.len < 48) return null;

    var button_code: u8 = event.button;
    button_code += event.modifiers.toBits();
    if (event.state.isMotion()) button_code += 32;

    // Use pixel coordinates if available, otherwise fall back to cell coords
    // Note: Unlike SGR which is 1-indexed, SGR-Pixels is 0-indexed
    const px = event.px orelse event.x;
    const py = event.py orelse event.y;

    // Terminator: 'M' for press/motion, 'm' for release
    const terminator: u8 = if (event.state.isRelease()) 'm' else 'M';

    const seq = std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
        button_code,
        px,
        py,
        terminator,
    }) catch return null;

    return .{ .data = buf, .len = seq.len };
}

/// Encode a mouse event to X10 format (mode 9/1000)
/// Format: ESC [ M <button+32> <x+33> <y+33>
/// Coordinate limit: max 222 (222 + 32 + 1 = 255)
pub fn encodeX10(event: MouseEvent, buf: []u8, include_modifiers: bool) ?EncodeResult {
    if (buf.len < 6) return null;

    // Coordinate limit: max 222
    if (event.x > 222 or event.y > 222) {
        log.debug("X10 mouse: coordinates ({d},{d}) exceed limit 222", .{ event.x, event.y });
        return null;
    }

    // Button code calculation
    var button_code: u8 = if (event.state.isRelease())
        3 // Release is always 3 in X10 format
    else
        event.button;

    // X10 mode (DECSET 9) doesn't have modifiers, but normal mode (1000) does
    if (include_modifiers) {
        button_code += event.modifiers.toBits();
    }
    if (event.state.isMotion()) button_code += 32;

    // Encode: ESC [ M <button+32> <x+33> <y+33>
    buf[0] = 0x1b; // ESC
    buf[1] = '[';
    buf[2] = 'M';
    buf[3] = 32 + button_code;
    buf[4] = 32 + @as(u8, @intCast(event.x)) + 1;
    buf[5] = 32 + @as(u8, @intCast(event.y)) + 1;

    return .{ .data = buf, .len = 6 };
}

/// Encode a mouse event to URXVT format (mode 1015)
/// Format: ESC [ <button+32> ; <x+1> ; <y+1> M
/// Like X10 but uses decimal encoding for coordinates (no 223 limit)
pub fn encodeUrxvt(event: MouseEvent, buf: []u8) ?EncodeResult {
    if (buf.len < 32) return null;

    var button_code: u8 = if (event.state.isRelease())
        3 // Release is always 3
    else
        event.button;

    button_code += event.modifiers.toBits();
    if (event.state.isMotion()) button_code += 32;

    // Coordinates are 1-indexed
    const x = event.x + 1;
    const y = event.y + 1;

    const seq = std.fmt.bufPrint(buf, "\x1b[{d};{d};{d}M", .{
        32 + button_code,
        x,
        y,
    }) catch return null;

    return .{ .data = buf, .len = seq.len };
}

/// Encode a mouse event to UTF-8 format (mode 1005)
/// Format: ESC [ M <button+32> <utf8(x+33)> <utf8(y+33)>
/// Like X10 but uses UTF-8 encoding for coordinates (extends beyond 223)
pub fn encodeUtf8(event: MouseEvent, buf: []u8) ?EncodeResult {
    if (buf.len < 12) return null;

    var button_code: u8 = if (event.state.isRelease())
        3 // Release is always 3
    else
        event.button;

    button_code += event.modifiers.toBits();
    if (event.state.isMotion()) button_code += 32;

    // Build the sequence: ESC [ M <button> <x> <y>
    buf[0] = 0x1b; // ESC
    buf[1] = '[';
    buf[2] = 'M';
    buf[3] = 32 + button_code;

    // UTF-8 encode coordinates (1-indexed, +32 offset)
    var i: usize = 4;
    const x_len = std.unicode.utf8Encode(@intCast(32 + event.x + 1), buf[i..]) catch return null;
    i += x_len;
    const y_len = std.unicode.utf8Encode(@intCast(32 + event.y + 1), buf[i..]) catch return null;
    i += y_len;

    return .{ .data = buf, .len = i };
}

/// Encode a mouse event using the specified format
pub fn encode(event: MouseEvent, format: MouseFormat, buf: []u8, include_x10_modifiers: bool) ?EncodeResult {
    return switch (format) {
        .sgr => encodeSgr(event, buf),
        .sgr_pixels => encodeSgrPixels(event, buf),
        .x10 => encodeX10(event, buf, include_x10_modifiers),
        .urxvt => encodeUrxvt(event, buf),
        .utf8 => encodeUtf8(event, buf),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "MouseState.fromString" {
    try std.testing.expectEqual(MouseState.down, MouseState.fromString("down"));
    try std.testing.expectEqual(MouseState.up, MouseState.fromString("up"));
    try std.testing.expectEqual(MouseState.move, MouseState.fromString("move"));
    try std.testing.expectEqual(@as(?MouseState, null), MouseState.fromString("invalid"));
}

test "Modifiers.toBits" {
    // No modifiers
    try std.testing.expectEqual(@as(u8, 0), (Modifiers{}).toBits());

    // Single modifiers
    try std.testing.expectEqual(@as(u8, 4), (Modifiers{ .shift = true }).toBits());
    try std.testing.expectEqual(@as(u8, 8), (Modifiers{ .alt = true }).toBits());
    try std.testing.expectEqual(@as(u8, 16), (Modifiers{ .ctrl = true }).toBits());

    // Combined modifiers
    try std.testing.expectEqual(@as(u8, 12), (Modifiers{ .shift = true, .alt = true }).toBits());
    try std.testing.expectEqual(@as(u8, 28), (Modifiers{ .shift = true, .alt = true, .ctrl = true }).toBits());
}

test "encodeSgr basic left click" {
    var buf: [32]u8 = undefined;
    const event = MouseEvent{
        .button = 0, // left
        .x = 10,
        .y = 5,
        .state = .down,
    };

    const result = encodeSgr(event, &buf) orelse unreachable;
    // Button 0, x=11 (1-indexed), y=6 (1-indexed), M for press
    try std.testing.expectEqualStrings("\x1b[<0;11;6M", result.slice());
}

test "encodeSgr left release" {
    var buf: [32]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .state = .up,
    };

    const result = encodeSgr(event, &buf) orelse unreachable;
    // Same coords, but 'm' for release
    try std.testing.expectEqualStrings("\x1b[<0;11;6m", result.slice());
}

test "encodeSgr with modifiers" {
    var buf: [32]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 0,
        .y = 0,
        .state = .down,
        .modifiers = .{ .ctrl = true, .shift = true },
    };

    const result = encodeSgr(event, &buf) orelse unreachable;
    // Button 0 + shift(4) + ctrl(16) = 20
    try std.testing.expectEqualStrings("\x1b[<20;1;1M", result.slice());
}

test "encodeSgr motion" {
    var buf: [32]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 5,
        .y = 5,
        .state = .move,
    };

    const result = encodeSgr(event, &buf) orelse unreachable;
    // Button 0 + motion(32) = 32
    try std.testing.expectEqualStrings("\x1b[<32;6;6M", result.slice());
}

test "encodeSgr right click" {
    var buf: [32]u8 = undefined;
    const event = MouseEvent{
        .button = 2, // right
        .x = 20,
        .y = 10,
        .state = .down,
    };

    const result = encodeSgr(event, &buf) orelse unreachable;
    try std.testing.expectEqualStrings("\x1b[<2;21;11M", result.slice());
}

test "encodeSgrPixels basic" {
    var buf: [48]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .px = 150,
        .py = 80,
        .state = .down,
    };

    const result = encodeSgrPixels(event, &buf) orelse unreachable;
    // Uses pixel coordinates (0-indexed)
    try std.testing.expectEqualStrings("\x1b[<0;150;80M", result.slice());
}

test "encodeSgrPixels falls back to cell coords" {
    var buf: [48]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .px = null,
        .py = null,
        .state = .down,
    };

    const result = encodeSgrPixels(event, &buf) orelse unreachable;
    // Falls back to cell coords (0-indexed in pixels mode)
    try std.testing.expectEqualStrings("\x1b[<0;10;5M", result.slice());
}

test "encodeX10 basic left click" {
    var buf: [6]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .state = .down,
    };

    const result = encodeX10(event, &buf, false) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqual(@as(u8, 0x1b), result.data[0]); // ESC
    try std.testing.expectEqual(@as(u8, '['), result.data[1]);
    try std.testing.expectEqual(@as(u8, 'M'), result.data[2]);
    try std.testing.expectEqual(@as(u8, 32 + 0), result.data[3]); // button 0 + 32
    try std.testing.expectEqual(@as(u8, 32 + 10 + 1), result.data[4]); // x + 33
    try std.testing.expectEqual(@as(u8, 32 + 5 + 1), result.data[5]); // y + 33
}

test "encodeX10 release" {
    var buf: [6]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .state = .up,
    };

    const result = encodeX10(event, &buf, false) orelse unreachable;
    // Release always uses button 3
    try std.testing.expectEqual(@as(u8, 32 + 3), result.data[3]);
}

test "encodeX10 with modifiers (mode 1000)" {
    var buf: [6]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .state = .down,
        .modifiers = .{ .ctrl = true },
    };

    const result = encodeX10(event, &buf, true) orelse unreachable;
    // Button 0 + ctrl(16) = 16
    try std.testing.expectEqual(@as(u8, 32 + 16), result.data[3]);
}

test "encodeX10 coordinate limit" {
    var buf: [6]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 223, // Exceeds 222 limit
        .y = 5,
        .state = .down,
    };

    const result = encodeX10(event, &buf, false);
    try std.testing.expectEqual(@as(?EncodeResult, null), result);
}

test "encodeX10 max valid coordinate" {
    var buf: [6]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 222, // Max valid
        .y = 222,
        .state = .down,
    };

    const result = encodeX10(event, &buf, false) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 32 + 222 + 1), result.data[4]); // 255
    try std.testing.expectEqual(@as(u8, 32 + 222 + 1), result.data[5]); // 255
}

test "encodeUrxvt basic" {
    var buf: [32]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .state = .down,
    };

    const result = encodeUrxvt(event, &buf) orelse unreachable;
    // Button 32 (0+32), x=11 (1-indexed), y=6 (1-indexed)
    try std.testing.expectEqualStrings("\x1b[32;11;6M", result.slice());
}

test "encodeUrxvt release" {
    var buf: [32]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .state = .up,
    };

    const result = encodeUrxvt(event, &buf) orelse unreachable;
    // Release always uses button 3, so 35 (3+32)
    try std.testing.expectEqualStrings("\x1b[35;11;6M", result.slice());
}

test "encodeUrxvt large coordinates" {
    var buf: [32]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 500,
        .y = 300,
        .state = .down,
    };

    const result = encodeUrxvt(event, &buf) orelse unreachable;
    // URXVT has no coordinate limit (decimal encoding)
    try std.testing.expectEqualStrings("\x1b[32;501;301M", result.slice());
}

test "encodeUtf8 basic" {
    var buf: [12]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .state = .down,
    };

    const result = encodeUtf8(event, &buf) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 6), result.len); // Small coords = single bytes
    try std.testing.expectEqual(@as(u8, 0x1b), result.data[0]); // ESC
    try std.testing.expectEqual(@as(u8, '['), result.data[1]);
    try std.testing.expectEqual(@as(u8, 'M'), result.data[2]);
    try std.testing.expectEqual(@as(u8, 32 + 0), result.data[3]); // button
    try std.testing.expectEqual(@as(u8, 32 + 10 + 1), result.data[4]); // x + 33
    try std.testing.expectEqual(@as(u8, 32 + 5 + 1), result.data[5]); // y + 33
}

test "encodeUtf8 large coordinates" {
    var buf: [12]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 200, // 200 + 33 = 233 > 127, needs 2-byte UTF-8
        .y = 5,
        .state = .down,
    };

    const result = encodeUtf8(event, &buf) orelse unreachable;
    // X coordinate needs 2 bytes (233 in UTF-8 is 0xC3 0xA9)
    try std.testing.expect(result.len > 6);
}

test "encode dispatcher" {
    var buf: [48]u8 = undefined;
    const event = MouseEvent{
        .button = 0,
        .x = 10,
        .y = 5,
        .state = .down,
    };

    // Test all formats
    const sgr = encode(event, .sgr, &buf, false) orelse unreachable;
    try std.testing.expectEqualStrings("\x1b[<0;11;6M", sgr.slice());

    const sgr_px = encode(event, .sgr_pixels, &buf, false) orelse unreachable;
    try std.testing.expectEqualStrings("\x1b[<0;10;5M", sgr_px.slice());

    const x10 = encode(event, .x10, &buf, false) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 6), x10.len);

    const urxvt = encode(event, .urxvt, &buf, false) orelse unreachable;
    try std.testing.expectEqualStrings("\x1b[32;11;6M", urxvt.slice());

    const utf8 = encode(event, .utf8, &buf, false) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 6), utf8.len);
}

test "wheel events" {
    var buf: [32]u8 = undefined;

    // Scroll up (button 64)
    const scroll_up = MouseEvent{
        .button = 64,
        .x = 10,
        .y = 5,
        .state = .down,
    };
    const result_up = encodeSgr(scroll_up, &buf) orelse unreachable;
    try std.testing.expectEqualStrings("\x1b[<64;11;6M", result_up.slice());

    // Scroll down (button 65)
    const scroll_down = MouseEvent{
        .button = 65,
        .x = 10,
        .y = 5,
        .state = .down,
    };
    const result_down = encodeSgr(scroll_down, &buf) orelse unreachable;
    try std.testing.expectEqualStrings("\x1b[<65;11;6M", result_down.slice());
}

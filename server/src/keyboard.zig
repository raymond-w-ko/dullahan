//! Keyboard event to terminal escape sequence conversion
//!
//! Converts browser KeyboardEvent data to terminal-compatible byte sequences.
//! Handles special keys, modifiers, cursor keys in application mode, and function keys.

const std = @import("std");

/// Keyboard event from browser (matches JavaScript KeyboardEvent)
pub const KeyEvent = struct {
    type: []const u8,
    key: []const u8,
    code: []const u8,
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    repeat: bool = false,
    timestamp: f64 = 0,
    keyCode: u16 = 0,
};

/// Convert a keyboard event to terminal escape sequence bytes.
/// Returns a slice into the output buffer with the escape sequence.
/// Returns empty slice for modifier-only keys or key-up events.
pub fn keyEventToBytes(event: KeyEvent, output: []u8, cursor_key_application: bool) []u8 {
    if (!std.mem.eql(u8, event.state, "down")) {
        return output[0..0];
    }

    const key = event.key;

    // Ignore modifier-only keys
    if (std.mem.eql(u8, key, "Meta") or
        std.mem.eql(u8, key, "Control") or
        std.mem.eql(u8, key, "Alt") or
        std.mem.eql(u8, key, "Shift") or
        std.mem.eql(u8, key, "CapsLock") or
        std.mem.eql(u8, key, "NumLock") or
        std.mem.eql(u8, key, "ScrollLock") or
        std.mem.eql(u8, key, "Hyper") or
        std.mem.eql(u8, key, "Super") or
        std.mem.eql(u8, key, "OS") or
        std.mem.eql(u8, key, "AltGraph") or
        std.mem.eql(u8, key, "Fn") or
        std.mem.eql(u8, key, "FnLock"))
    {
        return output[0..0];
    }

    const ctrl = event.ctrl;
    const alt = event.alt;
    const shift = event.shift;

    // Single character keys
    if (key.len == 1) {
        const c = key[0];

        // Ctrl+letter -> control character
        if (ctrl and c >= 'a' and c <= 'z') {
            output[0] = c - 'a' + 1;
            return output[0..1];
        }
        if (ctrl and c >= 'A' and c <= 'Z') {
            output[0] = c - 'A' + 1;
            return output[0..1];
        }

        // Ctrl+special -> control character
        if (ctrl) {
            const ctrl_char: ?u8 = switch (c) {
                '@' => 0x00,
                '[' => 0x1b,
                '\\' => 0x1c,
                ']' => 0x1d,
                '^' => 0x1e,
                '_' => 0x1f,
                '?' => 0x7f,
                else => null,
            };
            if (ctrl_char) |cc| {
                output[0] = cc;
                return output[0..1];
            }
        }

        // Alt+key -> ESC + key
        if (alt) {
            output[0] = 0x1b;
            output[1] = c;
            return output[0..2];
        }

        output[0] = c;
        return output[0..1];
    }

    // Named special keys
    if (std.mem.eql(u8, key, "Enter")) {
        output[0] = '\r';
        return output[0..1];
    }
    if (std.mem.eql(u8, key, "Backspace")) {
        output[0] = 0x7f;
        return output[0..1];
    }
    if (std.mem.eql(u8, key, "Tab")) {
        if (shift) {
            output[0] = 0x1b;
            output[1] = '[';
            output[2] = 'Z';
            return output[0..3];
        }
        output[0] = '\t';
        return output[0..1];
    }
    if (std.mem.eql(u8, key, "Escape")) {
        output[0] = 0x1b;
        return output[0..1];
    }
    if (std.mem.eql(u8, key, "Delete")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '3';
        output[3] = '~';
        return output[0..4];
    }

    // Arrow keys
    if (std.mem.eql(u8, key, "ArrowUp")) {
        return writeArrowKey(output, 'A', ctrl, alt, cursor_key_application);
    }
    if (std.mem.eql(u8, key, "ArrowDown")) {
        return writeArrowKey(output, 'B', ctrl, alt, cursor_key_application);
    }
    if (std.mem.eql(u8, key, "ArrowRight")) {
        return writeArrowKey(output, 'C', ctrl, alt, cursor_key_application);
    }
    if (std.mem.eql(u8, key, "ArrowLeft")) {
        return writeArrowKey(output, 'D', ctrl, alt, cursor_key_application);
    }

    // Navigation keys
    if (std.mem.eql(u8, key, "Home")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = 'H';
        return output[0..3];
    }
    if (std.mem.eql(u8, key, "End")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = 'F';
        return output[0..3];
    }

    if (std.mem.eql(u8, key, "PageUp")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '5';
        output[3] = '~';
        return output[0..4];
    }
    if (std.mem.eql(u8, key, "PageDown")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '6';
        output[3] = '~';
        return output[0..4];
    }

    if (std.mem.eql(u8, key, "Insert")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '2';
        output[3] = '~';
        return output[0..4];
    }

    // Function keys (F1-F12)
    if (key.len >= 2 and key[0] == 'F') {
        const fnum = std.fmt.parseInt(u8, key[1..], 10) catch return output[0..0];
        return writeFunctionKey(output, fnum);
    }

    // Multi-byte UTF-8 character (emoji, etc.)
    if (key.len > 1 and key.len <= output.len) {
        @memcpy(output[0..key.len], key);
        if (alt) {
            var i: usize = key.len;
            while (i > 0) : (i -= 1) {
                output[i] = output[i - 1];
            }
            output[0] = 0x1b;
            return output[0 .. key.len + 1];
        }
        return output[0..key.len];
    }

    return output[0..0];
}

/// Write arrow key escape sequence with optional modifiers
fn writeArrowKey(output: []u8, arrow: u8, ctrl: bool, alt: bool, cursor_key_application: bool) []u8 {
    if (ctrl or alt) {
        var mod: u8 = 1;
        if (alt) mod += 2;
        if (ctrl) mod += 4;
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '1';
        output[3] = ';';
        output[4] = '0' + mod;
        output[5] = arrow;
        return output[0..6];
    }
    output[0] = 0x1b;
    if (cursor_key_application) {
        output[1] = 'O';
    } else {
        output[1] = '[';
    }
    output[2] = arrow;
    return output[0..3];
}

/// Write function key escape sequence (F1-F12)
fn writeFunctionKey(output: []u8, fnum: u8) []u8 {
    const codes = [_]struct { prefix: []const u8, suffix: u8 }{
        .{ .prefix = "\x1bOP", .suffix = 0 }, // F1
        .{ .prefix = "\x1bOQ", .suffix = 0 }, // F2
        .{ .prefix = "\x1bOR", .suffix = 0 }, // F3
        .{ .prefix = "\x1bOS", .suffix = 0 }, // F4
        .{ .prefix = "\x1b[15~", .suffix = 0 }, // F5
        .{ .prefix = "\x1b[17~", .suffix = 0 }, // F6
        .{ .prefix = "\x1b[18~", .suffix = 0 }, // F7
        .{ .prefix = "\x1b[19~", .suffix = 0 }, // F8
        .{ .prefix = "\x1b[20~", .suffix = 0 }, // F9
        .{ .prefix = "\x1b[21~", .suffix = 0 }, // F10
        .{ .prefix = "\x1b[23~", .suffix = 0 }, // F11
        .{ .prefix = "\x1b[24~", .suffix = 0 }, // F12
    };

    if (fnum >= 1 and fnum <= 12) {
        const code = codes[fnum - 1];
        @memcpy(output[0..code.prefix.len], code.prefix);
        return output[0..code.prefix.len];
    }

    return output[0..0];
}

// ============================================================================
// Tests
// ============================================================================

test "basic keys" {
    var buf: [32]u8 = undefined;

    // Single character
    const a = keyEventToBytes(.{ .type = "key", .key = "a", .code = "KeyA", .state = "down" }, &buf, false);
    try std.testing.expectEqualStrings("a", a);

    // Enter
    const enter = keyEventToBytes(.{ .type = "key", .key = "Enter", .code = "Enter", .state = "down" }, &buf, false);
    try std.testing.expectEqualStrings("\r", enter);

    // Backspace
    const bs = keyEventToBytes(.{ .type = "key", .key = "Backspace", .code = "Backspace", .state = "down" }, &buf, false);
    try std.testing.expectEqual(@as(u8, 0x7f), bs[0]);
}

test "modifier keys" {
    var buf: [32]u8 = undefined;

    // Ctrl+c
    const ctrl_c = keyEventToBytes(.{ .type = "key", .key = "c", .code = "KeyC", .state = "down", .ctrl = true }, &buf, false);
    try std.testing.expectEqual(@as(u8, 3), ctrl_c[0]);

    // Alt+x
    const alt_x = keyEventToBytes(.{ .type = "key", .key = "x", .code = "KeyX", .state = "down", .alt = true }, &buf, false);
    try std.testing.expectEqual(@as(u8, 0x1b), alt_x[0]);
    try std.testing.expectEqual(@as(u8, 'x'), alt_x[1]);
}

test "arrow keys" {
    var buf: [32]u8 = undefined;

    // Normal mode
    const up_normal = keyEventToBytes(.{ .type = "key", .key = "ArrowUp", .code = "ArrowUp", .state = "down" }, &buf, false);
    try std.testing.expectEqualStrings("\x1b[A", up_normal);

    // Application mode
    const up_app = keyEventToBytes(.{ .type = "key", .key = "ArrowUp", .code = "ArrowUp", .state = "down" }, &buf, true);
    try std.testing.expectEqualStrings("\x1bOA", up_app);
}

test "function keys" {
    var buf: [32]u8 = undefined;

    const f1 = keyEventToBytes(.{ .type = "key", .key = "F1", .code = "F1", .state = "down" }, &buf, false);
    try std.testing.expectEqualStrings("\x1bOP", f1);

    const f5 = keyEventToBytes(.{ .type = "key", .key = "F5", .code = "F5", .state = "down" }, &buf, false);
    try std.testing.expectEqualStrings("\x1b[15~", f5);
}

test "modifier-only keys ignored" {
    var buf: [32]u8 = undefined;

    const ctrl = keyEventToBytes(.{ .type = "key", .key = "Control", .code = "ControlLeft", .state = "down" }, &buf, false);
    try std.testing.expectEqual(@as(usize, 0), ctrl.len);

    const shift = keyEventToBytes(.{ .type = "key", .key = "Shift", .code = "ShiftLeft", .state = "down" }, &buf, false);
    try std.testing.expectEqual(@as(usize, 0), shift.len);
}

test "key up ignored" {
    var buf: [32]u8 = undefined;

    const up = keyEventToBytes(.{ .type = "key", .key = "a", .code = "KeyA", .state = "up" }, &buf, false);
    try std.testing.expectEqual(@as(usize, 0), up.len);
}

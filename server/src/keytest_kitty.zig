//! Kitty Keyboard Protocol Tester
//!
//! Simple line-based output for each key event.
//! Format: ↓/↑ key (mods) Bytes: xx xx xx
//!
//! Press Escape twice to exit.

const std = @import("std");
const posix = std.posix;

// Kitty keyboard protocol flags:
// 1=disambiguate, 2=report event types, 4=report alternate keys, 8=report all keys
const KITTY_ENABLE = "\x1b[>11u"; // 1+2+8 = disambiguate + events + all keys
const KITTY_DISABLE = "\x1b[<u";

var running = true;
var escape_count: u8 = 0;
var log_file: ?std.fs.File = null;

pub fn main() !void {
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;

    // Open log file
    log_file = std.fs.cwd().createFile("/tmp/keytest-kitty.log", .{ .truncate = true }) catch null;
    defer if (log_file) |f| f.close();

    // Set raw mode
    const original = try posix.tcgetattr(stdin_fd);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(stdin_fd, .NOW, raw);
    defer posix.tcsetattr(stdin_fd, .NOW, original) catch {};

    // Enable Kitty protocol
    _ = posix.write(stdout_fd, KITTY_ENABLE) catch {};
    defer _ = posix.write(stdout_fd, KITTY_DISABLE) catch {};

    // Header
    _ = posix.write(stdout_fd, "Kitty Keyboard Tester (ESC twice to exit)\n") catch {};
    _ = posix.write(stdout_fd, "─────────────────────────────────────────\n") catch {};

    var buf: [64]u8 = undefined;
    while (running) {
        const n = posix.read(stdin_fd, &buf) catch break;
        if (n == 0) break;

        parseAndPrint(stdout_fd, buf[0..n]);
    }

    _ = posix.write(stdout_fd, "\nBye!\n") catch {};
}

fn parseAndPrint(fd: posix.fd_t, buf: []const u8) void {
    var out: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    const w = fbs.writer();

    // Parse the input
    var arrow: u8 = ' ';
    var key_name: []const u8 = "?";
    var mods: u8 = 0;
    var event_type: u8 = 1; // 1=press, 2=repeat, 3=release

    if (buf.len >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        const last = buf[buf.len - 1];

        if (last == 'u') {
            // CSI u sequence: codepoint ; mods:event u
            const params = buf[2 .. buf.len - 1];
            var cp: u21 = 0;
            parseCSIu(params, &cp, &mods, &event_type);
            key_name = codepointName(cp);
        } else if (last >= 'A' and last <= 'D') {
            // Arrow keys: CSI 1 ; mods:event <letter>
            const params = buf[2 .. buf.len - 1];
            parseArrowParams(params, &mods, &event_type);
            key_name = switch (last) {
                'A' => "Up",
                'B' => "Down",
                'C' => "Right",
                'D' => "Left",
                else => "?",
            };
        } else if (last == 'H' or last == 'F') {
            const params = buf[2 .. buf.len - 1];
            parseArrowParams(params, &mods, &event_type);
            key_name = if (last == 'H') "Home" else "End";
        } else if (last == '~') {
            // Function keys: CSI num ; mods:event ~
            const params = buf[2 .. buf.len - 1];
            var num: u8 = 0;
            parseFnParams(params, &num, &mods, &event_type);
            key_name = fnKeyName(num);
        } else if (last >= 'P' and last <= 'S') {
            // F1-F4: CSI 1 ; mods:event P/Q/R/S
            const params = buf[2 .. buf.len - 1];
            parseArrowParams(params, &mods, &event_type);
            key_name = switch (last) {
                'P' => "F1",
                'Q' => "F2",
                'R' => "F3",
                'S' => "F4",
                else => "?",
            };
        }
    } else if (buf.len == 1) {
        // Single byte (legacy mode fallback)
        const c = buf[0];
        if (c == 0x1b) {
            key_name = "Escape";
            // Note: escape_count handled in parseCSIu for Kitty mode
            escape_count += 1;
            if (escape_count >= 2) running = false;
        } else if (c == 0x0d) {
            key_name = "Enter";
        } else if (c == 0x09) {
            key_name = "Tab";
        } else if (c == 0x7f) {
            key_name = "Backspace";
        } else if (c >= 0x20 and c < 0x7f) {
            key_name = &[_]u8{c};
        } else if (c >= 1 and c <= 26) {
            key_name = "Ctrl+?";
            mods = 4; // Ctrl
        }
    }

    // Note: escape_count reset is handled in parseCSIu when a non-escape key is pressed

    // Event arrow
    arrow = switch (event_type) {
        1 => 0xe2, // ↓ (will write 3 bytes)
        2 => 0xe2, // ⟳ repeat
        3 => 0xe2, // ↑
        else => ' ',
    };

    // Write event symbol (UTF-8)
    switch (event_type) {
        1 => w.writeAll("↓ ") catch {},
        2 => w.writeAll("⟳ ") catch {},
        3 => w.writeAll("↑ ") catch {},
        else => w.writeAll("? ") catch {},
    }

    // Key name (pad to 12 chars)
    w.writeAll(key_name) catch {};
    const pad = if (key_name.len < 12) 12 - key_name.len else 0;
    for (0..pad) |_| w.writeByte(' ') catch {};

    // Modifiers - Kitty sends (1 + modifier_bits), so subtract 1 first
    if (mods > 1) {
        const m = mods - 1;
        w.writeAll(" (") catch {};
        var first = true;
        if (m & 0x01 != 0) {
            if (!first) w.writeByte('+') catch {};
            w.writeAll("Shift") catch {};
            first = false;
        }
        if (m & 0x02 != 0) {
            if (!first) w.writeByte('+') catch {};
            w.writeAll("Alt") catch {};
            first = false;
        }
        if (m & 0x04 != 0) {
            if (!first) w.writeByte('+') catch {};
            w.writeAll("Ctrl") catch {};
            first = false;
        }
        if (m & 0x08 != 0) {
            if (!first) w.writeByte('+') catch {};
            w.writeAll("Super") catch {};
            first = false;
        }
        w.writeByte(')') catch {};
    }

    // Raw bytes
    w.writeAll("  Bytes:") catch {};
    for (buf) |b| {
        std.fmt.format(w, " {x:0>2}", .{b}) catch {};
    }
    w.writeByte('\n') catch {};

    _ = posix.write(fd, fbs.getWritten()) catch {};

    // Also log
    if (log_file) |f| {
        _ = f.write(fbs.getWritten()) catch {};
    }
}

fn parseCSIu(params: []const u8, cp: *u21, mods: *u8, event: *u8) void {
    // Format: codepoint;mods:event or codepoint
    var semi_idx: usize = params.len;
    for (params, 0..) |c, i| {
        if (c == ';') {
            semi_idx = i;
            break;
        }
    }

    // Parse codepoint (may have :shifted:base suffix)
    var cp_end = semi_idx;
    for (params[0..semi_idx], 0..) |c, i| {
        if (c == ':') {
            cp_end = i;
            break;
        }
    }
    cp.* = std.fmt.parseInt(u21, params[0..cp_end], 10) catch 0;

    // Parse mods:event
    if (semi_idx < params.len) {
        parseModsEvent(params[semi_idx + 1 ..], mods, event);
    }
    
    // Track Escape presses for double-escape exit
    // Codepoint 27 = Escape
    if (cp.* == 27 and event.* == 1) { // press event
        escape_count += 1;
        if (escape_count >= 2) {
            running = false;
        }
    } else if (event.* == 1) { // any other key press resets
        escape_count = 0;
    }
}

fn parseArrowParams(params: []const u8, mods: *u8, event: *u8) void {
    // Format: 1;mods:event or just 1
    var semi_idx: usize = params.len;
    for (params, 0..) |c, i| {
        if (c == ';') {
            semi_idx = i;
            break;
        }
    }
    if (semi_idx < params.len) {
        parseModsEvent(params[semi_idx + 1 ..], mods, event);
    }
}

fn parseFnParams(params: []const u8, num: *u8, mods: *u8, event: *u8) void {
    // Format: num;mods:event or num
    var semi_idx: usize = params.len;
    for (params, 0..) |c, i| {
        if (c == ';') {
            semi_idx = i;
            break;
        }
    }
    num.* = std.fmt.parseInt(u8, params[0..semi_idx], 10) catch 0;
    if (semi_idx < params.len) {
        parseModsEvent(params[semi_idx + 1 ..], mods, event);
    }
}

fn parseModsEvent(s: []const u8, mods: *u8, event: *u8) void {
    // Format: mods or mods:event
    var colon_idx: usize = s.len;
    for (s, 0..) |c, i| {
        if (c == ':') {
            colon_idx = i;
            break;
        }
    }
    mods.* = std.fmt.parseInt(u8, s[0..colon_idx], 10) catch 1;
    if (colon_idx < s.len) {
        event.* = std.fmt.parseInt(u8, s[colon_idx + 1 ..], 10) catch 1;
    }
}

fn codepointName(cp: u21) []const u8 {
    return switch (cp) {
        27 => "Escape",
        13 => "Enter",
        9 => "Tab",
        127 => "Backspace",
        32 => "Space",
        57344 => "Escape",
        57345 => "Enter",
        57346 => "Tab",
        57347 => "Backspace",
        57348 => "Insert",
        57349 => "Delete",
        57350 => "Left",
        57351 => "Right",
        57352 => "Up",
        57353 => "Down",
        57354 => "PageUp",
        57355 => "PageDown",
        57356 => "Home",
        57357 => "End",
        57358 => "CapsLock",
        57359 => "ScrollLock",
        57360 => "NumLock",
        57361 => "PrintScreen",
        57362 => "Pause",
        57363 => "Menu",
        57364 => "F1",
        57365 => "F2",
        57366 => "F3",
        57367 => "F4",
        57368 => "F5",
        57369 => "F6",
        57370 => "F7",
        57371 => "F8",
        57372 => "F9",
        57373 => "F10",
        57374 => "F11",
        57375 => "F12",
        57441 => "LShift",
        57442 => "LCtrl",
        57443 => "LAlt",
        57444 => "LSuper",
        57447 => "RShift",
        57448 => "RCtrl",
        57449 => "RAlt",
        57450 => "RSuper",
        else => blk: {
            if (cp >= 0x21 and cp <= 0x7e) {
                // Single printable ASCII - return static string
                const chars = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                const idx = cp - 0x20;
                break :blk chars[idx..][0..1];
            }
            break :blk "?";
        },
    };
}

fn fnKeyName(num: u8) []const u8 {
    return switch (num) {
        2 => "Insert",
        3 => "Delete",
        5 => "PageUp",
        6 => "PageDown",
        15 => "F5",
        17 => "F6",
        18 => "F7",
        19 => "F8",
        20 => "F9",
        21 => "F10",
        23 => "F11",
        24 => "F12",
        else => "Fn?",
    };
}

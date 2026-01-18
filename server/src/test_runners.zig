//! Test runners for dullahan
//!
//! Standalone test tools integrated into the main binary.
//! Run with: dullahan test <subcommand>
//!
//! Available tests:
//!   keytest-kitty   - Kitty keyboard protocol tester
//!   keytest-bytes   - Byte coverage tester (256-byte grid)
//!   delta-gen       - Delta sync test data generator
//!   shell-delta     - Shell delta sync test

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

// Import dullahan modules for delta tests
const Pane = @import("pane.zig").Pane;
const Pty = @import("pty.zig").Pty;
const paths = @import("paths.zig");
const snapshot = @import("snapshot.zig");

const log = std.log.scoped(.test_runners);

/// Test subcommand
pub const TestCommand = enum {
    @"keytest-kitty",
    @"keytest-bytes",
    @"delta-gen",
    @"shell-delta",
    @"osc52-set",
    @"osc52-get",
    @"osc52-interactive",
    @"grapheme-test",
    @"grapheme-debug",
    @"hyperlink-test",
    help,

    pub fn fromString(s: []const u8) ?TestCommand {
        const map = std.StaticStringMap(TestCommand).initComptime(.{
            .{ "keytest-kitty", .@"keytest-kitty" },
            .{ "keytest-bytes", .@"keytest-bytes" },
            .{ "delta-gen", .@"delta-gen" },
            .{ "shell-delta", .@"shell-delta" },
            .{ "osc52-set", .@"osc52-set" },
            .{ "osc52-get", .@"osc52-get" },
            .{ "osc52-interactive", .@"osc52-interactive" },
            .{ "grapheme-test", .@"grapheme-test" },
            .{ "grapheme-debug", .@"grapheme-debug" },
            .{ "hyperlink-test", .@"hyperlink-test" },
            .{ "help", .help },
        });
        return map.get(s);
    }

    pub fn description(self: TestCommand) []const u8 {
        return switch (self) {
            .@"keytest-kitty" => "Kitty keyboard protocol tester (ESC twice to exit)",
            .@"keytest-bytes" => "Byte coverage tester - 256-byte grid (press 'q' to exit)",
            .@"delta-gen" => "Generate delta sync test fixtures in test_fixtures/delta/",
            .@"shell-delta" => "Spawn shell, test delta sync with arrow keys",
            .@"osc52-set" => "Send OSC 52 SET to clipboard (usage: osc52-set [c|p] [text])",
            .@"osc52-get" => "Send OSC 52 GET to read clipboard (usage: osc52-get [c|p])",
            .@"osc52-interactive" => "Interactive OSC 52 clipboard tester",
            .@"grapheme-test" => "Display grapheme clusters (emoji, combining marks)",
            .@"grapheme-debug" => "Debug grapheme cluster detection in VT emulator",
            .@"hyperlink-test" => "Display OSC 8 hyperlinks for testing",
            .help => "Show available test commands",
        };
    }
};

pub fn printTestUsage() void {
    const usage =
        \\Usage: dullahan test <SUBCOMMAND>
        \\
        \\Test Commands:
        \\  keytest-kitty     Kitty keyboard protocol tester (ESC twice to exit)
        \\  keytest-bytes     Byte coverage tester - 256-byte grid (press 'q' to exit)
        \\  delta-gen         Generate delta sync test fixtures
        \\  shell-delta       Shell delta sync test
        \\  osc52-set         Send OSC 52 SET sequence (run in terminal pane)
        \\  osc52-get         Send OSC 52 GET sequence (run in terminal pane)
        \\  osc52-interactive Interactive clipboard tester (run in terminal pane)
        \\  grapheme-test     Display grapheme clusters (emoji, combining marks)
        \\  grapheme-debug    Debug grapheme detection in VT emulator
        \\  hyperlink-test    Display OSC 8 hyperlinks for testing
        \\  help              Show this help
        \\
        \\Examples:
        \\  dullahan test keytest-kitty         # Test keyboard input with Kitty protocol
        \\  dullahan test osc52-set c hello     # Set clipboard 'c' to "hello"
        \\  dullahan test osc52-set p primary   # Set primary selection to "primary"
        \\  dullahan test osc52-get c           # Request clipboard 'c' content
        \\  dullahan test osc52-interactive     # Interactive mode (run in dullahan pane)
        \\  dullahan test grapheme-test         # Test grapheme cluster rendering
        \\  dullahan test hyperlink-test        # Test OSC 8 hyperlinks
        \\
    ;
    std.debug.print("{s}", .{usage});
}

/// Run the specified test command
pub fn runTest(allocator: std.mem.Allocator, cmd: TestCommand) !void {
    switch (cmd) {
        .@"keytest-kitty" => try runKeytestKitty(),
        .@"keytest-bytes" => try runKeytestBytes(),
        .@"delta-gen" => try runDeltaGen(allocator),
        .@"shell-delta" => try runShellDelta(allocator),
        .@"osc52-set" => try runOsc52Set(),
        .@"osc52-get" => try runOsc52Get(),
        .@"osc52-interactive" => try runOsc52Interactive(),
        .@"grapheme-test" => runGraphemeTest(),
        .@"grapheme-debug" => try runGraphemeDebug(allocator),
        .@"hyperlink-test" => runHyperlinkTest(),
        .help => printTestUsage(),
    }
}

// =============================================================================
// Kitty Keyboard Protocol Tester
// =============================================================================

// Kitty keyboard protocol flags:
// 1=disambiguate, 2=report event types, 4=report alternate keys, 8=report all keys
const KITTY_ENABLE = "\x1b[>11u"; // 1+2+8 = disambiguate + events + all keys
const KITTY_DISABLE = "\x1b[<u";

var kitty_running = true;
var kitty_escape_count: u8 = 0;
var kitty_log_file: ?std.fs.File = null;

fn runKeytestKitty() !void {
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;

    // Reset state
    kitty_running = true;
    kitty_escape_count = 0;

    // Ensure temp directory exists and open log file
    paths.ensureTempDir() catch {};
    const log_path = paths.StaticPaths.keytestLog();
    kitty_log_file = std.fs.createFileAbsolute(log_path, .{ .truncate = true }) catch null;
    defer if (kitty_log_file) |f| f.close();

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
    while (kitty_running) {
        const n = posix.read(stdin_fd, &buf) catch break;
        if (n == 0) break;

        kittyParseAndPrint(stdout_fd, buf[0..n]);
    }

    _ = posix.write(stdout_fd, "\nBye!\n") catch {};
}

fn kittyParseAndPrint(fd: posix.fd_t, buf: []const u8) void {
    var out: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    const w = fbs.writer();

    // Parse the input
    var key_name: []const u8 = "?";
    var mods: u8 = 0;
    var event_type: u8 = 1; // 1=press, 2=repeat, 3=release

    if (buf.len >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        const last = buf[buf.len - 1];

        if (last == 'u') {
            // CSI u sequence: codepoint ; mods:event u
            const params = buf[2 .. buf.len - 1];
            var cp: u21 = 0;
            kittyParseCSIu(params, &cp, &mods, &event_type);
            key_name = kittyCodepointName(cp);
        } else if (last >= 'A' and last <= 'D') {
            // Arrow keys: CSI 1 ; mods:event <letter>
            const params = buf[2 .. buf.len - 1];
            kittyParseArrowParams(params, &mods, &event_type);
            key_name = switch (last) {
                'A' => "Up",
                'B' => "Down",
                'C' => "Right",
                'D' => "Left",
                else => "?",
            };
        } else if (last == 'H' or last == 'F') {
            const params = buf[2 .. buf.len - 1];
            kittyParseArrowParams(params, &mods, &event_type);
            key_name = if (last == 'H') "Home" else "End";
        } else if (last == '~') {
            // Function keys: CSI num ; mods:event ~
            const params = buf[2 .. buf.len - 1];
            var num: u8 = 0;
            kittyParseFnParams(params, &num, &mods, &event_type);
            key_name = kittyFnKeyName(num);
        } else if (last >= 'P' and last <= 'S') {
            // F1-F4: CSI 1 ; mods:event P/Q/R/S
            const params = buf[2 .. buf.len - 1];
            kittyParseArrowParams(params, &mods, &event_type);
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
            kitty_escape_count += 1;
            if (kitty_escape_count >= 2) kitty_running = false;
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
    if (kitty_log_file) |f| {
        _ = f.write(fbs.getWritten()) catch {};
    }
}

fn kittyParseCSIu(params: []const u8, cp: *u21, mods: *u8, event: *u8) void {
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
        kittyParseModsEvent(params[semi_idx + 1 ..], mods, event);
    }

    // Track Escape presses for double-escape exit
    if (cp.* == 27 and event.* == 1) {
        kitty_escape_count += 1;
        if (kitty_escape_count >= 2) {
            kitty_running = false;
        }
    } else if (event.* == 1) {
        kitty_escape_count = 0;
    }
}

fn kittyParseArrowParams(params: []const u8, mods: *u8, event: *u8) void {
    var semi_idx: usize = params.len;
    for (params, 0..) |c, i| {
        if (c == ';') {
            semi_idx = i;
            break;
        }
    }
    if (semi_idx < params.len) {
        kittyParseModsEvent(params[semi_idx + 1 ..], mods, event);
    }
}

fn kittyParseFnParams(params: []const u8, num: *u8, mods: *u8, event: *u8) void {
    var semi_idx: usize = params.len;
    for (params, 0..) |c, i| {
        if (c == ';') {
            semi_idx = i;
            break;
        }
    }
    num.* = std.fmt.parseInt(u8, params[0..semi_idx], 10) catch 0;
    if (semi_idx < params.len) {
        kittyParseModsEvent(params[semi_idx + 1 ..], mods, event);
    }
}

fn kittyParseModsEvent(s: []const u8, mods: *u8, event: *u8) void {
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

fn kittyCodepointName(cp: u21) []const u8 {
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
                const chars = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                const idx = cp - 0x20;
                break :blk chars[idx..][0..1];
            }
            break :blk "?";
        },
    };
}

fn kittyFnKeyName(num: u8) []const u8 {
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

// =============================================================================
// Byte Coverage Tester
// =============================================================================

const RESET = "\x1b[0m";
const BLUE = "\x1b[34;1m";
const YELLOW = "\x1b[33;1m";
const DIM = "\x1b[2m";
const CLEAR = "\x1b[2J\x1b[H";
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";

var bytes_received: [256]bool = [_]bool{false} ** 256;
var bytes_running = true;
var bytes_total_received: u16 = 0;
var bytes_warning_buf: [80]u8 = [_]u8{' '} ** 80;
var bytes_warning_len: usize = 0;

const key_hints = [256][]const u8{
    // 0x00-0x0F
    "^@", "^A", "^B", "^C", "^D", "^E", "^F", "^G",
    "^H", "Tab", "^J", "^K", "^L", "Ret", "^N", "^O",
    // 0x10-0x1F
    "^P", "^Q", "^R", "^S", "^T", "^U", "^V", "^W",
    "^X", "^Y", "^Z", "Esc", "^\\", "^]", "^^", "^_",
    // 0x20-0x2F (printable)
    "Spc", "!", "\"", "#", "$", "%", "&", "'",
    "(", ")", "*", "+", ",", "-", ".", "/",
    // 0x30-0x3F
    "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", ":", ";", "<", "=", ">", "?",
    // 0x40-0x4F
    "@", "A", "B", "C", "D", "E", "F", "G",
    "H", "I", "J", "K", "L", "M", "N", "O",
    // 0x50-0x5F
    "P", "Q", "R", "S", "T", "U", "V", "W",
    "X", "Y", "Z", "[", "\\", "]", "^", "_",
    // 0x60-0x6F
    "`", "a", "b", "c", "d", "e", "f", "g",
    "h", "i", "j", "k", "l", "m", "n", "o",
    // 0x70-0x7F
    "p", "q", "r", "s", "t", "u", "v", "w",
    "x", "y", "z", "{", "|", "}", "~", "Del",
    // 0x80-0xFF (extended)
    "x80", "x81", "x82", "x83", "x84", "x85", "x86", "x87",
    "x88", "x89", "x8A", "x8B", "x8C", "x8D", "x8E", "x8F",
    "x90", "x91", "x92", "x93", "x94", "x95", "x96", "x97",
    "x98", "x99", "x9A", "x9B", "x9C", "x9D", "x9E", "x9F",
    "xA0", "xA1", "xA2", "xA3", "xA4", "xA5", "xA6", "xA7",
    "xA8", "xA9", "xAA", "xAB", "xAC", "xAD", "xAE", "xAF",
    "xB0", "xB1", "xB2", "xB3", "xB4", "xB5", "xB6", "xB7",
    "xB8", "xB9", "xBA", "xBB", "xBC", "xBD", "xBE", "xBF",
    "xC0", "xC1", "xC2", "xC3", "xC4", "xC5", "xC6", "xC7",
    "xC8", "xC9", "xCA", "xCB", "xCC", "xCD", "xCE", "xCF",
    "xD0", "xD1", "xD2", "xD3", "xD4", "xD5", "xD6", "xD7",
    "xD8", "xD9", "xDA", "xDB", "xDC", "xDD", "xDE", "xDF",
    "xE0", "xE1", "xE2", "xE3", "xE4", "xE5", "xE6", "xE7",
    "xE8", "xE9", "xEA", "xEB", "xEC", "xED", "xEE", "xEF",
    "xF0", "xF1", "xF2", "xF3", "xF4", "xF5", "xF6", "xF7",
    "xF8", "xF9", "xFA", "xFB", "xFC", "xFD", "xFE", "xFF",
};

fn runKeytestBytes() !void {
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;

    // Reset state
    bytes_received = [_]bool{false} ** 256;
    bytes_running = true;
    bytes_total_received = 0;
    bytes_warning_len = 0;

    // Set raw mode
    const original = try posix.tcgetattr(stdin_fd);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 1; // 100ms timeout
    try posix.tcsetattr(stdin_fd, .NOW, raw);
    defer posix.tcsetattr(stdin_fd, .NOW, original) catch {};

    _ = posix.write(stdout_fd, HIDE_CURSOR) catch {};
    defer _ = posix.write(stdout_fd, SHOW_CURSOR) catch {};

    bytesRender(stdout_fd);

    var buf: [64]u8 = undefined;
    var seq_buf: [64]u8 = undefined;
    var seq_len: usize = 0;

    while (bytes_running) {
        const n = posix.read(stdin_fd, &buf) catch break;

        if (n == 0) {
            if (seq_len > 0 and seq_buf[0] == 0x1b) {
                if (seq_len == 1) {
                    bytesMarkReceived(0x1b);
                    bytesClearWarning();
                }
                seq_len = 0;
            }
            continue;
        }

        for (buf[0..n]) |b| {
            if (seq_len < seq_buf.len) {
                seq_buf[seq_len] = b;
                seq_len += 1;
            }
        }

        if (seq_buf[0] == 0x1b and seq_len > 1) {
            if (seq_len >= 2 and seq_buf[1] == '[') {
                const last = seq_buf[seq_len - 1];
                if (bytesIsCSITerminator(last)) {
                    bytesSetWarning(&seq_buf, seq_len);
                    seq_len = 0;
                    bytesRender(stdout_fd);
                    continue;
                }
                continue;
            }
            if (seq_len >= 2 and seq_buf[1] == 'O') {
                if (seq_len >= 3) {
                    bytesSetWarning(&seq_buf, seq_len);
                    seq_len = 0;
                    bytesRender(stdout_fd);
                    continue;
                }
                continue;
            }
            if (seq_len == 2 and seq_buf[1] >= 0x20 and seq_buf[1] < 0x7f) {
                bytesSetWarning(&seq_buf, seq_len);
                seq_len = 0;
                bytesRender(stdout_fd);
                continue;
            }
        }

        if (seq_buf[0] != 0x1b or seq_len == 1) {
            for (seq_buf[0..seq_len]) |b| {
                bytesMarkReceived(b);
            }
            bytesClearWarning();
            seq_len = 0;
        }

        if (seq_len == 0 and buf[0] == 'q') {
            bytes_running = false;
        }

        bytesRender(stdout_fd);
    }
}

fn bytesIsCSITerminator(c: u8) bool {
    return c >= 0x40 and c <= 0x7E;
}

fn bytesMarkReceived(b: u8) void {
    if (!bytes_received[b]) {
        bytes_received[b] = true;
        bytes_total_received += 1;
    }
}

fn bytesClearWarning() void {
    bytes_warning_len = 0;
}

fn bytesSetWarning(seq: []const u8, len: usize) void {
    var w = std.io.fixedBufferStream(&bytes_warning_buf);
    const writer = w.writer();

    writer.writeAll("Escape sequence: ") catch {};
    for (seq[0..len]) |b| {
        if (b == 0x1b) {
            writer.writeAll("ESC ") catch {};
        } else if (b >= 0x20 and b < 0x7f) {
            writer.writeByte(b) catch {};
            writer.writeByte(' ') catch {};
        } else {
            std.fmt.format(writer, "0x{X:0>2} ", .{b}) catch {};
        }
    }

    bytes_warning_len = w.pos;
}

fn bytesRender(fd: posix.fd_t) void {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll(CLEAR) catch {};
    w.writeAll("Byte Coverage Tester") catch {};
    std.fmt.format(w, " ({d}/256 received, press 'q' to quit)\n", .{bytes_total_received}) catch {};

    if (bytes_warning_len > 0) {
        w.writeAll(YELLOW) catch {};
        w.writeAll(bytes_warning_buf[0..bytes_warning_len]) catch {};
        w.writeAll(RESET) catch {};
    }
    w.writeAll("\n\n") catch {};

    var byte_val: u16 = 0;
    while (byte_val < 256) : (byte_val += 1) {
        const b: u8 = @intCast(byte_val);
        const hint = key_hints[b];

        if (bytes_received[b]) {
            w.writeAll(BLUE) catch {};
        } else {
            w.writeAll(DIM) catch {};
        }

        std.fmt.format(w, "{X:0>2}:{s:<3}", .{ b, hint }) catch {};
        w.writeAll(RESET) catch {};

        if ((byte_val + 1) % 8 == 0) {
            w.writeAll("\n") catch {};
        } else {
            w.writeAll("  ") catch {};
        }
    }

    w.writeAll("\n") catch {};
    w.writeAll(DIM ++ "Note: ^X = Ctrl+X, 0x80-0xFF need special input methods\n" ++ RESET) catch {};

    _ = posix.write(fd, fbs.getWritten()) catch {};
}

// =============================================================================
// Delta Test Generator
// =============================================================================

const DeltaTestCase = struct {
    name: []const u8,
    cols: u16,
    rows: u16,
    initial_input: []const u8,
    delta_input: []const u8,
};

const delta_test_cases = [_]DeltaTestCase{
    .{
        .name = "simple_echo",
        .cols = 80,
        .rows = 24,
        .initial_input = "hello\r\n",
        .delta_input = "world\r\n",
    },
    .{
        .name = "cursor_move",
        .cols = 40,
        .rows = 10,
        .initial_input = "line1\r\nline2\r\n",
        .delta_input = "\x1b[Hstart",
    },
    .{
        .name = "colors",
        .cols = 40,
        .rows = 10,
        .initial_input = "plain\r\n",
        .delta_input = "\x1b[31mred\x1b[0m\r\n",
    },
    .{
        .name = "multi_line",
        .cols = 40,
        .rows = 10,
        .initial_input = "",
        .delta_input = "a\r\nb\r\nc\r\n",
    },
};

fn runDeltaGen(allocator: std.mem.Allocator) !void {
    const out_dir = "test_fixtures/delta";
    std.fs.cwd().makePath(out_dir) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    for (delta_test_cases) |tc| {
        try generateDeltaTestCase(allocator, out_dir, tc);
    }

    log.info("Generated {d} test cases in {s}/", .{ delta_test_cases.len, out_dir });
    std.debug.print("Generated {d} test cases in {s}/\n", .{ delta_test_cases.len, out_dir });
}

fn generateDeltaTestCase(allocator: std.mem.Allocator, out_dir: []const u8, tc: DeltaTestCase) !void {
    log.info("Generating test case: {s}", .{tc.name});

    var pane = try Pane.init(allocator, .{
        .cols = tc.cols,
        .rows = tc.rows,
    });
    defer pane.deinit();

    if (tc.initial_input.len > 0) {
        try pane.feed(tc.initial_input);
    }

    pane.clearDirtyRows();

    const snapshot_a = try snapshot.generateBinarySnapshot(allocator, &pane);
    defer allocator.free(snapshot_a);

    const gen_a = pane.generation;
    log.debug("Snapshot A: gen={d}, {d} bytes", .{ gen_a, snapshot_a.len });

    try pane.feed(tc.delta_input);

    const snapshot_b = try snapshot.generateBinarySnapshot(allocator, &pane);
    defer allocator.free(snapshot_b);

    const gen_b = pane.generation;
    log.debug("Snapshot B: gen={d}, {d} bytes, dirty_rows={d}", .{
        gen_b,
        snapshot_b.len,
        pane.getDirtyRowCount(),
    });

    const delta = try snapshot.generateDelta(allocator, &pane, 0, false);
    defer allocator.free(delta);

    log.debug("Delta: {d} bytes", .{delta.len});

    // Write metadata
    var meta_path_buf: [256]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&meta_path_buf, "{s}/{s}_meta.json", .{ out_dir, tc.name });

    var meta_file = try std.fs.cwd().createFile(meta_path, .{});
    defer meta_file.close();

    var buf: [1024]u8 = undefined;
    const meta_json = try std.fmt.bufPrint(&buf,
        \\{{
        \\  "name": "{s}",
        \\  "cols": {d},
        \\  "rows": {d},
        \\  "gen_a": {d},
        \\  "gen_b": {d}
        \\}}
    , .{
        tc.name,
        tc.cols,
        tc.rows,
        gen_a,
        gen_b,
    });
    try meta_file.writeAll(meta_json);

    // Write files
    var path_buf: [256]u8 = undefined;
    const snapshot_a_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}_snapshot_a.bin", .{ out_dir, tc.name });
    try deltaWriteFile(snapshot_a_path, snapshot_a);

    const snapshot_b_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}_snapshot_b.bin", .{ out_dir, tc.name });
    try deltaWriteFile(snapshot_b_path, snapshot_b);

    const delta_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}_delta.bin", .{ out_dir, tc.name });
    try deltaWriteFile(delta_path, delta);

    log.info("  Written: {s}_*.bin", .{tc.name});
}

fn deltaWriteFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

// =============================================================================
// Shell Delta Test
// =============================================================================

const UP_ARROW = "\x1b[A";

fn runShellDelta(allocator: std.mem.Allocator) !void {
    var pane = try Pane.init(allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    var pty = try Pty.open(.{
        .ws_row = 24,
        .ws_col = 80,
    });

    // Try to find a shell
    const shell_path = findShell() orelse {
        std.debug.print("Error: Could not find a shell (tried fish, bash, zsh, sh)\n", .{});
        return error.NoShellFound;
    };

    // Set up minimal environment (SHELL is set by the shell itself)
    const env: [4:null]?[*:0]const u8 = .{
        "TERM=xterm-256color",
        "HOME=/tmp",
        "USER=test",
        "fish_greeting=",
    };

    const pid = try pty.spawn(&.{ shell_path, "-i" }, &env);
    log.info("Spawned shell (pid={d})", .{pid});
    std.debug.print("Spawned shell: {s} (pid={d})\n", .{ shell_path, pid });

    pane.pty = pty;
    pane.child_pid = pid;

    log.info("Waiting for shell prompt...", .{});
    std.debug.print("Waiting for shell prompt...\n", .{});
    try shellWaitForOutput(allocator, &pane, 2000);

    log.info("Shell alive: {any}", .{pane.isAlive()});

    const initial_snapshot = try snapshot.generateBinarySnapshot(allocator, &pane);
    defer allocator.free(initial_snapshot);
    log.info("Initial snapshot: {d} bytes, gen={d}", .{ initial_snapshot.len, pane.generation });

    pane.clearDirtyRows();

    var mismatches: usize = 0;
    for (0..10) |i| {
        log.info("\n=== Iteration {d} ===", .{i + 1});
        std.debug.print("Iteration {d}/10...\n", .{i + 1});

        if (!pane.isAlive()) {
            log.err("Shell died before iteration {d}!", .{i + 1});
            break;
        }

        try pane.writeInput(UP_ARROW);
        log.info("Sent UP arrow", .{});

        try shellWaitForOutput(allocator, &pane, 500);

        const gen_before = pane.generation;
        const dirty_count = pane.getDirtyRowCount();
        log.info("After up: gen={d}, dirty_rows={d}", .{ gen_before, dirty_count });

        const full_snapshot = try snapshot.generateBinarySnapshot(allocator, &pane);
        defer allocator.free(full_snapshot);

        const delta_data = try snapshot.generateDelta(allocator, &pane, 0, false);
        defer allocator.free(delta_data);

        log.info("Full snapshot: {d} bytes", .{full_snapshot.len});
        log.info("Delta: {d} bytes", .{delta_data.len});

        const mismatch = try shellCompareSnapshotAndDelta(allocator, full_snapshot, delta_data, &pane);
        if (mismatch) {
            mismatches += 1;
            log.err("MISMATCH detected in iteration {d}!", .{i + 1});
        } else {
            log.info("OK - snapshot and delta match", .{});
        }

        pane.clearDirtyRows();
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    log.info("\n=== Summary ===", .{});
    log.info("Total iterations: 10", .{});
    log.info("Mismatches: {d}", .{mismatches});

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Total iterations: 10\n", .{});
    std.debug.print("Mismatches: {d}\n", .{mismatches});

    if (mismatches > 0) {
        log.err("TEST FAILED: {d} mismatches detected", .{mismatches});
        std.debug.print("TEST FAILED: {d} mismatches detected\n", .{mismatches});
        std.process.exit(1);
    } else {
        log.info("TEST PASSED: All iterations matched", .{});
        std.debug.print("TEST PASSED: All iterations matched\n", .{});
    }
}

fn findShell() ?[:0]const u8 {
    const shells = [_][:0]const u8{
        "/bin/bash",
        "/bin/zsh",
        "/bin/sh",
        "/usr/bin/bash",
        "/usr/bin/zsh",
        "/usr/bin/sh",
    };
    for (shells) |shell| {
        std.fs.accessAbsolute(shell, .{}) catch continue;
        return shell;
    }
    return null;
}

fn shellWaitForOutput(allocator: std.mem.Allocator, pane: *Pane, timeout_ms: u32) !void {
    _ = allocator;
    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;

    const pty_fd = pane.getPtyFd() orelse return error.NoPty;

    const start = std.time.milliTimestamp();
    const deadline = start + timeout_ms;

    var poll_fds = [_]posix.pollfd{
        .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    while (std.time.milliTimestamp() < deadline) {
        const remaining = @as(i32, @intCast(@max(0, deadline - std.time.milliTimestamp())));
        const ready = posix.poll(&poll_fds, remaining) catch break;

        if (ready == 0) break;

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(pty_fd, &buf) catch break;
            if (n == 0) break;

            total_read += n;
            try pane.feed(buf[0..n]);

            log.debug("Read {d} bytes from PTY", .{n});
        }
    }

    log.info("Total read: {d} bytes", .{total_read});
}

fn shellCompareSnapshotAndDelta(allocator: std.mem.Allocator, snapshot_data: []const u8, delta_data: []const u8, pane: *Pane) !bool {
    const decoded_snapshot = try shellDecodeSnapshot(allocator, snapshot_data);
    defer allocator.free(decoded_snapshot.cells);

    const decoded_delta = try shellDecodeDelta(allocator, delta_data);
    defer {
        for (decoded_delta.dirty_rows) |row| {
            allocator.free(row.cells);
        }
        allocator.free(decoded_delta.dirty_rows);
        allocator.free(decoded_delta.row_ids);
    }

    const cols = pane.cols;
    const rows = pane.rows;

    var row_cache = std.AutoHashMap(u64, []const u8).init(allocator);
    defer row_cache.deinit();

    for (decoded_delta.dirty_rows) |row| {
        try row_cache.put(row.id, row.cells);
    }

    var has_mismatch = false;
    for (0..rows) |y| {
        const snapshot_row_start = y * cols * 8;
        const snapshot_row_end = snapshot_row_start + cols * 8;
        const snapshot_row = decoded_snapshot.cells[snapshot_row_start..snapshot_row_end];

        const row_id = if (y < decoded_delta.row_ids.len) decoded_delta.row_ids[y] else 0;

        if (row_cache.get(row_id)) |delta_row| {
            if (!std.mem.eql(u8, snapshot_row, delta_row)) {
                log.err("Row {d} (id={d}) MISMATCH:", .{ y, row_id });
                has_mismatch = true;
            }
        }
    }

    return has_mismatch;
}

const ShellDecodedSnapshot = struct {
    cells: []u8,
    cols: u16,
    rows: u16,
};

const ShellDecodedDelta = struct {
    dirty_rows: []ShellDirtyRow,
    row_ids: []u64,
};

const ShellDirtyRow = struct {
    id: u64,
    cells: []u8,
};

fn shellDecodeSnapshot(allocator: std.mem.Allocator, data: []const u8) !ShellDecodedSnapshot {
    const is_compressed = data[0] == 1;
    const payload = data[1..];

    var decompressed: []u8 = undefined;
    if (is_compressed) {
        decompressed = try shellDecompressSnappy(allocator, payload);
    } else {
        decompressed = try allocator.dupe(u8, payload);
    }
    defer allocator.free(decompressed);

    const cells = try shellExtractBinaryField(allocator, decompressed);

    return .{
        .cells = cells,
        .cols = 80,
        .rows = 24,
    };
}

fn shellDecodeDelta(allocator: std.mem.Allocator, data: []const u8) !ShellDecodedDelta {
    const is_compressed = data[0] == 1;
    const payload = data[1..];

    var decompressed: []u8 = undefined;
    if (is_compressed) {
        decompressed = try shellDecompressSnappy(allocator, payload);
    } else {
        decompressed = try allocator.dupe(u8, payload);
    }
    defer allocator.free(decompressed);

    var dirty_rows: std.ArrayListUnmanaged(ShellDirtyRow) = .{};
    errdefer {
        for (dirty_rows.items) |row| allocator.free(row.cells);
        dirty_rows.deinit(allocator);
    }

    try shellExtractDirtyRows(allocator, decompressed, &dirty_rows);
    const row_ids = try shellExtractRowIds(allocator, decompressed);

    return .{
        .dirty_rows = try dirty_rows.toOwnedSlice(allocator),
        .row_ids = row_ids,
    };
}

fn shellDecompressSnappy(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len < 1) return error.InvalidData;

    var length: u32 = 0;
    var shift: u5 = 0;
    var pos: usize = 0;
    while (pos < data.len) {
        const byte = data[pos];
        length |= @as(u32, @intCast(byte & 0x7F)) << shift;
        pos += 1;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }

    const compressed = data[pos..];
    var output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);

    var out_pos: usize = 0;
    var in_pos: usize = 0;

    while (in_pos < compressed.len and out_pos < length) {
        const tag = compressed[in_pos];
        in_pos += 1;

        const tag_type = tag & 0x03;

        if (tag_type == 0) {
            var lit_len: usize = @as(usize, tag >> 2) + 1;
            if (lit_len > 60) {
                const extra_bytes = lit_len - 60;
                lit_len = 1;
                for (0..extra_bytes) |i| {
                    lit_len += @as(usize, compressed[in_pos + i]) << @as(u5, @intCast(i * 8));
                }
                in_pos += extra_bytes;
            }
            @memcpy(output[out_pos .. out_pos + lit_len], compressed[in_pos .. in_pos + lit_len]);
            in_pos += lit_len;
            out_pos += lit_len;
        } else if (tag_type == 1) {
            const copy_len = @as(usize, (tag >> 2) & 0x07) + 4;
            const offset = @as(usize, (tag >> 5)) << 8 | @as(usize, compressed[in_pos]);
            in_pos += 1;
            for (0..copy_len) |i| {
                output[out_pos + i] = output[out_pos - offset + i];
            }
            out_pos += copy_len;
        } else if (tag_type == 2) {
            const copy_len = @as(usize, tag >> 2) + 1;
            const offset = @as(usize, compressed[in_pos]) | (@as(usize, compressed[in_pos + 1]) << 8);
            in_pos += 2;
            for (0..copy_len) |i| {
                output[out_pos + i] = output[out_pos - offset + i];
            }
            out_pos += copy_len;
        }
    }

    return output;
}

fn shellExtractBinaryField(allocator: std.mem.Allocator, msgpack: []const u8) ![]u8 {
    var largest_start: usize = 0;
    var largest_len: usize = 0;

    var i: usize = 0;
    while (i < msgpack.len) {
        if (msgpack[i] == 0xc4 and i + 2 < msgpack.len) {
            const len = msgpack[i + 1];
            if (len > largest_len and i + 2 + len <= msgpack.len) {
                largest_start = i + 2;
                largest_len = len;
            }
            i += 2 + len;
        } else if (msgpack[i] == 0xc5 and i + 3 < msgpack.len) {
            const len = @as(usize, msgpack[i + 1]) << 8 | @as(usize, msgpack[i + 2]);
            if (len > largest_len and i + 3 + len <= msgpack.len) {
                largest_start = i + 3;
                largest_len = len;
            }
            i += 3 + len;
        } else if (msgpack[i] == 0xc6 and i + 5 < msgpack.len) {
            const len = @as(usize, msgpack[i + 1]) << 24 | @as(usize, msgpack[i + 2]) << 16 |
                @as(usize, msgpack[i + 3]) << 8 | @as(usize, msgpack[i + 4]);
            if (len > largest_len and i + 5 + len <= msgpack.len) {
                largest_start = i + 5;
                largest_len = len;
            }
            i += 5 + len;
        } else {
            i += 1;
        }
    }

    if (largest_len == 0) return error.FieldNotFound;

    return try allocator.dupe(u8, msgpack[largest_start .. largest_start + largest_len]);
}

fn shellExtractDirtyRows(allocator: std.mem.Allocator, msgpack: []const u8, rows: *std.ArrayListUnmanaged(ShellDirtyRow)) !void {
    var i: usize = 0;
    while (i < msgpack.len) {
        if (msgpack[i] >= 0x90 and msgpack[i] <= 0x9f) {
            const arr_len = msgpack[i] & 0x0f;
            i += 1;

            for (0..arr_len) |_| {
                if (i >= msgpack.len) break;

                if (msgpack[i] >= 0x80 and msgpack[i] <= 0x8f) {
                    const map_len = msgpack[i] & 0x0f;
                    i += 1;

                    var row_id: u64 = 0;
                    var cells_data: ?[]const u8 = null;

                    for (0..map_len) |_| {
                        if (i >= msgpack.len) break;
                        if (msgpack[i] >= 0xa0 and msgpack[i] <= 0xbf) {
                            const key_len = msgpack[i] & 0x1f;
                            i += 1;
                            if (i + key_len > msgpack.len) break;
                            const key = msgpack[i .. i + key_len];
                            i += key_len;

                            if (std.mem.eql(u8, key, "id")) {
                                if (i < msgpack.len) {
                                    if (msgpack[i] <= 0x7f) {
                                        row_id = msgpack[i];
                                        i += 1;
                                    } else if (msgpack[i] == 0xcc) {
                                        row_id = msgpack[i + 1];
                                        i += 2;
                                    } else if (msgpack[i] == 0xcd) {
                                        row_id = @as(u64, msgpack[i + 1]) << 8 | msgpack[i + 2];
                                        i += 3;
                                    } else if (msgpack[i] == 0xce) {
                                        row_id = @as(u64, msgpack[i + 1]) << 24 | @as(u64, msgpack[i + 2]) << 16 |
                                            @as(u64, msgpack[i + 3]) << 8 | msgpack[i + 4];
                                        i += 5;
                                    } else if (msgpack[i] == 0xcf) {
                                        row_id = @as(u64, msgpack[i + 1]) << 56 | @as(u64, msgpack[i + 2]) << 48 |
                                            @as(u64, msgpack[i + 3]) << 40 | @as(u64, msgpack[i + 4]) << 32 |
                                            @as(u64, msgpack[i + 5]) << 24 | @as(u64, msgpack[i + 6]) << 16 |
                                            @as(u64, msgpack[i + 7]) << 8 | msgpack[i + 8];
                                        i += 9;
                                    }
                                }
                            } else if (std.mem.eql(u8, key, "cells")) {
                                if (i < msgpack.len) {
                                    if (msgpack[i] == 0xc4) {
                                        const len = msgpack[i + 1];
                                        cells_data = msgpack[i + 2 .. i + 2 + len];
                                        i += 2 + len;
                                    } else if (msgpack[i] == 0xc5) {
                                        const len = @as(usize, msgpack[i + 1]) << 8 | msgpack[i + 2];
                                        cells_data = msgpack[i + 3 .. i + 3 + len];
                                        i += 3 + len;
                                    } else if (msgpack[i] == 0xc6) {
                                        const len = @as(usize, msgpack[i + 1]) << 24 | @as(usize, msgpack[i + 2]) << 16 |
                                            @as(usize, msgpack[i + 3]) << 8 | msgpack[i + 4];
                                        cells_data = msgpack[i + 5 .. i + 5 + len];
                                        i += 5 + len;
                                    }
                                }
                            } else {
                                i = shellSkipMsgpackValue(msgpack, i);
                            }
                        } else {
                            break;
                        }
                    }

                    if (cells_data) |cells| {
                        try rows.append(allocator, .{
                            .id = row_id,
                            .cells = try allocator.dupe(u8, cells),
                        });
                    }
                } else {
                    i = shellSkipMsgpackValue(msgpack, i);
                }
            }
        } else {
            i += 1;
        }
    }
}

fn shellExtractRowIds(allocator: std.mem.Allocator, msgpack: []const u8) ![]u64 {
    var i: usize = 0;
    while (i < msgpack.len) {
        if (i + 7 < msgpack.len and msgpack[i] == 0xa6) {
            if (std.mem.eql(u8, msgpack[i + 1 .. i + 7], "rowIds")) {
                i += 7;
                if (i < msgpack.len) {
                    var bin_len: usize = 0;
                    var bin_start: usize = 0;
                    if (msgpack[i] == 0xc4) {
                        bin_len = msgpack[i + 1];
                        bin_start = i + 2;
                    } else if (msgpack[i] == 0xc5) {
                        bin_len = @as(usize, msgpack[i + 1]) << 8 | msgpack[i + 2];
                        bin_start = i + 3;
                    }

                    if (bin_len > 0 and bin_len % 8 == 0) {
                        const num_rows = bin_len / 8;
                        var row_ids = try allocator.alloc(u64, num_rows);
                        for (0..num_rows) |j| {
                            const offset = bin_start + j * 8;
                            row_ids[j] = @as(u64, msgpack[offset]) |
                                (@as(u64, msgpack[offset + 1]) << 8) |
                                (@as(u64, msgpack[offset + 2]) << 16) |
                                (@as(u64, msgpack[offset + 3]) << 24) |
                                (@as(u64, msgpack[offset + 4]) << 32) |
                                (@as(u64, msgpack[offset + 5]) << 40) |
                                (@as(u64, msgpack[offset + 6]) << 48) |
                                (@as(u64, msgpack[offset + 7]) << 56);
                        }
                        return row_ids;
                    }
                }
            }
        }
        i += 1;
    }

    return allocator.alloc(u64, 0);
}

fn shellSkipMsgpackValue(data: []const u8, start: usize) usize {
    if (start >= data.len) return data.len;

    const byte = data[start];

    if (byte <= 0x7f) return start + 1;
    if (byte >= 0x80 and byte <= 0x8f) {
        var pos = start + 1;
        const count = (byte & 0x0f) * 2;
        for (0..count) |_| {
            pos = shellSkipMsgpackValue(data, pos);
        }
        return pos;
    }
    if (byte >= 0x90 and byte <= 0x9f) {
        var pos = start + 1;
        const count = byte & 0x0f;
        for (0..count) |_| {
            pos = shellSkipMsgpackValue(data, pos);
        }
        return pos;
    }
    if (byte >= 0xa0 and byte <= 0xbf) {
        const len = byte & 0x1f;
        return start + 1 + len;
    }
    if (byte >= 0xc0 and byte <= 0xc3) return start + 1;
    if (byte == 0xc4) return start + 2 + data[start + 1];
    if (byte == 0xc5) return start + 3 + (@as(usize, data[start + 1]) << 8 | data[start + 2]);
    if (byte == 0xcc) return start + 2;
    if (byte == 0xcd) return start + 3;
    if (byte == 0xce) return start + 5;
    if (byte == 0xcf) return start + 9;
    if (byte == 0xd9) return start + 2 + data[start + 1];
    if (byte >= 0xe0) return start + 1;

    return start + 1;
}

// =============================================================================
// OSC 52 Clipboard Testers
// =============================================================================

// OSC 52 format:
// SET: ESC ] 52 ; <kind> ; <base64-data> BEL
// GET: ESC ] 52 ; <kind> ; ? BEL
// kind: 'c' (clipboard), 'p' (primary), 's' (selection)

const OSC_START = "\x1b]52;";
const OSC_END_BEL = "\x07";
const OSC_END_ST = "\x1b\\";

/// Send a few preset OSC 52 SET sequences to test clipboard functionality
fn runOsc52Set() !void {
    const stdout_fd = posix.STDOUT_FILENO;

    std.debug.print("OSC 52 SET Test - Sending clipboard sequences...\n\n", .{});

    // Test 1: Set clipboard 'c' with simple text
    const test1_text = "Hello from OSC 52!";
    const test1_b64 = "SGVsbG8gZnJvbSBPU0MgNTIh"; // base64 of "Hello from OSC 52!"
    std.debug.print("1. Setting clipboard 'c' to: \"{s}\"\n", .{test1_text});
    _ = posix.write(stdout_fd, OSC_START ++ "c;" ++ test1_b64 ++ OSC_END_BEL) catch {};
    std.debug.print("   Sent: ESC]52;c;<base64>BEL\n\n", .{});

    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Test 2: Set primary 'p' with different text
    const test2_text = "Primary selection test";
    const test2_b64 = "UHJpbWFyeSBzZWxlY3Rpb24gdGVzdA=="; // base64 of "Primary selection test"
    std.debug.print("2. Setting primary 'p' to: \"{s}\"\n", .{test2_text});
    _ = posix.write(stdout_fd, OSC_START ++ "p;" ++ test2_b64 ++ OSC_END_BEL) catch {};
    std.debug.print("   Sent: ESC]52;p;<base64>BEL\n\n", .{});

    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Test 3: Set clipboard with ST terminator instead of BEL
    const test3_text = "ST terminator test";
    const test3_b64 = "U1QgdGVybWluYXRvciB0ZXN0"; // base64 of "ST terminator test"
    std.debug.print("3. Setting clipboard 'c' with ST terminator: \"{s}\"\n", .{test3_text});
    _ = posix.write(stdout_fd, OSC_START ++ "c;" ++ test3_b64 ++ OSC_END_ST) catch {};
    std.debug.print("   Sent: ESC]52;c;<base64>ESC\\\n\n", .{});

    std.debug.print("Done! Check the ClipboardBar in the client.\n", .{});
    std.debug.print("Clipboard 'c' should show: \"{s}\"\n", .{test3_text});
    std.debug.print("Primary 'p' should show: \"{s}\"\n", .{test2_text});
}

/// Send OSC 52 GET sequences to request clipboard content
fn runOsc52Get() !void {
    const stdout_fd = posix.STDOUT_FILENO;

    std.debug.print("OSC 52 GET Test - Requesting clipboard content...\n\n", .{});

    // Request clipboard 'c'
    std.debug.print("1. Requesting clipboard 'c'...\n", .{});
    _ = posix.write(stdout_fd, OSC_START ++ "c;?" ++ OSC_END_BEL) catch {};
    std.debug.print("   Sent: ESC]52;c;?BEL\n", .{});
    std.debug.print("   (Response will be sent back as OSC 52 sequence)\n\n", .{});

    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Request primary 'p'
    std.debug.print("2. Requesting primary 'p'...\n", .{});
    _ = posix.write(stdout_fd, OSC_START ++ "p;?" ++ OSC_END_BEL) catch {};
    std.debug.print("   Sent: ESC]52;p;?BEL\n", .{});
    std.debug.print("   (Response will be sent back as OSC 52 sequence)\n\n", .{});

    std.debug.print("Done! The terminal should receive OSC 52 responses.\n", .{});
    std.debug.print("Note: The response data will be sent to the PTY as escape sequences.\n", .{});
}

/// Interactive OSC 52 tester - allows user to set/get clipboard interactively
fn runOsc52Interactive() !void {
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;

    std.debug.print("OSC 52 Interactive Clipboard Tester\n", .{});
    std.debug.print("====================================\n\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  sc <text>  - Set clipboard 'c' to <text>\n", .{});
    std.debug.print("  sp <text>  - Set primary 'p' to <text>\n", .{});
    std.debug.print("  gc         - Get clipboard 'c'\n", .{});
    std.debug.print("  gp         - Get primary 'p'\n", .{});
    std.debug.print("  q          - Quit\n\n", .{});

    var buf: [1024]u8 = undefined;

    while (true) {
        std.debug.print("> ", .{});

        const n = posix.read(stdin_fd, &buf) catch break;
        if (n == 0) break;

        // Trim trailing newline
        var input = buf[0..n];
        while (input.len > 0 and (input[input.len - 1] == '\n' or input[input.len - 1] == '\r')) {
            input = input[0 .. input.len - 1];
        }

        if (input.len == 0) continue;

        // Parse command
        if (std.mem.eql(u8, input, "q") or std.mem.eql(u8, input, "quit")) {
            std.debug.print("Bye!\n", .{});
            break;
        } else if (std.mem.eql(u8, input, "gc")) {
            std.debug.print("Requesting clipboard 'c'...\n", .{});
            _ = posix.write(stdout_fd, OSC_START ++ "c;?" ++ OSC_END_BEL) catch {};
        } else if (std.mem.eql(u8, input, "gp")) {
            std.debug.print("Requesting primary 'p'...\n", .{});
            _ = posix.write(stdout_fd, OSC_START ++ "p;?" ++ OSC_END_BEL) catch {};
        } else if (std.mem.startsWith(u8, input, "sc ")) {
            const text = input[3..];
            if (text.len > 0) {
                osc52SetClipboard(stdout_fd, 'c', text);
                std.debug.print("Set clipboard 'c' to: \"{s}\"\n", .{text});
            } else {
                std.debug.print("Usage: sc <text>\n", .{});
            }
        } else if (std.mem.startsWith(u8, input, "sp ")) {
            const text = input[3..];
            if (text.len > 0) {
                osc52SetClipboard(stdout_fd, 'p', text);
                std.debug.print("Set primary 'p' to: \"{s}\"\n", .{text});
            } else {
                std.debug.print("Usage: sp <text>\n", .{});
            }
        } else {
            std.debug.print("Unknown command: {s}\n", .{input});
            std.debug.print("Use 'sc <text>', 'sp <text>', 'gc', 'gp', or 'q'\n", .{});
        }
    }
}

/// Helper to send OSC 52 SET with runtime base64 encoding
fn osc52SetClipboard(fd: posix.fd_t, kind: u8, text: []const u8) void {
    // Build OSC 52 SET sequence with base64-encoded text
    var out_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const w = fbs.writer();

    // ESC ] 52 ; <kind> ;
    w.writeAll("\x1b]52;") catch return;
    w.writeByte(kind) catch return;
    w.writeByte(';') catch return;

    // Base64 encode the text
    const b64_len = std.base64.standard.Encoder.calcSize(text.len);
    if (b64_len > 1500) {
        std.debug.print("Text too long for buffer\n", .{});
        return;
    }

    var b64_buf: [1500]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64_buf, text);
    w.writeAll(b64_buf[0..b64_len]) catch return;

    // BEL terminator
    w.writeByte(0x07) catch return;

    _ = posix.write(fd, fbs.getWritten()) catch {};
}

// =============================================================================
// Grapheme Cluster Tester
// =============================================================================

/// Display various grapheme clusters to test Unicode rendering
fn runGraphemeTest() void {
    const stdout_fd = posix.STDOUT_FILENO;

    const output =
        \\
        \\Grapheme Cluster Test
        \\=====================
        \\
        \\This test displays various Unicode grapheme clusters.
        \\Each grapheme should render as a single character.
        \\
        \\1. EMOJI WITH SKIN TONE MODIFIERS
        \\   👍       (thumbs up)
        \\   👍🏻      (thumbs up, light skin)
        \\   👍🏼      (thumbs up, medium-light skin)
        \\   👍🏽      (thumbs up, medium skin)
        \\   👍🏾      (thumbs up, medium-dark skin)
        \\   👍🏿      (thumbs up, dark skin)
        \\
        \\2. FAMILY EMOJI (ZWJ SEQUENCES)
        \\   👨‍👩‍👧     (family: man, woman, girl)
        \\   👨‍👩‍👧‍👦    (family: man, woman, girl, boy)
        \\   👩‍👩‍👦‍👦    (family: woman, woman, boy, boy)
        \\   👨‍👨‍👧‍👧    (family: man, man, girl, girl)
        \\
        \\3. PROFESSION EMOJI (ZWJ SEQUENCES)
        \\   👨‍💻      (man technologist)
        \\   👩‍💻      (woman technologist)
        \\   👨‍🚀      (man astronaut)
        \\   👩‍🚀      (woman astronaut)
        \\   👨‍🍳      (man cook)
        \\   👩‍🍳      (woman cook)
        \\
        \\4. FLAG EMOJI (REGIONAL INDICATORS)
        \\   🇺🇸      (United States)
        \\   🇬🇧      (United Kingdom)
        \\   🇯🇵      (Japan)
        \\   🇩🇪      (Germany)
        \\   🇫🇷      (France)
        \\
        \\5. COMBINING MARKS (DIACRITICS)
        \\   é        (e + combining acute accent, precomposed)
        \\   é       (e + combining acute accent, decomposed - U+0065 U+0301)
        \\   ñ        (n + combining tilde, precomposed)
        \\   ñ       (n + combining tilde, decomposed - U+006E U+0303)
        \\   ü        (u + combining diaeresis, precomposed)
        \\   ü       (u + combining diaeresis, decomposed - U+0075 U+0308)
        \\
        \\6. COMBINING MARKS (STACKED)
        \\   ệ        (e + circumflex + dot below)
        \\   ǭ        (o + macron + ogonek)
        \\
        \\7. EMOJI VARIATIONS
        \\   ❤️       (red heart)
        \\   ❤️‍🔥      (heart on fire)
        \\   ❤️‍🩹      (mending heart)
        \\   ☀️       (sun with rays)
        \\   ⭐       (star)
        \\
        \\8. KEYCAP SEQUENCES
        \\   1️⃣       (keycap 1)
        \\   2️⃣       (keycap 2)
        \\   #️⃣       (keycap #)
        \\   *️⃣       (keycap *)
        \\
        \\9. WIDE CHARACTERS (CJK)
        \\   日本語    (Japanese)
        \\   中文     (Chinese)
        \\   한국어    (Korean)
        \\
        \\10. MIXED WIDTH LINE
        \\    Hello世界🌍Test
        \\    ^^^^^|^^|^|^^^^
        \\    (each ^ marks a cell, | marks wide char boundaries)
        \\
        \\Test complete!
        \\
    ;

    _ = posix.write(stdout_fd, output) catch {};
}

// =============================================================================
// Grapheme Debug Tester
// =============================================================================

/// Debug grapheme cluster detection by feeding emoji through the VT emulator
fn runGraphemeDebug(allocator: std.mem.Allocator) !void {
    std.debug.print("\nGrapheme Debug Test\n", .{});
    std.debug.print("===================\n\n", .{});
    std.debug.print("Feeding emoji through VT emulator and inspecting grapheme data...\n\n", .{});

    // Create a pane (which includes a ghostty terminal)
    var pane = try Pane.init(allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    // Test cases: each is a name and UTF-8 bytes to feed
    const TestCase = struct {
        name: []const u8,
        input: []const u8,
        expected_graphemes: usize, // How many extra codepoints we expect
    };

    const test_cases = [_]TestCase{
        // Skin tone modifier (should have 1 extra codepoint)
        .{ .name = "Thumbs up + skin tone", .input = "👍🏻", .expected_graphemes = 1 },
        // Family emoji (ZWJ sequence - 6 extra codepoints: ZWJ, woman, ZWJ, girl, ZWJ, boy)
        .{ .name = "Family emoji", .input = "👨‍👩‍👧‍👦", .expected_graphemes = 6 },
        // Man technologist (ZWJ sequence - 2 extra: ZWJ, laptop)
        .{ .name = "Man technologist", .input = "👨‍💻", .expected_graphemes = 2 },
        // Flag emoji (2 regional indicators)
        .{ .name = "US Flag", .input = "🇺🇸", .expected_graphemes = 1 },
        // Red heart with variation selector
        .{ .name = "Red heart (VS16)", .input = "❤️", .expected_graphemes = 1 },
        // Heart on fire (ZWJ)
        .{ .name = "Heart on fire", .input = "❤️‍🔥", .expected_graphemes = 3 },
        // Simple combining mark (decomposed é)
        .{ .name = "e + acute (NFD)", .input = "e\xCC\x81", .expected_graphemes = 1 },
        // Keycap
        .{ .name = "Keycap 1", .input = "1️⃣", .expected_graphemes = 2 },
    };

    for (test_cases) |tc| {
        // Clear and feed the input
        try pane.feed("\x1b[2J\x1b[H"); // Clear screen, home cursor
        try pane.feed(tc.input);
        try pane.feed("\n"); // Newline to make sure it's processed

        // Get the terminal pages
        const pages = &pane.terminal.screens.active.pages;

        std.debug.print("Test: {s}\n", .{tc.name});
        std.debug.print("  Input bytes: ", .{});
        for (tc.input) |b| {
            std.debug.print("{x:0>2} ", .{b});
        }
        std.debug.print("\n", .{});

        // Check first row for grapheme data
        var grapheme_count: usize = 0;
        var found_grapheme_cell = false;

        // Get first row via pin
        if (pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } })) |row_pin| {
            const page = &row_pin.node.data;
            const cells = row_pin.cells(.all);

            for (0..cells.len) |col_idx| {
                const cell = &cells[col_idx]; // Get pointer to actual cell in page memory
                // Skip empty cells
                if (cell.codepoint() == 0 or cell.codepoint() == ' ') continue;

                const has_grapheme = cell.hasGrapheme();
                const cp = cell.codepoint();

                std.debug.print("  Cell[{d}]: U+{X:0>4}", .{ col_idx, cp });

                if (has_grapheme) {
                    found_grapheme_cell = true;
                    if (page.lookupGrapheme(cell)) |extra_cps| {
                        grapheme_count = extra_cps.len;
                        std.debug.print(" + grapheme({d}): ", .{extra_cps.len});
                        for (extra_cps) |extra_cp| {
                            std.debug.print("U+{X:0>4} ", .{extra_cp});
                        }
                    } else {
                        std.debug.print(" (hasGrapheme but no data!)", .{});
                    }
                }
                std.debug.print("\n", .{});
            }
        }

        const status = if (grapheme_count == tc.expected_graphemes)
            "✓ PASS"
        else if (found_grapheme_cell)
            "~ PARTIAL"
        else
            "✗ FAIL";

        std.debug.print("  Result: {s} (found {d} extra codepoints, expected {d})\n\n", .{
            status,
            grapheme_count,
            tc.expected_graphemes,
        });
    }

    std.debug.print("Debug complete!\n", .{});
}

// =============================================================================
// Hyperlink (OSC 8) Tester
// =============================================================================

/// Display OSC 8 hyperlinks to test clickable link rendering
fn runHyperlinkTest() void {
    const stdout_fd = posix.STDOUT_FILENO;

    // OSC 8 format: ESC ] 8 ; params ; URI BEL text ESC ] 8 ; ; BEL
    // params can include id=xxx for link grouping
    const ESC = "\x1b";
    const BEL = "\x07";
    const OSC8_START = ESC ++ "]8;;";
    const OSC8_END = ESC ++ "]8;;" ++ BEL;

    _ = posix.write(stdout_fd,
        \\
        \\OSC 8 Hyperlink Test
        \\====================
        \\
        \\This test displays clickable hyperlinks using OSC 8 escape sequences.
        \\Hover over links to see the URL, click to open.
        \\
        \\1. BASIC HTTPS LINKS
        \\
    ) catch {};

    // Link 1: Basic HTTPS
    _ = posix.write(stdout_fd, OSC8_START ++ "https://example.com" ++ BEL ++ "Click here for example.com" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, "\n   ") catch {};

    // Link 2: Another HTTPS link
    _ = posix.write(stdout_fd, OSC8_START ++ "https://github.com" ++ BEL ++ "GitHub" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, " | ") catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "https://google.com" ++ BEL ++ "Google" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, " | ") catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "https://anthropic.com" ++ BEL ++ "Anthropic" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\2. HTTP LINKS (unsecured)
        \\
    ) catch {};

    _ = posix.write(stdout_fd, OSC8_START ++ "http://example.org" ++ BEL ++ "HTTP link (example.org)" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\3. MAILTO LINKS
        \\
    ) catch {};

    _ = posix.write(stdout_fd, OSC8_START ++ "mailto:test@example.com" ++ BEL ++ "test@example.com" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, "\n   ") catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "mailto:support@example.com?subject=Hello" ++ BEL ++ "Email with subject" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\4. TEL LINKS
        \\
    ) catch {};

    _ = posix.write(stdout_fd, OSC8_START ++ "tel:+1-555-123-4567" ++ BEL ++ "+1 (555) 123-4567" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\5. FILE LINKS (local)
        \\
    ) catch {};

    _ = posix.write(stdout_fd, OSC8_START ++ "file:///tmp/test.txt" ++ BEL ++ "/tmp/test.txt" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\6. LINKS WITH SPECIAL CHARACTERS
        \\
    ) catch {};

    _ = posix.write(stdout_fd, OSC8_START ++ "https://example.com/path?query=hello%20world&foo=bar" ++ BEL ++ "URL with query params" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, "\n   ") catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "https://example.com/path#section" ++ BEL ++ "URL with anchor" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\7. LINK WITH ID PARAMETER (for grouping)
        \\
    ) catch {};

    // Link with id parameter
    _ = posix.write(stdout_fd, ESC ++ "]8;id=link1;https://example.com" ++ BEL ++ "Grouped link 1" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, " | ") catch {};
    _ = posix.write(stdout_fd, ESC ++ "]8;id=link1;https://example.com" ++ BEL ++ "Same link group" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\8. LINK IN COLORED TEXT
        \\
    ) catch {};

    _ = posix.write(stdout_fd, "\x1b[31m") catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "https://example.com/red" ++ BEL ++ "Red link" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, "\x1b[0m | \x1b[32m") catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "https://example.com/green" ++ BEL ++ "Green link" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, "\x1b[0m | \x1b[34m") catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "https://example.com/blue" ++ BEL ++ "Blue link" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, "\x1b[0m") catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\9. ADJACENT LINKS
        \\
    ) catch {};

    _ = posix.write(stdout_fd, OSC8_START ++ "https://a.com" ++ BEL ++ "AAA" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "https://b.com" ++ BEL ++ "BBB" ++ OSC8_END) catch {};
    _ = posix.write(stdout_fd, OSC8_START ++ "https://c.com" ++ BEL ++ "CCC" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\10. LONG URL
        \\
    ) catch {};

    _ = posix.write(stdout_fd, OSC8_START ++ "https://example.com/this/is/a/very/long/path/that/might/wrap/across/multiple/lines/in/the/terminal" ++ BEL ++ "Very long URL path" ++ OSC8_END) catch {};

    _ = posix.write(stdout_fd,
        \\
        \\
        \\Test complete!
        \\
        \\Note: Links should be underlined and clickable. Unsupported protocols
        \\(file://, javascript:, etc.) may be blocked by the client for security.
        \\
    ) catch {};
}

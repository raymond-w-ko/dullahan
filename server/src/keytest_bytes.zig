//! Byte Coverage Tester
//!
//! Shows all 256 possible bytes (0x00-0xFF) and lights them up when received.
//! Goal: Verify every byte can be input through the terminal.
//!
//! Layout: 8 bytes per row, 32 rows
//! Format: "XX:key" where XX is hex, key is hint
//! Gray = not yet received, Blue = received

const std = @import("std");
const posix = std.posix;

// ANSI codes
const RESET = "\x1b[0m";
const BLUE = "\x1b[34;1m";
const DIM = "\x1b[2m";
const CLEAR = "\x1b[2J\x1b[H";
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";

// Track which bytes have been received
var received: [256]bool = [_]bool{false} ** 256;
var running = true;
var total_received: u16 = 0;

// Key hints for each byte
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
    // 0x80-0xFF (extended - typically not directly inputtable)
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

pub fn main() !void {
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;

    // Set raw mode
    const original = try posix.tcgetattr(stdin_fd);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false; // Disable Ctrl+S/Ctrl+Q flow control
    raw.iflag.ICRNL = false; // Don't translate CR to NL
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(stdin_fd, .NOW, raw);
    defer posix.tcsetattr(stdin_fd, .NOW, original) catch {};

    _ = posix.write(stdout_fd, HIDE_CURSOR) catch {};
    defer _ = posix.write(stdout_fd, SHOW_CURSOR) catch {};

    render(stdout_fd);

    var buf: [64]u8 = undefined;
    while (running) {
        const n = posix.read(stdin_fd, &buf) catch break;
        if (n == 0) break;

        // Mark each received byte
        for (buf[0..n]) |b| {
            if (!received[b]) {
                received[b] = true;
                total_received += 1;
            }
        }

        // Quit on 'q' or after receiving most bytes
        if (buf[0] == 'q' or buf[0] == 'Q') {
            running = false;
        }

        render(stdout_fd);
    }
}

fn render(fd: posix.fd_t) void {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll(CLEAR) catch {};
    w.writeAll("Byte Coverage Tester") catch {};
    std.fmt.format(w, " ({d}/256 received, press 'q' to quit)\n\n", .{total_received}) catch {};

    // 8 bytes per row, 32 rows
    // Format: "XX:kkk " = 7-8 chars, pad to 10 for alignment
    var byte: u16 = 0;
    while (byte < 256) : (byte += 1) {
        const b: u8 = @intCast(byte);
        const hint = key_hints[b];
        
        if (received[b]) {
            w.writeAll(BLUE) catch {};
        } else {
            w.writeAll(DIM) catch {};
        }
        
        std.fmt.format(w, "{X:0>2}:{s:<3}", .{ b, hint }) catch {};
        w.writeAll(RESET) catch {};
        
        // 8 per row
        if ((byte + 1) % 8 == 0) {
            w.writeAll("\n") catch {};
        } else {
            w.writeAll("  ") catch {};
        }
    }

    w.writeAll("\n") catch {};
    
    // Show last few bytes received
    w.writeAll(DIM ++ "Note: ^X = Ctrl+X, Esc sequences count as multiple bytes\n" ++ RESET) catch {};
    w.writeAll(DIM ++ "      0x80-0xFF typically need special input methods\n" ++ RESET) catch {};

    _ = posix.write(fd, fbs.getWritten()) catch {};
}

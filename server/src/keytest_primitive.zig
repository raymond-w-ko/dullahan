//! Primitive Key Tester
//!
//! Tests legacy/VT keyboard input. Shows each key press with visual feedback.
//! Keys light up blue when pressed. Press 'q' or Ctrl+C to exit.

const std = @import("std");
const posix = std.posix;

// ANSI color codes
const RESET = "\x1b[0m";
const BLUE = "\x1b[34m";
const GREEN = "\x1b[32m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const CLEAR_SCREEN = "\x1b[2J\x1b[H";
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";

const KeyState = struct {
    name: []const u8,
    pressed: bool = false,
    raw: ?[]const u8 = null,
};

var running = true;
var keys: std.StringHashMapUnmanaged(KeyState) = .{};
var key_order: std.ArrayListUnmanaged([]const u8) = .{};
var last_raw: [64]u8 = undefined;
var last_raw_len: usize = 0;
var alloc: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    alloc = gpa.allocator();

    defer keys.deinit(alloc);
    defer key_order.deinit(alloc);

    // Set terminal to raw mode
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;
    const original_termios = try posix.tcgetattr(stdin_fd);
    var raw = original_termios;
    
    // Set raw mode - disable ALL special character handling
    raw.lflag.ICANON = false;  // Disable line buffering
    raw.lflag.ECHO = false;    // Disable echo
    raw.lflag.ISIG = false;    // Disable Ctrl+C, Ctrl+Z, Ctrl+\ signals
    raw.lflag.IEXTEN = false;  // Disable Ctrl+V, Ctrl+O (DISCARD)
    raw.iflag.IXON = false;    // Disable Ctrl+S/Ctrl+Q flow control
    raw.iflag.ICRNL = false;   // Don't translate CR to NL
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    
    try posix.tcsetattr(stdin_fd, .NOW, raw);
    defer posix.tcsetattr(stdin_fd, .NOW, original_termios) catch {};

    _ = posix.write(stdout_fd, HIDE_CURSOR) catch {};
    defer _ = posix.write(stdout_fd, SHOW_CURSOR) catch {};

    try render(stdout_fd);

    var buf: [32]u8 = undefined;
    while (running) {
        const n = posix.read(stdin_fd, &buf) catch break;
        if (n == 0) break;

        // Save raw bytes for display
        last_raw_len = @min(n, last_raw.len);
        @memcpy(last_raw[0..last_raw_len], buf[0..last_raw_len]);

        // Parse and record key
        const key_name = parseKey(buf[0..n]);
        try recordKey(key_name);

        // Check for quit
        if (std.mem.eql(u8, key_name, "q") or std.mem.eql(u8, key_name, "Ctrl+C")) {
            running = false;
        }

        try render(stdout_fd);
    }
}

fn parseKey(buf: []const u8) []const u8 {
    if (buf.len == 0) return "???";

    // Single character
    if (buf.len == 1) {
        const c = buf[0];
        return switch (c) {
            0x00 => "Ctrl+@",
            0x01...0x1a => blk: {
                const names = [_][]const u8{
                    "Ctrl+A", "Ctrl+B", "Ctrl+C", "Ctrl+D", "Ctrl+E", "Ctrl+F", "Ctrl+G",
                    "Ctrl+H", "Tab", "Ctrl+J", "Ctrl+K", "Ctrl+L", "Enter", "Ctrl+N",
                    "Ctrl+O", "Ctrl+P", "Ctrl+Q", "Ctrl+R", "Ctrl+S", "Ctrl+T", "Ctrl+U",
                    "Ctrl+V", "Ctrl+W", "Ctrl+X", "Ctrl+Y", "Ctrl+Z",
                };
                break :blk names[c - 1];
            },
            0x1b => "Escape",
            0x1c => "Ctrl+\\",
            0x1d => "Ctrl+]",
            0x1e => "Ctrl+^",
            0x1f => "Ctrl+_",
            0x7f => "Backspace",
            ' ' => "Space",
            '!'...'~' => blk: {
                const s = @as(*const [1]u8, @ptrCast(&c));
                break :blk s;
            },
            else => "???",
        };
    }

    // Escape sequences
    if (buf[0] == 0x1b) {
        if (buf.len >= 2 and buf[1] == '[') {
            // CSI sequence
            
            // Check for CSI u (Kitty protocol) - modern terminals send this
            // Format: CSI codepoint ; modifiers u
            if (buf[buf.len - 1] == 'u') {
                return parseCSIu(buf[2 .. buf.len - 1]);
            }
            
            if (buf.len == 3) {
                return switch (buf[2]) {
                    'A' => "Up",
                    'B' => "Down",
                    'C' => "Right",
                    'D' => "Left",
                    'H' => "Home",
                    'F' => "End",
                    'Z' => "Shift+Tab",
                    else => "CSI+?",
                };
            }
            if (buf.len >= 4 and buf[buf.len - 1] == '~') {
                // CSI n ~
                const n = std.fmt.parseInt(u8, buf[2 .. buf.len - 1], 10) catch return "CSI~?";
                return switch (n) {
                    1 => "Home",
                    2 => "Insert",
                    3 => "Delete",
                    4 => "End",
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
            // CSI with modifiers (e.g., CSI 1;5A = Ctrl+Up)
            if (buf.len >= 6 and buf[2] == '1' and buf[3] == ';') {
                const mod = buf[4] - '0';
                const arrow = buf[5];
                const mod_str = switch (mod) {
                    2 => "Shift+",
                    3 => "Alt+",
                    4 => "Shift+Alt+",
                    5 => "Ctrl+",
                    6 => "Ctrl+Shift+",
                    7 => "Ctrl+Alt+",
                    8 => "Ctrl+Shift+Alt+",
                    else => "",
                };
                const arrow_str = switch (arrow) {
                    'A' => "Up",
                    'B' => "Down",
                    'C' => "Right",
                    'D' => "Left",
                    'H' => "Home",
                    'F' => "End",
                    else => "?",
                };
                _ = mod_str;
                _ = arrow_str;
                return "Mod+Arrow";
            }
        }
        if (buf.len >= 2 and buf[1] == 'O') {
            // SS3 sequence (F1-F4)
            if (buf.len == 3) {
                return switch (buf[2]) {
                    'P' => "F1",
                    'Q' => "F2",
                    'R' => "F3",
                    'S' => "F4",
                    else => "SS3+?",
                };
            }
        }
        // Alt + key
        if (buf.len == 2 and buf[1] >= 0x20 and buf[1] < 0x7f) {
            return "Alt+key";
        }
    }

    return "???";
}

/// Parse CSI u sequence (Kitty protocol)
/// Format: codepoint ; modifiers  (without CSI prefix and 'u' suffix)
fn parseCSIu(params: []const u8) []const u8 {
    // Split on semicolon
    var codepoint_end: usize = params.len;
    var modifiers: u8 = 1; // Default: no modifiers (1 = base)
    
    for (params, 0..) |c, i| {
        if (c == ';') {
            codepoint_end = i;
            if (i + 1 < params.len) {
                modifiers = std.fmt.parseInt(u8, params[i + 1 ..], 10) catch 1;
            }
            break;
        }
    }
    
    const codepoint = std.fmt.parseInt(u21, params[0..codepoint_end], 10) catch return "CSI-u?";
    
    // Build modifier prefix
    const mod_prefix: []const u8 = switch (modifiers) {
        1 => "",           // No modifiers
        2 => "Shift+",
        3 => "Alt+",
        4 => "Shift+Alt+",
        5 => "Ctrl+",
        6 => "Ctrl+Shift+",
        7 => "Ctrl+Alt+",
        8 => "Ctrl+Shift+Alt+",
        9 => "Super+",
        else => "Mod+",
    };
    
    // Get key name from codepoint
    const key_name: []const u8 = switch (codepoint) {
        // Special keys (Kitty functional key codepoints)
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
        // Standard ASCII
        9 => "Tab",
        13 => "Enter",
        27 => "Escape",
        32 => "Space",
        127 => "Backspace",
        // Printable ASCII with modifiers
        else => blk: {
            if (codepoint >= 'a' and codepoint <= 'z') {
                // Return combined name for modified letters
                if (mod_prefix.len > 0) {
                    // Static buffer for combined names
                    const names = [_][]const u8{
                        "Ctrl+A", "Ctrl+B", "Ctrl+C", "Ctrl+D", "Ctrl+E", "Ctrl+F", "Ctrl+G",
                        "Ctrl+H", "Ctrl+I", "Ctrl+J", "Ctrl+K", "Ctrl+L", "Ctrl+M", "Ctrl+N",
                        "Ctrl+O", "Ctrl+P", "Ctrl+Q", "Ctrl+R", "Ctrl+S", "Ctrl+T", "Ctrl+U",
                        "Ctrl+V", "Ctrl+W", "Ctrl+X", "Ctrl+Y", "Ctrl+Z",
                    };
                    if (modifiers == 5) { // Ctrl
                        break :blk names[codepoint - 'a'];
                    }
                }
                const s = @as(*const [1]u8, @ptrCast(&@as(u8, @intCast(codepoint))));
                break :blk s;
            }
            if (codepoint >= 'A' and codepoint <= 'Z') {
                const s = @as(*const [1]u8, @ptrCast(&@as(u8, @intCast(codepoint))));
                break :blk s;
            }
            if (codepoint >= '!' and codepoint <= '~') {
                const s = @as(*const [1]u8, @ptrCast(&@as(u8, @intCast(codepoint))));
                break :blk s;
            }
            break :blk "???";
        },
    };
    
    // For simple cases without prefix, just return the key name
    if (mod_prefix.len == 0) {
        return key_name;
    }
    
    return key_name;
}

fn recordKey(name: []const u8) !void {
    if (keys.get(name)) |_| {
        // Already exists, just mark as pressed again
        try keys.put(alloc, name, .{ .name = name, .pressed = true });
    } else {
        // New key
        const owned_name = try alloc.dupe(u8, name);
        try keys.put(alloc, owned_name, .{ .name = owned_name, .pressed = true });
        try key_order.append(alloc, owned_name);
    }
}

fn render(fd: posix.fd_t) !void {
    var out_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const w = fbs.writer();

    w.writeAll(CLEAR_SCREEN) catch {};
    w.writeAll(BOLD ++ "Primitive Key Tester" ++ RESET ++ " (press 'q' or Ctrl+C to exit)\n\n") catch {};

    // Show last raw bytes
    w.writeAll("Raw: ") catch {};
    if (last_raw_len > 0) {
        w.writeAll(DIM) catch {};
        for (last_raw[0..last_raw_len]) |b| {
            std.fmt.format(w, "0x{x:0>2} ", .{b}) catch {};
        }
        w.writeAll(RESET) catch {};
    }
    w.writeAll("\n\n") catch {};

    // Show keys
    w.writeAll("Keys pressed:\n") catch {};
    for (key_order.items) |name| {
        if (keys.get(name)) |state| {
            if (state.pressed) {
                w.writeAll("  " ++ BLUE ++ BOLD) catch {};
                w.writeAll(name) catch {};
                w.writeAll(RESET ++ " ↓\n") catch {};
            } else {
                w.writeAll("  " ++ DIM) catch {};
                w.writeAll(name) catch {};
                w.writeAll(RESET ++ "\n") catch {};
            }
        }
    }

    w.writeAll("\n" ++ DIM ++ "Note: Legacy mode - no key release detection" ++ RESET ++ "\n") catch {};

    _ = posix.write(fd, fbs.getWritten()) catch {};
}

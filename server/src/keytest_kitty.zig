//! Kitty Keyboard Protocol Tester
//!
//! Tests Kitty keyboard protocol with key press/release events.
//! Shows each key with down (↓) and up (↑) arrows that light up.
//!
//! Colors:
//!   - Key name: normal → blue when held
//!   - Down arrow (↓): dim → green when pressed
//!   - Up arrow (↑): dim → blue when released
//!
//! When a key completes full cycle (down + up), it fades out.
//! Press Escape twice to exit.

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

// Kitty keyboard protocol
// CSI > flags u - push mode with flags
// flags: 1=disambiguate, 2=report event types, 4=report alternate keys, 8=report all keys, 16=report text
// Using flags 1+2+8 = 11 to get all keys including arrows as CSI u sequences
const KITTY_ENABLE = "\x1b[>11u"; // disambiguate + report events + report all keys
const KITTY_DISABLE = "\x1b[<u";

// Log file for debugging
var log_file: ?std.fs.File = null;

const KeyState = struct {
    codepoint: u21,
    name: []const u8,
    down: bool = false,
    up: bool = false,
    timestamp: i64 = 0,
};

var running = true;
var keys: std.AutoHashMapUnmanaged(u21, KeyState) = .{};
var key_order: std.ArrayListUnmanaged(u21) = .{};
var last_raw: [64]u8 = undefined;
var last_raw_len: usize = 0;
var escape_count: u8 = 0;
var alloc: std.mem.Allocator = undefined;
var owned_strings: std.ArrayListUnmanaged([]const u8) = .{};

fn log(comptime fmt: []const u8, args: anytype) void {
    if (log_file) |f| {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = f.write(msg) catch {};
        _ = f.write("\n") catch {};
    }
}

fn logBytes(prefix: []const u8, bytes: []const u8) void {
    if (log_file) |f| {
        _ = f.write(prefix) catch {};
        var buf: [8]u8 = undefined;
        for (bytes) |b| {
            const hex = std.fmt.bufPrint(&buf, " 0x{x:0>2}", .{b}) catch continue;
            _ = f.write(hex) catch {};
        }
        _ = f.write("\n") catch {};
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    alloc = gpa.allocator();

    defer keys.deinit(alloc);
    defer key_order.deinit(alloc);
    defer {
        for (owned_strings.items) |s| alloc.free(s);
        owned_strings.deinit(alloc);
    }

    // Open log file
    log_file = std.fs.cwd().createFile("/tmp/keytest-kitty.log", .{ .truncate = true }) catch null;
    defer if (log_file) |f| f.close();
    
    log("=== Kitty Keyboard Tester started ===", .{});
    logBytes("Kitty enable sequence:", KITTY_ENABLE);

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

    // Enable Kitty keyboard protocol
    _ = posix.write(stdout_fd, KITTY_ENABLE) catch {};
    defer _ = posix.write(stdout_fd, KITTY_DISABLE) catch {};

    _ = posix.write(stdout_fd, HIDE_CURSOR) catch {};
    defer _ = posix.write(stdout_fd, SHOW_CURSOR) catch {};

    try render(stdout_fd);

    var buf: [64]u8 = undefined;
    while (running) {
        const n = posix.read(stdin_fd, &buf) catch break;
        if (n == 0) break;

        // Save raw bytes for display
        last_raw_len = @min(n, last_raw.len);
        @memcpy(last_raw[0..last_raw_len], buf[0..last_raw_len]);

        // Log raw bytes
        logBytes("Raw input:", buf[0..n]);

        // Parse Kitty protocol or legacy
        try parseInput(buf[0..n]);

        // Remove completed keys (both down and up received)
        try pruneCompletedKeys();

        try render(stdout_fd);
    }
}

fn parseInput(buf: []const u8) !void {
    if (buf.len == 0) return;

    // Check for CSI sequence
    if (buf.len >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        const last_byte = buf[buf.len - 1];
        
        // CSI u sequence (Kitty protocol)
        if (last_byte == 'u') {
            const params = buf[2 .. buf.len - 1];
            log("CSI u sequence, params: {s}", .{params});
            try parseKittySequence(params);
            return;
        }
        
        // CSI ~ sequence (legacy function keys, but Kitty sends these too)
        if (last_byte == '~') {
            const params = buf[2 .. buf.len - 1];
            log("CSI ~ sequence, params: {s}", .{params});
            try parseLegacyFunction(params);
            return;
        }
        
        // Legacy CSI sequences (arrows) - fallback if Kitty not fully enabled
        if (buf.len == 3) {
            log("Legacy CSI sequence: {c}", .{buf[2]});
            const key_cp: ?u21 = switch (buf[2]) {
                'A' => 57352, // Up - use Kitty codepoints for consistency
                'B' => 57353, // Down
                'C' => 57351, // Right
                'D' => 57350, // Left
                'H' => 57356, // Home
                'F' => 57357, // End
                else => null,
            };
            if (key_cp) |cp| {
                const name = switch (buf[2]) {
                    'A' => "Up",
                    'B' => "Down", 
                    'C' => "Right",
                    'D' => "Left",
                    'H' => "Home",
                    'F' => "End",
                    else => "?",
                };
                try recordKey(cp, name, .press);
            }
            return;
        }
        
        // Other CSI sequences - log for debugging
        log("Unknown CSI sequence, terminator: 0x{x:0>2}", .{last_byte});
    }

    // Single escape (legacy mode fallback)
    if (buf.len == 1 and buf[0] == 0x1b) {
        try recordKey(0x1b, "Escape", .press);
        return;
    }

    // Single printable character
    if (buf.len == 1) {
        const c = buf[0];
        if (c >= 0x20 and c < 0x7f) {
            const name = try alloc.dupe(u8, &[_]u8{c});
            try owned_strings.append(alloc, name);
            try recordKey(c, name, .press);
        } else if (c == 0x0d) {
            try recordKey(c, "Enter", .press);
        } else if (c == 0x7f) {
            try recordKey(c, "Backspace", .press);
        } else if (c == 0x09) {
            try recordKey(c, "Tab", .press);
        } else if (c >= 0x01 and c <= 0x1a) {
            // Ctrl+letter
            const letter: u8 = 'A' + c - 1;
            const name = try std.fmt.allocPrint(alloc, "Ctrl+{c}", .{letter});
            try owned_strings.append(alloc, name);
            try recordKey(c, name, .press);
        }
    }

    // UTF-8 multi-byte
    if (buf.len > 1 and buf[0] >= 0xc0) {
        const cp = std.unicode.utf8Decode(buf) catch return;
        var name_buf: [8]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &name_buf) catch return;
        const name = try alloc.dupe(u8, name_buf[0..len]);
        try owned_strings.append(alloc, name);
        try recordKey(cp, name, .press);
    }
}

const EventType = enum { press, repeat, release };

fn parseLegacyFunction(params: []const u8) !void {
    // Format: number ~ or number;modifiers ~
    var num_end: usize = params.len;
    for (params, 0..) |c, i| {
        if (c == ';') {
            num_end = i;
            break;
        }
    }
    
    const num = std.fmt.parseInt(u8, params[0..num_end], 10) catch return;
    
    // Map to Kitty codepoints
    const cp: u21 = switch (num) {
        2 => 57348,  // Insert
        3 => 57349,  // Delete
        5 => 57354,  // PageUp
        6 => 57355,  // PageDown
        15 => 57368, // F5
        17 => 57369, // F6
        18 => 57370, // F7
        19 => 57371, // F8
        20 => 57372, // F9
        21 => 57373, // F10
        23 => 57374, // F11
        24 => 57375, // F12
        else => return,
    };
    
    const name = try codepointToName(cp);
    log("Legacy function key: {d} -> {s}", .{ num, name });
    try recordKey(cp, name, .press);
}

fn parseKittySequence(params: []const u8) !void {
    // Kitty format: codepoint:shifted:base ; modifiers:event-type ; text u
    // Examples:
    //   "106;1:3" = codepoint 106, modifiers 1, event-type 3 (release)
    //   "57352;1:1" = Up arrow, press
    //   "97" = 'a' press (minimal)
    
    // Split on semicolons first
    var parts: [3][]const u8 = .{ params, "", "" };
    var part_idx: usize = 0;
    var start: usize = 0;
    
    for (params, 0..) |c, i| {
        if (c == ';') {
            if (part_idx < 3) {
                parts[part_idx] = params[start..i];
                part_idx += 1;
            }
            start = i + 1;
        }
    }
    if (part_idx < 3) {
        parts[part_idx] = params[start..];
    }

    log("  parts[0]={s} parts[1]={s} parts[2]={s}", .{ parts[0], parts[1], parts[2] });

    // Parse codepoint (may have :shifted_key:base_key suffix)
    var cp_str = parts[0];
    if (std.mem.indexOfScalar(u8, cp_str, ':')) |colon_idx| {
        cp_str = cp_str[0..colon_idx];
    }
    
    const codepoint = std.fmt.parseInt(u21, cp_str, 10) catch {
        log("  Failed to parse codepoint from: {s}", .{cp_str});
        return;
    };
    
    // Parse modifiers:event-type from parts[1]
    // Format: "modifiers" or "modifiers:event-type"
    var event_type: EventType = .press;
    if (parts[1].len > 0) {
        var mod_part = parts[1];
        if (std.mem.indexOfScalar(u8, mod_part, ':')) |colon_idx| {
            // Has event type after colon
            const et_str = mod_part[colon_idx + 1 ..];
            const et = std.fmt.parseInt(u8, et_str, 10) catch 1;
            event_type = switch (et) {
                1 => .press,
                2 => .repeat,
                3 => .release,
                else => .press,
            };
            log("  event_type from '{s}': {d}", .{ et_str, et });
        }
    }

    // Generate name from codepoint
    const name = try codepointToName(codepoint);
    log("  codepoint={d} name={s} event={s}", .{ codepoint, name, @tagName(event_type) });
    try recordKey(codepoint, name, event_type);
}

fn codepointToName(cp: u21) ![]const u8 {
    // Special keys (from Kitty protocol functional key definitions)
    return switch (cp) {
        57358 => "CapsLock",
        57359 => "ScrollLock",
        57360 => "NumLock",
        57361 => "PrintScreen",
        57362 => "Pause",
        57363 => "Menu",
        57376 => "F13",
        57377 => "F14",
        57378 => "F15",
        57379 => "F16",
        57380 => "F17",
        57381 => "F18",
        57382 => "F19",
        57383 => "F20",
        57384 => "F21",
        57385 => "F22",
        57386 => "F23",
        57387 => "F24",
        57388 => "F25",
        57399 => "KP_0",
        57400 => "KP_1",
        57401 => "KP_2",
        57402 => "KP_3",
        57403 => "KP_4",
        57404 => "KP_5",
        57405 => "KP_6",
        57406 => "KP_7",
        57407 => "KP_8",
        57408 => "KP_9",
        57409 => "KP_.",
        57410 => "KP_/",
        57411 => "KP_*",
        57412 => "KP_-",
        57413 => "KP_+",
        57414 => "KP_Enter",
        57415 => "KP_=",
        57416 => "KP_Sep",
        57417 => "KP_Left",
        57418 => "KP_Right",
        57419 => "KP_Up",
        57420 => "KP_Down",
        57421 => "KP_PgUp",
        57422 => "KP_PgDn",
        57423 => "KP_Home",
        57424 => "KP_End",
        57425 => "KP_Ins",
        57426 => "KP_Del",
        57427 => "KP_Begin",
        57428 => "MediaPlay",
        57429 => "MediaPause",
        57430 => "MediaPlayPause",
        57431 => "MediaRev",
        57432 => "MediaStop",
        57433 => "MediaFwd",
        57434 => "MediaRewind",
        57435 => "MediaNext",
        57436 => "MediaPrev",
        57437 => "MediaRecord",
        57438 => "VolDown",
        57439 => "VolUp",
        57440 => "Mute",
        57441 => "LShift",
        57442 => "LCtrl",
        57443 => "LAlt",
        57444 => "LSuper",
        57445 => "LHyper",
        57446 => "LMeta",
        57447 => "RShift",
        57448 => "RCtrl",
        57449 => "RAlt",
        57450 => "RSuper",
        57451 => "RHyper",
        57452 => "RMeta",
        57453 => "ISOLevel3",
        57454 => "ISOLevel5",
        0x1b => "Escape",
        0x0d => "Enter",
        0x09 => "Tab",
        0x7f => "Backspace",
        0x08 => "Backspace",
        127425 => "Insert",
        127426 => "Delete",
        127427 => "Left",
        127428 => "Right",
        127429 => "Up",
        127430 => "Down",
        127431 => "PageUp",
        127432 => "PageDown",
        127433 => "Home",
        127434 => "End",
        // Standard codepoints for function keys in Kitty
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
        // Printable ASCII
        ' ' => "Space",
        else => blk: {
            if (cp >= 0x21 and cp <= 0x7e) {
                // Printable ASCII
                var buf: [1]u8 = .{@intCast(cp)};
                const name = try alloc.dupe(u8, &buf);
                try owned_strings.append(alloc, name);
                break :blk name;
            }
            if (cp < 0x10000) {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch {
                    const name = try std.fmt.allocPrint(alloc, "U+{X:0>4}", .{cp});
                    try owned_strings.append(alloc, name);
                    break :blk name;
                };
                const name = try alloc.dupe(u8, buf[0..len]);
                try owned_strings.append(alloc, name);
                break :blk name;
            }
            const name = try std.fmt.allocPrint(alloc, "U+{X:0>4}", .{cp});
            try owned_strings.append(alloc, name);
            break :blk name;
        },
    };
}

fn recordKey(codepoint: u21, name: []const u8, event_type: EventType) !void {
    const now = std.time.milliTimestamp();
    
    // Track escape presses for double-escape exit
    // Codepoint 27 (0x1b) or 57344 (Kitty functional Escape)
    if ((codepoint == 0x1b or codepoint == 57344) and event_type == .press) {
        escape_count += 1;
        if (escape_count >= 2) {
            running = false;
            return;
        }
    } else if (event_type == .press) {
        // Any other key press resets escape count
        escape_count = 0;
    }
    
    if (keys.get(codepoint)) |existing| {
        var state = existing;
        state.timestamp = now;
        switch (event_type) {
            .press => {
                state.down = true;
                state.up = false; // Reset up on new press
            },
            .repeat => {}, // Ignore repeats for visual
            .release => {
                state.up = true;
            },
        }
        try keys.put(alloc, codepoint, state);
    } else {
        var state = KeyState{
            .codepoint = codepoint,
            .name = name,
            .timestamp = now,
        };
        switch (event_type) {
            .press => state.down = true,
            .repeat => {},
            .release => state.up = true,
        }
        try keys.put(alloc, codepoint, state);
        try key_order.append(alloc, codepoint);
    }
}

fn pruneCompletedKeys() !void {
    const now = std.time.milliTimestamp();
    var i: usize = 0;
    while (i < key_order.items.len) {
        const cp = key_order.items[i];
        if (keys.get(cp)) |state| {
            // Remove if both down and up, and older than 500ms
            if (state.down and state.up and (now - state.timestamp) > 500) {
                _ = keys.remove(cp);
                _ = key_order.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

fn render(fd: posix.fd_t) !void {
    var out_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const w = fbs.writer();

    w.writeAll(CLEAR_SCREEN) catch {};
    w.writeAll(BOLD ++ "Kitty Keyboard Protocol Tester" ++ RESET ++ " (press Escape twice to exit)\n\n") catch {};

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

    // Show keys with up/down states
    w.writeAll("Keys:\n") catch {};
    for (key_order.items) |cp| {
        if (keys.get(cp)) |state| {
            // Key name
            if (state.down and !state.up) {
                w.writeAll("  " ++ BLUE ++ BOLD) catch {};
            } else {
                w.writeAll("  ") catch {};
            }
            
            // Pad name to 12 chars
            w.writeAll(state.name) catch {};
            const pad_len = if (state.name.len < 12) 12 - state.name.len else 0;
            for (0..pad_len) |_| {
                w.writeByte(' ') catch {};
            }
            w.writeAll(RESET) catch {};

            // Down arrow
            if (state.down) {
                w.writeAll(GREEN ++ "↓" ++ RESET) catch {};
            } else {
                w.writeAll(DIM ++ "↓" ++ RESET) catch {};
            }

            w.writeAll(" ") catch {};

            // Up arrow
            if (state.up) {
                w.writeAll(BLUE ++ "↑" ++ RESET) catch {};
            } else {
                w.writeAll(DIM ++ "↑" ++ RESET) catch {};
            }

            w.writeAll("\n") catch {};
        }
    }

    w.writeAll("\n" ++ DIM ++ "Kitty protocol enabled - key release detection active" ++ RESET ++ "\n") catch {};

    _ = posix.write(fd, fbs.getWritten()) catch {};
}

//! Browser keyboard event adapter for libghostty-vt's key encoder.

const std = @import("std");
const ghostty = @import("ghostty-vt");

const input = ghostty.input;

/// Keyboard event from browser (matches JavaScript KeyboardEvent).
pub const KeyEvent = struct {
    type: []const u8,
    key: []const u8,
    code: []const u8,
    unshiftedKey: ?[]const u8 = null,
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    altGraph: bool = false,
    capsLock: bool = false,
    numLock: bool = false,
    repeat: bool = false,
    timestamp: f64 = 0,
    keyCode: u16 = 0,
};

pub const EncodeOptions = input.KeyEncodeOptions;
// One browser key event carries at most one UTF-8 codepoint for the primary,
// shifted, base-layout, and associated-text fields. Their decimal CSI-u form
// is bounded well below Ghostty's own 128-byte key-encoder test buffers.
pub const max_encoded_size: usize = 128;

/// Encode browser key data using Ghostty's legacy, modifyOtherKeys, or Kitty
/// keyboard encoder according to the active terminal modes.
pub fn keyEventToBytes(event: KeyEvent, output: []u8, options: EncodeOptions) []u8 {
    var writer: std.Io.Writer = .fixed(output);
    input.encodeKey(&writer, toGhosttyEvent(event), options) catch return output[0..0];
    return writer.buffered();
}

fn toGhosttyEvent(event: KeyEvent) input.KeyEvent {
    const printable = std.unicode.utf8ValidateSlice(event.key) and
        std.unicode.utf8CountCodepoints(event.key) catch 0 == 1;
    const unshifted = unshiftedCodepoint(event.unshiftedKey, event.code, event.key, event.shift);

    return .{
        .action = if (std.mem.eql(u8, event.state, "up"))
            .release
        else if (event.repeat)
            .repeat
        else
            .press,
        .key = keyFromEvent(event),
        .mods = .{
            // Browsers commonly expose AltGr as synthetic Ctrl+Alt. AltGr is
            // consumed by the layout to produce text, not a terminal chord.
            .ctrl = event.ctrl and !event.altGraph,
            .alt = event.alt and !event.altGraph,
            .shift = event.shift,
            .super = event.meta,
            .caps_lock = event.capsLock,
            .num_lock = event.numLock,
        },
        // Browser KeyboardEvent.key already contains the shifted printable
        // value, so Shift was consumed to produce its text.
        .consumed_mods = .{
            .shift = printable and event.shift,
            .ctrl = printable and event.altGraph,
            .alt = printable and event.altGraph,
        },
        .utf8 = if (printable) event.key else "",
        .unshifted_codepoint = unshifted,
    };
}

fn unshiftedCodepoint(unshifted_key: ?[]const u8, code: []const u8, key: []const u8, shifted: bool) u21 {
    if (unshifted_key) |value| {
        if (std.unicode.utf8ValidateSlice(value) and (std.unicode.utf8CountCodepoints(value) catch 0) == 1) {
            return std.unicode.utf8Decode(value) catch 0;
        }
    }
    // Older clients do not send unshiftedKey. Their logical key is still
    // authoritative when Shift is not active, including non-US layouts.
    if (!shifted and std.unicode.utf8ValidateSlice(key) and (std.unicode.utf8CountCodepoints(key) catch 0) == 1) {
        return std.unicode.utf8Decode(key) catch 0;
    }
    if (code.len == 4 and std.mem.startsWith(u8, code, "Key")) {
        const c = code[3];
        if (c >= 'A' and c <= 'Z') return c - 'A' + 'a';
    }
    if (code.len == 6 and std.mem.startsWith(u8, code, "Digit")) {
        const c = code[5];
        if (c >= '0' and c <= '9') return c;
    }
    const punctuation = [_]struct { []const u8, u21 }{
        .{ "Backquote", '`' },    .{ "Backslash", '\\' }, .{ "BracketLeft", '[' },
        .{ "BracketRight", ']' }, .{ "Comma", ',' },      .{ "Equal", '=' },
        .{ "Minus", '-' },        .{ "Period", '.' },     .{ "Quote", '\'' },
        .{ "Semicolon", ';' },    .{ "Slash", '/' },      .{ "Space", ' ' },
    };
    for (punctuation) |entry| if (std.mem.eql(u8, code, entry[0])) return entry[1];

    if (std.unicode.utf8ValidateSlice(key) and (std.unicode.utf8CountCodepoints(key) catch 0) == 1) {
        return std.unicode.utf8Decode(key) catch 0;
    }
    return 0;
}

fn keyFromEvent(event: KeyEvent) input.Key {
    const code = event.code;
    if (!event.numLock and std.mem.startsWith(u8, code, "Numpad")) {
        const navigation = [_]struct { []const u8, []const u8, input.Key }{
            .{ "Numpad0", "Insert", .numpad_insert },       .{ "Numpad1", "End", .numpad_end },
            .{ "Numpad2", "ArrowDown", .numpad_down },      .{ "Numpad3", "PageDown", .numpad_page_down },
            .{ "Numpad4", "ArrowLeft", .numpad_left },      .{ "Numpad5", "Clear", .numpad_begin },
            .{ "Numpad6", "ArrowRight", .numpad_right },    .{ "Numpad7", "Home", .numpad_home },
            .{ "Numpad8", "ArrowUp", .numpad_up },          .{ "Numpad9", "PageUp", .numpad_page_up },
            .{ "NumpadDecimal", "Delete", .numpad_delete },
        };
        for (navigation) |entry| {
            if (std.mem.eql(u8, code, entry[0]) and std.mem.eql(u8, event.key, entry[1])) return entry[2];
        }
    }
    if (code.len == 4 and std.mem.startsWith(u8, code, "Key")) {
        const c = code[3];
        if (c >= 'A' and c <= 'Z') return @enumFromInt(@intFromEnum(input.Key.key_a) + c - 'A');
    }
    if (code.len == 6 and std.mem.startsWith(u8, code, "Digit")) {
        const c = code[5];
        if (c >= '0' and c <= '9') return @enumFromInt(@intFromEnum(input.Key.digit_0) + c - '0');
    }
    if (code.len >= 2 and code[0] == 'F') {
        const n = std.fmt.parseInt(u8, code[1..], 10) catch 0;
        if (n >= 1 and n <= 25) return @enumFromInt(@intFromEnum(input.Key.f1) + n - 1);
    }

    const entries = [_]struct { []const u8, input.Key }{
        .{ "Backquote", .backquote },                         .{ "Backslash", .backslash },
        .{ "BracketLeft", .bracket_left },                    .{ "BracketRight", .bracket_right },
        .{ "Comma", .comma },                                 .{ "Equal", .equal },
        .{ "IntlBackslash", .intl_backslash },                .{ "IntlRo", .intl_ro },
        .{ "IntlYen", .intl_yen },                            .{ "Minus", .minus },
        .{ "Period", .period },                               .{ "Quote", .quote },
        .{ "Semicolon", .semicolon },                         .{ "Slash", .slash },
        .{ "AltLeft", .alt_left },                            .{ "AltRight", .alt_right },
        .{ "Backspace", .backspace },                         .{ "CapsLock", .caps_lock },
        .{ "ContextMenu", .context_menu },                    .{ "ControlLeft", .control_left },
        .{ "ControlRight", .control_right },                  .{ "Enter", .enter },
        .{ "Escape", .escape },                               .{ "MetaLeft", .meta_left },
        .{ "MetaRight", .meta_right },                        .{ "ShiftLeft", .shift_left },
        .{ "ShiftRight", .shift_right },                      .{ "Space", .space },
        .{ "Fn", .@"fn" },                                    .{ "FnLock", .fn_lock },
        .{ "Tab", .tab },                                     .{ "Convert", .convert },
        .{ "KanaMode", .kana_mode },                          .{ "NonConvert", .non_convert },
        .{ "Delete", .delete },                               .{ "End", .end },
        .{ "Help", .help },                                   .{ "Home", .home },
        .{ "Insert", .insert },                               .{ "PageDown", .page_down },
        .{ "PageUp", .page_up },                              .{ "ArrowDown", .arrow_down },
        .{ "ArrowLeft", .arrow_left },                        .{ "ArrowRight", .arrow_right },
        .{ "ArrowUp", .arrow_up },                            .{ "NumLock", .num_lock },
        .{ "NumpadAdd", .numpad_add },                        .{ "NumpadBackspace", .numpad_backspace },
        .{ "NumpadClear", .numpad_clear },                    .{ "NumpadComma", .numpad_comma },
        .{ "NumpadDecimal", .numpad_decimal },                .{ "NumpadDivide", .numpad_divide },
        .{ "NumpadEnter", .numpad_enter },                    .{ "NumpadEqual", .numpad_equal },
        .{ "NumpadMultiply", .numpad_multiply },              .{ "NumpadClearEntry", .numpad_clear_entry },
        .{ "NumpadMemoryAdd", .numpad_memory_add },           .{ "NumpadMemoryClear", .numpad_memory_clear },
        .{ "NumpadMemoryRecall", .numpad_memory_recall },     .{ "NumpadMemoryStore", .numpad_memory_store },
        .{ "NumpadMemorySubtract", .numpad_memory_subtract }, .{ "NumpadParenLeft", .numpad_paren_left },
        .{ "NumpadParenRight", .numpad_paren_right },         .{ "NumpadSubtract", .numpad_subtract },
        .{ "Pause", .pause },                                 .{ "PrintScreen", .print_screen },
        .{ "ScrollLock", .scroll_lock },                      .{ "BrowserBack", .browser_back },
        .{ "BrowserFavorites", .browser_favorites },          .{ "BrowserForward", .browser_forward },
        .{ "BrowserHome", .browser_home },                    .{ "BrowserRefresh", .browser_refresh },
        .{ "BrowserSearch", .browser_search },                .{ "BrowserStop", .browser_stop },
        .{ "Eject", .eject },                                 .{ "LaunchApp1", .launch_app_1 },
        .{ "LaunchApp2", .launch_app_2 },                     .{ "LaunchMail", .launch_mail },
        .{ "MediaSelect", .media_select },                    .{ "AudioVolumeDown", .audio_volume_down },
        .{ "AudioVolumeMute", .audio_volume_mute },           .{ "AudioVolumeUp", .audio_volume_up },
        .{ "MediaPlayPause", .media_play_pause },             .{ "MediaStop", .media_stop },
        .{ "MediaTrackNext", .media_track_next },             .{ "MediaTrackPrevious", .media_track_previous },
        .{ "Power", .power },                                 .{ "Sleep", .sleep },
        .{ "WakeUp", .wake_up },                              .{ "Copy", .copy },
        .{ "Cut", .cut },                                     .{ "Paste", .paste },
    };
    for (entries) |entry| if (std.mem.eql(u8, code, entry[0])) return entry[1];

    if (std.mem.startsWith(u8, code, "Numpad") and code.len == 7 and code[6] >= '0' and code[6] <= '9') {
        return @enumFromInt(@intFromEnum(input.Key.numpad_0) + code[6] - '0');
    }
    return .unidentified;
}

test "legacy and Kitty modified enter" {
    var buf: [64]u8 = undefined;
    const event: KeyEvent = .{
        .type = "key",
        .key = "Enter",
        .code = "Enter",
        .state = "down",
        .alt = true,
    };
    try std.testing.expectEqualStrings("\x1b\r", keyEventToBytes(event, &buf, .default));

    var kitty = EncodeOptions.default;
    kitty.kitty_flags = @bitCast(@as(u5, 1));
    try std.testing.expectEqualStrings("\x1b[13;3u", keyEventToBytes(event, &buf, kitty));

    var pi_options = EncodeOptions.default;
    pi_options.kitty_flags = @bitCast(@as(u5, 7));
    try std.testing.expectEqualStrings("\x1b[13;3u", keyEventToBytes(event, &buf, pi_options));

    var shifted = event;
    shifted.alt = false;
    shifted.shift = true;
    try std.testing.expectEqualStrings("\x1b[13;2u", keyEventToBytes(shifted, &buf, pi_options));
}

test "modifyOtherKeys fallback distinguishes modified enter" {
    var buf: [64]u8 = undefined;
    var options = EncodeOptions.default;
    options.modify_other_keys_state_2 = true;
    const event: KeyEvent = .{
        .type = "key",
        .key = "Enter",
        .code = "Enter",
        .state = "down",
        .shift = true,
    };
    try std.testing.expectEqualStrings("\x1b[27;2;13~", keyEventToBytes(event, &buf, options));
}

test "Kitty reports repeat and release" {
    var buf: [64]u8 = undefined;
    var options = EncodeOptions.default;
    options.kitty_flags = @bitCast(@as(u5, 3));
    const base: KeyEvent = .{ .type = "key", .key = "a", .code = "KeyA", .state = "down" };

    var repeat = base;
    repeat.repeat = true;
    try std.testing.expectEqualStrings("\x1b[97;1:2u", keyEventToBytes(repeat, &buf, options));
    var release = base;
    release.state = "up";
    try std.testing.expectEqualStrings("\x1b[97;1:3u", keyEventToBytes(release, &buf, options));
}

test "Kitty reports all keys with associated text" {
    var buf: [64]u8 = undefined;
    var options = EncodeOptions.default;
    options.kitty_flags = @bitCast(@as(u5, 31));
    const event: KeyEvent = .{
        .type = "key",
        .key = "A",
        .code = "KeyA",
        .state = "down",
        .shift = true,
    };
    try std.testing.expectEqualStrings("\x1b[97:65;2;65u", keyEventToBytes(event, &buf, options));
}

test "legacy basics remain compatible" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a", keyEventToBytes(.{
        .type = "key",
        .key = "a",
        .code = "KeyA",
        .state = "down",
    }, &buf, .default));
    try std.testing.expectEqualStrings("\x1b[A", keyEventToBytes(.{
        .type = "key",
        .key = "ArrowUp",
        .code = "ArrowUp",
        .state = "down",
    }, &buf, .default));
    try std.testing.expectEqualStrings("\x03", keyEventToBytes(.{
        .type = "key",
        .key = "c",
        .code = "KeyC",
        .state = "down",
        .ctrl = true,
    }, &buf, .default));
}

test "Kitty suppresses modifiers unless report-all is enabled" {
    var buf: [64]u8 = undefined;
    const event: KeyEvent = .{
        .type = "key",
        .key = "Alt",
        .code = "AltLeft",
        .state = "down",
        .alt = true,
    };
    var options = EncodeOptions.default;
    options.kitty_flags = @bitCast(@as(u5, 7));
    try std.testing.expectEqual(@as(usize, 0), keyEventToBytes(event, &buf, options).len);
    options.kitty_flags = @bitCast(@as(u5, 15));
    try std.testing.expect(keyEventToBytes(event, &buf, options).len > 0);
}

test "NumLock-off keypad keys retain navigation identity" {
    var buf: [64]u8 = undefined;
    var options = EncodeOptions.default;
    options.kitty_flags = @bitCast(@as(u5, 1));
    try std.testing.expectEqualStrings("\x1b[57424u", keyEventToBytes(.{
        .type = "key",
        .key = "End",
        .code = "Numpad1",
        .state = "down",
        .numLock = false,
    }, &buf, options));
    try std.testing.expectEqualStrings("\x1b[57400;129u", keyEventToBytes(.{
        .type = "key",
        .key = "1",
        .code = "Numpad1",
        .state = "down",
        .numLock = true,
    }, &buf, options));
}

test "non-US layout separates logical and PC-101 base keys" {
    var buf: [64]u8 = undefined;
    var options = EncodeOptions.default;
    options.kitty_flags = @bitCast(@as(u5, 7));
    const output = keyEventToBytes(.{
        .type = "key",
        .key = "q",
        .code = "KeyA",
        .unshiftedKey = "q",
        .state = "down",
        .ctrl = true,
    }, &buf, options);
    try std.testing.expectEqualStrings("\x1b[113::97;5u", output);
}

test "AltGraph text does not become a synthetic Ctrl-Alt chord" {
    var buf: [max_encoded_size]u8 = undefined;
    const event: KeyEvent = .{
        .type = "key",
        .key = "@",
        .code = "KeyQ",
        .unshiftedKey = "q",
        .state = "down",
        .ctrl = true,
        .alt = true,
        .altGraph = true,
    };
    try std.testing.expectEqualStrings("@", keyEventToBytes(event, &buf, .default));
    var kitty = EncodeOptions.default;
    kitty.kitty_flags = @bitCast(@as(u5, 7));
    try std.testing.expectEqualStrings("@", keyEventToBytes(event, &buf, kitty));
}

test "maximum-width Kitty event exceeds old buffer without being dropped" {
    var buf: [max_encoded_size]u8 = undefined;
    var options = EncodeOptions.default;
    options.kitty_flags = @bitCast(@as(u5, 31));
    const output = keyEventToBytes(.{
        .type = "key",
        .key = "\xF4\x8F\xBF\xBF",
        .code = "KeyA",
        .unshiftedKey = "\xF4\x8F\xBF\xBE",
        .state = "down",
        .shift = true,
        .capsLock = true,
        .numLock = true,
    }, &buf, options);
    try std.testing.expect(output.len > 32);
    try std.testing.expect(output.len < max_encoded_size);
    try std.testing.expect(output[output.len - 1] == 'u');
}

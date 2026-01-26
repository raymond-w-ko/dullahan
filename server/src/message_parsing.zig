//! Message Parsing
//!
//! Standalone utilities for parsing JSON and msgpack wire protocol messages.
//! Extracted from event_loop.zig to reduce file size and improve modularity.
//!
//! These functions convert raw wire data into the unified ParsedMessage type
//! for processing by the event loop's message handler.

const std = @import("std");
const msgpack = @import("msgpack");
const messages = @import("messages.zig");
const constants = @import("constants.zig");

// Message type aliases from messages.zig
const KeyEvent = messages.KeyEvent;
const TextMessage = messages.TextMessage;
const ResizeMessage = messages.ResizeMessage;
const ScrollMessage = messages.ScrollMessage;
const SyncMessage = messages.SyncMessage;
const FocusMessage = messages.FocusMessage;
const MouseMessage = messages.MouseMessage;
const HelloMessage = messages.HelloMessage;
const NewWindowMessage = messages.NewWindowMessage;
const CloseWindowMessage = messages.CloseWindowMessage;
const ClosePaneMessage = messages.ClosePaneMessage;
const SetLayoutMessage = messages.SetLayoutMessage;
const SwapPanesMessage = messages.SwapPanesMessage;
const ResizeLayoutMessage = messages.ResizeLayoutMessage;
const ClipboardResponseMessage = messages.ClipboardResponseMessage;
const ClipboardSetMessage = messages.ClipboardSetMessage;
const MessageType = messages.MessageType;

pub const ParsedMessage = messages.ParsedMessage;
pub const JsonCleanup = messages.JsonCleanup;

/// Result type for JSON message parsing
pub const JsonParseResult = struct {
    msg: ParsedMessage,
    cleanup: JsonCleanup,
};

/// Result type for msgpack message parsing
pub const MsgpackParseResult = struct {
    msg: ParsedMessage,
    payload: msgpack.Payload,
};

/// Parse a JSON message into the unified ParsedMessage type.
/// Returns null if parsing fails.
pub fn parseJsonMessage(allocator: std.mem.Allocator, data: []const u8) ?JsonParseResult {
    const msg_type = std.json.parseFromSlice(MessageType, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer msg_type.deinit();

    const type_str = msg_type.value.type;

    if (std.mem.eql(u8, type_str, "key")) {
        const parsed = std.json.parseFromSlice(KeyEvent, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .key = .{
                .key = parsed.value.key,
                .code = parsed.value.code,
                .state = parsed.value.state,
                .ctrl = parsed.value.ctrl,
                .alt = parsed.value.alt,
                .shift = parsed.value.shift,
                .meta = parsed.value.meta,
                .repeat = parsed.value.repeat,
                .timestamp = parsed.value.timestamp,
                .keyCode = parsed.value.keyCode,
            } },
            .cleanup = .{ .json_key = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "text")) {
        const parsed = std.json.parseFromSlice(TextMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .text = .{ .data = parsed.value.data } },
            .cleanup = .{ .json_text = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "resize")) {
        const parsed = std.json.parseFromSlice(ResizeMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .resize = .{ .paneId = parsed.value.paneId, .cols = parsed.value.cols, .rows = parsed.value.rows } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "scroll")) {
        const parsed = std.json.parseFromSlice(ScrollMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .scroll = .{ .delta = parsed.value.delta } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "ping")) {
        return .{ .msg = .{ .ping = {} }, .cleanup = .{ .none = {} } };
    } else if (std.mem.eql(u8, type_str, "sync")) {
        const parsed = std.json.parseFromSlice(SyncMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .sync = .{ .gen = parsed.value.gen, .minRowId = parsed.value.minRowId } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "resync")) {
        const parsed = std.json.parseFromSlice(messages.ResyncMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .resync = .{ .paneId = parsed.value.paneId, .reason = parsed.value.reason } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "focus")) {
        const parsed = std.json.parseFromSlice(FocusMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .focus = .{ .paneId = parsed.value.paneId } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "hello")) {
        const parsed = std.json.parseFromSlice(HelloMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .hello = .{
                .clientId = parsed.value.clientId,
                .themeFg = parsed.value.themeFg,
                .themeBg = parsed.value.themeBg,
                .token = parsed.value.token,
            } },
            .cleanup = .{ .json_hello = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "request_master")) {
        return .{ .msg = .{ .request_master = {} }, .cleanup = .{ .none = {} } };
    } else if (std.mem.eql(u8, type_str, "new_window")) {
        const parsed = std.json.parseFromSlice(NewWindowMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .new_window = .{ .templateId = parsed.value.templateId } },
            .cleanup = .{ .json_new_window = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "close_window")) {
        const parsed = std.json.parseFromSlice(CloseWindowMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .close_window = .{ .windowId = parsed.value.windowId } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "close_pane")) {
        const parsed = std.json.parseFromSlice(ClosePaneMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .close_pane = .{ .paneId = parsed.value.paneId } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "set_layout")) {
        const parsed = std.json.parseFromSlice(SetLayoutMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .set_layout = .{
                .windowId = parsed.value.windowId,
                .templateId = parsed.value.templateId,
            } },
            .cleanup = .{ .json_set_layout = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "swap_panes")) {
        const parsed = std.json.parseFromSlice(SwapPanesMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .swap_panes = .{
                .windowId = parsed.value.windowId,
                .paneId1 = parsed.value.paneId1,
                .paneId2 = parsed.value.paneId2,
            } },
            .cleanup = .{ .json_swap_panes = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "resize_layout")) {
        const parsed = std.json.parseFromSlice(ResizeLayoutMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .resize_layout = .{
                .windowId = parsed.value.windowId,
                .nodes = parsed.value.nodes,
            } },
            .cleanup = .{ .json_resize_layout = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "mouse")) {
        const parsed = std.json.parseFromSlice(MouseMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .mouse = .{
                .paneId = parsed.value.paneId,
                .button = parsed.value.button,
                .x = parsed.value.x,
                .y = parsed.value.y,
                .px = parsed.value.px,
                .py = parsed.value.py,
                .state = parsed.value.state,
                .ctrl = parsed.value.ctrl,
                .alt = parsed.value.alt,
                .shift = parsed.value.shift,
                .meta = parsed.value.meta,
                .timestamp = parsed.value.timestamp,
            } },
            .cleanup = .{ .json_mouse = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "select_all")) {
        const parsed = std.json.parseFromSlice(FocusMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .select_all = .{ .paneId = parsed.value.paneId } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "clear_selection")) {
        const parsed = std.json.parseFromSlice(FocusMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .clear_selection = .{ .paneId = parsed.value.paneId } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "clipboard_response")) {
        const parsed = std.json.parseFromSlice(ClipboardResponseMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .clipboard_response = .{
                .paneId = parsed.value.paneId,
                .clipboard = parsed.value.clipboard,
                .data = parsed.value.data,
            } },
            .cleanup = .{ .json_clipboard_response = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "clipboard_set")) {
        const parsed = std.json.parseFromSlice(ClipboardSetMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return .{
            .msg = .{ .clipboard_set = .{
                .clipboard = parsed.value.clipboard,
                .data = parsed.value.data,
            } },
            .cleanup = .{ .json_clipboard_set = parsed },
        };
    } else if (std.mem.eql(u8, type_str, "copy")) {
        const parsed = std.json.parseFromSlice(messages.CopyMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return .{
            .msg = .{ .copy = .{ .paneId = parsed.value.paneId } },
            .cleanup = .{ .none = {} },
        };
    } else if (std.mem.eql(u8, type_str, "clipboard_paste")) {
        const parsed = std.json.parseFromSlice(messages.ClipboardPasteMessage, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        // Extract just the first character (c or p) to avoid use-after-free
        const kind: u8 = if (parsed.value.clipboard.len > 0) parsed.value.clipboard[0] else 'c';
        return .{
            .msg = .{ .clipboard_paste = .{
                .paneId = parsed.value.paneId,
                .clipboard = kind,
            } },
            .cleanup = .{ .none = {} },
        };
    }

    return .{ .msg = .{ .unknown = {} }, .cleanup = .{ .none = {} } };
}

/// Parse a msgpack message into the unified ParsedMessage type.
/// Returns null if parsing fails.
pub fn parseMsgpackMessage(allocator: std.mem.Allocator, data: []const u8) ?MsgpackParseResult {
    var buffer: [constants.buffer.general]u8 = undefined;
    @memcpy(buffer[0..data.len], data);

    var write_stream = msgpack.compat.fixedBufferStream(&buffer);
    var read_stream = msgpack.compat.fixedBufferStream(buffer[0..data.len]);

    const BufferType = msgpack.compat.BufferStream;
    var packer = msgpack.Pack(
        *BufferType,
        *BufferType,
        BufferType.WriteError,
        BufferType.ReadError,
        BufferType.write,
        BufferType.read,
    ).init(&write_stream, &read_stream);

    const payload = packer.read(allocator) catch return null;

    const type_payload = (payload.mapGet("type") catch return null) orelse return null;
    const type_str = type_payload.asStr() catch return null;

    if (std.mem.eql(u8, type_str, "key")) {
        const key_payload = (payload.mapGet("key") catch return null) orelse return null;
        const key = key_payload.asStr() catch return null;
        const state_payload = (payload.mapGet("state") catch return null) orelse return null;
        const state = state_payload.asStr() catch return null;

        const ctrl = if (payload.mapGet("ctrl") catch null) |p| (p.asBool() catch false) else false;
        const alt = if (payload.mapGet("alt") catch null) |p| (p.asBool() catch false) else false;
        const shift = if (payload.mapGet("shift") catch null) |p| (p.asBool() catch false) else false;

        return .{
            .msg = .{ .key = .{
                .key = key,
                .state = state,
                .ctrl = ctrl,
                .alt = alt,
                .shift = shift,
            } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "text")) {
        const data_payload = (payload.mapGet("data") catch return null) orelse return null;
        const text = data_payload.asStr() catch return null;
        return .{
            .msg = .{ .text = .{ .data = text } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "resize")) {
        const pane_id_payload = (payload.mapGet("paneId") catch return null) orelse return null;
        const cols_payload = (payload.mapGet("cols") catch return null) orelse return null;
        const rows_payload = (payload.mapGet("rows") catch return null) orelse return null;
        const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return null);
        const cols: u16 = @intCast(cols_payload.getUint() catch return null);
        const rows: u16 = @intCast(rows_payload.getUint() catch return null);
        return .{
            .msg = .{ .resize = .{ .paneId = pane_id, .cols = cols, .rows = rows } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "scroll")) {
        const delta_payload = (payload.mapGet("delta") catch return null) orelse return null;
        const delta: i32 = @intCast(delta_payload.getInt() catch return null);
        return .{
            .msg = .{ .scroll = .{ .delta = delta } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "ping")) {
        return .{ .msg = .{ .ping = {} }, .payload = payload };
    } else if (std.mem.eql(u8, type_str, "sync")) {
        const gen_payload = (payload.mapGet("gen") catch return null) orelse return null;
        const gen: u64 = gen_payload.getUint() catch return null;
        const minRowId: u64 = if (payload.mapGet("minRowId") catch null) |p| (p.getUint() catch 0) else 0;
        return .{
            .msg = .{ .sync = .{ .gen = gen, .minRowId = minRowId } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "resync")) {
        const pane_id_payload = (payload.mapGet("paneId") catch return null) orelse return null;
        const reason_payload = (payload.mapGet("reason") catch return null) orelse return null;
        const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return null);
        const reason = reason_payload.asStr() catch return null;
        return .{
            .msg = .{ .resync = .{ .paneId = pane_id, .reason = reason } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "focus")) {
        const pane_id_payload = (payload.mapGet("paneId") catch return null) orelse return null;
        const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return null);
        return .{
            .msg = .{ .focus = .{ .paneId = pane_id } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "hello")) {
        const client_id_payload = (payload.mapGet("clientId") catch return null) orelse return null;
        const client_id_str = client_id_payload.asStr() catch return null;
        const token: ?[]const u8 = if (payload.mapGet("token") catch null) |p| (p.asStr() catch null) else null;
        return .{
            .msg = .{ .hello = .{ .clientId = client_id_str, .token = token } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "request_master")) {
        return .{ .msg = .{ .request_master = {} }, .payload = payload };
    } else if (std.mem.eql(u8, type_str, "new_window")) {
        const template_id: ?[]const u8 = if (payload.mapGet("templateId") catch null) |p| (p.asStr() catch null) else null;
        return .{
            .msg = .{ .new_window = .{ .templateId = template_id } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "close_window")) {
        const window_id_payload = (payload.mapGet("windowId") catch return null) orelse return null;
        const window_id: u16 = @intCast(window_id_payload.getUint() catch return null);
        return .{
            .msg = .{ .close_window = .{ .windowId = window_id } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "close_pane")) {
        const pane_id_payload = (payload.mapGet("paneId") catch return null) orelse return null;
        const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return null);
        return .{
            .msg = .{ .close_pane = .{ .paneId = pane_id } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "set_layout")) {
        const window_id_payload = (payload.mapGet("windowId") catch return null) orelse return null;
        const template_id_payload = (payload.mapGet("templateId") catch return null) orelse return null;
        const window_id: u16 = @intCast(window_id_payload.getUint() catch return null);
        const template_id = template_id_payload.asStr() catch return null;
        return .{
            .msg = .{ .set_layout = .{
                .windowId = window_id,
                .templateId = template_id,
            } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "swap_panes")) {
        const window_id_payload = (payload.mapGet("windowId") catch return null) orelse return null;
        const pane_id1_payload = (payload.mapGet("paneId1") catch return null) orelse return null;
        const pane_id2_payload = (payload.mapGet("paneId2") catch return null) orelse return null;
        const window_id: u16 = @intCast(window_id_payload.getUint() catch return null);
        const pane_id1: u16 = @intCast(pane_id1_payload.getUint() catch return null);
        const pane_id2: u16 = @intCast(pane_id2_payload.getUint() catch return null);
        return .{
            .msg = .{ .swap_panes = .{
                .windowId = window_id,
                .paneId1 = pane_id1,
                .paneId2 = pane_id2,
            } },
            .payload = payload,
        };
    } else if (std.mem.eql(u8, type_str, "mouse")) {
        const pane_id_payload = (payload.mapGet("paneId") catch return null) orelse return null;
        const button_payload = (payload.mapGet("button") catch return null) orelse return null;
        const x_payload = (payload.mapGet("x") catch return null) orelse return null;
        const y_payload = (payload.mapGet("y") catch return null) orelse return null;
        const state_payload = (payload.mapGet("state") catch return null) orelse return null;

        const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return null);
        const button: u8 = @intCast(button_payload.getUint() catch return null);
        const x: u16 = @intCast(x_payload.getUint() catch return null);
        const y: u16 = @intCast(y_payload.getUint() catch return null);
        const state = state_payload.asStr() catch return null;

        const px: ?u32 = if (payload.mapGet("px") catch null) |p| @intCast(p.getUint() catch 0) else null;
        const py: ?u32 = if (payload.mapGet("py") catch null) |p| @intCast(p.getUint() catch 0) else null;
        const ctrl = if (payload.mapGet("ctrl") catch null) |p| (p.asBool() catch false) else false;
        const alt = if (payload.mapGet("alt") catch null) |p| (p.asBool() catch false) else false;
        const shift = if (payload.mapGet("shift") catch null) |p| (p.asBool() catch false) else false;
        const meta = if (payload.mapGet("meta") catch null) |p| (p.asBool() catch false) else false;
        // Note: msgpack doesn't have getFloat, and timestamp is rarely needed. Use 0.
        const timestamp: f64 = 0;

        return .{
            .msg = .{ .mouse = .{
                .paneId = pane_id,
                .button = button,
                .x = x,
                .y = y,
                .px = px,
                .py = py,
                .state = state,
                .ctrl = ctrl,
                .alt = alt,
                .shift = shift,
                .meta = meta,
                .timestamp = timestamp,
            } },
            .payload = payload,
        };
    }

    return .{ .msg = .{ .unknown = {} }, .payload = payload };
}

// Tests
test "parseJsonMessage ping" {
    const allocator = std.testing.allocator;
    const result = parseJsonMessage(allocator, "{\"type\":\"ping\"}");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.msg == .ping);
}

test "parseJsonMessage resize" {
    const allocator = std.testing.allocator;
    const result = parseJsonMessage(allocator, "{\"type\":\"resize\",\"paneId\":1,\"cols\":80,\"rows\":24}");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.msg == .resize);
    try std.testing.expectEqual(result.?.msg.resize.paneId, 1);
    try std.testing.expectEqual(result.?.msg.resize.cols, 80);
    try std.testing.expectEqual(result.?.msg.resize.rows, 24);
}

test "parseJsonMessage scroll" {
    const allocator = std.testing.allocator;
    const result = parseJsonMessage(allocator, "{\"type\":\"scroll\",\"delta\":-5}");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.msg == .scroll);
    try std.testing.expectEqual(result.?.msg.scroll.delta, -5);
}

test "parseJsonMessage unknown type" {
    const allocator = std.testing.allocator;
    const result = parseJsonMessage(allocator, "{\"type\":\"foobar\"}");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.msg == .unknown);
}

test "parseJsonMessage invalid json" {
    const allocator = std.testing.allocator;
    const result = parseJsonMessage(allocator, "not valid json");
    try std.testing.expect(result == null);
}

test "parseJsonMessage text with cleanup" {
    const allocator = std.testing.allocator;
    var result = parseJsonMessage(allocator, "{\"type\":\"text\",\"data\":\"hello\"}");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.msg == .text);
    try std.testing.expectEqualStrings(result.?.msg.text.data, "hello");
    // Clean up
    result.?.cleanup.deinit();
}

test "parseJsonMessage resync" {
    const allocator = std.testing.allocator;
    const result = parseJsonMessage(allocator, "{\"type\":\"resync\",\"paneId\":1,\"reason\":\"cache_miss\"}");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.msg == .resync);
    try std.testing.expectEqual(result.?.msg.resync.paneId, 1);
    try std.testing.expectEqualStrings(result.?.msg.resync.reason, "cache_miss");
}

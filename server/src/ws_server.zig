//! WebSocket server for terminal clients
//!
//! Manages WebSocket connections and terminal state synchronization.
//! Uses binary msgpack for efficient data transmission.

const std = @import("std");
const msgpack = @import("msgpack");
const http = @import("http.zig");
const websocket = @import("websocket.zig");
const snapshot = @import("snapshot.zig");
const Session = @import("session.zig").Session;
const Pane = @import("pane.zig").Pane;

const log = std.log.scoped(.ws_server);

// ============================================================================
// Message Types (parsed from client JSON)
// ============================================================================

/// Keyboard event from client
const KeyEvent = struct {
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

/// IME composed text from client
const TextMessage = struct {
    type: []const u8,
    data: []const u8,
};

/// Terminal resize request from client
const ResizeMessage = struct {
    type: []const u8,
    cols: u16,
    rows: u16,
};

/// Scroll request from client
const ScrollMessage = struct {
    type: []const u8,
    delta: i32,  // Negative = scroll up (toward history), positive = scroll down
};

/// Generic message to peek at type field
const MessageType = struct {
    type: []const u8,
};

/// WebSocket server for terminal clients
pub const WsServer = struct {
    http_server: http.Server,
    allocator: std.mem.Allocator,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, port: u16, static_dir: ?[]const u8) !WsServer {
        return .{
            .http_server = try http.Server.init(allocator, port, static_dir),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WsServer) void {
        self.http_server.deinit();
    }

    /// Run the WebSocket server, handling clients
    pub fn run(self: *WsServer, session: *Session) !void {
        log.info("WebSocket server starting...", .{});

        while (self.running) {
            // Accept new WebSocket connection
            const ws_conn = self.http_server.acceptWebSocket() catch |e| {
                if (e == error.ConnectionResetByPeer or e == error.BrokenPipe) {
                    continue;
                }
                log.err("Accept error: {any}", .{e});
                continue;
            };

            if (ws_conn) |conn| {
                // Spawn thread for each WebSocket client so accept loop keeps running
                const thread = std.Thread.spawn(.{}, handleClientThread, .{ self, conn, session }) catch |e| {
                    log.err("Failed to spawn client thread: {any}", .{e});
                    var c = conn;
                    c.close();
                    continue;
                };
                thread.detach();
            }
        }
    }

    /// Thread entry point for client handling
    fn handleClientThread(self: *WsServer, conn: websocket.Connection, session: *Session) void {
        self.handleClient(conn, session) catch |e| {
            log.err("Client handler error: {any}", .{e});
        };
    }

    /// Handle a single WebSocket client
    fn handleClient(self: *WsServer, conn: websocket.Connection, session: *Session) !void {
        var ws = conn;
        defer ws.close();

        log.info("Client connected, sending initial snapshot", .{});

        // Get the active pane
        const pane = session.activePane() orelse {
            log.err("No active pane", .{});
            return;
        };

        // Send initial snapshot
        var last_version = pane.version;
        try self.sendSnapshot(&ws, pane);

        log.info("Snapshot sent, entering message loop", .{});

        // Set read timeout for polling (100ms)
        ws.setReadTimeout(100);

        // Message loop with polling for pane updates
        while (true) {
            const frame_result = ws.readFrame();

            if (frame_result) |frame| {
                defer self.allocator.free(frame.payload);

                switch (frame.opcode) {
                    .text => {
                        // Parse JSON client message (legacy/fallback)
                        self.handleClientMessage(frame.payload, session, &ws) catch |e| {
                            log.err("Failed to handle text message: {any}", .{e});
                        };
                        // Send immediate feedback if pane was modified
                        if (pane.version != last_version) {
                            self.sendSnapshot(&ws, pane) catch {};
                            last_version = pane.version;
                        }
                    },
                    .binary => {
                        // Parse msgpack client message
                        self.handleBinaryMessage(frame.payload, session, &ws) catch |e| {
                            log.err("Failed to handle binary message: {any}", .{e});
                        };
                        // Send immediate feedback if pane was modified
                        if (pane.version != last_version) {
                            self.sendSnapshot(&ws, pane) catch {};
                            last_version = pane.version;
                        }
                    },
                    .ping => {
                        ws.sendPong(frame.payload) catch {};
                    },
                    .pong => {
                        // Ignore pong
                    },
                    .close => {
                        log.info("Client sent close frame", .{});
                        ws.sendClose() catch {};
                        return;
                    },
                    else => {
                        log.warn("Unknown opcode: {any}", .{@intFromEnum(frame.opcode)});
                    },
                }
            } else |e| {
                // Check various timeout-related errors
                if (e == error.WouldBlock or e == error.ConnectionTimedOut) {
                    // Timeout - check if pane was updated
                    if (pane.version != last_version) {
                        log.debug("Pane updated (v{d} -> v{d}), sending snapshot", .{ last_version, pane.version });
                        self.sendSnapshot(&ws, pane) catch |send_err| {
                            log.err("Failed to send snapshot: {any}", .{send_err});
                            return;
                        };
                        last_version = pane.version;
                    }
                    continue;
                } else if (e == error.ConnectionClosed) {
                    log.info("Client disconnected", .{});
                    return;
                } else {
                    log.err("Read error (unexpected): {any}", .{e});
                    return;
                }
            }
        }
    }

    /// Send a binary msgpack snapshot to a single client
    fn sendSnapshot(self: *WsServer, ws: *websocket.Connection, pane: *Pane) !void {
        const snap = try snapshot.generateBinarySnapshot(self.allocator, pane);
        defer self.allocator.free(snap);
        try ws.sendBinary(snap);
    }

    /// Handle a message from a client
    /// Note: Does not send snapshots - the main loop handles that via version tracking
    fn handleClientMessage(self: *WsServer, data: []const u8, session: *Session, ws: *websocket.Connection) !void {
        // Parse message type first
        const msg_type = std.json.parseFromSlice(MessageType, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch |e| {
            log.warn("Failed to parse message type: {any}", .{e});
            return;
        };
        defer msg_type.deinit();

        const type_str = msg_type.value.type;

        if (std.mem.eql(u8, type_str, "key")) {
            // Keyboard event - convert to PTY input
            const key_event = std.json.parseFromSlice(KeyEvent, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch |e| {
                log.warn("Failed to parse key event: {any}", .{e});
                return;
            };
            defer key_event.deinit();

            const pane = session.activePane() orelse return;

            var output_buf: [32]u8 = undefined;
            const output = keyEventToBytes(key_event.value, &output_buf);

            if (output.len > 0) {
                pane.writeInput(output) catch |e| {
                    log.err("Failed to write key to PTY: {any}", .{e});
                };
            }
        } else if (std.mem.eql(u8, type_str, "text")) {
            // IME composed text - send UTF-8 directly
            const text_msg = std.json.parseFromSlice(TextMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch |e| {
                log.warn("Failed to parse text message: {any}", .{e});
                return;
            };
            defer text_msg.deinit();

            log.debug("Received text: {d} bytes", .{text_msg.value.data.len});

            const pane = session.activePane() orelse return;

            // Data is already unescaped by JSON parser
            pane.writeInput(text_msg.value.data) catch |e| {
                log.err("Failed to write text to PTY: {any}", .{e});
            };
        } else if (std.mem.eql(u8, type_str, "resize")) {
            // Resize message
            const resize_msg = std.json.parseFromSlice(ResizeMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch |e| {
                log.warn("Failed to parse resize message: {any}", .{e});
                return;
            };
            defer resize_msg.deinit();

            log.info("Resize request: {d}x{d}", .{ resize_msg.value.cols, resize_msg.value.rows });

            // Resize pane (this increments pane.version)
            const pane = session.activePane() orelse return;
            try pane.resize(resize_msg.value.cols, resize_msg.value.rows);
        } else if (std.mem.eql(u8, type_str, "scroll")) {
            // Scroll request
            const scroll_msg = std.json.parseFromSlice(ScrollMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch |e| {
                log.warn("Failed to parse scroll message: {any}", .{e});
                return;
            };
            defer scroll_msg.deinit();

            const pane = session.activePane() orelse return;
            pane.scroll(scroll_msg.value.delta);
        } else if (std.mem.eql(u8, type_str, "ping")) {
            // Ping message - send binary pong
            const pong = try snapshot.generateBinaryPong(self.allocator);
            defer self.allocator.free(pong);
            try ws.sendBinary(pong);
        } else {
            log.warn("Unknown message type: {s}", .{data});
        }
    }

    /// Handle a binary msgpack message from a client
    fn handleBinaryMessage(self: *WsServer, data: []const u8, session: *Session, ws: *websocket.Connection) !void {
        // Parse msgpack message
        var buffer: [4096]u8 = undefined;
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

        const payload = packer.read(self.allocator) catch |e| {
            log.warn("Failed to parse msgpack: {any}", .{e});
            return;
        };
        defer payload.free(self.allocator);

        // Get message type
        const type_payload = payload.mapGet("type") catch {
            log.warn("Binary message missing 'type' field", .{});
            return;
        } orelse {
            log.warn("Binary message missing 'type' field", .{});
            return;
        };

        const type_str = type_payload.asStr() catch {
            log.warn("Binary message 'type' is not a string", .{});
            return;
        };

        if (std.mem.eql(u8, type_str, "key")) {
            // Keyboard event
            const pane = session.activePane() orelse return;

            const key_payload = (payload.mapGet("key") catch return) orelse return;
            const key = key_payload.asStr() catch return;

            const state_payload = (payload.mapGet("state") catch return) orelse return;
            const state = state_payload.asStr() catch return;

            // Only process keydown events
            if (!std.mem.eql(u8, state, "down")) return;

            const ctrl = if (payload.mapGet("ctrl") catch null) |p| (p.asBool() catch false) else false;
            const alt = if (payload.mapGet("alt") catch null) |p| (p.asBool() catch false) else false;
            const shift = if (payload.mapGet("shift") catch null) |p| (p.asBool() catch false) else false;

            var output_buf: [32]u8 = undefined;
            const event = KeyEvent{
                .type = "key",
                .key = key,
                .code = "",
                .state = state,
                .ctrl = ctrl,
                .alt = alt,
                .shift = shift,
            };
            const output = keyEventToBytes(event, &output_buf);

            if (output.len > 0) {
                pane.writeInput(output) catch |e| {
                    log.err("Failed to write key to PTY: {any}", .{e});
                };
            }
        } else if (std.mem.eql(u8, type_str, "text")) {
            // IME composed text
            const pane = session.activePane() orelse return;
            const data_payload = (payload.mapGet("data") catch return) orelse return;
            const text = data_payload.asStr() catch return;
            pane.writeInput(text) catch |e| {
                log.err("Failed to write text to PTY: {any}", .{e});
            };
        } else if (std.mem.eql(u8, type_str, "resize")) {
            const pane = session.activePane() orelse return;
            const cols_payload = (payload.mapGet("cols") catch return) orelse return;
            const rows_payload = (payload.mapGet("rows") catch return) orelse return;
            const cols: u16 = @intCast(cols_payload.getUint() catch return);
            const rows: u16 = @intCast(rows_payload.getUint() catch return);
            log.info("Binary resize request: {d}x{d}", .{ cols, rows });
            try pane.resize(cols, rows);
        } else if (std.mem.eql(u8, type_str, "scroll")) {
            const pane = session.activePane() orelse return;
            const delta_payload = (payload.mapGet("delta") catch return) orelse return;
            const delta: i32 = @intCast(delta_payload.getInt() catch return);
            pane.scroll(delta);
        } else if (std.mem.eql(u8, type_str, "ping")) {
            const pong = try snapshot.generateBinaryPong(self.allocator);
            defer self.allocator.free(pong);
            try ws.sendBinary(pong);
        } else {
            log.warn("Unknown binary message type: {s}", .{type_str});
        }
    }
};

/// Convert a keyboard event to PTY byte sequence
/// Returns slice of output buffer with bytes to send
///
/// Note: This preserves full event data for future Kitty keyboard protocol support.
/// Currently converts to legacy/VT sequences for shell compatibility.
fn keyEventToBytes(event: KeyEvent, output: []u8) []u8 {
    // Only process keydown events
    if (!std.mem.eql(u8, event.state, "down")) {
        return output[0..0];
    }

    const key = event.key;

    // Ignore modifier-only keys in legacy mode
    // These only generate output with Kitty keyboard protocol
    if (std.mem.eql(u8, key, "Meta") or
        std.mem.eql(u8, key, "Control") or
        std.mem.eql(u8, key, "Alt") or
        std.mem.eql(u8, key, "Shift") or
        std.mem.eql(u8, key, "CapsLock") or
        std.mem.eql(u8, key, "NumLock") or
        std.mem.eql(u8, key, "ScrollLock") or
        std.mem.eql(u8, key, "Hyper") or
        std.mem.eql(u8, key, "Super") or
        std.mem.eql(u8, key, "OS") or // Windows key on some platforms
        std.mem.eql(u8, key, "AltGraph") or
        std.mem.eql(u8, key, "Fn") or
        std.mem.eql(u8, key, "FnLock"))
    {
        return output[0..0];
    }

    // Get modifiers from parsed struct
    const ctrl = event.ctrl;
    const alt = event.alt;
    const shift = event.shift;
    
    // Handle special keys first
    if (key.len == 1) {
        const c = key[0];
        
        // Ctrl + letter -> control character
        if (ctrl and c >= 'a' and c <= 'z') {
            output[0] = c - 'a' + 1; // Ctrl+A = 0x01, Ctrl+Z = 0x1A
            return output[0..1];
        }
        if (ctrl and c >= 'A' and c <= 'Z') {
            output[0] = c - 'A' + 1;
            return output[0..1];
        }
        
        // Ctrl + special characters
        if (ctrl) {
            const ctrl_char: ?u8 = switch (c) {
                '@' => 0x00,
                '[' => 0x1b, // Escape
                '\\' => 0x1c,
                ']' => 0x1d,
                '^' => 0x1e,
                '_' => 0x1f,
                '?' => 0x7f, // Delete
                else => null,
            };
            if (ctrl_char) |cc| {
                output[0] = cc;
                return output[0..1];
            }
        }
        
        // Alt + character -> ESC + character
        if (alt) {
            output[0] = 0x1b;
            output[1] = c;
            return output[0..2];
        }
        
        // Regular character - encode as UTF-8 (already is for ASCII)
        output[0] = c;
        return output[0..1];
    }
    
    // Multi-character key names
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
            // Shift+Tab = CSI Z (backtab)
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
        // CSI 3 ~
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '3';
        output[3] = '~';
        return output[0..4];
    }
    
    // Arrow keys
    if (std.mem.eql(u8, key, "ArrowUp")) {
        return writeArrowKey(output, 'A', ctrl, alt);
    }
    if (std.mem.eql(u8, key, "ArrowDown")) {
        return writeArrowKey(output, 'B', ctrl, alt);
    }
    if (std.mem.eql(u8, key, "ArrowRight")) {
        return writeArrowKey(output, 'C', ctrl, alt);
    }
    if (std.mem.eql(u8, key, "ArrowLeft")) {
        return writeArrowKey(output, 'D', ctrl, alt);
    }
    
    // Home/End
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
    
    // Page Up/Down
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
    
    // Insert
    if (std.mem.eql(u8, key, "Insert")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '2';
        output[3] = '~';
        return output[0..4];
    }
    
    // Function keys F1-F12
    if (key.len >= 2 and key[0] == 'F') {
        const fnum = std.fmt.parseInt(u8, key[1..], 10) catch return output[0..0];
        return writeFunctionKey(output, fnum);
    }
    
    // Multi-byte UTF-8 characters (e.g., from dead keys or special input)
    // The key value is already UTF-8 encoded and unescaped by JSON parser
    if (key.len > 1 and key.len <= output.len) {
        @memcpy(output[0..key.len], key);
        if (alt) {
            // Alt + UTF-8 char: prepend ESC
            // Shift existing content right by 1
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

/// Write arrow key escape sequence with modifiers
fn writeArrowKey(output: []u8, arrow: u8, ctrl: bool, alt: bool) []u8 {
    if (ctrl or alt) {
        // CSI 1 ; <mod> <arrow>
        // mod: 2=Shift, 3=Alt, 4=Shift+Alt, 5=Ctrl, 6=Ctrl+Shift, 7=Ctrl+Alt, 8=Ctrl+Shift+Alt
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
    // Simple: CSI <arrow>
    output[0] = 0x1b;
    output[1] = '[';
    output[2] = arrow;
    return output[0..3];
}

/// Write function key escape sequence
fn writeFunctionKey(output: []u8, fnum: u8) []u8 {
    // F1-F4: SS3 P, Q, R, S (or CSI 11~, etc.)
    // F5-F12: CSI 15~, 17~, 18~, 19~, 20~, 21~, 23~, 24~
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

test "parse key event" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"key\",\"key\":\"a\",\"code\":\"KeyA\",\"state\":\"down\",\"ctrl\":false,\"alt\":false,\"shift\":false,\"meta\":false}";

    const parsed = try std.json.parseFromSlice(KeyEvent, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("key", parsed.value.type);
    try std.testing.expectEqualStrings("a", parsed.value.key);
    try std.testing.expectEqualStrings("KeyA", parsed.value.code);
    try std.testing.expectEqualStrings("down", parsed.value.state);
    try std.testing.expect(!parsed.value.ctrl);
}

test "parse resize message" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"resize\",\"cols\":80,\"rows\":24}";

    const parsed = try std.json.parseFromSlice(ResizeMessage, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("resize", parsed.value.type);
    try std.testing.expectEqual(@as(u16, 80), parsed.value.cols);
    try std.testing.expectEqual(@as(u16, 24), parsed.value.rows);
}

test "parse text message" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"text\",\"data\":\"hello\\nworld\"}";

    const parsed = try std.json.parseFromSlice(TextMessage, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("text", parsed.value.type);
    try std.testing.expectEqualStrings("hello\nworld", parsed.value.data); // Already unescaped!
}

test "keyEventToBytes basic" {
    var output: [32]u8 = undefined;

    // Regular key
    const result = keyEventToBytes(.{
        .type = "key",
        .key = "a",
        .code = "KeyA",
        .state = "down",
    }, &output);
    try std.testing.expectEqualStrings("a", result);

    // Ctrl+C
    const ctrl_c = keyEventToBytes(.{
        .type = "key",
        .key = "c",
        .code = "KeyC",
        .state = "down",
        .ctrl = true,
    }, &output);
    try std.testing.expectEqual(@as(u8, 0x03), ctrl_c[0]);

    // Keyup should be ignored
    const keyup = keyEventToBytes(.{
        .type = "key",
        .key = "a",
        .code = "KeyA",
        .state = "up",
    }, &output);
    try std.testing.expectEqual(@as(usize, 0), keyup.len);
}

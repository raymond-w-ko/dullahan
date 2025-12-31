//! WebSocket server for terminal clients
//!
//! Manages WebSocket connections and terminal state synchronization.

const std = @import("std");
const http = @import("http.zig");
const websocket = @import("websocket.zig");
const snapshot = @import("snapshot.zig");
const Session = @import("session.zig").Session;
const Pane = @import("pane.zig").Pane;

const log = std.log.scoped(.ws_server);

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
                        // Parse client message (this may update pane)
                        self.handleClientMessage(frame.payload, session, &ws) catch |e| {
                            log.err("Failed to handle message: {any}", .{e});
                        };
                        // Send immediate feedback if pane was modified
                        if (pane.version != last_version) {
                            self.sendSnapshot(&ws, pane) catch {};
                            last_version = pane.version;
                        }
                    },
                    .binary => {
                        log.debug("Received binary frame ({d} bytes)", .{frame.payload.len});
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

    /// Send a snapshot to a single client
    fn sendSnapshot(self: *WsServer, ws: *websocket.Connection, pane: *Pane) !void {
        const snap = try snapshot.generateSnapshot(self.allocator, pane);
        defer self.allocator.free(snap);
        try ws.sendText(snap);
    }

    /// Handle a message from a client
    /// Note: Does not send snapshots - the main loop handles that via version tracking
    fn handleClientMessage(self: *WsServer, data: []const u8, session: *Session, ws: *websocket.Connection) !void {
        _ = self;

        // Simple JSON parsing - look for "type" field
        // Format: {"type":"...", ...}

        if (std.mem.indexOf(u8, data, "\"type\":\"key\"")) |_| {
            // Keyboard event - convert to PTY input
            // Full fidelity preserved for future Kitty keyboard protocol support
            const pane = session.activePane() orelse return;
            
            var output_buf: [32]u8 = undefined;
            const output = keyEventToBytes(data, &output_buf);
            
            if (output.len > 0) {
                pane.writeInput(output) catch |e| {
                    log.err("Failed to write key to PTY: {any}", .{e});
                };
            }
        } else if (std.mem.indexOf(u8, data, "\"type\":\"text\"")) |_| {
            // IME composed text - send UTF-8 directly
            if (extractJsonString(data, "\"data\":\"")) |text_data| {
                log.debug("Received text: {d} bytes", .{text_data.len});

                const pane = session.activePane() orelse return;
                
                // Unescape JSON string
                var unescaped: [1024]u8 = undefined;
                const unescaped_len = unescapeJson(text_data, &unescaped);
                
                pane.writeInput(unescaped[0..unescaped_len]) catch |e| {
                    log.err("Failed to write text to PTY: {any}", .{e});
                };
            }
        } else if (std.mem.indexOf(u8, data, "\"type\":\"resize\"")) |_| {
            // Resize message
            const cols = extractJsonInt(data, "\"cols\":") orelse return;
            const rows = extractJsonInt(data, "\"rows\":") orelse return;

            log.info("Resize request: {d}x{d}", .{ cols, rows });

            // Resize pane (this increments pane.version)
            const pane = session.activePane() orelse return;
            try pane.resize(@intCast(cols), @intCast(rows));
        } else if (std.mem.indexOf(u8, data, "\"type\":\"ping\"")) |_| {
            // Ping message - send pong
            try ws.sendText("{\"type\":\"pong\"}");
        } else {
            log.warn("Unknown message type: {s}", .{data});
        }
    }
};

/// Convert a keyboard event JSON to PTY byte sequence
/// Returns slice of output buffer with bytes to send
/// 
/// Note: This preserves full event data for future Kitty keyboard protocol support.
/// Currently converts to legacy/VT sequences for shell compatibility.
fn keyEventToBytes(json: []const u8, output: []u8) []u8 {
    // Only process keydown events
    if (std.mem.indexOf(u8, json, "\"state\":\"down\"") == null) {
        return output[0..0];
    }
    
    // Extract key value first
    const key = extractJsonString(json, "\"key\":\"") orelse return output[0..0];
    
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
    
    // Extract modifiers
    const ctrl = std.mem.indexOf(u8, json, "\"ctrl\":true") != null;
    const alt = std.mem.indexOf(u8, json, "\"alt\":true") != null;
    const shift = std.mem.indexOf(u8, json, "\"shift\":true") != null;
    
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
    // The key value is already UTF-8 encoded, just copy it
    if (key.len > 1 and key.len <= output.len) {
        // Unescape the key value first
        const len = unescapeJson(key, output);
        if (alt and len > 0) {
            // Alt + UTF-8 char: prepend ESC
            // Shift existing content right by 1
            var i: usize = len;
            while (i > 0) : (i -= 1) {
                output[i] = output[i - 1];
            }
            output[0] = 0x1b;
            return output[0 .. len + 1];
        }
        return output[0..len];
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

/// Unescape a JSON string (handle \r, \n, \t, \\, \", etc.)
fn unescapeJson(input: []const u8, output: []u8) usize {
    var out_idx: usize = 0;
    var i: usize = 0;
    
    while (i < input.len and out_idx < output.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            const char: u8 = switch (next) {
                'r' => '\r',
                'n' => '\n',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                '/' => '/',
                else => next,
            };
            output[out_idx] = char;
            out_idx += 1;
            i += 2;
        } else {
            output[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }
    
    return out_idx;
}

/// Extract a string value from JSON (simple, not full parser)
fn extractJsonString(json: []const u8, prefix: []const u8) ?[]const u8 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;

    // Find closing quote (handling escapes simply)
    var end_idx = value_start;
    while (end_idx < json.len) : (end_idx += 1) {
        if (json[end_idx] == '"' and (end_idx == value_start or json[end_idx - 1] != '\\')) {
            break;
        }
    }

    if (end_idx >= json.len) return null;
    return json[value_start..end_idx];
}

/// Extract an integer value from JSON
fn extractJsonInt(json: []const u8, prefix: []const u8) ?i64 {
    const start_idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start_idx + prefix.len;

    var end_idx = value_start;
    while (end_idx < json.len and (json[end_idx] >= '0' and json[end_idx] <= '9')) {
        end_idx += 1;
    }

    if (end_idx == value_start) return null;

    return std.fmt.parseInt(i64, json[value_start..end_idx], 10) catch null;
}

test "extract json string" {
    const json = "{\"type\":\"input\",\"data\":\"hello\"}";
    const data = extractJsonString(json, "\"data\":\"");
    try std.testing.expectEqualStrings("hello", data.?);
}

test "extract json int" {
    const json = "{\"type\":\"resize\",\"cols\":80,\"rows\":24}";
    try std.testing.expectEqual(@as(i64, 80), extractJsonInt(json, "\"cols\":").?);
    try std.testing.expectEqual(@as(i64, 24), extractJsonInt(json, "\"rows\":").?);
}

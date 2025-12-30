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
                // Handle this client (blocking for now - single client)
                self.handleClient(conn, session) catch |e| {
                    log.err("Client handler error: {any}", .{e});
                };
            }
        }
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

        if (std.mem.indexOf(u8, data, "\"type\":\"input\"")) |_| {
            // Input message - extract data field
            if (extractJsonString(data, "\"data\":\"")) |input_data| {
                log.debug("Received input: {d} bytes", .{input_data.len});

                // Feed input to terminal (this increments pane.version)
                const pane = session.activePane() orelse return;
                try pane.feed(input_data);
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

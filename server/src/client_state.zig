//! Client state management for connected WebSocket clients.
//!
//! Each connected browser client has a ClientState that tracks:
//! - WebSocket connection
//! - Per-pane generation counters (for delta sync)
//! - Client identification and authentication

const std = @import("std");
const websocket = @import("websocket.zig");
const ws_proxy = @import("ws_proxy.zig");

const log = std.log.scoped(.client_state);

pub const ClientState = struct {
    ws: websocket.Connection,
    pane_generations: std.AutoHashMap(u16, u64),
    connected: bool = true,
    allocator: std.mem.Allocator,

    /// Client's unique ID (set when client sends "hello" message)
    /// UUIDv4 format, e.g. "550e8400-e29b-41d4-a716-446655440000"
    client_id: ?[]const u8 = null,

    /// Whether the client has been authenticated.
    /// In dev mode, clients are auto-authenticated on hello.
    /// Future: will require token validation.
    authenticated: bool = false,

    /// Auth role based on token (none/view/master).
    auth_role: ws_proxy.AuthRole = .none,

    /// Auth token from hello message (for future token validation)
    auth_token: ?[]const u8 = null,

    /// Whether the client's socket is congested (WouldBlock occurred).
    /// When true, skip sending to this client until socket becomes writable.
    write_congested: bool = false,

    /// Last time (ms since epoch) we received any frame from this client.
    last_rx_ms: i64 = 0,

    /// Whether server has sent an idle ping and is waiting for a pong.
    awaiting_pong: bool = false,

    /// Timestamp when last idle ping was sent.
    last_ping_sent_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, ws: websocket.Connection) ClientState {
        const now = std.time.milliTimestamp();
        return .{
            .ws = ws,
            .pane_generations = std.AutoHashMap(u16, u64).init(allocator),
            .allocator = allocator,
            .last_rx_ms = now,
        };
    }

    pub fn deinit(self: *ClientState) void {
        // Free client ID if allocated
        if (self.client_id) |id| {
            self.allocator.free(id);
        }
        // Free auth token if allocated
        if (self.auth_token) |token| {
            self.allocator.free(token);
        }
        self.pane_generations.deinit();
        self.ws.deinit();
        self.connected = false;
    }

    /// Set the client ID (called when "hello" message is received)
    pub fn setClientId(self: *ClientState, id: []const u8) !void {
        // Free old ID if any
        if (self.client_id) |old_id| {
            self.allocator.free(old_id);
        }
        // Allocate and copy new ID
        self.client_id = try self.allocator.dupe(u8, id);
    }

    /// Set the auth token (called when "hello" message is received with token)
    pub fn setAuthToken(self: *ClientState, token: []const u8) !void {
        // Free old token if any
        if (self.auth_token) |old_token| {
            self.allocator.free(old_token);
        }
        // Allocate and copy new token
        self.auth_token = try self.allocator.dupe(u8, token);
    }

    /// Get short client ID for logging (first 8 chars or "anonymous")
    pub fn shortId(self: *const ClientState) []const u8 {
        if (self.client_id) |id| {
            return if (id.len >= 8) id[0..8] else id;
        }
        return "anon";
    }

    pub fn getGeneration(self: *ClientState, pane_id: u16) u64 {
        return self.pane_generations.get(pane_id) orelse 0;
    }

    pub fn setGeneration(self: *ClientState, pane_id: u16, gen: u64) void {
        self.pane_generations.put(pane_id, gen) catch |e| {
            log.info("[recoverable] pane generation tracking: {any}", .{e});
        };
    }

    /// Record inbound traffic/activity from client.
    pub fn markRx(self: *ClientState, now_ms: i64) void {
        self.last_rx_ms = now_ms;
        self.awaiting_pong = false;
    }
};

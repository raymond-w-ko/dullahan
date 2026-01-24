//! WebSocket Proxy Layer
//!
//! Centralizes all WebSocket send/recv operations, enabling:
//! - Authentication checks before message processing
//! - Permission validation (master vs slave)
//! - Future extensibility (rate limiting, audit logging, metrics)

const std = @import("std");
const websocket = @import("websocket.zig");

const log = std.log.scoped(.ws_proxy);

/// Error types for proxy operations
pub const ProxyError = error{
    NotAuthenticated,
    NotMaster,
    SendFailed,
};

/// WebSocket proxy for centralized message handling.
/// Provides auth checks, permission validation, and message routing.
pub const WsProxy = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WsProxy {
        return .{ .allocator = allocator };
    }

    // ========================================================================
    // Authentication Checks
    // ========================================================================

    /// Check if a client is authenticated. Returns error if not.
    pub fn requireAuth(client: anytype) ProxyError!void {
        if (!client.authenticated) {
            return ProxyError.NotAuthenticated;
        }
    }

    /// Check if client is authenticated (returns bool instead of error).
    pub fn isAuthenticated(client: anytype) bool {
        return client.authenticated;
    }

    // ========================================================================
    // Permission Checks
    // ========================================================================

    /// Check if client is the current master.
    pub fn isMaster(client: anytype, master_id: ?[]const u8) bool {
        if (master_id) |mid| {
            if (client.client_id) |cid| {
                return std.mem.eql(u8, cid, mid);
            }
        }
        return false;
    }

    /// Require client to be master. Returns error if not.
    pub fn requireMaster(client: anytype, master_id: ?[]const u8) ProxyError!void {
        if (!isMaster(client, master_id)) {
            return ProxyError.NotMaster;
        }
    }

    // ========================================================================
    // Send Methods (with auth checks)
    // ========================================================================

    /// Send binary message to a single client.
    /// Checks authentication before sending.
    pub fn send(client: anytype, msg: []const u8) !void {
        try requireAuth(client);
        try client.ws.sendBinary(msg);
    }

    /// Send binary message to a single client without auth check.
    /// Use this for initial connection handshake messages.
    pub fn sendUnchecked(client: anytype, msg: []const u8) !void {
        try client.ws.sendBinary(msg);
    }

    /// Broadcast binary message to all authenticated clients.
    pub fn broadcast(
        clients: anytype, // *std.ArrayListUnmanaged(ClientState)
        msg: []const u8,
    ) void {
        for (clients.items) |*client| {
            if (client.authenticated) {
                client.ws.sendBinary(msg) catch |e| {
                    log.warn("broadcast failed for client {s}: {any}", .{ client.shortId(), e });
                };
            }
        }
    }

    /// Broadcast binary message to all connected clients (including unauthenticated).
    /// Use this for messages that should reach everyone.
    pub fn broadcastAll(
        clients: anytype,
        msg: []const u8,
    ) void {
        for (clients.items) |*client| {
            client.ws.sendBinary(msg) catch |e| {
                log.warn("broadcastAll failed for client {s}: {any}", .{ client.shortId(), e });
            };
        }
    }

    /// Broadcast binary message with a filter function.
    pub fn broadcastIf(
        clients: anytype,
        msg: []const u8,
        comptime filter: fn (anytype) bool,
    ) void {
        for (clients.items) |*client| {
            if (client.authenticated and filter(client)) {
                client.ws.sendBinary(msg) catch |e| {
                    log.warn("broadcastIf failed for client {s}: {any}", .{ client.shortId(), e });
                };
            }
        }
    }

    /// Send binary message only to the master client.
    pub fn sendToMaster(
        clients: anytype,
        master_id: ?[]const u8,
        msg: []const u8,
    ) bool {
        if (master_id) |mid| {
            for (clients.items) |*client| {
                if (client.authenticated) {
                    if (client.client_id) |cid| {
                        if (std.mem.eql(u8, cid, mid)) {
                            client.ws.sendBinary(msg) catch |e| {
                                log.warn("sendToMaster failed: {any}", .{e});
                                return false;
                            };
                            return true;
                        }
                    }
                }
            }
        }
        return false;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WsProxy isMaster" {
    const MockClient = struct {
        authenticated: bool = true,
        client_id: ?[]const u8 = null,
    };

    var client = MockClient{ .authenticated = true, .client_id = "client-123" };

    // Client is master when IDs match
    try std.testing.expect(WsProxy.isMaster(&client, "client-123"));

    // Client is not master when IDs differ
    try std.testing.expect(!WsProxy.isMaster(&client, "other-client"));

    // Client is not master when master_id is null
    try std.testing.expect(!WsProxy.isMaster(&client, null));

    // Client is not master when client has no ID
    client.client_id = null;
    try std.testing.expect(!WsProxy.isMaster(&client, "client-123"));
}

test "WsProxy requireAuth" {
    const MockClient = struct {
        authenticated: bool = false,
    };

    var client = MockClient{ .authenticated = false };

    // Should error when not authenticated
    try std.testing.expectError(ProxyError.NotAuthenticated, WsProxy.requireAuth(&client));

    // Should succeed when authenticated
    client.authenticated = true;
    try WsProxy.requireAuth(&client);
}

test "WsProxy requireMaster" {
    const MockClient = struct {
        authenticated: bool = true,
        client_id: ?[]const u8 = null,
    };

    var client = MockClient{ .authenticated = true, .client_id = "client-123" };

    // Should succeed when client is master
    try WsProxy.requireMaster(&client, "client-123");

    // Should error when client is not master
    try std.testing.expectError(ProxyError.NotMaster, WsProxy.requireMaster(&client, "other-client"));
}

//! WebSocket Proxy Layer
//!
//! Centralizes all WebSocket send/recv operations, enabling:
//! - Authentication checks before message processing
//! - Permission validation (master vs slave)
//! - Future extensibility (rate limiting, audit logging, metrics)

const std = @import("std");
const websocket = @import("websocket.zig");

const log = std.log.scoped(.ws_proxy);

/// Authentication roles derived from tokens.
pub const AuthRole = enum {
    none,
    view,
    master,
};

/// Centralized auth token store for connections.
pub const AuthStore = struct {
    allocator: std.mem.Allocator,
    master_token: []const u8,
    view_token: []const u8,

    pub fn init(allocator: std.mem.Allocator, master_token: []const u8, view_token: []const u8) !AuthStore {
        return .{
            .allocator = allocator,
            .master_token = try allocator.dupe(u8, master_token),
            .view_token = try allocator.dupe(u8, view_token),
        };
    }

    pub fn deinit(self: *AuthStore) void {
        self.allocator.free(self.master_token);
        self.allocator.free(self.view_token);
    }

    fn tokensEqual(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        return std.ascii.eqlIgnoreCase(a, b);
    }

    fn extractPrefixedToken(input: []const u8, prefix: []const u8) ?[]const u8 {
        const idx = std.mem.indexOf(u8, input, prefix) orelse return null;
        var rest = input[idx + prefix.len ..];
        rest = std.mem.trimLeft(u8, rest, " \t\r\n");
        const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
        if (end == 0) return null;
        return rest[0..end];
    }

    pub fn roleForToken(self: *const AuthStore, token: ?[]const u8) AuthRole {
        if (token) |raw| {
            const value = std.mem.trim(u8, raw, " \t\r\n");
            if (value.len == 0) return .none;

            if (extractPrefixedToken(value, "master=")) |candidate| {
                return if (tokensEqual(candidate, self.master_token)) .master else .none;
            }
            if (extractPrefixedToken(value, "view=")) |candidate| {
                return if (tokensEqual(candidate, self.view_token)) .view else .none;
            }

            if (tokensEqual(value, self.master_token)) return .master;
            if (tokensEqual(value, self.view_token)) return .view;
        }
        return .none;
    }

    pub fn canRequestMaster(role: AuthRole) bool {
        return role == .master;
    }

    pub fn canControl(role: AuthRole) bool {
        return role == .master;
    }
};

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

    fn markCongested(client: anytype) void {
        if (@hasField(@TypeOf(client.*), "write_congested")) {
            if (client.ws.hasPendingWrite()) {
                client.write_congested = true;
            }
        }
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
        markCongested(client);
    }

    /// Send binary message to a single client without auth check.
    /// Use this for initial connection handshake messages.
    pub fn sendUnchecked(client: anytype, msg: []const u8) !void {
        try client.ws.sendBinary(msg);
        markCongested(client);
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
                markCongested(client);
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
            markCongested(client);
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
                markCongested(client);
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
                            markCongested(client);
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

test "AuthStore roleForToken" {
    var store = try AuthStore.init(std.testing.allocator, "master-token", "view-token");
    defer store.deinit();

    try std.testing.expectEqual(AuthRole.master, store.roleForToken("master-token"));
    try std.testing.expectEqual(AuthRole.view, store.roleForToken("view-token"));
    try std.testing.expectEqual(AuthRole.master, store.roleForToken("master=master-token"));
    try std.testing.expectEqual(AuthRole.view, store.roleForToken("view=view-token"));
    try std.testing.expectEqual(AuthRole.view, store.roleForToken("  view-token\n"));
    try std.testing.expectEqual(AuthRole.master, store.roleForToken("master=master-token view=view-token"));
    try std.testing.expectEqual(AuthRole.view, store.roleForToken("view=view-token master=master-token"));
    try std.testing.expectEqual(AuthRole.master, store.roleForToken("MASTER-TOKEN"));
    try std.testing.expectEqual(AuthRole.none, store.roleForToken("nope"));
    try std.testing.expectEqual(AuthRole.none, store.roleForToken(null));
}

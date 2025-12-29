//! HTTP server with WebSocket upgrade for dullahan
//!
//! Listens on a port and upgrades connections to WebSocket for terminal communication.

const std = @import("std");
const websocket = @import("websocket.zig");

const log = std.log.scoped(.http);

pub const DEFAULT_PORT: u16 = 7681;

/// HTTP request parsed from raw data
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn isWebSocketUpgrade(self: *const Request) bool {
        const upgrade = self.getHeader("upgrade") orelse return false;
        const connection = self.getHeader("connection") orelse return false;

        // Check if upgrade header contains "websocket" (case-insensitive)
        var has_websocket = false;
        var it = std.mem.splitScalar(u8, upgrade, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (std.ascii.eqlIgnoreCase(trimmed, "websocket")) {
                has_websocket = true;
                break;
            }
        }

        // Check if connection header contains "upgrade" (case-insensitive)
        var has_upgrade = false;
        var it2 = std.mem.splitScalar(u8, connection, ',');
        while (it2.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (std.ascii.eqlIgnoreCase(trimmed, "upgrade")) {
                has_upgrade = true;
                break;
            }
        }

        return has_websocket and has_upgrade;
    }

    pub fn getWebSocketKey(self: *const Request) ?[]const u8 {
        return self.getHeader("sec-websocket-key");
    }
};

/// Parse HTTP request from raw bytes
pub fn parseRequest(allocator: std.mem.Allocator, data: []const u8) !Request {
    var lines = std.mem.splitSequence(u8, data, "\r\n");

    // First line: method path version
    const request_line = lines.next() orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, request_line, ' ');

    const method = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;

    // Parse headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();

    while (lines.next()) |line| {
        if (line.len == 0) break; // Empty line ends headers

        const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
        const name = std.mem.trim(u8, line[0..colon_idx], " \t");
        const value = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");

        // Store header name in lowercase for easier lookup
        const lower_name = try allocator.alloc(u8, name.len);
        for (name, 0..) |c, i| {
            lower_name[i] = std.ascii.toLower(c);
        }

        try headers.put(lower_name, value);
    }

    return .{
        .method = method,
        .path = path,
        .headers = headers,
    };
}

/// Send HTTP response
pub fn sendResponse(stream: std.net.Stream, status: []const u8, headers: []const [2][]const u8, body: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.print("HTTP/1.1 {s}\r\n", .{status});
    for (headers) |header| {
        try writer.print("{s}: {s}\r\n", .{ header[0], header[1] });
    }
    try writer.print("Content-Length: {d}\r\n", .{body.len});
    try writer.writeAll("\r\n");
    try writer.writeAll(body);

    _ = try stream.write(fbs.getWritten());
}

/// Send WebSocket upgrade response
pub fn sendWebSocketUpgrade(stream: std.net.Stream, client_key: []const u8) !void {
    const accept_key = websocket.computeAcceptKey(client_key);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.print("Sec-WebSocket-Accept: {s}\r\n", .{accept_key});
    try writer.writeAll("\r\n");

    _ = try stream.write(fbs.getWritten());
}

/// HTTP/WebSocket server
pub const Server = struct {
    listener: std.net.Server,
    allocator: std.mem.Allocator,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, port: u16) !Server {
        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        const listener = try address.listen(.{
            .reuse_address = true,
        });

        log.info("HTTP server listening on port {d}", .{port});

        return .{
            .listener = listener,
            .allocator = allocator,
            .port = port,
        };
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit();
    }

    /// Accept a connection and handle HTTP/WebSocket upgrade
    /// Returns a WebSocket connection if upgrade succeeded, null otherwise
    pub fn acceptWebSocket(self: *Server) !?websocket.Connection {
        const conn = try self.listener.accept();
        errdefer conn.stream.close();

        // Read HTTP request
        var buf: [4096]u8 = undefined;
        const n = try conn.stream.read(&buf);
        if (n == 0) {
            conn.stream.close();
            return null;
        }

        // Parse request
        var request = parseRequest(self.allocator, buf[0..n]) catch |e| {
            log.err("Failed to parse HTTP request: {any}", .{e});
            sendResponse(conn.stream, "400 Bad Request", &.{}, "Bad Request") catch {};
            conn.stream.close();
            return null;
        };
        defer request.deinit();

        log.debug("HTTP {s} {s}", .{ request.method, request.path });

        // Check for WebSocket upgrade
        if (!request.isWebSocketUpgrade()) {
            // Regular HTTP - serve a simple page
            const html =
                \\<!DOCTYPE html>
                \\<html><body>
                \\<h1>Dullahan Terminal Server</h1>
                \\<p>Connect via WebSocket on this port.</p>
                \\</body></html>
            ;
            sendResponse(conn.stream, "200 OK", &.{.{ "Content-Type", "text/html" }}, html) catch {};
            conn.stream.close();
            return null;
        }

        // WebSocket upgrade
        const client_key = request.getWebSocketKey() orelse {
            sendResponse(conn.stream, "400 Bad Request", &.{}, "Missing Sec-WebSocket-Key") catch {};
            conn.stream.close();
            return null;
        };

        sendWebSocketUpgrade(conn.stream, client_key) catch |e| {
            log.err("Failed to send WebSocket upgrade: {any}", .{e});
            conn.stream.close();
            return null;
        };

        log.info("WebSocket connection established from {any}", .{conn.address});

        return websocket.Connection.init(conn.stream, self.allocator);
    }
};

test "parse http request" {
    const allocator = std.testing.allocator;
    const request_data =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: localhost:7681\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "\r\n";

    var request = try parseRequest(allocator, request_data);
    defer request.deinit();

    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("/ws", request.path);
    try std.testing.expect(request.isWebSocketUpgrade());
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", request.getWebSocketKey().?);
}

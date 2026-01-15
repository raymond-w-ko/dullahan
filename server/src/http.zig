//! HTTP server with WebSocket upgrade and static file serving
//!
//! Listens on a port and either:
//! - Upgrades connections to WebSocket for terminal communication
//! - Serves static files from a directory or embedded assets

const std = @import("std");
const posix = std.posix;
const constants = @import("constants.zig");
const websocket = @import("websocket.zig");
const embedded_assets = @import("embedded_assets.zig");

const log = std.log.scoped(.http);

pub const DEFAULT_PORT: u16 = 7681;

/// HTTP request parsed from raw data
pub const Request = struct {
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),

    pub fn deinit(self: *Request) void {
        // Free the allocated lowercase header keys
        var it = self.headers.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
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
    errdefer {
        var it = headers.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        headers.deinit();
    }

    while (lines.next()) |line| {
        if (line.len == 0) break; // Empty line ends headers

        const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
        const name = std.mem.trim(u8, line[0..colon_idx], " \t");
        const value = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");

        // Store header name in lowercase for easier lookup
        const lower_name = try allocator.alloc(u8, name.len);
        errdefer allocator.free(lower_name);
        for (name, 0..) |c, i| {
            lower_name[i] = std.ascii.toLower(c);
        }

        try headers.put(lower_name, value);
    }

    return .{
        .allocator = allocator,
        .method = method,
        .path = path,
        .headers = headers,
    };
}

/// Send HTTP response with body
pub fn sendResponse(stream: std.net.Stream, status: []const u8, headers: []const [2][]const u8, body: []const u8) !void {
    var buf: [constants.buffer.general]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.print("HTTP/1.1 {s}\r\n", .{status});
    for (headers) |header| {
        try writer.print("{s}: {s}\r\n", .{ header[0], header[1] });
    }
    try writer.print("Content-Length: {d}\r\n", .{body.len});
    try writer.writeAll("\r\n");
    try writer.writeAll(body);

    try websocket.streamWriteAll(stream, fbs.getWritten());
}

/// Send HTTP response headers only (for streaming body)
pub fn sendResponseHeaders(stream: std.net.Stream, status: []const u8, headers: []const [2][]const u8, content_length: usize) !void {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.print("HTTP/1.1 {s}\r\n", .{status});
    for (headers) |header| {
        try writer.print("{s}: {s}\r\n", .{ header[0], header[1] });
    }
    try writer.print("Content-Length: {d}\r\n", .{content_length});
    try writer.writeAll("\r\n");

    try websocket.streamWriteAll(stream, fbs.getWritten());
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

    try websocket.streamWriteAll(stream, fbs.getWritten());
}

/// Get MIME type for file extension
fn getMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".ttf")) return "font/ttf";
    if (std.mem.eql(u8, ext, ".map")) return "application/json";
    return "application/octet-stream";
}

/// HTTP/WebSocket server
pub const Server = struct {
    listener: std.net.Server,
    allocator: std.mem.Allocator,
    port: u16,
    static_dir: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, port: u16, static_dir: ?[]const u8) !Server {
        // Only accept connections from localhost for security
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const listener = try address.listen(.{
            .reuse_address = true,
            .kernel_backlog = 128, // Handle burst of connections on refresh
        });

        if (static_dir) |dir| {
            log.info("HTTP server listening on port {d}, serving static files from {s}", .{ port, dir });
        } else {
            log.info("HTTP server listening on port {d}", .{port});
        }

        return .{
            .listener = listener,
            .allocator = allocator,
            .port = port,
            .static_dir = static_dir,
        };
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit();
    }

    /// Serve a static file (from embedded assets or filesystem)
    fn serveFile(self: *Server, stream: std.net.Stream, url_path: []const u8, request: *const Request) void {
        // Try embedded assets first (for single-binary distribution)
        if (self.serveEmbeddedFile(stream, url_path, request)) {
            return;
        }

        const static_dir = self.static_dir orelse {
            self.serveNotFound(stream);
            return;
        };

        // Sanitize path - remove leading slash, handle directory traversal
        var clean_path = url_path;
        if (clean_path.len > 0 and clean_path[0] == '/') {
            clean_path = clean_path[1..];
        }

        // Block directory traversal
        if (std.mem.indexOf(u8, clean_path, "..") != null) {
            self.serveForbidden(stream);
            return;
        }

        // Default to index.html for root
        if (clean_path.len == 0) {
            clean_path = "index.html";
        }

        // Build full path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ static_dir, clean_path }) catch {
            self.serveError(stream);
            return;
        };

        // Open and read file
        const file = std.fs.cwd().openFile(full_path, .{}) catch {
            log.debug("File not found: {s}", .{full_path});
            self.serveNotFound(stream);
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            self.serveError(stream);
            return;
        };

        const file_size = stat.size;
        const mime_type = getMimeType(clean_path);

        // Generate ETag from mtime and size
        var etag_buf: [64]u8 = undefined;
        const mtime_sec: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
        const etag = std.fmt.bufPrint(&etag_buf, "\"{x}-{x}\"", .{ @as(u64, @bitCast(mtime_sec)), file_size }) catch "\"0\"";

        // Check If-None-Match for 304 response
        if (request.getHeader("if-none-match")) |client_etag| {
            if (std.mem.eql(u8, client_etag, etag)) {
                sendResponse(stream, "304 Not Modified", &.{
                    .{ "ETag", etag },
                    .{ "Cache-Control", "no-cache" },
                    .{ "Pragma", "no-cache" },
                }, "") catch {};
                return;
            }
        }

        log.debug("Serving {s} ({d} bytes, {s})", .{ clean_path, file_size, mime_type });

        // Send headers with ETag
        sendResponseHeaders(stream, "200 OK", &.{
            .{ "Content-Type", mime_type },
            .{ "Cache-Control", "no-cache" },
            .{ "Pragma", "no-cache" },
            .{ "ETag", etag },
        }, file_size) catch {
            return;
        };

        // Stream file content
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = file.read(&buf) catch return;
            if (n == 0) break;
            websocket.streamWriteAll(stream, buf[0..n]) catch return;
        }
    }

    /// Serve a file from embedded assets, returns true if served
    fn serveEmbeddedFile(self: *Server, stream: std.net.Stream, url_path: []const u8, request: *const Request) bool {
        _ = self;

        // Normalize path for lookup
        const lookup_path = if (url_path.len == 0 or std.mem.eql(u8, url_path, "/"))
            "/"
        else
            url_path;

        const asset = embedded_assets.get(lookup_path) orelse return false;

        log.debug("Serving embedded asset: {s} ({d} bytes, {s}, etag={s})", .{
            lookup_path,
            asset.content.len,
            asset.mime_type,
            asset.etag,
        });

        // Check If-None-Match for 304 response
        if (request.getHeader("if-none-match")) |client_etag| {
            if (std.mem.eql(u8, client_etag, asset.etag)) {
                sendResponse(stream, "304 Not Modified", &.{
                    .{ "ETag", asset.etag },
                    .{ "Cache-Control", "no-cache" },
                }, "") catch {};
                return true;
            }
        }

        // Send headers first, then stream body (files can be large)
        sendResponseHeaders(stream, "200 OK", &.{
            .{ "Content-Type", asset.mime_type },
            .{ "Cache-Control", "no-cache" },
            .{ "ETag", asset.etag },
        }, asset.content.len) catch return true;

        // Stream body
        websocket.streamWriteAll(stream, asset.content) catch {};

        return true;
    }

    fn serveNotFound(self: *Server, stream: std.net.Stream) void {
        _ = self;
        const body = "<!DOCTYPE html><html><body><h1>404 Not Found</h1></body></html>";
        sendResponse(stream, "404 Not Found", &.{
            .{ "Content-Type", "text/html" },
        }, body) catch {};
    }

    fn serveForbidden(self: *Server, stream: std.net.Stream) void {
        _ = self;
        const body = "<!DOCTYPE html><html><body><h1>403 Forbidden</h1></body></html>";
        sendResponse(stream, "403 Forbidden", &.{
            .{ "Content-Type", "text/html" },
        }, body) catch {};
    }

    fn serveError(self: *Server, stream: std.net.Stream) void {
        _ = self;
        const body = "<!DOCTYPE html><html><body><h1>500 Internal Server Error</h1></body></html>";
        sendResponse(stream, "500 Internal Server Error", &.{
            .{ "Content-Type", "text/html" },
        }, body) catch {};
    }

    /// Get the underlying socket fd for polling
    pub fn getFd(self: *Server) posix.fd_t {
        return self.listener.stream.handle;
    }

    /// Accept a connection with timeout (non-blocking with poll)
    /// Returns null if timeout expires, error on failure, or WebSocket connection on success
    /// timeout_ms: timeout in milliseconds (-1 for infinite)
    pub fn acceptWebSocketTimeout(self: *Server, timeout_ms: i32) !?websocket.Connection {
        // Poll the listener socket with timeout
        var poll_fds = [_]posix.pollfd{
            .{ .fd = self.listener.stream.handle, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&poll_fds, timeout_ms) catch |e| {
            return e;
        };

        // Timeout - no connection available
        if (ready == 0) {
            return null;
        }

        // Check for errors
        if (poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            return error.SocketError;
        }

        // Connection available - delegate to regular accept
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            return self.acceptWebSocket();
        }

        return null;
    }

    /// Accept a connection and handle HTTP/WebSocket upgrade
    /// Returns a WebSocket connection if upgrade succeeded, null otherwise
    pub fn acceptWebSocket(self: *Server) !?websocket.Connection {
        log.debug("Waiting for connection...", .{});
        const conn = try self.listener.accept();
        log.debug("Accepted connection, reading request...", .{});
        errdefer conn.stream.close();

        // Set read/write timeouts so we don't block forever
        const timeout = std.posix.timeval{
            .sec = 0,
            .usec = constants.timeout.http_read_ms * 1000,
        };
        std.posix.setsockopt(
            conn.stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {};
        std.posix.setsockopt(
            conn.stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {};

        // Read HTTP request
        var buf: [constants.buffer.general]u8 = undefined;
        const n = conn.stream.read(&buf) catch |e| {
            if (e == error.WouldBlock) {
                log.debug("Read timeout waiting for HTTP request", .{});
                conn.stream.close();
                return null;
            }
            return e;
        };
        log.debug("Read {d} bytes", .{n});
        if (n == 0) {
            log.debug("Empty request, closing", .{});
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

        log.debug("HTTP {s} {s} (upgrade={any})", .{ request.method, request.path, request.isWebSocketUpgrade() });

        // Check for WebSocket upgrade
        if (!request.isWebSocketUpgrade()) {
            // Serve static file
            self.serveFile(conn.stream, request.path, &request);
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

test "mime types" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getMimeType("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", getMimeType("style.css"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", getMimeType("app.js"));
    try std.testing.expectEqualStrings("image/png", getMimeType("logo.png"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("unknown.xyz"));
}

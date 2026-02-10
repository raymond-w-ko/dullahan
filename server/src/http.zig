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
const tls_wrapper = @import("tls_wrapper.zig");

const log = std.log.scoped(.http);

pub const DEFAULT_PORT: u16 = 7681;

const HANDSHAKE_TIMEOUT_MS: i64 = 5_000;
const FIRST_BYTE_TIMEOUT_MS: i64 = 250;
const HEADER_COMPLETE_TIMEOUT_MS: i64 = 2_000;
const MAX_HEADER_BYTES: usize = 16 * 1024;

fn setNonBlocking(fd: posix.fd_t, enabled: bool) void {
    const fl_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    const O_NONBLOCK: usize = if (@import("builtin").os.tag == .macos) 0x4 else 0x800;
    const new_flags = if (enabled) (fl_flags | O_NONBLOCK) else (fl_flags & ~O_NONBLOCK);
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, new_flags) catch {};
}

fn setSocketTimeoutMs(fd: posix.fd_t, timeout_ms: u32) void {
    const timeout = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    ) catch {};
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&timeout),
    ) catch {};
}

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
pub fn sendResponse(stream: *tls_wrapper.Stream, status: []const u8, headers: []const [2][]const u8, body: []const u8) !void {
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

    try stream.writeAll(fbs.getWritten());
}

/// Send HTTP response headers only (for streaming body)
pub fn sendResponseHeaders(stream: *tls_wrapper.Stream, status: []const u8, headers: []const [2][]const u8, content_length: usize) !void {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.print("HTTP/1.1 {s}\r\n", .{status});
    for (headers) |header| {
        try writer.print("{s}: {s}\r\n", .{ header[0], header[1] });
    }
    try writer.print("Content-Length: {d}\r\n", .{content_length});
    try writer.writeAll("\r\n");

    try stream.writeAll(fbs.getWritten());
}

/// Send WebSocket upgrade response
pub fn sendWebSocketUpgrade(stream: *tls_wrapper.Stream, client_key: []const u8) !void {
    const accept_key = websocket.computeAcceptKey(client_key);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.print("Sec-WebSocket-Accept: {s}\r\n", .{accept_key});
    try writer.writeAll("\r\n");

    try stream.writeAll(fbs.getWritten());
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

const PendingStream = union(enum) {
    plain: std.net.Stream,
    tls_handshake: tls_wrapper.TlsHandshake,
    tls: tls_wrapper.TlsConnection,

    fn handle(self: *const PendingStream) posix.fd_t {
        return switch (self.*) {
            .plain => |s| s.handle,
            .tls_handshake => |*hs| hs.handle(),
            .tls => |*t| t.handle(),
        };
    }

    fn isTls(self: *const PendingStream) bool {
        return switch (self.*) {
            .plain => false,
            .tls_handshake, .tls => true,
        };
    }

    fn hasPendingData(self: *const PendingStream) bool {
        return switch (self.*) {
            .tls => |*t| t.hasPendingData(),
            else => false,
        };
    }

    fn close(self: *PendingStream) void {
        switch (self.*) {
            .plain => |s| s.close(),
            .tls_handshake => |*hs| hs.deinit(),
            .tls => |*t| t.close(),
        }
    }
};

const PendingConn = struct {
    stream: PendingStream,
    peer_addr: std.net.Address,
    accepted_ms: i64,
    handshake_done_ms: ?i64 = null,
    first_byte_ms: ?i64 = null,
    deadline_ms: i64,
    req_buf: std.ArrayListUnmanaged(u8) = .{},

    fn init(tls_context: ?*tls_wrapper.TlsContext, conn: std.net.Server.Connection) !PendingConn {
        // Keep accepted sockets non-blocking so event loop never stalls.
        setNonBlocking(conn.stream.handle, true);

        // Disable Nagle's algorithm for low-latency interactive traffic.
        const nodelay: c_int = 1;
        std.posix.setsockopt(
            conn.stream.handle,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&nodelay),
        ) catch {};

        const accepted_ms = std.time.milliTimestamp();
        if (tls_context) |tls_ctx| {
            const handshake = try tls_ctx.beginHandshake(conn.stream);
            return .{
                .stream = .{ .tls_handshake = handshake },
                .peer_addr = conn.address,
                .accepted_ms = accepted_ms,
                .deadline_ms = accepted_ms + HANDSHAKE_TIMEOUT_MS,
            };
        }

        return .{
            .stream = .{ .plain = conn.stream },
            .peer_addr = conn.address,
            .accepted_ms = accepted_ms,
            .deadline_ms = accepted_ms + FIRST_BYTE_TIMEOUT_MS,
        };
    }

    fn deinit(self: *PendingConn, allocator: std.mem.Allocator) void {
        self.req_buf.deinit(allocator);
        self.stream.close();
    }

    fn getFd(self: *const PendingConn) posix.fd_t {
        return self.stream.handle();
    }

    fn pollEvents(self: *const PendingConn) i16 {
        return switch (self.stream) {
            .tls_handshake => posix.POLL.IN | posix.POLL.OUT,
            else => posix.POLL.IN,
        };
    }
};

/// HTTP/WebSocket server
pub const Server = struct {
    listener: std.net.Server,
    allocator: std.mem.Allocator,
    port: u16,
    static_dir: ?[]const u8,
    tls_context: ?*tls_wrapper.TlsContext,
    pending: std.ArrayListUnmanaged(PendingConn) = .{},
    ready_ws: std.ArrayListUnmanaged(websocket.Connection) = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        static_dir: ?[]const u8,
        bind_all: bool,
        tls_context: ?*tls_wrapper.TlsContext,
    ) !Server {
        // Bind to all interfaces if requested (e.g., for Tailscale), otherwise localhost only
        const address = if (bind_all)
            std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port)
        else
            std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);

        const listener = try address.listen(.{
            .reuse_address = true,
            .kernel_backlog = 128, // Handle burst of connections on refresh
        });
        setNonBlocking(listener.stream.handle, true);

        const bind_addr = if (bind_all) "0.0.0.0" else "127.0.0.1";
        const protocol = if (tls_context != null) "HTTPS" else "HTTP";
        if (static_dir) |dir| {
            log.info("{s} server listening on {s}:{d}, serving static files from {s}", .{ protocol, bind_addr, port, dir });
        } else {
            log.info("{s} server listening on {s}:{d}", .{ protocol, bind_addr, port });
        }

        return .{
            .listener = listener,
            .allocator = allocator,
            .port = port,
            .static_dir = static_dir,
            .tls_context = tls_context,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.pending.items) |*pending| {
            pending.deinit(self.allocator);
        }
        self.pending.deinit(self.allocator);

        for (self.ready_ws.items) |*ws| {
            ws.deinit();
        }
        self.ready_ws.deinit(self.allocator);

        self.listener.deinit();
    }

    /// Check if TLS is enabled
    pub fn isTlsEnabled(self: *const Server) bool {
        return self.tls_context != null;
    }

    /// Serve a static file (from embedded assets or filesystem)
    fn serveFile(self: *Server, stream: *tls_wrapper.Stream, url_path: []const u8, request: *const Request) void {
        // Strip query string if present (e.g., "/?debug" -> "/")
        const query_idx = std.mem.indexOf(u8, url_path, "?");
        const path_only = if (query_idx) |idx| url_path[0..idx] else url_path;

        // Try embedded assets first (for single-binary distribution)
        if (self.serveEmbeddedFile(stream, path_only, request)) {
            return;
        }

        const static_dir = self.static_dir orelse {
            self.serveNotFound(stream);
            return;
        };

        // Sanitize path - remove leading slash, handle directory traversal
        var clean_path = path_only;
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
            stream.writeAll(buf[0..n]) catch return;
        }
    }

    /// Serve a file from embedded assets, returns true if served
    fn serveEmbeddedFile(self: *Server, stream: *tls_wrapper.Stream, url_path: []const u8, request: *const Request) bool {
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
        stream.writeAll(asset.content) catch {};

        return true;
    }

    fn serveNotFound(self: *Server, stream: *tls_wrapper.Stream) void {
        _ = self;
        const body = "<!DOCTYPE html><html><body><h1>404 Not Found</h1></body></html>";
        sendResponse(stream, "404 Not Found", &.{
            .{ "Content-Type", "text/html" },
        }, body) catch {};
    }

    fn serveForbidden(self: *Server, stream: *tls_wrapper.Stream) void {
        _ = self;
        const body = "<!DOCTYPE html><html><body><h1>403 Forbidden</h1></body></html>";
        sendResponse(stream, "403 Forbidden", &.{
            .{ "Content-Type", "text/html" },
        }, body) catch {};
    }

    fn serveError(self: *Server, stream: *tls_wrapper.Stream) void {
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

    /// Number of pending accepted sockets still in TLS/HTTP upgrade phase.
    pub fn pendingCount(self: *const Server) usize {
        return self.pending.items.len;
    }

    /// Fill pollfds for pending sockets starting at `start_idx`.
    pub fn fillPendingPollSet(self: *const Server, fds: []posix.pollfd, start_idx: usize) void {
        var idx = start_idx;
        for (self.pending.items) |pending| {
            if (idx >= fds.len) break;
            fds[idx] = .{
                .fd = pending.getFd(),
                .events = pending.pollEvents(),
                .revents = 0,
            };
            idx += 1;
        }
    }

    /// Drain all immediately-acceptible sockets into pending state.
    pub fn enqueueAcceptedConnections(self: *Server) !void {
        while (true) {
            const conn = self.listener.accept() catch |e| switch (e) {
                error.WouldBlock => break,
                else => return e,
            };

            const pending = PendingConn.init(self.tls_context, conn) catch |e| {
                log.warn("Failed to initialize pending connection: {any}", .{e});
                conn.stream.close();
                continue;
            };
            try self.pending.append(self.allocator, pending);
        }
    }

    /// Process poll() revents for pending sockets (TLS handshake and HTTP parsing).
    pub fn processPendingPollEvents(self: *Server, pending_fds: []const posix.pollfd) !void {
        const count = @min(pending_fds.len, self.pending.items.len);
        var idx = count;
        while (idx > 0) {
            idx -= 1;
            if (idx >= self.pending.items.len) continue;

            const revents = pending_fds[idx].revents;
            if (revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                self.closeAndRemovePending(idx);
                continue;
            }

            switch (self.pending.items[idx].stream) {
                .tls_handshake => try self.processPendingHandshake(idx, revents),
                else => {
                    if (revents & posix.POLL.IN != 0 or self.pending.items[idx].stream.hasPendingData()) {
                        try self.readPendingRequest(idx);
                    }
                },
            }
        }
    }

    /// Expire pending sockets that exceeded their stage deadline.
    pub fn expirePendingConnections(self: *Server) void {
        const now = std.time.milliTimestamp();
        var idx = self.pending.items.len;
        while (idx > 0) {
            idx -= 1;
            if (idx >= self.pending.items.len) continue;
            const pending = &self.pending.items[idx];
            if (now <= pending.deadline_ms) continue;

            const accept_elapsed = now - pending.accepted_ms;
            const handshake_elapsed = if (pending.handshake_done_ms) |ms| ms - pending.accepted_ms else -1;
            switch (pending.stream) {
                .tls_handshake => log.debug("TLS handshake timeout after {d}ms (peer={any})", .{ accept_elapsed, pending.peer_addr }),
                else => log.debug(
                    "Read timeout waiting for HTTP request (accept {d}ms, handshake {d}ms, tls={}, peer={any})",
                    .{ accept_elapsed, handshake_elapsed, pending.stream.isTls(), pending.peer_addr },
                ),
            }
            self.closeAndRemovePending(idx);
        }
    }

    /// Pop one newly-upgraded WebSocket connection, if available.
    pub fn takeReadyWebSocket(self: *Server) ?websocket.Connection {
        if (self.ready_ws.items.len == 0) return null;
        const last = self.ready_ws.items.len - 1;
        return self.ready_ws.orderedRemove(last);
    }

    fn closeAndRemovePending(self: *Server, idx: usize) void {
        if (idx >= self.pending.items.len) return;
        var pending = self.pending.orderedRemove(idx);
        pending.deinit(self.allocator);
    }

    fn processPendingHandshake(self: *Server, idx: usize, revents: i16) !void {
        if (idx >= self.pending.items.len) return;
        if (revents & (posix.POLL.IN | posix.POLL.OUT) == 0) return;

        const pending = &self.pending.items[idx];
        switch (pending.stream) {
            .tls_handshake => |*handshake| {
                const done = handshake.advance() catch |e| switch (e) {
                    error.WouldBlock => return,
                    error.ConnectionClosed => {
                        self.closeAndRemovePending(idx);
                        return;
                    },
                    else => {
                        log.warn("TLS handshake failed: {any}", .{e});
                        self.closeAndRemovePending(idx);
                        return;
                    },
                };
                if (!done) return;

                const now = std.time.milliTimestamp();
                pending.handshake_done_ms = now;
                pending.deadline_ms = now + FIRST_BYTE_TIMEOUT_MS;
                log.debug(
                    "TLS handshake done in {d}ms",
                    .{now - pending.accepted_ms},
                );

                const tls_conn = handshake.intoConnection();
                pending.stream = .{ .tls = tls_conn };

                if (pending.stream.hasPendingData()) {
                    try self.readPendingRequest(idx);
                }
            },
            else => {},
        }
    }

    fn readPendingRequest(self: *Server, idx: usize) !void {
        while (idx < self.pending.items.len) {
            var pending = &self.pending.items[idx];

            if (pending.req_buf.items.len >= MAX_HEADER_BYTES) {
                log.warn("HTTP headers exceeded {d} bytes", .{MAX_HEADER_BYTES});
                self.respondAndClose(idx, "431 Request Header Fields Too Large", "Headers too large");
                return;
            }

            var buf: [constants.buffer.general]u8 = undefined;
            const n = switch (pending.stream) {
                .plain => |*plain| plain.read(&buf),
                .tls => |*tls_conn| tls_conn.read(&buf),
                .tls_handshake => return,
            } catch |e| switch (e) {
                error.WouldBlock => return,
                else => {
                    log.debug("Read error: {any}", .{e});
                    self.closeAndRemovePending(idx);
                    return;
                },
            };

            if (n == 0) {
                log.debug("Empty request, closing", .{});
                self.closeAndRemovePending(idx);
                return;
            }

            try pending.req_buf.appendSlice(self.allocator, buf[0..n]);

            if (pending.first_byte_ms == null) {
                const now = std.time.milliTimestamp();
                pending.first_byte_ms = now;
                pending.deadline_ms = now + HEADER_COMPLETE_TIMEOUT_MS;
            }

            if (std.mem.indexOf(u8, pending.req_buf.items, "\r\n\r\n") != null) {
                const now = std.time.milliTimestamp();
                const start_ms = pending.handshake_done_ms orelse pending.accepted_ms;
                log.debug(
                    "HTTP headers read in {d}ms (accept to headers {d}ms)",
                    .{ now - start_ms, now - pending.accepted_ms },
                );
                try self.finishPendingRequest(idx);
                return;
            }
        }
    }

    fn finishPendingRequest(self: *Server, idx: usize) !void {
        if (idx >= self.pending.items.len) return;
        const pending = &self.pending.items[idx];

        var request = parseRequest(self.allocator, pending.req_buf.items) catch |e| {
            log.err("Failed to parse HTTP request: {any}", .{e});
            self.respondAndClose(idx, "400 Bad Request", "Bad Request");
            return;
        };
        defer request.deinit();

        log.debug("HTTP {s} {s} (upgrade={any})", .{ request.method, request.path, request.isWebSocketUpgrade() });

        if (!request.isWebSocketUpgrade()) {
            self.serveRequestAndClose(idx, &request);
            return;
        }

        const client_key = request.getWebSocketKey() orelse {
            self.respondAndClose(idx, "400 Bad Request", "Missing Sec-WebSocket-Key");
            return;
        };

        try self.sendUpgradeAndPromote(idx, client_key);
    }

    fn respondAndClose(self: *Server, idx: usize, status: []const u8, body: []const u8) void {
        if (idx >= self.pending.items.len) return;
        var pending = &self.pending.items[idx];

        setNonBlocking(pending.getFd(), false);
        setSocketTimeoutMs(pending.getFd(), 1000);

        switch (pending.stream) {
            .plain => |*plain| {
                var stream: tls_wrapper.Stream = .{ .plain = plain.* };
                sendResponse(&stream, status, &.{}, body) catch {};
            },
            .tls => |*tls_conn| {
                var stream: tls_wrapper.Stream = .{ .tls = tls_conn.* };
                sendResponse(&stream, status, &.{}, body) catch {};
            },
            .tls_handshake => {},
        }

        self.closeAndRemovePending(idx);
    }

    fn serveRequestAndClose(self: *Server, idx: usize, request: *const Request) void {
        if (idx >= self.pending.items.len) return;
        var pending = &self.pending.items[idx];

        setNonBlocking(pending.getFd(), false);
        setSocketTimeoutMs(pending.getFd(), 5000);

        switch (pending.stream) {
            .plain => |*plain| {
                var stream: tls_wrapper.Stream = .{ .plain = plain.* };
                self.serveFile(&stream, request.path, request);
            },
            .tls => |*tls_conn| {
                var stream: tls_wrapper.Stream = .{ .tls = tls_conn.* };
                self.serveFile(&stream, request.path, request);
            },
            .tls_handshake => {},
        }

        self.closeAndRemovePending(idx);
    }

    fn sendUpgradeAndPromote(self: *Server, idx: usize, client_key: []const u8) !void {
        if (idx >= self.pending.items.len) return;
        var pending = &self.pending.items[idx];
        const peer_addr = pending.peer_addr;

        setNonBlocking(pending.getFd(), false);
        setSocketTimeoutMs(pending.getFd(), 1000);

        switch (pending.stream) {
            .plain => |*plain| {
                var stream: tls_wrapper.Stream = .{ .plain = plain.* };
                sendWebSocketUpgrade(&stream, client_key) catch |e| {
                    log.err("Failed to send WebSocket upgrade: {any}", .{e});
                    self.closeAndRemovePending(idx);
                    return;
                };
            },
            .tls => |*tls_conn| {
                var stream: tls_wrapper.Stream = .{ .tls = tls_conn.* };
                sendWebSocketUpgrade(&stream, client_key) catch |e| {
                    log.err("Failed to send WebSocket upgrade: {any}", .{e});
                    self.closeAndRemovePending(idx);
                    return;
                };
            },
            .tls_handshake => {
                self.closeAndRemovePending(idx);
                return;
            },
        }

        // Promote to non-blocking websocket transport.
        setNonBlocking(pending.getFd(), true);
        var promoted = self.pending.orderedRemove(idx);
        defer promoted.req_buf.deinit(self.allocator);

        const ws_stream: tls_wrapper.Stream = switch (promoted.stream) {
            .plain => |plain| .{ .plain = plain },
            .tls => |tls_conn| .{ .tls = tls_conn },
            .tls_handshake => unreachable,
        };

        var ws_conn = websocket.Connection.init(ws_stream, self.allocator);
        errdefer ws_conn.deinit();
        try self.ready_ws.append(self.allocator, ws_conn);

        log.info("WebSocket connection established from {any}", .{peer_addr});
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

//! HTTP server with WebSocket upgrade and static file serving
//!
//! Listens on a port and either:
//! - Upgrades connections to WebSocket for terminal communication
//! - Serves static files from a directory or embedded assets

const std = @import("std");
const posix = std.posix;
const constants = @import("constants.zig");
const paths = @import("paths.zig");
const websocket = @import("websocket.zig");
const embedded_assets = @import("embedded_assets.zig");
const tls_wrapper = @import("tls_wrapper.zig");

const log = std.log.scoped(.http);

pub const DEFAULT_PORT: u16 = 7681;

const HANDSHAKE_TIMEOUT_MS: i64 = 10_000;
const FIRST_BYTE_TIMEOUT_MS: i64 = 15_000;
const HEADER_COMPLETE_TIMEOUT_MS: i64 = 15_000;
const BODY_COMPLETE_TIMEOUT_MS: i64 = 60_000;
const WRITE_TIMEOUT_MS: i64 = 30_000;
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

fn buildWebSocketUpgradeResponse(allocator: std.mem.Allocator, client_key: []const u8) !PendingBuffer {
    const accept_key = websocket.computeAcceptKey(client_key);
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);

    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.print("Sec-WebSocket-Accept: {s}\r\n", .{accept_key});
    try writer.writeAll("\r\n");

    return .{
        .data = try out.toOwnedSlice(allocator),
    };
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

fn parseContentLength(raw: []const u8) !usize {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return error.InvalidContentLength;
    return std.fmt.parseInt(usize, trimmed, 10);
}

fn pathWithoutQuery(path: []const u8) []const u8 {
    const query_idx = std.mem.indexOf(u8, path, "?");
    return if (query_idx) |idx| path[0..idx] else path;
}

fn extForImageMime(content_type: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(content_type, "image/png")) return "png";
    if (std.ascii.eqlIgnoreCase(content_type, "image/jpeg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(content_type, "image/webp")) return "webp";
    if (std.ascii.eqlIgnoreCase(content_type, "image/gif")) return "gif";
    if (std.ascii.eqlIgnoreCase(content_type, "image/bmp")) return "bmp";
    if (std.ascii.eqlIgnoreCase(content_type, "image/tiff")) return "tiff";
    if (std.ascii.eqlIgnoreCase(content_type, "image/heic")) return "heic";
    return "img";
}

fn readTokensFile(path: []const u8, buf: []u8) !?struct { master: []const u8, view: []const u8 } {
    const file = std.fs.openFileAbsolute(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer file.close();

    const n = try file.readAll(buf);
    if (n == 0) return null;

    var master: ?[]const u8 = null;
    var view: ?[]const u8 = null;
    var iter = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "master=")) {
            master = std.mem.trim(u8, line["master=".len..], " \t\r\n");
        } else if (std.mem.startsWith(u8, line, "view=")) {
            view = std.mem.trim(u8, line["view=".len..], " \t\r\n");
        }
    }

    if (master == null or view == null) return null;
    return .{ .master = master.?, .view = view.? };
}

fn isUploadAuthorized(request: *const Request) bool {
    const auth = request.getHeader("authorization") orelse return false;
    if (auth.len < 8) return false;
    if (!std.ascii.eqlIgnoreCase(auth[0..7], "Bearer ")) return false;

    const token = std.mem.trim(u8, auth[7..], " \t");
    if (token.len == 0) return false;

    var tokens_buf: [256]u8 = undefined;
    const tokens = readTokensFile(paths.StaticPaths.tokens(), &tokens_buf) catch return false;
    if (tokens == null) return false;

    return std.mem.eql(u8, token, tokens.?.master);
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

const PendingBuffer = struct {
    data: []u8,
    sent: usize = 0,

    fn deinit(self: *PendingBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    fn hasRemaining(self: *const PendingBuffer) bool {
        return self.sent < self.data.len;
    }
};

const PendingBody = union(enum) {
    none,
    bytes: struct {
        data: []const u8,
        sent: usize = 0,
    },
    owned_bytes: struct {
        data: []u8,
        sent: usize = 0,
    },
    file: struct {
        file: std.fs.File,
        remaining: u64,
        chunk: [16 * 1024]u8 = undefined,
        chunk_len: usize = 0,
        chunk_sent: usize = 0,
    },

    fn deinit(self: *PendingBody, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .owned_bytes => |*b| allocator.free(b.data),
            .file => |*f| f.file.close(),
            else => {},
        }
        self.* = .none;
    }

    fn hasRemaining(self: *const PendingBody) bool {
        return switch (self.*) {
            .none => false,
            .bytes => |b| b.sent < b.data.len,
            .owned_bytes => |b| b.sent < b.data.len,
            .file => |f| f.remaining > 0 or f.chunk_sent < f.chunk_len,
        };
    }
};

const PendingResponse = struct {
    header: PendingBuffer,
    body: PendingBody = .none,

    fn deinit(self: *PendingResponse, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        self.body.deinit(allocator);
    }

    fn hasRemaining(self: *const PendingResponse) bool {
        return self.header.hasRemaining() or self.body.hasRemaining();
    }
};

const PendingWriteState = union(enum) {
    none,
    http: PendingResponse,
    ws_upgrade: PendingBuffer,

    fn deinit(self: *PendingWriteState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .http => |*response| response.deinit(allocator),
            .ws_upgrade => |*upgrade| upgrade.deinit(allocator),
            .none => {},
        }
        self.* = .none;
    }

    fn hasRemaining(self: *const PendingWriteState) bool {
        return switch (self.*) {
            .none => false,
            .http => |response| response.hasRemaining(),
            .ws_upgrade => |upgrade| upgrade.hasRemaining(),
        };
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
    header_end: ?usize = null,
    expected_total_bytes: ?usize = null,
    write_state: PendingWriteState = .none,

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
        self.write_state.deinit(allocator);
        self.req_buf.deinit(allocator);
        self.stream.close();
    }

    fn getFd(self: *const PendingConn) posix.fd_t {
        return self.stream.handle();
    }

    fn pollEvents(self: *const PendingConn) i16 {
        return switch (self.stream) {
            .tls_handshake => posix.POLL.IN | posix.POLL.OUT,
            else => if (self.write_state.hasRemaining())
                posix.POLL.IN | posix.POLL.OUT
            else
                posix.POLL.IN,
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

    fn buildResponseHeader(
        self: *Server,
        status: []const u8,
        headers: []const [2][]const u8,
        content_length: u64,
    ) !PendingBuffer {
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(self.allocator);
        const writer = out.writer(self.allocator);
        try writer.print("HTTP/1.1 {s}\r\n", .{status});
        for (headers) |header| {
            try writer.print("{s}: {s}\r\n", .{ header[0], header[1] });
        }
        try writer.print("Content-Length: {d}\r\n", .{content_length});
        try writer.writeAll("\r\n");

        return .{
            .data = try out.toOwnedSlice(self.allocator),
        };
    }

    fn buildSimpleResponse(
        self: *Server,
        status: []const u8,
        headers: []const [2][]const u8,
        body: []const u8,
    ) !PendingResponse {
        return .{
            .header = try self.buildResponseHeader(status, headers, body.len),
            .body = .{
                .bytes = .{
                    .data = body,
                },
            },
        };
    }

    fn buildNotFoundResponse(self: *Server) !PendingResponse {
        const body = "<!DOCTYPE html><html><body><h1>404 Not Found</h1></body></html>";
        return self.buildSimpleResponse("404 Not Found", &.{
            .{ "Content-Type", "text/html" },
        }, body);
    }

    fn buildForbiddenResponse(self: *Server) !PendingResponse {
        const body = "<!DOCTYPE html><html><body><h1>403 Forbidden</h1></body></html>";
        return self.buildSimpleResponse("403 Forbidden", &.{
            .{ "Content-Type", "text/html" },
        }, body);
    }

    fn buildErrorResponse(self: *Server) !PendingResponse {
        const body = "<!DOCTYPE html><html><body><h1>500 Internal Server Error</h1></body></html>";
        return self.buildSimpleResponse("500 Internal Server Error", &.{
            .{ "Content-Type", "text/html" },
        }, body);
    }

    fn buildEmbeddedResponse(self: *Server, url_path: []const u8, request: *const Request) !?PendingResponse {
        const lookup_path = if (url_path.len == 0 or std.mem.eql(u8, url_path, "/"))
            "/"
        else
            url_path;
        const asset = embedded_assets.get(lookup_path) orelse return null;

        log.debug("Serving embedded asset: {s} ({d} bytes, {s}, etag={s})", .{
            lookup_path,
            asset.content.len,
            asset.mime_type,
            asset.etag,
        });

        if (request.getHeader("if-none-match")) |client_etag| {
            if (std.mem.eql(u8, client_etag, asset.etag)) {
                const not_modified = try self.buildSimpleResponse("304 Not Modified", &.{
                    .{ "ETag", asset.etag },
                    .{ "Cache-Control", "no-cache" },
                }, "");
                return not_modified;
            }
        }

        return .{
            .header = try self.buildResponseHeader("200 OK", &.{
                .{ "Content-Type", asset.mime_type },
                .{ "Cache-Control", "no-cache" },
                .{ "ETag", asset.etag },
            }, asset.content.len),
            .body = .{
                .bytes = .{
                    .data = asset.content,
                },
            },
        };
    }

    fn buildStaticFileResponse(self: *Server, url_path: []const u8, request: *const Request) !PendingResponse {
        const query_idx = std.mem.indexOf(u8, url_path, "?");
        const path_only = if (query_idx) |idx| url_path[0..idx] else url_path;

        if (try self.buildEmbeddedResponse(path_only, request)) |embedded| {
            return embedded;
        }

        const static_dir = self.static_dir orelse return self.buildNotFoundResponse();

        var clean_path = path_only;
        if (clean_path.len > 0 and clean_path[0] == '/') {
            clean_path = clean_path[1..];
        }
        if (std.mem.indexOf(u8, clean_path, "..") != null) {
            return self.buildForbiddenResponse();
        }
        if (clean_path.len == 0) {
            clean_path = "index.html";
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ static_dir, clean_path }) catch {
            return self.buildErrorResponse();
        };

        const file = std.fs.cwd().openFile(full_path, .{}) catch {
            log.debug("File not found: {s}", .{full_path});
            return self.buildNotFoundResponse();
        };
        errdefer file.close();

        const stat = file.stat() catch return self.buildErrorResponse();
        const file_size = stat.size;
        const mime_type = getMimeType(clean_path);

        var etag_buf: [64]u8 = undefined;
        const mtime_sec: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
        const etag = std.fmt.bufPrint(&etag_buf, "\"{x}-{x}\"", .{ @as(u64, @bitCast(mtime_sec)), file_size }) catch "\"0\"";

        if (request.getHeader("if-none-match")) |client_etag| {
            if (std.mem.eql(u8, client_etag, etag)) {
                return self.buildSimpleResponse("304 Not Modified", &.{
                    .{ "ETag", etag },
                    .{ "Cache-Control", "no-cache" },
                    .{ "Pragma", "no-cache" },
                }, "");
            }
        }

        log.debug("Serving {s} ({d} bytes, {s})", .{ clean_path, file_size, mime_type });
        return .{
            .header = try self.buildResponseHeader("200 OK", &.{
                .{ "Content-Type", mime_type },
                .{ "Cache-Control", "no-cache" },
                .{ "Pragma", "no-cache" },
                .{ "ETag", etag },
            }, file_size),
            .body = .{
                .file = .{
                    .file = file,
                    .remaining = file_size,
                },
            },
        };
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

            if (self.pending.items[idx].stream == .tls_handshake) {
                try self.processPendingHandshake(idx, revents);
                continue;
            }

            if (self.pending.items[idx].write_state.hasRemaining()) {
                // TLS writes may need either readability (WANT_READ) or writability (WANT_WRITE).
                if (revents & (posix.POLL.OUT | posix.POLL.IN) != 0) {
                    self.flushPendingWrite(idx) catch |e| {
                        log.debug("Pending write failed: {any}", .{e});
                        self.closeAndRemovePending(idx);
                    };
                }
                continue;
            }

            if (revents & posix.POLL.IN != 0 or self.pending.items[idx].stream.hasPendingData()) {
                try self.readPendingRequest(idx);
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
            if (pending.write_state.hasRemaining()) {
                log.debug(
                    "Write timeout sending HTTP response (accept {d}ms, handshake {d}ms, tls={}, peer={any})",
                    .{ accept_elapsed, handshake_elapsed, pending.stream.isTls(), pending.peer_addr },
                );
            } else switch (pending.stream) {
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

            if (pending.header_end == null and pending.req_buf.items.len >= MAX_HEADER_BYTES) {
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

            if (pending.header_end == null) {
                if (std.mem.indexOf(u8, pending.req_buf.items, "\r\n\r\n")) |header_delim_idx| {
                    const header_end = header_delim_idx + 4;
                    pending.header_end = header_end;

                    const now = std.time.milliTimestamp();
                    const start_ms = pending.handshake_done_ms orelse pending.accepted_ms;
                    log.debug(
                        "HTTP headers read in {d}ms (accept to headers {d}ms)",
                        .{ now - start_ms, now - pending.accepted_ms },
                    );

                    var header_request = parseRequest(self.allocator, pending.req_buf.items[0..header_end]) catch |e| {
                        log.err("Failed to parse HTTP headers: {any}", .{e});
                        self.respondAndClose(idx, "400 Bad Request", "Bad Request");
                        return;
                    };
                    defer header_request.deinit();

                    const content_length: usize = blk: {
                        const raw = header_request.getHeader("content-length") orelse break :blk 0;
                        const parsed = parseContentLength(raw) catch {
                            self.respondAndClose(idx, "400 Bad Request", "Invalid Content-Length");
                            return;
                        };
                        break :blk parsed;
                    };

                    if (content_length > constants.upload.max_image_paste_bytes) {
                        self.respondAndClose(idx, "413 Payload Too Large", "Payload too large");
                        return;
                    }

                    const expected_total = std.math.add(usize, header_end, content_length) catch {
                        self.respondAndClose(idx, "413 Payload Too Large", "Payload too large");
                        return;
                    };
                    pending.expected_total_bytes = expected_total;
                    pending.deadline_ms = now + (if (content_length > 0) BODY_COMPLETE_TIMEOUT_MS else HEADER_COMPLETE_TIMEOUT_MS);
                }
            }

            if (pending.expected_total_bytes) |expected_total| {
                if (pending.req_buf.items.len >= expected_total) {
                    try self.finishPendingRequest(idx);
                    return;
                }
            }
        }
    }

    fn finishPendingRequest(self: *Server, idx: usize) !void {
        if (idx >= self.pending.items.len) return;
        const pending = &self.pending.items[idx];

        const header_end = pending.header_end orelse blk: {
            const found = std.mem.indexOf(u8, pending.req_buf.items, "\r\n\r\n") orelse {
                self.respondAndClose(idx, "400 Bad Request", "Bad Request");
                return;
            };
            break :blk found + 4;
        };
        const expected_total = pending.expected_total_bytes orelse pending.req_buf.items.len;
        if (expected_total < header_end or pending.req_buf.items.len < expected_total) {
            self.respondAndClose(idx, "400 Bad Request", "Bad Request");
            return;
        }

        var request = parseRequest(self.allocator, pending.req_buf.items[0..header_end]) catch |e| {
            log.err("Failed to parse HTTP request: {any}", .{e});
            self.respondAndClose(idx, "400 Bad Request", "Bad Request");
            return;
        };
        defer request.deinit();
        const body = pending.req_buf.items[header_end..expected_total];

        log.debug("HTTP {s} {s} (upgrade={any})", .{ request.method, request.path, request.isWebSocketUpgrade() });

        if (!request.isWebSocketUpgrade()) {
            self.serveRequestAndClose(idx, &request, body);
            return;
        }

        const client_key = request.getWebSocketKey() orelse {
            self.respondAndClose(idx, "400 Bad Request", "Missing Sec-WebSocket-Key");
            return;
        };

        try self.sendUpgradeAndPromote(idx, client_key);
    }

    fn respondAndClose(self: *Server, idx: usize, status: []const u8, body: []const u8) void {
        const response = self.buildSimpleResponse(status, &.{
            .{ "Content-Type", "text/plain; charset=utf-8" },
        }, body) catch {
            self.closeAndRemovePending(idx);
            return;
        };
        self.queuePendingHttpResponse(idx, response);
    }

    fn serveRequestAndClose(self: *Server, idx: usize, request: *const Request, body: []const u8) void {
        const req_path = pathWithoutQuery(request.path);
        if (std.mem.eql(u8, req_path, "/api/paste-image")) {
            self.handleImageUploadAndClose(idx, request, body);
            return;
        }

        const response = self.buildStaticFileResponse(request.path, request) catch {
            const fallback = self.buildErrorResponse() catch {
                self.closeAndRemovePending(idx);
                return;
            };
            self.queuePendingHttpResponse(idx, fallback);
            return;
        };
        self.queuePendingHttpResponse(idx, response);
    }

    fn handleImageUploadAndClose(self: *Server, idx: usize, request: *const Request, body: []const u8) void {
        if (!std.mem.eql(u8, request.method, "POST")) {
            self.respondAndClose(idx, "405 Method Not Allowed", "Method Not Allowed");
            return;
        }

        if (!isUploadAuthorized(request)) {
            self.respondAndClose(idx, "401 Unauthorized", "Unauthorized");
            return;
        }

        const content_type_header = request.getHeader("content-type") orelse {
            self.respondAndClose(idx, "415 Unsupported Media Type", "Missing Content-Type");
            return;
        };
        const semicolon_idx = std.mem.indexOf(u8, content_type_header, ";");
        const content_type = std.mem.trim(u8, if (semicolon_idx) |i| content_type_header[0..i] else content_type_header, " \t");
        if (!std.mem.startsWith(u8, content_type, "image/")) {
            self.respondAndClose(idx, "415 Unsupported Media Type", "Expected image/* Content-Type");
            return;
        }

        if (body.len == 0) {
            self.respondAndClose(idx, "400 Bad Request", "Empty image payload");
            return;
        }
        if (body.len > constants.upload.max_image_paste_bytes) {
            self.respondAndClose(idx, "413 Payload Too Large", "Payload too large");
            return;
        }

        paths.ensureTempDir() catch {
            self.respondAndClose(idx, "500 Internal Server Error", "Failed to prepare temp dir");
            return;
        };

        var rand_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_bytes);
        var rand_hex: [16]u8 = undefined;
        for (rand_bytes, 0..) |b, i| {
            rand_hex[i * 2] = if ((b >> 4) < 10) '0' + @as(u8, (b >> 4)) else 'a' + @as(u8, (b >> 4) - 10);
            rand_hex[i * 2 + 1] = if ((b & 0x0F) < 10) '0' + @as(u8, (b & 0x0F)) else 'a' + @as(u8, (b & 0x0F) - 10);
        }

        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        const ext = extForImageMime(content_type);

        var filename_buf: [96]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "paste-image-{d}-{s}.{s}", .{
            now_ms,
            rand_hex,
            ext,
        }) catch {
            self.respondAndClose(idx, "500 Internal Server Error", "Failed to allocate upload name");
            return;
        };

        const uploaded_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
            paths.getTempDir(),
            filename,
        }) catch {
            self.respondAndClose(idx, "500 Internal Server Error", "Failed to allocate upload path");
            return;
        };
        defer self.allocator.free(uploaded_path);

        const file = std.fs.createFileAbsolute(uploaded_path, .{
            .truncate = true,
            .mode = 0o600,
        }) catch {
            self.respondAndClose(idx, "500 Internal Server Error", "Failed to create upload file");
            return;
        };
        defer file.close();

        file.writeAll(body) catch {
            self.respondAndClose(idx, "500 Internal Server Error", "Failed to store upload");
            return;
        };

        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{body.len}) catch "0";

        const response = self.buildSimpleResponse("201 Created", &.{
            .{ "Content-Type", "application/json; charset=utf-8" },
            .{ "Cache-Control", "no-store" },
            .{ "X-Dullahan-Image-Path", uploaded_path },
            .{ "X-Dullahan-Image-Mime", content_type },
            .{ "X-Dullahan-Image-Size", size_str },
        }, "{\"ok\":true}") catch {
            self.closeAndRemovePending(idx);
            return;
        };

        log.debug("Stored image upload ({d} bytes) at {s}", .{ body.len, uploaded_path });
        self.queuePendingHttpResponse(idx, response);
    }

    fn sendUpgradeAndPromote(self: *Server, idx: usize, client_key: []const u8) !void {
        if (idx >= self.pending.items.len) return;
        const upgrade = try buildWebSocketUpgradeResponse(self.allocator, client_key);
        self.queuePendingWsUpgrade(idx, upgrade);
    }

    fn queuePendingHttpResponse(self: *Server, idx: usize, response: PendingResponse) void {
        if (idx >= self.pending.items.len) {
            var tmp = response;
            tmp.deinit(self.allocator);
            return;
        }
        var pending = &self.pending.items[idx];
        pending.write_state.deinit(self.allocator);
        pending.write_state = .{ .http = response };
        pending.deadline_ms = std.time.milliTimestamp() + WRITE_TIMEOUT_MS;

        self.flushPendingWrite(idx) catch |e| {
            log.debug("Failed to flush queued HTTP response: {any}", .{e});
            self.closeAndRemovePending(idx);
        };
    }

    fn queuePendingWsUpgrade(self: *Server, idx: usize, upgrade: PendingBuffer) void {
        if (idx >= self.pending.items.len) {
            var tmp = upgrade;
            tmp.deinit(self.allocator);
            return;
        }
        var pending = &self.pending.items[idx];
        pending.write_state.deinit(self.allocator);
        pending.write_state = .{ .ws_upgrade = upgrade };
        pending.deadline_ms = std.time.milliTimestamp() + WRITE_TIMEOUT_MS;

        self.flushPendingWrite(idx) catch |e| {
            log.debug("Failed to flush queued WS upgrade: {any}", .{e});
            self.closeAndRemovePending(idx);
        };
    }

    fn writeToPendingStream(self: *Server, pending: *PendingConn, data: []const u8) !usize {
        _ = self;
        return switch (pending.stream) {
            .plain => |*plain| plain.write(data),
            .tls => |*tls_conn| tls_conn.write(data),
            .tls_handshake => error.InvalidState,
        };
    }

    fn flushPendingBuffer(self: *Server, pending: *PendingConn, buffer: *PendingBuffer) !bool {
        while (buffer.hasRemaining()) {
            const n = self.writeToPendingStream(pending, buffer.data[buffer.sent..]) catch |e| switch (e) {
                error.WouldBlock => return false,
                else => return e,
            };
            if (n == 0) return error.ConnectionClosed;
            buffer.sent += n;
            pending.deadline_ms = std.time.milliTimestamp() + WRITE_TIMEOUT_MS;
        }
        return true;
    }

    fn flushPendingResponse(self: *Server, pending: *PendingConn, response: *PendingResponse) !bool {
        if (try self.flushPendingBuffer(pending, &response.header) == false) {
            return false;
        }

        switch (response.body) {
            .none => return true,
            .bytes => |*body| {
                while (body.sent < body.data.len) {
                    const n = self.writeToPendingStream(pending, body.data[body.sent..]) catch |e| switch (e) {
                        error.WouldBlock => return false,
                        else => return e,
                    };
                    if (n == 0) return error.ConnectionClosed;
                    body.sent += n;
                    pending.deadline_ms = std.time.milliTimestamp() + WRITE_TIMEOUT_MS;
                }
                return true;
            },
            .owned_bytes => |*body| {
                while (body.sent < body.data.len) {
                    const n = self.writeToPendingStream(pending, body.data[body.sent..]) catch |e| switch (e) {
                        error.WouldBlock => return false,
                        else => return e,
                    };
                    if (n == 0) return error.ConnectionClosed;
                    body.sent += n;
                    pending.deadline_ms = std.time.milliTimestamp() + WRITE_TIMEOUT_MS;
                }
                return true;
            },
            .file => |*file_body| {
                while (true) {
                    if (file_body.chunk_sent < file_body.chunk_len) {
                        const n = self.writeToPendingStream(pending, file_body.chunk[file_body.chunk_sent..file_body.chunk_len]) catch |e| switch (e) {
                            error.WouldBlock => return false,
                            else => return e,
                        };
                        if (n == 0) return error.ConnectionClosed;
                        file_body.chunk_sent += n;
                        pending.deadline_ms = std.time.milliTimestamp() + WRITE_TIMEOUT_MS;
                        continue;
                    }

                    if (file_body.remaining == 0) return true;

                    const chunk_cap_u64: u64 = @intCast(file_body.chunk.len);
                    const to_read: usize = @intCast(@min(chunk_cap_u64, file_body.remaining));
                    const n_read = file_body.file.read(file_body.chunk[0..to_read]) catch return error.ReadFailed;
                    if (n_read == 0) {
                        file_body.remaining = 0;
                        return true;
                    }
                    file_body.remaining -= @as(u64, @intCast(n_read));
                    file_body.chunk_len = n_read;
                    file_body.chunk_sent = 0;
                }
            },
        }
    }

    fn flushPendingWrite(self: *Server, idx: usize) !void {
        if (idx >= self.pending.items.len) return;
        var pending = &self.pending.items[idx];

        switch (pending.write_state) {
            .none => return,
            .http => |*response| {
                if (!try self.flushPendingResponse(pending, response)) return;
                self.closeAndRemovePending(idx);
            },
            .ws_upgrade => |*upgrade| {
                if (!try self.flushPendingBuffer(pending, upgrade)) return;
                try self.promotePendingWebSocket(idx);
            },
        }
    }

    fn promotePendingWebSocket(self: *Server, idx: usize) !void {
        if (idx >= self.pending.items.len) return;

        const peer_addr = self.pending.items[idx].peer_addr;
        var promoted = self.pending.orderedRemove(idx);
        defer promoted.req_buf.deinit(self.allocator);
        defer promoted.write_state.deinit(self.allocator);

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

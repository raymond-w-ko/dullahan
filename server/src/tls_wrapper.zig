//! TLS wrapper for Dullahan
//!
//! Provides a unified Stream type that works for both plain TCP and TLS connections.
//! Uses system OpenSSL (libssl/libcrypto) for TLS support.

const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

const log = std.log.scoped(.tls);

fn initOpenSsl() void {
    if (@hasDecl(c, "OPENSSL_init_ssl")) {
        _ = c.OPENSSL_init_ssl(0, null);
    } else {
        _ = c.SSL_library_init();
        c.SSL_load_error_strings();
    }
}

fn logOpenSslErrors(context: []const u8) void {
    var err = c.ERR_get_error();
    if (err == 0) {
        log.err("{s}: unknown OpenSSL error", .{context});
        return;
    }
    while (err != 0) {
        var buf: [256]u8 = undefined;
        _ = c.ERR_error_string_n(err, &buf, buf.len);
        const msg = std.mem.sliceTo(buf[0..], 0);
        log.err("{s}: {s}", .{ context, msg });
        err = c.ERR_get_error();
    }
}

fn logSslFailure(context: []const u8, rc: c_int, ssl_error: c_int) void {
    log.err("{s}: rc={d} ssl_error={d}", .{ context, rc, ssl_error });
}

fn handleSslResult(ssl: *c.SSL, rc: c_int, context: []const u8) !usize {
    const err = c.SSL_get_error(ssl, rc);
    switch (err) {
        c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => return error.WouldBlock,
        c.SSL_ERROR_ZERO_RETURN => return 0,
        c.SSL_ERROR_SYSCALL => {
            if (rc == 0) return 0;
            logSslFailure(context, rc, err);
            logOpenSslErrors(context);
            return error.TlsSyscall;
        },
        else => {
            logSslFailure(context, rc, err);
            logOpenSslErrors(context);
            return error.TlsFailure;
        },
    }
}

/// Configuration for TLS server
pub const TlsConfig = struct {
    cert_path: []const u8,
    key_path: []const u8,
};

/// TLS server context - holds loaded certificates and keys
pub const TlsContext = struct {
    ctx: *c.SSL_CTX,
    allocator: std.mem.Allocator,

    /// Initialize TLS context by loading certificate and key from PEM files
    pub fn init(allocator: std.mem.Allocator, config: TlsConfig) !TlsContext {
        initOpenSsl();

        log.info("Loading TLS certificate from {s}", .{config.cert_path});
        log.info("Loading TLS key from {s}", .{config.key_path});

        // Check key file permissions (warn if world-readable)
        if (std.fs.cwd().statFile(config.key_path)) |stat| {
            const mode = stat.mode;
            if (mode & 0o004 != 0) {
                log.warn("TLS key file {s} is world-readable. Consider restricting permissions.", .{config.key_path});
            }
        } else |_| {}

        const method = c.TLS_server_method() orelse {
            logOpenSslErrors("TLS_server_method");
            return error.TlsInitFailed;
        };
        const ctx = c.SSL_CTX_new(method) orelse {
            logOpenSslErrors("SSL_CTX_new");
            return error.TlsInitFailed;
        };

        const cert_path_z = try allocator.dupeZ(u8, config.cert_path);
        defer allocator.free(cert_path_z);
        const key_path_z = try allocator.dupeZ(u8, config.key_path);
        defer allocator.free(key_path_z);

        if (c.SSL_CTX_use_certificate_file(ctx, cert_path_z, c.SSL_FILETYPE_PEM) != 1) {
            logOpenSslErrors("SSL_CTX_use_certificate_file");
            c.SSL_CTX_free(ctx);
            return error.TlsInitFailed;
        }
        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path_z, c.SSL_FILETYPE_PEM) != 1) {
            logOpenSslErrors("SSL_CTX_use_PrivateKey_file");
            c.SSL_CTX_free(ctx);
            return error.TlsInitFailed;
        }
        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            logOpenSslErrors("SSL_CTX_check_private_key");
            c.SSL_CTX_free(ctx);
            return error.TlsInitFailed;
        }

        log.info("TLS context initialized successfully", .{});

        return .{
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TlsContext) void {
        _ = self.allocator;
        c.SSL_CTX_free(self.ctx);
    }

    /// Perform TLS handshake on an accepted connection
    /// Returns a TLS connection wrapper
    pub fn upgrade(self: *TlsContext, tcp_stream: std.net.Stream) !TlsConnection {
        log.debug("Starting TLS handshake", .{});

        // Disable Nagle's algorithm for TLS connections
        // This ensures small writes (like delta updates) are sent immediately
        // rather than being buffered, which is critical for real-time terminal updates
        const nodelay: c_int = 1;
        posix.setsockopt(
            tcp_stream.handle,
            posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&nodelay),
        ) catch |e| {
            log.warn("Failed to set TCP_NODELAY: {}", .{e});
        };

        const ssl = c.SSL_new(self.ctx) orelse {
            logOpenSslErrors("SSL_new");
            return error.TlsInitFailed;
        };

        const mode_flags: c_ulong = c.SSL_MODE_ENABLE_PARTIAL_WRITE | c.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER;
        _ = c.SSL_set_mode(ssl, mode_flags);

        if (c.SSL_set_fd(ssl, @intCast(tcp_stream.handle)) != 1) {
            logOpenSslErrors("SSL_set_fd");
            c.SSL_free(ssl);
            return error.TlsInitFailed;
        }

        const accept_rc = c.SSL_accept(ssl);
        if (accept_rc != 1) {
            const accept_err = c.SSL_get_error(ssl, accept_rc);
            logSslFailure("SSL_accept", accept_rc, accept_err);
            logOpenSslErrors("SSL_accept");
            c.SSL_free(ssl);
            return error.TlsHandshakeFailed;
        }

        log.debug("TLS handshake completed successfully", .{});

        return .{
            .ssl = ssl,
            .tcp_stream = tcp_stream,
        };
    }

    /// Begin a non-blocking TLS handshake.
    /// Call `TlsHandshake.advance()` until it returns true.
    pub fn beginHandshake(self: *TlsContext, tcp_stream: std.net.Stream) !TlsHandshake {
        log.debug("Starting TLS handshake (non-blocking)", .{});

        // Disable Nagle's algorithm for TLS connections.
        const nodelay: c_int = 1;
        posix.setsockopt(
            tcp_stream.handle,
            posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&nodelay),
        ) catch |e| {
            log.warn("Failed to set TCP_NODELAY: {}", .{e});
        };

        const ssl = c.SSL_new(self.ctx) orelse {
            logOpenSslErrors("SSL_new");
            return error.TlsInitFailed;
        };

        const mode_flags: c_ulong = c.SSL_MODE_ENABLE_PARTIAL_WRITE | c.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER;
        _ = c.SSL_set_mode(ssl, mode_flags);

        if (c.SSL_set_fd(ssl, @intCast(tcp_stream.handle)) != 1) {
            logOpenSslErrors("SSL_set_fd");
            c.SSL_free(ssl);
            return error.TlsInitFailed;
        }

        return .{
            .ssl = ssl,
            .tcp_stream = tcp_stream,
            .completed = false,
        };
    }
};

/// Incremental TLS handshake state for poll/event-loop driven servers.
pub const TlsHandshake = struct {
    ssl: *c.SSL,
    tcp_stream: std.net.Stream,
    completed: bool = false,

    /// Progress one step of TLS handshake.
    /// Returns true once handshake is complete.
    pub fn advance(self: *TlsHandshake) !bool {
        if (self.completed) return true;

        const accept_rc = c.SSL_accept(self.ssl);
        if (accept_rc == 1) {
            self.completed = true;
            log.debug("TLS handshake completed successfully", .{});
            return true;
        }

        const accept_err = c.SSL_get_error(self.ssl, accept_rc);
        switch (accept_err) {
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => return error.WouldBlock,
            c.SSL_ERROR_ZERO_RETURN => return error.ConnectionClosed,
            c.SSL_ERROR_SYSCALL => {
                if (accept_rc == 0) return error.ConnectionClosed;
                logSslFailure("SSL_accept", accept_rc, accept_err);
                logOpenSslErrors("SSL_accept");
                return error.TlsSyscall;
            },
            else => {
                logSslFailure("SSL_accept", accept_rc, accept_err);
                logOpenSslErrors("SSL_accept");
                return error.TlsHandshakeFailed;
            },
        }
    }

    /// Convert a completed handshake into a TLS connection.
    pub fn intoConnection(self: *TlsHandshake) TlsConnection {
        std.debug.assert(self.completed);
        return .{
            .ssl = self.ssl,
            .tcp_stream = self.tcp_stream,
        };
    }

    /// Underlying socket fd for poll().
    pub fn handle(self: *const TlsHandshake) posix.fd_t {
        return self.tcp_stream.handle;
    }

    /// Cleanup an in-progress handshake.
    pub fn deinit(self: *TlsHandshake) void {
        if (self.completed) return;
        c.SSL_free(self.ssl);
        self.tcp_stream.close();
    }
};

/// TLS connection - wraps an OpenSSL SSL* connection
pub const TlsConnection = struct {
    ssl: *c.SSL,
    tcp_stream: std.net.Stream,

    pub fn read(self: *TlsConnection, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        const max_len: usize = @intCast(std.math.maxInt(c_int));
        const len: c_int = @intCast(@min(buf.len, max_len));
        const rc = c.SSL_read(self.ssl, buf.ptr, len);
        if (rc > 0) return @intCast(rc);
        return handleSslResult(self.ssl, rc, "TLS read");
    }

    pub fn write(self: *TlsConnection, data: []const u8) !usize {
        if (data.len == 0) return 0;
        const max_len: usize = @intCast(std.math.maxInt(c_int));
        const len: c_int = @intCast(@min(data.len, max_len));
        const rc = c.SSL_write(self.ssl, data.ptr, len);
        if (rc > 0) return @intCast(rc);
        return handleSslResult(self.ssl, rc, "TLS write");
    }

    pub fn close(self: *TlsConnection) void {
        // Send TLS close_notify alert
        const shutdown_rc = c.SSL_shutdown(self.ssl);
        if (shutdown_rc == 0) {
            _ = c.SSL_shutdown(self.ssl);
        }
        c.SSL_free(self.ssl);
        self.tcp_stream.close();
    }

    /// Get the underlying socket fd for polling
    pub fn handle(self: *const TlsConnection) posix.fd_t {
        return self.tcp_stream.handle;
    }

    /// Check if the TLS layer has buffered data waiting to be read.
    /// This is important for event loops: poll() checks the TCP socket,
    /// but the TLS library may have already read and decrypted more data
    /// than we consumed. We need to check this before going back to poll().
    pub fn hasPendingData(self: *const TlsConnection) bool {
        return c.SSL_pending(self.ssl) > 0;
    }
};

/// Unified stream type that handles both plain TCP and TLS connections
pub const Stream = union(enum) {
    plain: std.net.Stream,
    tls: TlsConnection,

    /// Read from the stream
    pub fn read(self: *Stream, buf: []u8) !usize {
        return switch (self.*) {
            .plain => |s| s.read(buf),
            .tls => |*t| t.read(buf),
        };
    }

    /// Write to the stream
    pub fn write(self: *Stream, data: []const u8) !usize {
        return switch (self.*) {
            .plain => |s| s.write(data),
            .tls => |*t| t.write(data),
        };
    }

    /// Write all data, handling partial writes
    pub fn writeAll(self: *Stream, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try self.write(data[written..]);
            if (n == 0) return error.ConnectionClosed;
            written += n;
        }
    }

    /// Get the underlying socket fd for polling
    pub fn handle(self: *const Stream) posix.fd_t {
        return switch (self.*) {
            .plain => |s| s.handle,
            .tls => |*t| t.handle(),
        };
    }

    /// Check if there's buffered data waiting to be read.
    /// For TLS connections, this checks the TLS layer's internal buffers.
    /// For plain TCP, this always returns false (poll() is accurate).
    pub fn hasPendingData(self: *Stream) bool {
        return switch (self.*) {
            .plain => false,
            .tls => |*t| t.hasPendingData(),
        };
    }

    /// Close the stream
    pub fn close(self: *Stream) void {
        switch (self.*) {
            .plain => |s| s.close(),
            .tls => |*t| t.close(),
        }
    }
};

test "Stream union size" {
    // TLS Connection contains encryption buffers, so it's large
    // Just verify it's reasonable (under 64KB)
    try std.testing.expect(@sizeOf(Stream) < 64 * 1024);
}

//! TLS wrapper for Dullahan
//!
//! Provides a unified Stream type that works for both plain TCP and TLS connections.
//! Uses ianic/tls.zig for TLS 1.3 support.

const std = @import("std");
const posix = std.posix;
const tls_lib = @import("tls");

const log = std.log.scoped(.tls);

/// Configuration for TLS server
pub const TlsConfig = struct {
    cert_path: []const u8,
    key_path: []const u8,
};

/// TLS server context - holds loaded certificates and keys
pub const TlsContext = struct {
    cert_key_pair: tls_lib.config.CertKeyPair,
    allocator: std.mem.Allocator,

    /// Initialize TLS context by loading certificate and key from PEM files
    pub fn init(allocator: std.mem.Allocator, config: TlsConfig) !TlsContext {
        log.info("Loading TLS certificate from {s}", .{config.cert_path});
        log.info("Loading TLS key from {s}", .{config.key_path});

        // Check key file permissions (warn if world-readable)
        if (std.fs.cwd().statFile(config.key_path)) |stat| {
            const mode = stat.mode;
            if (mode & 0o004 != 0) {
                log.warn("TLS key file {s} is world-readable. Consider restricting permissions.", .{config.key_path});
            }
        } else |_| {}

        // Load certificate and key from files
        // Use fromFilePathAbsolute for absolute paths, fromFilePath for relative
        const cert_key_pair = tls_lib.config.CertKeyPair.fromFilePath(
            allocator,
            std.fs.cwd(),
            config.cert_path,
            config.key_path,
        ) catch |e| {
            log.err("Failed to load TLS certificate/key: {}", .{e});
            return e;
        };

        log.info("TLS context initialized successfully", .{});

        return .{
            .cert_key_pair = cert_key_pair,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TlsContext) void {
        self.cert_key_pair.deinit(self.allocator);
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

        const tls_conn = tls_lib.server(tcp_stream, .{
            .auth = &self.cert_key_pair,
        }) catch |e| {
            log.err("TLS handshake failed: {}", .{e});
            return e;
        };

        log.debug("TLS handshake completed successfully", .{});

        return .{
            .conn = tls_conn,
            .tcp_stream = tcp_stream,
        };
    }
};

/// TLS connection - wraps the tls.zig Connection
pub const TlsConnection = struct {
    conn: tls_lib.Connection(std.net.Stream),
    tcp_stream: std.net.Stream,

    pub fn read(self: *TlsConnection, buf: []u8) !usize {
        return self.conn.read(buf) catch |e| {
            if (e == error.EndOfStream) return 0;
            return e;
        };
    }

    pub fn write(self: *TlsConnection, data: []const u8) !usize {
        return self.conn.write(data) catch |e| {
            if (e == error.WouldBlock) return e;
            log.err("TLS write failed: {} (data_len={})", .{ e, data.len });
            return e;
        };
    }

    pub fn close(self: *TlsConnection) void {
        // Send TLS close_notify alert
        self.conn.close() catch {};
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
    pub fn hasPendingData(self: *TlsConnection) bool {
        // Check both: decrypted data in read_buf and encrypted data in record reader
        return self.conn.read_buf.len > 0 or self.conn.rec_rdr.hasMore();
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

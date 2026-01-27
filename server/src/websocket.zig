//! WebSocket implementation for dullahan
//!
//! Implements RFC 6455 WebSocket protocol for terminal communication.

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const base64 = std.base64;
const tls_wrapper = @import("tls_wrapper.zig");

const log = std.log.scoped(.websocket);

/// WebSocket frame opcodes
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// WebSocket frame header
pub const FrameHeader = struct {
    fin: bool,
    opcode: Opcode,
    mask: bool,
    payload_len: u64,
    masking_key: ?[4]u8,
};

/// Parse WebSocket frame header from bytes
pub fn parseFrameHeader(data: []const u8) !struct { header: FrameHeader, header_len: usize } {
    if (data.len < 2) return error.InsufficientData;

    const byte0 = data[0];
    const byte1 = data[1];

    const fin = (byte0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(byte0 & 0x0F)));
    const mask = (byte1 & 0x80) != 0;
    var payload_len: u64 = byte1 & 0x7F;

    var offset: usize = 2;

    if (payload_len == 126) {
        if (data.len < 4) return error.InsufficientData;
        payload_len = std.mem.readInt(u16, data[2..4], .big);
        offset = 4;
    } else if (payload_len == 127) {
        if (data.len < 10) return error.InsufficientData;
        payload_len = std.mem.readInt(u64, data[2..10], .big);
        offset = 10;
    }

    var masking_key: ?[4]u8 = null;
    if (mask) {
        if (data.len < offset + 4) return error.InsufficientData;
        masking_key = data[offset..][0..4].*;
        offset += 4;
    }

    return .{
        .header = .{
            .fin = fin,
            .opcode = opcode,
            .mask = mask,
            .payload_len = payload_len,
            .masking_key = masking_key,
        },
        .header_len = offset,
    };
}

/// Unmask payload data in-place
pub fn unmaskPayload(data: []u8, masking_key: [4]u8) void {
    for (data, 0..) |*byte, i| {
        byte.* ^= masking_key[i % 4];
    }
}

/// Create a WebSocket frame (server -> client, no masking)
pub fn createFrame(allocator: std.mem.Allocator, opcode: Opcode, payload: []const u8) ![]u8 {
    var frame: std.ArrayListUnmanaged(u8) = .{};
    errdefer frame.deinit(allocator);

    // First byte: FIN + opcode
    try frame.append(allocator, 0x80 | @as(u8, @intFromEnum(opcode)));

    // Payload length (no mask for server -> client)
    if (payload.len < 126) {
        try frame.append(allocator, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        try frame.append(allocator, 126);
        try frame.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(payload.len))));
    } else {
        try frame.append(allocator, 127);
        try frame.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, payload.len)));
    }

    // Payload data
    try frame.appendSlice(allocator, payload);

    return frame.toOwnedSlice(allocator);
}

/// WebSocket handshake magic GUID
const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Compute WebSocket accept key from client key
pub fn computeAcceptKey(client_key: []const u8) [28]u8 {
    var hasher = Sha1.init(.{});
    hasher.update(client_key);
    hasher.update(WS_MAGIC);
    const hash = hasher.finalResult();

    var accept_key: [28]u8 = undefined;
    _ = base64.standard.Encoder.encode(&accept_key, &hash);
    return accept_key;
}

/// WebSocket connection state
pub const Connection = struct {
    stream: tls_wrapper.Stream,
    allocator: std.mem.Allocator,

    pub fn init(stream: tls_wrapper.Stream, allocator: std.mem.Allocator) Connection {
        // Set socket options for robustness after suspend/resume
        // TCP keepalive: detect dead connections after machine sleep
        const fd = stream.handle();
        const keepalive_enable: c_int = 1;
        std.posix.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.KEEPALIVE,
            std.mem.asBytes(&keepalive_enable),
        ) catch {};

        // Write timeout: prevent blocking forever on stale sockets
        // 10 seconds is enough for network issues, but catches dead connections
        const write_timeout = std.posix.timeval{
            .sec = 10,
            .usec = 0,
        };
        std.posix.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&write_timeout),
        ) catch {};

        return .{
            .stream = stream,
            .allocator = allocator,
        };
    }

    /// Get underlying file descriptor for polling
    pub fn getFd(self: *const Connection) std.posix.fd_t {
        return self.stream.handle();
    }

    /// Set read timeout for polling (0 = no timeout)
    pub fn setReadTimeout(self: *Connection, timeout_ms: u32) void {
        const timeout = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(
            self.stream.handle(),
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {};
    }

    /// Set write timeout (0 = no timeout)
    pub fn setWriteTimeout(self: *Connection, timeout_ms: u32) void {
        const timeout = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(
            self.stream.handle(),
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {};
    }

    /// Set both read and write timeouts
    pub fn setTimeouts(self: *Connection, timeout_ms: u32) void {
        self.setReadTimeout(timeout_ms);
        self.setWriteTimeout(timeout_ms);
    }

    /// Send a text message
    pub fn sendText(self: *Connection, message: []const u8) !void {
        const frame = try createFrame(self.allocator, .text, message);
        defer self.allocator.free(frame);
        try self.stream.writeAll(frame);
    }

    /// Send a binary message
    pub fn sendBinary(self: *Connection, data: []const u8) !void {
        const frame = try createFrame(self.allocator, .binary, data);
        defer self.allocator.free(frame);
        try self.stream.writeAll(frame);
    }

    /// Send a close frame
    pub fn sendClose(self: *Connection) !void {
        const frame = try createFrame(self.allocator, .close, &.{});
        defer self.allocator.free(frame);
        try self.stream.writeAll(frame);
    }

    /// Send a pong frame (response to ping)
    pub fn sendPong(self: *Connection, payload: []const u8) !void {
        const frame = try createFrame(self.allocator, .pong, payload);
        defer self.allocator.free(frame);
        try self.stream.writeAll(frame);
    }

    /// Read and parse one WebSocket frame
    /// Returns the opcode and payload (caller must free payload)
    pub fn readFrame(self: *Connection) !struct { opcode: Opcode, payload: []u8 } {
        // Read header bytes (up to 14 bytes max for header)
        var header_buf: [14]u8 = undefined;

        // First read 2 bytes minimum
        const initial = try self.stream.read(header_buf[0..2]);
        if (initial < 2) return error.ConnectionClosed;

        // Parse to determine how much more we need
        const byte1 = header_buf[1];
        const mask = (byte1 & 0x80) != 0;
        const len_indicator = byte1 & 0x7F;

        var header_len: usize = 2;
        if (len_indicator == 126) {
            header_len += 2;
        } else if (len_indicator == 127) {
            header_len += 8;
        }
        if (mask) header_len += 4;

        // Read remaining header bytes
        if (header_len > 2) {
            const remaining = header_len - 2;
            var total_read: usize = 0;
            while (total_read < remaining) {
                const n = try self.stream.read(header_buf[2 + total_read .. 2 + remaining]);
                if (n == 0) return error.ConnectionClosed;
                total_read += n;
            }
        }

        // Parse the complete header
        const parsed = try parseFrameHeader(header_buf[0..header_len]);
        const header = parsed.header;

        // Allocate and read payload
        const payload = try self.allocator.alloc(u8, @intCast(header.payload_len));
        errdefer self.allocator.free(payload);

        var payload_read: usize = 0;
        while (payload_read < payload.len) {
            const n = try self.stream.read(payload[payload_read..]);
            if (n == 0) return error.ConnectionClosed;
            payload_read += n;
        }

        // Unmask if needed
        if (header.masking_key) |key| {
            unmaskPayload(payload, key);
        }

        return .{ .opcode = header.opcode, .payload = payload };
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
    }

    /// Check if the underlying stream has buffered data waiting to be read.
    /// For TLS connections, this checks if the TLS layer has decrypted data
    /// that wasn't consumed yet. Essential for event loops where poll()
    /// might not wake up for data already buffered in userspace.
    pub fn hasPendingData(self: *Connection) bool {
        return self.stream.hasPendingData();
    }
};

test "compute accept key" {
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = computeAcceptKey(client_key);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "create text frame" {
    const allocator = std.testing.allocator;
    const frame = try createFrame(allocator, .text, "Hello");
    defer allocator.free(frame);

    try std.testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 5), frame[1]); // Length
    try std.testing.expectEqualStrings("Hello", frame[2..7]);
}

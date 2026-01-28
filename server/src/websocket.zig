//! WebSocket implementation for dullahan
//!
//! Implements RFC 6455 WebSocket protocol for terminal communication.

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const base64 = std.base64;
const builtin = @import("builtin");
const constants = @import("constants.zig");
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
    read_buf: std.ArrayListUnmanaged(u8) = .{},
    write_buf: std.ArrayListUnmanaged(u8) = .{},

    const max_write_buffer: usize = 8 * 1024 * 1024; // 8MB per client

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

        // Set non-blocking for poll-based event loop.
        const fl_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch 0;
        const O_NONBLOCK: usize = if (builtin.os.tag == .macos) 0x4 else 0x800;
        _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl_flags | O_NONBLOCK) catch {};

        return .{
            .stream = stream,
            .allocator = allocator,
            .read_buf = .{},
            .write_buf = .{},
        };
    }

    pub fn deinit(self: *Connection) void {
        self.read_buf.deinit(self.allocator);
        self.write_buf.deinit(self.allocator);
        self.stream.close();
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
        try self.sendFrame(.text, message);
    }

    /// Send a binary message
    pub fn sendBinary(self: *Connection, data: []const u8) !void {
        try self.sendFrame(.binary, data);
    }

    /// Send a close frame
    pub fn sendClose(self: *Connection) !void {
        try self.sendFrame(.close, &.{});
    }

    /// Send a pong frame (response to ping)
    pub fn sendPong(self: *Connection, payload: []const u8) !void {
        try self.sendFrame(.pong, payload);
    }

    /// Read and parse one WebSocket frame
    /// Returns the opcode and payload (caller must free payload)
    pub fn readFrame(self: *Connection) !struct { opcode: Opcode, payload: []u8 } {
        while (true) {
            if (self.read_buf.items.len < 2) {
                if (try self.readMore()) |_| {} else {
                    return error.WouldBlock;
                }
            }

            const parsed = parseFrameHeader(self.read_buf.items) catch |e| switch (e) {
                error.InsufficientData => {
                    if (try self.readMore()) |_| {} else {
                        return error.WouldBlock;
                    }
                    continue;
                },
                else => return e,
            };

            const header = parsed.header;
            if (header.payload_len > std.math.maxInt(usize)) {
                return error.FrameTooLarge;
            }

            const header_len = parsed.header_len;
            const payload_len: usize = @intCast(header.payload_len);
            const total_len = header_len + payload_len;

            if (self.read_buf.items.len < total_len) {
                if (try self.readMore()) |_| {} else {
                    return error.WouldBlock;
                }
                continue;
            }

            const payload = try self.allocator.alloc(u8, payload_len);
            errdefer self.allocator.free(payload);

            if (payload_len > 0) {
                std.mem.copyForwards(u8, payload, self.read_buf.items[header_len .. header_len + payload_len]);
            }

            if (header.masking_key) |key| {
                unmaskPayload(payload, key);
            }

            const remaining = self.read_buf.items.len - total_len;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.read_buf.items[0..remaining], self.read_buf.items[total_len..]);
            }
            self.read_buf.items.len = remaining;

            return .{ .opcode = header.opcode, .payload = payload };
        }
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
    }

    /// Check if the underlying stream has buffered data waiting to be read.
    /// For TLS connections, this checks if the TLS layer has decrypted data
    /// that wasn't consumed yet. Essential for event loops where poll()
    /// might not wake up for data already buffered in userspace.
    pub fn hasPendingData(self: *Connection) bool {
        return self.read_buf.items.len > 0 or self.stream.hasPendingData();
    }

    /// Check if there's queued outbound data waiting to be written.
    pub fn hasPendingWrite(self: *const Connection) bool {
        return self.write_buf.items.len > 0;
    }

    /// Attempt to flush queued outbound data. Returns true if drained.
    pub fn flushWriteBuffer(self: *Connection) !bool {
        while (self.write_buf.items.len > 0) {
            const n = self.stream.write(self.write_buf.items) catch |e| switch (e) {
                error.WouldBlock => return false,
                else => return e,
            };
            if (n == 0) return error.ConnectionClosed;
            const remaining = self.write_buf.items.len - n;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.write_buf.items[0..remaining], self.write_buf.items[n..]);
            }
            self.write_buf.items.len = remaining;
        }
        return true;
    }

    fn readMore(self: *Connection) !?usize {
        var buf: [constants.buffer.general]u8 = undefined;
        const n = self.stream.read(&buf) catch |e| switch (e) {
            error.WouldBlock => return null,
            else => return e,
        };
        if (n == 0) return error.ConnectionClosed;
        try self.read_buf.appendSlice(self.allocator, buf[0..n]);
        return n;
    }

    fn sendFrame(self: *Connection, opcode: Opcode, payload: []const u8) !void {
        const frame = try createFrame(self.allocator, opcode, payload);
        defer self.allocator.free(frame);

        if (self.write_buf.items.len == 0) {
            const n = self.stream.write(frame) catch |e| switch (e) {
                error.WouldBlock => {
                    try self.write_buf.appendSlice(self.allocator, frame);
                    return;
                },
                else => return e,
            };
            if (n == 0) return error.ConnectionClosed;
            if (n < frame.len) {
                try self.write_buf.appendSlice(self.allocator, frame[n..]);
            }
        } else {
            try self.write_buf.appendSlice(self.allocator, frame);
        }

        if (self.write_buf.items.len > max_write_buffer) {
            return error.WriteBufferFull;
        }
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

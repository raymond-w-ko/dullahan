//! Narrow compatibility layer for Dullahan's poll-based TCP ownership.
//! std.Io.net owns listening; accepted streams retain raw nonblocking access.

const std = @import("std");
const posix_compat = @import("posix_compat.zig");

pub const Address = struct {
    inner: std.Io.net.IpAddress,

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return .{ .inner = .{ .ip4 = .{ .bytes = bytes, .port = port } } };
    }
};

pub const ListenOptions = struct {
    reuse_address: bool = false,
    kernel_backlog: u31 = std.Io.net.default_kernel_backlog,
};

pub const Stream = struct {
    io: std.Io,
    handle: std.posix.fd_t,

    pub fn read(self: Stream, buffer: []u8) !usize {
        return std.posix.read(self.handle, buffer);
    }

    pub fn write(self: Stream, bytes: []const u8) !usize {
        return posix_compat.write(self.handle, bytes);
    }

    pub fn close(self: Stream) void {
        _ = std.posix.system.close(self.handle);
    }
};

pub const Connection = struct {
    stream: Stream,
    address: []const u8 = "unknown",
};

pub const Server = struct {
    io: std.Io,
    inner: std.Io.net.Server,
    stream: struct { handle: std.posix.fd_t },

    pub fn accept(self: *Server) !Connection {
        const accepted = try self.inner.accept(self.io);
        return .{
            .stream = .{
                .io = self.io,
                .handle = accepted.socket.handle,
            },
        };
    }

    pub fn deinit(self: *Server) void {
        self.inner.deinit(self.io);
    }
};

pub fn listen(io: std.Io, address: Address, options: ListenOptions) !Server {
    const inner = try address.inner.listen(io, .{
        .reuse_address = options.reuse_address,
        .kernel_backlog = options.kernel_backlog,
    });
    return .{
        .io = io,
        .stream = .{ .handle = inner.socket.handle },
        .inner = inner,
    };
}

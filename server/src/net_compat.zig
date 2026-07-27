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
    address: std.Io.net.IpAddress,
};

const PosixAddress = extern union {
    any: std.posix.sockaddr,
    in: std.posix.sockaddr.in,
    in6: std.posix.sockaddr.in6,
};

fn addressFromPosix(address: *const PosixAddress) !std.Io.net.IpAddress {
    return switch (address.any.family) {
        std.posix.AF.INET => .{ .ip4 = .{
            .port = std.mem.bigToNative(u16, address.in.port),
            .bytes = @bitCast(address.in.addr),
        } },
        std.posix.AF.INET6 => .{ .ip6 = .{
            .port = std.mem.bigToNative(u16, address.in6.port),
            .bytes = address.in6.addr,
            .flow = address.in6.flowinfo,
            .interface = .{ .index = address.in6.scope_id },
        } },
        else => error.AddressFamilyNotSupported,
    };
}

pub const Server = struct {
    io: std.Io,
    inner: std.Io.net.Server,
    stream: struct { handle: std.posix.fd_t },

    pub fn accept(self: *Server) !Connection {
        var address: PosixAddress = undefined;
        var address_len: std.posix.socklen_t = @sizeOf(PosixAddress);
        const fd = try posix_compat.accept(
            self.stream.handle,
            &address.any,
            &address_len,
            std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        );
        errdefer _ = std.posix.system.close(fd);

        return .{
            .stream = .{
                .io = self.io,
                .handle = fd,
            },
            .address = try addressFromPosix(&address),
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

test "nonblocking accept preserves flags and peer addresses" {
    var server = try listen(std.testing.io, .initIp4(.{ 127, 0, 0, 1 }, 0), .{
        .reuse_address = true,
    });
    defer server.deinit();
    try posix_compat.setNonBlocking(server.stream.handle, true);

    try std.testing.expectError(error.WouldBlock, server.accept());

    const address = server.inner.socket.address;
    var first_client = try address.connect(std.testing.io, .{ .mode = .stream });
    defer first_client.close(std.testing.io);
    var second_client = try address.connect(std.testing.io, .{ .mode = .stream });
    defer second_client.close(std.testing.io);

    var first = try server.accept();
    defer first.stream.close();
    var second = try server.accept();
    defer second.stream.close();

    try std.testing.expect(try posix_compat.isNonBlocking(first.stream.handle));
    try std.testing.expect(try posix_compat.isCloseOnExec(first.stream.handle));
    try std.testing.expect(try posix_compat.isNonBlocking(second.stream.handle));
    try std.testing.expect(try posix_compat.isCloseOnExec(second.stream.handle));

    switch (first.address) {
        .ip4 => |peer| {
            try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &peer.bytes);
            try std.testing.expect(peer.port != 0);
        },
        .ip6 => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.WouldBlock, server.accept());
}

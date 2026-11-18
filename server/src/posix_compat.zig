const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const WriteError = error{
    InvalidArgument,
    ProcessNotFound,
    WouldBlock,
    NotOpenForWriting,
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
    PermissionDenied,
    BrokenPipe,
    ConnectionResetByPeer,
    DeviceBusy,
    NoDevice,
    MessageTooBig,
    Unexpected,
};

pub fn pipe() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = posix.system.pipe(&fds);
    switch (posix.errno(rc)) {
        .SUCCESS => return fds,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .MFILE, .NFILE => return error.ProcessFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub fn fcntl(fd: posix.fd_t, cmd: i32, arg: usize) !usize {
    const rc = posix.system.fcntl(fd, cmd, arg);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR => return fcntl(fd, cmd, arg),
        .AGAIN => return error.WouldBlock,
        .BADF => return error.InvalidFileDescriptor,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.Unexpected,
    }
}

fn statusFlag(comptime field_name: []const u8) usize {
    var flags: posix.O = .{};
    @field(flags, field_name) = true;
    const Bits = @Int(.unsigned, @bitSizeOf(posix.O));
    return @intCast(@as(Bits, @bitCast(flags)));
}

pub fn setNonBlocking(fd: posix.fd_t, enabled: bool) !void {
    const current = try fcntl(fd, posix.F.GETFL, 0);
    const nonblock = statusFlag("NONBLOCK");
    const updated = if (enabled) current | nonblock else current & ~nonblock;
    _ = try fcntl(fd, posix.F.SETFL, updated);
}

pub fn isNonBlocking(fd: posix.fd_t) !bool {
    return (try fcntl(fd, posix.F.GETFL, 0)) & statusFlag("NONBLOCK") != 0;
}

pub fn setCloseOnExec(fd: posix.fd_t, enabled: bool) !void {
    const current = try fcntl(fd, posix.F.GETFD, 0);
    const updated = if (enabled) current | posix.FD_CLOEXEC else current & ~@as(usize, posix.FD_CLOEXEC);
    _ = try fcntl(fd, posix.F.SETFD, updated);
}

pub fn isCloseOnExec(fd: posix.fd_t) !bool {
    return (try fcntl(fd, posix.F.GETFD, 0)) & posix.FD_CLOEXEC != 0;
}

fn openAppendAt(dir_fd: posix.fd_t, path: []const u8, mode: posix.mode_t) !posix.fd_t {
    var flags: posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    };
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;

    const fd = try posix.openat(dir_fd, path, flags, mode);
    errdefer _ = posix.system.close(fd);
    if (!@hasField(posix.O, "CLOEXEC")) try setCloseOnExec(fd, true);
    return fd;
}

pub fn openAppend(path: []const u8, mode: posix.mode_t) !posix.fd_t {
    return openAppendAt(posix.AT.FDCWD, path, mode);
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) !posix.socket_t {
    const rc = posix.system.socket(domain, socket_type, protocol);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => return error.Unexpected,
    }
}

pub fn bind(sock: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    const rc = posix.system.bind(sock, addr, len);
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .BADF, .INVAL, .NOTSOCK, .FAULT => unreachable,
        else => return error.Unexpected,
    }
}

pub fn listen(sock: posix.socket_t, backlog: u31) !void {
    const rc = posix.system.listen(sock, backlog);
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .BADF, .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        else => return error.Unexpected,
    }
}

pub fn accept(
    sock: posix.socket_t,
    addr: ?*posix.sockaddr,
    addr_size: ?*posix.socklen_t,
    flags: u32,
) !posix.socket_t {
    const supported_flags: u32 = posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    if (flags & ~supported_flags != 0) return error.UnsupportedFlags;

    const accept4_unsupported = switch (builtin.target.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .haiku => true,
        else => false,
    };

    while (true) {
        const rc = if (accept4_unsupported)
            posix.system.accept(sock, addr, addr_size)
        else
            posix.system.accept4(sock, addr, addr_size, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.socket_t = @intCast(rc);
                errdefer _ = posix.system.close(fd);
                if (accept4_unsupported) {
                    if (flags & posix.SOCK.CLOEXEC != 0) try setCloseOnExec(fd, true);
                    if (flags & posix.SOCK.NONBLOCK != 0) try setNonBlocking(fd, true);
                }
                return fd;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .INVAL => return error.SocketNotListening,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            .BADF, .FAULT, .NOTSOCK, .OPNOTSUPP => unreachable,
            else => return error.Unexpected,
        }
    }
}

test "append handles never overwrite each other's records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first_fd = try openAppendAt(tmp.dir.handle, "shared.log", 0o600);
    defer _ = posix.system.close(first_fd);
    const second_fd = try openAppendAt(tmp.dir.handle, "shared.log", 0o600);
    defer _ = posix.system.close(second_fd);

    const first: std.Io.File = .{ .handle = first_fd, .flags = .{ .nonblocking = false } };
    const second: std.Io.File = .{ .handle = second_fd, .flags = .{ .nonblocking = false } };
    var first_buffer: [32]u8 = undefined;
    var second_buffer: [32]u8 = undefined;
    var first_writer = first.writerStreaming(std.testing.io, &first_buffer);
    var second_writer = second.writerStreaming(std.testing.io, &second_buffer);
    try first_writer.interface.writeAll("first-1\n");
    try first_writer.interface.flush();
    try second_writer.interface.writeAll("second-1\n");
    try second_writer.interface.flush();
    try first_writer.interface.writeAll("first-2\n");
    try first_writer.interface.flush();
    try second_writer.interface.writeAll("second-2\n");
    try second_writer.interface.flush();

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "shared.log", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(
        "first-1\nsecond-1\nfirst-2\nsecond-2\n",
        contents,
    );
    try std.testing.expect(try isCloseOnExec(first_fd));
    try std.testing.expect(try isCloseOnExec(second_fd));
}

pub fn connect(sock: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    while (true) {
        const rc = posix.system.connect(sock, addr, len);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .HOSTUNREACH, .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound,
            .BADF, .FAULT, .ISCONN, .NOTSOCK, .PROTOTYPE, .CONNABORTED => unreachable,
            else => return error.Unexpected,
        }
    }
}

pub fn setsockopt(
    fd: posix.socket_t,
    level: i32,
    optname: u32,
    opt: []const u8,
) !void {
    const rc = posix.system.setsockopt(fd, level, optname, opt.ptr, @intCast(opt.len));
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        .DOM => return error.TimeoutTooBig,
        .ISCONN => return error.AlreadyConnected,
        .NOPROTOOPT => return error.InvalidProtocolOption,
        .NOMEM, .NOBUFS => return error.SystemResources,
        .PERM => return error.PermissionDenied,
        .NODEV => return error.NoDevice,
        .OPNOTSUPP => return error.OperationNotSupported,
        .BADF, .NOTSOCK, .INVAL, .FAULT => unreachable,
        else => return error.Unexpected,
    }
}

/// Zig 0.16 removed std.posix.write in favor of std.Io. Dullahan still needs
/// nonblocking, partial writes for PTYs and sockets, so keep this narrow shim
/// until those owners migrate to an async std.Io implementation.
pub fn write(fd: posix.fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;

    const max_count = switch (builtin.target.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };

    while (true) {
        const rc = posix.system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DESTADDRREQ => unreachable,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageTooBig,
            else => return error.Unexpected,
        }
    }
}

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
    if (flags != 0) return error.UnsupportedFlags;
    while (true) {
        const rc = posix.system.accept(sock, addr, addr_size);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
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

    const max_count = switch (builtin.os.tag) {
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

//! PTY (Pseudo-Terminal) support for dullahan
//!
//! Provides PTY allocation and child process spawning so that
//! programs like zsh/fish that check isatty() work correctly.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h"); // stat() for directory check
    if (builtin.os.tag == .macos) {
        @cInclude("util.h"); // openpty() on macOS
    } else {
        @cInclude("pty.h"); // openpty() on Linux
    }
    @cInclude("termios.h");
    @cInclude("unistd.h"); // setsid
    @cInclude("stdlib.h"); // setenv
});

pub const Winsize = extern struct {
    ws_row: u16 = 24,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

pub const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,

    pub const Error = error{
        OpenPtyFailed,
        SetAttrFailed,
        ForkFailed,
        ExecFailed,
        SetSidFailed,
        SetCttyFailed,
    };

    /// Open a new PTY pair with the given size
    pub fn open(size: Winsize) Error!Pty {
        var ws = size;
        var master: posix.fd_t = undefined;
        var slave: posix.fd_t = undefined;

        if (c.openpty(&master, &slave, null, null, @ptrCast(&ws)) < 0) {
            return error.OpenPtyFailed;
        }
        errdefer {
            _ = posix.system.close(master);
            _ = posix.system.close(slave);
        }

        // Set CLOEXEC on master so it's not inherited by child
        const fd_flags = posix.fcntl(master, posix.F.GETFD, 0) catch {
            return error.OpenPtyFailed;
        };
        _ = posix.fcntl(master, posix.F.SETFD, fd_flags | posix.FD_CLOEXEC) catch {
            return error.OpenPtyFailed;
        };

        // Set non-blocking on master for poll-based event loop
        const fl_flags = posix.fcntl(master, posix.F.GETFL, 0) catch {
            return error.OpenPtyFailed;
        };
        // O_NONBLOCK = 0x4 on macOS, 0x800 on Linux
        const O_NONBLOCK: usize = if (builtin.os.tag == .macos) 0x4 else 0x800;
        _ = posix.fcntl(master, posix.F.SETFL, fl_flags | O_NONBLOCK) catch {
            return error.OpenPtyFailed;
        };

        // Enable UTF-8 mode
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master, &attrs) != 0) {
            return error.SetAttrFailed;
        }
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master, c.TCSANOW, &attrs) != 0) {
            return error.SetAttrFailed;
        }

        return .{ .master = master, .slave = slave };
    }

    pub fn deinit(self: *Pty) void {
        _ = posix.system.close(self.master);
        self.* = undefined;
    }

    /// Set the PTY size
    pub fn setSize(self: *Pty, size: Winsize) !void {
        const TIOCSWINSZ: u32 = if (builtin.os.tag == .macos) 2148037735 else 0x5414;
        if (c.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&size)) < 0) {
            return error.SetSizeFailed;
        }
    }

    /// Read from the master side of the PTY
    pub fn read(self: *Pty, buf: []u8) !usize {
        return posix.read(self.master, buf);
    }

    /// Write to the master side of the PTY (sends input to child)
    pub fn write(self: *Pty, data: []const u8) !usize {
        return posix.write(self.master, data);
    }

    /// Spawn a child process connected to this PTY
    pub fn spawn(self: *Pty, argv: []const [:0]const u8, env: ?[*:null]const ?[*:0]const u8) Error!posix.pid_t {
        const pid = posix.fork() catch return error.ForkFailed;

        if (pid == 0) {
            // Child process
            self.childSetup() catch posix.exit(1);
            
            // Set terminal environment variables
            setTerminalEnv();

            // Convert argv to null-terminated pointer array
            var argv_buf: [64:null]?[*:0]const u8 = undefined;
            for (argv, 0..) |arg, i| {
                argv_buf[i] = arg.ptr;
            }
            argv_buf[argv.len] = null;

            const argv_ptr: [*:null]const ?[*:0]const u8 = &argv_buf;
            const env_ptr = env orelse @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));

            _ = posix.execvpeZ(argv_buf[0].?, argv_ptr, env_ptr) catch {};
            posix.exit(1);
        }

        // Parent: close slave fd, we only need master
        _ = posix.system.close(self.slave);
        self.slave = -1;

        return pid;
    }

    /// Setup child process to use the PTY slave
    fn childSetup(self: *Pty) Error!void {
        // Create new session
        if (c.setsid() < 0) {
            return error.SetSidFailed;
        }

        // Set controlling terminal
        const TIOCSCTTY: u32 = if (builtin.os.tag == .macos) 536900705 else 0x540E;
        if (c.ioctl(self.slave, TIOCSCTTY, @as(c_ulong, 0)) < 0) {
            return error.SetCttyFailed;
        }

        // Duplicate slave to stdin/stdout/stderr
        _ = posix.system.dup2(self.slave, 0);
        _ = posix.system.dup2(self.slave, 1);
        _ = posix.system.dup2(self.slave, 2);

        // Close original fds
        if (self.slave > 2) {
            _ = posix.system.close(self.slave);
        }
        _ = posix.system.close(self.master);
    }
};

/// Set terminal-related environment variables for Ghostty compatibility
fn setTerminalEnv() void {
    // Set TERM_PROGRAM to identify as Ghostty
    _ = c.setenv("TERM_PROGRAM", "ghostty", 1);
    
    // Set TERM to xterm-ghostty for terminfo lookup
    _ = c.setenv("TERM", "xterm-ghostty", 1);
    
    // Set TERMINFO only if Ghostty.app terminfo directory exists
    const terminfo_path = "/Applications/Ghostty.app/Contents/Resources/terminfo";
    var stat_buf: c.struct_stat = undefined;
    if (c.stat(terminfo_path, &stat_buf) == 0) {
        // Check if it's a directory (S_IFDIR = 0o40000)
        if (stat_buf.st_mode & c.S_IFMT == c.S_IFDIR) {
            _ = c.setenv("TERMINFO", terminfo_path, 1);
        }
    }
}

test "pty can be opened" {
    var pty = try Pty.open(.{});
    defer pty.deinit();

    try std.testing.expect(pty.master >= 0);
}

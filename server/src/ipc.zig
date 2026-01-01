//! IPC module for dullahan server/client communication
//!
//! Uses Unix domain sockets for bidirectional communication.
//! Protocol is simple line-based text commands and JSON responses.

const std = @import("std");
const posix = std.posix;

pub const Config = struct {
    /// Socket path (default: /tmp/dullahan.sock)
    socket_path: []const u8 = "/tmp/dullahan.sock",
    /// PID file path
    pid_path: []const u8 = "/tmp/dullahan.pid",
    /// Command timeout in milliseconds
    timeout_ms: u32 = 5000,
};

pub const Command = enum {
    status,
    quit,
    ping,
    help,
    demo,
    @"pty-demo",
    dump,
    @"dump-raw",
    @"debug-capture",

    pub fn fromString(s: []const u8) ?Command {
        const map = std.StaticStringMap(Command).initComptime(.{
            .{ "status", .status },
            .{ "quit", .quit },
            .{ "ping", .ping },
            .{ "help", .help },
            .{ "demo", .demo },
            .{ "pty-demo", .@"pty-demo" },
            .{ "dump", .dump },
            .{ "dump-raw", .@"dump-raw" },
            .{ "debug-capture", .@"debug-capture" },
        });
        return map.get(s);
    }

    pub fn description(self: Command) []const u8 {
        return switch (self) {
            .status => "Show server status and runtime info",
            .quit => "Gracefully shutdown the server",
            .ping => "Check if server is responsive",
            .help => "Show available commands",
            .demo => "Run ls -al --color and show terminal output (pipe)",
            .@"pty-demo" => "Run ls -al --color via PTY (isatty=true)",
            .dump => "Dump terminal state (compact, human-readable)",
            .@"dump-raw" => "Dump raw terminal cells with escape codes visible",
            .@"debug-capture" => "Run 'claude', capture PTY output as hex to /tmp/dullahan-capture.hex",
        };
    }
};

pub const Response = struct {
    success: bool,
    message: []const u8,
    data: ?[]const u8 = null,

    pub fn ok(message: []const u8) Response {
        return .{ .success = true, .message = message };
    }

    pub fn okWithData(message: []const u8, data: []const u8) Response {
        return .{ .success = true, .message = message, .data = data };
    }

    pub fn err(message: []const u8) Response {
        return .{ .success = false, .message = message };
    }

    pub fn format(self: Response, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .{};
        const writer = list.writer(allocator);

        if (self.success) {
            try writer.writeAll("OK: ");
        } else {
            try writer.writeAll("ERR: ");
        }
        try writer.writeAll(self.message);
        if (self.data) |d| {
            try writer.writeAll("\n");
            try writer.writeAll(d);
        }
        try writer.writeAll("\n");

        return list.toOwnedSlice(allocator);
    }
};

/// Check if a server is already running by reading PID file
fn isServerRunning(pid_path: []const u8) bool {
    const file = std.fs.cwd().openFile(pid_path, .{}) catch return false;
    defer file.close();

    var buf: [20]u8 = undefined;
    const n = file.readAll(&buf) catch return false;
    const pid_str = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    const pid = std.fmt.parseInt(posix.pid_t, pid_str, 10) catch return false;

    // Check if process exists (kill with signal 0)
    posix.kill(pid, 0) catch |e| switch (e) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true, // Process exists but we can't signal it
        else => return false,
    };
    return true;
}

/// Server-side socket listener
pub const Server = struct {
    socket: posix.socket_t,
    config: Config,

    pub fn init(config: Config) !Server {
        // Check if another server is already running via PID file
        if (isServerRunning(config.pid_path)) {
            return error.AddressInUse;
        }
        
        // Remove existing socket file if present (stale from crashed server)
        std.fs.cwd().deleteFile(config.socket_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };

        const socket = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(socket);

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes: []const u8 = config.socket_path;
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        try posix.bind(socket, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(socket, 5);

        return .{ .socket = socket, .config = config };
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.socket);
        std.fs.cwd().deleteFile(self.config.socket_path) catch {};
        std.fs.cwd().deleteFile(self.config.pid_path) catch {};
    }

    pub fn writePidFile(self: *Server) !void {
        const file = try std.fs.cwd().createFile(self.config.pid_path, .{});
        defer file.close();
        const pid = std.c.getpid();
        var buf: [20]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch unreachable;
        try file.writeAll(slice);
    }

    /// Accept a connection and read command (blocking)
    pub fn acceptCommand(self: *Server, allocator: std.mem.Allocator) !struct { conn: posix.socket_t, command: Command } {
        const conn = try posix.accept(self.socket, null, null, 0);
        errdefer posix.close(conn);

        var buf: [256]u8 = undefined;
        const n = try posix.read(conn, &buf);
        if (n == 0) return error.ConnectionClosed;

        // Trim whitespace
        const cmd_str = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);

        const command = Command.fromString(cmd_str) orelse {
            // Send error response for unknown command
            const resp = Response.err("Unknown command. Use 'help' for available commands.");
            const formatted = try resp.format(allocator);
            defer allocator.free(formatted);
            _ = posix.write(conn, formatted) catch {};
            posix.close(conn);
            return error.UnknownCommand;
        };

        return .{ .conn = conn, .command = command };
    }

    /// Send response to client
    pub fn sendResponse(self: *Server, conn: posix.socket_t, response: Response, allocator: std.mem.Allocator) !void {
        _ = self;
        const formatted = try response.format(allocator);
        defer allocator.free(formatted);
        _ = try posix.write(conn, formatted);
        posix.close(conn);
    }
};

/// Client-side socket connection
pub const Client = struct {
    config: Config,

    pub fn init(config: Config) Client {
        return .{ .config = config };
    }

    /// Check if server is running by reading PID file
    pub fn isServerRunning(self: *Client) bool {
        const file = std.fs.cwd().openFile(self.config.pid_path, .{}) catch return false;
        defer file.close();

        var buf: [20]u8 = undefined;
        const n = file.readAll(&buf) catch return false;
        const pid_str = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
        const pid = std.fmt.parseInt(posix.pid_t, pid_str, 10) catch return false;

        // Check if process exists (kill with signal 0)
        posix.kill(pid, 0) catch |e| switch (e) {
            error.ProcessNotFound => return false,
            error.PermissionDenied => return true, // Process exists but we can't signal it
            else => return false,
        };
        return true;
    }

    /// Send command and receive response
    pub fn sendCommand(self: *Client, command: Command, allocator: std.mem.Allocator) ![]u8 {
        const socket = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer posix.close(socket);

        // Set receive timeout
        const timeout = posix.timeval{
            .sec = @intCast(self.config.timeout_ms / 1000),
            .usec = @intCast((self.config.timeout_ms % 1000) * 1000),
        };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes: []const u8 = self.config.socket_path;
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        posix.connect(socket, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            return error.ServerNotRunning;
        };

        // Send command
        const cmd_name = @tagName(command);
        _ = try posix.write(socket, cmd_name);

        // Read response
        var response: std.ArrayListUnmanaged(u8) = .{};
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = posix.read(socket, &buf) catch |e| switch (e) {
                error.WouldBlock => return error.Timeout,
                else => return e,
            };
            if (n == 0) break;
            try response.appendSlice(allocator, buf[0..n]);
        }

        return response.toOwnedSlice(allocator);
    }
};

// Tests
test "Command.fromString" {
    try std.testing.expectEqual(Command.status, Command.fromString("status").?);
    try std.testing.expectEqual(Command.quit, Command.fromString("quit").?);
    try std.testing.expect(Command.fromString("invalid") == null);
}

test "Response.format" {
    const resp = Response.ok("Server is running");
    const formatted = try resp.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("OK: Server is running\n", formatted);
}

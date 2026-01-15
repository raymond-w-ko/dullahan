//! IPC module for dullahan server/client communication
//!
//! Uses Unix domain sockets for bidirectional communication.
//! Protocol is simple line-based text commands and JSON responses.

const std = @import("std");
const posix = std.posix;
const constants = @import("constants.zig");
const paths = @import("paths.zig");

pub const Config = struct {
    /// Socket path (null = use default from paths module)
    socket_path: ?[]const u8 = null,
    /// PID file path (null = use default from paths module)
    pid_path: ?[]const u8 = null,
    /// Command timeout in milliseconds
    timeout_ms: u32 = constants.timeout.cli_default_ms,

    /// Resolve socket path - returns provided value or default
    pub fn getSocketPath(self: Config) []const u8 {
        return self.socket_path orelse paths.StaticPaths.socket();
    }

    /// Resolve pid path - returns provided value or default
    pub fn getPidPath(self: Config) []const u8 {
        return self.pid_path orelse paths.StaticPaths.pid();
    }
};

pub const Command = enum {
    status,
    quit,
    ping,
    help,
    shell,
    dump,
    @"dump-raw",
    @"debug-capture",
    @"pty-log",
    @"pty-log-on",
    @"pty-log-off",
    ttysize,
    layouts,
    panes,
    windows,
    send,

    pub fn fromString(s: []const u8) ?Command {
        const map = std.StaticStringMap(Command).initComptime(.{
            .{ "status", .status },
            .{ "quit", .quit },
            .{ "ping", .ping },
            .{ "help", .help },
            .{ "shell", .shell },
            .{ "dump", .dump },
            .{ "dump-raw", .@"dump-raw" },
            .{ "debug-capture", .@"debug-capture" },
            .{ "pty-log", .@"pty-log" },
            .{ "pty-log-on", .@"pty-log-on" },
            .{ "pty-log-off", .@"pty-log-off" },
            .{ "ttysize", .ttysize },
            .{ "layouts", .layouts },
            .{ "panes", .panes },
            .{ "windows", .windows },
            .{ "send", .send },
        });
        return map.get(s);
    }

    pub fn description(self: Command) []const u8 {
        return switch (self) {
            .status => "Show server status and runtime info",
            .quit => "Gracefully shutdown the server",
            .ping => "Check if server is responsive",
            .help => "Show available commands",
            .shell => "Show detected shell and detection steps",
            .dump => "Dump terminal state (compact, human-readable)",
            .@"dump-raw" => "Dump raw terminal cells with escape codes visible",
            .@"debug-capture" => "Run 'claude', capture PTY output as hex to temp dir",
            .@"pty-log" => "Show PTY traffic logging status and file path",
            .@"pty-log-on" => "Enable PTY traffic logging to file",
            .@"pty-log-off" => "Disable PTY traffic logging",
            .ttysize => "Query server's console terminal size via ioctl TIOCGWINSZ",
            .layouts => "List available layout templates (JSON)",
            .panes => "List all pane IDs",
            .windows => "List windows with their pane IDs (JSON)",
            .send => "Send text to pane: send <pane_id> [text] (reads stdin if no text)",
        };
    }
};

/// Parsed command with optional data payload
pub const ParsedCommand = struct {
    command: Command,
    data: ?[]const u8 = null,

    /// Parse a command string, extracting command and optional data.
    /// Format: "command" or "command data..."
    pub fn parse(input: []const u8) ?ParsedCommand {
        const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;

        // Split on first space
        if (std.mem.indexOf(u8, trimmed, " ")) |space_idx| {
            const cmd_str = trimmed[0..space_idx];
            const data = std.mem.trim(u8, trimmed[space_idx + 1 ..], &std.ascii.whitespace);
            const command = Command.fromString(cmd_str) orelse return null;
            return .{
                .command = command,
                .data = if (data.len > 0) data else null,
            };
        }

        // No space - just command
        const command = Command.fromString(trimmed) orelse return null;
        return .{ .command = command };
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
        const socket_path = config.getSocketPath();
        const pid_path = config.getPidPath();

        // Ensure temp directory exists
        paths.ensureTempDir() catch |e| {
            return e;
        };

        // Check if another server is already running via PID file
        if (isServerRunning(pid_path)) {
            return error.AddressInUse;
        }

        // Remove existing socket file if present (stale from crashed server)
        std.fs.cwd().deleteFile(socket_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };

        const socket = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(socket);

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        try posix.bind(socket, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(socket, 5);

        return .{ .socket = socket, .config = config };
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.socket);
        std.fs.cwd().deleteFile(self.config.getSocketPath()) catch {};
        std.fs.cwd().deleteFile(self.config.getPidPath()) catch {};
    }

    pub fn writePidFile(self: *Server) !void {
        const file = try std.fs.cwd().createFile(self.config.getPidPath(), .{});
        defer file.close();
        const pid = std.c.getpid();
        var buf: [20]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch unreachable;
        try file.writeAll(slice);
    }

    /// Accept a connection and read command (blocking)
    pub fn acceptCommand(self: *Server, allocator: std.mem.Allocator) !struct { conn: posix.socket_t, parsed: ParsedCommand } {
        const conn = try posix.accept(self.socket, null, null, 0);
        errdefer posix.close(conn);

        var buf: [constants.buffer.general]u8 = undefined;
        const n = try posix.read(conn, &buf);
        if (n == 0) return error.ConnectionClosed;

        const parsed = ParsedCommand.parse(buf[0..n]) orelse {
            // Send error response for unknown command
            const resp = Response.err("Unknown command. Use 'help' for available commands.");
            const formatted = try resp.format(allocator);
            defer allocator.free(formatted);
            _ = posix.write(conn, formatted) catch {};
            posix.close(conn);
            return error.UnknownCommand;
        };

        return .{ .conn = conn, .parsed = parsed };
    }

    /// Accept a connection with timeout (non-blocking with poll)
    /// Returns null if timeout expires, otherwise returns the parsed command
    /// timeout_ms: timeout in milliseconds (-1 for infinite)
    pub fn acceptCommandTimeout(self: *Server, allocator: std.mem.Allocator, timeout_ms: i32) !?struct { conn: posix.socket_t, parsed: ParsedCommand } {
        // Poll the socket with timeout
        var poll_fds = [_]posix.pollfd{
            .{ .fd = self.socket, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&poll_fds, timeout_ms) catch |e| {
            return e;
        };

        // Timeout - no connection
        if (ready == 0) {
            return null;
        }

        // Check for errors
        if (poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            return error.SocketError;
        }

        // Connection available - accept it
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const conn = try posix.accept(self.socket, null, null, 0);
            errdefer posix.close(conn);

            var buf: [constants.buffer.general]u8 = undefined;
            const n = try posix.read(conn, &buf);
            if (n == 0) return error.ConnectionClosed;

            const parsed = ParsedCommand.parse(buf[0..n]) orelse {
                // Send error response for unknown command
                const resp = Response.err("Unknown command. Use 'help' for available commands.");
                const formatted = try resp.format(allocator);
                defer allocator.free(formatted);
                _ = posix.write(conn, formatted) catch {};
                posix.close(conn);
                return error.UnknownCommand;
            };

            return .{ .conn = conn, .parsed = parsed };
        }

        return null;
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
        const file = std.fs.cwd().openFile(self.config.getPidPath(), .{}) catch return false;
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
        return self.sendCommandWithData(command, null, allocator);
    }

    /// Send command with optional data payload and receive response
    pub fn sendCommandWithData(self: *Client, command: Command, data: ?[]const u8, allocator: std.mem.Allocator) ![]u8 {
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
        const socket_path = self.config.getSocketPath();
        @memcpy(addr.path[0..socket_path.len], socket_path);

        posix.connect(socket, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            return error.ServerNotRunning;
        };

        // Send command (with optional data)
        const cmd_name = @tagName(command);
        _ = try posix.write(socket, cmd_name);
        if (data) |d| {
            _ = try posix.write(socket, " ");
            _ = try posix.write(socket, d);
        }

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

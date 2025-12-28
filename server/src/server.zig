//! Dullahan server
//!
//! Main server loop that handles IPC commands and manages terminal state.

const std = @import("std");
const ipc = @import("ipc.zig");
const Session = @import("session.zig").Session;

pub const ServerState = struct {
    allocator: std.mem.Allocator,
    start_time: i64,
    commands_processed: u64 = 0,
    running: bool = true,

    /// The terminal session (windows/panes)
    session: Session,

    pub fn init(allocator: std.mem.Allocator) !ServerState {
        return .{
            .allocator = allocator,
            .start_time = std.time.timestamp(),
            .session = try Session.init(allocator, .{}),
        };
    }

    pub fn deinit(self: *ServerState) void {
        self.session.deinit();
    }

    pub fn uptime(self: *const ServerState) i64 {
        return std.time.timestamp() - self.start_time;
    }

    pub fn formatStatus(self: *const ServerState, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        const writer = buf.writer(allocator);

        const up = self.uptime();
        const hours = @divFloor(up, 3600);
        const mins = @divFloor(@mod(up, 3600), 60);
        const secs = @mod(up, 60);

        try writer.print("Uptime: {}h {}m {}s\n", .{ hours, mins, secs });
        try writer.print("Commands processed: {}\n", .{self.commands_processed});
        try writer.print("Running: {}\n", .{self.running});

        return buf.toOwnedSlice(allocator);
    }
};

pub fn run(allocator: std.mem.Allocator, config: ipc.Config) !void {
    var state = try ServerState.init(allocator);
    defer state.deinit();

    var server = try ipc.Server.init(config);
    defer server.deinit();

    // Write PID file
    try server.writePidFile();

    std.debug.print("dullahan server started (socket: {s})\n", .{config.socket_path});

    // Main loop
    while (state.running) {
        const result = server.acceptCommand(allocator) catch |e| switch (e) {
            error.UnknownCommand => continue,
            else => {
                std.debug.print("Accept error: {}\n", .{e});
                continue;
            },
        };

        state.commands_processed += 1;

        const response = handleCommand(result.command, &state, allocator) catch |e| blk: {
            std.debug.print("Command error: {}\n", .{e});
            break :blk ipc.Response.err("Internal error");
        };

        server.sendResponse(result.conn, response, allocator) catch |e| {
            std.debug.print("Send error: {}\n", .{e});
        };
    }

    std.debug.print("dullahan server shutting down\n", .{});
}

fn handleCommand(command: ipc.Command, state: *ServerState, allocator: std.mem.Allocator) !ipc.Response {
    return switch (command) {
        .ping => ipc.Response.ok("pong"),

        .status => blk: {
            const data = try state.formatStatus(allocator);
            // Note: This leaks, but server is long-running so it's fine for now
            // TODO: Use arena allocator per-request
            break :blk ipc.Response.okWithData("Server status", data);
        },

        .quit => blk: {
            state.running = false;
            break :blk ipc.Response.ok("Shutting down");
        },

        .help => blk: {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            const writer = buf.writer(allocator);
            try writer.writeAll("Available commands:\n");
            inline for (std.meta.fields(ipc.Command)) |field| {
                const cmd: ipc.Command = @enumFromInt(field.value);
                try writer.print("  {s:<10} - {s}\n", .{ field.name, cmd.description() });
            }
            const data = try buf.toOwnedSlice(allocator);
            break :blk ipc.Response.okWithData("Help", data);
        },

        .demo => blk: {
            // Run ls -al --color=always in the active pane
            try state.session.runCommand(&.{ "ls", "-al", "--color=always" });

            // Get the terminal output
            const pane = state.session.activePane() orelse
                break :blk ipc.Response.err("No active pane");

            const output = try pane.plainString();
            break :blk ipc.Response.okWithData("Terminal output (plain text)", output);
        },

        .dump => blk: {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            const writer = buf.writer(allocator);

            // Server info
            const up = state.uptime();
            try writer.print("Server: up={d}s cmds={d}\n", .{ up, state.commands_processed });

            // Session dump
            try state.session.dump(writer);

            const data = try buf.toOwnedSlice(allocator);
            break :blk ipc.Response.okWithData("State dump", data);
        },
    };
}

test "ServerState uptime" {
    var state = try ServerState.init(std.testing.allocator);
    defer state.deinit();
    // Just verify it doesn't crash
    try std.testing.expect(state.uptime() >= 0);
}

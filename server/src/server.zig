//! Dullahan server
//!
//! Main server loop that handles IPC commands and manages terminal state.

const std = @import("std");
const ipc = @import("ipc.zig");
const Session = @import("session.zig").Session;
const WsServer = @import("ws_server.zig").WsServer;
const PtyReader = @import("pty_reader.zig").PtyReader;
const http = @import("http.zig");
const signal = @import("signal.zig");

const log = std.log.scoped(.server);

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

        try writer.print("Uptime: {d}h {d}m {d}s\n", .{ hours, mins, secs });
        try writer.print("Commands processed: {d}\n", .{self.commands_processed});
        try writer.print("Running: {any}\n", .{self.running});

        return buf.toOwnedSlice(allocator);
    }
};

pub const RunConfig = struct {
    ipc: ipc.Config = .{},
    static_dir: ?[]const u8 = null,
    ws_port: u16 = http.DEFAULT_PORT,

    /// Get static_dir with fallback to ./client if it exists
    pub fn getStaticDir(self: RunConfig) ?[]const u8 {
        if (self.static_dir) |dir| return dir;

        // Check if ./client exists
        std.fs.cwd().access("client", .{}) catch return null;
        return "client";
    }
};

pub fn run(allocator: std.mem.Allocator, config: RunConfig) !void {
    // Install signal handlers first
    signal.install();
    defer signal.reset();

    var state = try ServerState.init(allocator);
    defer state.deinit();

    var ipc_server = ipc.Server.init(config.ipc) catch |e| {
        if (e == error.AddressInUse) {
            log.err("IPC socket {s} is already in use. Another server may be running.", .{config.ipc.socket_path});
            std.debug.print("Error: IPC socket already in use. Is another dullahan running?\n", .{});
        } else {
            log.err("Failed to start IPC server: {any}", .{e});
            std.debug.print("Error: Failed to start IPC server: {any}\n", .{e});
        }
        return e;
    };
    defer ipc_server.deinit();

    // Write PID file
    try ipc_server.writePidFile();

    // Start WebSocket server on separate thread
    const static_dir = config.getStaticDir();
    var ws_server = WsServer.init(allocator, config.ws_port, static_dir) catch |e| {
        if (e == error.AddressInUse) {
            log.err("Port {d} is already in use. Another server may be running.", .{config.ws_port});
            std.debug.print("Error: Port {d} is already in use. Is another dullahan or ttyd running?\n", .{config.ws_port});
        } else {
            log.err("Failed to start WebSocket server: {any}", .{e});
            std.debug.print("Error: Failed to start WebSocket server: {any}\n", .{e});
        }
        return e;
    };
    defer ws_server.deinit();

    const ws_thread = std.Thread.spawn(.{}, runWsServer, .{ &ws_server, &state.session }) catch |e| {
        log.err("Failed to start WebSocket server thread: {any}", .{e});
        return e;
    };

    // Start PTY reader thread
    var pty_reader = PtyReader.init(allocator, &state.session);
    const pty_thread = std.Thread.spawn(.{}, runPtyReader, .{&pty_reader}) catch |e| {
        log.err("Failed to start PTY reader thread: {any}", .{e});
        return e;
    };

    // Spawn shell in the initial pane
    if (state.session.activePane()) |pane| {
        pane.spawnShell() catch |e| {
            log.err("Failed to spawn shell: {any}", .{e});
        };
    }

    log.info("dullahan server started (socket: {s}, ws: port {d})", .{ config.ipc.socket_path, config.ws_port });
    std.debug.print("dullahan server started (socket: {s}, ws: port {d})\n", .{ config.ipc.socket_path, config.ws_port });
    if (static_dir) |dir| {
        std.debug.print("Serving static files from: {s}\n", .{dir});
    }
    std.debug.print("Press Ctrl+C to shutdown\n", .{});

    // Main IPC loop - uses poll with 100ms timeout to check for signals
    while (state.running and !signal.isShutdownRequested()) {
        // Use timeout-based accept so we can check shutdown flag periodically
        const result = ipc_server.acceptCommandTimeout(allocator, 100) catch |e| switch (e) {
            error.UnknownCommand => continue,
            error.SocketError => {
                // Socket was likely closed by signal handler
                if (signal.isShutdownRequested()) break;
                log.err("Socket error", .{});
                continue;
            },
            else => {
                log.err("Accept error: {any}", .{e});
                continue;
            },
        };

        // Check if we got a command or just a timeout
        if (result) |cmd_result| {
            state.commands_processed += 1;

            const response = handleCommand(cmd_result.command, &state, allocator) catch |e| blk: {
                log.err("Command error: {any}", .{e});
                break :blk ipc.Response.err("Internal error");
            };

            ipc_server.sendResponse(cmd_result.conn, response, allocator) catch |e| {
                log.err("Send error: {any}", .{e});
            };
        }
        // If result is null, it was just a timeout - loop continues
    }

    // Log why we're shutting down
    if (signal.isShutdownRequested()) {
        log.info("Received shutdown signal", .{});
        std.debug.print("\nReceived shutdown signal, cleaning up...\n", .{});
    }

    // Signal servers to stop
    ws_server.running.store(false, .release);
    pty_reader.stop();
    
    ws_thread.join();
    pty_thread.join();

    log.info("dullahan server shutting down", .{});
    std.debug.print("dullahan server shutting down\n", .{});
}

fn runWsServer(ws_server: *WsServer, session: *Session) void {
    ws_server.run(session) catch |e| {
        log.err("WebSocket server error: {any}", .{e});
    };
}

fn runPtyReader(pty_reader: *PtyReader) void {
    pty_reader.run();
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
            // Run ls -al --color=always in the active pane (via pipe)
            try state.session.runCommand(&.{ "ls", "-al", "--color=always" });

            // Get the terminal output
            const pane = state.session.activePane() orelse
                break :blk ipc.Response.err("No active pane");

            const output = try pane.plainString();
            break :blk ipc.Response.okWithData("Terminal output (pipe)", output);
        },

        .@"pty-demo" => blk: {
            // Run ls -al --color=always in the active pane (via PTY)
            try state.session.runCommandPty(&.{ "ls", "-al", "--color=always" });

            // Get the terminal output
            const pane = state.session.activePane() orelse
                break :blk ipc.Response.err("No active pane");

            const output = try pane.plainString();
            break :blk ipc.Response.okWithData("Terminal output (PTY)", output);
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

        .@"dump-raw" => blk: {
            const pane = state.session.activePane() orelse
                break :blk ipc.Response.err("No active pane");

            var buf: std.ArrayListUnmanaged(u8) = .{};
            const writer = buf.writer(allocator);

            try pane.dumpRaw(writer);

            const data = try buf.toOwnedSlice(allocator);
            break :blk ipc.Response.okWithData("Raw cell dump", data);
        },

        .@"debug-capture" => blk: {
            const pane = state.session.activePane() orelse
                break :blk ipc.Response.err("No active pane");

            const capture_path = "/tmp/dullahan-capture.hex";
            
            // Start capture
            pane.startCapture(capture_path) catch |e| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Failed to start capture: {any}", .{e}) catch "Failed to start capture";
                break :blk ipc.Response.err(msg);
            };
            
            // Send "claude\n" and immediately return
            // User should run dump-raw after a few seconds to see results
            pane.writeInput("claude\n") catch {};
            
            // Quick sleep to let some output arrive
            std.Thread.sleep(500 * std.time.ns_per_ms);
            
            // Stop capture (will continue in next call if needed)
            pane.stopCapture();
            
            break :blk ipc.Response.okWithData("Capture started", "Sent 'claude\\n'. Run 'dump-raw' to see terminal state, check /tmp/dullahan-capture.hex for hex dump.");
        },
    };
}

test "ServerState uptime" {
    var state = try ServerState.init(std.testing.allocator);
    defer state.deinit();
    // Just verify it doesn't crash
    try std.testing.expect(state.uptime() >= 0);
}

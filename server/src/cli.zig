//! CLI client for dullahan server
//!
//! Sends commands to running server, spawning it if necessary.

const std = @import("std");
const ipc = @import("ipc.zig");
const test_runners = @import("test_runners.zig");

pub const CliArgs = struct {
    command: ?ipc.Command = null,
    timeout_ms: u32 = 5000,
    socket_path: []const u8 = "/tmp/dullahan.sock",
    pid_path: []const u8 = "/tmp/dullahan.pid",
    static_dir: ?[]const u8 = null,
    ws_port: u16 = 7681,
    help: bool = false,
    serve: bool = false,
    no_spawn: bool = false,
    test_command: ?test_runners.TestCommand = null,

    pub fn parse(allocator: std.mem.Allocator) !CliArgs {
        _ = allocator;
        var args = CliArgs{};

        var arg_iter = std.process.args();
        _ = arg_iter.skip(); // Skip program name

        while (arg_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                args.help = true;
            } else if (std.mem.eql(u8, arg, "--no-spawn")) {
                args.no_spawn = true;
            } else if (std.mem.eql(u8, arg, "serve")) {
                args.serve = true;
            } else if (std.mem.eql(u8, arg, "test")) {
                // Next arg should be test subcommand
                if (arg_iter.next()) |test_arg| {
                    if (test_runners.TestCommand.fromString(test_arg)) |cmd| {
                        args.test_command = cmd;
                    } else {
                        // Unknown test command, show help
                        args.test_command = .help;
                    }
                } else {
                    // No subcommand given, show help
                    args.test_command = .help;
                }
            } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
                const val = arg["--timeout=".len..];
                args.timeout_ms = std.fmt.parseInt(u32, val, 10) catch 5000;
            } else if (std.mem.startsWith(u8, arg, "--socket=")) {
                args.socket_path = arg["--socket=".len..];
            } else if (std.mem.startsWith(u8, arg, "--static-dir=")) {
                args.static_dir = arg["--static-dir=".len..];
            } else if (std.mem.startsWith(u8, arg, "--port=")) {
                const val = arg["--port=".len..];
                args.ws_port = std.fmt.parseInt(u16, val, 10) catch 7681;
            } else if (ipc.Command.fromString(arg)) |cmd| {
                args.command = cmd;
            }
        }

        return args;
    }
};

pub fn printUsage() void {
    const usage =
        \\Usage: dullahan [OPTIONS] <COMMAND>
        \\
        \\Commands:
        \\  serve         Run as server (foreground)
        \\  status        Show server status
        \\  ping          Check if server is responsive
        \\  quit          Shutdown the server
        \\  help          Show available commands
        \\  test          Run test utilities (see 'dullahan test help')
        \\
        \\Options:
        \\  -h, --help           Show this help
        \\  --timeout=MS         Command timeout in milliseconds (default: 5000)
        \\  --socket=PATH        Socket path (default: /tmp/dullahan.sock)
        \\  --static-dir=PATH    Serve static files from directory
        \\  --port=PORT          WebSocket/HTTP port (default: 7681)
        \\  --no-spawn           Don't auto-spawn server if not running
        \\
        \\Examples:
        \\  dullahan serve                          # Start server
        \\  dullahan serve --static-dir=./client    # Serve client files
        \\  dullahan status                         # Get server status
        \\  dullahan --timeout=1000 ping            # Ping with 1s timeout
        \\  dullahan test keytest-kitty             # Run keyboard tester
        \\
    ;
    std.debug.print("{s}", .{usage});
}

pub fn runClient(allocator: std.mem.Allocator, args: CliArgs) !void {
    const command = args.command orelse {
        std.debug.print("Error: No command specified. Use --help for usage.\n", .{});
        return error.NoCommand;
    };

    const config = ipc.Config{
        .socket_path = args.socket_path,
        .pid_path = args.pid_path,
        .timeout_ms = args.timeout_ms,
    };

    var client = ipc.Client.init(config);

    // Check if server is running
    if (!client.isServerRunning()) {
        if (args.no_spawn) {
            std.debug.print("Error: Server not running (use 'dullahan serve' to start)\n", .{});
            return error.ServerNotRunning;
        }

        std.debug.print("Server not running. Starting...\n", .{});
        try spawnServer(allocator, args);

        // Wait a bit for server to start
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Retry connection a few times
        var retries: u8 = 10;
        while (retries > 0) : (retries -= 1) {
            if (client.isServerRunning()) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        if (!client.isServerRunning()) {
            std.debug.print("Error: Failed to start server\n", .{});
            return error.ServerStartFailed;
        }
    }

    // Send command
    const response = client.sendCommand(command, allocator) catch |e| {
        switch (e) {
            error.Timeout => std.debug.print("Error: Command timed out\n", .{}),
            error.ServerNotRunning => std.debug.print("Error: Cannot connect to server\n", .{}),
            else => std.debug.print("Error: {}\n", .{e}),
        }
        return e;
    };
    defer allocator.free(response);

    std.debug.print("{s}", .{response});
}

fn spawnServer(allocator: std.mem.Allocator, args: CliArgs) !void {
    // Get path to self
    var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_path_buf);

    var child = std.process.Child.init(
        &.{ self_path, "serve", args.socket_path, args.pid_path },
        allocator,
    );

    // Detach from parent
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Don't wait - let it run in background
    // The child process will daemonize itself
}

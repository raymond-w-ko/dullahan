//! CLI client for dullahan server
//!
//! Sends commands to running server, spawning it if necessary.

const std = @import("std");
const constants = @import("constants.zig");
const ipc = @import("ipc.zig");
const paths = @import("paths.zig");
const test_runners = @import("test_runners.zig");

pub const CliArgs = struct {
    command: ?ipc.Command = null,
    send_data: ?[]const u8 = null, // Data payload for send command (pane_id + text)
    timeout_ms: u32 = constants.timeout.cli_default_ms,
    socket_path: ?[]const u8 = null, // null means use default from paths module
    pid_path: ?[]const u8 = null, // null means use default from paths module
    static_dir: ?[]const u8 = null,
    ws_port: u16 = 7681,
    pty_log: bool = false,
    no_delta: bool = false,
    help: bool = false,
    serve: bool = false,
    no_spawn: bool = false,
    test_command: ?test_runners.TestCommand = null,
    tls_cert: ?[]const u8 = null, // TLS certificate path (enables HTTPS/WSS)
    tls_key: ?[]const u8 = null, // TLS private key path

    pub fn parse(allocator: std.mem.Allocator) !CliArgs {
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
            } else if (std.mem.eql(u8, arg, "send") or
                std.mem.eql(u8, arg, "clipboard-set") or
                std.mem.eql(u8, arg, "clipboard-get"))
            {
                // Commands that take arguments: collect remaining args
                args.command = ipc.Command.fromString(arg);
                var data_parts: std.ArrayListUnmanaged([]const u8) = .{};
                defer data_parts.deinit(allocator);
                while (arg_iter.next()) |data_arg| {
                    data_parts.append(allocator, data_arg) catch {};
                }
                if (data_parts.items.len > 0) {
                    args.send_data = std.mem.join(allocator, " ", data_parts.items) catch null;
                }
            } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
                const val = arg["--timeout=".len..];
                args.timeout_ms = std.fmt.parseInt(u32, val, 10) catch constants.timeout.cli_default_ms;
            } else if (std.mem.startsWith(u8, arg, "--socket=")) {
                args.socket_path = @as(?[]const u8, arg["--socket=".len..]);
            } else if (std.mem.startsWith(u8, arg, "--static-dir=")) {
                args.static_dir = arg["--static-dir=".len..];
            } else if (std.mem.startsWith(u8, arg, "--port=")) {
                const val = arg["--port=".len..];
                args.ws_port = std.fmt.parseInt(u16, val, 10) catch 7681;
            } else if (std.mem.eql(u8, arg, "--pty-log")) {
                args.pty_log = true;
            } else if (std.mem.eql(u8, arg, "--no-delta")) {
                args.no_delta = true;
            } else if (std.mem.startsWith(u8, arg, "--tls-cert=")) {
                args.tls_cert = arg["--tls-cert=".len..];
            } else if (std.mem.startsWith(u8, arg, "--tls-key=")) {
                args.tls_key = arg["--tls-key=".len..];
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
        \\  serve                      Run as server (foreground)
        \\  status                     Show server status
        \\  ping                       Check if server is responsive
        \\  quit                       Shutdown the server
        \\  help                       Show available commands
        \\  shell                      Show detected shell and detection steps
        \\  panes                      List all pane IDs
        \\  windows                    List windows with pane IDs (JSON)
        \\  send <pane_id> [text]      Send text to pane (reads stdin if no text)
        \\  clipboard-set <c|p> <text> Set internal clipboard (c=clipboard, p=primary)
        \\  clipboard-get <c|p>        Get internal clipboard content
        \\  test                       Run test utilities (see 'dullahan test help')
        \\
        \\Options:
        \\  -h, --help           Show this help
        \\  --timeout=MS         Command timeout in milliseconds (default: 5000)
        \\  --socket=PATH        Socket path (default: /tmp/dullahan-<uid>/dullahan.sock)
        \\  --static-dir=PATH    Serve static files from directory
        \\  --port=PORT          WebSocket/HTTP port (default: 7681)
        \\  --pty-log            Enable PTY traffic logging (truncates existing log)
        \\  --no-delta           Disable delta updates (always send full snapshots)
        \\  --no-spawn           Don't auto-spawn server if not running
        \\  --tls-cert=PATH      TLS certificate file (enables HTTPS/WSS)
        \\  --tls-key=PATH       TLS private key file (required with --tls-cert)
        \\
        \\Examples:
        \\  dullahan serve                          # Start HTTP server
        \\  dullahan serve --tls-cert=cert.pem --tls-key=key.pem  # Start HTTPS server
        \\  dullahan panes                          # List pane IDs: "0 1 2"
        \\  dullahan windows                        # List windows with panes (JSON)
        \\  dullahan send 1 "echo hello"            # Send to pane 1
        \\  echo "ls -la" | dullahan send 1         # Send from stdin to pane 1
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

    // Ensure temp directory exists
    paths.ensureTempDir() catch |e| {
        std.debug.print("Error: Could not create temp directory: {}\n", .{e});
        return e;
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

    // Prepare command data
    var send_data = args.send_data;
    var stdin_buf: ?[]u8 = null;
    defer if (stdin_buf) |buf| allocator.free(buf);

    // For send command: if only pane_id provided (no text), read from stdin
    if (command == .send) {
        if (send_data) |data| {
            // Check if data contains text (has a space after pane_id)
            const has_text = std.mem.indexOf(u8, data, " ") != null;
            if (!has_text) {
                // Only pane_id provided, read text from stdin
                const stdin_text = readStdin(allocator) catch |e| {
                    std.debug.print("Error reading stdin: {}\n", .{e});
                    return e;
                };
                if (stdin_text.len > 0) {
                    // Combine: "pane_id stdin_text"
                    stdin_buf = std.fmt.allocPrint(allocator, "{s} {s}", .{ data, stdin_text }) catch null;
                    allocator.free(stdin_text);
                    if (stdin_buf) |buf| {
                        send_data = buf;
                    }
                } else {
                    allocator.free(stdin_text);
                    std.debug.print("Error: No text provided. Usage: send <pane_id> [text]\n", .{});
                    return error.NoData;
                }
            }
        } else {
            std.debug.print("Error: send requires pane_id. Usage: send <pane_id> [text]\n", .{});
            return error.NoData;
        }
    }

    // Send command
    const response = client.sendCommandWithData(command, send_data, allocator) catch |e| {
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

/// Read all available data from stdin (for piped input)
fn readStdin(allocator: std.mem.Allocator) ![]u8 {
    const posix = std.posix;
    const stdin_fd = posix.STDIN_FILENO;

    // Read all stdin into buffer
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    var read_buf: [constants.buffer.general]u8 = undefined;
    while (true) {
        const n = posix.read(stdin_fd, &read_buf) catch |e| {
            if (e == error.WouldBlock) break;
            return e;
        };
        if (n == 0) break;
        try buf.appendSlice(allocator, read_buf[0..n]);
    }

    // Trim trailing newlines before converting to owned slice
    while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == '\n' or buf.items[buf.items.len - 1] == '\r')) {
        _ = buf.pop();
    }

    return buf.toOwnedSlice(allocator);
}

fn spawnServer(allocator: std.mem.Allocator, args: CliArgs) !void {
    _ = args; // Server will compute its own paths from UID

    // Get path to self
    var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_path_buf);

    // Server will use the same paths module, computing paths from UID
    var child = std.process.Child.init(
        &.{ self_path, "serve" },
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

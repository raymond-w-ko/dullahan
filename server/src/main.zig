const std = @import("std");
const dullahan = @import("dullahan");

// Import through the library module to avoid duplicate module errors
const cli = dullahan.cli;
const server = dullahan.server;
const ipc = dullahan.ipc;
const paths = dullahan.paths;
const test_runners = dullahan.test_runners;
const dlog = dullahan.dlog;
const os_name = dullahan.os_name;

// Custom logging to file (path determined at runtime from paths module)
var log_file: ?std.fs.File = null;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = fileLog,
};

fn fileLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Lazy init log file
    if (log_file == null) {
        // Ensure temp directory exists
        paths.ensureTempDir() catch return;

        const log_path = paths.StaticPaths.log();
        log_file = std.fs.createFileAbsolute(log_path, .{
            .truncate = false,
        }) catch return;
        // Seek to end for append
        log_file.?.seekFromEnd(0) catch {};
    }

    const file = log_file orelse return;

    // Get timestamp
    const ts = std.time.timestamp();
    const level_str = comptime level.asText();
    const scope_str = if (scope == .default) "" else @tagName(scope);

    // Format into buffer, then write
    var buf: [4096]u8 = undefined;
    const prefix = if (scope_str.len > 0)
        std.fmt.bufPrint(&buf, "[{d}] {s} ({s}): ", .{ ts, level_str, scope_str }) catch return
    else
        std.fmt.bufPrint(&buf, "[{d}] {s}: ", .{ ts, level_str }) catch return;

    file.writeAll(prefix) catch return;

    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format ++ "\n", args) catch return;
    file.writeAll(msg) catch return;
}

pub fn main() !void {
    // Resolve OS name once before any other startup work.
    os_name.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try cli.CliArgs.parse(allocator);

    // Ensure temp file paths include the requested port.
    paths.setPort(args.ws_port);

    // Initialize debug logging (loads DULLAHAN_DEBUG env var)
    dlog.init();

    if (args.help) {
        cli.printUsage();
        return;
    }

    if (args.test_command) |test_cmd| {
        // Run test utility
        test_runners.runTest(allocator, test_cmd) catch |e| {
            std.debug.print("Test error: {}\n", .{e});
            std.process.exit(1);
        };
    } else if (args.serve) {
        // If --background/-d flag, spawn ourselves without the flag and exit
        if (args.background) {
            try spawnBackground(allocator, args);
            return;
        }

        // Run as server - ipc.Config handles path defaults and temp dir creation
        const config = server.RunConfig{
            .ipc = .{
                .socket_path = args.socket_path,
                .pid_path = args.pid_path,
            },
            .static_dir = args.static_dir,
            .ws_port = args.ws_port,
            .pty_log = args.pty_log,
            .no_delta = args.no_delta,
            .no_sync_output = args.no_sync_output,
            .tls_cert = args.tls_cert,
            .tls_key = args.tls_key,
        };
        try server.run(allocator, config);
    } else if (args.command != null) {
        // Run as client
        cli.runClient(allocator, args) catch {
            // Error already printed
            std.process.exit(1);
        };
    } else {
        cli.printUsage();
    }
}

/// Spawn server in background (for --background/-d flag)
fn spawnBackground(allocator: std.mem.Allocator, args: cli.CliArgs) !void {
    // Get path to self
    var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_path_buf);

    // Build argv without --background/-d flag
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(allocator);

    try argv.append(allocator, self_path);
    try argv.append(allocator, "serve");

    if (args.socket_path) |p| {
        var buf: [512]u8 = undefined;
        const opt = std.fmt.bufPrint(&buf, "--socket={s}", .{p}) catch unreachable;
        try argv.append(allocator, try allocator.dupe(u8, opt));
    }
    if (args.pid_path) |p| {
        var buf: [512]u8 = undefined;
        const opt = std.fmt.bufPrint(&buf, "--pid={s}", .{p}) catch unreachable;
        try argv.append(allocator, try allocator.dupe(u8, opt));
    }
    if (args.static_dir) |p| {
        var buf: [512]u8 = undefined;
        const opt = std.fmt.bufPrint(&buf, "--static-dir={s}", .{p}) catch unreachable;
        try argv.append(allocator, try allocator.dupe(u8, opt));
    }
    if (args.ws_port != 7681) {
        var buf: [64]u8 = undefined;
        const opt = std.fmt.bufPrint(&buf, "--port={d}", .{args.ws_port}) catch unreachable;
        try argv.append(allocator, try allocator.dupe(u8, opt));
    }
    if (args.pty_log) {
        try argv.append(allocator, "--pty-log");
    }
    if (args.no_delta) {
        try argv.append(allocator, "--no-delta");
    }
    if (args.no_sync_output) {
        try argv.append(allocator, "--no-sync-output");
    }
    if (args.tls_cert) |p| {
        var buf: [512]u8 = undefined;
        const opt = std.fmt.bufPrint(&buf, "--tls-cert={s}", .{p}) catch unreachable;
        try argv.append(allocator, try allocator.dupe(u8, opt));
    }
    if (args.tls_key) |p| {
        var buf: [512]u8 = undefined;
        const opt = std.fmt.bufPrint(&buf, "--tls-key={s}", .{p}) catch unreachable;
        try argv.append(allocator, try allocator.dupe(u8, opt));
    }

    var child = std.process.Child.init(argv.items, allocator);

    // Detach from parent
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    std.debug.print("Server started in background\n", .{});

    // Echo tokens even when running in background by reading the tokens file.
    const tokens_path = paths.StaticPaths.tokens();
    var prev_buf: [256]u8 = undefined;
    var prev_len: usize = 0;
    var has_prev = false;
    if (std.fs.openFileAbsolute(tokens_path, .{})) |prev_file| {
        defer prev_file.close();
        prev_len = prev_file.readAll(&prev_buf) catch 0;
        has_prev = prev_len > 0;
    } else |_| {}

    const max_attempts: u32 = 60;
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const file = std.fs.openFileAbsolute(tokens_path, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => {
                std.debug.print("Warning: failed to open tokens file {s}: {any}\n", .{ tokens_path, e });
                return;
            },
        };
        defer file.close();

        var buf: [256]u8 = undefined;
        const n = file.readAll(&buf) catch |e| {
            std.debug.print("Warning: failed to read tokens file {s}: {any}\n", .{ tokens_path, e });
            return;
        };
        if (n == 0) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }
        if (has_prev and n == prev_len and std.mem.eql(u8, buf[0..n], prev_buf[0..n])) {
            // File still contains old tokens; wait for server to write new ones.
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }

        var master: ?[]const u8 = null;
        var view: ?[]const u8 = null;
        var iter = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "master=")) {
                master = line["master=".len..];
            } else if (std.mem.startsWith(u8, line, "view=")) {
                view = line["view=".len..];
            }
        }

        std.debug.print("  Auth tokens:\n", .{});
        if (master) |token| {
            std.debug.print("    Master: {s}\n", .{token});
        }
        if (view) |token| {
            std.debug.print("    View:   {s}\n", .{token});
        }
        std.debug.print("  Tokens file: {s}\n", .{tokens_path});
        if (args.tls_cert) |cert_path| {
            printAuthUrlsFromCert(cert_path, args.ws_port, master, view);
        }
        return;
    }

    std.debug.print("Warning: tokens file not ready: {s}\n", .{tokens_path});
}

fn certHostFromPath(cert_path: []const u8) []const u8 {
    const base = std.fs.path.basename(cert_path);
    const ext = std.fs.path.extension(base);
    return if (ext.len > 0) base[0 .. base.len - ext.len] else base;
}

fn printAuthUrlsFromCert(cert_path: []const u8, port: u16, master: ?[]const u8, view: ?[]const u8) void {
    const host = certHostFromPath(cert_path);
    std.debug.print("  Auth URLs (cert host):\n", .{});
    if (port == 443) {
        if (master) |token| {
            std.debug.print("    Master: https://{s}/?token={s}\n", .{ host, token });
        }
        if (view) |token| {
            std.debug.print("    View:   https://{s}/?token={s}\n", .{ host, token });
        }
    } else {
        if (master) |token| {
            std.debug.print("    Master: https://{s}:{d}/?token={s}\n", .{ host, port, token });
        }
        if (view) |token| {
            std.debug.print("    View:   https://{s}:{d}/?token={s}\n", .{ host, port, token });
        }
    }
}

// Tests specific to main (CLI, arg parsing, etc.)
test "main module sanity check" {
    try std.testing.expect(true);
}

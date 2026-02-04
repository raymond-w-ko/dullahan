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

    // Initialize debug logging (loads DULLAHAN_DEBUG env var)
    dlog.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try cli.CliArgs.parse(allocator);

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
}

// Tests specific to main (CLI, arg parsing, etc.)
test "main module sanity check" {
    try std.testing.expect(true);
}

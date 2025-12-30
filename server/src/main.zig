const std = @import("std");
const dullahan = @import("dullahan");

// Import through the library module to avoid duplicate module errors
const cli = dullahan.cli;
const server = dullahan.server;
const ipc = dullahan.ipc;

// Custom logging to file
const log_file_path = "/tmp/dullahan.log";
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
        log_file = std.fs.createFileAbsolute(log_file_path, .{
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try cli.CliArgs.parse(allocator);

    if (args.help) {
        cli.printUsage();
        return;
    }

    if (args.serve) {
        // Run as server
        const config = server.RunConfig{
            .ipc = .{
                .socket_path = args.socket_path,
                .pid_path = args.pid_path,
            },
            .static_dir = args.static_dir,
            .ws_port = args.ws_port,
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

// Tests specific to main (CLI, arg parsing, etc.)
test "main module sanity check" {
    try std.testing.expect(true);
}

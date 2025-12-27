const std = @import("std");
const dullahan = @import("dullahan");

// Import through the library module to avoid duplicate module errors
const cli = dullahan.cli;
const server = dullahan.server;
const ipc = dullahan.ipc;

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
        const config = ipc.Config{
            .socket_path = args.socket_path,
            .pid_path = args.pid_path,
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

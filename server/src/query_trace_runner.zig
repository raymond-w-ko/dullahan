//! Minimal runner that exercises the verification harness against a handful of
//! parser-routed query cases. This is intentionally a smoke test for the
//! diagnostics substrate; the full compatibility matrix is tracked separately.

const std = @import("std");

const Pane = @import("pane.zig").Pane;
const verification_harness = @import("verification_harness.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    const artifact_dir = try runSmoke(allocator);
    defer allocator.free(artifact_dir);
    std.debug.print("query-trace artifacts: {s}\n", .{artifact_dir});
}

pub fn runSmoke(allocator: std.mem.Allocator) ![]u8 {
    var harness = try verification_harness.Harness.init(allocator, .{
        .label = "query-trace",
        .debug_config = "+all,-delta",
    });
    defer harness.deinit();

    var pane = try Pane.init(allocator, .{ .cols = 80, .rows = 24, .id = 1 });
    defer pane.deinit();
    try harness.attachFakePty(&pane);

    const cases = [_]struct { name: []const u8, request: []const u8 }{
        .{ .name = "osc11-bel", .request = "\x1b]11;?\x07" },
        .{ .name = "osc11-st", .request = "\x1b]11;?\x1b\\" },
        .{ .name = "da1", .request = "\x1b[c" },
        .{ .name = "dsr-status", .request = "\x1b[5n" },
    };

    for (cases) |case| {
        const response = try harness.captureFeed(&pane, case.name, case.request);
        allocator.free(response);
    }

    try pane.feed("cursor-trace");
    const cursor_response = try harness.captureFeed(&pane, "dsr-cursor", "\x1b[6n");
    allocator.free(cursor_response);

    _ = try harness.finish();
    return allocator.dupe(u8, harness.artifact_dir);
}

test "query trace runner emits harness artifacts" {
    const artifact_dir = try runSmoke(std.testing.allocator);
    defer std.testing.allocator.free(artifact_dir);

    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/manifest.json", .{artifact_dir});
    defer std.testing.allocator.free(manifest_path);
    const server_log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/server.log", .{artifact_dir});
    defer std.testing.allocator.free(server_log_path);
    const pty_log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/pty-traffic.jsonl", .{artifact_dir});
    defer std.testing.allocator.free(pty_log_path);

    var manifest_file = try std.fs.openFileAbsolute(manifest_path, .{});
    manifest_file.close();
    var server_log_file = try std.fs.openFileAbsolute(server_log_path, .{});
    server_log_file.close();
    var pty_log_file = try std.fs.openFileAbsolute(pty_log_path, .{});
    pty_log_file.close();
}

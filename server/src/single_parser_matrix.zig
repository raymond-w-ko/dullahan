//! End-to-end single-parser compatibility matrix.
//!
//! This runner exercises the user-visible probes called out in the migration
//! plan and preserves a reusable diagnostics artifact bundle for the whole run.

const std = @import("std");

const Pane = @import("pane.zig").Pane;
const verification_harness = @import("verification_harness.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    const artifact_dir = try runSmoke(allocator);
    defer allocator.free(artifact_dir);
    std.debug.print("single-parser matrix artifacts: {s}\n", .{artifact_dir});
}

pub fn runSmoke(allocator: std.mem.Allocator) ![]u8 {
    var harness = try verification_harness.Harness.init(allocator, .{
        .label = "single-parser-matrix",
        .debug_config = "+all,-delta",
    });
    defer harness.deinit();

    var pane = try Pane.init(allocator, .{ .cols = 80, .rows = 24, .id = 1 });
    defer pane.deinit();
    try harness.attachFakePty(&pane);

    try runMatrix(allocator, &harness, &pane);

    _ = try harness.finish();
    return allocator.dupe(u8, harness.artifact_dir);
}

fn runMatrix(
    allocator: std.mem.Allocator,
    harness: *verification_harness.Harness,
    pane: *Pane,
) !void {
    try expectPrefixSuffix(allocator, harness, pane, "lipgloss-osc11-bel", "\x1b]11;?\x07", "\x1b]11;rgb:", "\x07");
    try expectPrefixSuffix(allocator, harness, pane, "lipgloss-osc11-st", "\x1b]11;?\x1b\\", "\x1b]11;rgb:", "\x1b\\");

    try expectExact(allocator, harness, pane, "fish-da1", "\x1b[c", "\x1b[?62;22;52c");
    try expectExact(allocator, harness, pane, "vim-da2", "\x1b[>c", "\x1b[>1;10;0c");
    try expectExact(allocator, harness, pane, "vim-dsr-status", "\x1b[5n", "\x1b[0n");

    try pane.feed("cursor-trace");
    try expectExact(allocator, harness, pane, "vim-dsr-cursor", "\x1b[6n", "\x1b[1;13R");

    try expectNoResponse(allocator, harness, pane, "osc52-set", "\x1b]52;c;SGVsbG8gV29ybGQ=\x07");
    try expectClipboardSet(pane, 'c', "SGVsbG8gV29ybGQ=");
    pane.clearClipboardSet();

    try expectNoResponse(allocator, harness, pane, "osc52-get", "\x1b]52;c;?\x1b\\");
    try expectClipboardGet(pane, 'c');
    pane.clearClipboardGet();

    try expectNoResponse(allocator, harness, pane, "title-osc2", "\x1b]2;Build Status\x07");
    try expectTitle(pane, "Build Status");
    pane.clearTitleChanged();

    try expectNoResponse(allocator, harness, pane, "title-osc0", "\x1b]0;Project Shell\x1b\\");
    try expectTitle(pane, "Project Shell");
    pane.clearTitleChanged();

    try expectNoResponse(allocator, harness, pane, "notify-osc9", "\x1b]9;Hello from OSC 9!\x07");
    try expectNotification(pane, null, "Hello from OSC 9!");
    pane.clearNotification();

    try expectNoResponse(allocator, harness, pane, "notify-osc777", "\x1b]777;notify;Build;Compiling source files...\x07");
    try expectNotification(pane, "Build", "Compiling source files...");
    pane.clearNotification();

    try expectNoResponse(allocator, harness, pane, "progress-osc9-4", "\x1b]9;4;1;25\x07");
    try expectProgress(pane, 1, 25);
    pane.clearProgressChanged();

    try expectExact(
        allocator,
        harness,
        pane,
        "xtgettcap-indn",
        "\x1bP+q696E646E\x1b\\",
        "\x1bP1+r696E646E=5C455B257031256453\x1b\\",
    );
    try expectExact(allocator, harness, pane, "xtversion", "\x1b[>q", "\x1bP>|dullahan dev\x1b\\");
    try expectExact(allocator, harness, pane, "decrqm-sync-output", "\x1b[?2026$p", "\x1b[?2026;2$y");
    try expectExact(allocator, harness, pane, "kitty-keyboard-query", "\x1b[?u", "\x1b[?0u");

    try expectNoResponse(allocator, harness, pane, "osc7-pwd", "\x1b]7;file://localhost/tmp/dullahan/project\x07");
    try expectPwd(pane, "file://localhost/tmp/dullahan/project");

    const size_14 = try std.fmt.allocPrint(allocator, "\x1b[4;{d};{d}t", .{
        pane.terminal.height_px,
        pane.terminal.width_px,
    });
    defer allocator.free(size_14);
    try expectExact(allocator, harness, pane, "size-report-14t", "\x1b[14t", size_14);

    const size_18 = try std.fmt.allocPrint(allocator, "\x1b[8;{d};{d}t", .{
        pane.rows,
        pane.cols,
    });
    defer allocator.free(size_18);
    try expectExact(allocator, harness, pane, "size-report-18t", "\x1b[18t", size_18);
}

fn expectExact(
    allocator: std.mem.Allocator,
    harness: *verification_harness.Harness,
    pane: *Pane,
    name: []const u8,
    request: []const u8,
    expected: []const u8,
) !void {
    std.debug.print("matrix case: {s}\n", .{name});
    const response = try harness.captureFeed(pane, name, request);
    defer allocator.free(response);

    if (!std.mem.eql(u8, response, expected)) {
        std.debug.print("matrix failure [{s}]: expected exact response\n", .{name});
        std.debug.print("  expected len={d}\n", .{expected.len});
        std.debug.print("  actual len={d}\n", .{response.len});
        return error.MatrixExpectationFailed;
    }
}

fn expectPrefixSuffix(
    allocator: std.mem.Allocator,
    harness: *verification_harness.Harness,
    pane: *Pane,
    name: []const u8,
    request: []const u8,
    prefix: []const u8,
    suffix: []const u8,
) !void {
    std.debug.print("matrix case: {s}\n", .{name});
    const response = try harness.captureFeed(pane, name, request);
    defer allocator.free(response);

    if (!std.mem.startsWith(u8, response, prefix) or !std.mem.endsWith(u8, response, suffix)) {
        std.debug.print("matrix failure [{s}]: expected prefix/suffix match\n", .{name});
        std.debug.print("  prefix len={d}\n", .{prefix.len});
        std.debug.print("  suffix len={d}\n", .{suffix.len});
        std.debug.print("  actual len={d}\n", .{response.len});
        return error.MatrixExpectationFailed;
    }
}

fn expectNoResponse(
    allocator: std.mem.Allocator,
    harness: *verification_harness.Harness,
    pane: *Pane,
    name: []const u8,
    request: []const u8,
) !void {
    std.debug.print("matrix case: {s}\n", .{name});
    const response = try harness.captureFeed(pane, name, request);
    defer allocator.free(response);

    if (response.len != 0) {
        std.debug.print("matrix failure [{s}]: expected no response, got len={d}\n", .{ name, response.len });
        return error.MatrixExpectationFailed;
    }
}

fn expectTitle(pane: *Pane, expected: []const u8) !void {
    try std.testing.expect(pane.hasTitleChanged());
    try std.testing.expectEqualStrings(expected, pane.getTitle().?);
}

fn expectNotification(pane: *Pane, expected_title: ?[]const u8, expected_body: []const u8) !void {
    try std.testing.expect(pane.hasNotification());
    const notification = pane.getNotification().?;
    if (expected_title) |title| {
        try std.testing.expectEqualStrings(title, notification.title.?);
    } else {
        try std.testing.expect(notification.title == null);
    }
    try std.testing.expectEqualStrings(expected_body, notification.body);
}

fn expectProgress(pane: *Pane, expected_state: u8, expected_value: u8) !void {
    try std.testing.expect(pane.hasProgressChanged());
    const progress = pane.getProgress();
    try std.testing.expectEqual(expected_state, progress.state);
    try std.testing.expectEqual(expected_value, progress.value);
}

fn expectClipboardSet(pane: *Pane, expected_kind: u8, expected_data: []const u8) !void {
    try std.testing.expect(pane.hasClipboardSet());
    const op = pane.getClipboardSet().?;
    try std.testing.expectEqual(expected_kind, op.kind);
    try std.testing.expectEqualStrings(expected_data, op.data);
}

fn expectClipboardGet(pane: *Pane, expected_kind: u8) !void {
    try std.testing.expect(pane.hasClipboardGet());
    try std.testing.expectEqual(expected_kind, pane.getClipboardGetKind().?);
}

fn expectPwd(pane: *Pane, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, pane.terminal.getPwd().?);
}

test "single parser matrix smoke completes and preserves artifacts" {
    const artifact_dir = try runSmoke(std.testing.allocator);
    defer std.testing.allocator.free(artifact_dir);

    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/manifest.json", .{artifact_dir});
    defer std.testing.allocator.free(manifest_path);
    var manifest_file = try std.fs.openFileAbsolute(manifest_path, .{});
    manifest_file.close();
}

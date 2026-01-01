//! Delta sync test data generator
//!
//! Generates test fixtures for verifying delta sync correctness:
//! - snapshot_a.bin: Initial terminal state
//! - snapshot_b.bin: Terminal state after input
//! - delta.bin: Delta update from A to B
//!
//! Run with: zig build gen-delta-test

const std = @import("std");
const dullahan = @import("dullahan");
const Pane = dullahan.Pane;
const snapshot = dullahan.snapshot;

const log = std.log.scoped(.delta_test_gen);

/// Test case definition
const TestCase = struct {
    name: []const u8,
    cols: u16,
    rows: u16,
    initial_input: []const u8,
    delta_input: []const u8,
};

const test_cases = [_]TestCase{
    .{
        .name = "simple_echo",
        .cols = 80,
        .rows = 24,
        .initial_input = "hello\r\n",
        .delta_input = "world\r\n",
    },
    .{
        .name = "cursor_move",
        .cols = 40,
        .rows = 10,
        .initial_input = "line1\r\nline2\r\n",
        .delta_input = "\x1b[Hstart", // Move to home, write "start"
    },
    .{
        .name = "colors",
        .cols = 40,
        .rows = 10,
        .initial_input = "plain\r\n",
        .delta_input = "\x1b[31mred\x1b[0m\r\n", // Red text
    },
    .{
        .name = "multi_line",
        .cols = 40,
        .rows = 10,
        .initial_input = "",
        .delta_input = "a\r\nb\r\nc\r\n",
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create output directory
    const out_dir = "test_fixtures/delta";
    std.fs.cwd().makePath(out_dir) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    for (test_cases) |tc| {
        try generateTestCase(allocator, out_dir, tc);
    }

    log.info("Generated {d} test cases in {s}/", .{ test_cases.len, out_dir });
}

fn generateTestCase(allocator: std.mem.Allocator, out_dir: []const u8, tc: TestCase) !void {
    log.info("Generating test case: {s}", .{tc.name});

    // Create pane
    var pane = try Pane.init(allocator, .{
        .cols = tc.cols,
        .rows = tc.rows,
    });
    defer pane.deinit();

    // Feed initial input
    if (tc.initial_input.len > 0) {
        try pane.feed(tc.initial_input);
    }

    // Clear dirty rows after initial state (so delta only captures the change)
    pane.clearDirtyRows();

    // Generate snapshot A (before delta input)
    const snapshot_a = try snapshot.generateBinarySnapshot(allocator, &pane);
    defer allocator.free(snapshot_a);

    const gen_a = pane.generation;
    log.debug("Snapshot A: gen={d}, {d} bytes", .{ gen_a, snapshot_a.len });

    // Feed delta input
    try pane.feed(tc.delta_input);

    // Generate snapshot B (after delta input)
    const snapshot_b = try snapshot.generateBinarySnapshot(allocator, &pane);
    defer allocator.free(snapshot_b);

    const gen_b = pane.generation;
    log.debug("Snapshot B: gen={d}, {d} bytes, dirty_rows={d}", .{
        gen_b,
        snapshot_b.len,
        pane.getDirtyRowCount(),
    });

    // Generate delta (captures changes from A to B)
    const delta = try snapshot.generateDelta(allocator, &pane, false);
    defer allocator.free(delta);

    log.debug("Delta: {d} bytes", .{delta.len});

    // Write test case metadata
    var meta_path_buf: [256]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&meta_path_buf, "{s}/{s}_meta.json", .{ out_dir, tc.name });

    var meta_file = try std.fs.cwd().createFile(meta_path, .{});
    defer meta_file.close();

    var buf: [1024]u8 = undefined;
    const meta_json = try std.fmt.bufPrint(&buf,
        \\{{
        \\  "name": "{s}",
        \\  "cols": {d},
        \\  "rows": {d},
        \\  "gen_a": {d},
        \\  "gen_b": {d}
        \\}}
    , .{
        tc.name,
        tc.cols,
        tc.rows,
        gen_a,
        gen_b,
    });
    try meta_file.writeAll(meta_json);

    // Write snapshot A
    var path_buf: [256]u8 = undefined;
    const snapshot_a_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}_snapshot_a.bin", .{ out_dir, tc.name });
    try writeFile(snapshot_a_path, snapshot_a);

    // Write snapshot B
    const snapshot_b_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}_snapshot_b.bin", .{ out_dir, tc.name });
    try writeFile(snapshot_b_path, snapshot_b);

    // Write delta
    const delta_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}_delta.bin", .{ out_dir, tc.name });
    try writeFile(delta_path, delta);

    log.info("  Written: {s}_*.bin", .{tc.name});
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

// Also export as library for Zig tests
pub fn generateTestData(allocator: std.mem.Allocator, tc: TestCase) !struct {
    snapshot_a: []u8,
    snapshot_b: []u8,
    delta: []u8,
    gen_a: u64,
    gen_b: u64,
} {
    var pane = try Pane.init(allocator, .{
        .cols = tc.cols,
        .rows = tc.rows,
    });
    defer pane.deinit();

    if (tc.initial_input.len > 0) {
        try pane.feed(tc.initial_input);
    }

    pane.clearDirtyRows();

    const snapshot_a = try snapshot.generateBinarySnapshot(allocator, &pane);
    errdefer allocator.free(snapshot_a);

    const gen_a = pane.generation;

    try pane.feed(tc.delta_input);

    const snapshot_b = try snapshot.generateBinarySnapshot(allocator, &pane);
    errdefer allocator.free(snapshot_b);

    const gen_b = pane.generation;

    const delta_data = try snapshot.generateDelta(allocator, &pane, false);
    errdefer allocator.free(delta_data);

    return .{
        .snapshot_a = snapshot_a,
        .snapshot_b = snapshot_b,
        .delta = delta_data,
        .gen_a = gen_a,
        .gen_b = gen_b,
    };
}

test "generate simple test data" {
    const allocator = std.testing.allocator;

    const result = try generateTestData(allocator, .{
        .name = "test",
        .cols = 10,
        .rows = 5,
        .initial_input = "hi\r\n",
        .delta_input = "bye\r\n",
    });
    defer allocator.free(result.snapshot_a);
    defer allocator.free(result.snapshot_b);
    defer allocator.free(result.delta);

    // Basic sanity checks
    try std.testing.expect(result.snapshot_a.len > 0);
    try std.testing.expect(result.snapshot_b.len > 0);
    try std.testing.expect(result.delta.len > 0);
    try std.testing.expect(result.gen_b > result.gen_a);
}

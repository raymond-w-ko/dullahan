//! Deterministic stress coverage for Kitty keyboard negotiation.
//!
//! Exercises parser fragmentation, query/response ordering, per-screen mode
//! stacks, and the key encoder state derived from the active terminal screen.

const std = @import("std");
const posix = std.posix;

const keyboard = @import("keyboard.zig");
const Pane = @import("pane.zig").Pane;

const da1_response = "\x1b[?62;22;52c";
const alt_enter_legacy = "\x1b\r";
const alt_enter_kitty = "\x1b[13;3u";

pub fn run(allocator: std.mem.Allocator, args: ?[]const u8) !void {
    const iterations = try parseIterations(args);
    try runIterations(allocator, iterations);
    std.debug.print("Kitty keyboard negotiation stress passed: {d} iterations\n", .{iterations});
}

pub fn runIterations(allocator: std.mem.Allocator, iterations: usize) !void {
    var pane = try Pane.init(allocator, .{ .cols = 80, .rows = 24, .id = 1 });
    defer pane.deinit();

    const fds = try posix.pipe();
    errdefer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }
    pane.pty = .{
        .master = fds[1],
        .slave = fds[0],
    };

    var seed: u64 = 0x4b495454595f4b42;
    for (0..iterations) |iteration| {
        // Start every iteration from a genuinely fresh primary screen and
        // disabled keyboard stacks. RIS emits no response.
        try feedFragmented(&pane, "\x1bc", &seed);
        try expectScreenAndFlags(&pane, .primary, 0);

        // Pi-style startup: push desired flags, query them, then issue DA as a
        // response-ordering sentinel. Arbitrary fragmentation must not matter.
        try feedFragmented(&pane, "\x1b[>7u\x1b[?u\x1b[c", &seed);
        try expectResponse(fds[0], "\x1b[?7u" ++ da1_response);
        try expectScreenAndFlags(&pane, .primary, 7);
        try expectAltEnterEncoding(&pane, alt_enter_kitty);

        // Kitty mode stacks are screen-local. Entering a fresh alternate
        // screen after negotiation must report zero rather than leaking the
        // primary stack. This is the state disagreement that motivated the
        // stress test and the associated diagnostics.
        try feedFragmented(&pane, "\x1b[?1049h\x1b[?u\x1b[c", &seed);
        try expectResponse(fds[0], "\x1b[?0u" ++ da1_response);
        try expectScreenAndFlags(&pane, .alternate, 0);
        try expectAltEnterEncoding(&pane, alt_enter_legacy);

        // Negotiate independently on the alternate screen, then bounce between
        // screens while querying on both sides.
        try feedFragmented(&pane, "\x1b[>3u\x1b[?u", &seed);
        try expectResponse(fds[0], "\x1b[?3u");
        try expectScreenAndFlags(&pane, .alternate, 3);

        try feedFragmented(&pane, "\x1b[?1049l\x1b[?u", &seed);
        try expectResponse(fds[0], "\x1b[?7u");
        try expectScreenAndFlags(&pane, .primary, 7);

        // Restore the primary stack entry pushed above.
        try feedFragmented(&pane, "\x1b[<u\x1b[?u", &seed);
        try expectResponse(fds[0], "\x1b[?0u");
        try expectScreenAndFlags(&pane, .primary, 0);

        // Restore the alternate stack entry and verify no cross-screen leak.
        try feedFragmented(&pane, "\x1b[?1049h\x1b[?u", &seed);
        try expectResponse(fds[0], "\x1b[?3u");
        try feedFragmented(&pane, "\x1b[<u\x1b[?u\x1b[?1049l", &seed);
        try expectResponse(fds[0], "\x1b[?0u");
        try expectScreenAndFlags(&pane, .primary, 0);

        if (iteration % 257 == 0) {
            // Exercise oversized pop hardening without performing attacker-
            // controlled work proportional to the requested count.
            try feedFragmented(&pane, "\x1b[>31u\x1b[<65535u\x1b[?u", &seed);
            try expectResponse(fds[0], "\x1b[?0u");
        }
    }
}

fn parseIterations(args: ?[]const u8) !usize {
    const raw = std.mem.trim(u8, args orelse "", " \t\r\n");
    if (raw.len == 0) return 1000;
    const value = try std.fmt.parseInt(usize, raw, 10);
    if (value == 0 or value > 100_000) return error.InvalidIterationCount;
    return value;
}

fn feedFragmented(pane: *Pane, bytes: []const u8, seed: *u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
        const chunk_len = @min(@as(usize, @intCast((seed.* >> 32) % 9 + 1)), bytes.len - offset);
        try pane.feed(bytes[offset .. offset + chunk_len]);
        offset += chunk_len;
    }
}

fn expectResponse(fd: posix.fd_t, expected: []const u8) !void {
    var actual: [128]u8 = undefined;
    if (expected.len > actual.len) return error.ExpectedResponseTooLarge;

    var offset: usize = 0;
    while (offset < expected.len) {
        const read_len = try posix.read(fd, actual[offset..expected.len]);
        if (read_len == 0) return error.UnexpectedResponseEof;
        offset += read_len;
    }
    if (!std.mem.eql(u8, expected, actual[0..offset])) {
        std.debug.print("Kitty stress response mismatch\n  expected={any}\n  actual={any}\n", .{ expected, actual[0..offset] });
        return error.KittyResponseMismatch;
    }
}

fn expectScreenAndFlags(
    pane: *Pane,
    expected_screen: @TypeOf(pane.terminal.screens.active_key),
    expected_flags: u5,
) !void {
    if (pane.terminal.screens.active_key != expected_screen) return error.KittyScreenMismatch;
    if (pane.terminal.screens.active.kitty_keyboard.current().int() != expected_flags) {
        return error.KittyFlagsMismatch;
    }
}

fn expectAltEnterEncoding(pane: *Pane, expected: []const u8) !void {
    var output_buf: [keyboard.max_encoded_size]u8 = undefined;
    const output = keyboard.keyEventToBytes(.{
        .type = "key",
        .key = "Enter",
        .code = "Enter",
        .state = "down",
        .alt = true,
    }, &output_buf, keyboard.EncodeOptions.fromTerminal(&pane.terminal));
    if (!std.mem.eql(u8, output, expected)) return error.KittyEncodingMismatch;
}

test "Kitty keyboard negotiation survives fragmentation and screen churn" {
    try runIterations(std.testing.allocator, 64);
}

test "Kitty keyboard stress iteration bounds" {
    try std.testing.expectEqual(@as(usize, 1000), try parseIterations(null));
    try std.testing.expectEqual(@as(usize, 12), try parseIterations(" 12 "));
    try std.testing.expectError(error.InvalidIterationCount, parseIterations("0"));
    try std.testing.expectError(error.InvalidIterationCount, parseIterations("100001"));
}

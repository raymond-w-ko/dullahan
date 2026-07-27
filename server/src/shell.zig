//! Shell detection module
//!
//! Detects the user's preferred shell with verbose logging of the
//! decision process. Used by pane.zig when spawning shells.

const std = @import("std");
const log = std.log.scoped(.shell);
var environment_shell: ?[]const u8 = null;

pub fn init(shell: ?[]const u8) void {
    environment_shell = shell;
}

/// Result of shell detection with explanation
pub const ShellInfo = struct {
    /// The shell path to use
    path: []const u8,
    /// How the shell was determined
    source: Source,

    pub const Source = enum {
        /// From $SHELL environment variable
        env_shell,
        /// Fallback to /bin/sh
        fallback_bin_sh,
    };

    pub fn sourceDescription(self: ShellInfo) []const u8 {
        return switch (self.source) {
            .env_shell => "$SHELL environment variable",
            .fallback_bin_sh => "fallback (no $SHELL set)",
        };
    }
};

/// Detect the user's shell with verbose logging.
/// Returns the shell path and how it was determined.
pub fn detectShell(io: std.Io) ShellInfo {
    log.info("Detecting shell...", .{});

    // Step 1: Check $SHELL environment variable
    if (environment_shell) |shell| {
        log.info("  $SHELL is set: {s}", .{shell});

        // Validate the path exists and is executable
        std.Io.Dir.accessAbsolute(io, shell, .{}) catch |e| {
            log.warn("  $SHELL path not accessible: {s} ({})", .{ shell, e });
            log.info("  Falling back to /bin/sh", .{});
            return .{ .path = "/bin/sh", .source = .fallback_bin_sh };
        };

        log.info("  Using shell from $SHELL: {s}", .{shell});
        return .{ .path = shell, .source = .env_shell };
    }

    // Step 2: Fallback to /bin/sh
    log.info("  $SHELL not set", .{});
    log.info("  Falling back to /bin/sh", .{});
    return .{ .path = "/bin/sh", .source = .fallback_bin_sh };
}

/// Format shell detection info for display (e.g., CLI output)
pub fn formatShellInfo(info: ShellInfo, writer: anytype) !void {
    try writer.print("Shell: {s}\n", .{info.path});
    try writer.print("Source: {s}\n", .{info.sourceDescription()});
}

/// Get verbose detection steps for CLI output
pub fn getDetectionSteps(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    const writer = &buf.writer;

    try writer.writeAll("Shell detection steps:\n");

    // Step 1: Check $SHELL
    if (environment_shell) |shell| {
        try writer.print("  1. $SHELL is set: {s}\n", .{shell});

        // Check if accessible
        std.Io.Dir.accessAbsolute(io, shell, .{}) catch |e| {
            try writer.print("     -> Path not accessible: {}\n", .{e});
            try writer.writeAll("  2. Falling back to /bin/sh\n");
            try writer.writeAll("\nResult: /bin/sh (fallback)\n");
            return buf.toOwnedSlice();
        };

        try writer.writeAll("     -> Path exists and is accessible\n");
        try writer.print("\nResult: {s} (from $SHELL)\n", .{shell});
    } else {
        try writer.writeAll("  1. $SHELL is not set\n");
        try writer.writeAll("  2. Falling back to /bin/sh\n");
        try writer.writeAll("\nResult: /bin/sh (fallback)\n");
    }

    return buf.toOwnedSlice();
}

// Tests
test "detectShell returns valid info" {
    const info = detectShell(std.testing.io);
    try std.testing.expect(info.path.len > 0);
}

test "formatShellInfo writes output" {
    const info = ShellInfo{ .path = "/bin/bash", .source = .env_shell };
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatShellInfo(info, &writer);
    try std.testing.expect(writer.buffered().len > 0);
}

//! Tailscale detection and IP retrieval
//!
//! Automatically detects if Tailscale is available and gets the IPv4 address.

const std = @import("std");

const log = std.log.scoped(.tailscale);

/// Result of Tailscale detection
pub const TailscaleInfo = struct {
    /// The Tailscale IPv4 address (e.g., "100.64.1.2")
    ip: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TailscaleInfo) void {
        self.allocator.free(self.ip);
    }
};

/// Paths to try for the Tailscale CLI
const tailscale_paths = &[_][]const u8{
    "tailscale", // Linux/Homebrew (in PATH)
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale", // macOS App Store
};

/// Detect Tailscale and get the IPv4 address.
/// Returns null if Tailscale is not available or not connected.
pub fn detect(allocator: std.mem.Allocator) ?TailscaleInfo {
    // Try each known Tailscale path
    for (tailscale_paths) |tailscale_path| {
        if (tryTailscale(allocator, tailscale_path)) |info| {
            return info;
        }
    }
    return null;
}

/// Timeout for tailscale detection (ms)
const TIMEOUT_MS = 500;

/// Try to get Tailscale IP using a specific executable path
/// Times out after 500ms to avoid blocking server startup
fn tryTailscale(allocator: std.mem.Allocator, tailscale_path: []const u8) ?TailscaleInfo {
    // Use spawn + poll to implement timeout (Child.run has no timeout support)
    var child = std.process.Child.init(
        &.{ tailscale_path, "ip", "-4" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |e| {
        log.debug("Failed to spawn {s}: {}", .{ tailscale_path, e });
        return null;
    };

    // Poll stdout with timeout
    const stdout_fd = child.stdout.?.handle;
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = stdout_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    const ready = std.posix.poll(&poll_fds, TIMEOUT_MS) catch |e| {
        log.debug("Poll failed for {s}: {}", .{ tailscale_path, e });
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return null;
    };

    if (ready == 0) {
        // Timeout - tailscale is hanging
        log.debug("{s} timed out after {}ms", .{ tailscale_path, TIMEOUT_MS });
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return null;
    }

    // Read stdout (process should have output ready)
    var buf: [256]u8 = undefined;
    const n = child.stdout.?.read(&buf) catch |e| {
        log.debug("Failed to read stdout from {s}: {}", .{ tailscale_path, e });
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return null;
    };

    // Wait for process to complete
    const term = child.wait() catch |e| {
        log.debug("Failed to wait for {s}: {}", .{ tailscale_path, e });
        return null;
    };

    // Check if command succeeded
    if (term.Exited != 0) {
        log.debug("{s} exited with code {}", .{ tailscale_path, term.Exited });
        return null;
    }

    // Parse the IP from stdout (trim whitespace)
    const ip_raw = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    if (ip_raw.len == 0) {
        log.debug("{s} returned empty IP", .{tailscale_path});
        return null;
    }

    // Validate it looks like an IP address (basic check)
    if (!isValidIpv4(ip_raw)) {
        log.debug("{s} returned invalid IP: {s}", .{ tailscale_path, ip_raw });
        return null;
    }

    // Allocate a copy of the IP
    const ip = allocator.dupe(u8, ip_raw) catch {
        log.debug("Failed to allocate IP string", .{});
        return null;
    };

    log.info("Detected Tailscale IP via {s}: {s}", .{ tailscale_path, ip });
    return TailscaleInfo{
        .ip = ip,
        .allocator = allocator,
    };
}

/// Basic IPv4 validation (contains dots and digits only)
fn isValidIpv4(s: []const u8) bool {
    if (s.len < 7 or s.len > 15) return false; // "1.1.1.1" to "255.255.255.255"

    var dot_count: u8 = 0;
    for (s) |c| {
        if (c == '.') {
            dot_count += 1;
        } else if (c < '0' or c > '9') {
            return false;
        }
    }
    return dot_count == 3;
}

test "isValidIpv4" {
    const testing = std.testing;
    try testing.expect(isValidIpv4("127.0.0.1"));
    try testing.expect(isValidIpv4("100.64.1.2"));
    try testing.expect(isValidIpv4("255.255.255.255"));
    try testing.expect(!isValidIpv4(""));
    try testing.expect(!isValidIpv4("localhost"));
    try testing.expect(!isValidIpv4("1.2.3")); // missing octet
    try testing.expect(!isValidIpv4("1.2.3.4.5")); // too many octets
}

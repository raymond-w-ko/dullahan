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

/// Try to get Tailscale IP using a specific executable path
/// Times out after 500ms to avoid blocking server startup
fn tryTailscale(allocator: std.mem.Allocator, tailscale_path: []const u8) ?TailscaleInfo {
    // Note: No timeout support in std.process.Child.run
    // If tailscale hangs, server startup will be delayed
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ tailscale_path, "ip", "-4" },
        .max_output_bytes = 256,
    }) catch |e| {
        log.debug("Failed to run {s}: {}", .{ tailscale_path, e });
        return null;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check if command succeeded
    if (result.term.Exited != 0) {
        log.debug("{s} exited with code {}", .{ tailscale_path, result.term.Exited });
        return null;
    }

    // Parse the IP from stdout (trim whitespace)
    const ip_raw = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
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

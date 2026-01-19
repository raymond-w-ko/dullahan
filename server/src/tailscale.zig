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

/// Detect Tailscale and get the IPv4 address.
/// Returns null if Tailscale is not available or not connected.
pub fn detect(allocator: std.mem.Allocator) ?TailscaleInfo {
    // Try to run `tailscale ip -4`
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tailscale", "ip", "-4" },
        .max_output_bytes = 256,
    }) catch |e| {
        log.debug("Failed to run tailscale command: {}", .{e});
        return null;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check if command succeeded
    if (result.term.Exited != 0) {
        log.debug("tailscale command exited with code {}", .{result.term.Exited});
        return null;
    }

    // Parse the IP from stdout (trim whitespace)
    const ip_raw = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (ip_raw.len == 0) {
        log.debug("tailscale returned empty IP", .{});
        return null;
    }

    // Validate it looks like an IP address (basic check)
    if (!isValidIpv4(ip_raw)) {
        log.debug("tailscale returned invalid IP: {s}", .{ip_raw});
        return null;
    }

    // Allocate a copy of the IP
    const ip = allocator.dupe(u8, ip_raw) catch {
        log.debug("Failed to allocate IP string", .{});
        return null;
    };

    log.info("Detected Tailscale IP: {s}", .{ip});
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

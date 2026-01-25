//! Wine-style category debug logging configuration
//!
//! Syntax: "+all,-mouse,+clipboard" or environment variable DULLAHAN_DEBUG
//!
//! Rules:
//! - +category enables a category
//! - -category disables a category
//! - +all / -all enables/disables all categories
//! - Evaluated left-to-right: +all,-mouse = everything except mouse
//!
//! Categories: connection, keyboard, mouse, clipboard, pane, window, delta,
//!             snapshot, layout, theme, pty, dsr, ipc, http, signal

const std = @import("std");

/// All known debug categories
pub const Category = enum {
    connection, // WebSocket connect/disconnect, client join/leave
    keyboard, // Keyboard input
    mouse, // Mouse events
    clipboard, // OSC 52 operations, copy/paste
    pane, // Pane creation, resize, terminal state
    window, // Window creation, layout changes
    delta, // Delta sync, dirty rows, generation tracking
    snapshot, // Terminal snapshots
    layout, // Layout loading, template selection
    theme, // OSC 10/11 color changes, palette sync
    pty, // PTY I/O, shell detection
    dsr, // Device Status Reports
    ipc, // IPC commands, status queries
    http, // HTTP server, WebSocket upgrade
    signal, // Signal handling, shutdown

    pub fn asText(self: Category) []const u8 {
        return @tagName(self);
    }
};

/// All categories for iteration
pub const ALL_CATEGORIES = std.enums.values(Category);

/// Debug configuration state
pub const Config = struct {
    all_enabled: bool = false,
    enabled: std.EnumSet(Category) = .{},
    disabled: std.EnumSet(Category) = .{},
    raw: []const u8 = "",

    /// Check if a category is enabled
    pub fn isEnabled(self: *const Config, cat: Category) bool {
        // Explicit disable always wins
        if (self.disabled.contains(cat)) return false;
        // Explicit enable
        if (self.enabled.contains(cat)) return true;
        // Fall back to all
        return self.all_enabled;
    }

    /// Check if any logging is enabled
    pub fn isAnyEnabled(self: *const Config) bool {
        return self.all_enabled or self.enabled.count() > 0;
    }

    /// Format current config as string (for status display)
    pub fn format(self: *const Config, buf: []u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        if (self.all_enabled) {
            writer.writeAll("+all") catch return "";
            for (ALL_CATEGORIES) |cat| {
                if (self.disabled.contains(cat)) {
                    writer.print(",-{s}", .{cat.asText()}) catch break;
                }
            }
        } else if (self.enabled.count() > 0) {
            var first = true;
            for (ALL_CATEGORIES) |cat| {
                if (self.enabled.contains(cat)) {
                    if (!first) writer.writeAll(",") catch break;
                    writer.print("+{s}", .{cat.asText()}) catch break;
                    first = false;
                }
            }
        } else {
            return "(disabled)";
        }

        return fbs.getWritten();
    }

    /// List enabled categories
    pub fn listEnabled(self: *const Config, buf: []Category) []const Category {
        var count: usize = 0;
        for (ALL_CATEGORIES) |cat| {
            if (self.isEnabled(cat)) {
                if (count < buf.len) {
                    buf[count] = cat;
                    count += 1;
                }
            }
        }
        return buf[0..count];
    }
};

/// Global configuration (runtime mutable)
var config: Config = .{};
var config_mutex: std.Thread.Mutex = .{};

/// Parse Wine-style debug config string
/// Examples: "+all,-mouse", "+mouse,+keyboard", "-all,+connection"
pub fn parse(value: []const u8) Config {
    var result: Config = .{};

    // Empty or "false" means disabled
    if (value.len == 0 or std.mem.eql(u8, value, "false")) {
        return result;
    }

    // "true" means +all (backward compat)
    if (std.mem.eql(u8, value, "true")) {
        result.all_enabled = true;
        result.raw = "+all";
        return result;
    }

    result.raw = value;

    // Parse comma-separated directives
    var iter = std.mem.tokenizeAny(u8, value, ", ");
    while (iter.next()) |part| {
        if (part.len == 0) continue;

        // Determine sign (+ or -)
        var sign: u8 = '+';
        var category_name = part;

        if (part[0] == '+') {
            sign = '+';
            category_name = part[1..];
        } else if (part[0] == '-') {
            sign = '-';
            category_name = part[1..];
        }

        // Handle special 'all' category
        if (std.mem.eql(u8, category_name, "all")) {
            if (sign == '+') {
                result.all_enabled = true;
                result.disabled = .{}; // Reset specific disables
            } else {
                result.all_enabled = false;
                result.enabled = .{}; // Reset specific enables
            }
        } else {
            // Parse category name
            const cat = std.meta.stringToEnum(Category, category_name) orelse continue;
            if (sign == '+') {
                result.enabled.insert(cat);
                result.disabled.remove(cat);
            } else {
                result.disabled.insert(cat);
                result.enabled.remove(cat);
            }
        }
    }

    return result;
}

/// Load config from environment variable
pub fn loadFromEnv() void {
    const env_value = std.posix.getenv("DULLAHAN_DEBUG") orelse return;
    setConfig(parse(env_value));
}

/// Get current config
pub fn getConfig() Config {
    config_mutex.lock();
    defer config_mutex.unlock();
    return config;
}

/// Set config at runtime
pub fn setConfig(new_config: Config) void {
    config_mutex.lock();
    defer config_mutex.unlock();
    config = new_config;
}

/// Set config from string
pub fn setConfigString(value: []const u8) void {
    setConfig(parse(value));
}

/// Check if a category is enabled (thread-safe)
pub fn isEnabled(cat: Category) bool {
    config_mutex.lock();
    defer config_mutex.unlock();
    return config.isEnabled(cat);
}

/// Check if any logging is enabled
pub fn isAnyEnabled() bool {
    config_mutex.lock();
    defer config_mutex.unlock();
    return config.isAnyEnabled();
}

/// Get current config string for display
pub fn getConfigString(buf: []u8) []const u8 {
    config_mutex.lock();
    defer config_mutex.unlock();
    return config.format(buf);
}

// ============================================================================
// Tests
// ============================================================================

test "parse empty" {
    const c = parse("");
    try std.testing.expect(!c.all_enabled);
    try std.testing.expectEqual(@as(usize, 0), c.enabled.count());
}

test "parse +all" {
    const c = parse("+all");
    try std.testing.expect(c.all_enabled);
    try std.testing.expect(c.isEnabled(.clipboard));
    try std.testing.expect(c.isEnabled(.mouse));
}

test "parse +all,-mouse" {
    const c = parse("+all,-mouse");
    try std.testing.expect(c.all_enabled);
    try std.testing.expect(c.isEnabled(.clipboard));
    try std.testing.expect(!c.isEnabled(.mouse));
}

test "parse +clipboard,+pane" {
    const c = parse("+clipboard,+pane");
    try std.testing.expect(!c.all_enabled);
    try std.testing.expect(c.isEnabled(.clipboard));
    try std.testing.expect(c.isEnabled(.pane));
    try std.testing.expect(!c.isEnabled(.mouse));
}

test "parse left-to-right evaluation" {
    // -all,+clipboard should enable only clipboard
    const c = parse("-all,+clipboard");
    try std.testing.expect(!c.all_enabled);
    try std.testing.expect(c.isEnabled(.clipboard));
    try std.testing.expect(!c.isEnabled(.mouse));
}

test "parse unknown category ignored" {
    const c = parse("+all,-unknown,+clipboard");
    try std.testing.expect(c.all_enabled);
    try std.testing.expect(c.isEnabled(.clipboard));
}

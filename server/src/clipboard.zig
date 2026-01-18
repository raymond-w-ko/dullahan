//! OSC 52 Clipboard handling
//!
//! Handles clipboard operations via OSC 52 escape sequences:
//! - SET operations: Terminal sets clipboard content
//! - GET operations: Terminal requests clipboard content from client

const std = @import("std");
const dlog = @import("dlog.zig");
const log_config = @import("log_config.zig");

const log = std.log.scoped(.clipboard);

/// OSC 52 clipboard operation data
pub const ClipboardOp = struct {
    kind: u8, // 'c' (clipboard), 's' (selection), 'p' (primary)
    data: []const u8, // base64-encoded, owned by caller

    pub fn deinit(self: ClipboardOp, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Clipboard handler for OSC 52 operations
/// Manages pending SET/GET operations and timeouts
pub const ClipboardHandler = struct {
    allocator: std.mem.Allocator,

    /// Pending OSC 52 clipboard SET operation
    /// Contains base64-encoded data to send to clients
    pending_set: ?ClipboardOp = null,

    /// Pending OSC 52 clipboard GET request
    /// The value is the clipboard kind ('c', 's', 'p')
    pending_get: ?u8 = null,

    /// Timestamp (ms) when clipboard GET was requested, for timeout handling
    get_timestamp_ms: ?i64 = null,

    /// Whether the GET request has been sent to the client (awaiting response)
    get_sent: bool = false,

    /// Clipboard GET timeout in milliseconds (5 seconds)
    pub const get_timeout_ms: i64 = 5000;

    /// Maximum allowed clipboard response size (100KB)
    pub const max_response_size: usize = 100_000;

    pub fn init(allocator: std.mem.Allocator) ClipboardHandler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ClipboardHandler) void {
        if (self.pending_set) |op| {
            op.deinit(self.allocator);
        }
    }

    // ========================================================================
    // SET operations
    // ========================================================================

    /// Check if there's a pending clipboard SET operation
    pub fn hasSet(self: *const ClipboardHandler) bool {
        return self.pending_set != null;
    }

    /// Get the pending clipboard SET operation (if any)
    pub fn getSet(self: *const ClipboardHandler) ?ClipboardOp {
        return self.pending_set;
    }

    /// Clear the clipboard SET operation
    pub fn clearSet(self: *ClipboardHandler) void {
        if (self.pending_set) |op| {
            op.deinit(self.allocator);
        }
        self.pending_set = null;
    }

    // ========================================================================
    // GET operations
    // ========================================================================

    /// Check if there's a pending clipboard GET request
    pub fn hasGet(self: *const ClipboardHandler) bool {
        return self.pending_get != null;
    }

    /// Get the clipboard kind for GET request (if any)
    pub fn getGetKind(self: *const ClipboardHandler) ?u8 {
        return self.pending_get;
    }

    /// Clear the clipboard GET request (called when response received or timed out)
    pub fn clearGet(self: *ClipboardHandler) void {
        self.pending_get = null;
        self.get_timestamp_ms = null;
        self.get_sent = false;
    }

    /// Check if clipboard GET request needs to be sent to client
    pub fn needsGetSend(self: *const ClipboardHandler) bool {
        return self.pending_get != null and !self.get_sent;
    }

    /// Mark clipboard GET as sent to client
    pub fn markGetSent(self: *ClipboardHandler) void {
        self.get_sent = true;
    }

    /// Check if a clipboard GET request has timed out
    pub fn hasGetTimedOut(self: *const ClipboardHandler) bool {
        if (self.get_timestamp_ms) |ts| {
            const now = std.time.milliTimestamp();
            return (now - ts) > get_timeout_ms;
        }
        return false;
    }

    // ========================================================================
    // OSC 52 parsing
    // ========================================================================

    /// Handle OSC 52 clipboard operations
    /// Format: <clipboard-kind> ; <base64-data>
    /// clipboard-kind: 'c' (clipboard), 's' (selection), 'p' (primary), or combinations
    /// base64-data: '?' for GET, base64-encoded data for SET
    pub fn handleOsc52(self: *ClipboardHandler, payload: []const u8, pane_id: u16) void {
        // Find semicolon separator between kind and data
        var sep_idx: ?usize = null;
        for (payload, 0..) |c, idx| {
            if (c == ';') {
                sep_idx = idx;
                break;
            }
        }

        if (sep_idx == null) {
            log.debug("OSC 52: missing semicolon separator", .{});
            return;
        }

        const kind_str = payload[0..sep_idx.?];
        const data_str = payload[sep_idx.? + 1 ..];

        // Parse clipboard kind - default to 'c' (system clipboard) if empty
        // Multiple kinds can be specified (e.g., "pc" for primary+clipboard)
        // We select the first one we find in priority order: 'c' > 'p' > 's'
        var kind: u8 = 'c'; // Default if none specified
        if (kind_str.len > 0) {
            // Look for preferred kinds in priority order
            var found_c = false;
            var found_p = false;
            var found_s = false;

            for (kind_str) |k| {
                switch (k) {
                    'c' => found_c = true,
                    'p' => found_p = true,
                    's' => found_s = true,
                    else => {},
                }
            }

            // Select by priority: c > p > s
            if (found_c) {
                kind = 'c';
            } else if (found_p) {
                kind = 'p';
            } else if (found_s) {
                kind = 's';
            }
            // If none of c/p/s found, keep default 'c'
        }

        // Check for GET request
        if (data_str.len == 1 and data_str[0] == '?') {
            log.debug("OSC 52 GET request: kind={c}", .{kind});
            if (log_config.log_clipboard) {
                dlog.debug("OSC 52 GET parsed: pane={d} kind='{c}'", .{ pane_id, kind });
            }
            self.pending_get = kind;
            self.get_timestamp_ms = std.time.milliTimestamp();
            return;
        }

        // SET request - data_str contains base64-encoded content
        if (data_str.len == 0) {
            log.debug("OSC 52 SET: empty data (clear clipboard)", .{});
            // Empty data means clear clipboard - still send to client
        }

        // Free any existing pending set operation
        if (self.pending_set) |old| {
            old.deinit(self.allocator);
        }

        // Copy the base64 data (we own it)
        const data_copy = self.allocator.dupe(u8, data_str) catch |e| {
            log.warn("OSC 52: failed to allocate clipboard data: {any}", .{e});
            self.pending_set = null;
            return;
        };

        self.pending_set = .{
            .kind = kind,
            .data = data_copy,
        };

        log.debug("OSC 52 SET: kind={c}, data_len={d}", .{ kind, data_str.len });
        if (log_config.log_clipboard) {
            dlog.debug("OSC 52 SET parsed: pane={d} kind='{c}' data_len={d}", .{ pane_id, kind, data_str.len });
        }
    }

    /// Handle clipboard GET timeout - returns response to send, or null if not timed out
    /// Caller is responsible for writing the response and clearing the get state
    pub fn checkGetTimeout(self: *ClipboardHandler) ?struct { kind: u8, should_timeout: bool } {
        if (self.pending_get) |kind| {
            if (self.hasGetTimedOut()) {
                log.warn("Clipboard GET timed out for kind={c}", .{kind});
                return .{ .kind = kind, .should_timeout = true };
            }
        }
        return null;
    }

    /// Format OSC 52 response for sending to terminal
    /// Returns formatted response in provided buffer, or null on error
    /// Format: ESC ] 52 ; <kind> ; <base64-data> ESC \
    pub fn formatResponse(kind: u8, data: []const u8, buf: []u8) ?[]u8 {
        const required_size: usize = 9 + data.len;
        if (required_size > buf.len) {
            log.warn("OSC 52 response buffer too small: need {d}, have {d}", .{
                required_size,
                buf.len,
            });
            return null;
        }

        const response = std.fmt.bufPrint(buf, "\x1b]52;{c};{s}\x1b\\", .{ kind, data }) catch |e| {
            log.warn("OSC 52 response format error: {any}", .{e});
            return null;
        };

        return response;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ClipboardHandler init and deinit" {
    var handler = ClipboardHandler.init(std.testing.allocator);
    defer handler.deinit();

    try std.testing.expect(!handler.hasSet());
    try std.testing.expect(!handler.hasGet());
}

test "OSC 52 SET parsing" {
    var handler = ClipboardHandler.init(std.testing.allocator);
    defer handler.deinit();

    // Basic SET
    handler.handleOsc52("c;SGVsbG8gV29ybGQ=", 0);
    try std.testing.expect(handler.hasSet());
    const op = handler.getSet().?;
    try std.testing.expectEqual(@as(u8, 'c'), op.kind);
    try std.testing.expectEqualStrings("SGVsbG8gV29ybGQ=", op.data);
}

test "OSC 52 GET parsing" {
    var handler = ClipboardHandler.init(std.testing.allocator);
    defer handler.deinit();

    handler.handleOsc52("c;?", 0);
    try std.testing.expect(handler.hasGet());
    try std.testing.expectEqual(@as(u8, 'c'), handler.getGetKind().?);
    try std.testing.expect(handler.needsGetSend());

    handler.markGetSent();
    try std.testing.expect(!handler.needsGetSend());
}

test "OSC 52 kind priority" {
    var handler = ClipboardHandler.init(std.testing.allocator);
    defer handler.deinit();

    // Multiple kinds - 'c' should win
    handler.handleOsc52("pcs;SGVsbG8=", 0);
    try std.testing.expectEqual(@as(u8, 'c'), handler.getSet().?.kind);

    handler.clearSet();

    // Without 'c', 'p' should win
    handler.handleOsc52("sp;SGVsbG8=", 0);
    try std.testing.expectEqual(@as(u8, 'p'), handler.getSet().?.kind);
}

test "OSC 52 empty kind defaults to clipboard" {
    var handler = ClipboardHandler.init(std.testing.allocator);
    defer handler.deinit();

    handler.handleOsc52(";SGVsbG8=", 0);
    try std.testing.expectEqual(@as(u8, 'c'), handler.getSet().?.kind);
}

test "formatResponse" {
    var buf: [100]u8 = undefined;

    const response = ClipboardHandler.formatResponse('c', "SGVsbG8=", &buf);
    try std.testing.expect(response != null);
    try std.testing.expectEqualStrings("\x1b]52;c;SGVsbG8=\x1b\\", response.?);
}

test "clearSet frees memory" {
    var handler = ClipboardHandler.init(std.testing.allocator);
    defer handler.deinit();

    handler.handleOsc52("c;SGVsbG8=", 0);
    try std.testing.expect(handler.hasSet());

    handler.clearSet();
    try std.testing.expect(!handler.hasSet());
}

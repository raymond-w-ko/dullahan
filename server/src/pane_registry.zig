//! PaneRegistry - global pane ownership and lookup
//!
//! The registry owns all panes globally, providing O(1) lookup by pane ID.
//! This decouples pane lifetime from window/session lifetime and enables
//! direct routing of messages by paneId.

const std = @import("std");
const Pane = @import("pane.zig").Pane;
const dlog = @import("dlog.zig");

const log = std.log.scoped(.pane_registry);
const plog = dlog.scoped(.pane);

/// Well-known pane ID for debug console (always pane 0 in window 0)
pub const DEBUG_PANE_ID: u16 = 0;

pub const PaneRegistry = struct {
    // Re-export debug pane ID for struct-level access
    pub const DEBUG_PANE = DEBUG_PANE_ID;

    /// All panes, indexed by pane ID
    panes: std.AutoHashMap(u16, *Pane),

    /// Next pane ID to assign
    next_id: u16 = 0,

    /// Allocator for panes
    allocator: std.mem.Allocator,

    /// Default dimensions for new panes
    default_cols: u16,
    default_rows: u16,

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) PaneRegistry {
        return .{
            .panes = std.AutoHashMap(u16, *Pane).init(allocator),
            .allocator = allocator,
            .default_cols = opts.cols,
            .default_rows = opts.rows,
        };
    }

    pub fn deinit(self: *PaneRegistry) void {
        // Deinit and free all panes
        var it = self.panes.valueIterator();
        while (it.next()) |pane_ptr| {
            pane_ptr.*.deinit();
            self.allocator.destroy(pane_ptr.*);
        }
        self.panes.deinit();
    }

    /// Create a new pane with default dimensions
    /// Returns the pane ID
    pub fn create(self: *PaneRegistry) !u16 {
        return self.createWithOptions(.{
            .cols = self.default_cols,
            .rows = self.default_rows,
        });
    }

    /// Create a new pane with specific options
    pub fn createWithOptions(self: *PaneRegistry, opts: Pane.Options) !u16 {
        const pane_id = self.next_id;
        self.next_id += 1;

        // Allocate pane on heap
        const pane_ptr = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane_ptr);

        // Initialize pane with assigned ID
        pane_ptr.* = try Pane.init(self.allocator, .{
            .cols = opts.cols,
            .rows = opts.rows,
            .id = pane_id,
        });
        errdefer pane_ptr.deinit();

        try self.panes.put(pane_id, pane_ptr);

        log.debug("Created pane {d} ({d}x{d})", .{ pane_id, opts.cols, opts.rows });
        plog.debug("Created pane {d} ({d}x{d})", .{ pane_id, opts.cols, opts.rows });

        return pane_id;
    }

    /// Get a pane by ID (O(1) lookup)
    pub fn get(self: *PaneRegistry, id: u16) ?*Pane {
        return self.panes.get(id);
    }

    /// Destroy a pane by ID
    pub fn destroy(self: *PaneRegistry, id: u16) void {
        if (self.panes.fetchRemove(id)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            log.debug("Destroyed pane {d}", .{id});
            plog.debug("Destroyed pane {d}", .{id});
        }
    }

    /// Get pane count
    pub fn count(self: *const PaneRegistry) usize {
        return self.panes.count();
    }

    /// Iterator over all panes
    pub fn iterator(self: *PaneRegistry) std.AutoHashMap(u16, *Pane).ValueIterator {
        return self.panes.valueIterator();
    }

    /// Get debug pane (pane 0 in window 0)
    pub fn getDebugPane(self: *PaneRegistry) ?*Pane {
        return self.get(DEBUG_PANE_ID);
    }

    /// Create a debug pane (no shell, for debug console output)
    /// Returns the pane ID
    pub fn createDebugPane(self: *PaneRegistry) !u16 {
        const pane_id = try self.create();
        // Debug pane doesn't spawn a shell - it receives direct feed
        log.info("Created debug pane {d}", .{pane_id});
        plog.info("Created debug pane {d}", .{pane_id});
        return pane_id;
    }

    /// Create a shell pane (spawns a shell process)
    /// Returns the pane ID
    pub fn createShellPane(self: *PaneRegistry) !u16 {
        const pane_id = try self.create();
        const pane = self.get(pane_id) orelse return error.PaneNotFound;

        pane.spawnShell() catch |e| {
            log.err("Failed to spawn shell in pane {d}: {any}", .{ pane_id, e });
            return e;
        };

        log.info("Created shell pane {d}", .{pane_id});
        plog.info("Created shell pane {d}", .{pane_id});
        return pane_id;
    }

    /// Resize all panes (silently ignores if dimensions unchanged)
    pub fn resizeAll(self: *PaneRegistry, cols: u16, rows: u16) !void {
        // Skip if dimensions haven't changed
        if (cols == self.default_cols and rows == self.default_rows) {
            return;
        }

        self.default_cols = cols;
        self.default_rows = rows;

        var it = self.panes.valueIterator();
        while (it.next()) |pane_ptr| {
            try pane_ptr.*.resize(cols, rows, null, null);
        }
    }
};

// Tests
test "pane registry can create and get panes" {
    var registry = PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    const id1 = try registry.create();
    const id2 = try registry.create();

    try std.testing.expectEqual(@as(u16, 0), id1);
    try std.testing.expectEqual(@as(u16, 1), id2);
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    const pane1 = registry.get(id1);
    try std.testing.expect(pane1 != null);
    try std.testing.expectEqual(id1, pane1.?.id);

    const pane2 = registry.get(id2);
    try std.testing.expect(pane2 != null);
    try std.testing.expectEqual(id2, pane2.?.id);
}

test "pane registry can destroy panes" {
    var registry = PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    const id = try registry.create();
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    registry.destroy(id);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expect(registry.get(id) == null);
}

test "pane registry respects dimensions" {
    var registry = PaneRegistry.init(std.testing.allocator, .{ .cols = 120, .rows = 40 });
    defer registry.deinit();

    const id = try registry.create();
    const pane = registry.get(id).?;

    try std.testing.expectEqual(@as(u16, 120), pane.cols);
    try std.testing.expectEqual(@as(u16, 40), pane.rows);
}

//! Integration tests that span multiple modules
//!
//! These tests import the library as a consumer would,
//! testing interactions between components.

const std = @import("std");
const dullahan = @import("dullahan");

// ============================================================================
// Basic Module Access Tests
// ============================================================================

test "math module is accessible from library root" {
    const result = dullahan.math.add(10, 20);
    try std.testing.expectEqual(30, result);
}

// ============================================================================
// Session + PaneRegistry Integration Tests
// ============================================================================

test "session with registry can create window and panes" {
    // Create pane registry (global pane ownership)
    var registry = dullahan.PaneRegistry.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer registry.deinit();

    // Create session with registry reference
    var session = try dullahan.Session.init(std.testing.allocator, &registry, .{
        .cols = 80,
        .rows = 24,
    });
    defer session.deinit();

    // Session starts empty
    try std.testing.expectEqual(@as(usize, 0), session.windowCount());
    try std.testing.expectEqual(@as(usize, 0), registry.count());

    // Create a window
    const window_id = try session.createWindow();
    try std.testing.expectEqual(@as(u16, 0), window_id);
    try std.testing.expectEqual(@as(usize, 1), session.windowCount());

    // Create panes via registry and add to window
    const pane1_id = try registry.create();
    const pane2_id = try registry.create();
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    const window = session.getWindow(window_id).?;
    try window.addPane(pane1_id);
    try window.addPane(pane2_id);
    window.active_pane_id = pane1_id;

    // Verify panes are accessible through both registry and session
    try std.testing.expect(registry.get(pane1_id) != null);
    try std.testing.expect(registry.get(pane2_id) != null);
    try std.testing.expect(session.getPane(window_id, pane1_id) != null);
    try std.testing.expect(session.getPaneById(pane2_id) != null);
}

test "session hierarchy: session -> window -> pane navigation" {
    var registry = dullahan.PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    var session = try dullahan.Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    // Create window with panes
    const window_id = try session.createWindow();
    const pane_id = try registry.create();

    const window = session.getWindow(window_id).?;
    try window.addPane(pane_id);
    window.active_pane_id = pane_id;

    // Navigate: session -> active window -> active pane
    const active_window = session.activeWindow().?;
    try std.testing.expectEqual(window_id, active_window.id);
    try std.testing.expectEqual(pane_id, active_window.active_pane_id);

    const active_pane = session.activePane().?;
    try std.testing.expectEqual(pane_id, active_pane.id);
}

test "multiple windows share pane registry" {
    var registry = dullahan.PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    var session = try dullahan.Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    // Create two windows
    const window1_id = try session.createWindow();
    const window2_id = try session.createWindow();

    // Create panes for each window via shared registry
    const pane1_id = try registry.create();
    const pane2_id = try registry.create();
    const pane3_id = try registry.create();

    // Add panes to windows
    const window1 = session.getWindow(window1_id).?;
    try window1.addPane(pane1_id);
    window1.active_pane_id = pane1_id;

    const window2 = session.getWindow(window2_id).?;
    try window2.addPane(pane2_id);
    try window2.addPane(pane3_id);
    window2.active_pane_id = pane2_id;

    // All panes accessible via registry regardless of which window they're in
    try std.testing.expectEqual(@as(usize, 3), registry.count());
    try std.testing.expect(registry.get(pane1_id) != null);
    try std.testing.expect(registry.get(pane2_id) != null);
    try std.testing.expect(registry.get(pane3_id) != null);

    // Panes accessible via session.getPaneById (no window context needed)
    try std.testing.expect(session.getPaneById(pane1_id) != null);
    try std.testing.expect(session.getPaneById(pane2_id) != null);
    try std.testing.expect(session.getPaneById(pane3_id) != null);
}

// ============================================================================
// Pane + Terminal Integration Tests
// ============================================================================

test "pane feed and content extraction" {
    var registry = dullahan.PaneRegistry.init(std.testing.allocator, .{
        .cols = 40,
        .rows = 10,
    });
    defer registry.deinit();

    var session = try dullahan.Session.init(std.testing.allocator, &registry, .{
        .cols = 40,
        .rows = 10,
    });
    defer session.deinit();

    // Create window with pane
    const window_id = try session.createWindow();
    const pane_id = try registry.create();
    const window = session.getWindow(window_id).?;
    try window.addPane(pane_id);
    window.active_pane_id = pane_id;

    // Get pane and feed content
    const pane = session.activePane().?;
    try pane.feed("Hello, integration test!\n");
    try pane.feed("Line two\n");

    // Extract content and verify
    const content = try pane.plainString();
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "Hello, integration test!") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Line two") != null);
}

test "pane generation tracking across modules" {
    var registry = dullahan.PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    var session = try dullahan.Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    const window_id = try session.createWindow();
    const pane_id = try registry.create();
    const window = session.getWindow(window_id).?;
    try window.addPane(pane_id);
    window.active_pane_id = pane_id;

    // Get pane via both registry and session
    const pane_via_registry = registry.get(pane_id).?;
    const pane_via_session = session.getPaneById(pane_id).?;

    // Both should be the same pointer
    try std.testing.expectEqual(@intFromPtr(pane_via_registry), @intFromPtr(pane_via_session));

    // Generation starts at 0
    try std.testing.expectEqual(@as(u64, 0), pane_via_registry.generation);

    // Feed content increments generation
    try pane_via_registry.feed("test");
    try std.testing.expect(pane_via_registry.generation > 0);

    // Changes visible via both access paths
    try std.testing.expectEqual(pane_via_registry.generation, pane_via_session.generation);
}

// ============================================================================
// Window Close Integration Test
// ============================================================================

test "closing window cleans up panes in registry" {
    var registry = dullahan.PaneRegistry.init(std.testing.allocator, .{});
    defer registry.deinit();

    var session = try dullahan.Session.init(std.testing.allocator, &registry, .{});
    defer session.deinit();

    // Create window and add panes
    const window_id = try session.createWindow();
    const pane1_id = try registry.create();
    const pane2_id = try registry.create();

    const window = session.getWindow(window_id).?;
    try window.addPane(pane1_id);
    try window.addPane(pane2_id);
    window.active_pane_id = pane1_id;

    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expectEqual(@as(usize, 1), session.windowCount());

    // Close window - panes should be destroyed
    try session.closeWindow(window_id);

    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqual(@as(usize, 0), session.windowCount());
    try std.testing.expect(registry.get(pane1_id) == null);
    try std.testing.expect(registry.get(pane2_id) == null);
}

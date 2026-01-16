//! Terminal module wrapping ghostty-vt
//!
//! This module provides the core terminal emulation functionality
//! using libghostty-vt.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub const Terminal = ghostty_vt.Terminal;

// Re-export types for selection API
pub const Selection = ghostty_vt.Selection;
pub const Screen = ghostty_vt.Screen;
pub const size = ghostty_vt.size;
pub const PageList = ghostty_vt.PageList;

/// Simplified selection bounds for wire protocol serialization.
/// Uses viewport coordinates (client-friendly).
/// Note: x uses CellCountInt (u16) since columns fit in a page,
/// but y uses u32 since it can span scrollback history.
pub const SelectionBounds = struct {
    start_x: size.CellCountInt,
    start_y: u32,
    end_x: size.CellCountInt,
    end_y: u32,
    is_rectangle: bool,
};

/// Create a new terminal with the given dimensions
pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Terminal {
    return Terminal.init(allocator, .{
        .cols = cols,
        .rows = rows,
    });
}

// ============================================================================
// Selection API wrappers
// ============================================================================

/// Check if the terminal has an active selection.
pub fn hasSelection(terminal: *Terminal) bool {
    return terminal.screens.active.selection != null;
}

/// Get the current selection bounds in viewport coordinates.
/// Returns null if there is no selection.
pub fn getSelection(terminal: *Terminal) ?SelectionBounds {
    const screen = terminal.screens.active;
    const sel = screen.selection orelse return null;

    // Get ordered bounds (top-left and bottom-right)
    const tl = sel.topLeft(screen);
    const br = sel.bottomRight(screen);

    // Convert pins to viewport coordinates
    const tl_point = screen.pages.pointFromPin(.viewport, tl) orelse return null;
    const br_point = screen.pages.pointFromPin(.viewport, br) orelse return null;

    return .{
        .start_x = tl.x,
        .start_y = tl_point.viewport.y,
        .end_x = br.x,
        .end_y = br_point.viewport.y,
        .is_rectangle = sel.rectangle,
    };
}

/// Extract the text content of the current selection.
/// Caller owns the returned memory and must free it with the same allocator.
/// Returns null if there is no selection.
pub fn getSelectionText(terminal: *Terminal, allocator: std.mem.Allocator) !?[:0]const u8 {
    const screen = terminal.screens.active;
    const sel = screen.selection orelse return null;

    return try screen.selectionString(allocator, .{
        .sel = sel,
        .trim = true,
    });
}

/// Set a selection from viewport coordinates.
/// Creates a tracked selection that will be updated as the screen changes.
pub fn setSelection(
    terminal: *Terminal,
    start_x: size.CellCountInt,
    start_y: u32,
    end_x: size.CellCountInt,
    end_y: u32,
    rectangle: bool,
) !void {
    const screen = terminal.screens.active;

    // Convert viewport coordinates to pins
    const start_pin = screen.pages.pin(.{ .viewport = .{
        .x = start_x,
        .y = start_y,
    } }) orelse return error.InvalidCoordinates;

    const end_pin = screen.pages.pin(.{ .viewport = .{
        .x = end_x,
        .y = end_y,
    } }) orelse return error.InvalidCoordinates;

    // Create an untracked selection, then set it (which will track it)
    const sel = Selection.init(start_pin, end_pin, rectangle);
    try screen.select(sel);
}

/// Clear the current selection.
pub fn clearSelection(terminal: *Terminal) void {
    terminal.screens.active.clearSelection();
}

/// Select all terminal content.
/// Returns true if content was selected, false if the terminal is empty.
pub fn selectAll(terminal: *Terminal) !bool {
    const screen = terminal.screens.active;
    const sel = screen.selectAll() orelse return false;
    try screen.select(sel);
    return true;
}

test "terminal can be created" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);
}

test "terminal can print text" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);

    try t.printString("Hello from dullahan!");

    const str = try t.plainString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "Hello from dullahan!") != null);
}

test "terminal wraps long lines" {
    var t = try init(std.testing.allocator, 10, 5);
    defer t.deinit(std.testing.allocator);

    try t.printString("This is a very long line that should wrap");

    const str = try t.plainString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    // The text should be wrapped since terminal is only 10 cols wide
    try std.testing.expect(str.len > 0);
}

// ============================================================================
// Selection API tests
// ============================================================================

test "hasSelection returns false initially" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);

    try std.testing.expect(!hasSelection(&t));
}

test "setSelection and getSelection roundtrip" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);

    // Write some text so we have content to select
    try t.printString("Hello World!");

    // Set a selection
    try setSelection(&t, 0, 0, 4, 0, false);

    // Verify selection exists
    try std.testing.expect(hasSelection(&t));

    // Get selection bounds
    const bounds = getSelection(&t);
    try std.testing.expect(bounds != null);
    try std.testing.expectEqual(@as(size.CellCountInt, 0), bounds.?.start_x);
    try std.testing.expectEqual(@as(u32, 0), bounds.?.start_y);
    try std.testing.expectEqual(@as(size.CellCountInt, 4), bounds.?.end_x);
    try std.testing.expectEqual(@as(u32, 0), bounds.?.end_y);
    try std.testing.expect(!bounds.?.is_rectangle);
}

test "getSelectionText returns correct text" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);

    // Write some text
    try t.printString("Hello World!");

    // Select "Hello"
    try setSelection(&t, 0, 0, 4, 0, false);

    // Get the selected text
    const text = try getSelectionText(&t, std.testing.allocator);
    try std.testing.expect(text != null);
    defer std.testing.allocator.free(text.?);

    try std.testing.expectEqualStrings("Hello", text.?);
}

test "clearSelection clears selection" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);

    try t.printString("Hello World!");

    // Set then clear selection
    try setSelection(&t, 0, 0, 4, 0, false);
    try std.testing.expect(hasSelection(&t));

    clearSelection(&t);
    try std.testing.expect(!hasSelection(&t));
    try std.testing.expect(getSelection(&t) == null);
}

test "selectAll selects entire content" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);

    try t.printString("Hello World!");

    // Select all
    const result = try selectAll(&t);
    try std.testing.expect(result);
    try std.testing.expect(hasSelection(&t));

    // Get the selected text
    const text = try getSelectionText(&t, std.testing.allocator);
    try std.testing.expect(text != null);
    defer std.testing.allocator.free(text.?);

    try std.testing.expectEqualStrings("Hello World!", text.?);
}

test "selectAll returns false on empty terminal" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);

    // Don't write anything - terminal is empty
    const result = try selectAll(&t);
    try std.testing.expect(!result);
    try std.testing.expect(!hasSelection(&t));
}

test "setSelection with rectangle mode" {
    var t = try init(std.testing.allocator, 80, 24);
    defer t.deinit(std.testing.allocator);

    try t.printString("AAABBB\n");
    try t.printString("CCCDDD\n");
    try t.printString("EEEFFF");

    // Set a rectangle selection
    try setSelection(&t, 0, 0, 2, 2, true);

    const bounds = getSelection(&t);
    try std.testing.expect(bounds != null);
    try std.testing.expect(bounds.?.is_rectangle);
}

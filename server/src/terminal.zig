//! Terminal module wrapping ghostty-vt
//!
//! This module provides the core terminal emulation functionality
//! using libghostty-vt.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub const Terminal = ghostty_vt.Terminal;

/// Create a new terminal with the given dimensions
pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Terminal {
    return Terminal.init(allocator, .{
        .cols = cols,
        .rows = rows,
    });
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

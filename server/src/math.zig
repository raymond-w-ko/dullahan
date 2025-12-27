/// Adds two integers together.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

// Tests live inline with the code — this is idiomatic Zig
// They're stripped from release builds (zero cost)

test "add positive numbers" {
    const result = add(2, 3);
    try std.testing.expectEqual(5, result);
}

test "add negative numbers" {
    try std.testing.expectEqual(-5, add(-2, -3));
}

test "add mixed signs" {
    try std.testing.expectEqual(0, add(-5, 5));
    try std.testing.expectEqual(-2, add(3, -5));
}

test "add with zero" {
    try std.testing.expectEqual(42, add(42, 0));
    try std.testing.expectEqual(42, add(0, 42));
}

const std = @import("std");

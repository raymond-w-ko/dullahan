const std = @import("std");
const dullahan = @import("dullahan");

pub fn main() !void {
    std.debug.print("dullahan server starting...\n", .{});

    // Example usage of the library
    const result = dullahan.math.add(2, 3);
    std.debug.print("2 + 3 = {}\n", .{result});
}

// Tests specific to main (CLI, arg parsing, etc.)
test "main module sanity check" {
    try std.testing.expect(true);
}

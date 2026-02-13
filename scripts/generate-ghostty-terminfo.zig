const std = @import("std");
const ghostty_terminfo = @import("ghostty_terminfo");

// Usage:
// zig run --dep ghostty_terminfo \
//   -Mroot=scripts/generate-ghostty-terminfo.zig \
//   -Mghostty_terminfo=deps/ghostty/src/terminfo/ghostty.zig \
//   > dist/ghostty.terminfo

pub fn main() !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout_writer.interface;
    try ghostty_terminfo.ghostty.encode(writer);
    try stdout_writer.end();
}

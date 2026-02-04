const std = @import("std");
const builtin = @import("builtin");
const dlog = @import("dlog.zig");

const log = dlog.scoped(.pane);

var cached_os_name_buf: [64]u8 = undefined;
var cached_os_name_len: usize = 0;
var cached_os_name_ready: bool = false;

/// Resolve and cache the OS name once at startup.
pub fn init() void {
    if (cached_os_name_ready) return;

    var temp: [128]u8 = undefined;
    var len: usize = 0;

    if (builtin.target.os.tag == .macos) {
        len = readCommandOutput(&temp, &.{ "sw_vers", "-productName" }) orelse 0;
    }
    if (len == 0) {
        len = readUnameSysname(&temp) orelse 0;
    }
    if (len == 0) {
        return;
    }

    if (len > cached_os_name_buf.len) {
        len = cached_os_name_buf.len;
    }
    std.mem.copyForwards(u8, cached_os_name_buf[0..len], temp[0..len]);
    cached_os_name_len = len;
    cached_os_name_ready = true;
}

pub fn get() ?[]const u8 {
    if (!cached_os_name_ready) {
        init();
    }
    if (!cached_os_name_ready) return null;
    return cached_os_name_buf[0..cached_os_name_len];
}

fn readUnameSysname(out: []u8) ?usize {
    const uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    if (sysname.len == 0) return null;
    const len = @min(sysname.len, out.len);
    std.mem.copyForwards(u8, out[0..len], sysname[0..len]);
    return len;
}

fn readCommandOutput(out: []u8, argv: []const []const u8) ?usize {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;
    const n = child.stdout.?.read(out) catch |e| {
        log.debug("Failed to read {s} stdout: {}", .{ argv[0], e });
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return null;
    };

    const term = child.wait() catch return null;
    if (term.Exited != 0) return null;

    var trimmed = std.mem.trim(u8, out[0..n], &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    // If trim removed leading whitespace, compact in-place.
    if (trimmed.ptr != out.ptr) {
        std.mem.copyForwards(u8, out[0..trimmed.len], trimmed);
        trimmed = out[0..trimmed.len];
    }
    return trimmed.len;
}

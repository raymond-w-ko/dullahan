//! Reusable diagnostics harness for parser and compatibility verification.
//!
//! Creates a scenario-scoped artifact directory under the shared temp dir and
//! records request/response JSONL events plus snapshots of shared server logs.

const std = @import("std");
const paths = @import("paths.zig");
const debug_config = @import("debug_config.zig");

pub const Options = struct {
    suite: []const u8 = "single-parser",
    scenario: []const u8,
};

pub const Harness = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    artifact_dir: []u8,
    events_path: []u8,
    metadata_path: []u8,
    events_file: std.Io.File,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Harness {
        try paths.ensureTempDir(io);

        const safe_suite = try sanitizePathComponent(allocator, opts.suite);
        defer allocator.free(safe_suite);
        const safe_scenario = try sanitizePathComponent(allocator, opts.scenario);
        defer allocator.free(safe_scenario);

        const ts_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const artifact_dir = try std.fmt.allocPrint(
            allocator,
            "{s}/diag-{s}-{s}-{d}",
            .{ paths.getTempDir(), safe_suite, safe_scenario, ts_ms },
        );
        errdefer allocator.free(artifact_dir);
        try std.Io.Dir.createDirAbsolute(io, artifact_dir, .default_dir);

        const events_path = try std.fmt.allocPrint(allocator, "{s}/events.jsonl", .{artifact_dir});
        errdefer allocator.free(events_path);
        const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{artifact_dir});
        errdefer allocator.free(metadata_path);

        const events_file = try std.Io.Dir.createFileAbsolute(io, events_path, .{ .truncate = true });
        errdefer events_file.close(io);

        var self = Harness{
            .io = io,
            .allocator = allocator,
            .artifact_dir = artifact_dir,
            .events_path = events_path,
            .metadata_path = metadata_path,
            .events_file = events_file,
        };
        try self.writeMetadata(opts);
        try self.recordNote("harness", "initialized");
        return self;
    }

    pub fn deinit(self: *Harness) void {
        self.events_file.close(self.io);
        self.allocator.free(self.metadata_path);
        self.allocator.free(self.events_path);
        self.allocator.free(self.artifact_dir);
    }

    pub fn artifactDir(self: *const Harness) []const u8 {
        return self.artifact_dir;
    }

    pub fn recordRequest(self: *Harness, label: []const u8, data: []const u8) !void {
        try self.recordBytes("request", label, data);
    }

    pub fn recordResponse(self: *Harness, label: []const u8, data: []const u8) !void {
        try self.recordBytes("response", label, data);
    }

    pub fn recordTrace(self: *Harness, label: []const u8, message: []const u8) !void {
        try self.writeEventLine("trace", label, message, null);
    }

    pub fn recordNote(self: *Harness, label: []const u8, message: []const u8) !void {
        try self.writeEventLine("note", label, message, null);
    }

    pub fn snapshotSharedLogs(self: *Harness) !void {
        try self.snapshotIfExists(paths.StaticPaths.log(), "server.log");
        try self.snapshotIfExists(paths.StaticPaths.ptyTraffic(), "pty-traffic.jsonl");
    }

    fn writeMetadata(self: *Harness, opts: Options) !void {
        const file = try std.Io.Dir.createFileAbsolute(self.io, self.metadata_path, .{ .truncate = true });
        defer file.close(self.io);

        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        const w = &writer;

        var debug_buf: [256]u8 = undefined;
        const debug_env = debug_config.getConfigString(&debug_buf);
        try w.print("{{\n  \"created_at_ms\": {d},\n  \"suite\": \"", .{std.Io.Timestamp.now(self.io, .real).toMilliseconds()});
        try writeHumanString(w, opts.suite);
        try w.writeAll("\",\n  \"scenario\": \"");
        try writeHumanString(w, opts.scenario);
        try w.writeAll("\",\n  \"artifact_dir\": \"");
        try writeHumanString(w, self.artifact_dir);
        try w.writeAll("\",\n  \"shared_server_log\": \"");
        try writeHumanString(w, paths.StaticPaths.log());
        try w.writeAll("\",\n  \"shared_pty_log\": \"");
        try writeHumanString(w, paths.StaticPaths.ptyTraffic());
        try w.writeAll("\",\n  \"debug_env\": \"");
        try writeHumanString(w, debug_env);
        try w.writeAll("\"\n}\n");
        try file.writeStreamingAll(self.io, w.buffered());
    }

    fn recordBytes(self: *Harness, kind: []const u8, label: []const u8, data: []const u8) !void {
        var buf: [8192]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        const w = &writer;

        try w.print("{{\"ts_ms\":{d},\"kind\":\"{s}\",\"label\":\"", .{ std.Io.Timestamp.now(self.io, .real).toMilliseconds(), kind });
        try writeHumanString(w, label);
        try w.print("\",\"len\":{d}", .{data.len});

        if (detectTerminator(data)) |terminator| {
            try w.print(",\"terminator\":\"{s}\"", .{terminator});
        }

        try w.writeAll(",\"bytes\":[");
        try writeBytesArray(w, data);
        try w.writeAll("],\"text\":\"");
        try writeHumanString(w, data);
        try w.writeAll("\"}\n");
        try self.events_file.writeStreamingAll(self.io, w.buffered());
    }

    fn writeEventLine(
        self: *Harness,
        kind: []const u8,
        label: []const u8,
        message: []const u8,
        extra: ?[]const u8,
    ) !void {
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        const w = &writer;

        try w.print("{{\"ts_ms\":{d},\"kind\":\"{s}\",\"label\":\"", .{ std.Io.Timestamp.now(self.io, .real).toMilliseconds(), kind });
        try writeHumanString(w, label);
        try w.writeAll("\",\"message\":\"");
        try writeHumanString(w, message);
        try w.writeAll("\"");
        if (extra) |v| {
            try w.print(",\"extra\":\"{s}\"", .{v});
        }
        try w.writeAll("}\n");
        try self.events_file.writeStreamingAll(self.io, w.buffered());
    }

    fn snapshotIfExists(self: *Harness, src_path: []const u8, dest_name: []const u8) !void {
        const src = std.Io.Dir.openFileAbsolute(self.io, src_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try self.recordTrace("snapshot-missing", src_path);
                return;
            },
            else => return err,
        };
        defer src.close(self.io);

        const dest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.artifact_dir, dest_name });
        defer self.allocator.free(dest_path);

        const dest = try std.Io.Dir.createFileAbsolute(self.io, dest_path, .{ .truncate = true });
        defer dest.close(self.io);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = src.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            try dest.writeStreamingAll(self.io, buf[0..n]);
        }
        try self.recordTrace("snapshot", dest_name);
    }
};

fn sanitizePathComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, value.len);
    for (value, 0..) |byte, idx| {
        out[idx] = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') byte else '-';
    }
    return out;
}

fn detectTerminator(data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    if (data[data.len - 1] == 0x07) return "bel";
    if (data.len >= 2 and data[data.len - 2] == 0x1b and data[data.len - 1] == '\\') return "st";
    return null;
}

fn writeBytesArray(w: *std.Io.Writer, data: []const u8) !void {
    for (data, 0..) |byte, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.print("\"0x{x:0>2}\"", .{byte});
    }
}

fn writeHumanString(w: *std.Io.Writer, data: []const u8) !void {
    for (data) |byte| {
        switch (byte) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (byte >= 32 and byte < 127) {
                    try w.writeByte(byte);
                } else {
                    try w.print("\\x{x:0>2}", .{byte});
                }
            },
        }
    }
}

test "diagnostics harness records request and response terminators" {
    paths.setPort(7791);
    defer paths.setPort(7681);

    var harness = try Harness.init(std.testing.io, std.testing.allocator, .{
        .suite = "single-parser",
        .scenario = "terminator-test",
    });
    const events_path = try std.testing.allocator.dupe(u8, harness.events_path);
    defer std.testing.allocator.free(events_path);
    defer harness.deinit();

    try harness.recordRequest("osc11-bel", "\x1b]11;?\x07");
    try harness.recordResponse("osc11-st", "\x1b]11;rgb:ffff/ffff/ffff\x1b\\");
    try harness.recordNote("done", "ok");
    harness.events_file.sync(std.testing.io) catch {};

    const contents = try readFileAllocAbsolute(std.testing.io, std.testing.allocator, events_path, 16 * 1024);
    defer std.testing.allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"terminator\":\"bel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"terminator\":\"st\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"label\":\"osc11-bel\"") != null);
}

test "diagnostics harness snapshots shared logs" {
    paths.setPort(7792);
    defer paths.setPort(7681);
    try paths.ensureTempDir(std.testing.io);

    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, paths.StaticPaths.log(), .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "server-log\n");
    }
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, paths.StaticPaths.ptyTraffic(), .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{\"event\":\"pty_io\"}\n");
    }

    var harness = try Harness.init(std.testing.io, std.testing.allocator, .{
        .suite = "single-parser",
        .scenario = "snapshot-test",
    });
    const artifact_dir = try std.testing.allocator.dupe(u8, harness.artifact_dir);
    defer std.testing.allocator.free(artifact_dir);
    defer harness.deinit();

    try harness.snapshotSharedLogs();

    const server_copy_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/server.log", .{artifact_dir});
    defer std.testing.allocator.free(server_copy_path);
    const pty_copy_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/pty-traffic.jsonl", .{artifact_dir});
    defer std.testing.allocator.free(pty_copy_path);

    const server_copy = try readFileAllocAbsolute(std.testing.io, std.testing.allocator, server_copy_path, 4096);
    defer std.testing.allocator.free(server_copy);
    const pty_copy = try readFileAllocAbsolute(std.testing.io, std.testing.allocator, pty_copy_path, 4096);
    defer std.testing.allocator.free(pty_copy);

    try std.testing.expectEqualStrings("server-log\n", server_copy);
    try std.testing.expectEqualStrings("{\"event\":\"pty_io\"}\n", pty_copy);
}

fn readFileAllocAbsolute(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

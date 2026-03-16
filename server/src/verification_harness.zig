//! Reusable diagnostics harness for single-parser verification runs.
//!
//! Creates a stable artifact directory under the dullahan temp dir, captures
//! request/response bytes for parser-routed exchanges, and snapshots the
//! relevant server/PTy logs so later e2e runners can reuse the same format.

const std = @import("std");
const builtin = @import("builtin");

const Pane = @import("pane.zig").Pane;
const Pty = @import("pty.zig").Pty;
const dlog = @import("dlog.zig");
const paths = @import("paths.zig");
const pty_log = @import("pty_log.zig");

pub const Options = struct {
    label: []const u8,
    debug_config: []const u8 = "+all,-delta",
};

const ClipboardSetSnapshot = struct {
    kind: u8,
    data: []const u8,
};

const NotificationSnapshot = struct {
    title: ?[]const u8 = null,
    body: []const u8,
};

const ProgressSnapshot = struct {
    state: u8,
    value: u8,
    changed: bool,
};

const PaneSnapshot = struct {
    title: ?[]const u8 = null,
    bell: bool = false,
    notification: ?NotificationSnapshot = null,
    progress: ?ProgressSnapshot = null,
    clipboard_set: ?ClipboardSetSnapshot = null,
    clipboard_get_kind: ?u8 = null,
    shell_event: ?[]const u8 = null,
    pwd: ?[]const u8 = null,
};

const CaptureRecord = struct {
    name: []const u8,
    request_file: []const u8,
    response_file: []const u8,
    request_len: usize,
    response_len: usize,
    request_hex: []const u8,
    response_hex: []const u8,
    request_text: []const u8,
    response_text: []const u8,
    request_terminator: []const u8,
    response_terminator: []const u8,
    pane_state: PaneSnapshot,
};

const Manifest = struct {
    version: u8,
    label: []const u8,
    artifact_dir: []const u8,
    debug_config: []const u8,
    server_log_file: []const u8,
    pty_traffic_file: []const u8,
    captures: []const CaptureRecord,
};

pub const Harness = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    debug_config: []u8,
    artifact_dir: []u8,
    manifest_path: []u8,
    server_log_artifact: []u8,
    pty_log_artifact: []u8,
    previous_debug_config: []u8,
    previous_pty_log_enabled: bool,
    server_log_offset: u64,
    pty_log_offset: u64,
    captures: std.ArrayListUnmanaged(CaptureRecord) = .{},
    capture_index: usize = 0,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Harness {
        dlog.init();
        try paths.ensureTempDir();

        var previous_config_buf: [256]u8 = undefined;
        const previous_config = dlog.getConfigString(&previous_config_buf);
        const previous_pty_log_enabled = pty_log.isEnabled();

        const server_log_offset = fileSizeOrZero(paths.StaticPaths.log());
        const pty_log_offset = if (previous_pty_log_enabled) fileSizeOrZero(pty_log.getLogPath()) else 0;

        const label_slug = try slugify(allocator, options.label);
        errdefer allocator.free(label_slug);

        const artifact_dir = try std.fmt.allocPrint(
            allocator,
            "{s}/verify-{s}-{d}",
            .{
                paths.getTempDir(),
                label_slug,
                std.time.milliTimestamp(),
            },
        );
        errdefer allocator.free(artifact_dir);
        try std.fs.makeDirAbsolute(artifact_dir);

        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{artifact_dir});
        errdefer allocator.free(manifest_path);
        const server_log_artifact = try std.fmt.allocPrint(allocator, "{s}/server.log", .{artifact_dir});
        errdefer allocator.free(server_log_artifact);
        const pty_log_artifact = try std.fmt.allocPrint(allocator, "{s}/pty-traffic.jsonl", .{artifact_dir});
        errdefer allocator.free(pty_log_artifact);

        const previous_debug_owned = try allocator.dupe(u8, previous_config);
        errdefer allocator.free(previous_debug_owned);
        const label_owned = try allocator.dupe(u8, options.label);
        errdefer allocator.free(label_owned);
        const debug_config_owned = try allocator.dupe(u8, options.debug_config);
        errdefer allocator.free(debug_config_owned);

        dlog.setConfig(options.debug_config);
        if (!previous_pty_log_enabled) {
            pty_log.setEnabled(true);
        }

        allocator.free(label_slug);

        return .{
            .allocator = allocator,
            .label = label_owned,
            .debug_config = debug_config_owned,
            .artifact_dir = artifact_dir,
            .manifest_path = manifest_path,
            .server_log_artifact = server_log_artifact,
            .pty_log_artifact = pty_log_artifact,
            .previous_debug_config = previous_debug_owned,
            .previous_pty_log_enabled = previous_pty_log_enabled,
            .server_log_offset = server_log_offset,
            .pty_log_offset = pty_log_offset,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.restoreLoggingState();
        for (self.captures.items) |capture| {
            freePaneSnapshot(self.allocator, &capture.pane_state);
            self.allocator.free(capture.name);
            self.allocator.free(capture.request_file);
            self.allocator.free(capture.response_file);
            self.allocator.free(capture.request_hex);
            self.allocator.free(capture.response_hex);
            self.allocator.free(capture.request_text);
            self.allocator.free(capture.response_text);
            self.allocator.free(capture.request_terminator);
            self.allocator.free(capture.response_terminator);
        }
        self.captures.deinit(self.allocator);
        self.allocator.free(self.label);
        self.allocator.free(self.debug_config);
        self.allocator.free(self.artifact_dir);
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.server_log_artifact);
        self.allocator.free(self.pty_log_artifact);
        self.allocator.free(self.previous_debug_config);
        self.* = undefined;
    }

    pub fn attachFakePty(self: *Harness, pane: *Pane) !void {
        _ = self;
        if (pane.pty != null) return error.AlreadyHasPty;
        const fds = try std.posix.pipe();
        errdefer {
            std.posix.close(fds[0]);
            std.posix.close(fds[1]);
        }
        try setNonBlocking(fds[0]);
        pane.pty = .{
            .master = fds[1],
            .slave = fds[0],
        };
    }

    pub fn captureFeed(self: *Harness, pane: *Pane, name: []const u8, request: []const u8) ![]u8 {
        const pty = &(pane.pty orelse return error.NoPtyAttached);
        self.capture_index += 1;

        const case_slug = try slugify(self.allocator, name);
        defer self.allocator.free(case_slug);

        const prefix = try std.fmt.allocPrint(self.allocator, "{s}/{d:0>2}-{s}", .{
            self.artifact_dir,
            self.capture_index,
            case_slug,
        });
        defer self.allocator.free(prefix);

        const request_file = try std.fmt.allocPrint(self.allocator, "{s}-request.bin", .{prefix});
        errdefer self.allocator.free(request_file);
        const response_file = try std.fmt.allocPrint(self.allocator, "{s}-response.bin", .{prefix});
        errdefer self.allocator.free(response_file);

        try writeFileAbsolute(request_file, request);
        try pane.feed(request);
        const response = try readAvailableFromFd(self.allocator, pty.slave, 25);
        errdefer self.allocator.free(response);
        try writeFileAbsolute(response_file, response);

        const snapshot = try snapshotPane(self.allocator, pane);
        errdefer freePaneSnapshot(self.allocator, &snapshot);

        try self.captures.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .request_file = request_file,
            .response_file = response_file,
            .request_len = request.len,
            .response_len = response.len,
            .request_hex = try allocHexString(self.allocator, request),
            .response_hex = try allocHexString(self.allocator, response),
            .request_text = try allocHumanString(self.allocator, request),
            .response_text = try allocHumanString(self.allocator, response),
            .request_terminator = try self.allocator.dupe(u8, detectTerminator(request)),
            .response_terminator = try self.allocator.dupe(u8, detectTerminator(response)),
            .pane_state = snapshot,
        });

        return response;
    }

    pub fn finish(self: *Harness) ![]const u8 {
        if (self.finished) return self.artifact_dir;
        defer self.restoreLoggingState();

        try copyFileTail(paths.StaticPaths.log(), self.server_log_offset, self.server_log_artifact);
        try copyFileTail(pty_log.getLogPath(), self.pty_log_offset, self.pty_log_artifact);
        try self.writeManifest();
        self.finished = true;
        return self.artifact_dir;
    }

    fn writeManifest(self: *Harness) !void {
        const manifest = Manifest{
            .version = 1,
            .label = self.label,
            .artifact_dir = self.artifact_dir,
            .debug_config = self.debug_config,
            .server_log_file = self.server_log_artifact,
            .pty_traffic_file = self.pty_log_artifact,
            .captures = self.captures.items,
        };

        const file = try std.fs.createFileAbsolute(self.manifest_path, .{ .truncate = true });
        defer file.close();
        const payload = try std.json.Stringify.valueAlloc(self.allocator, manifest, .{ .whitespace = .indent_2 });
        defer self.allocator.free(payload);
        try file.writeAll(payload);
        try file.writeAll("\n");
    }

    fn restoreLoggingState(self: *Harness) void {
        if (self.previous_debug_config.len > 0) {
            dlog.setConfig(self.previous_debug_config);
        } else {
            dlog.setConfig("");
        }
        if (!self.previous_pty_log_enabled and pty_log.isEnabled()) {
            pty_log.setEnabled(false);
        }
    }
};

fn snapshotPane(allocator: std.mem.Allocator, pane: *Pane) !PaneSnapshot {
    var snapshot: PaneSnapshot = .{
        .bell = pane.hasBell(),
        .clipboard_get_kind = pane.getClipboardGetKind(),
    };

    if (pane.getTitle()) |title| {
        snapshot.title = try allocator.dupe(u8, title);
    }

    if (pane.getNotification()) |notification| {
        snapshot.notification = .{
            .title = if (notification.title) |title| try allocator.dupe(u8, title) else null,
            .body = try allocator.dupe(u8, notification.body),
        };
    }

    const progress = pane.getProgress();
    if (pane.hasProgressChanged() or progress.state != 0 or progress.value != 0) {
        snapshot.progress = .{
            .state = progress.state,
            .value = progress.value,
            .changed = pane.hasProgressChanged(),
        };
    }

    if (pane.getClipboardSet()) |op| {
        snapshot.clipboard_set = .{
            .kind = op.kind,
            .data = try allocator.dupe(u8, op.data),
        };
    }

    if (pane.getShellEvent()) |event| {
        snapshot.shell_event = try allocator.dupe(u8, @tagName(event.kind));
    }

    if (pane.terminal.getPwd()) |pwd| {
        snapshot.pwd = try allocator.dupe(u8, pwd);
    }

    return snapshot;
}

fn freePaneSnapshot(allocator: std.mem.Allocator, snapshot: *const PaneSnapshot) void {
    if (snapshot.title) |title| allocator.free(title);
    if (snapshot.notification) |notification| {
        if (notification.title) |title| allocator.free(title);
        allocator.free(notification.body);
    }
    if (snapshot.clipboard_set) |set| allocator.free(set.data);
    if (snapshot.shell_event) |kind| allocator.free(kind);
    if (snapshot.pwd) |pwd| allocator.free(pwd);
}

fn slugify(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);

    var last_dash = false;
    for (label) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(allocator, std.ascii.toLower(ch));
            last_dash = false;
            continue;
        }
        if (!last_dash) {
            try out.append(allocator, '-');
            last_dash = true;
        }
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "capture");
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

fn setNonBlocking(fd: std.posix.fd_t) !void {
    const current = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    const o_nonblock: usize = if (builtin.os.tag == .macos) 0x4 else 0x800;
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, current | o_nonblock);
}

fn readAvailableFromFd(allocator: std.mem.Allocator, fd: std.posix.fd_t, timeout_ms: i32) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const ready = try std.posix.poll(&poll_fds, timeout_ms);
    if (ready == 0 or (poll_fds[0].revents & std.posix.POLL.IN) == 0) {
        return out.toOwnedSlice(allocator);
    }

    var buf: [512]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }

    return out.toOwnedSlice(allocator);
}

fn writeFileAbsolute(path: []const u8, bytes: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn copyFileTail(source_path: []const u8, start_offset: u64, dest_path: []const u8) !void {
    const dest = try std.fs.createFileAbsolute(dest_path, .{ .truncate = true });
    defer dest.close();

    const source = std.fs.openFileAbsolute(source_path, .{}) catch return;
    defer source.close();

    const stat = try source.stat();
    if (stat.size <= start_offset) return;

    try source.seekTo(start_offset);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try source.read(&buf);
        if (n == 0) break;
        try dest.writeAll(buf[0..n]);
    }
}

fn fileSizeOrZero(path: []const u8) u64 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();
    return (file.stat() catch return 0).size;
}

fn detectTerminator(bytes: []const u8) []const u8 {
    if (bytes.len == 0) return "none";
    if (bytes[bytes.len - 1] == 0x07) return "bel";
    if (bytes.len >= 2 and bytes[bytes.len - 2] == 0x1b and bytes[bytes.len - 1] == '\\') return "st";
    return "none";
}

fn allocHexString(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    for (bytes, 0..) |byte, idx| {
        if (idx != 0) try out.appendSlice(allocator, " ");
        try writer.print("{x:0>2}", .{byte});
    }
    return out.toOwnedSlice(allocator);
}

fn allocHumanString(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    for (bytes) |byte| {
        switch (byte) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (byte >= 32 and byte < 127) {
                    try out.append(allocator, byte);
                } else {
                    try writer.print("\\x{x:0>2}", .{byte});
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

test "capture harness records BEL and ST query responses" {
    var harness = try Harness.init(std.testing.allocator, .{
        .label = "unit-trace",
        .debug_config = "+all,-delta",
    });
    defer harness.deinit();

    var pane = try Pane.init(std.testing.allocator, .{ .cols = 40, .rows = 10, .id = 77 });
    defer pane.deinit();
    try harness.attachFakePty(&pane);

    const bel = try harness.captureFeed(&pane, "osc11-bel", "\x1b]11;?\x07");
    defer std.testing.allocator.free(bel);
    try std.testing.expect(std.mem.endsWith(u8, bel, "\x07"));

    const st = try harness.captureFeed(&pane, "osc11-st", "\x1b]11;?\x1b\\");
    defer std.testing.allocator.free(st);
    try std.testing.expect(std.mem.endsWith(u8, st, "\x1b\\"));

    _ = try harness.finish();
    try std.testing.expectEqual(@as(usize, 2), harness.captures.items.len);
}

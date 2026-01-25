//! IPC Command Handlers
//!
//! Individual handlers for each IPC command, extracted from event_loop.zig.
//! Each handler receives a Context with all the state it needs.

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");
const paths = @import("paths.zig");
const shell = @import("shell.zig");
const snapshot = @import("snapshot.zig");
const layout_db = @import("layout_db.zig");
const debug_config = @import("debug_config.zig");
const Session = @import("session.zig").Session;

const sys = @cImport({
    @cInclude("sys/ioctl.h");
});

const log = std.log.scoped(.ipc_commands);

/// Log a recoverable error with context
fn logRecoverable(comptime context: []const u8, err: anyerror) void {
    log.info("[recoverable] {s}: {any}", .{ context, err });
}

/// Client info for status display (minimal info, no connection state)
pub const ClientInfo = struct {
    client_id: ?[]const u8,
    is_master: bool,
};

/// Result of command dispatch - includes response and optional broadcast data
pub const DispatchResult = struct {
    response: ipc.Response,
    /// Optional binary data to broadcast to all clients (caller must free)
    broadcast_data: ?[]const u8 = null,
};

/// Context passed to all command handlers
pub const Context = struct {
    /// Allocator for building responses (arena, freed after response sent)
    alloc: std.mem.Allocator,

    /// Persistent allocator for storage that outlives the command
    persistent_alloc: std.mem.Allocator,

    /// Command arguments (optional)
    data: ?[]const u8,

    /// Server uptime in seconds
    uptime: i64,

    /// Number of commands processed
    commands_processed: u64,

    /// Server running flag (writable)
    running: *bool,

    /// Session state
    session: *Session,

    /// Layout database
    layouts: *layout_db.LayoutDb,

    /// Connected client count
    client_count: usize,

    /// Client info for status display
    clients: []const ClientInfo,

    /// Master client ID (if any)
    master_id: ?[]const u8,

    /// IPC clipboard storage (writable)
    ipc_clipboard_c: *?[]const u8,
    ipc_clipboard_p: *?[]const u8,
};

/// Dispatch a command to its handler
/// Returns a DispatchResult containing the response and optional broadcast data
pub fn dispatch(ctx: Context, command: ipc.Command) !DispatchResult {
    // Most commands just return a response with no broadcast
    const response: ipc.Response = switch (command) {
        .ping => handlePing(ctx),
        .status => try handleStatus(ctx),
        .quit => handleQuit(ctx),
        .help => try handleHelp(ctx),
        .shell => try handleShell(ctx),
        .dump => try handleDump(ctx),
        .@"dump-raw" => try handleDumpRaw(ctx),
        .@"debug-capture" => handleDebugCapture(ctx),
        .@"pty-log" => try handlePtyLog(ctx),
        .@"pty-log-on" => try handlePtyLogOn(ctx),
        .@"pty-log-off" => handlePtyLogOff(ctx),
        .ttysize => try handleTtySize(ctx),
        .layouts => try handleLayouts(ctx),
        .panes => try handlePanes(ctx),
        .windows => try handleWindows(ctx),
        .send => handleSend(ctx),
        // clipboard-set is special - returns broadcast data
        .@"clipboard-set" => return handleClipboardSet(ctx),
        .@"clipboard-get" => handleClipboardGet(ctx),
        .@"debug-log" => try handleDebugLog(ctx),
    };
    return .{ .response = response };
}

// ============================================================================
// Command Handlers
// ============================================================================

fn handlePing(_: Context) ipc.Response {
    return ipc.Response.ok("pong");
}

fn handleStatus(ctx: Context) !ipc.Response {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);

    const up = ctx.uptime;
    const hours = @divFloor(up, 3600);
    const mins = @divFloor(@mod(up, 3600), 60);
    const secs = @mod(up, 60);

    try writer.print("Uptime: {d}h {d}m {d}s\n", .{ hours, mins, secs });
    try writer.print("Commands processed: {d}\n", .{ctx.commands_processed});
    try writer.print("Running: {any}\n", .{ctx.running.*});
    try writer.print("Connected clients: {d}\n", .{ctx.client_count});

    // Show master status
    if (ctx.master_id) |master| {
        const short_master = if (master.len >= 8) master[0..8] else master;
        try writer.print("Master: {s}...\n", .{short_master});
    } else {
        try writer.writeAll("Master: (none)\n");
    }

    // List connected clients
    if (ctx.clients.len > 0) {
        try writer.writeAll("Clients:\n");
        for (ctx.clients, 0..) |client, i| {
            const master_marker: []const u8 = if (client.is_master) " [MASTER]" else "";
            if (client.client_id) |id| {
                try writer.print("  [{d}] {s}{s}\n", .{ i, id, master_marker });
            } else {
                try writer.print("  [{d}] (anonymous)\n", .{i});
            }
        }
    }

    const status_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("Server status", status_data);
}

fn handleQuit(ctx: Context) ipc.Response {
    ctx.running.* = false;
    return ipc.Response.ok("Shutting down");
}

fn handleHelp(ctx: Context) !ipc.Response {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);
    try writer.writeAll("Available commands:\n");
    inline for (std.meta.fields(ipc.Command)) |field| {
        const cmd: ipc.Command = @enumFromInt(field.value);
        try writer.print("  {s:<10} - {s}\n", .{ field.name, cmd.description() });
    }
    const result_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("Help", result_data);
}

fn handleShell(ctx: Context) !ipc.Response {
    const steps = try shell.getDetectionSteps(ctx.alloc);
    return ipc.Response.okWithData("Shell detection", steps);
}

fn handleDump(ctx: Context) !ipc.Response {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);

    try writer.print("Server: up={d}s cmds={d}\n", .{ ctx.uptime, ctx.commands_processed });
    try ctx.session.dump(writer);

    const result_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("State dump", result_data);
}

fn handleDumpRaw(ctx: Context) !ipc.Response {
    const pane = ctx.session.activePane() orelse
        return ipc.Response.err("No active pane");

    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);
    try pane.dumpRaw(writer);

    const result_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("Raw cell dump", result_data);
}

fn handleDebugCapture(ctx: Context) ipc.Response {
    const pane = ctx.session.activePane() orelse
        return ipc.Response.err("No active pane");

    const capture_path = paths.StaticPaths.capture();

    pane.startCapture(capture_path) catch |e| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "Failed to start capture: {any}", .{e}) catch "Failed to start capture";
        return ipc.Response.err(msg);
    };

    pane.writeInput("claude\n") catch |e| {
        logRecoverable("capture test input", e);
    };
    std.Thread.sleep(500 * std.time.ns_per_ms);
    pane.stopCapture();

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Sent 'claude\\n'. Run 'dump-raw' to see terminal state, check {s} for hex dump.", .{capture_path}) catch "Capture complete";
    return ipc.Response.okWithData("Capture started", msg);
}

fn handlePtyLog(ctx: Context) !ipc.Response {
    const enabled = ctx.session.isPtyLoggingEnabled();
    const path = ctx.session.getPtyLogPath();
    const msg = try std.fmt.allocPrint(ctx.alloc, "PTY logging: {s}\nLog file: {s}", .{
        if (enabled) "enabled" else "disabled",
        path,
    });
    return ipc.Response.okWithData(if (enabled) "PTY logging enabled" else "PTY logging disabled", msg);
}

fn handlePtyLogOn(ctx: Context) !ipc.Response {
    ctx.session.setPtyLogging(true);
    const path = ctx.session.getPtyLogPath();
    const msg = try std.fmt.allocPrint(ctx.alloc, "PTY traffic logging enabled.\nLog file: {s}", .{path});
    return ipc.Response.okWithData("PTY logging enabled", msg);
}

fn handlePtyLogOff(ctx: Context) ipc.Response {
    ctx.session.setPtyLogging(false);
    return ipc.Response.ok("PTY logging disabled");
}

fn handleTtySize(ctx: Context) !ipc.Response {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);

    // Query stdin (fd 0) for terminal size
    const TIOCGWINSZ: u32 = if (builtin.os.tag == .macos) 0x40087468 else 0x5413;
    var ws: extern struct {
        ws_row: u16 = 0,
        ws_col: u16 = 0,
        ws_xpixel: u16 = 0,
        ws_ypixel: u16 = 0,
    } = .{};

    if (sys.ioctl(0, TIOCGWINSZ, @intFromPtr(&ws)) < 0) {
        // Try stdout if stdin doesn't work
        if (sys.ioctl(1, TIOCGWINSZ, @intFromPtr(&ws)) < 0) {
            return ipc.Response.err("ioctl TIOCGWINSZ failed (not a tty?)");
        }
    }

    try writer.print("Server console size (ioctl):\n", .{});
    try writer.print("  cols: {d}\n", .{ws.ws_col});
    try writer.print("  rows: {d}\n", .{ws.ws_row});
    try writer.print("  xpixel: {d}\n", .{ws.ws_xpixel});
    try writer.print("  ypixel: {d}\n", .{ws.ws_ypixel});

    // Also show pane sizes from registry
    try writer.print("\nVirtual terminal pane sizes:\n", .{});
    var it = ctx.session.pane_registry.iterator();
    while (it.next()) |pane_ptr| {
        const pane = pane_ptr.*;
        try writer.print("  pane {d}: {d}x{d}\n", .{ pane.id, pane.cols, pane.rows });
    }

    const result_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("Server console size", result_data);
}

fn handleLayouts(ctx: Context) !ipc.Response {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);

    // Write JSON array of layout templates
    try writer.writeAll("[\n");
    const templates = ctx.layouts.getAll();
    for (templates, 0..) |template, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.print("  {{ \"id\": \"{s}\", \"name\": \"{s}\", \"panes\": {d} }}", .{
            template.id,
            template.name,
            template.countPanes(),
        });
    }
    try writer.writeAll("\n]");

    const json_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("Available layouts", json_data);
}

fn handlePanes(ctx: Context) !ipc.Response {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);

    // List all pane IDs from registry
    var pane_it = ctx.session.pane_registry.iterator();
    var first = true;
    while (pane_it.next()) |pane_ptr| {
        const pane = pane_ptr.*;
        if (!first) try writer.writeAll(" ");
        try writer.print("{d}", .{pane.id});
        first = false;
    }
    if (first) {
        try writer.writeAll("(no panes)");
    }

    const result_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("Pane IDs", result_data);
}

fn handleWindows(ctx: Context) !ipc.Response {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);

    // JSON array of windows with pane IDs
    try writer.writeAll("[\n");
    var win_it = ctx.session.windows.iterator();
    var first_win = true;
    while (win_it.next()) |entry| {
        if (!first_win) try writer.writeAll(",\n");
        first_win = false;

        const window = entry.value_ptr;
        try writer.print("  {{ \"id\": {d}, \"panes\": [", .{window.id});

        for (window.pane_ids.items, 0..) |pane_id, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{d}", .{pane_id});
        }
        try writer.writeAll("]");

        // Include template if set
        if (window.template_id) |template| {
            try writer.print(", \"template\": \"{s}\"", .{template});
        }
        try writer.writeAll(" }");
    }
    try writer.writeAll("\n]");

    const result_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("Windows", result_data);
}

fn handleSend(ctx: Context) ipc.Response {
    const args = ctx.data orelse
        return ipc.Response.err("Usage: send <pane_id> [text]\nReads from stdin if no text provided");

    // Parse pane ID from first argument
    const space_idx = std.mem.indexOf(u8, args, " ");
    const pane_id_str = if (space_idx) |idx| args[0..idx] else args;
    const text = if (space_idx) |idx| std.mem.trim(u8, args[idx + 1 ..], &std.ascii.whitespace) else null;

    const pane_id = std.fmt.parseInt(u16, pane_id_str, 10) catch
        return ipc.Response.err("Invalid pane ID. Usage: send <pane_id> [text]");

    const pane = ctx.session.pane_registry.get(pane_id) orelse
        return ipc.Response.err("Pane not found");

    // If no text provided, that's handled by CLI reading stdin
    const send_text = text orelse
        return ipc.Response.err("No text provided. Use stdin: echo 'text' | dullahan send <pane_id>");

    if (send_text.len == 0)
        return ipc.Response.err("Empty text. Use stdin: echo 'text' | dullahan send <pane_id>");

    pane.writeInput(send_text) catch |e| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "Failed to send: {any}", .{e}) catch "Failed to send";
        return ipc.Response.err(msg);
    };

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Sent {d} bytes to pane {d}", .{ send_text.len, pane.id }) catch "Sent";
    return ipc.Response.ok(msg);
}

fn handleClipboardSet(ctx: Context) DispatchResult {
    const args = ctx.data orelse
        return .{ .response = ipc.Response.err("Usage: clipboard-set <c|p> <text>") };

    // Parse kind (c or p) from first argument
    const space_idx = std.mem.indexOf(u8, args, " ");
    const kind_str = if (space_idx) |idx| args[0..idx] else args;
    const text = if (space_idx) |idx| args[idx + 1 ..] else null;

    if (kind_str.len != 1 or (kind_str[0] != 'c' and kind_str[0] != 'p'))
        return .{ .response = ipc.Response.err("Invalid kind. Use 'c' (clipboard) or 'p' (primary)") };

    const kind = kind_str[0];
    const clipboard_text = text orelse
        return .{ .response = ipc.Response.err("No text provided. Usage: clipboard-set <c|p> <text>") };

    // Store locally for clipboard-get (use persistent allocator for storage)
    const text_copy = ctx.persistent_alloc.dupe(u8, clipboard_text) catch
        return .{ .response = ipc.Response.err("Out of memory") };

    if (kind == 'c') {
        if (ctx.ipc_clipboard_c.*) |old| {
            ctx.persistent_alloc.free(old);
        }
        ctx.ipc_clipboard_c.* = text_copy;
    } else {
        if (ctx.ipc_clipboard_p.*) |old| {
            ctx.persistent_alloc.free(old);
        }
        ctx.ipc_clipboard_p.* = text_copy;
    }

    // Encode text as base64 for the clipboard message
    const encoded_len = std.base64.standard.Encoder.calcSize(clipboard_text.len);
    const base64_data = ctx.alloc.alloc(u8, encoded_len) catch
        return .{ .response = ipc.Response.err("Out of memory for base64") };
    defer ctx.alloc.free(base64_data);
    _ = std.base64.standard.Encoder.encode(base64_data, clipboard_text);

    // Generate clipboard SET message - caller will broadcast
    // Use pane ID 0 (debug pane) as a placeholder
    const clipboard_msg = snapshot.generateClipboardMessage(
        ctx.alloc,
        0, // pane_id (not important for SET broadcast)
        "set",
        kind,
        base64_data,
    ) catch return .{ .response = ipc.Response.err("Failed to generate clipboard message") };
    // Note: don't defer free - caller owns broadcast_data

    var resp_buf: [128]u8 = undefined;
    const resp_msg = std.fmt.bufPrint(&resp_buf, "Set '{c}' clipboard: {d} bytes, broadcast to {d} clients", .{
        kind,
        clipboard_text.len,
        ctx.client_count,
    }) catch "Set clipboard";

    return .{
        .response = ipc.Response.ok(resp_msg),
        .broadcast_data = clipboard_msg,
    };
}

fn handleClipboardGet(ctx: Context) ipc.Response {
    const args = ctx.data orelse
        return ipc.Response.err("Usage: clipboard-get <c|p>");

    const kind_str = std.mem.trim(u8, args, &std.ascii.whitespace);
    if (kind_str.len != 1 or (kind_str[0] != 'c' and kind_str[0] != 'p'))
        return ipc.Response.err("Invalid kind. Use 'c' (clipboard) or 'p' (primary)");

    const kind = kind_str[0];
    const stored = if (kind == 'c') ctx.ipc_clipboard_c.* else ctx.ipc_clipboard_p.*;

    if (stored) |stored_text| {
        return ipc.Response.okWithData("Clipboard content", stored_text);
    } else {
        return ipc.Response.ok("(empty)");
    }
}

fn handleDebugLog(ctx: Context) !ipc.Response {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(ctx.alloc);

    const args = ctx.data orelse {
        // No args - show current config
        var config_buf: [256]u8 = undefined;
        const current = debug_config.getConfigString(&config_buf);
        try writer.print("Current debug config: {s}\n\n", .{current});
        try writer.writeAll("Categories:\n");
        for (debug_config.ALL_CATEGORIES) |cat| {
            const enabled = debug_config.isEnabled(cat);
            try writer.print("  {s:<12} {s}\n", .{ cat.asText(), if (enabled) "[ON]" else "[off]" });
        }
        try writer.writeAll("\nUsage:\n");
        try writer.writeAll("  debug-log +all           Enable all categories\n");
        try writer.writeAll("  debug-log +all,-delta    All except delta\n");
        try writer.writeAll("  debug-log +clipboard     Enable only clipboard\n");
        try writer.writeAll("  debug-log off            Disable all logging\n");
        try writer.writeAll("  debug-log list           List all categories\n");
        const result_data = try buf.toOwnedSlice(ctx.alloc);
        return ipc.Response.okWithData("Debug logging status", result_data);
    };

    const trimmed = std.mem.trim(u8, args, &std.ascii.whitespace);

    // Handle special commands
    if (std.mem.eql(u8, trimmed, "off") or std.mem.eql(u8, trimmed, "false")) {
        debug_config.setConfigString("");
        return ipc.Response.ok("Debug logging disabled");
    }

    if (std.mem.eql(u8, trimmed, "list")) {
        try writer.writeAll("Available debug categories:\n");
        for (debug_config.ALL_CATEGORIES) |cat| {
            try writer.print("  {s}\n", .{cat.asText()});
        }
        const result_data = try buf.toOwnedSlice(ctx.alloc);
        return ipc.Response.okWithData("Debug categories", result_data);
    }

    if (std.mem.eql(u8, trimmed, "on") or std.mem.eql(u8, trimmed, "true")) {
        debug_config.setConfigString("+all");
        return ipc.Response.ok("Debug logging enabled: +all");
    }

    // Parse as config string
    debug_config.setConfigString(trimmed);

    var config_buf: [256]u8 = undefined;
    const current = debug_config.getConfigString(&config_buf);
    try writer.print("Debug config set: {s}\n\n", .{current});
    try writer.writeAll("Enabled categories:\n");
    var any_enabled = false;
    for (debug_config.ALL_CATEGORIES) |cat| {
        if (debug_config.isEnabled(cat)) {
            try writer.print("  {s}\n", .{cat.asText()});
            any_enabled = true;
        }
    }
    if (!any_enabled) {
        try writer.writeAll("  (none)\n");
    }

    const result_data = try buf.toOwnedSlice(ctx.alloc);
    return ipc.Response.okWithData("Debug config updated", result_data);
}

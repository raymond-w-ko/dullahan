//! Single-threaded event loop for dullahan server
//!
//! Multiplexes IPC, HTTP/WebSocket, and PTY I/O in one poll() loop.
//! Eliminates all threading and synchronization complexity.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const msgpack = @import("msgpack");

const sys = @cImport({
    @cInclude("sys/ioctl.h");
});
const constants = @import("constants.zig");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const paths = @import("paths.zig");
const shell = @import("shell.zig");
const websocket = @import("websocket.zig");
const snapshot = @import("snapshot.zig");
const layout_db = @import("layout_db.zig");
const Session = @import("session.zig").Session;
const Window = @import("window.zig").Window;
const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const MouseEvents = pane_mod.MouseEvents;
const MouseFormat = pane_mod.MouseFormat;
const signal = @import("signal.zig");
const mouse = @import("mouse.zig");

const log = std.log.scoped(.event_loop);

// ============================================================================
// Error Handling Helpers
// ============================================================================
//
// Standardized error handling to ensure consistent logging and behavior.
// Categories:
//   - fatal: Server should exit (e.g., failed to start IPC)
//   - client: Log and potentially disconnect client
//   - recoverable: Log at info/debug level and continue
//   - silent: Truly ignorable (e.g., failed to send close frame)

/// Log a recoverable error with context. Server continues operation.
fn logRecoverable(comptime context: []const u8, err: anyerror) void {
    log.info("[recoverable] {s}: {any}", .{ context, err });
}

/// Log a client-related error. May result in client disconnect.
fn logClientError(comptime context: []const u8, err: anyerror) void {
    log.warn("[client] {s}: {any}", .{ context, err });
}

/// Log and handle a fatal error. Server should exit after this.
fn logFatal(comptime context: []const u8, err: anyerror) noreturn {
    log.err("[FATAL] {s}: {any}", .{ context, err });
    std.process.exit(1);
}

// ============================================================================
// Message Types (for parsing client messages)
// ============================================================================

const KeyEvent = struct {
    type: []const u8,
    key: []const u8,
    code: []const u8,
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    repeat: bool = false,
    timestamp: f64 = 0,
    keyCode: u16 = 0,
};

const TextMessage = struct {
    type: []const u8,
    data: []const u8,
};

const ResizeMessage = struct {
    type: []const u8,
    cols: u16,
    rows: u16,
};

const ScrollMessage = struct {
    type: []const u8,
    delta: i32,
};

const SyncMessage = struct {
    type: []const u8,
    gen: u64,
    minRowId: u64,
};

const FocusMessage = struct {
    type: []const u8,
    paneId: u16,
};

const MouseMessage = struct {
    type: []const u8,
    paneId: u16,
    button: u8,
    x: u16,
    y: u16,
    px: ?u32 = null, // Pixel X coordinate (for SGR-Pixels mode 1016)
    py: ?u32 = null, // Pixel Y coordinate (for SGR-Pixels mode 1016)
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    timestamp: f64 = 0,
};

const HelloMessage = struct {
    type: []const u8,
    clientId: []const u8,
};

const NewWindowMessage = struct {
    type: []const u8,
    templateId: ?[]const u8 = null,
};

const CloseWindowMessage = struct {
    type: []const u8,
    windowId: u16,
};

const ClipboardResponseMessage = struct {
    type: []const u8,
    paneId: u16,
    clipboard: []const u8,
    data: []const u8,
};

const MessageType = struct {
    type: []const u8,
};

// ============================================================================
// Parsed Message Union (protocol-agnostic)
// ============================================================================

/// Unified message representation for both JSON and msgpack protocols.
/// Borrows string data from the underlying protocol payload.
const ParsedMessage = union(enum) {
    key: ParsedKeyEvent,
    text: ParsedText,
    resize: ParsedResize,
    scroll: ParsedScroll,
    ping: void,
    sync: ParsedSync,
    focus: ParsedFocus,
    hello: ParsedHello,
    request_master: void,
    new_window: ParsedNewWindow,
    close_window: ParsedCloseWindow,
    mouse: ParsedMouse,
    select_all: ParsedSelectAll,
    clear_selection: ParsedClearSelection,
    clipboard_response: ParsedClipboardResponse,
    unknown: void,
};

const ParsedKeyEvent = struct {
    key: []const u8,
    code: []const u8 = "",
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    repeat: bool = false,
    timestamp: f64 = 0,
    keyCode: u16 = 0,
};

const ParsedText = struct {
    data: []const u8,
};

const ParsedResize = struct {
    cols: u16,
    rows: u16,
};

const ParsedScroll = struct {
    delta: i32,
};

const ParsedSync = struct {
    gen: u64,
    minRowId: u64 = 0,
};

const ParsedFocus = struct {
    paneId: u16,
};

const ParsedHello = struct {
    clientId: []const u8,
};

const ParsedNewWindow = struct {
    templateId: ?[]const u8 = null,
};

const ParsedCloseWindow = struct {
    windowId: u16,
};

const ParsedMouse = struct {
    paneId: u16,
    button: u8,
    x: u16,
    y: u16,
    px: ?u32 = null,
    py: ?u32 = null,
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    timestamp: f64 = 0,
};

const ParsedSelectAll = struct {
    paneId: u16,
};

const ParsedClearSelection = struct {
    paneId: u16,
};

const ParsedClipboardResponse = struct {
    paneId: u16,
    clipboard: []const u8,
    data: []const u8,
};

/// Cleanup helper for JSON parsed messages.
/// Holds references to parsed JSON that need to be freed after message handling.
const JsonCleanup = union(enum) {
    none: void,
    json_key: std.json.Parsed(KeyEvent),
    json_text: std.json.Parsed(TextMessage),
    json_hello: std.json.Parsed(HelloMessage),
    json_new_window: std.json.Parsed(NewWindowMessage),
    json_mouse: std.json.Parsed(MouseMessage),
    json_clipboard_response: std.json.Parsed(ClipboardResponseMessage),

    pub fn deinit(self: *JsonCleanup) void {
        switch (self.*) {
            .none => {},
            .json_key => |*p| p.deinit(),
            .json_text => |*p| p.deinit(),
            .json_hello => |*p| p.deinit(),
            .json_new_window => |*p| p.deinit(),
            .json_mouse => |*p| p.deinit(),
            .json_clipboard_response => |*p| p.deinit(),
        }
    }
};

// ============================================================================
// Client State
// ============================================================================

pub const ClientState = struct {
    ws: websocket.Connection,
    pane_generations: std.AutoHashMap(u16, u64),
    connected: bool = true,
    allocator: std.mem.Allocator,

    /// Client's unique ID (set when client sends "hello" message)
    /// UUIDv4 format, e.g. "550e8400-e29b-41d4-a716-446655440000"
    client_id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, ws: websocket.Connection) ClientState {
        return .{
            .ws = ws,
            .pane_generations = std.AutoHashMap(u16, u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClientState) void {
        // Free client ID if allocated
        if (self.client_id) |id| {
            self.allocator.free(id);
        }
        self.pane_generations.deinit();
        self.ws.close();
        self.connected = false;
    }

    /// Set the client ID (called when "hello" message is received)
    pub fn setClientId(self: *ClientState, id: []const u8) !void {
        // Free old ID if any
        if (self.client_id) |old_id| {
            self.allocator.free(old_id);
        }
        // Allocate and copy new ID
        self.client_id = try self.allocator.dupe(u8, id);
    }

    /// Get short client ID for logging (first 8 chars or "anonymous")
    pub fn shortId(self: *const ClientState) []const u8 {
        if (self.client_id) |id| {
            return if (id.len >= 8) id[0..8] else id;
        }
        return "anon";
    }

    pub fn getGeneration(self: *ClientState, pane_id: u16) u64 {
        return self.pane_generations.get(pane_id) orelse 0;
    }

    pub fn setGeneration(self: *ClientState, pane_id: u16, gen: u64) void {
        self.pane_generations.put(pane_id, gen) catch |e| {
            logRecoverable("pane generation tracking", e);
        };
    }
};

// ============================================================================
// Event Loop
// ============================================================================

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    ipc_server: *ipc.Server,
    http_server: *http.Server,
    session: *Session,
    clients: std.ArrayListUnmanaged(ClientState) = .{},
    running: bool = true,

    // Server state for IPC commands
    start_time: i64,
    commands_processed: u64 = 0,

    // Master/slave state: only one client can be master at a time
    // Master client can perform privileged operations (resize, create panes, etc.)
    master_id: ?[]const u8 = null,

    // Layout database (templates for window creation)
    layouts: layout_db.LayoutDb,

    const IPC_FD_INDEX = 0;
    const HTTP_FD_INDEX = 1;
    const FIXED_FD_COUNT = 2;

    pub fn init(
        allocator: std.mem.Allocator,
        ipc_server: *ipc.Server,
        http_server: *http.Server,
        session: *Session,
    ) EventLoop {
        var layouts = layout_db.LayoutDb.init(allocator);
        layouts.load() catch |e| {
            logRecoverable("load layouts", e);
        };

        return .{
            .allocator = allocator,
            .ipc_server = ipc_server,
            .http_server = http_server,
            .session = session,
            .start_time = std.time.timestamp(),
            .layouts = layouts,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        for (self.clients.items) |*client| {
            client.deinit();
        }
        self.clients.deinit(self.allocator);
        // Free master_id if allocated
        if (self.master_id) |id| {
            self.allocator.free(id);
        }
        self.layouts.deinit();
    }

    pub fn uptime(self: *const EventLoop) i64 {
        return std.time.timestamp() - self.start_time;
    }

    /// Assign layouts to existing windows that don't have layouts yet.
    /// Called after init to set up layouts for windows created before EventLoop.
    pub fn assignLayoutsToExistingWindows(self: *EventLoop) void {
        var it = self.session.windows.iterator();
        while (it.next()) |entry| {
            var window = entry.value_ptr;

            // Skip windows that already have layouts
            if (window.template_id != null) continue;

            // Choose template based on pane count
            const pane_count = window.paneCount();
            const template_id: []const u8 = switch (pane_count) {
                1 => "single",
                2 => "2-col",
                3 => "3-col",
                4 => "2x2",
                else => "single", // Fallback
            };

            if (self.layouts.get(template_id)) |template| {
                window.setLayoutFromTemplate(template) catch |e| {
                    log.warn("Failed to set layout for window {d}: {}", .{ window.id, e });
                };
            }
        }
    }

    /// Main event loop
    pub fn run(self: *EventLoop) !void {
        log.info("Event loop starting (single-threaded)", .{});

        while (self.running and !signal.isShutdownRequested()) {
            const poll_fds = try self.buildPollSet();
            defer self.allocator.free(poll_fds);

            const ready = posix.poll(poll_fds, 100) catch |e| {
                log.err("poll error: {any}", .{e});
                continue;
            };

            if (ready == 0) continue;

            try self.dispatchEvents(poll_fds);
        }

        log.info("Event loop stopped", .{});
    }

    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    fn buildPollSet(self: *EventLoop) ![]posix.pollfd {
        // Count PTYs via pane registry
        var pty_count: usize = 0;
        var count_it = self.session.pane_registry.iterator();
        while (count_it.next()) |pane_ptr| {
            if (pane_ptr.*.getPtyFd() != null) {
                pty_count += 1;
            }
        }

        const total = FIXED_FD_COUNT + self.clients.items.len + pty_count;
        var fds = try self.allocator.alloc(posix.pollfd, total);

        fds[IPC_FD_INDEX] = .{ .fd = self.ipc_server.socket, .events = posix.POLL.IN, .revents = 0 };
        fds[HTTP_FD_INDEX] = .{ .fd = self.http_server.getFd(), .events = posix.POLL.IN, .revents = 0 };

        var idx: usize = FIXED_FD_COUNT;
        for (self.clients.items) |client| {
            fds[idx] = .{ .fd = client.ws.getFd(), .events = posix.POLL.IN, .revents = 0 };
            idx += 1;
        }

        // Add PTY fds via pane registry
        var pane_it = self.session.pane_registry.iterator();
        while (pane_it.next()) |pane_ptr| {
            if (pane_ptr.*.getPtyFd()) |fd| {
                fds[idx] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
                idx += 1;
            }
        }

        return fds;
    }

    fn dispatchEvents(self: *EventLoop, fds: []posix.pollfd) !void {
        // IMPORTANT: Save the client count that was used when building the poll set.
        // This count must be used for PTY index calculation even if clients are
        // removed during dispatch, because fds indices are fixed at poll time.
        const poll_client_count = self.clients.items.len;

        // Check IPC
        if (fds[IPC_FD_INDEX].revents & posix.POLL.IN != 0) {
            self.handleIpc() catch |e| {
                log.err("IPC error: {any}", .{e});
            };
        }

        // Check HTTP accept
        if (fds[HTTP_FD_INDEX].revents & posix.POLL.IN != 0) {
            self.handleHttpAccept() catch |e| {
                log.err("HTTP accept error: {any}", .{e});
            };
        }

        // Check clients (iterate backwards to allow removal)
        var client_idx: usize = poll_client_count;
        while (client_idx > 0) {
            client_idx -= 1;
            const fd_idx = FIXED_FD_COUNT + client_idx;
            const revents = fds[fd_idx].revents;

            if (revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                log.info("Client {d} disconnected (poll error/hangup)", .{client_idx});
                self.removeClient(client_idx);
            } else if (revents & posix.POLL.IN != 0) {
                self.handleWsClient(client_idx) catch |e| {
                    if (e == error.ConnectionClosed) {
                        log.info("Client {d} disconnected", .{client_idx});
                        self.removeClient(client_idx);
                    } else if (e == error.WouldBlock) {
                        // Timeout on partial frame - just continue, don't remove client
                        log.debug("Client {d} read timeout (partial frame?)", .{client_idx});
                    } else {
                        log.err("Client {d} error: {any}", .{ client_idx, e });
                        self.removeClient(client_idx);
                    }
                };
            }
        }

        // Check PTYs - use poll_client_count (not current clients.items.len)
        // because fds array was built with that count
        const pty_start_idx = FIXED_FD_COUNT + poll_client_count;
        var pty_idx: usize = 0;
        var pane_it = self.session.pane_registry.iterator();
        while (pane_it.next()) |pane_ptr| {
            const pane = pane_ptr.*;
            if (pane.getPtyFd() != null) {
                const fd_idx = pty_start_idx + pty_idx;
                if (fd_idx < fds.len) {
                    const revents = fds[fd_idx].revents;

                    if (revents & posix.POLL.IN != 0) {
                        self.handlePtyData(pane) catch |e| {
                            log.err("PTY read error for pane {d}: {any}", .{ pane.id, e });
                        };
                    }

                    if (revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                        log.info("PTY hangup/error for pane {d}", .{pane.id});
                        _ = pane.isAlive();
                    }
                }
                pty_idx += 1;
            }
        }
    }

    fn handleIpc(self: *EventLoop) !void {
        const result = self.ipc_server.acceptCommandTimeout(self.allocator, 0) catch |e| switch (e) {
            error.UnknownCommand => return,
            else => return e,
        };

        if (result) |cmd_result| {
            self.commands_processed += 1;

            // Use arena allocator per-request to avoid leaking response data
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            const response = self.handleCommand(cmd_result.parsed.command, cmd_result.parsed.data, arena_alloc) catch |e| blk: {
                log.err("Command error: {any}", .{e});
                break :blk ipc.Response.err("Internal error");
            };

            self.ipc_server.sendResponse(cmd_result.conn, response, arena_alloc) catch |e| {
                log.err("Send error: {any}", .{e});
            };
        }
    }

    fn handleCommand(self: *EventLoop, command: ipc.Command, data: ?[]const u8, alloc: std.mem.Allocator) !ipc.Response {
        return switch (command) {
            .ping => ipc.Response.ok("pong"),

            .status => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);

                const up = self.uptime();
                const hours = @divFloor(up, 3600);
                const mins = @divFloor(@mod(up, 3600), 60);
                const secs = @mod(up, 60);

                try writer.print("Uptime: {d}h {d}m {d}s\n", .{ hours, mins, secs });
                try writer.print("Commands processed: {d}\n", .{self.commands_processed});
                try writer.print("Running: {any}\n", .{self.running});
                try writer.print("Connected clients: {d}\n", .{self.clients.items.len});

                // Show master status
                if (self.master_id) |master| {
                    const short_master = if (master.len >= 8) master[0..8] else master;
                    try writer.print("Master: {s}...\n", .{short_master});
                } else {
                    try writer.writeAll("Master: (none)\n");
                }

                // List connected clients
                if (self.clients.items.len > 0) {
                    try writer.writeAll("Clients:\n");
                    for (self.clients.items, 0..) |*client, i| {
                        const is_master = if (client.client_id) |id| self.isMaster(id) else false;
                        const master_marker: []const u8 = if (is_master) " [MASTER]" else "";
                        if (client.client_id) |id| {
                            try writer.print("  [{d}] {s}{s}\n", .{ i, id, master_marker });
                        } else {
                            try writer.print("  [{d}] (anonymous)\n", .{i});
                        }
                    }
                }

                const status_data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Server status", status_data);
            },

            .quit => blk: {
                self.running = false;
                break :blk ipc.Response.ok("Shutting down");
            },

            .help => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);
                try writer.writeAll("Available commands:\n");
                inline for (std.meta.fields(ipc.Command)) |field| {
                    const cmd: ipc.Command = @enumFromInt(field.value);
                    try writer.print("  {s:<10} - {s}\n", .{ field.name, cmd.description() });
                }
                const result_data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Help", result_data);
            },

            .shell => blk: {
                const steps = try shell.getDetectionSteps(alloc);
                break :blk ipc.Response.okWithData("Shell detection", steps);
            },

            .dump => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);

                const up = self.uptime();
                try writer.print("Server: up={d}s cmds={d}\n", .{ up, self.commands_processed });
                try self.session.dump(writer);

                const result_data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("State dump", result_data);
            },

            .@"dump-raw" => blk: {
                const pane = self.session.activePane() orelse
                    break :blk ipc.Response.err("No active pane");

                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);
                try pane.dumpRaw(writer);

                const result_data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Raw cell dump", result_data);
            },

            .@"debug-capture" => blk: {
                const pane = self.session.activePane() orelse
                    break :blk ipc.Response.err("No active pane");

                const capture_path = paths.StaticPaths.capture();

                pane.startCapture(capture_path) catch |e| {
                    var errbuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&errbuf, "Failed to start capture: {any}", .{e}) catch "Failed to start capture";
                    break :blk ipc.Response.err(msg);
                };

                pane.writeInput("claude\n") catch |e| {
                    logRecoverable("capture test input", e);
                };
                std.Thread.sleep(500 * std.time.ns_per_ms);
                pane.stopCapture();

                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Sent 'claude\\n'. Run 'dump-raw' to see terminal state, check {s} for hex dump.", .{capture_path}) catch "Capture complete";
                break :blk ipc.Response.okWithData("Capture started", msg);
            },

            .@"pty-log" => blk: {
                const enabled = self.session.isPtyLoggingEnabled();
                const path = self.session.getPtyLogPath();
                const msg = try std.fmt.allocPrint(alloc, "PTY logging: {s}\nLog file: {s}", .{
                    if (enabled) "enabled" else "disabled",
                    path,
                });
                break :blk ipc.Response.okWithData(if (enabled) "PTY logging enabled" else "PTY logging disabled", msg);
            },

            .@"pty-log-on" => blk: {
                self.session.setPtyLogging(true);
                const path = self.session.getPtyLogPath();
                const msg = try std.fmt.allocPrint(alloc, "PTY traffic logging enabled.\nLog file: {s}", .{path});
                break :blk ipc.Response.okWithData("PTY logging enabled", msg);
            },

            .@"pty-log-off" => blk: {
                self.session.setPtyLogging(false);
                break :blk ipc.Response.ok("PTY logging disabled");
            },

            .ttysize => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);

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
                        break :blk ipc.Response.err("ioctl TIOCGWINSZ failed (not a tty?)");
                    }
                }

                try writer.print("Server console size (ioctl):\n", .{});
                try writer.print("  cols: {d}\n", .{ws.ws_col});
                try writer.print("  rows: {d}\n", .{ws.ws_row});
                try writer.print("  xpixel: {d}\n", .{ws.ws_xpixel});
                try writer.print("  ypixel: {d}\n", .{ws.ws_ypixel});

                // Also show pane sizes from registry
                try writer.print("\nVirtual terminal pane sizes:\n", .{});
                var it = self.session.pane_registry.iterator();
                while (it.next()) |pane_ptr| {
                    const pane = pane_ptr.*;
                    try writer.print("  pane {d}: {d}x{d}\n", .{ pane.id, pane.cols, pane.rows });
                }

                const result_data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Server console size", result_data);
            },

            .layouts => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);

                // Write JSON array of layout templates
                try writer.writeAll("[\n");
                const templates = self.layouts.getAll();
                for (templates, 0..) |template, i| {
                    if (i > 0) try writer.writeAll(",\n");
                    try writer.print("  {{ \"id\": \"{s}\", \"name\": \"{s}\", \"panes\": {d} }}", .{
                        template.id,
                        template.name,
                        template.countPanes(),
                    });
                }
                try writer.writeAll("\n]");

                const json_data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Available layouts", json_data);
            },

            .panes => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);

                // List all pane IDs from registry
                var pane_it = self.session.pane_registry.iterator();
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

                const result_data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Pane IDs", result_data);
            },

            .windows => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);

                // JSON array of windows with pane IDs
                try writer.writeAll("[\n");
                var win_it = self.session.windows.iterator();
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

                const result_data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Windows", result_data);
            },

            .send => blk: {
                const args = data orelse
                    break :blk ipc.Response.err("Usage: send <pane_id> [text]\nReads from stdin if no text provided");

                // Parse pane ID from first argument
                const space_idx = std.mem.indexOf(u8, args, " ");
                const pane_id_str = if (space_idx) |idx| args[0..idx] else args;
                const text = if (space_idx) |idx| std.mem.trim(u8, args[idx + 1 ..], &std.ascii.whitespace) else null;

                const pane_id = std.fmt.parseInt(u16, pane_id_str, 10) catch
                    break :blk ipc.Response.err("Invalid pane ID. Usage: send <pane_id> [text]");

                const pane = self.session.pane_registry.get(pane_id) orelse
                    break :blk ipc.Response.err("Pane not found");

                // If no text provided, that's handled by CLI reading stdin
                const send_text = text orelse
                    break :blk ipc.Response.err("No text provided. Use stdin: echo 'text' | dullahan send <pane_id>");

                if (send_text.len == 0)
                    break :blk ipc.Response.err("Empty text. Use stdin: echo 'text' | dullahan send <pane_id>");

                pane.writeInput(send_text) catch |e| {
                    var errbuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&errbuf, "Failed to send: {any}", .{e}) catch "Failed to send";
                    break :blk ipc.Response.err(msg);
                };

                var msg_buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Sent {d} bytes to pane {d}", .{ send_text.len, pane.id }) catch "Sent";
                break :blk ipc.Response.ok(msg);
            },
        };
    }

    fn handleHttpAccept(self: *EventLoop) !void {
        const ws_conn = try self.http_server.acceptWebSocket();
        if (ws_conn == null) return;

        var client = ClientState.init(self.allocator, ws_conn.?);

        // Send initial snapshots for all panes via registry
        log.info("Sending initial snapshots for {d} panes", .{self.session.pane_registry.count()});
        var pane_it = self.session.pane_registry.iterator();
        while (pane_it.next()) |pane_ptr| {
            const pane = pane_ptr.*;
            log.info("Sending snapshot for pane {d}, gen={d}", .{ pane.id, pane.generation });
            self.sendSnapshot(&client.ws, pane) catch |e| {
                logClientError("send initial snapshot", e);
                client.deinit();
                return;
            };
            // Don't call clearDirtyRows() here - initial snapshot sends full state,
            // and clearing would reset dirty_base_gen which affects broadcast deltas
            // for other clients or subsequent updates
            client.setGeneration(pane.id, pane.generation);
        }

        // Send layout message (window→pane mappings + available templates)
        {
            const layout_msg = snapshot.generateLayoutMessage(self.allocator, self.session, &self.layouts) catch |e| {
                logClientError("generate layout message", e);
                client.deinit();
                return;
            };
            defer self.allocator.free(layout_msg);
            client.ws.sendBinary(layout_msg) catch |e| {
                logClientError("send layout message", e);
                client.deinit();
                return;
            };
        }

        // Send current master state
        {
            const master_msg = snapshot.generateMasterChangedMessage(self.allocator, self.master_id) catch |e| {
                logClientError("generate master_changed message", e);
                client.deinit();
                return;
            };
            defer self.allocator.free(master_msg);
            client.ws.sendBinary(master_msg) catch |e| {
                logClientError("send master_changed message", e);
                client.deinit();
                return;
            };
        }

        // Set short read/write timeouts so the event loop doesn't block
        // This allows the loop to check for shutdown signals even if:
        // - A client sends an incomplete WebSocket frame (read blocks)
        // - A client disconnects while we're trying to send (write blocks)
        client.ws.setTimeouts(100);

        try self.clients.append(self.allocator, client);
        log.info("Client connected, total clients: {d}", .{self.clients.items.len});
    }

    fn handleWsClient(self: *EventLoop, client_idx: usize) !void {
        var client = &self.clients.items[client_idx];
        var ws = &client.ws;

        const frame = try ws.readFrame();
        defer self.allocator.free(frame.payload);

        switch (frame.opcode) {
            .text => {
                if (self.parseJsonMessage(frame.payload)) |result| {
                    var cleanup = result.cleanup;
                    defer cleanup.deinit();
                    try self.handleParsedMessage(result.msg, client);
                    try self.sendClientUpdates(client);
                }
            },
            .binary => {
                if (self.parseMsgpackMessage(frame.payload)) |result| {
                    defer result.payload.free(self.allocator);
                    try self.handleParsedMessage(result.msg, client);
                    try self.sendClientUpdates(client);
                }
            },
            .ping => {
                ws.sendPong(frame.payload) catch {};
            },
            .pong => {},
            .close => {
                ws.sendClose() catch {};
                return error.ConnectionClosed;
            },
            else => {
                log.warn("Unknown opcode: {any}", .{@intFromEnum(frame.opcode)});
            },
        }
    }

    fn handlePtyData(self: *EventLoop, pane: *Pane) !void {
        var buf: [constants.buffer.general]u8 = undefined;

        if (pane.pty) |*pty| {
            const n = pty.read(&buf) catch |e| {
                if (e == error.WouldBlock) {
                    // Non-blocking read with no data - this is normal
                    return;
                }
                if (e == error.InputOutput or e == error.BrokenPipe) {
                    log.info("PTY closed for pane {d}", .{pane.id});
                    _ = pane.isAlive();
                }
                return e;
            };

            if (n > 0) {
                self.session.logPtyRecv(pane.id, buf[0..n]);
                try pane.feed(buf[0..n]);

                // Send updates for both the PTY pane and the debug pane
                // (debug pane was updated by logPtyRecv)
                const debug_pane = self.session.getDebugPane();
                for (self.clients.items) |*client| {
                    self.sendPaneUpdate(client, pane) catch |e| {
                        logClientError("send pane update", e);
                    };
                    if (debug_pane) |dp| {
                        if (dp.id != pane.id) { // Don't send twice if this IS the debug pane
                            self.sendPaneUpdate(client, dp) catch |e| {
                                logClientError("send debug pane update", e);
                            };
                        }
                    }
                }
            }
        }
    }

    fn removeClient(self: *EventLoop, idx: usize) void {
        var client = self.clients.orderedRemove(idx);
        const was_master = if (client.client_id) |id| self.isMaster(id) else false;
        log.info("Client disconnected: {s}, total clients: {d}", .{ client.shortId(), self.clients.items.len });
        client.deinit();

        // If disconnecting client was master, clear master and broadcast
        if (was_master) {
            self.setMaster(null) catch |e| {
                logRecoverable("clear master on disconnect", e);
            };
        }
    }

    /// Find a client by their UUID
    pub fn getClientById(self: *EventLoop, client_id: []const u8) ?*ClientState {
        for (self.clients.items) |*client| {
            if (client.client_id) |id| {
                if (std.mem.eql(u8, id, client_id)) {
                    return client;
                }
            }
        }
        return null;
    }

    /// Get count of identified clients (those who have sent hello)
    pub fn getIdentifiedClientCount(self: *EventLoop) usize {
        var count: usize = 0;
        for (self.clients.items) |*client| {
            if (client.client_id != null) {
                count += 1;
            }
        }
        return count;
    }

    /// Check if a client is the current master
    pub fn isMaster(self: *EventLoop, client_id: []const u8) bool {
        if (self.master_id) |master| {
            return std.mem.eql(u8, master, client_id);
        }
        return false;
    }

    /// Set a new master (or clear if null). Broadcasts master_changed to all clients.
    pub fn setMaster(self: *EventLoop, new_master_id: ?[]const u8) !void {
        // Allocate new ID first (before freeing old) to avoid use-after-free
        // if allocation fails
        const new_copy = if (new_master_id) |id|
            try self.allocator.dupe(u8, id)
        else
            null;

        // Only free old after new is successfully allocated
        if (self.master_id) |old| {
            self.allocator.free(old);
        }

        self.master_id = new_copy;

        if (new_copy) |id| {
            log.info("Master set to: {s}", .{if (id.len >= 8) id[0..8] else id});
        } else {
            log.info("Master cleared (no master)", .{});
        }

        // Broadcast master_changed to all clients
        try self.broadcastMasterChanged();
    }

    /// Broadcast master_changed message to all connected clients
    fn broadcastMasterChanged(self: *EventLoop) !void {
        const msg = try snapshot.generateMasterChangedMessage(self.allocator, self.master_id);
        defer self.allocator.free(msg);

        for (self.clients.items) |*client| {
            client.ws.sendBinary(msg) catch |e| {
                logClientError("broadcast master_changed", e);
            };
        }
    }

    /// Broadcast layout message to all connected clients
    fn broadcastLayout(self: *EventLoop) !void {
        const msg = try snapshot.generateLayoutMessage(self.allocator, self.session, &self.layouts);
        defer self.allocator.free(msg);

        for (self.clients.items) |*client| {
            client.ws.sendBinary(msg) catch |e| {
                logClientError("broadcast layout", e);
            };
        }
    }

    /// Broadcast pane update (snapshot/delta) to all connected clients.
    /// Used for selection changes and other immediate updates.
    fn broadcastPaneUpdate(self: *EventLoop, pane: *Pane) !void {
        const pane_id = pane.id;

        // Handle clipboard SET operation (OSC 52) - must broadcast to ALL clients before clearing
        if (pane.hasClipboardSet()) {
            if (pane.getClipboardSet()) |op| {
                const msg = snapshot.generateClipboardMessage(
                    pane.allocator,
                    pane_id,
                    "set",
                    op.kind,
                    op.data,
                ) catch |e| {
                    logRecoverable("generate clipboard SET message", e);
                    return;
                };
                defer pane.allocator.free(msg);

                for (self.clients.items) |*client| {
                    client.ws.sendBinary(msg) catch |e| {
                        logClientError("broadcast clipboard SET", e);
                    };
                }
            }
            pane.clearClipboardSet();
        }

        // Handle clipboard GET request (OSC 52) - send to master client only
        // Only send if not already sent (we keep pending until response or timeout)
        if (pane.needsClipboardGetSend()) {
            if (pane.getClipboardGetKind()) |kind| {
                const msg = snapshot.generateClipboardMessage(
                    pane.allocator,
                    pane_id,
                    "get",
                    kind,
                    null, // no data for GET request
                ) catch |e| {
                    logRecoverable("generate clipboard GET message", e);
                    return;
                };
                defer pane.allocator.free(msg);

                // GET should only go to master client (they respond with clipboard content)
                for (self.clients.items) |*client| {
                    const is_master = if (client.client_id) |id| self.isMaster(id) else false;
                    if (is_master) {
                        client.ws.sendBinary(msg) catch |e| {
                            logClientError("send clipboard GET to master", e);
                        };
                        pane.markClipboardGetSent();
                        break;
                    }
                }
            }
            // Note: Don't clear here - wait for response or timeout
        }

        // Check for clipboard GET timeout
        if (pane.hasClipboardGetTimedOut()) {
            pane.handleClipboardGetTimeout();
        }

        // Now broadcast pane state updates to all clients
        for (self.clients.items) |*client| {
            self.sendPaneUpdate(client, pane) catch |e| {
                logClientError("broadcast pane update", e);
            };
        }
    }

    fn sendClientUpdates(self: *EventLoop, client: *ClientState) !void {
        // Send updates for all panes via registry
        var it = self.session.pane_registry.iterator();
        while (it.next()) |pane_ptr| {
            try self.sendPaneUpdate(client, pane_ptr.*);
        }
    }

    fn sendPaneUpdate(self: *EventLoop, client: *ClientState, pane: *Pane) !void {
        const pane_id = pane.id;
        const last_gen = client.getGeneration(pane_id);
        if (pane.generation == last_gen) return;

        // Check for title change on any pane
        if (pane.hasTitleChanged()) {
            if (pane.getTitle()) |title| {
                const msg = try snapshot.generateTitleMessage(pane.allocator, pane_id, title);
                defer pane.allocator.free(msg);
                try client.ws.sendBinary(msg);
            }
            pane.clearTitleChanged();
        }

        // Check if this is the active pane for bell notification
        const window = self.session.activeWindow();
        const is_active = window != null and pane_id == window.?.active_pane_id;
        if (is_active) {
            if (pane.hasBell()) {
                const msg = try snapshot.generateBellMessage(pane.allocator);
                defer pane.allocator.free(msg);
                try client.ws.sendBinary(msg);
                pane.clearBell();
            }
        }

        // Note: Clipboard SET/GET operations are handled in broadcastPaneUpdate()
        // to ensure all clients receive them before the state is cleared.

        const result = try pane.getBroadcastDelta();
        defer pane.allocator.free(result.delta);

        if (last_gen == result.from_gen) {
            // Client can apply this delta
            try client.ws.sendBinary(result.delta);
        } else {
            // Client can't apply delta (generation mismatch), send full snapshot
            log.debug("Pane {d}: client gen {d} != delta from_gen {d}, sending snapshot", .{
                pane_id, last_gen, result.from_gen,
            });
            const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
            defer pane.allocator.free(snap);
            try client.ws.sendBinary(snap);
        }

        client.setGeneration(pane_id, pane.generation);
    }

    fn sendSnapshot(self: *EventLoop, ws: *websocket.Connection, pane: *Pane) !void {
        _ = self;
        const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
        defer pane.allocator.free(snap);
        try ws.sendBinary(snap);
    }

    // ========================================================================
    // Protocol-Agnostic Message Parsing
    // ========================================================================

    /// Parse a JSON message into the unified ParsedMessage type.
    /// Returns null if parsing fails.
    fn parseJsonMessage(self: *EventLoop, data: []const u8) ?struct { msg: ParsedMessage, cleanup: JsonCleanup } {
        const msg_type = std.json.parseFromSlice(MessageType, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer msg_type.deinit();

        const type_str = msg_type.value.type;

        if (std.mem.eql(u8, type_str, "key")) {
            const parsed = std.json.parseFromSlice(KeyEvent, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .key = .{
                    .key = parsed.value.key,
                    .code = parsed.value.code,
                    .state = parsed.value.state,
                    .ctrl = parsed.value.ctrl,
                    .alt = parsed.value.alt,
                    .shift = parsed.value.shift,
                    .meta = parsed.value.meta,
                    .repeat = parsed.value.repeat,
                    .timestamp = parsed.value.timestamp,
                    .keyCode = parsed.value.keyCode,
                } },
                .cleanup = .{ .json_key = parsed },
            };
        } else if (std.mem.eql(u8, type_str, "text")) {
            const parsed = std.json.parseFromSlice(TextMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .text = .{ .data = parsed.value.data } },
                .cleanup = .{ .json_text = parsed },
            };
        } else if (std.mem.eql(u8, type_str, "resize")) {
            const parsed = std.json.parseFromSlice(ResizeMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .resize = .{ .cols = parsed.value.cols, .rows = parsed.value.rows } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "scroll")) {
            const parsed = std.json.parseFromSlice(ScrollMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .scroll = .{ .delta = parsed.value.delta } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "ping")) {
            return .{ .msg = .{ .ping = {} }, .cleanup = .{ .none = {} } };
        } else if (std.mem.eql(u8, type_str, "sync")) {
            const parsed = std.json.parseFromSlice(SyncMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .sync = .{ .gen = parsed.value.gen, .minRowId = parsed.value.minRowId } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "focus")) {
            const parsed = std.json.parseFromSlice(FocusMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .focus = .{ .paneId = parsed.value.paneId } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "hello")) {
            const parsed = std.json.parseFromSlice(HelloMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .hello = .{ .clientId = parsed.value.clientId } },
                .cleanup = .{ .json_hello = parsed },
            };
        } else if (std.mem.eql(u8, type_str, "request_master")) {
            return .{ .msg = .{ .request_master = {} }, .cleanup = .{ .none = {} } };
        } else if (std.mem.eql(u8, type_str, "new_window")) {
            const parsed = std.json.parseFromSlice(NewWindowMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .new_window = .{ .templateId = parsed.value.templateId } },
                .cleanup = .{ .json_new_window = parsed },
            };
        } else if (std.mem.eql(u8, type_str, "close_window")) {
            const parsed = std.json.parseFromSlice(CloseWindowMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .close_window = .{ .windowId = parsed.value.windowId } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "mouse")) {
            const parsed = std.json.parseFromSlice(MouseMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .mouse = .{
                    .paneId = parsed.value.paneId,
                    .button = parsed.value.button,
                    .x = parsed.value.x,
                    .y = parsed.value.y,
                    .px = parsed.value.px,
                    .py = parsed.value.py,
                    .state = parsed.value.state,
                    .ctrl = parsed.value.ctrl,
                    .alt = parsed.value.alt,
                    .shift = parsed.value.shift,
                    .meta = parsed.value.meta,
                    .timestamp = parsed.value.timestamp,
                } },
                .cleanup = .{ .json_mouse = parsed },
            };
        } else if (std.mem.eql(u8, type_str, "select_all")) {
            const parsed = std.json.parseFromSlice(FocusMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .select_all = .{ .paneId = parsed.value.paneId } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "clear_selection")) {
            const parsed = std.json.parseFromSlice(FocusMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .clear_selection = .{ .paneId = parsed.value.paneId } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "clipboard_response")) {
            const parsed = std.json.parseFromSlice(ClipboardResponseMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .clipboard_response = .{
                    .paneId = parsed.value.paneId,
                    .clipboard = parsed.value.clipboard,
                    .data = parsed.value.data,
                } },
                .cleanup = .{ .json_clipboard_response = parsed },
            };
        }

        return .{ .msg = .{ .unknown = {} }, .cleanup = .{ .none = {} } };
    }

    /// Parse a msgpack message into the unified ParsedMessage type.
    /// Returns null if parsing fails.
    fn parseMsgpackMessage(self: *EventLoop, data: []const u8) ?struct { msg: ParsedMessage, payload: msgpack.Payload } {
        var buffer: [constants.buffer.general]u8 = undefined;
        @memcpy(buffer[0..data.len], data);

        var write_stream = msgpack.compat.fixedBufferStream(&buffer);
        var read_stream = msgpack.compat.fixedBufferStream(buffer[0..data.len]);

        const BufferType = msgpack.compat.BufferStream;
        var packer = msgpack.Pack(
            *BufferType,
            *BufferType,
            BufferType.WriteError,
            BufferType.ReadError,
            BufferType.write,
            BufferType.read,
        ).init(&write_stream, &read_stream);

        const payload = packer.read(self.allocator) catch return null;

        const type_payload = (payload.mapGet("type") catch return null) orelse return null;
        const type_str = type_payload.asStr() catch return null;

        if (std.mem.eql(u8, type_str, "key")) {
            const key_payload = (payload.mapGet("key") catch return null) orelse return null;
            const key = key_payload.asStr() catch return null;
            const state_payload = (payload.mapGet("state") catch return null) orelse return null;
            const state = state_payload.asStr() catch return null;

            const ctrl = if (payload.mapGet("ctrl") catch null) |p| (p.asBool() catch false) else false;
            const alt = if (payload.mapGet("alt") catch null) |p| (p.asBool() catch false) else false;
            const shift = if (payload.mapGet("shift") catch null) |p| (p.asBool() catch false) else false;

            return .{
                .msg = .{ .key = .{
                    .key = key,
                    .state = state,
                    .ctrl = ctrl,
                    .alt = alt,
                    .shift = shift,
                } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "text")) {
            const data_payload = (payload.mapGet("data") catch return null) orelse return null;
            const text = data_payload.asStr() catch return null;
            return .{
                .msg = .{ .text = .{ .data = text } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "resize")) {
            const cols_payload = (payload.mapGet("cols") catch return null) orelse return null;
            const rows_payload = (payload.mapGet("rows") catch return null) orelse return null;
            const cols: u16 = @intCast(cols_payload.getUint() catch return null);
            const rows: u16 = @intCast(rows_payload.getUint() catch return null);
            return .{
                .msg = .{ .resize = .{ .cols = cols, .rows = rows } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "scroll")) {
            const delta_payload = (payload.mapGet("delta") catch return null) orelse return null;
            const delta: i32 = @intCast(delta_payload.getInt() catch return null);
            return .{
                .msg = .{ .scroll = .{ .delta = delta } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "ping")) {
            return .{ .msg = .{ .ping = {} }, .payload = payload };
        } else if (std.mem.eql(u8, type_str, "sync")) {
            const gen_payload = (payload.mapGet("gen") catch return null) orelse return null;
            const gen: u64 = gen_payload.getUint() catch return null;
            const minRowId: u64 = if (payload.mapGet("minRowId") catch null) |p| (p.getUint() catch 0) else 0;
            return .{
                .msg = .{ .sync = .{ .gen = gen, .minRowId = minRowId } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "focus")) {
            const pane_id_payload = (payload.mapGet("paneId") catch return null) orelse return null;
            const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return null);
            return .{
                .msg = .{ .focus = .{ .paneId = pane_id } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "hello")) {
            const client_id_payload = (payload.mapGet("clientId") catch return null) orelse return null;
            const client_id_str = client_id_payload.asStr() catch return null;
            return .{
                .msg = .{ .hello = .{ .clientId = client_id_str } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "request_master")) {
            return .{ .msg = .{ .request_master = {} }, .payload = payload };
        } else if (std.mem.eql(u8, type_str, "new_window")) {
            const template_id: ?[]const u8 = if (payload.mapGet("templateId") catch null) |p| (p.asStr() catch null) else null;
            return .{
                .msg = .{ .new_window = .{ .templateId = template_id } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "close_window")) {
            const window_id_payload = (payload.mapGet("windowId") catch return null) orelse return null;
            const window_id: u16 = @intCast(window_id_payload.getUint() catch return null);
            return .{
                .msg = .{ .close_window = .{ .windowId = window_id } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "mouse")) {
            const pane_id_payload = (payload.mapGet("paneId") catch return null) orelse return null;
            const button_payload = (payload.mapGet("button") catch return null) orelse return null;
            const x_payload = (payload.mapGet("x") catch return null) orelse return null;
            const y_payload = (payload.mapGet("y") catch return null) orelse return null;
            const state_payload = (payload.mapGet("state") catch return null) orelse return null;

            const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return null);
            const button: u8 = @intCast(button_payload.getUint() catch return null);
            const x: u16 = @intCast(x_payload.getUint() catch return null);
            const y: u16 = @intCast(y_payload.getUint() catch return null);
            const state = state_payload.asStr() catch return null;

            const px: ?u32 = if (payload.mapGet("px") catch null) |p| @intCast(p.getUint() catch 0) else null;
            const py: ?u32 = if (payload.mapGet("py") catch null) |p| @intCast(p.getUint() catch 0) else null;
            const ctrl = if (payload.mapGet("ctrl") catch null) |p| (p.asBool() catch false) else false;
            const alt = if (payload.mapGet("alt") catch null) |p| (p.asBool() catch false) else false;
            const shift = if (payload.mapGet("shift") catch null) |p| (p.asBool() catch false) else false;
            const meta = if (payload.mapGet("meta") catch null) |p| (p.asBool() catch false) else false;
            // Note: msgpack doesn't have getFloat, and timestamp is rarely needed. Use 0.
            const timestamp: f64 = 0;

            return .{
                .msg = .{ .mouse = .{
                    .paneId = pane_id,
                    .button = button,
                    .x = x,
                    .y = y,
                    .px = px,
                    .py = py,
                    .state = state,
                    .ctrl = ctrl,
                    .alt = alt,
                    .shift = shift,
                    .meta = meta,
                    .timestamp = timestamp,
                } },
                .payload = payload,
            };
        }

        return .{ .msg = .{ .unknown = {} }, .payload = payload };
    }

    // ========================================================================
    // Unified Message Handler
    // ========================================================================

    /// Handle a parsed message (works for both JSON and msgpack protocols).
    fn handleParsedMessage(self: *EventLoop, msg: ParsedMessage, client: *ClientState) !void {
        switch (msg) {
            .key => |key_msg| {
                if (!std.mem.eql(u8, key_msg.state, "down")) return;

                const pane = self.session.activePane() orelse return;

                // Clear selection on any keyboard input
                if (pane.hasSelection()) {
                    pane.clearSelection();
                    self.broadcastPaneUpdate(pane) catch |e| {
                        logRecoverable("broadcast selection clear on keypress", e);
                    };
                }

                var output_buf: [32]u8 = undefined;
                const cursor_key_app = pane.isCursorKeyApplication();

                // Convert ParsedKeyEvent to KeyEvent for keyEventToBytes
                const key_event = KeyEvent{
                    .type = "key",
                    .key = key_msg.key,
                    .code = key_msg.code,
                    .state = key_msg.state,
                    .ctrl = key_msg.ctrl,
                    .alt = key_msg.alt,
                    .shift = key_msg.shift,
                    .meta = key_msg.meta,
                    .repeat = key_msg.repeat,
                    .timestamp = key_msg.timestamp,
                    .keyCode = key_msg.keyCode,
                };
                const output = keyEventToBytes(key_event, &output_buf, cursor_key_app);

                if (output.len > 0) {
                    self.session.logPtySend(pane.id, output);
                    pane.writeInput(output) catch |e| {
                        logRecoverable("write key to PTY", e);
                    };
                }
            },
            .text => |text_msg| {
                const pane = self.session.activePane() orelse return;

                // Clear selection on any text input
                if (pane.hasSelection()) {
                    pane.clearSelection();
                    self.broadcastPaneUpdate(pane) catch |e| {
                        logRecoverable("broadcast selection clear on text", e);
                    };
                }

                self.session.logPtySend(pane.id, text_msg.data);
                pane.writeInput(text_msg.data) catch |e| {
                    logRecoverable("write text to PTY", e);
                };
            },
            .resize => |resize_msg| {
                // Only master can resize
                const client_id = client.client_id orelse return;
                if (!self.isMaster(client_id)) {
                    log.debug("Rejecting resize from non-master client {s}", .{client.shortId()});
                    return;
                }

                const cols = resize_msg.cols;
                const rows = resize_msg.rows;

                if (cols < constants.limits.min_cols or cols > constants.limits.max_cols or
                    rows < constants.limits.min_rows or rows > constants.limits.max_rows) {
                    log.warn("Rejecting invalid resize: {d}x{d} (limits: {d}-{d}x{d}-{d})", .{
                        cols,                          rows,
                        constants.limits.min_cols,     constants.limits.max_cols,
                        constants.limits.min_rows,     constants.limits.max_rows,
                    });
                    return;
                }

                // Resize all panes via registry (debug pane needs resize too)
                try self.session.pane_registry.resizeAll(cols, rows);
            },
            .scroll => |scroll_msg| {
                const pane = self.session.activePane() orelse return;
                pane.scroll(scroll_msg.delta);
            },
            .ping => {
                const pong = try snapshot.generateBinaryPong(self.allocator);
                defer self.allocator.free(pong);
                try client.ws.sendBinary(pong);
            },
            .sync => |sync_msg| {
                const pane = self.session.activePane() orelse return;
                try self.handleSyncRequest(client, pane, sync_msg.gen);
            },
            .focus => |focus_msg| {
                const window = self.session.activeWindow() orelse return;
                if (window.setActivePane(focus_msg.paneId)) {
                    log.info("Switched to pane {d}", .{focus_msg.paneId});
                }
            },
            .hello => |hello_msg| {
                client.setClientId(hello_msg.clientId) catch |e| {
                    logClientError("set client ID", e);
                    return;
                };
                log.info("Client identified: {s}", .{client.shortId()});

                // Auto-assign as master if no master exists
                if (self.master_id == null) {
                    if (client.client_id) |cid| {
                        log.info("No master, auto-assigning {s} as master", .{client.shortId()});
                        self.setMaster(cid) catch |e| {
                            logRecoverable("auto-set master", e);
                        };
                    }
                }
            },
            .request_master => {
                // Client is requesting to become master
                const client_id = client.client_id orelse {
                    log.warn("Anonymous client tried to request master", .{});
                    return;
                };

                // Set this client as master (broadcasts to all clients)
                self.setMaster(client_id) catch |e| {
                    logRecoverable("set master", e);
                };
            },
            .new_window => |new_window_msg| {
                // Only master can create windows
                const client_id = client.client_id orelse return;
                if (!self.isMaster(client_id)) {
                    log.debug("Rejecting new_window from non-master client {s}", .{client.shortId()});
                    return;
                }

                // Get template ID (default to 3-col if not specified)
                const template_id = new_window_msg.templateId orelse "3-col";

                // Look up the template
                const template = self.layouts.get(template_id) orelse blk: {
                    log.warn("Template '{s}' not found, falling back to 3-col", .{template_id});
                    break :blk self.layouts.get("3-col") orelse {
                        log.err("Fallback template '3-col' not found", .{});
                        return;
                    };
                };

                // Count panes needed for this template
                const pane_count = template.countPanes();
                log.info("Creating window with template '{s}' ({d} panes)", .{ template_id, pane_count });

                // Create new window with the required number of panes
                const result = self.session.createWindowWithPaneCount(pane_count) catch |e| {
                    logRecoverable("create new window", e);
                    return;
                };
                defer self.allocator.free(result.pane_ids);

                log.info("Created new window {d} with {d} panes", .{ result.window_id, pane_count });

                // Assign layout to the new window
                if (self.session.getWindow(result.window_id)) |window| {
                    window.setLayoutFromTemplate(template) catch |e| {
                        logRecoverable("set layout for new window", e);
                    };
                }

                // Broadcast updated layout to all clients
                self.broadcastLayout() catch |e| {
                    logRecoverable("broadcast layout", e);
                };

                // Send initial snapshots for new panes to all clients
                for (result.pane_ids) |pane_id| {
                    if (self.session.pane_registry.get(pane_id)) |pane| {
                        for (self.clients.items) |*c| {
                            self.sendSnapshot(&c.ws, pane) catch |e| {
                                logClientError("send snapshot for new pane", e);
                            };
                            c.setGeneration(pane_id, pane.generation);
                        }
                    }
                }
            },
            .close_window => |close_window_msg| {
                // Only master can close windows
                const client_id = client.client_id orelse return;
                if (!self.isMaster(client_id)) {
                    log.debug("Rejecting close_window from non-master client {s}", .{client.shortId()});
                    return;
                }

                const window_id = close_window_msg.windowId;

                // Can't close the last window
                if (self.session.windowCount() <= 1) {
                    log.warn("Rejecting close_window: can't close the last window", .{});
                    return;
                }

                // Close the window (removes window, destroys panes, updates active window)
                self.session.closeWindow(window_id) catch |e| {
                    logRecoverable("close window", e);
                    return;
                };

                log.info("Closed window {d}", .{window_id});

                // Broadcast updated layout to all clients
                self.broadcastLayout() catch |e| {
                    logRecoverable("broadcast layout after close", e);
                };
            },
            .mouse => |mouse_msg| {
                log.debug("Mouse {s}: pane={d} button={d} pos=({d},{d}) px=({?},{?}) mods={s}{s}{s}{s} ts={d:.3}", .{
                    mouse_msg.state,
                    mouse_msg.paneId,
                    mouse_msg.button,
                    mouse_msg.x,
                    mouse_msg.y,
                    mouse_msg.px,
                    mouse_msg.py,
                    if (mouse_msg.ctrl) "C" else "",
                    if (mouse_msg.alt) "A" else "",
                    if (mouse_msg.shift) "S" else "",
                    if (mouse_msg.meta) "M" else "",
                    mouse_msg.timestamp,
                });

                // Get pane and check mouse mode
                const pane = self.session.getPaneById(mouse_msg.paneId) orelse {
                    log.warn("Mouse event for unknown pane {d}", .{mouse_msg.paneId});
                    return;
                };

                // Check if terminal has mouse reporting enabled
                const mouse_events = pane.getMouseEvents();

                // Terminal selection is used when:
                // 1. App doesn't have mouse mode enabled (mouse_events == .none), OR
                // 2. Shift is held (shift-click bypasses app mouse handling)
                const do_terminal_selection = mouse_events == .none or mouse_msg.shift;

                if (do_terminal_selection) {
                    // Handle terminal selection (bypasses app when shift held)
                    // Only left button (0) triggers selection
                    if (mouse_msg.button == 0) {
                        const is_down = std.mem.eql(u8, mouse_msg.state, "down");
                        const is_move = std.mem.eql(u8, mouse_msg.state, "move");
                        const is_up = std.mem.eql(u8, mouse_msg.state, "up");

                        if (is_down) {
                            // Start selection
                            pane.startSelection(mouse_msg.x, mouse_msg.y);
                            // Update with initial point (creates zero-size selection)
                            pane.updateSelection(mouse_msg.x, mouse_msg.y, mouse_msg.alt);
                            // Broadcast update to all clients
                            self.broadcastPaneUpdate(pane) catch |e| {
                                logRecoverable("broadcast selection start", e);
                            };
                        } else if (is_move and pane.isSelectionActive()) {
                            // Update selection during drag
                            // Alt key creates rectangular selection
                            pane.updateSelection(mouse_msg.x, mouse_msg.y, mouse_msg.alt);
                            // Broadcast update to all clients
                            self.broadcastPaneUpdate(pane) catch |e| {
                                logRecoverable("broadcast selection update", e);
                            };
                        } else if (is_up and pane.isSelectionActive()) {
                            // Check if this was a single click (no drag)
                            if (pane.isSelectionAtStart(mouse_msg.x, mouse_msg.y)) {
                                // Single click - clear selection instead of keeping empty one
                                pane.clearSelection();
                                log.debug("Single click - cleared empty selection", .{});
                            } else {
                                // Real drag - update selection to final position before ending
                                // This is important when mouseMove events are disabled on client
                                pane.updateSelection(mouse_msg.x, mouse_msg.y, mouse_msg.alt);
                                pane.endSelection();
                            }
                            // Final broadcast
                            self.broadcastPaneUpdate(pane) catch |e| {
                                logRecoverable("broadcast selection end", e);
                            };
                        }
                    }
                    return;
                }

                // Sending to app - clear any existing terminal selection on mousedown
                // This prevents "fighting" between terminal selection and app selection
                const is_press = std.mem.eql(u8, mouse_msg.state, "down");
                if (is_press and pane.hasSelection()) {
                    pane.clearSelection();
                    log.debug("Cleared terminal selection (app mouse mode active)", .{});
                    self.broadcastPaneUpdate(pane) catch |e| {
                        logRecoverable("broadcast selection clear for app", e);
                    };
                }

                // Check if this event type should be reported
                const is_motion = std.mem.eql(u8, mouse_msg.state, "move");
                if (is_motion and !mouse_events.motion()) {
                    log.debug("Mouse motion ignored (mode={s})", .{@tagName(mouse_events)});
                    return;
                }

                // For X10 mode (9), only report button presses (not releases)
                const is_release = std.mem.eql(u8, mouse_msg.state, "up");
                if (mouse_events == .x10 and is_release) {
                    log.debug("Mouse release ignored (X10 mode)", .{});
                    return;
                }

                const mouse_format = pane.getMouseFormat();
                log.debug("Mouse event accepted: mode={s} format={s}", .{
                    @tagName(mouse_events),
                    @tagName(mouse_format),
                });

                // Build mouse event for encoding
                const mouse_state = mouse.MouseState.fromString(mouse_msg.state) orelse {
                    log.warn("Unknown mouse state: {s}", .{mouse_msg.state});
                    return;
                };

                const event = mouse.MouseEvent{
                    .button = mouse_msg.button,
                    .x = mouse_msg.x,
                    .y = mouse_msg.y,
                    .px = mouse_msg.px,
                    .py = mouse_msg.py,
                    .state = mouse_state,
                    .modifiers = .{
                        .ctrl = mouse_msg.ctrl,
                        .alt = mouse_msg.alt,
                        .shift = mouse_msg.shift,
                        .meta = mouse_msg.meta,
                    },
                };

                // X10 mode (DECSET 9) doesn't have modifiers, but normal mode (1000) does
                const include_x10_modifiers = mouse_events != .x10;

                // Encode and send mouse event
                var buf: [48]u8 = undefined;
                const result = mouse.encode(event, mouse_format, &buf, include_x10_modifiers) orelse {
                    log.debug("Failed to encode mouse event (format={s})", .{@tagName(mouse_format)});
                    return;
                };

                // Write to PTY
                const mouse_seq = result.slice();
                self.session.logPtySend(pane.id, mouse_seq);
                pane.writeInput(mouse_seq) catch |e| {
                    logRecoverable("send mouse event", e);
                    return;
                };
                log.debug("Sent {s} mouse: pos=({d},{d})", .{ @tagName(mouse_format), mouse_msg.x, mouse_msg.y });
            },
            .select_all => |select_msg| {
                const pane = self.session.getPaneById(select_msg.paneId) orelse {
                    log.warn("select_all for unknown pane {d}", .{select_msg.paneId});
                    return;
                };

                const selected = pane.selectAll() catch |e| {
                    logRecoverable("select_all", e);
                    return;
                };

                if (selected) {
                    log.debug("Selected all content in pane {d}", .{select_msg.paneId});
                    // Broadcast update to all clients
                    self.broadcastPaneUpdate(pane) catch |e| {
                        logRecoverable("broadcast select_all", e);
                    };
                } else {
                    log.debug("select_all: pane {d} is empty", .{select_msg.paneId});
                }
            },
            .clear_selection => |clear_msg| {
                const pane = self.session.getPaneById(clear_msg.paneId) orelse {
                    log.warn("clear_selection for unknown pane {d}", .{clear_msg.paneId});
                    return;
                };

                pane.clearSelection();
                log.debug("Cleared selection in pane {d}", .{clear_msg.paneId});

                // Broadcast update to all clients
                self.broadcastPaneUpdate(pane) catch |e| {
                    logRecoverable("broadcast clear_selection", e);
                };
            },
            .clipboard_response => |clip_msg| {
                // Client responding to an OSC 52 GET request
                const pane = self.session.getPaneById(clip_msg.paneId) orelse {
                    log.warn("clipboard_response for unknown pane {d}", .{clip_msg.paneId});
                    return;
                };

                // Extract clipboard kind (first char of string, default 'c')
                const kind: u8 = if (clip_msg.clipboard.len > 0) clip_msg.clipboard[0] else 'c';

                // Send the OSC 52 response back to the terminal
                pane.sendClipboardResponse(kind, clip_msg.data);

                // Clear the pending GET state (response received)
                pane.clearClipboardGet();

                log.debug("Forwarded clipboard response to pane {d}: kind={c}, data_len={d}", .{
                    clip_msg.paneId,
                    kind,
                    clip_msg.data.len,
                });
            },
            .unknown => {},
        }
    }

    fn handleSyncRequest(self: *EventLoop, client: *ClientState, pane: *Pane, client_gen: u64) !void {
        _ = self;

        if (client_gen == pane.generation) {
            const delta = try snapshot.generateDelta(pane.allocator, pane, client_gen, true);
            defer pane.allocator.free(delta);
            try client.ws.sendBinary(delta);
            return;
        }

        const result = try pane.getBroadcastDelta();
        defer pane.allocator.free(result.delta);

        if (client_gen == result.from_gen) {
            try client.ws.sendBinary(result.delta);
        } else {
            const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
            defer pane.allocator.free(snap);
            try client.ws.sendBinary(snap);
        }

        client.setGeneration(pane.id, pane.generation);
    }
};

// ============================================================================
// Key Event Conversion
// ============================================================================

fn keyEventToBytes(event: KeyEvent, output: []u8, cursor_key_application: bool) []u8 {
    if (!std.mem.eql(u8, event.state, "down")) {
        return output[0..0];
    }

    const key = event.key;

    if (std.mem.eql(u8, key, "Meta") or
        std.mem.eql(u8, key, "Control") or
        std.mem.eql(u8, key, "Alt") or
        std.mem.eql(u8, key, "Shift") or
        std.mem.eql(u8, key, "CapsLock") or
        std.mem.eql(u8, key, "NumLock") or
        std.mem.eql(u8, key, "ScrollLock") or
        std.mem.eql(u8, key, "Hyper") or
        std.mem.eql(u8, key, "Super") or
        std.mem.eql(u8, key, "OS") or
        std.mem.eql(u8, key, "AltGraph") or
        std.mem.eql(u8, key, "Fn") or
        std.mem.eql(u8, key, "FnLock"))
    {
        return output[0..0];
    }

    const ctrl = event.ctrl;
    const alt = event.alt;
    const shift = event.shift;

    if (key.len == 1) {
        const c = key[0];

        if (ctrl and c >= 'a' and c <= 'z') {
            output[0] = c - 'a' + 1;
            return output[0..1];
        }
        if (ctrl and c >= 'A' and c <= 'Z') {
            output[0] = c - 'A' + 1;
            return output[0..1];
        }

        if (ctrl) {
            const ctrl_char: ?u8 = switch (c) {
                '@' => 0x00,
                '[' => 0x1b,
                '\\' => 0x1c,
                ']' => 0x1d,
                '^' => 0x1e,
                '_' => 0x1f,
                '?' => 0x7f,
                else => null,
            };
            if (ctrl_char) |cc| {
                output[0] = cc;
                return output[0..1];
            }
        }

        if (alt) {
            output[0] = 0x1b;
            output[1] = c;
            return output[0..2];
        }

        output[0] = c;
        return output[0..1];
    }

    if (std.mem.eql(u8, key, "Enter")) {
        output[0] = '\r';
        return output[0..1];
    }
    if (std.mem.eql(u8, key, "Backspace")) {
        output[0] = 0x7f;
        return output[0..1];
    }
    if (std.mem.eql(u8, key, "Tab")) {
        if (shift) {
            output[0] = 0x1b;
            output[1] = '[';
            output[2] = 'Z';
            return output[0..3];
        }
        output[0] = '\t';
        return output[0..1];
    }
    if (std.mem.eql(u8, key, "Escape")) {
        output[0] = 0x1b;
        return output[0..1];
    }
    if (std.mem.eql(u8, key, "Delete")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '3';
        output[3] = '~';
        return output[0..4];
    }

    if (std.mem.eql(u8, key, "ArrowUp")) {
        return writeArrowKey(output, 'A', ctrl, alt, cursor_key_application);
    }
    if (std.mem.eql(u8, key, "ArrowDown")) {
        return writeArrowKey(output, 'B', ctrl, alt, cursor_key_application);
    }
    if (std.mem.eql(u8, key, "ArrowRight")) {
        return writeArrowKey(output, 'C', ctrl, alt, cursor_key_application);
    }
    if (std.mem.eql(u8, key, "ArrowLeft")) {
        return writeArrowKey(output, 'D', ctrl, alt, cursor_key_application);
    }

    if (std.mem.eql(u8, key, "Home")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = 'H';
        return output[0..3];
    }
    if (std.mem.eql(u8, key, "End")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = 'F';
        return output[0..3];
    }

    if (std.mem.eql(u8, key, "PageUp")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '5';
        output[3] = '~';
        return output[0..4];
    }
    if (std.mem.eql(u8, key, "PageDown")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '6';
        output[3] = '~';
        return output[0..4];
    }

    if (std.mem.eql(u8, key, "Insert")) {
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '2';
        output[3] = '~';
        return output[0..4];
    }

    if (key.len >= 2 and key[0] == 'F') {
        const fnum = std.fmt.parseInt(u8, key[1..], 10) catch return output[0..0];
        return writeFunctionKey(output, fnum);
    }

    if (key.len > 1 and key.len <= output.len) {
        @memcpy(output[0..key.len], key);
        if (alt) {
            var i: usize = key.len;
            while (i > 0) : (i -= 1) {
                output[i] = output[i - 1];
            }
            output[0] = 0x1b;
            return output[0 .. key.len + 1];
        }
        return output[0..key.len];
    }

    return output[0..0];
}

fn writeArrowKey(output: []u8, arrow: u8, ctrl: bool, alt: bool, cursor_key_application: bool) []u8 {
    if (ctrl or alt) {
        var mod: u8 = 1;
        if (alt) mod += 2;
        if (ctrl) mod += 4;
        output[0] = 0x1b;
        output[1] = '[';
        output[2] = '1';
        output[3] = ';';
        output[4] = '0' + mod;
        output[5] = arrow;
        return output[0..6];
    }
    output[0] = 0x1b;
    if (cursor_key_application) {
        output[1] = 'O';
    } else {
        output[1] = '[';
    }
    output[2] = arrow;
    return output[0..3];
}

fn writeFunctionKey(output: []u8, fnum: u8) []u8 {
    const codes = [_]struct { prefix: []const u8, suffix: u8 }{
        .{ .prefix = "\x1bOP", .suffix = 0 },
        .{ .prefix = "\x1bOQ", .suffix = 0 },
        .{ .prefix = "\x1bOR", .suffix = 0 },
        .{ .prefix = "\x1bOS", .suffix = 0 },
        .{ .prefix = "\x1b[15~", .suffix = 0 },
        .{ .prefix = "\x1b[17~", .suffix = 0 },
        .{ .prefix = "\x1b[18~", .suffix = 0 },
        .{ .prefix = "\x1b[19~", .suffix = 0 },
        .{ .prefix = "\x1b[20~", .suffix = 0 },
        .{ .prefix = "\x1b[21~", .suffix = 0 },
        .{ .prefix = "\x1b[23~", .suffix = 0 },
        .{ .prefix = "\x1b[24~", .suffix = 0 },
    };

    if (fnum >= 1 and fnum <= 12) {
        const code = codes[fnum - 1];
        @memcpy(output[0..code.prefix.len], code.prefix);
        return output[0..code.prefix.len];
    }

    return output[0..0];
}

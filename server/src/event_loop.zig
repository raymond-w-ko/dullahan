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
const ShellIntegrationEvent = pane_mod.ShellIntegrationEvent;
const signal = @import("signal.zig");
const mouse = @import("mouse.zig");
const keyboard = @import("keyboard.zig");
const messages = @import("messages.zig");
const log_config = @import("log_config.zig");
const dlog = @import("dlog.zig");
const ipc_commands = @import("ipc_commands.zig");
const ws_proxy = @import("ws_proxy.zig");

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

/// Log layout dimensions for debugging (info level for visibility)
fn logLayoutDimensions(nodes: []const layout_db.LayoutNode, indent: usize) void {
    for (nodes) |node| {
        switch (node) {
            .pane => |p| {
                log.info("{s}pane: width={d:.1}% height={d:.1}% id={?}", .{
                    indentStr(indent),
                    p.width,
                    p.height,
                    p.pane_id,
                });
            },
            .container => |c| {
                log.info("{s}container: width={d:.1}% height={d:.1}%", .{
                    indentStr(indent),
                    c.width,
                    c.height,
                });
                logLayoutDimensions(c.children, indent + 1);
            },
        }
    }
}

fn indentStr(indent: usize) []const u8 {
    const spaces = "                ";
    const len = @min(indent * 2, spaces.len);
    return spaces[0..len];
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
// Message Types (imported from messages.zig)
// ============================================================================

const KeyEvent = messages.KeyEvent;
const TextMessage = messages.TextMessage;
const ResizeMessage = messages.ResizeMessage;
const ScrollMessage = messages.ScrollMessage;
const SyncMessage = messages.SyncMessage;
const FocusMessage = messages.FocusMessage;
const MouseMessage = messages.MouseMessage;
const HelloMessage = messages.HelloMessage;
const NewWindowMessage = messages.NewWindowMessage;
const CloseWindowMessage = messages.CloseWindowMessage;
const ClosePaneMessage = messages.ClosePaneMessage;
const SetLayoutMessage = messages.SetLayoutMessage;
const SwapPanesMessage = messages.SwapPanesMessage;
const ResizeLayoutMessage = messages.ResizeLayoutMessage;
const ClipboardResponseMessage = messages.ClipboardResponseMessage;
const ClipboardSetMessage = messages.ClipboardSetMessage;
const MessageType = messages.MessageType;

const ParsedMessage = messages.ParsedMessage;
const ParsedKeyEvent = messages.ParsedKeyEvent;
const ParsedText = messages.ParsedText;
const ParsedResize = messages.ParsedResize;
const ParsedScroll = messages.ParsedScroll;
const ParsedSync = messages.ParsedSync;
const ParsedFocus = messages.ParsedFocus;
const ParsedHello = messages.ParsedHello;
const ParsedNewWindow = messages.ParsedNewWindow;
const ParsedCloseWindow = messages.ParsedCloseWindow;
const ParsedClosePane = messages.ParsedClosePane;
const ParsedMouse = messages.ParsedMouse;
const ParsedSelectAll = messages.ParsedSelectAll;
const ParsedClearSelection = messages.ParsedClearSelection;
const ParsedClipboardResponse = messages.ParsedClipboardResponse;
const JsonCleanup = messages.JsonCleanup;

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

    /// Whether the client has been authenticated.
    /// In dev mode, clients are auto-authenticated on hello.
    /// Future: will require token validation.
    authenticated: bool = false,

    /// Auth token from hello message (for future token validation)
    auth_token: ?[]const u8 = null,

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
        // Free auth token if allocated
        if (self.auth_token) |token| {
            self.allocator.free(token);
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

    /// Set the auth token (called when "hello" message is received with token)
    pub fn setAuthToken(self: *ClientState, token: []const u8) !void {
        // Free old token if any
        if (self.auth_token) |old_token| {
            self.allocator.free(old_token);
        }
        // Allocate and copy new token
        self.auth_token = try self.allocator.dupe(u8, token);
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

    // Master's theme colors for OSC 10/11 queries (parsed from "#rrggbb" format)
    // These are updated when master sends hello with theme colors
    master_theme_fg: ?[3]u8 = null, // [r, g, b]
    master_theme_bg: ?[3]u8 = null, // [r, g, b]

    // Layout database (templates for window creation)
    layouts: layout_db.LayoutDb,

    // IPC clipboard storage (for clipboard-set/clipboard-get testing)
    ipc_clipboard_c: ?[]const u8 = null,
    ipc_clipboard_p: ?[]const u8 = null,

    // Debug: disable delta updates (always send full snapshots)
    no_delta: bool = false,

    const IPC_FD_INDEX = 0;
    const HTTP_FD_INDEX = 1;
    const FIXED_FD_COUNT = 2;

    pub fn init(
        allocator: std.mem.Allocator,
        ipc_server: *ipc.Server,
        http_server: *http.Server,
        session: *Session,
        no_delta: bool,
    ) EventLoop {
        var layouts = layout_db.LayoutDb.init(allocator);
        layouts.load() catch |e| {
            logRecoverable("load layouts", e);
        };

        if (no_delta) {
            log.info("Delta updates DISABLED (--no-delta)", .{});
        }

        return .{
            .allocator = allocator,
            .ipc_server = ipc_server,
            .http_server = http_server,
            .session = session,
            .start_time = std.time.timestamp(),
            .layouts = layouts,
            .no_delta = no_delta,
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
        // Free clipboard storage
        if (self.ipc_clipboard_c) |c| {
            self.allocator.free(c);
        }
        if (self.ipc_clipboard_p) |p| {
            self.allocator.free(p);
        }
        self.layouts.deinit();
    }

    pub fn uptime(self: *const EventLoop) i64 {
        return std.time.timestamp() - self.start_time;
    }

    // ========================================================================
    // WebSocket Proxy Methods
    // ========================================================================
    // These methods centralize WebSocket send operations, enabling:
    // - Authentication checks before message processing
    // - Permission validation (master vs slave)
    // - Future extensibility (rate limiting, audit logging, metrics)

    /// Broadcast binary message to all clients (including unauthenticated).
    /// Use for messages that everyone should receive, like during initial connection.
    fn wsBroadcastAll(self: *EventLoop, msg: []const u8) void {
        ws_proxy.WsProxy.broadcastAll(&self.clients, msg);
    }

    /// Broadcast binary message to all authenticated clients only.
    fn wsBroadcast(self: *EventLoop, msg: []const u8) void {
        ws_proxy.WsProxy.broadcast(&self.clients, msg);
    }

    /// Send to a single client without auth check.
    /// Use for initial connection handshake messages.
    fn wsSendUnchecked(self: *EventLoop, client: *ClientState, msg: []const u8) !void {
        _ = self;
        try ws_proxy.WsProxy.sendUnchecked(client, msg);
    }

    /// Send to master client only. Returns true if sent successfully.
    fn wsSendToMaster(self: *EventLoop, msg: []const u8) bool {
        return ws_proxy.WsProxy.sendToMaster(&self.clients, self.master_id, msg);
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

            if (ready > 0) {
                try self.dispatchEvents(poll_fds);
            }

            // Check for synchronized output timeouts on every iteration
            // This handles apps that enable sync mode but forget to disable it
            self.checkSyncTimeouts();
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
            // Free the IPC buffer when done (parsed.data points into this buffer)
            var mutable_result = cmd_result;
            defer mutable_result.deinit(self.allocator);

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
        // Build client info for status display
        var client_infos = try alloc.alloc(ipc_commands.ClientInfo, self.clients.items.len);
        defer alloc.free(client_infos);

        for (self.clients.items, 0..) |*client, i| {
            client_infos[i] = .{
                .client_id = client.client_id,
                .is_master = if (client.client_id) |id| self.isMaster(id) else false,
            };
        }

        // Build context for command handlers
        const ctx = ipc_commands.Context{
            .alloc = alloc,
            .persistent_alloc = self.allocator,
            .data = data,
            .uptime = self.uptime(),
            .commands_processed = self.commands_processed,
            .running = &self.running,
            .session = self.session,
            .layouts = &self.layouts,
            .client_count = self.clients.items.len,
            .clients = client_infos,
            .master_id = self.master_id,
            .ipc_clipboard_c = &self.ipc_clipboard_c,
            .ipc_clipboard_p = &self.ipc_clipboard_p,
        };

        // Dispatch to handler
        const result = try ipc_commands.dispatch(ctx, command);

        // Handle broadcast if needed
        if (result.broadcast_data) |broadcast_msg| {
            defer alloc.free(broadcast_msg);
            self.wsBroadcastAll(broadcast_msg);
        }

        return result.response;
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
            self.wsSendUnchecked(&client, layout_msg) catch |e| {
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
            self.wsSendUnchecked(&client, master_msg) catch |e| {
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
        if (log_config.log_client_join) {
            log.info("Client connected, total clients: {d}", .{self.clients.items.len});
            dlog.info("Client connected, total clients: {d}", .{self.clients.items.len});
        }
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

                    // Auth gate: only allow hello messages from unauthenticated clients
                    if (!client.authenticated) {
                        if (result.msg != .hello) {
                            log.warn("Dropping non-hello message from unauthenticated client {s}", .{client.shortId()});
                            return;
                        }
                    }

                    try self.handleParsedMessage(result.msg, client);
                    try self.sendClientUpdates(client);
                }
            },
            .binary => {
                if (self.parseMsgpackMessage(frame.payload)) |result| {
                    defer result.payload.free(self.allocator);

                    // Auth gate: only allow hello messages from unauthenticated clients
                    if (!client.authenticated) {
                        if (result.msg != .hello) {
                            log.warn("Dropping non-hello message from unauthenticated client {s}", .{client.shortId()});
                            return;
                        }
                    }

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

                // Check for synchronized output mode (DECSET 2026) transitions
                // Returns true if sync mode just ended (need to flush immediately)
                const sync_just_ended = pane.checkSyncModeTransition();

                // Handle clipboard operations (OSC 52) BEFORE sending pane updates
                // This ensures clipboard messages are broadcast to all clients immediately
                self.handlePaneClipboard(pane);

                // Handle shell integration events (OSC 133) - broadcast to all clients
                self.handlePaneShellIntegration(pane);

                // Send updates only if not in sync mode, OR if sync just ended
                // When sync mode is enabled, updates are deferred until mode is disabled
                if (!pane.sync_output_enabled or sync_just_ended) {
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
    }

    /// Synchronized output timeout in nanoseconds (1 second)
    const SYNC_TIMEOUT_NS: i128 = 1_000_000_000;

    /// Check all panes for sync output timeouts and flush if exceeded.
    /// Called on each poll iteration to handle apps that forget to disable sync mode.
    fn checkSyncTimeouts(self: *EventLoop) void {
        const now = std.time.nanoTimestamp();
        var pane_it = self.session.pane_registry.iterator();
        while (pane_it.next()) |pane_ptr| {
            const pane = pane_ptr.*;
            if (pane.sync_output_enabled) {
                if (pane.sync_output_start_ns) |start| {
                    if (now - start > SYNC_TIMEOUT_NS) {
                        log.debug("Sync timeout for pane {d}", .{pane.id});
                        pane.forceSyncDisable();
                        self.broadcastPaneUpdate(pane) catch |e| {
                            logClientError("sync timeout broadcast", e);
                        };
                    }
                }
            }
        }
    }

    fn removeClient(self: *EventLoop, idx: usize) void {
        var client = self.clients.orderedRemove(idx);
        const was_master = if (client.client_id) |id| self.isMaster(id) else false;
        if (log_config.log_client_join) {
            log.info("Client disconnected: {s}, total clients: {d}", .{ client.shortId(), self.clients.items.len });
            dlog.info("Client disconnected: {s}, total clients: {d}", .{ client.shortId(), self.clients.items.len });
        }
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
        self.wsBroadcastAll(msg);
    }

    /// Parse a hex color string like "#rrggbb" into [r, g, b] bytes.
    /// Returns null if the string is not a valid hex color.
    fn parseHexColor(color_str: []const u8) ?[3]u8 {
        // Must be exactly "#rrggbb" (7 chars)
        if (color_str.len != 7 or color_str[0] != '#') {
            return null;
        }
        const r = std.fmt.parseInt(u8, color_str[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, color_str[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, color_str[5..7], 16) catch return null;
        return .{ r, g, b };
    }

    /// Set master's theme colors and update all panes.
    /// Called when master client sends hello with theme colors.
    pub fn setMasterTheme(self: *EventLoop, fg: ?[]const u8, bg: ?[]const u8) void {
        // Parse colors
        self.master_theme_fg = if (fg) |f| parseHexColor(f) else null;
        self.master_theme_bg = if (bg) |b| parseHexColor(b) else null;

        // Log the change to debug console
        if (log_config.log_theme_colors) {
            if (self.master_theme_fg) |f| {
                dlog.info("Master theme fg: #{x:0>2}{x:0>2}{x:0>2}", .{ f[0], f[1], f[2] });
            }
            if (self.master_theme_bg) |b| {
                dlog.info("Master theme bg: #{x:0>2}{x:0>2}{x:0>2}", .{ b[0], b[1], b[2] });
            }
        }

        // Update all panes with new theme colors
        self.updatePaneThemeColors();
    }

    /// Update all panes with current master theme colors.
    fn updatePaneThemeColors(self: *EventLoop) void {
        var pane_iter = self.session.pane_registry.panes.valueIterator();
        while (pane_iter.next()) |pane_ptr| {
            pane_ptr.*.setThemeColors(self.master_theme_fg, self.master_theme_bg);
        }
    }

    /// Broadcast layout message to all connected clients
    fn broadcastLayout(self: *EventLoop) !void {
        const msg = try snapshot.generateLayoutMessage(self.allocator, self.session, &self.layouts);
        defer self.allocator.free(msg);
        self.wsBroadcastAll(msg);
    }

    // ========================================================================
    // Layout Resize Helpers
    // ========================================================================

    const LayoutNode = layout_db.LayoutNode;

    /// Error type for layout parsing
    const LayoutParseError = error{
        InvalidLayoutNodes,
        InvalidLayoutNode,
        MissingType,
        InvalidType,
        MissingWidth,
        MissingHeight,
        InvalidWidth,
        InvalidHeight,
        MissingChildren,
        InvalidNodeType,
        OutOfMemory,
    };

    /// Parse layout nodes from JSON value
    fn parseLayoutNodesFromJson(self: *EventLoop, json_nodes: std.json.Value) LayoutParseError![]LayoutNode {
        if (json_nodes != .array) return error.InvalidLayoutNodes;

        const nodes = self.allocator.alloc(LayoutNode, json_nodes.array.items.len) catch return error.OutOfMemory;
        errdefer self.allocator.free(nodes);

        for (json_nodes.array.items, 0..) |item, i| {
            nodes[i] = try self.parseLayoutNodeFromJson(item);
        }

        return nodes;
    }

    /// Parse a single layout node from JSON
    fn parseLayoutNodeFromJson(self: *EventLoop, json_node: std.json.Value) LayoutParseError!LayoutNode {
        if (json_node != .object) return error.InvalidLayoutNode;

        const obj = json_node.object;
        const type_val = obj.get("type") orelse return error.MissingType;
        if (type_val != .string) return error.InvalidType;

        const width_val = obj.get("width") orelse return error.MissingWidth;
        const height_val = obj.get("height") orelse return error.MissingHeight;

        const width: f32 = switch (width_val) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => return error.InvalidWidth,
        };

        const height: f32 = switch (height_val) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => return error.InvalidHeight,
        };

        if (std.mem.eql(u8, type_val.string, "pane")) {
            const pane_id: ?u16 = if (obj.get("paneId")) |pid| blk: {
                if (pid != .integer) break :blk null;
                break :blk @intCast(pid.integer);
            } else null;

            return .{ .pane = .{
                .width = width,
                .height = height,
                .pane_id = pane_id,
            } };
        } else if (std.mem.eql(u8, type_val.string, "container")) {
            const children_val = obj.get("children") orelse return error.MissingChildren;
            const children = try self.parseLayoutNodesFromJson(children_val);

            return .{ .container = .{
                .width = width,
                .height = height,
                .children = children,
            } };
        }

        return error.InvalidNodeType;
    }

    /// Free layout nodes recursively
    fn freeLayoutNodes(self: *EventLoop, nodes: []LayoutNode) void {
        for (nodes) |*node| {
            if (node.* == .container) {
                self.freeLayoutNodes(node.container.children);
            }
        }
        self.allocator.free(nodes);
    }

    /// Validate layout percentages (each sibling group should sum close to 100%)
    fn validateLayoutPercentages(_: *EventLoop, nodes: []const LayoutNode) bool {
        return validateLayoutPercentagesImpl(nodes);
    }

    fn validateLayoutPercentagesImpl(nodes: []const LayoutNode) bool {
        if (nodes.len == 0) return true;

        // Check width/height percentages
        var width_sum: f32 = 0;
        var height_sum: f32 = 0;

        for (nodes) |node| {
            switch (node) {
                .pane => |p| {
                    width_sum += p.width;
                    height_sum += p.height;
                    // Validate min size (5%)
                    if (p.width < 5 or p.height < 5) return false;
                },
                .container => |c| {
                    width_sum += c.width;
                    height_sum += c.height;
                    // Validate min size
                    if (c.width < 5 or c.height < 5) return false;
                    // Recursively validate children
                    if (!validateLayoutPercentagesImpl(c.children)) return false;
                },
            }
        }

        // At least one dimension should sum close to 100% (allow 5% tolerance)
        const width_ok = @abs(width_sum - 100.0) < 5.0;
        const height_ok = @abs(height_sum - 100.0) < 5.0;

        // Width sums for horizontal splits, height sums for vertical splits
        // (depends on nesting level, so we allow either to be valid)
        return width_ok or height_ok;
    }

    /// Copy dimensions from new_nodes to old_nodes in place, preserving pane IDs
    fn copyLayoutDimensions(_: *EventLoop, old_nodes: []LayoutNode, new_nodes: []const LayoutNode) !void {
        if (old_nodes.len != new_nodes.len) return error.LayoutMismatch;

        for (old_nodes, new_nodes) |*old, new| {
            switch (old.*) {
                .pane => |*p| {
                    if (new != .pane) return error.LayoutTypeMismatch;
                    // Update dimensions, keep pane_id
                    p.width = new.pane.width;
                    p.height = new.pane.height;
                },
                .container => |*c| {
                    if (new != .container) return error.LayoutTypeMismatch;
                    // Update dimensions
                    c.width = new.container.width;
                    c.height = new.container.height;
                    // Recursively update children
                    try copyLayoutDimensionsStatic(c.children, new.container.children);
                },
            }
        }
    }

    /// Static version for recursive calls
    fn copyLayoutDimensionsStatic(old_nodes: []LayoutNode, new_nodes: []const LayoutNode) !void {
        if (old_nodes.len != new_nodes.len) return error.LayoutMismatch;

        for (old_nodes, new_nodes) |*old, new| {
            switch (old.*) {
                .pane => |*p| {
                    if (new != .pane) return error.LayoutTypeMismatch;
                    p.width = new.pane.width;
                    p.height = new.pane.height;
                },
                .container => |*c| {
                    if (new != .container) return error.LayoutTypeMismatch;
                    c.width = new.container.width;
                    c.height = new.container.height;
                    try copyLayoutDimensionsStatic(c.children, new.container.children);
                },
            }
        }
    }

    /// Broadcast pane update (snapshot/delta) to all connected clients.
    /// Used for selection changes and other immediate updates.
    fn broadcastPaneUpdate(self: *EventLoop, pane: *Pane) !void {
        // Handle any pending clipboard operations first
        // Note: This is typically handled in handlePtyData(), but included here
        // for completeness in case broadcastPaneUpdate is called from other paths.
        self.handlePaneClipboard(pane);

        // Broadcast pane state updates to all clients
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

        // Check for toast notification (OSC 9/777)
        if (pane.hasNotification()) {
            if (pane.getNotification()) |notif| {
                const msg = try snapshot.generateToastMessage(pane.allocator, pane_id, notif.title, notif.body);
                defer pane.allocator.free(msg);
                try client.ws.sendBinary(msg);
            }
            pane.clearNotification();
        }

        // Check for progress update (OSC 9;4)
        if (pane.hasProgressChanged()) {
            const progress = pane.getProgress();
            const msg = try snapshot.generateProgressMessage(pane.allocator, pane_id, progress.state, progress.value);
            defer pane.allocator.free(msg);
            try client.ws.sendBinary(msg);
            pane.clearProgressChanged();
        }

        // Note: Clipboard SET/GET operations are handled in broadcastPaneUpdate()
        // to ensure all clients receive them before the state is cleared.

        // If no_delta is set, always send full snapshots for debugging
        if (self.no_delta) {
            const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
            defer pane.allocator.free(snap);
            try client.ws.sendBinary(snap);
            client.setGeneration(pane_id, pane.generation);
            return;
        }

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

    /// Send current IPC clipboard state to a client.
    /// Called when a client first connects (after hello) to sync clipboard state.
    fn sendIpcClipboardState(self: *EventLoop, client: *ClientState) !void {
        // Send clipboard 'c' if set
        if (self.ipc_clipboard_c) |text| {
            const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
            const base64_data = try self.allocator.alloc(u8, encoded_len);
            defer self.allocator.free(base64_data);
            _ = std.base64.standard.Encoder.encode(base64_data, text);

            const msg = try snapshot.generateClipboardMessage(
                self.allocator,
                0, // pane_id doesn't matter for IPC clipboard
                "set",
                'c',
                base64_data,
            );
            defer self.allocator.free(msg);

            try client.ws.sendBinary(msg);
            if (log_config.log_clipboard) {
                dlog.info("Sent IPC clipboard 'c' to new client: {d} bytes", .{text.len});
            }
        }

        // Send clipboard 'p' if set
        if (self.ipc_clipboard_p) |text| {
            const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
            const base64_data = try self.allocator.alloc(u8, encoded_len);
            defer self.allocator.free(base64_data);
            _ = std.base64.standard.Encoder.encode(base64_data, text);

            const msg = try snapshot.generateClipboardMessage(
                self.allocator,
                0,
                "set",
                'p',
                base64_data,
            );
            defer self.allocator.free(msg);

            try client.ws.sendBinary(msg);
            if (log_config.log_clipboard) {
                dlog.info("Sent IPC clipboard 'p' to new client: {d} bytes", .{text.len});
            }
        }
    }

    /// Update IPC clipboard storage from base64-encoded data.
    /// Called when OSC 52 SET is received from a pane.
    fn updateIpcClipboardFromBase64(self: *EventLoop, kind: u8, base64_data: []const u8) void {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(base64_data) catch return;
        if (decoded_len == 0) return;

        const buf = self.allocator.alloc(u8, decoded_len) catch return;
        defer self.allocator.free(buf);

        std.base64.standard.Decoder.decode(buf, base64_data) catch return;

        const text_copy = self.allocator.dupe(u8, buf[0..decoded_len]) catch return;

        if (kind == 'c') {
            if (self.ipc_clipboard_c) |old| self.allocator.free(old);
            self.ipc_clipboard_c = text_copy;
        } else if (kind == 'p') {
            if (self.ipc_clipboard_p) |old| self.allocator.free(old);
            self.ipc_clipboard_p = text_copy;
        } else {
            self.allocator.free(text_copy);
        }
    }

    /// Update primary (p) clipboard from pane selection text.
    /// Called when a selection is completed (mouse drag ends).
    /// Broadcasts clipboard SET to all clients (but not navigator.clipboard).
    fn updatePrimaryClipboardFromSelection(self: *EventLoop, pane: *Pane) void {
        // Get the selected text from the terminal
        const selected_text = pane.getSelectionText() catch |e| {
            logRecoverable("get selection text for primary clipboard", e);
            return;
        };

        if (selected_text) |text| {
            defer pane.allocator.free(text);

            if (log_config.log_clipboard) {
                dlog.info("Selection → primary: pane={d} text_len={d}", .{ pane.id, text.len });
            }

            // Store in ipc_clipboard_p (primary selection)
            const text_copy = self.allocator.dupe(u8, text) catch |e| {
                logRecoverable("allocate primary clipboard text", e);
                return;
            };
            if (self.ipc_clipboard_p) |old| {
                self.allocator.free(old);
            }
            self.ipc_clipboard_p = text_copy;

            // Broadcast clipboard SET to all clients
            const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
            const base64_data = self.allocator.alloc(u8, encoded_len) catch |e| {
                logRecoverable("allocate base64 for primary clipboard", e);
                return;
            };
            defer self.allocator.free(base64_data);
            _ = std.base64.standard.Encoder.encode(base64_data, text);

            const msg = snapshot.generateClipboardMessage(
                self.allocator,
                pane.id,
                "set",
                'p',
                base64_data,
            ) catch |e| {
                logRecoverable("generate clipboard message for primary", e);
                return;
            };
            defer self.allocator.free(msg);
            self.wsBroadcastAll(msg);

            log.debug("Updated primary clipboard from selection: {d} chars", .{text.len});
        }
    }

    /// Handle clipboard operations (OSC 52) for a pane.
    /// This checks for pending SET/GET and broadcasts to appropriate clients.
    /// Called after pane.feed() to ensure clipboard messages are sent immediately.
    fn handlePaneClipboard(self: *EventLoop, pane: *Pane) void {
        const pane_id = pane.id;

        // Handle clipboard SET operation - broadcast to ALL clients
        if (pane.hasClipboardSet()) {
            if (pane.getClipboardSet()) |op| {
                if (log_config.log_clipboard) {
                    dlog.info("Clipboard SET: pane={d} kind='{c}' data_len={d}", .{ pane_id, op.kind, op.data.len });
                }

                // Also update IPC clipboard storage so clipboard-get works
                // op.data is base64-encoded, decode it for storage
                self.updateIpcClipboardFromBase64(op.kind, op.data);

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
                self.wsBroadcastAll(msg);
            }
            pane.clearClipboardSet();
        }

        // Handle clipboard GET request - send to master client only
        if (pane.needsClipboardGetSend()) {
            if (pane.getClipboardGetKind()) |kind| {
                if (log_config.log_clipboard) {
                    dlog.info("Clipboard GET request: pane={d} kind='{c}'", .{ pane_id, kind });
                }

                const msg = snapshot.generateClipboardMessage(
                    pane.allocator,
                    pane_id,
                    "get",
                    kind,
                    null,
                ) catch |e| {
                    logRecoverable("generate clipboard GET message", e);
                    return;
                };
                defer pane.allocator.free(msg);

                if (self.wsSendToMaster(msg)) {
                    pane.markClipboardGetSent();
                }
            }
        }

        // Check for clipboard GET timeout
        if (pane.hasClipboardGetTimedOut()) {
            if (log_config.log_clipboard) {
                dlog.warn("Clipboard GET timeout: pane={d}", .{pane_id});
            }
            pane.handleClipboardGetTimeout();
        }
    }

    /// Handle shell integration events (OSC 133) for a pane.
    /// Broadcasts shell integration messages to all connected clients.
    /// Called after pane.feed() to ensure events are sent immediately.
    fn handlePaneShellIntegration(self: *EventLoop, pane: *Pane) void {
        if (!pane.hasShellEvent()) return;

        const event = pane.getShellEvent() orelse return;
        const pane_id = pane.id;

        // Convert event kind to string
        const event_str = switch (event.kind) {
            .prompt_start => "prompt_start",
            .prompt_end => "prompt_end",
            .output_start => "output_start",
            .command_end => "command_end",
        };

        log.info("Shell integration: pane={d} event={s} exit_code={?d}", .{
            pane_id,
            event_str,
            event.exit_code,
        });

        const msg = snapshot.generateShellIntegrationMessage(
            self.allocator,
            pane_id,
            event_str,
            event.exit_code,
        ) catch |e| {
            logRecoverable("generate shell integration message", e);
            pane.clearShellEvent();
            return;
        };
        defer self.allocator.free(msg);
        self.wsBroadcastAll(msg);

        pane.clearShellEvent();
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
                .msg = .{ .hello = .{
                    .clientId = parsed.value.clientId,
                    .themeFg = parsed.value.themeFg,
                    .themeBg = parsed.value.themeBg,
                    .token = parsed.value.token,
                } },
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
        } else if (std.mem.eql(u8, type_str, "close_pane")) {
            const parsed = std.json.parseFromSlice(ClosePaneMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .close_pane = .{ .paneId = parsed.value.paneId } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "set_layout")) {
            const parsed = std.json.parseFromSlice(SetLayoutMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .set_layout = .{
                    .windowId = parsed.value.windowId,
                    .templateId = parsed.value.templateId,
                } },
                .cleanup = .{ .json_set_layout = parsed },
            };
        } else if (std.mem.eql(u8, type_str, "swap_panes")) {
            const parsed = std.json.parseFromSlice(SwapPanesMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .swap_panes = .{
                    .windowId = parsed.value.windowId,
                    .paneId1 = parsed.value.paneId1,
                    .paneId2 = parsed.value.paneId2,
                } },
                .cleanup = .{ .json_swap_panes = parsed },
            };
        } else if (std.mem.eql(u8, type_str, "resize_layout")) {
            const parsed = std.json.parseFromSlice(ResizeLayoutMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .resize_layout = .{
                    .windowId = parsed.value.windowId,
                    .nodes = parsed.value.nodes,
                } },
                .cleanup = .{ .json_resize_layout = parsed },
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
        } else if (std.mem.eql(u8, type_str, "clipboard_set")) {
            const parsed = std.json.parseFromSlice(ClipboardSetMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            return .{
                .msg = .{ .clipboard_set = .{
                    .clipboard = parsed.value.clipboard,
                    .data = parsed.value.data,
                } },
                .cleanup = .{ .json_clipboard_set = parsed },
            };
        } else if (std.mem.eql(u8, type_str, "copy")) {
            const parsed = std.json.parseFromSlice(messages.CopyMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            return .{
                .msg = .{ .copy = .{ .paneId = parsed.value.paneId } },
                .cleanup = .{ .none = {} },
            };
        } else if (std.mem.eql(u8, type_str, "clipboard_paste")) {
            const parsed = std.json.parseFromSlice(messages.ClipboardPasteMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            // Extract just the first character (c or p) to avoid use-after-free
            const kind: u8 = if (parsed.value.clipboard.len > 0) parsed.value.clipboard[0] else 'c';
            return .{
                .msg = .{ .clipboard_paste = .{
                    .paneId = parsed.value.paneId,
                    .clipboard = kind,
                } },
                .cleanup = .{ .none = {} },
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
            const token: ?[]const u8 = if (payload.mapGet("token") catch null) |p| (p.asStr() catch null) else null;
            return .{
                .msg = .{ .hello = .{ .clientId = client_id_str, .token = token } },
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
        } else if (std.mem.eql(u8, type_str, "close_pane")) {
            const pane_id_payload = (payload.mapGet("paneId") catch return null) orelse return null;
            const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return null);
            return .{
                .msg = .{ .close_pane = .{ .paneId = pane_id } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "set_layout")) {
            const window_id_payload = (payload.mapGet("windowId") catch return null) orelse return null;
            const template_id_payload = (payload.mapGet("templateId") catch return null) orelse return null;
            const window_id: u16 = @intCast(window_id_payload.getUint() catch return null);
            const template_id = template_id_payload.asStr() catch return null;
            return .{
                .msg = .{ .set_layout = .{
                    .windowId = window_id,
                    .templateId = template_id,
                } },
                .payload = payload,
            };
        } else if (std.mem.eql(u8, type_str, "swap_panes")) {
            const window_id_payload = (payload.mapGet("windowId") catch return null) orelse return null;
            const pane_id1_payload = (payload.mapGet("paneId1") catch return null) orelse return null;
            const pane_id2_payload = (payload.mapGet("paneId2") catch return null) orelse return null;
            const window_id: u16 = @intCast(window_id_payload.getUint() catch return null);
            const pane_id1: u16 = @intCast(pane_id1_payload.getUint() catch return null);
            const pane_id2: u16 = @intCast(pane_id2_payload.getUint() catch return null);
            return .{
                .msg = .{ .swap_panes = .{
                    .windowId = window_id,
                    .paneId1 = pane_id1,
                    .paneId2 = pane_id2,
                } },
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

                // Check if this is a modifier-only key (Ctrl, Shift, Alt, Meta)
                // Don't clear selection for modifier-only keys - they don't produce output
                const is_modifier_only = std.mem.eql(u8, key_msg.code, "ControlLeft") or
                    std.mem.eql(u8, key_msg.code, "ControlRight") or
                    std.mem.eql(u8, key_msg.code, "ShiftLeft") or
                    std.mem.eql(u8, key_msg.code, "ShiftRight") or
                    std.mem.eql(u8, key_msg.code, "AltLeft") or
                    std.mem.eql(u8, key_msg.code, "AltRight") or
                    std.mem.eql(u8, key_msg.code, "MetaLeft") or
                    std.mem.eql(u8, key_msg.code, "MetaRight");

                // Clear selection on keyboard input that produces output (not modifier-only)
                if (!is_modifier_only and pane.hasSelection()) {
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
                const output = keyboard.keyEventToBytes(key_event, &output_buf, cursor_key_app);

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

                // Wrap in bracketed paste sequences if mode is enabled (DECSET 2004)
                if (pane.terminal.modes.get(.bracketed_paste)) {
                    const PASTE_START = "\x1b[200~";
                    const PASTE_END = "\x1b[201~";

                    self.session.logPtySend(pane.id, PASTE_START);
                    self.session.logPtySend(pane.id, text_msg.data);
                    self.session.logPtySend(pane.id, PASTE_END);

                    pane.writeInput(PASTE_START) catch |e| {
                        logRecoverable("write paste start to PTY", e);
                        return;
                    };
                    pane.writeInput(text_msg.data) catch |e| {
                        logRecoverable("write text to PTY", e);
                        return;
                    };
                    pane.writeInput(PASTE_END) catch |e| {
                        logRecoverable("write paste end to PTY", e);
                    };
                } else {
                    self.session.logPtySend(pane.id, text_msg.data);
                    pane.writeInput(text_msg.data) catch |e| {
                        logRecoverable("write text to PTY", e);
                    };
                }
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
                const old_pane_id = window.active_pane_id;

                if (window.setActivePane(focus_msg.paneId)) {
                    // Send focus-out to previously active pane
                    if (old_pane_id != focus_msg.paneId) {
                        if (self.session.pane_registry.get(old_pane_id)) |old_pane| {
                            old_pane.sendFocusOut();
                        }
                    }

                    // Send focus-in to newly active pane
                    if (self.session.pane_registry.get(focus_msg.paneId)) |new_pane| {
                        new_pane.sendFocusIn();
                    }

                    log.info("Switched to pane {d}", .{focus_msg.paneId});
                }
            },
            .hello => |hello_msg| {
                client.setClientId(hello_msg.clientId) catch |e| {
                    logClientError("set client ID", e);
                    return;
                };

                // Mark client as authenticated (dev mode: auto-auth on valid hello)
                // Future: validate hello_msg.token here before setting authenticated
                client.authenticated = true;

                if (log_config.log_client_join) {
                    log.info("Client identified: {s}", .{client.shortId()});
                    dlog.info("Client identified: {s}", .{client.shortId()});
                }

                // Auto-assign as master if no master exists
                if (self.master_id == null) {
                    if (client.client_id) |cid| {
                        if (log_config.log_client_join) {
                            log.info("No master, auto-assigning {s} as master", .{client.shortId()});
                            dlog.info("No master, auto-assigning {s} as master", .{client.shortId()});
                        }
                        self.setMaster(cid) catch |e| {
                            logRecoverable("auto-set master", e);
                        };
                    }
                }

                // If this client is master, store their theme colors for OSC 10/11
                if (client.client_id) |cid| {
                    if (self.isMaster(cid)) {
                        self.setMasterTheme(hello_msg.themeFg, hello_msg.themeBg);
                    }
                }

                // Send current IPC clipboard state to the new client
                self.sendIpcClipboardState(client) catch |e| {
                    logRecoverable("send IPC clipboard state", e);
                };
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

                // Get template ID (default to 2x2 if not specified)
                const template_id = new_window_msg.templateId orelse "2x2";

                // Look up the template
                const template = self.layouts.get(template_id) orelse blk: {
                    log.warn("Template '{s}' not found, falling back to 2x2", .{template_id});
                    break :blk self.layouts.get("2x2") orelse {
                        log.err("Fallback template '2x2' not found", .{});
                        return;
                    };
                };

                // Count panes needed for this template
                const pane_count = template.countPanes();
                if (log_config.log_window_creation) {
                    log.info("Creating window with template '{s}' ({d} panes)", .{ template_id, pane_count });
                    dlog.info("Creating window with template '{s}' ({d} panes)", .{ template_id, pane_count });
                }

                // Create new window with the required number of panes
                const result = self.session.createWindowWithPaneCount(pane_count) catch |e| {
                    logRecoverable("create new window", e);
                    return;
                };
                defer self.allocator.free(result.pane_ids);

                if (log_config.log_window_creation) {
                    log.info("Created new window {d} with {d} panes", .{ result.window_id, pane_count });
                    dlog.info("Created new window {d} with {d} panes", .{ result.window_id, pane_count });
                }

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
            .close_pane => |close_pane_msg| {
                // Only master can close panes
                const client_id = client.client_id orelse return;
                if (!self.isMaster(client_id)) {
                    log.debug("Rejecting close_pane from non-master client {s}", .{client.shortId()});
                    return;
                }

                const pane_id = close_pane_msg.paneId;

                // Find which window contains this pane
                var target_window: ?*Window = null;
                var it = self.session.windows.valueIterator();
                while (it.next()) |window_ptr| {
                    if (window_ptr.hasPane(pane_id)) {
                        target_window = window_ptr;
                        break;
                    }
                }

                const window = target_window orelse {
                    log.warn("close_pane: pane {d} not found in any window", .{pane_id});
                    return;
                };

                // If this is the last pane in the window, close the entire window instead
                if (window.paneCount() <= 1) {
                    // Can't close the last pane in the last window
                    if (self.session.windowCount() <= 1) {
                        log.warn("Rejecting close_pane: can't close the last pane in the last window", .{});
                        return;
                    }

                    // Close the entire window
                    const window_id = window.id;
                    self.session.closeWindow(window_id) catch |e| {
                        logRecoverable("close window (last pane)", e);
                        return;
                    };
                    log.info("Closed window {d} (last pane closed)", .{window_id});
                } else {
                    // Remove pane from window and destroy it
                    window.removePane(pane_id);
                    self.session.pane_registry.destroy(pane_id);
                    log.info("Closed pane {d}", .{pane_id});
                }

                // Broadcast updated layout to all clients
                self.broadcastLayout() catch |e| {
                    logRecoverable("broadcast layout after close pane", e);
                };
            },
            .set_layout => |set_layout_msg| {
                // Only master can change layouts
                const client_id = client.client_id orelse return;
                if (!self.isMaster(client_id)) {
                    log.debug("Rejecting set_layout from non-master client {s}", .{client.shortId()});
                    return;
                }

                const window_id = set_layout_msg.windowId;
                const template_id = set_layout_msg.templateId;

                // Look up the template
                const template = self.layouts.get(template_id) orelse {
                    log.warn("Template '{s}' not found for set_layout", .{template_id});
                    return;
                };

                // Get the window
                const window = self.session.getWindow(window_id) orelse {
                    log.warn("Window {d} not found for set_layout", .{window_id});
                    return;
                };

                // Check if template requires more panes than window has
                const required_panes = template.countPanes();
                const current_panes = window.paneCount();

                if (required_panes > current_panes) {
                    // Add panes to fill the layout
                    const to_add = required_panes - current_panes;
                    var i: usize = 0;
                    while (i < to_add) : (i += 1) {
                        const new_pane_id = self.session.pane_registry.createShellPane() catch |e| {
                            logRecoverable("create pane for layout change", e);
                            return;
                        };
                        window.addPane(new_pane_id) catch |e| {
                            logRecoverable("add pane to window for layout change", e);
                            return;
                        };
                        // Send initial snapshot for new pane
                        if (self.session.pane_registry.get(new_pane_id)) |new_pane| {
                            for (self.clients.items) |*c| {
                                self.sendSnapshot(&c.ws, new_pane) catch |e| {
                                    logClientError("send snapshot for new pane", e);
                                };
                                c.setGeneration(new_pane_id, new_pane.generation);
                            }
                        }
                    }
                    log.info("Added {d} panes to window {d} for layout '{s}'", .{ to_add, window_id, template_id });
                } else if (required_panes < current_panes) {
                    // Extra panes become hidden (not rendered in layout, but still exist)
                    const hidden = current_panes - required_panes;
                    log.info("Window {d} has {d} hidden panes after layout change to '{s}'", .{ window_id, hidden, template_id });
                }

                // Log current dimensions before reset (for debugging)
                if (window.layout_nodes) |old_nodes| {
                    log.info("Before reset - current layout dimensions:", .{});
                    logLayoutDimensions(old_nodes, 0);
                }

                // Apply the new layout (clones fresh nodes from template with original dimensions)
                window.setLayoutFromTemplate(template) catch |e| {
                    logRecoverable("set layout from template", e);
                    return;
                };

                // Log the new layout dimensions for debugging
                if (window.layout_nodes) |nodes| {
                    log.info("Changed window {d} layout to '{s}' - reset to template dimensions", .{ window_id, template_id });
                    logLayoutDimensions(nodes, 0);
                } else {
                    log.info("Changed window {d} layout to '{s}'", .{ window_id, template_id });
                }

                // Broadcast updated layout to all clients
                self.broadcastLayout() catch |e| {
                    logRecoverable("broadcast layout after set_layout", e);
                };
            },
            .swap_panes => |swap_msg| {
                // Only master can swap panes
                const client_id = client.client_id orelse return;
                if (!self.isMaster(client_id)) {
                    log.debug("Rejecting swap_panes from non-master client {s}", .{client.shortId()});
                    return;
                }

                const window_id = swap_msg.windowId;
                const pane_id1 = swap_msg.paneId1;
                const pane_id2 = swap_msg.paneId2;

                // Get the window
                const window = self.session.getWindow(window_id) orelse {
                    log.warn("Window {d} not found for swap_panes", .{window_id});
                    return;
                };

                // Swap the pane positions
                if (!window.swapPanePositions(pane_id1, pane_id2)) {
                    log.warn("Failed to swap panes {d} and {d} in window {d}: one or both panes not found", .{ pane_id1, pane_id2, window_id });
                    return;
                }

                log.info("Swapped panes {d} and {d} in window {d}", .{ pane_id1, pane_id2, window_id });

                // Re-apply layout with new pane order
                if (self.layouts.get(window.template_id orelse "")) |template| {
                    window.setLayoutFromTemplate(template) catch |e| {
                        logRecoverable("re-apply layout after swap_panes", e);
                        return;
                    };
                }

                // Broadcast updated layout to all clients
                self.broadcastLayout() catch |e| {
                    logRecoverable("broadcast layout after swap_panes", e);
                };
            },
            .resize_layout => |resize_msg| {
                // Only master can resize layout
                const client_id = client.client_id orelse return;
                if (!self.isMaster(client_id)) {
                    log.debug("Rejecting resize_layout from non-master client {s}", .{client.shortId()});
                    return;
                }

                const window_id = resize_msg.windowId;

                // Get the window
                const window = self.session.getWindow(window_id) orelse {
                    log.warn("Window {d} not found for resize_layout", .{window_id});
                    return;
                };

                // Parse and validate the new layout nodes
                const new_nodes = self.parseLayoutNodesFromJson(resize_msg.nodes) catch |e| {
                    log.warn("Failed to parse resize_layout nodes: {any}", .{e});
                    return;
                };
                defer self.freeLayoutNodes(new_nodes);

                // Validate percentages (each sibling group should sum to ~100%)
                if (!self.validateLayoutPercentages(new_nodes)) {
                    log.warn("Invalid layout percentages in resize_layout", .{});
                    return;
                }

                // Update window's layout nodes in place
                if (window.layout_nodes) |old_nodes| {
                    // Deep copy new dimensions into existing layout, preserving pane IDs
                    self.copyLayoutDimensions(old_nodes, new_nodes) catch |e| {
                        log.warn("Failed to copy layout dimensions: {any}", .{e});
                        return;
                    };
                } else {
                    log.warn("Window {d} has no layout to resize", .{window_id});
                    return;
                }

                log.info("Resized layout for window {d}", .{window_id});

                // Broadcast updated layout to all clients
                self.broadcastLayout() catch |e| {
                    logRecoverable("broadcast layout after resize_layout", e);
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
                    // Handle terminal operations when not in mouse reporting mode
                    // (or when shift is held to bypass mouse reporting)

                    // Middle-click (button 1) pastes from primary clipboard
                    if (mouse_msg.button == 1) {
                        const is_down = std.mem.eql(u8, mouse_msg.state, "down");
                        if (is_down) {
                            // Paste from primary clipboard
                            if (self.ipc_clipboard_p) |text| {
                                if (log_config.log_clipboard) {
                                    dlog.info("Middle-click paste: pane={d} text_len={d}", .{
                                        mouse_msg.paneId,
                                        text.len,
                                    });
                                }

                                // Write to PTY with bracketed paste support
                                if (pane.terminal.modes.get(.bracketed_paste)) {
                                    const PASTE_START = "\x1b[200~";
                                    const PASTE_END = "\x1b[201~";

                                    self.session.logPtySend(pane.id, PASTE_START);
                                    self.session.logPtySend(pane.id, text);
                                    self.session.logPtySend(pane.id, PASTE_END);

                                    pane.writeInput(PASTE_START) catch |e| {
                                        logRecoverable("write paste start for middle-click", e);
                                        return;
                                    };
                                    pane.writeInput(text) catch |e| {
                                        logRecoverable("write text for middle-click paste", e);
                                        return;
                                    };
                                    pane.writeInput(PASTE_END) catch |e| {
                                        logRecoverable("write paste end for middle-click", e);
                                    };
                                } else {
                                    self.session.logPtySend(pane.id, text);
                                    pane.writeInput(text) catch |e| {
                                        logRecoverable("write text for middle-click paste", e);
                                    };
                                }

                                log.debug("Middle-click pasted to pane {d}: {d} chars", .{ pane.id, text.len });
                            } else {
                                log.debug("Middle-click paste: primary clipboard is empty", .{});
                            }
                        }
                        return;
                    }

                    // Left button (0) triggers selection
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

                                // Auto-update primary (p) clipboard with selection text
                                // This is standard X11 terminal behavior - select to copy to primary
                                self.updatePrimaryClipboardFromSelection(pane);
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

                if (log_config.log_clipboard) {
                    dlog.info("Clipboard response: pane={d} kind='{c}' data_len={d}", .{
                        clip_msg.paneId,
                        kind,
                        clip_msg.data.len,
                    });
                }

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
            .clipboard_set => |clip_msg| {
                // Client updating server's clipboard storage (from browser clipboard bar)
                const kind: u8 = if (clip_msg.clipboard.len > 0) clip_msg.clipboard[0] else 'c';

                if (log_config.log_clipboard) {
                    dlog.info("Clipboard set from client: kind='{c}' data_len={d}", .{
                        kind,
                        clip_msg.data.len,
                    });
                }

                // Update server's clipboard storage
                self.updateIpcClipboardFromBase64(kind, clip_msg.data);

                log.debug("Updated IPC clipboard from client: kind={c}, data_len={d}", .{
                    kind,
                    clip_msg.data.len,
                });
            },
            .copy => |copy_msg| {
                // Client requesting to copy selection to clipboard
                const pane = self.session.getPaneById(copy_msg.paneId) orelse {
                    log.warn("copy for unknown pane {d}", .{copy_msg.paneId});
                    return;
                };

                // Get the selected text from the terminal
                const selected_text = pane.getSelectionText() catch |e| {
                    logRecoverable("get selection text for copy", e);
                    return;
                };

                if (selected_text) |text| {
                    defer pane.allocator.free(text);

                    if (log_config.log_clipboard) {
                        dlog.info("Copy: pane={d} text_len={d}", .{ copy_msg.paneId, text.len });
                    }

                    // Store in ipc_clipboard_c (system clipboard)
                    const text_copy = self.allocator.dupe(u8, text) catch |e| {
                        logRecoverable("allocate clipboard text", e);
                        return;
                    };
                    if (self.ipc_clipboard_c) |old| {
                        self.allocator.free(old);
                    }
                    self.ipc_clipboard_c = text_copy;

                    // Broadcast clipboard SET to all clients
                    const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
                    const base64_data = self.allocator.alloc(u8, encoded_len) catch |e| {
                        logRecoverable("allocate base64 for copy", e);
                        return;
                    };
                    defer self.allocator.free(base64_data);
                    _ = std.base64.standard.Encoder.encode(base64_data, text);

                    const clipboard_msg = snapshot.generateClipboardMessage(
                        self.allocator,
                        copy_msg.paneId,
                        "set",
                        'c',
                        base64_data,
                    ) catch |e| {
                        logRecoverable("generate clipboard message for copy", e);
                        return;
                    };
                    defer self.allocator.free(clipboard_msg);
                    self.wsBroadcastAll(clipboard_msg);

                    log.debug("Copied selection from pane {d}: {d} chars", .{ copy_msg.paneId, text.len });
                } else {
                    log.debug("Copy: no selection in pane {d}", .{copy_msg.paneId});
                }
            },
            .clipboard_paste => |paste_msg| {
                // Client requesting to paste from server clipboard to PTY
                const pane = self.session.getPaneById(paste_msg.paneId) orelse {
                    log.warn("clipboard_paste for unknown pane {d}", .{paste_msg.paneId});
                    return;
                };

                const kind = paste_msg.clipboard; // Already a u8 ('c' or 'p')
                const text = if (kind == 'p') self.ipc_clipboard_p else self.ipc_clipboard_c;

                if (text) |data| {
                    if (log_config.log_clipboard) {
                        dlog.info("Clipboard paste: pane={d} kind='{c}' text_len={d}", .{
                            paste_msg.paneId,
                            kind,
                            data.len,
                        });
                    }

                    // Write to PTY with bracketed paste support
                    if (pane.terminal.modes.get(.bracketed_paste)) {
                        const PASTE_START = "\x1b[200~";
                        const PASTE_END = "\x1b[201~";

                        self.session.logPtySend(pane.id, PASTE_START);
                        self.session.logPtySend(pane.id, data);
                        self.session.logPtySend(pane.id, PASTE_END);

                        pane.writeInput(PASTE_START) catch |e| {
                            logRecoverable("write paste start to PTY", e);
                            return;
                        };
                        pane.writeInput(data) catch |e| {
                            logRecoverable("write clipboard text to PTY", e);
                            return;
                        };
                        pane.writeInput(PASTE_END) catch |e| {
                            logRecoverable("write paste end to PTY", e);
                        };
                    } else {
                        self.session.logPtySend(pane.id, data);
                        pane.writeInput(data) catch |e| {
                            logRecoverable("write clipboard text to PTY", e);
                        };
                    }

                    log.debug("Pasted '{c}' clipboard to pane {d}: {d} chars", .{ kind, paste_msg.paneId, data.len });
                } else {
                    log.debug("Clipboard paste: '{c}' clipboard is empty", .{kind});
                }
            },
            .unknown => {},
        }
    }

    fn handleSyncRequest(self: *EventLoop, client: *ClientState, pane: *Pane, client_gen: u64) !void {
        // If no_delta is set, always send full snapshots for debugging
        if (self.no_delta) {
            const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
            defer pane.allocator.free(snap);
            try client.ws.sendBinary(snap);
            client.setGeneration(pane.id, pane.generation);
            return;
        }

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

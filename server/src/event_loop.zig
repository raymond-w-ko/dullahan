//! Single-threaded event loop for dullahan server
//!
//! Multiplexes IPC, HTTP/WebSocket, and PTY I/O in one poll() loop.
//! Eliminates all threading and synchronization complexity.

const std = @import("std");
const posix = std.posix;
const constants = @import("constants.zig");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const websocket = @import("websocket.zig");
const snapshot = @import("snapshot.zig");
const layout_db = @import("layout_db.zig");
const layout_helpers = @import("layout_helpers.zig");
const message_parsing = @import("message_parsing.zig");
const message_handlers = @import("message_handlers.zig");
const Session = @import("session.zig").Session;
const Pane = @import("pane.zig").Pane;
const signal = @import("signal.zig");
const messages = @import("messages.zig");
const dlog = @import("dlog.zig");
const ipc_commands = @import("ipc_commands.zig");
const ws_proxy = @import("ws_proxy.zig");
const client_state = @import("client_state.zig");
const ClientState = client_state.ClientState;
const theme_db = @import("theme_db.zig");

const log = std.log.scoped(.event_loop);

// Category-scoped debug loggers
const conn_log = dlog.scoped(.connection);
const clip_log = dlog.scoped(.clipboard);
const theme_log = dlog.scoped(.theme);

// Error helpers
fn logRecoverable(comptime context: []const u8, err: anyerror) void {
    log.info("[recoverable] {s}: {any}", .{ context, err });
}

fn logClientError(comptime context: []const u8, err: anyerror) void {
    log.warn("[client] {s}: {any}", .{ context, err });
}

/// Handle write error, setting congestion flag if WouldBlock.
/// Returns true if the error was WouldBlock (client is now congested).
fn handleWriteError(client: *ClientState, comptime context: []const u8, err: anyerror) bool {
    if (err == error.WouldBlock or err == error.WriteBufferFull) {
        if (!client.write_congested) {
            log.debug("Client {s} write congested, pausing updates", .{client.shortId()});
            client.write_congested = true;
        }
        return true;
    }
    logClientError(context, err);
    return false;
}

const ParsedMessage = messages.ParsedMessage;

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    ipc_server: *ipc.Server,
    http_server: *http.Server,
    session: *Session,
    clients: std.ArrayListUnmanaged(ClientState) = .{},
    running: bool = true,
    auth_store: ws_proxy.AuthStore,

    // Server state for IPC commands
    start_time: i64,
    commands_processed: u64 = 0,

    // Master/slave state: only one client can be master at a time
    // Master client can perform privileged operations (resize, create panes, etc.)
    master_id: ?[]const u8 = null,

    // Master's theme colors for OSC 10/11/4 queries
    // Set from theme name lookup (primary) or parsed hex colors (fallback)
    // Contains full theme data: fg, bg, cursor colors, selection colors, and 16-color palette
    master_theme: ?theme_db.ThemeColors = null,

    // Layout database (templates for window creation)
    layouts: layout_db.LayoutDb,

    // IPC clipboard storage (for clipboard-set/clipboard-get testing)
    ipc_clipboard_c: ?[]const u8 = null,
    ipc_clipboard_p: ?[]const u8 = null,

    // Debug: disable delta updates (always send full snapshots)
    no_delta: bool = false,

    // Snapshot of counts used when building current poll set.
    // These are needed because lists can mutate during dispatch.
    last_poll_pending_count: usize = 0,
    last_poll_client_count: usize = 0,

    const IPC_FD_INDEX = 0;
    const HTTP_FD_INDEX = 1;
    const FIXED_FD_COUNT = 2;

    pub fn init(
        allocator: std.mem.Allocator,
        ipc_server: *ipc.Server,
        http_server: *http.Server,
        session: *Session,
        no_delta: bool,
        auth_store: ws_proxy.AuthStore,
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
            .auth_store = auth_store,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        for (self.clients.items) |*client| {
            client.deinit();
        }
        self.clients.deinit(self.allocator);
        self.auth_store.deinit();
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

    // WebSocket proxy methods
    pub fn wsBroadcastAll(self: *EventLoop, msg: []const u8) void {
        ws_proxy.WsProxy.broadcastAll(&self.clients, msg);
    }

    /// Broadcast binary message to all authenticated clients only.
    pub fn wsBroadcast(self: *EventLoop, msg: []const u8) void {
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
                6 => "3x2",
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
            self.http_server.expirePendingConnections();
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

        const pending_count = self.http_server.pendingCount();
        const client_count = self.clients.items.len;
        const total = FIXED_FD_COUNT + pending_count + client_count + pty_count;
        var fds = try self.allocator.alloc(posix.pollfd, total);

        fds[IPC_FD_INDEX] = .{ .fd = self.ipc_server.socket, .events = posix.POLL.IN, .revents = 0 };
        fds[HTTP_FD_INDEX] = .{ .fd = self.http_server.getFd(), .events = posix.POLL.IN, .revents = 0 };

        var idx: usize = FIXED_FD_COUNT;
        self.http_server.fillPendingPollSet(fds, idx);
        idx += pending_count;

        for (self.clients.items) |client| {
            // Add POLLOUT for congested clients so we know when socket is writable
            const events: i16 = if (client.write_congested or client.ws.hasPendingWrite())
                posix.POLL.IN | posix.POLL.OUT
            else
                posix.POLL.IN;
            fds[idx] = .{ .fd = client.ws.getFd(), .events = events, .revents = 0 };
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

        self.last_poll_pending_count = pending_count;
        self.last_poll_client_count = client_count;
        return fds;
    }

    fn dispatchEvents(self: *EventLoop, fds: []posix.pollfd) !void {
        // IMPORTANT: Save the client count that was used when building the poll set.
        // This count must be used for PTY index calculation even if clients are
        // removed during dispatch, because fds indices are fixed at poll time.
        const poll_pending_count = self.last_poll_pending_count;
        const poll_client_count = self.last_poll_client_count;

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

        // Process pending TLS/HTTP upgrade sockets.
        const pending_start_idx = FIXED_FD_COUNT;
        const pending_end_idx = @min(fds.len, pending_start_idx + poll_pending_count);
        if (pending_start_idx < pending_end_idx) {
            self.http_server.processPendingPollEvents(fds[pending_start_idx..pending_end_idx]) catch |e| {
                log.err("HTTP pending processing error: {any}", .{e});
            };
        }
        self.drainReadyWebSockets() catch |e| {
            log.err("HTTP promote error: {any}", .{e});
        };

        // Check clients (iterate backwards to allow removal)
        const client_start_idx = FIXED_FD_COUNT + poll_pending_count;
        var client_idx: usize = poll_client_count;
        while (client_idx > 0) {
            client_idx -= 1;
            const fd_idx = client_start_idx + client_idx;
            const revents = fds[fd_idx].revents;

            if (revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                log.info("Client {d} disconnected (poll error/hangup)", .{client_idx});
                self.removeClient(client_idx);
            } else if (revents & posix.POLL.OUT != 0) {
                // Socket is writable - flush pending writes and resume updates
                if (client_idx < self.clients.items.len) {
                    const client = &self.clients.items[client_idx];
                    var removed = false;
                    const drained = client.ws.flushWriteBuffer() catch |e| blk: {
                        if (!handleWriteError(client, "flush write buffer", e)) {
                            log.info("Disconnecting client {s} after write failure", .{client.shortId()});
                            self.removeClient(client_idx);
                            removed = true;
                        }
                        break :blk false;
                    };
                    if (removed) continue;

                    if (drained) {
                        if (client.write_congested) {
                            log.debug("Client {s} write cleared, resuming updates", .{client.shortId()});
                        }
                        client.write_congested = false;
                        // Send updates for all panes to catch up
                        self.sendClientUpdates(client) catch |e| {
                            if (!handleWriteError(client, "resume updates", e)) {
                                log.info("Disconnecting client {s} after resume failure", .{client.shortId()});
                                self.removeClient(client_idx);
                            }
                        };
                    } else {
                        client.write_congested = true;
                    }
                }
            }
            if (revents & posix.POLL.IN != 0) {
                // Process this client. Keep processing as long as TLS has buffered data.
                // This is critical for TLS: poll() checks the TCP socket, but the TLS
                // library may have already read and decrypted more data than we consumed.
                // Without this loop, buffered data would wait until the next TCP packet.
                var continue_processing = true;
                while (continue_processing) {
                    continue_processing = false;
                    self.handleWsClient(client_idx) catch |e| {
                        if (e == error.ConnectionClosed) {
                            log.info("Client {d} disconnected", .{client_idx});
                            self.removeClient(client_idx);
                            break;
                        } else if (e == error.WouldBlock or e == error.WriteBufferFull) {
                            // No complete frame available yet; keep buffered data and try later.
                            if (e == error.WriteBufferFull and client_idx < self.clients.items.len) {
                                self.clients.items[client_idx].write_congested = true;
                            }
                            log.debug("Client {d} read would-block (incomplete frame)", .{client_idx});
                            break;
                        } else {
                            log.err("Client {d} error: {any}", .{ client_idx, e });
                            self.removeClient(client_idx);
                            break;
                        }
                    };
                    // Check if TLS has more data buffered that poll() wouldn't see
                    if (client_idx < self.clients.items.len) {
                        const client = &self.clients.items[client_idx];
                        if (client.ws.hasPendingData()) {
                            continue_processing = true;
                        }
                    }
                }
            }
        }

        // Check PTYs - use poll_client_count (not current clients.items.len)
        // because fds array was built with that count
        const pty_start_idx = client_start_idx + poll_client_count;
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

                    if (revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                        log.info("PTY hangup/error for pane {d}", .{pane.id});
                        self.respawnPaneShellIfExited(pane, "poll hangup/error");
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
            self.wsBroadcast(broadcast_msg);
        }

        return result.response;
    }

    fn handleHttpAccept(self: *EventLoop) !void {
        try self.http_server.enqueueAcceptedConnections();
    }

    fn drainReadyWebSockets(self: *EventLoop) !void {
        while (self.http_server.takeReadyWebSocket()) |ws_conn| {
            var owned_ws = ws_conn;
            errdefer owned_ws.deinit();

            var client = ClientState.init(self.allocator, owned_ws);
            client.ws.setTimeouts(0);
            try self.clients.append(self.allocator, client);
            conn_log.info("Client connected, total: {d}", .{self.clients.items.len});
        }
    }

    fn handleWsClient(self: *EventLoop, client_idx: usize) !void {
        var client = &self.clients.items[client_idx];
        const frame = try client.ws.readFrame();
        defer self.allocator.free(frame.payload);

        switch (frame.opcode) {
            .text => {
                if (message_parsing.parseJsonMessage(self.allocator, frame.payload)) |result| {
                    var cleanup = result.cleanup;
                    defer cleanup.deinit();
                    if (!client.authenticated and result.msg != .hello) return;
                    try self.handleParsedMessage(result.msg, client);
                    try self.sendClientUpdates(client);
                }
            },
            .binary => {
                if (message_parsing.parseMsgpackMessage(self.allocator, frame.payload)) |result| {
                    defer result.payload.free(self.allocator);
                    if (!client.authenticated and result.msg != .hello) return;
                    try self.handleParsedMessage(result.msg, client);
                    try self.sendClientUpdates(client);
                }
            },
            .ping => client.ws.sendPong(frame.payload) catch {},
            .pong => {},
            .close => {
                client.ws.sendClose() catch {};
                return error.ConnectionClosed;
            },
            else => {},
        }
    }

    fn respawnPaneShellIfExited(self: *EventLoop, pane: *Pane, comptime reason: []const u8) void {
        _ = self;
        const restarted = pane.respawnShellIfExited() catch |e| {
            log.err("Failed to respawn pane {d} shell after {s}: {any}", .{ pane.id, reason, e });
            return;
        };
        if (restarted) {
            log.info("Respawned pane {d} shell after {s}", .{ pane.id, reason });
        }
    }

    fn handlePtyData(self: *EventLoop, pane: *Pane) !void {
        var buf: [constants.buffer.general]u8 = undefined;
        const pty = &(pane.pty orelse return);

        const n = pty.read(&buf) catch |e| {
            if (e == error.WouldBlock) return;
            if (e == error.InputOutput or e == error.BrokenPipe) {
                self.respawnPaneShellIfExited(pane, "pty read error");
                return;
            }
            return e;
        };
        if (n == 0) {
            self.respawnPaneShellIfExited(pane, "pty EOF");
            return;
        }

        self.session.logPtyRecv(pane.id, buf[0..n]);
        try pane.feed(buf[0..n]);

        const sync_just_ended = pane.checkSyncModeTransition();
        self.handlePaneClipboard(pane);
        self.handlePaneShellIntegration(pane);

        if (!pane.sync_output_enabled or sync_just_ended) {
            const debug_pane = self.session.getDebugPane();
            for (self.clients.items) |*client| {
                self.sendPaneUpdate(client, pane) catch |e| {
                    _ = handleWriteError(client, "send pane update", e);
                };
                if (debug_pane) |dp| {
                    if (dp.id != pane.id) {
                        self.sendPaneUpdate(client, dp) catch |e| {
                            _ = handleWriteError(client, "send debug update", e);
                        };
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
        log.info("Client disconnected: {s}, total clients: {d}", .{ client.shortId(), self.clients.items.len });
        conn_log.info("Client disconnected: {s}, total clients: {d}", .{ client.shortId(), self.clients.items.len });
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
        self.wsBroadcast(msg);
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
    /// Called when master client sends hello with theme info.
    ///
    /// Priority order:
    /// 1. Theme name lookup (server-side database) - eliminates race conditions
    /// 2. Hex color fallback (for custom themes not in database)
    /// 3. Default colors (if all else fails)
    pub fn setMasterTheme(
        self: *EventLoop,
        theme_name: ?[]const u8,
        fallback_fg: ?[]const u8,
        fallback_bg: ?[]const u8,
    ) void {
        // Try theme name lookup first (primary method)
        if (theme_name) |name| {
            if (theme_db.get(name)) |theme| {
                self.master_theme = theme;
                theme_log.info("Theme from name lookup: '{s}' fg=#{x:0>2}{x:0>2}{x:0>2} bg=#{x:0>2}{x:0>2}{x:0>2}", .{
                    name,
                    theme.fg[0],
                    theme.fg[1],
                    theme.fg[2],
                    theme.bg[0],
                    theme.bg[1],
                    theme.bg[2],
                });
                self.updatePaneThemeColors();
                return;
            }
            theme_log.info("Theme '{s}' not found in database, using fallback colors", .{name});
        }

        // Fall back to parsed hex colors (custom themes)
        if (fallback_fg != null or fallback_bg != null) {
            const fg = if (fallback_fg) |f| parseHexColor(f) else null;
            const bg = if (fallback_bg) |b| parseHexColor(b) else null;
            self.master_theme = theme_db.ThemeColors.fromFallback(fg, bg);

            if (fg) |f| {
                theme_log.info("Theme fg from CSS fallback: #{x:0>2}{x:0>2}{x:0>2}", .{ f[0], f[1], f[2] });
            }
            if (bg) |b| {
                theme_log.info("Theme bg from CSS fallback: #{x:0>2}{x:0>2}{x:0>2}", .{ b[0], b[1], b[2] });
            }
        } else {
            // No theme info at all - clear the theme
            self.master_theme = null;
            theme_log.info("No theme info provided, using terminal defaults", .{});
        }

        self.updatePaneThemeColors();
    }

    /// Update all panes with current master theme colors.
    /// Update all panes with current master theme colors.
    fn updatePaneThemeColors(self: *EventLoop) void {
        // Extract fg/bg from master_theme (full palette support can be added later)
        const fg: ?[3]u8 = if (self.master_theme) |t| t.fg else null;
        const bg: ?[3]u8 = if (self.master_theme) |t| t.bg else null;

        var pane_iter = self.session.pane_registry.panes.valueIterator();
        while (pane_iter.next()) |pane_ptr| {
            pane_ptr.*.setThemeColors(fg, bg);
        }
    }

    /// Broadcast layout message to all connected clients
    pub fn broadcastLayout(self: *EventLoop) !void {
        const msg = try snapshot.generateLayoutMessage(self.allocator, self.session, &self.layouts);
        defer self.allocator.free(msg);
        self.wsBroadcast(msg);
    }

    /// Broadcast pane update (snapshot/delta) to all connected clients.
    /// Used for selection changes and other immediate updates.
    pub fn broadcastPaneUpdate(self: *EventLoop, pane: *Pane) !void {
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
        if (!client.authenticated) return;

        // Skip congested clients - they'll get updates when socket becomes writable
        if (client.write_congested or client.ws.hasPendingWrite()) {
            client.write_congested = true;
            return;
        }

        const pane_id = pane.id;
        const last_gen = client.getGeneration(pane_id);
        if (pane.generation == last_gen) return;

        // Check for title change on any pane
        if (pane.hasTitleChanged()) {
            if (pane.getTitle()) |title| {
                const msg = try snapshot.generateTitleMessage(pane.allocator, pane_id, title);
                defer pane.allocator.free(msg);
                try client.ws.sendBinary(msg);
                if (client.ws.hasPendingWrite()) {
                    client.write_congested = true;
                    return;
                }
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
                if (client.ws.hasPendingWrite()) {
                    client.write_congested = true;
                    return;
                }
                pane.clearBell();
            }
        }

        // Check for toast notification (OSC 9/777)
        if (pane.hasNotification()) {
            if (pane.getNotification()) |notif| {
                const msg = try snapshot.generateToastMessage(pane.allocator, pane_id, notif.title, notif.body);
                defer pane.allocator.free(msg);
                try client.ws.sendBinary(msg);
                if (client.ws.hasPendingWrite()) {
                    client.write_congested = true;
                    return;
                }
            }
            pane.clearNotification();
        }

        // Check for progress update (OSC 9;4)
        if (pane.hasProgressChanged()) {
            const progress = pane.getProgress();
            const msg = try snapshot.generateProgressMessage(pane.allocator, pane_id, progress.state, progress.value);
            defer pane.allocator.free(msg);
            try client.ws.sendBinary(msg);
            if (client.ws.hasPendingWrite()) {
                client.write_congested = true;
                return;
            }
            pane.clearProgressChanged();
        }

        // Note: Clipboard SET/GET operations are handled in broadcastPaneUpdate()
        // to ensure all clients receive them before the state is cleared.

        // If no_delta is set, always send full snapshots for debugging
        if (self.no_delta) {
            const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
            defer pane.allocator.free(snap);
            try client.ws.sendBinary(snap);
            if (client.ws.hasPendingWrite()) {
                client.write_congested = true;
                return;
            }
            client.setGeneration(pane_id, pane.generation);
            return;
        }

        const result = try pane.getBroadcastDelta();
        defer pane.allocator.free(result.delta);

        if (last_gen == result.from_gen) {
            // Client can apply this delta
            try client.ws.sendBinary(result.delta);

            if (client.ws.hasPendingWrite()) {
                client.write_congested = true;
                return;
            }
            client.setGeneration(pane_id, pane.generation);
        } else {
            // Client can't apply delta (generation mismatch).
            // Send full snapshot to resync immediately.
            log.debug("Pane {d}: client gen {d} != delta from_gen {d}, sending snapshot to resync", .{
                pane_id, last_gen, result.from_gen,
            });
            const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
            defer pane.allocator.free(snap);
            try client.ws.sendBinary(snap);
            if (client.ws.hasPendingWrite()) {
                client.write_congested = true;
                return;
            }
            client.setGeneration(pane_id, pane.generation);
        }
    }

    pub fn sendSnapshot(self: *EventLoop, ws: *websocket.Connection, pane: *Pane) !void {
        _ = self;
        const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
        defer pane.allocator.free(snap);
        try ws.sendBinary(snap);
    }

    /// Send initial state (snapshots + layout + master) to a freshly authenticated client.
    pub fn sendInitialState(self: *EventLoop, client: *ClientState) !void {
        // Send initial snapshots for all panes
        var pane_it = self.session.pane_registry.iterator();
        while (pane_it.next()) |pane_ptr| {
            const pane = pane_ptr.*;
            try self.sendSnapshot(&client.ws, pane);
            client.setGeneration(pane.id, pane.generation);
        }

        // Send layout message
        const layout_msg = try snapshot.generateLayoutMessage(self.allocator, self.session, &self.layouts);
        defer self.allocator.free(layout_msg);
        try self.wsSendUnchecked(client, layout_msg);

        // Send current master state
        const master_msg = try snapshot.generateMasterChangedMessage(self.allocator, self.master_id);
        defer self.allocator.free(master_msg);
        try self.wsSendUnchecked(client, master_msg);
    }

    /// Send current IPC clipboard state to a client.
    /// Called when a client first connects (after hello) to sync clipboard state.
    pub fn sendIpcClipboardState(self: *EventLoop, client: *ClientState) !void {
        // Send both clipboard types if set
        const clipboards = [_]struct { kind: u8, text: ?[]const u8 }{
            .{ .kind = 'c', .text = self.ipc_clipboard_c },
            .{ .kind = 'p', .text = self.ipc_clipboard_p },
        };
        for (clipboards) |cb| {
            if (cb.text) |text| {
                const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
                const base64_data = try self.allocator.alloc(u8, encoded_len);
                defer self.allocator.free(base64_data);
                _ = std.base64.standard.Encoder.encode(base64_data, text);

                const msg = try snapshot.generateClipboardMessage(self.allocator, 0, "set", cb.kind, base64_data);
                defer self.allocator.free(msg);

                try client.ws.sendBinary(msg);
                clip_log.info("Sent IPC clipboard '{c}' to new client: {d} bytes", .{ cb.kind, text.len });
            }
        }
    }

    /// Update IPC clipboard storage from base64-encoded data.
    /// Called when OSC 52 SET is received from a pane.
    pub fn updateIpcClipboardFromBase64(self: *EventLoop, kind: u8, base64_data: []const u8) void {
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
    pub fn updatePrimaryClipboardFromSelection(self: *EventLoop, pane: *Pane) void {
        // Get the selected text from the terminal
        const selected_text = pane.getSelectionText() catch |e| {
            logRecoverable("get selection text for primary clipboard", e);
            return;
        };

        if (selected_text) |text| {
            defer pane.allocator.free(text);

            clip_log.info("Selection → primary: pane={d} text_len={d}", .{ pane.id, text.len });

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
            self.wsBroadcast(msg);

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
                clip_log.info("Clipboard SET: pane={d} kind='{c}' data_len={d}", .{ pane_id, op.kind, op.data.len });

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
                self.wsBroadcast(msg);
            }
            pane.clearClipboardSet();
        }

        // Handle clipboard GET request - send to master client only
        if (pane.needsClipboardGetSend()) {
            if (pane.getClipboardGetKind()) |kind| {
                clip_log.info("Clipboard GET request: pane={d} kind='{c}'", .{ pane_id, kind });

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
            clip_log.warn("Clipboard GET timeout: pane={d}", .{pane_id});
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
        self.wsBroadcast(msg);

        pane.clearShellEvent();
    }

    // Message handler delegation
    fn handleParsedMessage(self: *EventLoop, msg: ParsedMessage, client: *ClientState) !void {
        try message_handlers.handleParsedMessage(self, msg, client);
    }

    pub fn handleSyncRequest(self: *EventLoop, client: *ClientState, pane: *Pane, client_gen: u64, client_min_row_id: u64) !void {
        // If no_delta is set, always send full snapshots for debugging
        if (self.no_delta) {
            const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
            defer pane.allocator.free(snap);
            try client.ws.sendBinary(snap);
            client.setGeneration(pane.id, pane.generation);
            return;
        }

        // Check if client's cache is too stale for the current viewport.
        // If client's minimum cached row ID is higher than the viewport's minimum,
        // the client has evicted rows we need to reference - send full snapshot.
        if (client_min_row_id > 0) {
            const viewport_min_row_id = pane.getMinVisibleRowId();
            if (client_min_row_id > viewport_min_row_id) {
                log.debug("Client cache stale: client_min={d} > viewport_min={d}, sending snapshot", .{
                    client_min_row_id,
                    viewport_min_row_id,
                });
                const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
                defer pane.allocator.free(snap);
                try client.ws.sendBinary(snap);
                client.setGeneration(pane.id, pane.generation);
                return;
            }
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

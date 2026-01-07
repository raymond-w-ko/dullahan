//! Single-threaded event loop for dullahan server
//!
//! Multiplexes IPC, HTTP/WebSocket, and PTY I/O in one poll() loop.
//! Eliminates all threading and synchronization complexity.

const std = @import("std");
const posix = std.posix;
const msgpack = @import("msgpack");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const websocket = @import("websocket.zig");
const snapshot = @import("snapshot.zig");
const Session = @import("session.zig").Session;
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const signal = @import("signal.zig");

const log = std.log.scoped(.event_loop);

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

const MessageType = struct {
    type: []const u8,
};

// ============================================================================
// Client State
// ============================================================================

pub const ClientState = struct {
    ws: websocket.Connection,
    pane_generations: std.AutoHashMap(u16, u64),
    connected: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ws: websocket.Connection) ClientState {
        return .{
            .ws = ws,
            .pane_generations = std.AutoHashMap(u16, u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClientState) void {
        self.pane_generations.deinit();
        self.ws.close();
        self.connected = false;
    }

    pub fn getGeneration(self: *ClientState, pane_id: u16) u64 {
        return self.pane_generations.get(pane_id) orelse 0;
    }

    pub fn setGeneration(self: *ClientState, pane_id: u16, gen: u64) void {
        self.pane_generations.put(pane_id, gen) catch {};
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

    const IPC_FD_INDEX = 0;
    const HTTP_FD_INDEX = 1;
    const FIXED_FD_COUNT = 2;

    pub fn init(
        allocator: std.mem.Allocator,
        ipc_server: *ipc.Server,
        http_server: *http.Server,
        session: *Session,
    ) EventLoop {
        return .{
            .allocator = allocator,
            .ipc_server = ipc_server,
            .http_server = http_server,
            .session = session,
            .start_time = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        for (self.clients.items) |*client| {
            client.deinit();
        }
        self.clients.deinit(self.allocator);
    }

    pub fn uptime(self: *const EventLoop) i64 {
        return std.time.timestamp() - self.start_time;
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
        var pty_count: usize = 0;
        var window_it = self.session.windows.valueIterator();
        while (window_it.next()) |window| {
            var pane_it = window.panes.valueIterator();
            while (pane_it.next()) |pane| {
                if (pane.getPtyFd() != null) {
                    pty_count += 1;
                }
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

        var window_it2 = self.session.windows.valueIterator();
        while (window_it2.next()) |window| {
            var pane_it = window.panes.valueIterator();
            while (pane_it.next()) |pane| {
                if (pane.getPtyFd()) |fd| {
                    fds[idx] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
                    idx += 1;
                }
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
        var window_it = self.session.windows.valueIterator();
        while (window_it.next()) |window| {
            var pane_it = window.panes.valueIterator();
            while (pane_it.next()) |pane| {
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

            const response = self.handleCommand(cmd_result.command, arena_alloc) catch |e| blk: {
                log.err("Command error: {any}", .{e});
                break :blk ipc.Response.err("Internal error");
            };

            self.ipc_server.sendResponse(cmd_result.conn, response, arena_alloc) catch |e| {
                log.err("Send error: {any}", .{e});
            };
        }
    }

    fn handleCommand(self: *EventLoop, command: ipc.Command, alloc: std.mem.Allocator) !ipc.Response {
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

                const data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Server status", data);
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
                const data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Help", data);
            },

            .dump => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);

                const up = self.uptime();
                try writer.print("Server: up={d}s cmds={d}\n", .{ up, self.commands_processed });
                try self.session.dump(writer);

                const data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("State dump", data);
            },

            .@"dump-raw" => blk: {
                const pane = self.session.activePane() orelse
                    break :blk ipc.Response.err("No active pane");

                var buf: std.ArrayListUnmanaged(u8) = .{};
                const writer = buf.writer(alloc);
                try pane.dumpRaw(writer);

                const data = try buf.toOwnedSlice(alloc);
                break :blk ipc.Response.okWithData("Raw cell dump", data);
            },

            .@"debug-capture" => blk: {
                const pane = self.session.activePane() orelse
                    break :blk ipc.Response.err("No active pane");

                const capture_path = "/tmp/dullahan-capture.hex";

                pane.startCapture(capture_path) catch |e| {
                    var errbuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&errbuf, "Failed to start capture: {any}", .{e}) catch "Failed to start capture";
                    break :blk ipc.Response.err(msg);
                };

                pane.writeInput("claude\n") catch {};
                std.Thread.sleep(500 * std.time.ns_per_ms);
                pane.stopCapture();

                break :blk ipc.Response.okWithData("Capture started", "Sent 'claude\\n'. Run 'dump-raw' to see terminal state, check /tmp/dullahan-capture.hex for hex dump.");
            },
        };
    }

    fn handleHttpAccept(self: *EventLoop) !void {
        const ws_conn = try self.http_server.acceptWebSocket();
        if (ws_conn == null) return;

        var client = ClientState.init(self.allocator, ws_conn.?);

        const window = self.session.activeWindow() orelse return;
        log.info("Sending initial snapshots for {d} panes", .{window.paneCount()});
        var pane_it = window.panes.valueIterator();
        while (pane_it.next()) |pane| {
            log.info("Sending snapshot for pane {d}, gen={d}", .{ pane.id, pane.generation });
            self.sendSnapshot(&client.ws, pane) catch |e| {
                log.err("Failed to send initial snapshot for pane {d}: {any}", .{ pane.id, e });
                client.deinit();
                return;
            };
            // Don't call clearDirtyRows() here - initial snapshot sends full state,
            // and clearing would reset dirty_base_gen which affects broadcast deltas
            // for other clients or subsequent updates
            client.setGeneration(pane.id, pane.generation);
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
                try self.handleClientMessage(frame.payload, client);
                try self.sendClientUpdates(client);
            },
            .binary => {
                try self.handleBinaryMessage(frame.payload, client);
                try self.sendClientUpdates(client);
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
        var buf: [4096]u8 = undefined;

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
                        log.err("Failed to send update to client: {any}", .{e});
                    };
                    if (debug_pane) |dp| {
                        if (dp.id != pane.id) { // Don't send twice if this IS the debug pane
                            self.sendPaneUpdate(client, dp) catch |e| {
                                log.err("Failed to send debug pane update: {any}", .{e});
                            };
                        }
                    }
                }
            }
        }
    }

    fn removeClient(self: *EventLoop, idx: usize) void {
        var client = self.clients.orderedRemove(idx);
        client.deinit();
        log.info("Client removed, total clients: {d}", .{self.clients.items.len});
    }

    fn sendClientUpdates(self: *EventLoop, client: *ClientState) !void {
        const window = self.session.activeWindow() orelse return;
        var it = window.panes.valueIterator();
        while (it.next()) |pane| {
            try self.sendPaneUpdate(client, pane);
        }
    }

    fn sendPaneUpdate(self: *EventLoop, client: *ClientState, pane: *Pane) !void {
        const pane_id = pane.id;
        const last_gen = client.getGeneration(pane_id);
        if (pane.generation == last_gen) return;

        // Check if this is the active pane by looking at the session's active window
        const window = self.session.activeWindow();
        const is_active = window != null and pane_id == window.?.active_pane_id;
        if (is_active) {
            if (pane.hasTitleChanged()) {
                if (pane.getTitle()) |title| {
                    const msg = try snapshot.generateTitleMessage(pane.allocator, title);
                    defer pane.allocator.free(msg);
                    try client.ws.sendBinary(msg);
                }
                pane.clearTitleChanged();
            }

            if (pane.hasBell()) {
                const msg = try snapshot.generateBellMessage(pane.allocator);
                defer pane.allocator.free(msg);
                try client.ws.sendBinary(msg);
                pane.clearBell();
            }
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

    fn handleClientMessage(self: *EventLoop, data: []const u8, client: *ClientState) !void {
        const msg_type = std.json.parseFromSlice(MessageType, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch |e| {
            log.warn("Failed to parse message type: {any}", .{e});
            return;
        };
        defer msg_type.deinit();

        const type_str = msg_type.value.type;

        if (std.mem.eql(u8, type_str, "key")) {
            const key_event = std.json.parseFromSlice(KeyEvent, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer key_event.deinit();

            const pane = self.session.activePane() orelse return;
            var output_buf: [32]u8 = undefined;
            const cursor_key_app = pane.isCursorKeyApplication();
            const output = keyEventToBytes(key_event.value, &output_buf, cursor_key_app);

            if (output.len > 0) {
                self.session.logPtySend(pane.id, output);
                pane.writeInput(output) catch |e| {
                    log.err("Failed to write key to PTY: {any}", .{e});
                };
            }
        } else if (std.mem.eql(u8, type_str, "text")) {
            const text_msg = std.json.parseFromSlice(TextMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer text_msg.deinit();

            const pane = self.session.activePane() orelse return;
            self.session.logPtySend(pane.id, text_msg.value.data);
            pane.writeInput(text_msg.value.data) catch |e| {
                log.err("Failed to write text to PTY: {any}", .{e});
            };
        } else if (std.mem.eql(u8, type_str, "resize")) {
            const resize_msg = std.json.parseFromSlice(ResizeMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer resize_msg.deinit();

            const cols = resize_msg.value.cols;
            const rows = resize_msg.value.rows;

            if (cols < 1 or cols > 500 or rows < 1 or rows > 500) return;

            // Resize all panes, not just active (debug pane needs resize too)
            const window = self.session.activeWindow() orelse return;
            var pane_it = window.panes.valueIterator();
            while (pane_it.next()) |pane| {
                try pane.resize(cols, rows);
            }
        } else if (std.mem.eql(u8, type_str, "scroll")) {
            const scroll_msg = std.json.parseFromSlice(ScrollMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer scroll_msg.deinit();

            const pane = self.session.activePane() orelse return;
            pane.scroll(scroll_msg.value.delta);
        } else if (std.mem.eql(u8, type_str, "ping")) {
            const pong = try snapshot.generateBinaryPong(self.allocator);
            defer self.allocator.free(pong);
            try client.ws.sendBinary(pong);
        } else if (std.mem.eql(u8, type_str, "sync")) {
            const sync_msg = std.json.parseFromSlice(SyncMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer sync_msg.deinit();

            const pane = self.session.activePane() orelse return;
            try self.handleSyncRequest(client, pane, sync_msg.value.gen);
        } else if (std.mem.eql(u8, type_str, "focus")) {
            const focus_msg = std.json.parseFromSlice(FocusMessage, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer focus_msg.deinit();

            const window = self.session.activeWindow() orelse return;
            if (window.setActivePane(focus_msg.value.paneId)) {
                log.info("Switched to pane {d}", .{focus_msg.value.paneId});
            }
        }
    }

    fn handleBinaryMessage(self: *EventLoop, data: []const u8, client: *ClientState) !void {
        var buffer: [4096]u8 = undefined;
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

        const payload = packer.read(self.allocator) catch |e| {
            log.warn("Failed to parse msgpack: {any}", .{e});
            return;
        };
        defer payload.free(self.allocator);

        const type_payload = payload.mapGet("type") catch return orelse return;
        const type_str = type_payload.asStr() catch return;

        if (std.mem.eql(u8, type_str, "key")) {
            const pane = self.session.activePane() orelse return;

            const key_payload = (payload.mapGet("key") catch return) orelse return;
            const key = key_payload.asStr() catch return;

            const state_payload = (payload.mapGet("state") catch return) orelse return;
            const state = state_payload.asStr() catch return;

            if (!std.mem.eql(u8, state, "down")) return;

            const ctrl = if (payload.mapGet("ctrl") catch null) |p| (p.asBool() catch false) else false;
            const alt = if (payload.mapGet("alt") catch null) |p| (p.asBool() catch false) else false;
            const shift = if (payload.mapGet("shift") catch null) |p| (p.asBool() catch false) else false;

            var output_buf: [32]u8 = undefined;
            const event = KeyEvent{
                .type = "key",
                .key = key,
                .code = "",
                .state = state,
                .ctrl = ctrl,
                .alt = alt,
                .shift = shift,
            };
            const cursor_key_app = pane.isCursorKeyApplication();
            const output = keyEventToBytes(event, &output_buf, cursor_key_app);

            if (output.len > 0) {
                self.session.logPtySend(pane.id, output);
                pane.writeInput(output) catch |e| {
                    log.err("Failed to write key to PTY: {any}", .{e});
                };
            }
        } else if (std.mem.eql(u8, type_str, "text")) {
            const pane = self.session.activePane() orelse return;
            const data_payload = (payload.mapGet("data") catch return) orelse return;
            const text = data_payload.asStr() catch return;

            self.session.logPtySend(pane.id, text);
            pane.writeInput(text) catch |e| {
                log.err("Failed to write text to PTY: {any}", .{e});
            };
        } else if (std.mem.eql(u8, type_str, "resize")) {
            const cols_payload = (payload.mapGet("cols") catch return) orelse return;
            const rows_payload = (payload.mapGet("rows") catch return) orelse return;
            const cols: u16 = @intCast(cols_payload.getUint() catch return);
            const rows: u16 = @intCast(rows_payload.getUint() catch return);
            // Resize all panes, not just active (debug pane needs resize too)
            const window = self.session.activeWindow() orelse return;
            var pane_it = window.panes.valueIterator();
            while (pane_it.next()) |pane| {
                try pane.resize(cols, rows);
            }
        } else if (std.mem.eql(u8, type_str, "scroll")) {
            const pane = self.session.activePane() orelse return;
            const delta_payload = (payload.mapGet("delta") catch return) orelse return;
            const delta: i32 = @intCast(delta_payload.getInt() catch return);
            pane.scroll(delta);
        } else if (std.mem.eql(u8, type_str, "ping")) {
            const pong = try snapshot.generateBinaryPong(self.allocator);
            defer self.allocator.free(pong);
            try client.ws.sendBinary(pong);
        } else if (std.mem.eql(u8, type_str, "focus")) {
            const pane_id_payload = (payload.mapGet("paneId") catch return) orelse return;
            const pane_id: u16 = @intCast(pane_id_payload.getUint() catch return);
            const window = self.session.activeWindow() orelse return;
            if (window.setActivePane(pane_id)) {
                log.info("Switched to pane {d}", .{pane_id});
            }
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

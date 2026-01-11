//! Dullahan server
//!
//! Single-threaded server using event loop for all I/O.

const std = @import("std");
const ipc = @import("ipc.zig");
const paths = @import("paths.zig");
const Session = @import("session.zig").Session;
const PaneRegistry = @import("pane_registry.zig").PaneRegistry;
const http = @import("http.zig");
const signal = @import("signal.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const dlog = @import("dlog.zig");

const log = std.log.scoped(.server);

pub const RunConfig = struct {
    ipc: ipc.Config = .{},
    static_dir: ?[]const u8 = null,
    ws_port: u16 = http.DEFAULT_PORT,

    /// Get static_dir with fallback to ./client if it exists
    pub fn getStaticDir(self: RunConfig) ?[]const u8 {
        if (self.static_dir) |dir| return dir;

        // Check if ./client exists
        std.fs.cwd().access("client", .{}) catch return null;
        return "client";
    }
};

pub fn run(allocator: std.mem.Allocator, config: RunConfig) !void {
    // Install signal handlers first
    signal.install();
    defer signal.reset();

    // Create global pane registry
    var pane_registry = PaneRegistry.init(allocator, .{});
    defer pane_registry.deinit();

    // Create session with registry pointer
    var session = try Session.init(allocator, &pane_registry, .{});
    defer session.deinit();

    // Create initial window with debug pane + 2 shell panes
    // This uses the reusable createWindowWithPanes() method
    const initial = try session.createWindowWithPanes();
    log.info("Created window {d} with panes: debug={d}, shell1={d}, shell2={d}", .{
        initial.window_id,
        initial.debug_pane_id,
        initial.shell1_pane_id,
        initial.shell2_pane_id,
    });

    // Initialize debug pane with welcome message and set up unified logging
    if (pane_registry.get(initial.debug_pane_id)) |debug_pane| {
        // Set debug pane for unified logging (file + console + stderr)
        dlog.setDebugPane(debug_pane);

        try debug_pane.feedDirect("\x1b[1;36m=== Dullahan Debug Console ===\x1b[0m\r\n");
        try debug_pane.feedDirect("Server logs and messages appear here.\r\n");
        try debug_pane.feedDirect("PTY traffic logging: use 'dullahan pty-log-on' to enable\r\n\r\n");

        dlog.info("Debug console initialized", .{});
    }

    var ipc_server = ipc.Server.init(config.ipc) catch |e| {
        if (e == error.AddressInUse) {
            log.err("IPC socket {s} is already in use. Another server may be running.", .{config.ipc.getSocketPath()});
            std.debug.print("Error: IPC socket already in use. Is another dullahan running?\n", .{});
        } else {
            log.err("Failed to start IPC server: {any}", .{e});
            std.debug.print("Error: Failed to start IPC server: {any}\n", .{e});
        }
        return e;
    };
    defer ipc_server.deinit();

    // Write PID file
    try ipc_server.writePidFile();

    // Initialize HTTP server for WebSocket
    const static_dir = config.getStaticDir();
    var http_server = http.Server.init(allocator, config.ws_port, static_dir) catch |e| {
        if (e == error.AddressInUse) {
            log.err("Port {d} is already in use. Another server may be running.", .{config.ws_port});
            std.debug.print("Error: Port {d} is already in use. Is another dullahan or ttyd running?\n", .{config.ws_port});
        } else {
            log.err("Failed to start HTTP server: {any}", .{e});
            std.debug.print("Error: Failed to start HTTP server: {any}\n", .{e});
        }
        return e;
    };
    defer http_server.deinit();

    // Initialize event loop
    var event_loop = EventLoop.init(allocator, &ipc_server, &http_server, &session);
    defer event_loop.deinit();

    // Note: Shells are already spawned by createWindowWithPanes() -> createShellPane()

    log.info("dullahan server started (socket: {s}, ws: port {d}) [single-threaded]", .{ config.ipc.getSocketPath(), config.ws_port });
    std.debug.print("dullahan server started (socket: {s}, ws: port {d}) [single-threaded]\n", .{ config.ipc.getSocketPath(), config.ws_port });
    if (static_dir) |dir| {
        std.debug.print("Serving static files from: {s}\n", .{dir});
    }
    std.debug.print("Press Ctrl+C to shutdown\n", .{});

    // Run the single-threaded event loop
    event_loop.run() catch |e| {
        log.err("Event loop error: {any}", .{e});
    };

    // Log why we're shutting down
    if (signal.isShutdownRequested()) {
        log.info("Received shutdown signal", .{});
        std.debug.print("\nReceived shutdown signal, cleaning up...\n", .{});
    }

    log.info("dullahan server shutting down", .{});
    std.debug.print("dullahan server shutting down\n", .{});
}

test "basic server test" {
    // Just verify imports work
    _ = EventLoop;
}

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
const pty_log = @import("pty_log.zig");
const tailscale = @import("tailscale.zig");
const tls_wrapper = @import("tls_wrapper.zig");

const log = std.log.scoped(.server);

pub const RunConfig = struct {
    ipc: ipc.Config = .{},
    static_dir: ?[]const u8 = null,
    ws_port: u16 = http.DEFAULT_PORT,
    pty_log: bool = false,
    no_delta: bool = false,
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,

    /// Get static_dir with fallback to ./client if it exists
    pub fn getStaticDir(self: RunConfig) ?[]const u8 {
        if (self.static_dir) |dir| return dir;

        // Check if ./client exists
        std.fs.cwd().access("client", .{}) catch return null;
        return "client";
    }

    /// Check if TLS is enabled (both cert and key provided)
    pub fn isTlsEnabled(self: RunConfig) bool {
        return self.tls_cert != null and self.tls_key != null;
    }
};

pub fn run(allocator: std.mem.Allocator, config: RunConfig) !void {
    // Install signal handlers first
    signal.install();
    defer signal.reset();

    // Enable PTY logging if requested (truncates existing log file)
    if (config.pty_log) {
        pty_log.setEnabled(true);
    }

    // Create global pane registry
    var pane_registry = PaneRegistry.init(allocator, .{});
    defer pane_registry.deinit();

    // Create session with registry pointer
    var session = try Session.init(allocator, &pane_registry, .{});
    defer session.deinit();

    // Create initial window with debug pane + 3 shell panes (2x2 grid)
    // This uses the reusable createWindowWithPanes() method
    const initial = try session.createWindowWithPanes();
    log.info("Created window {d} with panes: debug={d}, shell1={d}, shell2={d}, shell3={d}", .{
        initial.window_id,
        initial.debug_pane_id,
        initial.shell1_pane_id,
        initial.shell2_pane_id,
        initial.shell3_pane_id,
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

    // Detect Tailscale for remote access
    var tailscale_info = tailscale.detect(allocator);
    defer if (tailscale_info) |*info| info.deinit();

    const bind_all = tailscale_info != null;

    // Initialize TLS context if certificates provided
    var tls_context: ?tls_wrapper.TlsContext = null;
    if (config.isTlsEnabled()) {
        // Validate that both cert and key are provided
        const cert_path = config.tls_cert.?;
        const key_path = config.tls_key.?;

        tls_context = tls_wrapper.TlsContext.init(allocator, .{
            .cert_path = cert_path,
            .key_path = key_path,
        }) catch |e| {
            log.err("Failed to initialize TLS: {}", .{e});
            std.debug.print("Error: Failed to initialize TLS: {}\n", .{e});
            std.debug.print("  Certificate: {s}\n", .{cert_path});
            std.debug.print("  Key: {s}\n", .{key_path});
            return e;
        };
    }
    defer if (tls_context) |*ctx| ctx.deinit();

    // Initialize HTTP server for WebSocket
    const static_dir = config.getStaticDir();
    const tls_ctx_ptr: ?*tls_wrapper.TlsContext = if (tls_context != null) &tls_context.? else null;
    var http_server = http.Server.init(allocator, config.ws_port, static_dir, bind_all, tls_ctx_ptr) catch |e| {
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
    var event_loop = EventLoop.init(allocator, &ipc_server, &http_server, &session, config.no_delta);
    defer event_loop.deinit();

    // Assign layouts to windows created before event loop
    event_loop.assignLayoutsToExistingWindows();

    // Note: Shells are already spawned by createWindowWithPanes() -> createShellPane()

    const protocol = if (config.isTlsEnabled()) "https" else "http";
    log.info("dullahan server started (socket: {s}, ws: port {d}, tls: {}) [single-threaded]", .{ config.ipc.getSocketPath(), config.ws_port, config.isTlsEnabled() });
    std.debug.print("dullahan server started\n", .{});
    std.debug.print("  IPC socket: {s}\n", .{config.ipc.getSocketPath()});
    std.debug.print("  Listening on:\n", .{});
    std.debug.print("    {s}://127.0.0.1:{d}/\n", .{ protocol, config.ws_port });
    if (tailscale_info) |info| {
        std.debug.print("    {s}://{s}:{d}/ (Tailscale)\n", .{ protocol, info.ip, config.ws_port });
    }
    if (static_dir) |dir| {
        std.debug.print("  Static files: {s}\n", .{dir});
    }
    if (config.isTlsEnabled()) {
        std.debug.print("  TLS enabled (certificate: {s})\n", .{config.tls_cert.?});
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

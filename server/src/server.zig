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
const ws_proxy = @import("ws_proxy.zig");

const log = std.log.scoped(.server);

pub const RunConfig = struct {
    ipc: ipc.Config = .{},
    static_dir: ?[]const u8 = null,
    ws_port: u16 = http.DEFAULT_PORT,
    pty_log: bool = false,
    no_delta: bool = false,
    no_sync_output: bool = false,
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

fn hexDigit(n: u8) u8 {
    return if (n < 10) @as(u8, '0') + n else @as(u8, 'a') + (n - 10);
}

fn generateTokenHex() [64]u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    var out: [64]u8 = undefined;
    for (bytes, 0..) |b, i| {
        out[i * 2] = hexDigit(b >> 4);
        out[i * 2 + 1] = hexDigit(b & 0x0F);
    }
    return out;
}

fn writeTokensFile(path: []const u8, master_token: []const u8, view_token: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();

    var buf: [256]u8 = undefined;
    const contents = try std.fmt.bufPrint(&buf, "master={s}\nview={s}\n", .{ master_token, view_token });
    try file.writeAll(contents);
}

pub fn run(allocator: std.mem.Allocator, config: RunConfig) !void {
    // Detect Tailscale for remote access BEFORE signal handlers are installed.
    // This is important because the SIGCHLD handler auto-reaps children, which
    // conflicts with Child.wait() used in tailscale detection.
    var tailscale_info = tailscale.detect(allocator);
    defer if (tailscale_info) |*info| info.deinit();

    const bind_all = tailscale_info != null;

    // Install signal handlers (including SIGCHLD auto-reap for shell processes)
    signal.install();
    defer signal.reset();

    // Enable PTY logging if requested (truncates existing log file)
    if (config.pty_log) {
        pty_log.setEnabled(true);
    }

    // Ensure temp directory exists for tokens/logs/sockets
    try paths.ensureTempDir();

    // Generate auth tokens for this server instance
    const master_token_buf = generateTokenHex();
    const view_token_buf = generateTokenHex();
    const master_token = master_token_buf[0..];
    const view_token = view_token_buf[0..];

    // Write tokens to temp file
    const tokens_path = paths.StaticPaths.tokens();
    writeTokensFile(tokens_path, master_token, view_token) catch |e| {
        log.warn("Failed to write tokens file {s}: {any}", .{ tokens_path, e });
    };

    // Create global pane registry
    var pane_registry = PaneRegistry.init(allocator, .{
        .allow_sync_output = !config.no_sync_output,
    });
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

    // Create additional windows (1-4) with 3x2 grids (6 panes each)
    const initial_active_window_id = session.active_window_id;
    for (0..4) |_| {
        const extra = try session.createWindowWithPaneCount(6);
        log.info("Created window {d} with {d} panes (3x2 grid)", .{ extra.window_id, extra.pane_ids.len });
        allocator.free(extra.pane_ids);
    }
    // Keep the initial window active on startup
    session.active_window_id = initial_active_window_id;

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
    const auth_store = try ws_proxy.AuthStore.init(allocator, master_token, view_token);
    var event_loop = EventLoop.init(allocator, &ipc_server, &http_server, &session, config.no_delta, auth_store);
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
    std.debug.print("  Auth tokens:\n", .{});
    std.debug.print("    Master: {s}\n", .{master_token});
    std.debug.print("    View:   {s}\n", .{view_token});
    std.debug.print("  Tokens file: {s}\n", .{tokens_path});
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

//! Dullahan core library
//!
//! This module exposes the core functionality for the dullahan server.

const std = @import("std");

// Re-export submodules
pub const math = @import("math.zig");
pub const terminal = @import("terminal.zig");
pub const ipc = @import("ipc.zig");
pub const server = @import("server.zig");
pub const cli = @import("cli.zig");

// WebSocket/HTTP server
pub const http = @import("http.zig");
pub const websocket = @import("websocket.zig");
pub const snapshot = @import("snapshot.zig");

// Session/Window/Pane hierarchy
pub const Session = @import("session.zig").Session;
pub const Window = @import("window.zig").Window;
pub const Pane = @import("pane.zig").Pane;
pub const PaneRegistry = @import("pane_registry.zig").PaneRegistry;
pub const Pty = @import("pty.zig").Pty;

// Event loop (single-threaded I/O)
pub const EventLoop = @import("event_loop.zig").EventLoop;

// Utilities
pub const process = @import("process.zig");

// Signal handling
pub const signal = @import("signal.zig");

// Unified logging (file + console + stderr)
pub const dlog = @import("dlog.zig");

// Debug configuration (Wine-style category logging)
pub const debug_config = @import("debug_config.zig");

// Path utilities (UID-specific temp directory)
pub const paths = @import("paths.zig");

// PTY traffic logging
pub const pty_log = @import("pty_log.zig");

// Tailscale detection
pub const tailscale = @import("tailscale.zig");

// Layout database (config file)
pub const layout_db = @import("layout_db.zig");

// Test runners (integrated test commands)
pub const test_runners = @import("test_runners.zig");

// Ensure all tests from submodules are run
test {
    std.testing.refAllDecls(@This());
}

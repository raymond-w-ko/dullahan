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

// Session/Window/Pane hierarchy
pub const Session = @import("session.zig").Session;
pub const Window = @import("window.zig").Window;
pub const Pane = @import("pane.zig").Pane;

// Ensure all tests from submodules are run
test {
    std.testing.refAllDecls(@This());
}

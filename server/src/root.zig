//! Dullahan core library
//!
//! This module exposes the core functionality for the dullahan server.

const std = @import("std");

// Re-export submodules
pub const math = @import("math.zig");

// Ensure all tests from submodules are run
test {
    std.testing.refAllDecls(@This());
}

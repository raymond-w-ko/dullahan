//! Integration tests that span multiple modules
//!
//! These tests import the library as a consumer would,
//! testing interactions between components.

const std = @import("std");
const dullahan = @import("dullahan");

test "math module is accessible from library root" {
    const result = dullahan.math.add(10, 20);
    try std.testing.expectEqual(30, result);
}

test "example multi-module interaction" {
    // TODO(du-9lb): When we have server + terminal modules, test them together
    // const server = dullahan.server.init(...);
    // const terminal = dullahan.terminal.spawn(...);
    // try std.testing.expect(server.hasTerminal(terminal.id));
    try std.testing.expect(true);
}

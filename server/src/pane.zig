//! Pane - a single terminal pane with an associated process
//!
//! A pane represents one terminal emulator instance connected to a shell
//! or command. Panes are contained within Windows.

const std = @import("std");
const posix = std.posix;
const ghostty = @import("ghostty-vt");
const Terminal = ghostty.Terminal;
const Pty = @import("pty.zig").Pty;
const snapshot = @import("snapshot.zig");

const log = std.log.scoped(.pane);

pub const Pane = struct {
    /// The terminal emulator state
    terminal: Terminal,

    /// Pane dimensions in cells
    cols: u16,
    rows: u16,

    /// Unique pane ID within the window
    id: u16,

    /// Allocator used for this pane
    allocator: std.mem.Allocator,

    /// Whether this pane is active/focused
    active: bool = true,

    /// Generation counter - increments on any content change
    /// Used for delta sync protocol to detect what changed
    /// See docs/delta-sync-design.md
    generation: u64 = 0,

    /// Dirty row tracking for delta sync
    /// Set of row IDs that changed since last clearDirtyRows() call
    dirty_rows: std.AutoHashMap(u64, void),

    /// Generation when dirty_rows was last cleared
    /// Clients with generation < this need full resync
    dirty_base_gen: u64 = 0,

    /// PTY for this pane (null if no shell spawned)
    pty: ?Pty = null,

    /// Child process ID (null if no shell spawned)
    child_pid: ?posix.pid_t = null,
    
    /// Mutex protecting terminal state access
    /// Required because PTY reader and WebSocket snapshot run on different threads
    mutex: std.Thread.Mutex = .{},

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        id: u16 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Pane {
        var terminal = try Terminal.init(allocator, .{
            .cols = opts.cols,
            .rows = opts.rows,
        });

        // Enable LNM (Line Feed/New Line Mode) so \n does CR+LF
        // Without this, \n only moves down, not back to column 0
        terminal.modes.set(.linefeed, true);

        return .{
            .terminal = terminal,
            .cols = opts.cols,
            .rows = opts.rows,
            .id = opts.id,
            .allocator = allocator,
            .dirty_rows = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    pub fn deinit(self: *Pane) void {
        // Kill child process if running
        if (self.child_pid) |pid| {
            _ = posix.kill(pid, posix.SIG.TERM) catch {};
            // Give it a moment, then force kill
            std.Thread.sleep(100 * std.time.ns_per_ms);
            _ = posix.kill(pid, posix.SIG.KILL) catch {};
            _ = posix.waitpid(pid, 0);
        }

        // Close PTY
        if (self.pty) |*pty| {
            pty.deinit();
        }

        self.dirty_rows.deinit();
        self.terminal.deinit(self.allocator);
    }

    /// Spawn a shell in this pane
    pub fn spawnShell(self: *Pane) !void {
        if (self.pty != null) return error.AlreadySpawned;

        // Open PTY with pane dimensions
        var pty = Pty.open(.{
            .ws_row = self.rows,
            .ws_col = self.cols,
        }) catch return error.PtyOpenFailed;
        errdefer pty.deinit();

        // Get user's shell from environment, fallback to /bin/sh
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        
        // Create null-terminated shell path
        var shell_buf: [256:0]u8 = undefined;
        const shell_z = std.fmt.bufPrintZ(&shell_buf, "{s}", .{shell}) catch "/bin/sh";

        // Spawn shell
        const pid = pty.spawn(&.{shell_z}, null) catch return error.SpawnFailed;

        self.pty = pty;
        self.child_pid = pid;

        log.info("Spawned shell (pid={d}) in pane {d}", .{ pid, self.id });
    }

    /// Write input to the PTY (stdin to child process)
    pub fn writeInput(self: *Pane, data: []const u8) !void {
        if (self.pty) |*pty| {
            _ = try pty.write(data);
        } else {
            return error.NoPty;
        }
    }

    /// Get the PTY master fd for polling (returns null if no PTY)
    pub fn getPtyFd(self: *Pane) ?posix.fd_t {
        if (self.pty) |pty| {
            return pty.master;
        }
        return null;
    }

    /// Check if child process is still alive
    pub fn isAlive(self: *Pane) bool {
        if (self.child_pid) |pid| {
            const result = posix.waitpid(pid, posix.W.NOHANG);
            if (result.pid != 0) {
                // Child exited
                self.child_pid = null;
                return false;
            }
            return true;
        }
        return false;
    }
    
    /// Lock terminal state for reading (used by snapshot generation)
    pub fn lock(self: *Pane) void {
        self.mutex.lock();
    }
    
    /// Unlock terminal state
    pub fn unlock(self: *Pane) void {
        self.mutex.unlock();
    }

    /// Feed raw bytes into the terminal (e.g., from process stdout)
    /// This processes VT escape sequences including colors, cursor movement, etc.
    pub fn feed(self: *Pane, data: []const u8) !void {
        // Check for DA1 request (CSI c or CSI 0 c) and respond
        // ghostty-vt's readonly handler ignores device_attributes, so we handle it here
        self.handleTerminalQueries(data);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Create a VT stream to process the input
        // vtStream() handles ANSI escape sequences properly
        var stream = self.terminal.vtStream();
        defer stream.deinit();
        try stream.nextSlice(data);

        // Collect dirty rows from ghostty's dirty tracking
        self.collectDirtyRows();

        // Increment generation to signal clients need update
        self.generation +%= 1;
    }

    /// Collect dirty row IDs from ghostty's dirty tracking into our dirty_rows set.
    /// Clears ghostty's dirty flags after collecting.
    fn collectDirtyRows(self: *Pane) void {
        const pages = &self.terminal.screens.active.pages;

        // Iterate through viewport rows to find dirty ones
        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            const pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }) orelse continue;

            if (pin.isDirty()) {
                const row_id = snapshot.computeRowId(pin);
                self.dirty_rows.put(row_id, {}) catch {
                    log.warn("Failed to track dirty row {d}", .{row_id});
                };
            }
        }

        // Clear ghostty's dirty flags
        self.terminal.screens.active.pages.clearDirty();
    }
    
    /// Handle terminal queries that require responses (DA1, etc.)
    /// These are sent by shells/apps to detect terminal capabilities
    fn handleTerminalQueries(self: *Pane, data: []const u8) void {
        // Look for DA1: ESC [ c or ESC [ 0 c
        // DA1 = Primary Device Attributes
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            if (data[i] == 0x1b and i + 2 < data.len) {
                if (data[i + 1] == '[') {
                    // CSI sequence
                    if (data[i + 2] == 'c') {
                        // ESC [ c - DA1 request
                        self.sendDA1Response();
                        i += 2;
                    } else if (i + 3 < data.len and data[i + 2] == '0' and data[i + 3] == 'c') {
                        // ESC [ 0 c - DA1 request (explicit)
                        self.sendDA1Response();
                        i += 3;
                    } else if (data[i + 2] == '>' and i + 3 < data.len and data[i + 3] == 'c') {
                        // ESC [ > c - DA2 (Secondary Device Attributes)
                        self.sendDA2Response();
                        i += 3;
                    }
                }
            }
        }
    }
    
    /// Send Primary Device Attributes response
    /// Response format: CSI ? <params> c
    /// We claim VT220 with color support (like Ghostty)
    fn sendDA1Response(self: *Pane) void {
        // Response: ESC [ ? 62 ; 22 c
        // 62 = VT220 (Level 2)
        // 22 = ANSI color
        const response = "\x1b[?62;22c";
        self.writeInput(response) catch |e| {
            log.warn("Failed to send DA1 response: {any}", .{e});
        };
        log.debug("Sent DA1 response", .{});
    }
    
    /// Send Secondary Device Attributes response  
    /// Response format: CSI > <params> c
    fn sendDA2Response(self: *Pane) void {
        // Response: ESC [ > 1 ; 10 ; 0 c
        // 1 = VT220
        // 10 = firmware version (arbitrary)
        // 0 = ROM cartridge (none)
        const response = "\x1b[>1;10;0c";
        self.writeInput(response) catch |e| {
            log.warn("Failed to send DA2 response: {any}", .{e});
        };
        log.debug("Sent DA2 response", .{});
    }

    /// Get a plain string representation of the terminal contents
    pub fn plainString(self: *Pane) ![]const u8 {
        return self.terminal.plainString(self.allocator);
    }

    /// Resize the pane
    pub fn resize(self: *Pane, cols: u16, rows: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.cols = cols;
        self.rows = rows;
        try self.terminal.resize(self.allocator, cols, rows);

        // Resize PTY if we have one
        if (self.pty) |*pty| {
            pty.setSize(.{ .ws_row = rows, .ws_col = cols }) catch |e| {
                log.warn("Failed to resize PTY: {any}", .{e});
            };
        }

        // Resize affects all rows - mark them all dirty
        self.markAllRowsDirty();

        // Increment generation to signal clients need update
        self.generation +%= 1;
    }

    /// Scroll the viewport by delta rows (negative = up, positive = down)
    pub fn scroll(self: *Pane, delta: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.terminal.screens.active.scroll(.{ .delta_row = delta });

        // Scrolling changes which rows are visible - mark all dirty
        self.markAllRowsDirty();

        // Increment generation to signal clients need update
        self.generation +%= 1;

        log.debug("Scrolled by {d} rows", .{delta});
    }

    /// Mark all visible rows as dirty (used for resize/scroll)
    fn markAllRowsDirty(self: *Pane) void {
        const pages = &self.terminal.screens.active.pages;

        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            const pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }) orelse continue;
            const row_id = snapshot.computeRowId(pin);
            self.dirty_rows.put(row_id, {}) catch {
                log.warn("Failed to track dirty row {d}", .{row_id});
            };
        }
    }

    /// Get the set of dirty row IDs since last clear.
    /// Caller should NOT modify the returned map.
    pub fn getDirtyRows(self: *Pane) *const std.AutoHashMap(u64, void) {
        return &self.dirty_rows;
    }

    /// Get count of dirty rows
    pub fn getDirtyRowCount(self: *Pane) usize {
        return self.dirty_rows.count();
    }

    /// Clear dirty row tracking and update base generation.
    /// Called after successfully sending delta to client.
    pub fn clearDirtyRows(self: *Pane) void {
        self.dirty_rows.clearRetainingCapacity();
        self.dirty_base_gen = self.generation;
    }

    /// Check if a client with given generation needs full resync.
    /// Returns true if client is too far behind (dirty tracking doesn't go back that far).
    pub fn needsFullResync(self: *Pane, client_gen: u64) bool {
        return client_gen < self.dirty_base_gen;
    }

    /// Dump pane state in compact human-readable format
    pub fn dump(self: *Pane, writer: anytype) !void {
        const screen = self.terminal.screens.active;
        const cursor = screen.cursor;

        try writer.print("Pane[{d}] {d}x{d}", .{ self.id, self.cols, self.rows });
        if (self.child_pid) |pid| {
            try writer.print(" pid={d}", .{pid});
        }
        try writer.print(" cur=({d},{d})", .{ cursor.x, cursor.y });

        // Cursor style
        const style_char: u8 = switch (cursor.cursor_style) {
            .block => 'B',
            .block_hollow => 'O',
            .underline => 'U',
            .bar => 'I',
        };
        try writer.print(" style={c}", .{style_char});

        if (cursor.pending_wrap) try writer.writeAll(" wrap");
        try writer.writeAll("\n");

        // Dump terminal content (non-empty rows only)
        try writer.writeAll("---content---\n");

        const content = self.terminal.plainString(self.allocator) catch |e| {
            try writer.print("(error: {})\n", .{e});
            return;
        };
        defer self.allocator.free(content);

        // Trim trailing empty lines and output
        var end = content.len;
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == ' ')) {
            end -= 1;
        }

        if (end > 0) {
            try writer.writeAll(content[0..end]);
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("(empty)\n");
        }
        try writer.writeAll("---end---\n");
    }
};

// Tests
test "pane can be created" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    try std.testing.expectEqual(@as(u16, 80), pane.cols);
    try std.testing.expectEqual(@as(u16, 24), pane.rows);
}

test "pane can feed data" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    try pane.feed("Hello, World!\r\n");

    const str = try pane.plainString();
    defer std.testing.allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "Hello") != null);
}

test "dirty row tracking" {
    var pane = try Pane.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer pane.deinit();

    // Initially no dirty rows
    try std.testing.expectEqual(@as(usize, 0), pane.getDirtyRowCount());

    // Feed some data - should mark rows dirty
    try pane.feed("Line 1\r\n");
    try std.testing.expect(pane.getDirtyRowCount() > 0);

    // Generation should have increased
    try std.testing.expect(pane.generation > 0);

    // Clear dirty rows
    const gen_before_clear = pane.generation;
    pane.clearDirtyRows();
    try std.testing.expectEqual(@as(usize, 0), pane.getDirtyRowCount());
    try std.testing.expectEqual(gen_before_clear, pane.dirty_base_gen);

    // Client with old generation needs resync
    try std.testing.expect(pane.needsFullResync(0));
    try std.testing.expect(!pane.needsFullResync(gen_before_clear));
}

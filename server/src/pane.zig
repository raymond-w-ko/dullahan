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
const process = @import("process.zig");

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
    
    /// Debug capture file for recording PTY output as hex
    /// Set via startCapture(), cleared via stopCapture()
    capture_file: ?std.fs.File = null,
    
    /// VT stream parser - persists between feed() calls to handle split escape sequences
    /// Lazily initialized on first feed() because vtStream() captures a Terminal pointer
    /// that would be invalid if captured during init() (before Pane is at final location)
    vt_stream: ?@TypeOf(Terminal.vtStream(undefined)) = null,

    /// Terminal title set by OSC 0/2 escape sequences
    /// Shells use this to show working directory, command, etc.
    title: ?[]const u8 = null,

    /// Flag indicating title has changed since last read
    /// Reset by clearTitleChanged(), used for push notifications
    title_changed: bool = false,

    /// Flag indicating bell was triggered (BEL 0x07 received)
    /// Reset by clearBell(), used for push notifications to clients
    bell_pending: bool = false,

    /// Broadcast coordination for delta sync
    /// Ensures only one thread generates delta per generation update
    broadcast_mutex: std.Thread.Mutex = .{},

    /// Generation of the last broadcast delta
    last_broadcast_gen: u64 = 0,

    /// Cached delta bytes for current generation (all clients get same delta)
    /// Owned by pane, freed on next delta generation or deinit
    cached_delta: ?[]u8 = null,

    /// The fromGen of the cached delta (what generation clients need to be at to apply it)
    cached_delta_from_gen: u64 = 0,

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
            // vt_stream is lazily initialized in feed() - see comment on field
        };
    }

    pub fn deinit(self: *Pane) void {
        // Close PTY FIRST - this sends SIGHUP to the shell and causes it to exit
        // Must happen before waitpid or the shell may be blocked reading from PTY
        if (self.pty) |*pty| {
            log.debug("Closing PTY", .{});
            pty.deinit();
        }
        self.pty = null;

        // Now reap the child process
        if (self.child_pid) |pid| {
            log.debug("Waiting for child process {d}", .{pid});
            process.reapChild(pid);
            log.debug("Child process cleanup complete", .{});
        }

        if (self.vt_stream) |*stream| {
            stream.deinit();
        }

        // Free title if allocated
        if (self.title) |t| {
            self.allocator.free(t);
        }

        // Free cached broadcast delta
        if (self.cached_delta) |delta| {
            self.allocator.free(delta);
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
            if (process.tryWaitpid(pid)) {
                // Child exited or doesn't exist
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
        // Write to capture file if enabled
        if (self.capture_file) |file| {
            self.writeCaptureHex(file, data);
        }

        // Check for DA1 request (CSI c or CSI 0 c) and respond
        // ghostty-vt's readonly handler ignores device_attributes, so we handle it here
        self.handleTerminalQueries(data);

        // Parse OSC sequences for title changes (OSC 0/2)
        // ghostty-vt parses these but we handle them ourselves for simplicity
        self.handleOscSequences(data);

        // Check for bell character (BEL 0x07)
        self.handleBell(data);

        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Use persistent VT stream to handle escape sequences split across reads
        // The stream maintains parser state between calls
        // Lazily initialize on first use (see comment on vt_stream field)
        if (self.vt_stream == null) {
            self.vt_stream = self.terminal.vtStream();
        }
        try self.vt_stream.?.nextSlice(data);

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

    /// Parse OSC (Operating System Command) sequences for title changes.
    /// OSC 0 = set icon name and window title
    /// OSC 2 = set window title only
    /// Format: ESC ] <cmd> ; <text> (BEL | ST)
    /// BEL = 0x07, ST = ESC \ (0x1b 0x5c)
    fn handleOscSequences(self: *Pane, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            // Look for ESC ]
            if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == ']') {
                const osc_start = i + 2;
                if (osc_start >= data.len) break;

                // Parse OSC number (0 or 2 for title)
                var cmd: u8 = 0;
                var param_end = osc_start;
                while (param_end < data.len and data[param_end] >= '0' and data[param_end] <= '9') {
                    cmd = cmd * 10 + (data[param_end] - '0');
                    param_end += 1;
                }

                // Skip if not OSC 0 or 2
                if (cmd != 0 and cmd != 2) continue;

                // Expect semicolon after command number
                if (param_end >= data.len or data[param_end] != ';') continue;
                const text_start = param_end + 1;

                // Find terminator: BEL (0x07) or ST (ESC \)
                var text_end = text_start;
                var found_term = false;
                while (text_end < data.len) : (text_end += 1) {
                    if (data[text_end] == 0x07) {
                        // BEL terminator
                        found_term = true;
                        break;
                    }
                    if (data[text_end] == 0x1b and text_end + 1 < data.len and data[text_end + 1] == '\\') {
                        // ST terminator (ESC \)
                        found_term = true;
                        break;
                    }
                }

                if (!found_term) continue;

                // Extract title text
                const title_text = data[text_start..text_end];
                if (title_text.len > 0) {
                    self.setTitle(title_text);
                }

                // Skip past this OSC sequence
                i = text_end;
            }
        }
    }

    /// Set the terminal title, allocating a copy of the string
    pub fn setTitle(self: *Pane, new_title: []const u8) void {
        // Free old title if present
        if (self.title) |old| {
            self.allocator.free(old);
        }

        // Allocate and copy new title
        const copy = self.allocator.dupe(u8, new_title) catch |e| {
            log.warn("Failed to allocate title: {any}", .{e});
            self.title = null;
            return;
        };

        self.title = copy;
        self.title_changed = true;
        log.debug("Title set to: {s}", .{new_title});
    }

    /// Get the current title (or null if none set)
    pub fn getTitle(self: *Pane) ?[]const u8 {
        return self.title;
    }

    /// Check if title has changed since last cleared
    pub fn hasTitleChanged(self: *Pane) bool {
        return self.title_changed;
    }

    /// Clear the title changed flag
    pub fn clearTitleChanged(self: *Pane) void {
        self.title_changed = false;
    }

    /// Check for bell character (BEL = 0x07) in input data
    /// Skips BEL characters that are OSC sequence terminators (ESC ] ... BEL)
    fn handleBell(self: *Pane, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            // Check for OSC sequence start (ESC ])
            if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == ']') {
                // Skip to end of OSC sequence (BEL or ST terminator)
                i += 2;
                while (i < data.len) : (i += 1) {
                    if (data[i] == 0x07) {
                        // BEL terminator - this is NOT a bell, skip it
                        break;
                    }
                    if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') {
                        // ST terminator (ESC \)
                        i += 1;
                        break;
                    }
                }
                continue;
            }
            // Standalone BEL - this is a real bell
            if (data[i] == 0x07) {
                self.bell_pending = true;
                log.debug("Bell triggered", .{});
                return; // One bell per feed is enough
            }
        }
    }

    /// Check if bell was triggered since last cleared
    pub fn hasBell(self: *Pane) bool {
        return self.bell_pending;
    }

    /// Clear the bell pending flag
    pub fn clearBell(self: *Pane) void {
        self.bell_pending = false;
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

        // Increment generation first
        self.generation +%= 1;

        // Resize reflows content, invalidating row IDs
        // Force all clients to do full resync
        self.forceFullResync();
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

    /// Mark all visible rows as dirty (used for scroll).
    /// For resize, use forceFullResync() instead.
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

    /// Force all clients to do a full resync.
    /// Used after resize because reflow invalidates row IDs.
    fn forceFullResync(self: *Pane) void {
        // Clear dirty tracking and set base to current generation
        // This makes needsFullResync() return true for any client
        // with an older generation
        self.dirty_rows.clearRetainingCapacity();
        self.dirty_base_gen = self.generation;
    }

    /// Get the set of dirty row IDs since last clear.
    /// Caller must hold the pane lock (this is only called from generateDelta which locks).
    pub fn getDirtyRows(self: *Pane) *const std.AutoHashMap(u64, void) {
        return &self.dirty_rows;
    }

    /// Get count of dirty rows
    pub fn getDirtyRowCount(self: *Pane) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dirty_rows.count();
    }

    /// Clear dirty row tracking and update base generation.
    /// Called after successfully sending delta to client.
    pub fn clearDirtyRows(self: *Pane) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.dirty_rows.clearRetainingCapacity();
        self.dirty_base_gen = self.generation;
    }

    /// Check if a client with given generation needs full resync.
    /// Returns true if client is too far behind (dirty tracking doesn't go back that far).
    pub fn needsFullResync(self: *Pane, client_gen: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return client_gen < self.dirty_base_gen;
    }

    /// Get the broadcast delta for the current generation.
    /// Thread-safe: ensures only one thread generates the delta, all others get cached copy.
    /// Returns owned slice that caller must free, or null if no update needed.
    /// Also returns the fromGen that clients must be at to apply this delta.
    pub fn getBroadcastDelta(self: *Pane) !struct { delta: []u8, from_gen: u64 } {
        self.broadcast_mutex.lock();
        defer self.broadcast_mutex.unlock();

        // Check if we already have a cached delta for current generation
        if (self.cached_delta != null and self.last_broadcast_gen == self.generation) {
            // Return a copy of cached delta
            const copy = try self.allocator.dupe(u8, self.cached_delta.?);
            return .{ .delta = copy, .from_gen = self.cached_delta_from_gen };
        }

        // Need to generate new delta
        const from_gen = self.last_broadcast_gen;

        // Generate delta (this locks self.mutex internally)
        const delta = try snapshot.generateDelta(self.allocator, self, from_gen, false);

        // Free old cached delta
        if (self.cached_delta) |old| {
            self.allocator.free(old);
        }

        // Cache the new delta
        self.cached_delta = delta;
        self.cached_delta_from_gen = from_gen;
        self.last_broadcast_gen = self.generation;

        // Clear dirty rows now that delta is generated
        // Need to lock mutex since dirty_rows is protected by it
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.dirty_rows.clearRetainingCapacity();
            self.dirty_base_gen = self.generation;
        }

        // Return a copy (caller owns it)
        const copy = try self.allocator.dupe(u8, delta);
        return .{ .delta = copy, .from_gen = from_gen };
    }

    /// Check if cursor keys should use application mode (DECCKM)
    /// When true, arrow keys use SS3 sequences (\x1bO), otherwise CSI (\x1b[)
    pub fn isCursorKeyApplication(self: *Pane) bool {
        return self.terminal.modes.get(.cursor_keys);
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

    /// Dump raw terminal cells with escape sequences and control chars visible.
    /// Useful for debugging ANSI parsing issues (e.g., stray 'm' from SGR codes).
    pub fn dumpRaw(self: *Pane, writer: anytype) !void {
        self.lock();
        defer self.unlock();

        const screen = self.terminal.screens.active;
        const cursor = screen.cursor;
        const pages = &screen.pages;

        try writer.print("Pane[{d}] {d}x{d} cur=({d},{d}) gen={d}\n", .{
            self.id,
            self.cols,
            self.rows,
            cursor.x,
            cursor.y,
            self.generation,
        });

        try writer.writeAll("---raw cells---\n");

        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            try writer.print("{d:>3}|", .{y});

            const pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } });
            if (pin == null) {
                try writer.writeAll("(no pin)\n");
                continue;
            }

            const cells = pin.?.cells(.all);
            var x: usize = 0;
            while (x < self.cols and x < cells.len) : (x += 1) {
                const cell = cells[x];
                const cp = cell.codepoint();

                if (cp == 0) {
                    // Empty cell
                    try writer.writeAll("·");
                } else if (cp < 32) {
                    // Control character - show as ^X
                    try writer.print("^{c}", .{@as(u8, @intCast(cp + 64))});
                } else if (cp == 127) {
                    try writer.writeAll("^?");
                } else if (cp < 127) {
                    // Normal ASCII
                    try writer.print("{c}", .{@as(u8, @intCast(cp))});
                } else {
                    // Unicode - show codepoint
                    try writer.print("U+{X:0>4}", .{cp});
                }
            }
            try writer.writeAll("|\n");
        }

        try writer.writeAll("---end raw---\n");
    }

    /// Start capturing PTY output to a file as hex
    pub fn startCapture(self: *Pane, path: []const u8) !void {
        if (self.capture_file != null) {
            return error.AlreadyCapturing;
        }
        
        const file = try std.fs.cwd().createFile(path, .{});
        self.capture_file = file;
        
        // Write header
        file.writeAll("# Dullahan PTY capture - hex dump\n") catch {};
        file.writeAll("# Format: [timestamp_ms] offset: hex bytes | ascii\n\n") catch {};
        
        log.info("Started capture to {s}", .{path});
    }
    
    /// Stop capturing PTY output
    pub fn stopCapture(self: *Pane) void {
        if (self.capture_file) |file| {
            file.writeAll("\n# End of capture\n") catch {};
            file.close();
            self.capture_file = null;
            log.info("Stopped capture", .{});
        }
    }
    
    /// Write data to capture file as hex dump
    fn writeCaptureHex(self: *Pane, file: std.fs.File, data: []const u8) void {
        _ = self;
        const timestamp = std.time.milliTimestamp();
        
        // Write in 16-byte rows using a buffer
        var buf: [256]u8 = undefined;
        var offset: usize = 0;
        while (offset < data.len) {
            const end = @min(offset + 16, data.len);
            const row = data[offset..end];
            
            // Format the line into buffer
            var fbs = std.io.fixedBufferStream(&buf);
            const w = fbs.writer();
            
            // Timestamp and offset
            std.fmt.format(w, "[{d}] {x:0>4}: ", .{ timestamp, offset }) catch return;
            
            // Hex bytes
            for (row) |byte| {
                std.fmt.format(w, "{x:0>2} ", .{byte}) catch return;
            }
            
            // Padding for short rows
            var pad: usize = 16 - row.len;
            while (pad > 0) : (pad -= 1) {
                w.writeAll("   ") catch return;
            }
            
            // ASCII representation
            w.writeAll("| ") catch return;
            for (row) |byte| {
                const c: u8 = if (byte >= 32 and byte < 127) byte else '.';
                std.fmt.format(w, "{c}", .{c}) catch return;
            }
            w.writeAll("\n") catch return;
            
            // Write to file
            file.writeAll(fbs.getWritten()) catch return;
            
            offset = end;
        }
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

test "OSC title parsing" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Initially no title
    try std.testing.expect(pane.getTitle() == null);
    try std.testing.expect(!pane.hasTitleChanged());

    // Feed OSC 2 with BEL terminator
    try pane.feed("\x1b]2;Hello World\x07");
    try std.testing.expect(pane.hasTitleChanged());
    try std.testing.expectEqualStrings("Hello World", pane.getTitle().?);

    // Clear the changed flag
    pane.clearTitleChanged();
    try std.testing.expect(!pane.hasTitleChanged());

    // Feed OSC 0 with ST terminator
    try pane.feed("\x1b]0;New Title\x1b\\");
    try std.testing.expect(pane.hasTitleChanged());
    try std.testing.expectEqualStrings("New Title", pane.getTitle().?);

    // Title with path (common shell prompt)
    pane.clearTitleChanged();
    try pane.feed("\x1b]2;user@host:~/projects\x07");
    try std.testing.expectEqualStrings("user@host:~/projects", pane.getTitle().?);
}

test "bell detection" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Initially no bell
    try std.testing.expect(!pane.hasBell());

    // Feed BEL character
    try pane.feed("\x07");
    try std.testing.expect(pane.hasBell());

    // Clear and verify
    pane.clearBell();
    try std.testing.expect(!pane.hasBell());

    // Bell in middle of text
    try pane.feed("Hello\x07World");
    try std.testing.expect(pane.hasBell());
}

test "bell detection skips OSC terminators" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // OSC 0 (set title) with BEL terminator - should NOT trigger bell
    try pane.feed("\x1b]0;My Title\x07");
    try std.testing.expect(!pane.hasBell());

    // OSC 2 (set title) with BEL terminator - should NOT trigger bell
    try pane.feed("\x1b]2;Another Title\x07");
    try std.testing.expect(!pane.hasBell());

    // OSC with ST terminator (ESC \) - should NOT trigger bell
    try pane.feed("\x1b]0;Title\x1b\\");
    try std.testing.expect(!pane.hasBell());

    // Mix: OSC followed by real bell - only real bell should trigger
    try pane.feed("\x1b]0;Title\x07\x07");
    try std.testing.expect(pane.hasBell());

    pane.clearBell();

    // Text with OSC in middle and real bell after
    try pane.feed("Hello\x1b]0;Title\x07World\x07");
    try std.testing.expect(pane.hasBell());
}

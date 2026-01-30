//! Pane - a single terminal pane with an associated process
//!
//! A pane represents one terminal emulator instance connected to a shell
//! or command. Panes are contained within Windows.

const std = @import("std");
const posix = std.posix;
const ghostty = @import("ghostty-vt");
const Terminal = ghostty.Terminal;
const osc = ghostty.osc;
const osc_color = osc.color;
const device_status = ghostty.device_status;
const Pty = @import("pty.zig").Pty;
const constants = @import("constants.zig");
const stream_handler = @import("stream_handler.zig");

/// Mouse event reporting modes (DECSET 9, 1000, 1002, 1003)
/// Re-exported from ghostty for use by event_loop.zig
pub const MouseEvents = Terminal.MouseEvents;

/// Mouse encoding formats (DECSET 1005, 1006, 1015, 1016)
/// Re-exported from ghostty for use by event_loop.zig
pub const MouseFormat = Terminal.MouseFormat;
const snapshot = @import("snapshot.zig");
const process = @import("process.zig");
const dlog = @import("dlog.zig");
const shell = @import("shell.zig");
const terminal_mod = @import("terminal.zig");
const clipboard_mod = @import("clipboard.zig");

/// Re-exported for convenience
pub const ClipboardOp = clipboard_mod.ClipboardOp;
pub const ClipboardHandler = clipboard_mod.ClipboardHandler;

const log = std.log.scoped(.pane);

// Category-scoped debug loggers
const plog = dlog.scoped(.pane);
const dsr_log = dlog.scoped(.dsr);
const clip_log = dlog.scoped(.clipboard);
const delta_log = dlog.scoped(.delta);

/// Shell integration event (OSC 133)
/// Sent by shells with semantic prompt integration to mark prompt/command regions
pub const ShellIntegrationEvent = struct {
    kind: Kind,
    exit_code: ?i32 = null, // Only set for command_end

    pub const Kind = enum {
        prompt_start, // A - start of prompt
        prompt_end, // B - end of prompt (command input starts)
        output_start, // C - command output starts
        command_end, // D - command finished with exit code
    };
};

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

    /// Synchronized output mode (DECSET 2026) state tracking
    /// When enabled, terminal updates are buffered until mode is disabled
    sync_output_enabled: bool = false,

    /// Whether synchronized output is allowed for this pane
    sync_output_allowed: bool = true,

    /// Timestamp (nanoseconds) when sync mode was enabled
    /// Used for timeout detection (1 second max)
    sync_output_start_ns: ?i128 = null,

    /// PTY for this pane (null if no shell spawned)
    pty: ?Pty = null,

    /// Child process ID (null if no shell spawned)
    child_pid: ?posix.pid_t = null,

    /// Debug capture file for recording PTY output as hex
    /// Set via startCapture(), cleared via stopCapture()
    capture_file: ?std.fs.File = null,
    
    /// VT stream parser - persists between feed() calls to handle split escape sequences
    /// Uses our custom stream handler that routes query events (DA1, DSR, OSC 10/11)
    /// and notification events (bell, title, clipboard) to the pane while delegating
    /// terminal-modifying events to the Terminal (like readonly does).
    /// Lazily initialized on first feed() because we need a stable pointer to the Pane.
    vt_stream: ?stream_handler.Stream = null,

    /// Terminal title set by OSC 0/2 escape sequences
    /// Shells use this to show working directory, command, etc.
    title: ?[]const u8 = null,

    /// Flag indicating title has changed since last read
    /// Reset by clearTitleChanged(), used for push notifications
    title_changed: bool = false,

    /// Flag indicating bell was triggered (BEL 0x07 received)
    /// Reset by clearBell(), used for push notifications to clients
    bell_pending: bool = false,

    /// Notification triggered by OSC 9 or OSC 777 escape sequences
    /// Reset by clearNotification(), used for toast notifications
    notify_pending: bool = false,

    /// Notification title (optional, from OSC 777 format)
    notify_title: ?[]const u8 = null,

    /// Notification body/message
    notify_body: ?[]const u8 = null,

    /// Progress bar state (OSC 9;4 ConEmu style)
    /// state: 0=hidden, 1=normal, 2=error, 3=indeterminate, 4=warning
    progress_state: u8 = 0,

    /// Progress value (0-100), only meaningful when progress_state > 0
    progress_value: u8 = 0,

    /// Flag indicating progress state changed since last read
    progress_changed: bool = false,

    /// Clipboard handler (OSC 52 operations)
    clipboard: ClipboardHandler,

    /// Generation of the last broadcast delta
    last_broadcast_gen: u64 = 0,

    /// Cached delta bytes for current generation (all clients get same delta)
    /// Owned by pane, freed on next delta generation or deinit
    cached_delta: ?[]u8 = null,

    /// The fromGen of the cached delta (what generation clients need to be at to apply it)
    cached_delta_from_gen: u64 = 0,

    /// Track whether we were last on alternate screen to detect screen switches
    /// Screen switches (primary <-> alternate) require full resync because
    /// row IDs are completely different between screens
    last_was_alt_screen: bool = false,

    /// Track the last seen page serial to detect page reallocation
    /// When ghostty adjusts page capacity, it creates new pages with new serials,
    /// which invalidates all existing row IDs and requires full resync
    last_page_serial: ?u64 = null,

    /// Shell integration (OSC 133) event tracking
    /// Stores the most recent shell integration event for broadcast to clients
    shell_event: ?ShellIntegrationEvent = null,

    /// Flag indicating a shell integration event needs to be sent to clients
    shell_event_pending: bool = false,

    /// Selection tracking state for mouse-based selection
    /// Start position of selection drag (viewport coordinates)
    selection_start: ?struct { x: u16, y: u16 } = null,

    /// Whether a selection drag is currently active
    selection_active: bool = false,

    /// Theme colors for OSC 10/11 queries (set by master client)
    /// Falls back to constants.colors defaults if null
    theme_fg: ?[3]u8 = null, // [r, g, b]
    theme_bg: ?[3]u8 = null, // [r, g, b]

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        id: u16 = 0,
        allow_sync_output: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Pane {
        var default_modes: ghostty.modes.ModePacked = .{};
        default_modes.grapheme_cluster = true;
        default_modes.cursor_blinking = true;

        var terminal = try Terminal.init(allocator, .{
            .cols = opts.cols,
            .rows = opts.rows,
            .default_modes = default_modes,
        });

        // Enable LNM (Line Feed/New Line Mode) so \n does CR+LF
        // Without this, \n only moves down, not back to column 0
        terminal.modes.set(.linefeed, true);

        // Enable grapheme clustering (mode 2027) so emoji with modifiers,
        // ZWJ sequences, and flag emoji are combined into single cells
        terminal.modes.set(.grapheme_cluster, true);

        // Provide approximate pixel dimensions for size reports.
        terminal.width_px = @as(u32, opts.cols) * @as(u32, constants.terminal.default_cell_width_px);
        terminal.height_px = @as(u32, opts.rows) * @as(u32, constants.terminal.default_cell_height_px);

        return .{
            .terminal = terminal,
            .cols = opts.cols,
            .rows = opts.rows,
            .id = opts.id,
            .allocator = allocator,
            .dirty_rows = std.AutoHashMap(u64, void).init(allocator),
            .clipboard = ClipboardHandler.init(allocator),
            .sync_output_allowed = opts.allow_sync_output,
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

        // Free notification data if allocated
        if (self.notify_title) |t| {
            self.allocator.free(t);
        }
        if (self.notify_body) |b| {
            self.allocator.free(b);
        }

        // Free cached broadcast delta
        if (self.cached_delta) |delta| {
            self.allocator.free(delta);
        }

        // Cleanup clipboard handler
        self.clipboard.deinit();

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

        // Detect user's shell
        const shell_info = shell.detectShell();

        // Create null-terminated shell path
        var shell_buf: [256:0]u8 = undefined;
        const shell_z = std.fmt.bufPrintZ(&shell_buf, "{s}", .{shell_info.path}) catch "/bin/sh";

        // Spawn shell
        const pid = pty.spawn(&.{shell_z}, null) catch return error.SpawnFailed;

        self.pty = pty;
        self.child_pid = pid;

        log.info("Spawned shell '{s}' (pid={d}) in pane {d} (source: {s})", .{
            shell_info.path,
            pid,
            self.id,
            shell_info.sourceDescription(),
        });
    }

    /// Write input to the PTY (stdin to child process)
    /// Loops until all data is written to handle non-blocking partial writes.
    pub fn writeInput(self: *Pane, data: []const u8) !void {
        if (self.pty) |*pty| {
            var remaining = data;
            while (remaining.len > 0) {
                const written = pty.write(remaining) catch |err| {
                    if (err == error.WouldBlock) {
                        // PTY buffer full, yield and retry
                        std.Thread.sleep(1_000_000); // 1ms
                        continue;
                    }
                    return err;
                };
                if (written == 0) {
                    return error.ConnectionClosed;
                }
                remaining = remaining[written..];
            }
        } else {
            return error.NoPty;
        }
    }

    /// Write directly to terminal buffer (no PTY required).
    /// Used for virtual panes like debug output that have no shell.
    pub fn feedDirect(self: *Pane, data: []const u8) !void {
        // Lazily initialize VT stream with our custom handler
        if (self.vt_stream == null) {
            const handler = stream_handler.Handler.init(&self.terminal, self);
            self.vt_stream = stream_handler.Stream.initAlloc(self.allocator, handler);
        }
        try self.vt_stream.?.nextSlice(data);

        // Collect dirty rows
        self.collectDirtyRows();

        // Increment generation
        self.generation +%= 1;
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

    /// Feed raw bytes into the terminal (e.g., from process stdout)
    /// This processes VT escape sequences including colors, cursor movement, etc.
    /// The custom stream handler receives parsed events from ghostty-vt and:
    /// - Delegates terminal-modifying events to the Terminal
    /// - Routes query events (DA1, DSR, OSC 10/11) to this pane for response
    /// - Routes notification events (bell, title, clipboard) to this pane
    pub fn feed(self: *Pane, data: []const u8) !void {
        // Write to capture file if enabled
        if (self.capture_file) |file| {
            self.writeCaptureHex(file, data);
        }

        // Use persistent VT stream with our custom handler to process escape sequences.
        // The handler receives fully-parsed events from ghostty-vt, eliminating the
        // dual-parser architecture that caused state desync issues.
        // Lazily initialize on first use (see comment on vt_stream field)
        if (self.vt_stream == null) {
            const handler = stream_handler.Handler.init(&self.terminal, self);
            self.vt_stream = stream_handler.Stream.initAlloc(self.allocator, handler);
        }
        try self.vt_stream.?.nextSlice(data);

        // Check for screen switch (primary <-> alternate)
        // Row IDs are completely different between screens, so clients need full resync
        const is_alt_screen = self.terminal.screens.active_key == .alternate;
        if (is_alt_screen != self.last_was_alt_screen) {
            log.debug("Screen switch detected: {s} -> {s}, forcing full resync", .{
                if (self.last_was_alt_screen) "alternate" else "primary",
                if (is_alt_screen) "alternate" else "primary",
            });
            self.last_was_alt_screen = is_alt_screen;
            self.forceFullResync();
        }

        // Check for page reallocation (ghostty adjusting page capacity)
        // When this happens, page serials change and all row IDs become invalid
        const pages = &self.terminal.screens.active.pages;
        if (pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } })) |first_pin| {
            const current_serial = first_pin.node.serial;
            if (self.last_page_serial) |last_serial| {
                if (current_serial != last_serial) {
                    log.debug("Page serial changed: {d} -> {d}, forcing full resync", .{
                        last_serial,
                        current_serial,
                    });
                    self.last_page_serial = current_serial;
                    self.forceFullResync();
                }
            } else {
                self.last_page_serial = current_serial;
            }
        }

        // Collect dirty rows from ghostty's dirty tracking
        self.collectDirtyRows();

        // Increment generation to signal clients need update
        self.generation +%= 1;
    }

    /// Collect dirty row IDs from ghostty's dirty tracking into our dirty_rows set.
    /// Clears ghostty's dirty flags after collecting.
    fn collectDirtyRows(self: *Pane) void {
        const pages = &self.terminal.screens.active.pages;

        // Check if a screen-level clear occurred (e.g., screen switch, erase display).
        // When this happens, ghostty doesn't mark individual rows dirty - it just sets
        // this flag. We need to mark all viewport rows as dirty in this case.
        const full_clear = self.terminal.flags.dirty.clear;
        if (full_clear) {
            self.terminal.flags.dirty.clear = false;
        }

        // Count how many rows ghostty marked dirty (for debug logging)
        var ghostty_dirty_count: usize = 0;

        // Iterate through viewport rows to find dirty ones
        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            const pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }) orelse continue;

            const is_ghostty_dirty = pin.isDirty();
            if (is_ghostty_dirty) {
                ghostty_dirty_count += 1;
            }

            // Mark row dirty if: screen-level clear occurred OR row is individually dirty
            if (full_clear or is_ghostty_dirty) {
                const row_id = snapshot.computeRowId(pin);
                self.dirty_rows.put(row_id, {}) catch {
                    log.warn("Failed to track dirty row {d}", .{row_id});
                };
            }
        }

        if (full_clear or ghostty_dirty_count > 0) {
            delta_log.debug("Pane {d}: collectDirtyRows full_clear={} ghostty_dirty={d} total_dirty={d}", .{
                self.id,
                full_clear,
                ghostty_dirty_count,
                self.dirty_rows.count(),
            });
        }

        // Clear ghostty's dirty flags
        self.terminal.screens.active.pages.clearDirty();
    }

    // ========================================================================
    // Synchronized Output Mode (DECSET 2026)
    // ========================================================================

    /// Check if synchronized output mode has changed and update state.
    /// Returns true if sync mode just ended (caller should broadcast immediately).
    /// Called after feed() to detect mode transitions.
    pub fn checkSyncModeTransition(self: *Pane) bool {
        const sync_mode = self.terminal.modes.get(.synchronized_output);
        if (sync_mode != self.sync_output_enabled) {
            const was_enabled = self.sync_output_enabled;
            if (sync_mode) {
                // Mode just enabled - record start time
                self.sync_output_start_ns = std.time.nanoTimestamp();
                log.debug("Pane {d}: Sync output enabled", .{self.id});
            } else {
                // Mode just disabled - clear timeout
                self.sync_output_start_ns = null;
                log.debug("Pane {d}: Sync output disabled", .{self.id});
            }
            self.sync_output_enabled = sync_mode;
            // Return true if we just ended sync mode (caller should flush)
            return was_enabled and !sync_mode;
        }
        return false;
    }

    /// Force disable synchronized output mode (used for timeout).
    /// Clears our tracking state; the terminal's mode flag will be
    /// corrected when the next DECSET/DECRST sequence arrives.
    pub fn forceSyncDisable(self: *Pane) void {
        self.sync_output_enabled = false;
        self.sync_output_start_ns = null;
        log.debug("Pane {d}: Sync output force-disabled (timeout)", .{self.id});
    }

    /// Check if sync mode is currently enabled
    pub fn isSyncOutputEnabled(self: *const Pane) bool {
        return self.sync_output_enabled;
    }

    /// Send Primary Device Attributes response
    /// Response format: CSI ? <params> c
    /// We claim VT220 with color support (like Ghostty)
    pub fn sendDA1Response(self: *Pane) void {
        // Response: ESC [ ? 62 ; 22 ; 52 c
        // 62 = VT220 (Level 2)
        // 22 = ANSI color
        // 52 = OSC 52 clipboard access
        const response = "\x1b[?62;22;52c";
        self.writeInput(response) catch |e| {
            log.warn("Failed to send DA1 response: {any}", .{e});
        };
        log.debug("Sent DA1 response", .{});
    }
    
    /// Send Secondary Device Attributes response
    /// Response format: CSI > <params> c
    pub fn sendDA2Response(self: *Pane) void {
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

    /// Send DSR (Device Status Report) response for status query (CSI 5 n)
    /// Response: CSI 0 n (terminal OK)
    fn sendDSRStatusResponse(self: *Pane) void {
        const response = "\x1b[0n";
        self.writeInput(response) catch |e| {
            log.warn("Failed to send DSR status response: {any}", .{e});
        };
        dsr_log.debug("Pane {d}: Sent DSR status response (OK)", .{self.id});
    }

    /// Send DSR (Device Status Report) cursor position response (CSI 6 n)
    /// Response: CSI row ; col R (1-indexed)
    fn sendDSRCursorResponse(self: *Pane) void {
        // Get cursor position from terminal (0-indexed), convert to 1-indexed
        const cursor = self.terminal.screens.active.cursor;
        var row = cursor.y;
        var col = cursor.x;
        if (self.terminal.modes.get(.origin)) {
            row = row -| self.terminal.scrolling_region.top;
            col = col -| self.terminal.scrolling_region.left;
        }
        row += 1;
        col += 1;

        // Format response: ESC [ row ; col R
        var buf: [32]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row, col }) catch {
            log.warn("Failed to format DSR cursor response", .{});
            return;
        };

        self.writeInput(response) catch |e| {
            log.warn("Failed to send DSR cursor response: {any}", .{e});
        };
        dsr_log.debug("Pane {d}: Sent DSR cursor position row={d}, col={d}", .{ self.id, row, col });
    }

    /// Send an in-band size report (DECSET 2048).
    /// Response: CSI 48 ; rows ; cols ; height_px ; width_px t
    pub fn sendInBandSizeReport(self: *Pane) void {
        const rows = self.rows;
        const cols = self.cols;
        const height_px = self.terminal.height_px;
        const width_px = self.terminal.width_px;

        var buf: [64]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "\x1b[48;{d};{d};{d};{d}t", .{
            rows,
            cols,
            height_px,
            width_px,
        }) catch {
            log.warn("Failed to format in-band size report", .{});
            return;
        };

        self.writeInput(response) catch |e| {
            log.warn("Failed to send in-band size report: {any}", .{e});
        };
        plog.debug(
            "Pane {d}: Sent in-band size report rows={d} cols={d} px={d}x{d}",
            .{ self.id, rows, cols, height_px, width_px },
        );
    }

    /// Send an XTWINOPS size report response (CSI t queries).
    pub fn sendSizeReport(self: *Pane, style: ghostty.SizeReportStyle) void {
        const rows = self.rows;
        const cols = self.cols;
        const height_px = self.terminal.height_px;
        const width_px = self.terminal.width_px;

        const cell_height: u32 = if (rows > 0) @divTrunc(height_px, rows) else constants.terminal.default_cell_height_px;
        const cell_width: u32 = if (cols > 0) @divTrunc(width_px, cols) else constants.terminal.default_cell_width_px;

        var buf: [64]u8 = undefined;
        const response = switch (style) {
            .csi_14_t => std.fmt.bufPrint(&buf, "\x1b[4;{d};{d}t", .{ height_px, width_px }),
            .csi_16_t => std.fmt.bufPrint(&buf, "\x1b[6;{d};{d}t", .{ cell_height, cell_width }),
            .csi_18_t => std.fmt.bufPrint(&buf, "\x1b[8;{d};{d}t", .{ rows, cols }),
            .csi_21_t => {
                // TODO(du-3ss): Respond to XTWINOPS window title queries (CSI 21 t).
                log.warn("XTWINOPS window title query (CSI 21 t) unhandled", .{});
                return;
            },
        } catch {
            log.warn("Failed to format size report {s}", .{@tagName(style)});
            return;
        };

        self.writeInput(response) catch |e| {
            log.warn("Failed to send size report {s}: {any}", .{@tagName(style), e});
        };
        plog.debug("Pane {d}: Sent size report {s}", .{ self.id, @tagName(style) });
    }

    /// Send OSC 10/11 color query response.
    /// cmd: 10 (foreground) or 11 (background)
    /// r, g, b: 8-bit color values
    /// use_st: true for ST terminator (ESC \), false for BEL (0x07)
    fn sendOscColorResponse(self: *Pane, cmd: u8, r: u8, g: u8, b: u8, use_st: bool) void {
        // Convert 8-bit to 16-bit by duplicating (0xAB -> 0xABAB)
        const r16: u16 = @as(u16, r) << 8 | r;
        const g16: u16 = @as(u16, g) << 8 | g;
        const b16: u16 = @as(u16, b) << 8 | b;

        // Format: ESC ] cmd ; rgb:RRRR/GGGG/BBBB terminator
        // Max size: 2 (ESC ]) + 2 (cmd) + 1 (;) + 4 (rgb:) + 4*3 (hex) + 2 (/) + 2 (terminator) = 25
        var buf: [32]u8 = undefined;
        const response = if (use_st)
            std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ cmd, r16, g16, b16 }) catch return
        else
            std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x07", .{ cmd, r16, g16, b16 }) catch return;

        self.writeInput(response) catch |e| {
            log.warn("Failed to send OSC {d} response: {any}", .{ cmd, e });
        };
        log.debug("Sent OSC {d} response: rgb:{x:0>4}/{x:0>4}/{x:0>4}", .{ cmd, r16, g16, b16 });
    }

    /// Send focus-in event (ESC [ I) if focus_event mode is enabled
    pub fn sendFocusIn(self: *Pane) void {
        if (!self.terminal.modes.get(.focus_event)) return;
        const response = "\x1b[I";
        self.writeInput(response) catch |e| {
            log.warn("Failed to send focus-in: {any}", .{e});
            return;
        };
        log.debug("Pane {d}: Sent focus-in event", .{self.id});
    }

    /// Send focus-out event (ESC [ O) if focus_event mode is enabled
    pub fn sendFocusOut(self: *Pane) void {
        if (!self.terminal.modes.get(.focus_event)) return;
        const response = "\x1b[O";
        self.writeInput(response) catch |e| {
            log.warn("Failed to send focus-out: {any}", .{e});
            return;
        };
        log.debug("Pane {d}: Sent focus-out event", .{self.id});
    }

    // ========================================================================
    // Stream Handler Event Callbacks
    // These methods are called by stream_handler.zig when ghostty-vt parses
    // events that need pane-level handling (queries, notifications, etc.)
    // ========================================================================

    /// Handle bell event from stream handler
    pub fn onBell(self: *Pane) void {
        self.bell_pending = true;
        log.debug("Bell triggered", .{});
    }

    /// Handle window title change from stream handler (OSC 0/2)
    pub fn onWindowTitle(self: *Pane, title: []const u8) void {
        if (title.len > 0) {
            self.setTitle(title);
        }
    }

    /// Handle clipboard contents event from stream handler (OSC 52)
    pub fn onClipboardContents(self: *Pane, kind: u8, data: []const u8) void {
        self.clipboard.handleOsc52Parsed(kind, data, self.id);
    }

    /// Handle color query response from stream handler (OSC 10/11/12)
    /// Sends the appropriate color response back to the terminal
    pub fn sendColorQueryResponse(
        self: *Pane,
        op: osc_color.Operation,
        target: osc_color.Target,
        terminator: osc.Terminator,
    ) void {
        const use_st = terminator == .st;

        switch (target) {
            .dynamic => |d| switch (d) {
                .foreground => {
                    // Use master's theme colors if available, else defaults
                    const fg = self.theme_fg orelse .{
                        constants.colors.fg_r,
                        constants.colors.fg_g,
                        constants.colors.fg_b,
                    };
                    self.sendOscColorResponse(10, fg[0], fg[1], fg[2], use_st);
                },
                .background => {
                    const bg = self.theme_bg orelse .{
                        constants.colors.bg_r,
                        constants.colors.bg_g,
                        constants.colors.bg_b,
                    };
                    self.sendOscColorResponse(11, bg[0], bg[1], bg[2], use_st);
                },
                .cursor => {
                    // Cursor color - use foreground as default
                    const fg = self.theme_fg orelse .{
                        constants.colors.fg_r,
                        constants.colors.fg_g,
                        constants.colors.fg_b,
                    };
                    self.sendOscColorResponse(12, fg[0], fg[1], fg[2], use_st);
                },
                else => {
                    // TODO(du-3ss): Respond to additional OSC dynamic color queries.
                    log.warn("OSC dynamic color query unhandled: {s}", .{@tagName(d)});
                },
            },
            .palette => |idx| {
                // Palette color query - respond with palette value
                const color = self.terminal.colors.palette.current[idx];
                // OSC 4 response format: OSC 4 ; idx ; rgb:RRRR/GGGG/BBBB ST
                self.sendOsc4ColorResponse(idx, color.r, color.g, color.b, use_st);
            },
            .special => {
                // TODO(du-3ss): Respond to OSC special color queries.
                log.warn("OSC special color query unhandled", .{});
            },
        }
        _ = op; // op tells us which OSC triggered this (4, 10, 11, etc.)
    }

    /// Send OSC 4 palette color response
    fn sendOsc4ColorResponse(self: *Pane, idx: u8, r: u8, g: u8, b: u8, use_st: bool) void {
        // Convert 8-bit to 16-bit by duplicating
        const r16: u16 = @as(u16, r) << 8 | r;
        const g16: u16 = @as(u16, g) << 8 | g;
        const b16: u16 = @as(u16, b) << 8 | b;

        var buf: [40]u8 = undefined;
        const response = if (use_st)
            std.fmt.bufPrint(&buf, "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ idx, r16, g16, b16 }) catch return
        else
            std.fmt.bufPrint(&buf, "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x07", .{ idx, r16, g16, b16 }) catch return;

        self.writeInput(response) catch |e| {
            log.warn("Failed to send OSC 4 response: {any}", .{e});
        };
        log.debug("Sent OSC 4 response: idx={d} rgb:{x:0>4}/{x:0>4}/{x:0>4}", .{ idx, r16, g16, b16 });
    }

    /// Handle Device Status Report request from stream handler
    pub fn handleDSR(self: *Pane, request: device_status.Request) void {
        switch (request) {
            .operating_status => self.sendDSRStatusResponse(),
            .cursor_position => self.sendDSRCursorResponse(),
            .color_scheme => {
                // Color scheme query (CSI ? 996 n) - report light/dark mode
                const bg = self.theme_bg orelse .{
                    constants.colors.bg_r,
                    constants.colors.bg_g,
                    constants.colors.bg_b,
                };
                const luminance = (@as(u32, bg[0]) * 2126 +
                    @as(u32, bg[1]) * 7152 +
                    @as(u32, bg[2]) * 722) / 10_000;
                const is_light = luminance > 127;
                self.sendColorSchemeResponse(is_light);
            },
        }
    }

    /// Send color scheme response (CSI ? 997 ; 1/2 n)
    /// is_light: true for light mode (1), false for dark mode (2)
    fn sendColorSchemeResponse(self: *Pane, is_light: bool) void {
        const response = if (is_light) "\x1b[?997;1n" else "\x1b[?997;2n";
        self.writeInput(response) catch |e| {
            log.warn("Failed to send color scheme response: {any}", .{e});
        };
        dsr_log.debug("Pane {d}: Sent color scheme response ({s})", .{ self.id, if (is_light) "light" else "dark" });
    }

    /// Handle desktop notification from stream handler (OSC 9/777)
    pub fn onDesktopNotification(self: *Pane, title: []const u8, body: []const u8) void {
        self.setNotification(
            if (title.len > 0) title else null,
            body,
        );
    }

    /// Handle progress report from stream handler (OSC 9;4)
    pub fn onProgressReport(self: *Pane, report: osc.Command.ProgressReport) void {
        const state: u8 = switch (report.state) {
            .remove => 0,
            .set => 1,
            .@"error" => 2,
            .indeterminate => 3,
            .pause => 4,
        };
        const value: u8 = report.progress orelse 0;
        self.setProgress(state, value);
    }

    /// Handle shell integration event from stream handler (OSC 133)
    pub fn onShellIntegration(self: *Pane, kind: ShellIntegrationEvent.Kind, exit_code: ?i32) void {
        self.shell_event = .{ .kind = kind, .exit_code = exit_code };
        self.shell_event_pending = true;

        log.info("Shell integration event: {s} exit_code={?d}", .{
            @tagName(kind),
            exit_code,
        });
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

    /// Check if bell was triggered since last cleared
    pub fn hasBell(self: *Pane) bool {
        return self.bell_pending;
    }

    /// Clear the bell pending flag
    pub fn clearBell(self: *Pane) void {
        self.bell_pending = false;
    }

    // ========================================================================
    // Notification API (OSC 9/777) - toast notifications
    // ========================================================================

    /// Set a notification (triggered by OSC 9 or OSC 777)
    pub fn setNotification(self: *Pane, title: ?[]const u8, body: []const u8) void {
        // Free previous notification data
        if (self.notify_title) |t| {
            self.allocator.free(t);
        }
        if (self.notify_body) |b| {
            self.allocator.free(b);
        }

        // Store new notification data
        self.notify_title = if (title) |t| self.allocator.dupe(u8, t) catch null else null;
        self.notify_body = self.allocator.dupe(u8, body) catch null;
        self.notify_pending = true;
        log.debug("Notification set: title={?s}, body={s}", .{ title, body });
    }

    /// Check if there's a pending notification
    pub fn hasNotification(self: *const Pane) bool {
        return self.notify_pending;
    }

    /// Get the pending notification (title, body)
    /// Returns null if no notification pending
    pub fn getNotification(self: *const Pane) ?struct { title: ?[]const u8, body: []const u8 } {
        if (!self.notify_pending) return null;
        if (self.notify_body) |body| {
            return .{ .title = self.notify_title, .body = body };
        }
        return null;
    }

    /// Clear the notification
    pub fn clearNotification(self: *Pane) void {
        if (self.notify_title) |t| {
            self.allocator.free(t);
            self.notify_title = null;
        }
        if (self.notify_body) |b| {
            self.allocator.free(b);
            self.notify_body = null;
        }
        self.notify_pending = false;
    }

    // ========================================================================
    // Progress API (OSC 9;4) - taskbar progress
    // ========================================================================

    /// Set progress state and value
    pub fn setProgress(self: *Pane, state: u8, value: u8) void {
        if (self.progress_state != state or self.progress_value != value) {
            self.progress_state = state;
            self.progress_value = value;
            self.progress_changed = true;
            log.debug("Progress set: state={d}, value={d}", .{ state, value });
        }
    }

    /// Check if progress state has changed
    pub fn hasProgressChanged(self: *const Pane) bool {
        return self.progress_changed;
    }

    /// Get current progress state and value
    pub fn getProgress(self: *const Pane) struct { state: u8, value: u8 } {
        return .{ .state = self.progress_state, .value = self.progress_value };
    }

    /// Clear the progress changed flag
    pub fn clearProgressChanged(self: *Pane) void {
        self.progress_changed = false;
    }

    // ========================================================================
    // Shell Integration API (OSC 133) - semantic prompts
    // ========================================================================

    /// Check if there's a pending shell integration event
    pub fn hasShellEvent(self: *const Pane) bool {
        return self.shell_event_pending;
    }

    /// Get the pending shell integration event (if any)
    pub fn getShellEvent(self: *const Pane) ?ShellIntegrationEvent {
        if (!self.shell_event_pending) return null;
        return self.shell_event;
    }

    /// Clear the shell integration event
    pub fn clearShellEvent(self: *Pane) void {
        self.shell_event = null;
        self.shell_event_pending = false;
    }

    // ========================================================================
    // Clipboard API (OSC 52) - delegates to ClipboardHandler
    // ========================================================================

    /// Check if there's a pending clipboard SET operation
    pub fn hasClipboardSet(self: *const Pane) bool {
        return self.clipboard.hasSet();
    }

    /// Get the pending clipboard SET operation (if any)
    pub fn getClipboardSet(self: *const Pane) ?ClipboardOp {
        return self.clipboard.getSet();
    }

    /// Clear the clipboard SET operation
    pub fn clearClipboardSet(self: *Pane) void {
        self.clipboard.clearSet();
    }

    /// Check if there's a pending clipboard GET request
    pub fn hasClipboardGet(self: *const Pane) bool {
        return self.clipboard.hasGet();
    }

    /// Get the clipboard kind for GET request (if any)
    pub fn getClipboardGetKind(self: *const Pane) ?u8 {
        return self.clipboard.getGetKind();
    }

    /// Clear the clipboard GET request (called when response received or timed out)
    pub fn clearClipboardGet(self: *Pane) void {
        self.clipboard.clearGet();
    }

    /// Check if clipboard GET request needs to be sent to client
    pub fn needsClipboardGetSend(self: *const Pane) bool {
        return self.clipboard.needsGetSend();
    }

    /// Mark clipboard GET as sent to client
    pub fn markClipboardGetSent(self: *Pane) void {
        self.clipboard.markGetSent();
    }

    /// Clipboard GET timeout in milliseconds (5 seconds)
    pub const clipboard_get_timeout_ms: i64 = ClipboardHandler.get_timeout_ms;

    /// Check if a clipboard GET request has timed out
    pub fn hasClipboardGetTimedOut(self: *const Pane) bool {
        return self.clipboard.hasGetTimedOut();
    }

    /// Handle clipboard GET timeout - send empty response and clear pending state
    pub fn handleClipboardGetTimeout(self: *Pane) void {
        if (self.clipboard.checkGetTimeout()) |timeout_info| {
            if (timeout_info.should_timeout) {
                // Send empty response to unblock the terminal
                self.sendClipboardResponse(timeout_info.kind, "");
                self.clipboard.clearGet();
            }
        }
    }

    /// Send OSC 52 clipboard response back to the terminal.
    /// Called when the client responds to a GET request.
    /// kind: 'c', 's', or 'p'
    /// data: base64-encoded clipboard contents
    pub fn sendClipboardResponse(self: *Pane, kind: u8, data: []const u8) void {
        const required_size: usize = 9 + data.len;

        if (required_size > ClipboardHandler.max_response_size) {
            log.warn("OSC 52 response too large: {d} bytes (max {d})", .{
                required_size,
                ClipboardHandler.max_response_size,
            });
            return;
        }

        // Use heap allocation instead of stack to avoid stack overflow
        const buf = self.allocator.alloc(u8, required_size) catch |e| {
            log.warn("Failed to allocate OSC 52 response buffer: {any}", .{e});
            return;
        };
        defer self.allocator.free(buf);

        const response = ClipboardHandler.formatResponse(kind, data, buf) orelse return;

        self.writeInput(response) catch |e| {
            log.warn("Failed to send OSC 52 response: {any}", .{e});
        };
        log.debug("Sent OSC 52 response: kind={c}, data_len={d}", .{ kind, data.len });
        clip_log.debug("OSC 52 response sent: pane={d} kind='{c}' data_len={d}", .{ self.id, kind, data.len });
    }

    /// Get a plain string representation of the terminal contents
    pub fn plainString(self: *Pane) ![]const u8 {
        return self.terminal.plainString(self.allocator);
    }

    /// Resize the pane
    pub fn resize(self: *Pane, cols: u16, rows: u16, cell_width: ?f32, cell_height: ?f32) !void {
        if (cell_width != null and cell_height != null) {
            plog.debug(
                "Pane {d}: Resize {d}x{d} -> {d}x{d} (cell {d:.2}x{d:.2})",
                .{ self.id, self.cols, self.rows, cols, rows, cell_width.?, cell_height.? },
            );
        } else {
            plog.debug(
                "Pane {d}: Resize {d}x{d} -> {d}x{d} (cell default)",
                .{ self.id, self.cols, self.rows, cols, rows },
            );
        }

        self.cols = cols;
        self.rows = rows;
        try self.terminal.resize(self.allocator, cols, rows);
        if (cell_width) |cw| {
            if (cell_height) |ch| {
                if (cw > 0 and ch > 0) {
                    const width_px: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(cols)) * cw));
                    const height_px: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(rows)) * ch));
                    self.terminal.width_px = width_px;
                    self.terminal.height_px = height_px;
                } else {
                    self.terminal.width_px = @as(u32, cols) * @as(u32, constants.terminal.default_cell_width_px);
                    self.terminal.height_px = @as(u32, rows) * @as(u32, constants.terminal.default_cell_height_px);
                }
            } else {
                self.terminal.width_px = @as(u32, cols) * @as(u32, constants.terminal.default_cell_width_px);
                self.terminal.height_px = @as(u32, rows) * @as(u32, constants.terminal.default_cell_height_px);
            }
        } else {
            self.terminal.width_px = @as(u32, cols) * @as(u32, constants.terminal.default_cell_width_px);
            self.terminal.height_px = @as(u32, rows) * @as(u32, constants.terminal.default_cell_height_px);
        }

        // Resize PTY if we have one
        if (self.pty) |*pty| {
            pty.setSize(.{ .ws_row = rows, .ws_col = cols }) catch |e| {
                log.warn("Failed to resize PTY: {any}", .{e});
            };
        }

        // Clear sync output mode (allowed by spec - resize can interrupt sync)
        self.sync_output_enabled = false;
        self.sync_output_start_ns = null;

        if (self.terminal.modes.get(.in_band_size_reports)) {
            self.sendInBandSizeReport();
        }

        // Increment generation first
        self.generation +%= 1;

        // Resize reflows content, invalidating row IDs
        // Force all clients to do full resync
        self.forceFullResync();
    }

    /// Scroll the viewport by delta rows (negative = up, positive = down)
    pub fn scroll(self: *Pane, delta: i32) void {
        self.terminal.screens.active.scroll(.{ .delta_row = delta });

        // Scrolling changes which rows are visible - mark all dirty
        self.markAllRowsDirty();

        // Increment generation to signal clients need update
        self.generation +%= 1;

        log.debug("Scrolled by {d} rows", .{delta});
    }

    /// Get the minimum row ID visible in the current viewport.
    /// Used for server-side cache staleness detection.
    pub fn getMinVisibleRowId(self: *Pane) u64 {
        const pages = &self.terminal.screens.active.pages;
        // Get the top-left pin of the viewport (row 0)
        if (pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } })) |top_pin| {
            return snapshot.computeRowId(top_pin);
        }
        // Fallback: return 0 if no pin (shouldn't happen)
        return 0;
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
        // Increment generation first - this is critical!
        // Clients are at the current generation, so we need the delta's from_gen
        // to be HIGHER than what clients have, triggering snapshot fallback.
        self.generation +%= 1;

        // Clear dirty tracking and set base to new generation
        self.dirty_rows.clearRetainingCapacity();
        self.dirty_base_gen = self.generation;

        // Invalidate cached delta
        if (self.cached_delta) |old| {
            self.allocator.free(old);
            self.cached_delta = null;
        }

        // Set last_broadcast_gen to new generation
        // Now delta from_gen will be higher than client_gen, forcing snapshot
        self.last_broadcast_gen = self.generation;

        delta_log.debug("Pane {d}: forceFullResync, new gen={d}", .{ self.id, self.generation });
    }

    /// Get the set of dirty row IDs since last clear.
    /// Caller must hold the pane lock (this is only called from generateDelta which locks).
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

    /// Get the broadcast delta for the current generation.
    /// Returns owned slice that caller must free.
    /// Also returns the fromGen that clients must be at to apply this delta.
    pub fn getBroadcastDelta(self: *Pane) !struct { delta: []u8, from_gen: u64 } {
        // Check if we already have a cached delta for current generation
        if (self.cached_delta != null and self.last_broadcast_gen == self.generation) {
            // Return a copy of cached delta
            const copy = try self.allocator.dupe(u8, self.cached_delta.?);
            return .{ .delta = copy, .from_gen = self.cached_delta_from_gen };
        }

        // Need to generate new delta
        const from_gen = self.last_broadcast_gen;
        const dirty_count = self.dirty_rows.count();

        // Generate delta
        const delta = try snapshot.generateDelta(self.allocator, self, from_gen, false);

        if (dirty_count > 0) {
            delta_log.debug("Pane {d}: getBroadcastDelta from_gen={d} to_gen={d} dirty_rows={d} delta_size={d}", .{
                self.id,
                from_gen,
                self.generation,
                dirty_count,
                delta.len,
            });
        }

        // Free old cached delta
        if (self.cached_delta) |old| {
            self.allocator.free(old);
        }

        // Cache the new delta
        self.cached_delta = delta;
        self.cached_delta_from_gen = from_gen;
        self.last_broadcast_gen = self.generation;

        // Clear dirty rows now that delta is generated
        self.dirty_rows.clearRetainingCapacity();
        self.dirty_base_gen = self.generation;

        // Return a copy (caller owns it)
        const copy = try self.allocator.dupe(u8, delta);
        return .{ .delta = copy, .from_gen = from_gen };
    }

    /// Check if cursor keys should use application mode (DECCKM)
    /// When true, arrow keys use SS3 sequences (\x1bO), otherwise CSI (\x1b[)
    pub fn isCursorKeyApplication(self: *Pane) bool {
        return self.terminal.modes.get(.cursor_keys);
    }

    /// Get the current mouse event reporting mode.
    /// Returns .none if mouse reporting is disabled.
    /// Used to determine whether to send mouse events to the terminal.
    pub fn getMouseEvents(self: *const Pane) MouseEvents {
        return self.terminal.flags.mouse_event;
    }

    /// Get the current mouse encoding format.
    /// Determines how mouse events are encoded in escape sequences.
    /// Only meaningful when getMouseEvents() != .none
    pub fn getMouseFormat(self: *const Pane) MouseFormat {
        return self.terminal.flags.mouse_format;
    }

    /// Check if mouse event reporting is enabled
    pub fn isMouseEnabled(self: *const Pane) bool {
        return self.terminal.flags.mouse_event != .none;
    }

    /// Check if mouse motion events should be reported.
    /// True for modes 1002 (button) and 1003 (any).
    pub fn wantsMouseMotion(self: *const Pane) bool {
        return self.terminal.flags.mouse_event.motion();
    }

    // ========================================================================
    // Selection API
    // ========================================================================

    /// Start a selection drag from the given viewport coordinates.
    /// Clears any existing selection and marks the start point.
    pub fn startSelection(self: *Pane, x: u16, y: u16) void {
        // Clear any existing selection
        terminal_mod.clearSelection(&self.terminal);

        // Record start position
        self.selection_start = .{ .x = x, .y = y };
        self.selection_active = true;

        log.debug("Selection started at ({d}, {d})", .{ x, y });
    }

    /// Update the selection end point during a drag.
    /// Must be called after startSelection.
    /// @param rectangle If true, create a rectangular selection (Alt+drag)
    pub fn updateSelection(self: *Pane, x: u16, y: u16, rectangle: bool) void {
        const start = self.selection_start orelse {
            log.warn("updateSelection called without startSelection", .{});
            return;
        };

        // Set selection from start to current position
        terminal_mod.setSelection(
            &self.terminal,
            start.x,
            start.y,
            x,
            y,
            rectangle,
        ) catch |e| {
            log.warn("Failed to set selection: {any}", .{e});
            return;
        };

        // Mark pane as dirty so clients receive the update
        self.generation +%= 1;
    }

    /// End the selection drag. The selection remains active until cleared.
    /// Increments generation to trigger client update with final selection state.
    pub fn endSelection(self: *Pane) void {
        self.selection_active = false;
        self.generation +%= 1;
        log.debug("Selection ended", .{});
    }

    /// Check if the given position matches the selection start (single click, no drag).
    /// Returns true if this would be a zero-size selection.
    pub fn isSelectionAtStart(self: *const Pane, x: u16, y: u16) bool {
        const start = self.selection_start orelse return false;
        return start.x == x and start.y == y;
    }

    /// Clear the current selection.
    pub fn clearSelection(self: *Pane) void {
        terminal_mod.clearSelection(&self.terminal);
        self.selection_start = null;
        self.selection_active = false;
        self.generation +%= 1;
        log.debug("Selection cleared", .{});
    }

    /// Check if a selection drag is currently in progress.
    pub fn isSelectionActive(self: *const Pane) bool {
        return self.selection_active;
    }

    /// Check if the terminal has a selection (drag completed or programmatic).
    pub fn hasSelection(self: *const Pane) bool {
        return terminal_mod.hasSelection(@constCast(&self.terminal));
    }

    /// Get the selected text content.
    /// Caller owns the returned memory.
    pub fn getSelectionText(self: *Pane) !?[:0]const u8 {
        return terminal_mod.getSelectionText(&self.terminal, self.allocator);
    }

    /// Select all terminal content.
    /// Returns true if content was selected, false if terminal is empty.
    pub fn selectAll(self: *Pane) !bool {
        const result = try terminal_mod.selectAll(&self.terminal);
        if (result) {
            self.generation +%= 1;
        }
        return result;
    }

    // ========================================================================
    // Theme colors (for OSC 10/11 queries)
    // ========================================================================

    /// Set theme colors from master client.
    /// Called by event_loop when master's theme is updated.
    pub fn setThemeColors(self: *Pane, fg: ?[3]u8, bg: ?[3]u8) void {
        self.theme_fg = fg;
        self.theme_bg = bg;
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

test "mouse mode accessors" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Initially mouse reporting is disabled
    try std.testing.expectEqual(MouseEvents.none, pane.getMouseEvents());
    try std.testing.expectEqual(MouseFormat.x10, pane.getMouseFormat());
    try std.testing.expect(!pane.isMouseEnabled());
    try std.testing.expect(!pane.wantsMouseMotion());

    // Enable SGR mouse mode via escape sequence (DECSET 1000 + 1006)
    try pane.feed("\x1b[?1000h"); // Enable normal mouse tracking
    try std.testing.expectEqual(MouseEvents.normal, pane.getMouseEvents());
    try std.testing.expect(pane.isMouseEnabled());
    try std.testing.expect(!pane.wantsMouseMotion()); // Normal mode doesn't track motion

    try pane.feed("\x1b[?1006h"); // Enable SGR format
    try std.testing.expectEqual(MouseFormat.sgr, pane.getMouseFormat());

    // Enable button tracking (motion while pressed)
    try pane.feed("\x1b[?1002h");
    try std.testing.expectEqual(MouseEvents.button, pane.getMouseEvents());
    try std.testing.expect(pane.wantsMouseMotion());

    // Enable any-event tracking (all motion)
    try pane.feed("\x1b[?1003h");
    try std.testing.expectEqual(MouseEvents.any, pane.getMouseEvents());
    try std.testing.expect(pane.wantsMouseMotion());

    // Disable mouse tracking
    try pane.feed("\x1b[?1003l");
    try std.testing.expectEqual(MouseEvents.none, pane.getMouseEvents());
    try std.testing.expect(!pane.isMouseEnabled());
}

test "OSC 52 clipboard SET" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Initially no clipboard operations pending
    try std.testing.expect(!pane.hasClipboardSet());
    try std.testing.expect(!pane.hasClipboardGet());

    // Feed OSC 52 SET with BEL terminator: ESC ] 52 ; c ; SGVsbG8gV29ybGQ= BEL
    // Base64 "SGVsbG8gV29ybGQ=" decodes to "Hello World"
    try pane.feed("\x1b]52;c;SGVsbG8gV29ybGQ=\x07");

    // Should have pending SET operation
    try std.testing.expect(pane.hasClipboardSet());
    try std.testing.expect(!pane.hasClipboardGet());

    // Verify SET data
    const op = pane.getClipboardSet().?;
    try std.testing.expectEqual(@as(u8, 'c'), op.kind);
    try std.testing.expectEqualStrings("SGVsbG8gV29ybGQ=", op.data);

    // Clear and verify
    pane.clearClipboardSet();
    try std.testing.expect(!pane.hasClipboardSet());
}

test "OSC 52 clipboard GET" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Feed OSC 52 GET with ST terminator: ESC ] 52 ; c ; ? ESC \
    try pane.feed("\x1b]52;c;?\x1b\\");

    // Should have pending GET request
    try std.testing.expect(!pane.hasClipboardSet());
    try std.testing.expect(pane.hasClipboardGet());

    // Verify GET kind
    try std.testing.expectEqual(@as(u8, 'c'), pane.getClipboardGetKind().?);

    // Clear and verify
    pane.clearClipboardGet();
    try std.testing.expect(!pane.hasClipboardGet());
}

test "OSC 52 clipboard with default kind" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Feed OSC 52 with empty kind (defaults to 'c')
    try pane.feed("\x1b]52;;SGVsbG8=\x07");

    try std.testing.expect(pane.hasClipboardSet());
    const op = pane.getClipboardSet().?;
    try std.testing.expectEqual(@as(u8, 'c'), op.kind);
    try std.testing.expectEqualStrings("SGVsbG8=", op.data);
    pane.clearClipboardSet();
}

test "OSC 52 clipboard single character kinds" {
    // Note: ghostty-vt only supports single-character clipboard kinds.
    // Multi-character kinds like "pc" are not supported by the standard parser.
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Test 'c' (clipboard)
    try pane.feed("\x1b]52;c;SGVsbG8=\x07");
    try std.testing.expect(pane.hasClipboardSet());
    const op_c = pane.getClipboardSet().?;
    try std.testing.expectEqual(@as(u8, 'c'), op_c.kind);
    pane.clearClipboardSet();

    // Test 'p' (primary selection)
    try pane.feed("\x1b]52;p;SGVsbG8=\x07");
    try std.testing.expect(pane.hasClipboardSet());
    const op_p = pane.getClipboardSet().?;
    try std.testing.expectEqual(@as(u8, 'p'), op_p.kind);
    pane.clearClipboardSet();

    // Test 's' (selection)
    try pane.feed("\x1b]52;s;SGVsbG8=\x07");
    try std.testing.expect(pane.hasClipboardSet());
    const op_s = pane.getClipboardSet().?;
    try std.testing.expectEqual(@as(u8, 's'), op_s.kind);
    pane.clearClipboardSet();
}

test "OSC 133 shell integration basic" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Initially no shell event
    try std.testing.expect(!pane.hasShellEvent());
    try std.testing.expect(pane.getShellEvent() == null);

    // Feed OSC 133 ; A (prompt start) with BEL terminator
    try pane.feed("\x1b]133;A\x07");
    try std.testing.expect(pane.hasShellEvent());
    const event_a = pane.getShellEvent().?;
    try std.testing.expectEqual(ShellIntegrationEvent.Kind.prompt_start, event_a.kind);
    try std.testing.expect(event_a.exit_code == null);

    // Clear and verify
    pane.clearShellEvent();
    try std.testing.expect(!pane.hasShellEvent());

    // Feed OSC 133 ; B (prompt end) with ST terminator
    try pane.feed("\x1b]133;B\x1b\\");
    try std.testing.expect(pane.hasShellEvent());
    const event_b = pane.getShellEvent().?;
    try std.testing.expectEqual(ShellIntegrationEvent.Kind.prompt_end, event_b.kind);
    pane.clearShellEvent();

    // Feed OSC 133 ; C (output start)
    try pane.feed("\x1b]133;C\x07");
    try std.testing.expect(pane.hasShellEvent());
    const event_c = pane.getShellEvent().?;
    try std.testing.expectEqual(ShellIntegrationEvent.Kind.output_start, event_c.kind);
    pane.clearShellEvent();
}

test "OSC 133 shell integration command_end with exit code" {
    var pane = try Pane.init(std.testing.allocator, .{});
    defer pane.deinit();

    // Feed OSC 133 ; D ; 0 (command end with exit code 0)
    try pane.feed("\x1b]133;D;0\x07");
    try std.testing.expect(pane.hasShellEvent());
    const event_d0 = pane.getShellEvent().?;
    try std.testing.expectEqual(ShellIntegrationEvent.Kind.command_end, event_d0.kind);
    try std.testing.expectEqual(@as(?i32, 0), event_d0.exit_code);
    pane.clearShellEvent();

    // Feed OSC 133 ; D ; 1 (command end with exit code 1)
    try pane.feed("\x1b]133;D;1\x07");
    const event_d1 = pane.getShellEvent().?;
    try std.testing.expectEqual(ShellIntegrationEvent.Kind.command_end, event_d1.kind);
    try std.testing.expectEqual(@as(?i32, 1), event_d1.exit_code);
    pane.clearShellEvent();

    // Feed OSC 133 ; D ; 127 (command end with exit code 127)
    try pane.feed("\x1b]133;D;127\x07");
    const event_d127 = pane.getShellEvent().?;
    try std.testing.expectEqual(ShellIntegrationEvent.Kind.command_end, event_d127.kind);
    try std.testing.expectEqual(@as(?i32, 127), event_d127.exit_code);
    pane.clearShellEvent();

    // Feed OSC 133 ; D (command end without exit code)
    try pane.feed("\x1b]133;D\x07");
    const event_d_no_code = pane.getShellEvent().?;
    try std.testing.expectEqual(ShellIntegrationEvent.Kind.command_end, event_d_no_code.kind);
    try std.testing.expect(event_d_no_code.exit_code == null);
    pane.clearShellEvent();
}

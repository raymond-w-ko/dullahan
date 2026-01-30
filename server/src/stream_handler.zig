//! Custom stream handler for dullahan that extends readonly behavior
//! with query response and notification capability.
//!
//! This handler receives parsed VT events from ghostty-vt and:
//! - Delegates terminal-modifying events to the Terminal (like readonly does)
//! - Routes query events (DA1, DSR, OSC 10/11) to the Pane for response
//! - Routes notification events (bell, title, clipboard) to the Pane
//!
//! This replaces the dual-parser pattern where we had custom OSC/CSI parsers
//! running before ghostty-vt, eliminating state desync issues.

const std = @import("std");
const ghostty = @import("ghostty-vt");

// ghostty-vt exports these types directly
const Terminal = ghostty.Terminal;
const modes = ghostty.modes;
const osc = ghostty.osc;
const osc_color = osc.color;
const device_status = ghostty.device_status;
const kitty_color = ghostty.kitty.color;
const dcs = ghostty.dcs;
const apc = ghostty.apc;
const DeviceAttributeReq = ghostty.DeviceAttributeReq;
const CursorStyleReq = ghostty.CursorStyleReq;
const StreamAction = ghostty.StreamAction;

const Pane = @import("pane.zig").Pane;
const dlog = @import("dlog.zig");

const log = dlog.scoped(.pane);

/// Handler that wraps a Terminal and Pane for full VT event handling.
/// Terminal-modifying events go to the terminal, query/notification events go to the pane.
pub const Handler = struct {
    terminal: *Terminal,
    pane: *Pane,
    dcs: dcs.Handler = .{},
    apc: apc.Handler = .{},

    pub fn init(terminal: *Terminal, pane: *Pane) Handler {
        return .{
            .terminal = terminal,
            .pane = pane,
        };
    }

    pub fn deinit(self: *Handler) void {
        self.dcs.deinit();
        self.apc.deinit();
    }

    /// Main VT event handler - called by ghostty-vt for each parsed action
    pub fn vt(
        self: *Handler,
        comptime action: StreamAction.Tag,
        value: StreamAction.Value(action),
    ) !void {
        switch (action) {
            // =================================================================
            // Events that need pane-level handling (queries, notifications)
            // =================================================================

            .bell => self.pane.onBell(),

            .window_title => self.pane.onWindowTitle(value.title),

            .clipboard_contents => self.pane.onClipboardContents(value.kind, value.data),

            .color_operation => try self.handleColorOp(value),

            .device_attributes => self.handleDeviceAttributes(value),

            .device_status => self.pane.handleDSR(value.request),

            .show_desktop_notification => self.pane.onDesktopNotification(
                value.title,
                value.body,
            ),

            .progress_report => self.pane.onProgressReport(value),

            .semantic_prompt => self.handleSemanticPrompt(value),

            // =================================================================
            // Terminal-modifying events (same as stream_readonly.zig)
            // =================================================================

            .print => try self.terminal.print(value.cp),
            .print_repeat => try self.terminal.printRepeat(value),
            .backspace => self.terminal.backspace(),
            .carriage_return => self.terminal.carriageReturn(),
            .linefeed => try self.terminal.linefeed(),
            .index => try self.terminal.index(),
            .next_line => {
                try self.terminal.index();
                self.terminal.carriageReturn();
            },
            .reverse_index => self.terminal.reverseIndex(),
            .cursor_up => self.terminal.cursorUp(value.value),
            .cursor_down => self.terminal.cursorDown(value.value),
            .cursor_left => self.terminal.cursorLeft(value.value),
            .cursor_right => self.terminal.cursorRight(value.value),
            .cursor_pos => self.terminal.setCursorPos(value.row, value.col),
            .cursor_col => self.terminal.setCursorPos(self.terminal.screens.active.cursor.y + 1, value.value),
            .cursor_row => self.terminal.setCursorPos(value.value, self.terminal.screens.active.cursor.x + 1),
            .cursor_col_relative => self.terminal.setCursorPos(
                self.terminal.screens.active.cursor.y + 1,
                self.terminal.screens.active.cursor.x + 1 +| value.value,
            ),
            .cursor_row_relative => self.terminal.setCursorPos(
                self.terminal.screens.active.cursor.y + 1 +| value.value,
                self.terminal.screens.active.cursor.x + 1,
            ),
            .cursor_style => {
                const blink = switch (value) {
                    .default, .steady_block, .steady_bar, .steady_underline => false,
                    .blinking_block, .blinking_bar, .blinking_underline => true,
                };
                const style: ghostty.Screen.CursorStyle = switch (value) {
                    .default, .blinking_block, .steady_block => .block,
                    .blinking_bar, .steady_bar => .bar,
                    .blinking_underline, .steady_underline => .underline,
                };
                self.terminal.modes.set(.cursor_blinking, blink);
                self.terminal.screens.active.cursor.cursor_style = style;
            },
            .erase_display_below => self.terminal.eraseDisplay(.below, value),
            .erase_display_above => self.terminal.eraseDisplay(.above, value),
            .erase_display_complete => self.terminal.eraseDisplay(.complete, value),
            .erase_display_scrollback => self.terminal.eraseDisplay(.scrollback, value),
            .erase_display_scroll_complete => self.terminal.eraseDisplay(.scroll_complete, value),
            .erase_line_right => self.terminal.eraseLine(.right, value),
            .erase_line_left => self.terminal.eraseLine(.left, value),
            .erase_line_complete => self.terminal.eraseLine(.complete, value),
            .erase_line_right_unless_pending_wrap => self.terminal.eraseLine(.right_unless_pending_wrap, value),
            .delete_chars => self.terminal.deleteChars(value),
            .erase_chars => self.terminal.eraseChars(value),
            .insert_lines => self.terminal.insertLines(value),
            .insert_blanks => self.terminal.insertBlanks(value),
            .delete_lines => self.terminal.deleteLines(value),
            .scroll_up => try self.terminal.scrollUp(value),
            .scroll_down => self.terminal.scrollDown(value),
            .horizontal_tab => self.horizontalTab(value),
            .horizontal_tab_back => self.horizontalTabBack(value),
            .tab_clear_current => self.terminal.tabClear(.current),
            .tab_clear_all => self.terminal.tabClear(.all),
            .tab_set => self.terminal.tabSet(),
            .tab_reset => self.terminal.tabReset(),
            .set_mode => try self.setMode(value.mode, true),
            .reset_mode => try self.setMode(value.mode, false),
            .save_mode => self.terminal.modes.save(value.mode),
            .restore_mode => {
                const v = self.terminal.modes.restore(value.mode);
                try self.setMode(value.mode, v);
            },
            .top_and_bottom_margin => self.terminal.setTopAndBottomMargin(value.top_left, value.bottom_right),
            .left_and_right_margin => self.terminal.setLeftAndRightMargin(value.top_left, value.bottom_right),
            .left_and_right_margin_ambiguous => {
                if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                    self.terminal.setLeftAndRightMargin(0, 0);
                } else {
                    self.terminal.saveCursor();
                }
            },
            .save_cursor => self.terminal.saveCursor(),
            .restore_cursor => self.terminal.restoreCursor(),
            .invoke_charset => self.terminal.invokeCharset(value.bank, value.charset, value.locking),
            .configure_charset => self.terminal.configureCharset(value.slot, value.charset),
            .set_attribute => switch (value) {
                .unknown => {},
                else => self.terminal.setAttribute(value) catch {},
            },
            .protected_mode_off => self.terminal.setProtectedMode(.off),
            .protected_mode_iso => self.terminal.setProtectedMode(.iso),
            .protected_mode_dec => self.terminal.setProtectedMode(.dec),
            .mouse_shift_capture => self.terminal.flags.mouse_shift_capture = if (value) .true else .false,
            .kitty_keyboard_push => self.terminal.screens.active.kitty_keyboard.push(value.flags),
            .kitty_keyboard_pop => self.terminal.screens.active.kitty_keyboard.pop(@intCast(value)),
            .kitty_keyboard_set => self.terminal.screens.active.kitty_keyboard.set(.set, value.flags),
            .kitty_keyboard_set_or => self.terminal.screens.active.kitty_keyboard.set(.@"or", value.flags),
            .kitty_keyboard_set_not => self.terminal.screens.active.kitty_keyboard.set(.not, value.flags),
            .modify_key_format => {
                self.terminal.flags.modify_other_keys_2 = false;
                switch (value) {
                    .other_keys_numeric => self.terminal.flags.modify_other_keys_2 = true,
                    else => {},
                }
            },
            .active_status_display => self.terminal.status_display = value,
            .decaln => try self.terminal.decaln(),
            .full_reset => self.terminal.fullReset(),
            .start_hyperlink => try self.terminal.screens.active.startHyperlink(value.uri, value.id),
            .end_hyperlink => self.terminal.screens.active.endHyperlink(),
            .mouse_shape => self.terminal.mouse_shape = value,
            .kitty_color_report => try self.kittyColorOperation(value),

            // =================================================================
            // DCS/APC - stateful parsing for queries and graphics
            // =================================================================
            .dcs_hook => try self.dcsHook(value),
            .dcs_put => try self.dcsPut(value),
            .dcs_unhook => try self.dcsUnhook(),
            .apc_start => self.apc.start(),
            .apc_end => try self.apcEnd(),
            .apc_put => self.apc.feed(self.pane.allocator, value),

            // =================================================================
            // Ignored events (queries we don't respond to, or no-ops)
            // =================================================================
            .enquiry => {},
            .request_mode => {
                log.debug("Unhandled mode request: {s}", .{@tagName(value.mode)});
            },
            .request_mode_unknown => {
                log.debug("Unhandled unknown mode request: ansi={} mode={d}", .{ value.ansi, value.mode });
            },
            .size_report => {
                log.debug("Unhandled size report request: {s}", .{@tagName(value)});
            },
            .xtversion => {
                log.debug("Unhandled XTVersion request", .{});
            },
            .kitty_keyboard_query => {
                log.debug("Unhandled kitty keyboard query", .{});
            },
            .report_pwd => {
                log.debug("Unhandled report PWD (OSC 7): {s}", .{value.url});
            },
            .title_push => {
                log.debug("Unhandled title push: {d}", .{value});
            },
            .title_pop => {
                log.debug("Unhandled title pop: {d}", .{value});
            },
        }
    }

    fn dcsHook(self: *Handler, payload: ghostty.DCS) !void {
        var cmd = self.dcs.hook(self.pane.allocator, payload) orelse return;
        defer cmd.deinit();
        try self.handleDcsCommand(&cmd);
    }

    fn dcsPut(self: *Handler, byte: u8) !void {
        var cmd = self.dcs.put(byte) orelse return;
        defer cmd.deinit();
        try self.handleDcsCommand(&cmd);
    }

    fn dcsUnhook(self: *Handler) !void {
        var cmd = self.dcs.unhook() orelse return;
        defer cmd.deinit();
        try self.handleDcsCommand(&cmd);
    }

    fn handleDcsCommand(self: *Handler, cmd: *dcs.Command) !void {
        switch (cmd.*) {
            .xtgettcap => |*gettcap| {
                // Respond to a small set of common XTGETTCAP queries.
                while (gettcap.next()) |key| {
                    log.debug("XTGETTCAP request (hex): {s}", .{key});

                    // indn: terminfo capability for "scroll down n lines".
                    // Response "\\E[%p1%dS" = CSI Ps S (scroll down Ps lines).
                    if (xtgettcapMatches(key, "696E646E")) {
                        self.sendXtgettcapResponse(key, "\\E[%p1%dS") catch |e| {
                            log.warn("Failed to send XTGETTCAP indn response: {any}", .{e});
                        };
                        continue;
                    }
                    // Ms: terminfo capability for OSC 52 clipboard operations.
                    // Response "\\E]52;%p1%s;%p2%s\\007" = OSC 52 ; <kind> ; <data> BEL.
                    if (xtgettcapMatches(key, "4D73")) {
                        self.sendXtgettcapResponse(key, "\\E]52;%p1%s;%p2%s\\007") catch |e| {
                            log.warn("Failed to send XTGETTCAP Ms response: {any}", .{e});
                        };
                        continue;
                    }
                    // query-os-name: fish extension for reporting the OS name.
                    // Response is the plain OS name string (e.g., "Linux"/"macOS"), hex-encoded.
                    if (xtgettcapMatches(key, "71756572792D6F732D6E616D65")) {
                        const os_name = getOsName() orelse "unknown";
                        self.sendXtgettcapResponse(key, os_name) catch |e| {
                            log.warn("Failed to send XTGETTCAP query-os-name response: {any}", .{e});
                        };
                        continue;
                    }
                }
            },
            .decrqss => |decrqss| {
                var response: [128]u8 = undefined;
                var stream = std.io.fixedBufferStream(&response);
                const writer = stream.writer();

                const prefix_fmt = "\x1bP{d}$r";
                const prefix_len = std.fmt.comptimePrint(prefix_fmt, .{0}).len;
                stream.pos = prefix_len;

                switch (decrqss) {
                    .none => {},
                    .sgr => {
                        log.debug("DECRQSS: SGR", .{});
                        const buf = try self.terminal.printAttributes(stream.buffer[stream.pos..]);
                        stream.pos += buf.len;
                        try writer.writeByte('m');
                    },
                    .decscusr => {
                        log.debug("DECRQSS: DECSCUSR", .{});
                        const blink = self.terminal.modes.get(.cursor_blinking);
                        const style: u8 = switch (self.terminal.screens.active.cursor.cursor_style) {
                            .block => if (blink) 1 else 2,
                            .underline => if (blink) 3 else 4,
                            .bar => if (blink) 5 else 6,
                            .block_hollow => if (blink) 1 else 2,
                        };
                        try writer.print("{d} q", .{style});
                    },
                    .decstbm => {
                        log.debug("DECRQSS: DECSTBM", .{});
                        try writer.print("{d};{d}r", .{
                            self.terminal.scrolling_region.top + 1,
                            self.terminal.scrolling_region.bottom + 1,
                        });
                    },
                    .decslrm => {
                        log.debug("DECRQSS: DECSLRM", .{});
                        if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                            try writer.print("{d};{d}s", .{
                                self.terminal.scrolling_region.left + 1,
                                self.terminal.scrolling_region.right + 1,
                            });
                        }
                    },
                }

                const valid = stream.pos > prefix_len;
                try writer.writeAll("\x1b\\");
                _ = try std.fmt.bufPrint(response[0..prefix_len], prefix_fmt, .{@intFromBool(valid)});
                self.pane.writeInput(response[0..stream.pos]) catch |e| {
                    log.warn("Failed to send DECRQSS response: {any}", .{e});
                };
            },
            .tmux => {
                log.debug("Ignoring tmux control-mode DCS", .{});
            },
        }
    }

    fn apcEnd(self: *Handler) !void {
        var cmd = self.apc.end() orelse return;
        defer cmd.deinit(self.pane.allocator);

        if (comptime @hasDecl(ghostty.kitty.graphics, "Command")) {
            switch (cmd) {
                .kitty => |*kitty_cmd| {
                    if (self.terminal.kittyGraphics(self.pane.allocator, kitty_cmd)) |resp| {
                        var buf: [1024]u8 = undefined;
                        var writer: std.Io.Writer = .fixed(&buf);
                        try resp.encode(&writer);
                        const final = writer.buffered();
                        if (final.len > 0) {
                            self.pane.writeInput(final) catch |e| {
                                log.warn("Failed to send kitty graphics response: {any}", .{e});
                            };
                        }
                    }
                },
            }
        }
    }

    // =========================================================================
    // Helper methods (same as stream_readonly.zig)
    // =========================================================================

    inline fn horizontalTab(self: *Handler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTab();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    inline fn horizontalTabBack(self: *Handler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTabBack();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    fn setMode(self: *Handler, mode: modes.Mode, enabled: bool) !void {
        self.terminal.modes.set(mode, enabled);

        switch (mode) {
            .autorepeat,
            .reverse_colors,
            => {},

            .origin => self.terminal.setCursorPos(1, 1),

            .enable_left_and_right_margin => if (!enabled) {
                self.terminal.scrolling_region.left = 0;
                self.terminal.scrolling_region.right = self.terminal.cols - 1;
            },

            .alt_screen_legacy => try self.terminal.switchScreenMode(.@"47", enabled),
            .alt_screen => try self.terminal.switchScreenMode(.@"1047", enabled),
            .alt_screen_save_cursor_clear_enter => try self.terminal.switchScreenMode(.@"1049", enabled),

            .save_cursor => if (enabled) {
                self.terminal.saveCursor();
            } else {
                self.terminal.restoreCursor();
            },

            .enable_mode_3 => {},

            .@"132_column" => try self.terminal.deccolm(
                self.terminal.screens.active.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),

            .synchronized_output,
            .linefeed,
            .in_band_size_reports,
            .focus_event,
            => {},

            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },

            .mouse_format_utf8 => self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.flags.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10,

            else => {},
        }
    }

    // =========================================================================
    // Pane-level event handlers (queries and notifications)
    // =========================================================================

    fn handleDeviceAttributes(self: *Handler, req: DeviceAttributeReq) void {
        switch (req) {
            .primary => self.pane.sendDA1Response(),
            .secondary => self.pane.sendDA2Response(),
            .tertiary => {}, // Not implemented
        }
    }

    fn handleColorOp(self: *Handler, value: anytype) !void {
        if (value.requests.count() == 0) return;

        var it = value.requests.constIterator(0);
        while (it.next()) |req| {
            switch (req.*) {
                .query => |target| {
                    // Respond to color query - delegate to pane
                    self.pane.sendColorQueryResponse(value.op, target, value.terminator);
                },
                .set => |set| {
                    // Update terminal colors (same as readonly)
                    switch (set.target) {
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.colors.palette.set(i, set.color);
                        },
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.set(set.color),
                            .background => self.terminal.colors.background.set(set.color),
                            .cursor => self.terminal.colors.cursor.set(set.color),
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => {},
                        },
                        .special => {},
                    }
                },
                .reset => |target| {
                    // Reset terminal colors (same as readonly)
                    switch (target) {
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.colors.palette.reset(i);
                        },
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.reset(),
                            .background => self.terminal.colors.background.reset(),
                            .cursor => self.terminal.colors.cursor.reset(),
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => {},
                        },
                        .special => {},
                    }
                },
                .reset_palette => {
                    const mask = &self.terminal.colors.palette.mask;
                    var mask_it = mask.iterator(.{});
                    while (mask_it.next()) |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(@intCast(i));
                    }
                    mask.* = .initEmpty();
                },
                .reset_special => {},
            }
        }
    }

    fn kittyColorOperation(self: *Handler, request: kitty_color.OSC) !void {
        for (request.list.items) |item| {
            switch (item) {
                .set => |v| switch (v.key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.set(palette, v.color);
                    },
                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.set(v.color),
                        .background => self.terminal.colors.background.set(v.color),
                        .cursor => self.terminal.colors.cursor.set(v.color),
                        else => {},
                    },
                },
                .reset => |key| switch (key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(palette);
                    },
                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.reset(),
                        .background => self.terminal.colors.background.reset(),
                        .cursor => self.terminal.colors.cursor.reset(),
                        else => {},
                    },
                },
                .query => |key| {
                    log.debug("Unhandled kitty color query: {f}", .{key});
                },
            }
        }
    }

    fn handleSemanticPrompt(self: *Handler, cmd: StreamAction.SemanticPrompt) void {
        switch (cmd.action) {
            .fresh_line_new_prompt => {
                const kind = cmd.readOption(.prompt_kind) orelse .initial;
                switch (kind) {
                    .initial, .right => {
                        self.terminal.screens.active.cursor.page_row.semantic_prompt = .prompt;
                        if (cmd.readOption(.redraw)) |redraw| {
                            self.terminal.flags.shell_redraws_prompt = redraw;
                        }
                        // Notify pane of shell integration event
                        self.pane.onShellIntegration(.prompt_start, null);
                    },
                    .continuation, .secondary => {
                        self.terminal.screens.active.cursor.page_row.semantic_prompt = .prompt_continuation;
                    },
                }
            },

            .end_prompt_start_input => {
                self.terminal.markSemanticPrompt(.input);
                self.pane.onShellIntegration(.prompt_end, null);
            },

            .end_input_start_output => {
                self.terminal.markSemanticPrompt(.command);
                self.pane.onShellIntegration(.output_start, null);
            },

            .end_command => {
                self.terminal.screens.active.cursor.page_row.semantic_prompt = .input;
                // Parse exit code from options if available
                const exit_code = cmd.readOption(.exit_code);
                self.pane.onShellIntegration(.command_end, exit_code);
            },

            .end_prompt_start_input_terminate_eol,
            .fresh_line,
            .new_command,
            .prompt_start,
            => {},
        }
    }

    /// Send a DCS XTGETTCAP response (xterm/kitty terminfo query reply).
    /// Format: ESC P 1 + r <hex key> [= <hex value>] ESC \
    /// Key/value are hex-encoded per XTGETTCAP spec.
    fn sendXtgettcapResponse(self: *Handler, key_hex: []const u8, value: []const u8) !void {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        try writer.writeAll("\x1bP1+r");
        try writer.writeAll(key_hex);
        if (value.len > 0) {
            try writer.writeByte('=');
            try writeHex(writer, value);
        }
        try writer.writeAll("\x1b\\");

        const out = stream.buffer[0..stream.pos];
        try self.pane.writeInput(out);
    }
};

fn xtgettcapMatches(key_hex: []const u8, expected_hex: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key_hex, expected_hex);
}

fn writeHex(writer: anytype, bytes: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (bytes) |b| {
        try writer.writeByte(hex[b >> 4]);
        try writer.writeByte(hex[b & 0x0F]);
    }
}

var cached_os_name_buf: [64]u8 = undefined;
var cached_os_name_len: usize = 0;
var cached_os_name_ready: bool = false;
var cached_os_name_mutex: std.Thread.Mutex = .{};

fn getOsName() ?[]const u8 {
    cached_os_name_mutex.lock();
    defer cached_os_name_mutex.unlock();

    if (cached_os_name_ready) {
        return cached_os_name_buf[0..cached_os_name_len];
    }

    var temp: [128]u8 = undefined;
    var len: usize = 0;

    if (std.builtin.target.os.tag == .macos) {
        len = readCommandOutput(&temp, &.{ "sw_vers", "-productName" }) orelse 0;
    }
    if (len == 0) {
        len = readUnameSysname(&temp) orelse 0;
    }
    if (len == 0) {
        return null;
    }

    if (len > cached_os_name_buf.len) {
        len = cached_os_name_buf.len;
    }
    std.mem.copyForwards(u8, cached_os_name_buf[0..len], temp[0..len]);
    cached_os_name_len = len;
    cached_os_name_ready = true;
    return cached_os_name_buf[0..len];
}

fn readUnameSysname(out: []u8) ?usize {
    const uts = std.posix.uname() catch return null;
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    if (sysname.len == 0) return null;
    const len = @min(sysname.len, out.len);
    std.mem.copyForwards(u8, out[0..len], sysname[0..len]);
    return len;
}

fn readCommandOutput(out: []u8, argv: []const []const u8) ?usize {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;
    const n = child.stdout.?.read(out) catch |e| {
        log.debug("Failed to read {s} stdout: {}", .{ argv[0], e });
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return null;
    };

    const term = child.wait() catch return null;
    if (term.Exited != 0) return null;

    var trimmed = std.mem.trim(u8, out[0..n], &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    // If trim removed leading whitespace, compact in-place.
    if (trimmed.ptr != out.ptr) {
        std.mem.copyForwards(u8, out[0..trimmed.len], trimmed);
        trimmed = out[0..trimmed.len];
    }
    return trimmed.len;
}

/// The stream type using our custom handler
pub const Stream = ghostty.Stream(Handler);

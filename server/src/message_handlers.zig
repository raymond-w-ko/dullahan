//! Message handlers extracted from event_loop.zig
//!
//! Handles all parsed message types (keyboard, mouse, clipboard, window management, etc.)
//! This module processes the ParsedMessage union from message_parsing.zig.

const std = @import("std");
const dlog = @import("dlog.zig");
const constants = @import("constants.zig");
const keyboard = @import("keyboard.zig");
const mouse = @import("mouse.zig");
const snapshot = @import("snapshot.zig");
const layout_db = @import("layout_db.zig");
const layout_helpers = @import("layout_helpers.zig");
const websocket = @import("websocket.zig");
const messages = @import("messages.zig");
const Session = @import("session.zig").Session;
const Window = @import("window.zig").Window;
const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const client_state = @import("client_state.zig");
const ClientState = client_state.ClientState;

// Import EventLoop for the handler context
const event_loop = @import("event_loop.zig");
const EventLoop = event_loop.EventLoop;

const log = std.log.scoped(.message_handlers);

// Category-scoped debug loggers
const conn_log = dlog.scoped(.connection);
const clip_log = dlog.scoped(.clipboard);
const window_log = dlog.scoped(.window);

// Message type aliases
const ParsedMessage = messages.ParsedMessage;
const ParsedKeyEvent = messages.ParsedKeyEvent;
const ParsedText = messages.ParsedText;
const ParsedResize = messages.ParsedResize;
const ParsedScroll = messages.ParsedScroll;
const ParsedSync = messages.ParsedSync;
const ParsedResync = messages.ParsedResync;
const ParsedFocus = messages.ParsedFocus;
const ParsedHello = messages.ParsedHello;
const ParsedNewWindow = messages.ParsedNewWindow;
const ParsedCloseWindow = messages.ParsedCloseWindow;
const ParsedClosePane = messages.ParsedClosePane;
const ParsedSetLayout = messages.ParsedSetLayout;
const ParsedResizeLayout = messages.ParsedResizeLayout;
const ParsedSwapPanes = messages.ParsedSwapPanes;
const ParsedMouse = messages.ParsedMouse;
const ParsedSelectAll = messages.ParsedSelectAll;
const ParsedClearSelection = messages.ParsedClearSelection;
const ParsedClipboardResponse = messages.ParsedClipboardResponse;
const ParsedClipboardSet = messages.ParsedClipboardSet;
const ParsedCopy = messages.ParsedCopy;
const ParsedClipboardPaste = messages.ParsedClipboardPaste;

const KeyEvent = messages.KeyEvent;

// ============================================================================
// Error Handling Helpers
// ============================================================================

/// Log a recoverable error with context. Server continues operation.
fn logRecoverable(comptime context: []const u8, err: anyerror) void {
    log.info("[recoverable] {s}: {any}", .{ context, err });
}

/// Log a client-related error. May result in client disconnect.
fn logClientError(comptime context: []const u8, err: anyerror) void {
    log.warn("[client] {s}: {any}", .{ context, err });
}

// ============================================================================
// Main Dispatch Function
// ============================================================================

/// Handle a parsed message (works for both JSON and msgpack protocols).
pub fn handleParsedMessage(el: *EventLoop, msg: ParsedMessage, client: *ClientState) !void {
    switch (msg) {
        .key => |key_msg| try handleKey(el, key_msg),
        .text => |text_msg| try handleText(el, text_msg),
        .resize => |resize_msg| try handleResize(el, client, resize_msg),
        .scroll => |scroll_msg| handleScroll(el, scroll_msg),
        .ping => try handlePing(el, client),
        .sync => |sync_msg| try handleSync(el, client, sync_msg),
        .resync => |resync_msg| try handleResync(el, client, resync_msg),
        .focus => |focus_msg| handleFocus(el, focus_msg),
        .hello => |hello_msg| handleHello(el, client, hello_msg),
        .request_master => handleRequestMaster(el, client),
        .new_window => |new_window_msg| handleNewWindow(el, client, new_window_msg),
        .close_window => |close_window_msg| handleCloseWindow(el, client, close_window_msg),
        .close_pane => |close_pane_msg| handleClosePane(el, client, close_pane_msg),
        .set_layout => |set_layout_msg| handleSetLayout(el, client, set_layout_msg),
        .swap_panes => |swap_msg| handleSwapPanes(el, client, swap_msg),
        .resize_layout => |resize_msg| handleResizeLayout(el, client, resize_msg),
        .mouse => |mouse_msg| handleMouse(el, mouse_msg),
        .select_all => |select_msg| handleSelectAll(el, select_msg),
        .clear_selection => |clear_msg| handleClearSelection(el, clear_msg),
        .clipboard_response => |clip_msg| handleClipboardResponse(el, clip_msg),
        .clipboard_set => |clip_msg| handleClipboardSet(el, clip_msg),
        .copy => |copy_msg| handleCopy(el, copy_msg),
        .clipboard_paste => |paste_msg| handleClipboardPaste(el, paste_msg),
        .unknown => {},
    }
}

// ============================================================================
// Keyboard Input Handlers
// ============================================================================

fn handleKey(el: *EventLoop, key_msg: ParsedKeyEvent) !void {
    if (!std.mem.eql(u8, key_msg.state, "down")) return;

    const pane = el.session.activePane() orelse return;

    // Check if this is a modifier-only key (Ctrl, Shift, Alt, Meta)
    // Don't clear selection for modifier-only keys - they don't produce output
    const is_modifier_only = std.mem.eql(u8, key_msg.code, "ControlLeft") or
        std.mem.eql(u8, key_msg.code, "ControlRight") or
        std.mem.eql(u8, key_msg.code, "ShiftLeft") or
        std.mem.eql(u8, key_msg.code, "ShiftRight") or
        std.mem.eql(u8, key_msg.code, "AltLeft") or
        std.mem.eql(u8, key_msg.code, "AltRight") or
        std.mem.eql(u8, key_msg.code, "MetaLeft") or
        std.mem.eql(u8, key_msg.code, "MetaRight");

    // Clear selection on keyboard input that produces output (not modifier-only)
    if (!is_modifier_only and pane.hasSelection()) {
        pane.clearSelection();
        el.broadcastPaneUpdate(pane) catch |e| {
            logRecoverable("broadcast selection clear on keypress", e);
        };
    }

    var output_buf: [32]u8 = undefined;
    const cursor_key_app = pane.isCursorKeyApplication();

    // Convert ParsedKeyEvent to KeyEvent for keyEventToBytes
    const key_event = KeyEvent{
        .type = "key",
        .key = key_msg.key,
        .code = key_msg.code,
        .state = key_msg.state,
        .ctrl = key_msg.ctrl,
        .alt = key_msg.alt,
        .shift = key_msg.shift,
        .meta = key_msg.meta,
        .repeat = key_msg.repeat,
        .timestamp = key_msg.timestamp,
        .keyCode = key_msg.keyCode,
    };
    const output = keyboard.keyEventToBytes(key_event, &output_buf, cursor_key_app);

    if (output.len > 0) {
        el.session.logPtySend(pane.id, output);
        pane.writeInput(output) catch |e| {
            logRecoverable("write key to PTY", e);
        };
    }
}

fn handleText(el: *EventLoop, text_msg: ParsedText) !void {
    const pane = el.session.activePane() orelse return;

    // Clear selection on any text input
    if (pane.hasSelection()) {
        pane.clearSelection();
        el.broadcastPaneUpdate(pane) catch |e| {
            logRecoverable("broadcast selection clear on text", e);
        };
    }

    // Wrap in bracketed paste sequences if mode is enabled (DECSET 2004)
    if (pane.terminal.modes.get(.bracketed_paste)) {
        const PASTE_START = "\x1b[200~";
        const PASTE_END = "\x1b[201~";

        el.session.logPtySend(pane.id, PASTE_START);
        el.session.logPtySend(pane.id, text_msg.data);
        el.session.logPtySend(pane.id, PASTE_END);

        pane.writeInput(PASTE_START) catch |e| {
            logRecoverable("write paste start to PTY", e);
            return;
        };
        pane.writeInput(text_msg.data) catch |e| {
            logRecoverable("write text to PTY", e);
            return;
        };
        pane.writeInput(PASTE_END) catch |e| {
            logRecoverable("write paste end to PTY", e);
        };
    } else {
        el.session.logPtySend(pane.id, text_msg.data);
        pane.writeInput(text_msg.data) catch |e| {
            logRecoverable("write text to PTY", e);
        };
    }
}

// ============================================================================
// Terminal Control Handlers
// ============================================================================

fn handleResize(el: *EventLoop, client: *ClientState, resize_msg: ParsedResize) !void {
    // Only master can resize
    const client_id = client.client_id orelse return;
    if (!el.isMaster(client_id)) {
        log.debug("Rejecting resize from non-master client {s}", .{client.shortId()});
        return;
    }

    const pane_id = resize_msg.paneId;
    const cols = resize_msg.cols;
    const rows = resize_msg.rows;

    if (cols < constants.limits.min_cols or cols > constants.limits.max_cols or
        rows < constants.limits.min_rows or rows > constants.limits.max_rows)
    {
        log.warn("Rejecting invalid resize for pane {d}: {d}x{d} (limits: {d}-{d}x{d}-{d})", .{
            pane_id, cols, rows,
            constants.limits.min_cols, constants.limits.max_cols,
            constants.limits.min_rows, constants.limits.max_rows,
        });
        return;
    }

    // Resize only the specific pane
    const pane = el.session.pane_registry.get(pane_id) orelse {
        log.warn("Resize for unknown pane {d}", .{pane_id});
        return;
    };
    try pane.resize(cols, rows);
}

fn handleScroll(el: *EventLoop, scroll_msg: ParsedScroll) void {
    const pane = el.session.activePane() orelse return;
    pane.scroll(scroll_msg.delta);
}

fn handlePing(el: *EventLoop, client: *ClientState) !void {
    const pong = try snapshot.generateBinaryPong(el.allocator);
    defer el.allocator.free(pong);
    try client.ws.sendBinary(pong);
}

fn handleSync(el: *EventLoop, client: *ClientState, sync_msg: ParsedSync) !void {
    const pane = el.session.activePane() orelse return;
    try el.handleSyncRequest(client, pane, sync_msg.gen);
}

fn handleResync(el: *EventLoop, client: *ClientState, resync_msg: ParsedResync) !void {
    const pane = el.session.getPaneById(resync_msg.paneId) orelse {
        log.warn("Resync request for unknown pane {d}", .{resync_msg.paneId});
        return;
    };

    log.info("Client requested resync for pane {d}: {s}", .{
        resync_msg.paneId,
        resync_msg.reason,
    });

    // Always send full snapshot, bypassing delta logic
    try el.sendSnapshot(&client.ws, pane);

    // Update client's tracked generation
    client.setGeneration(pane.id, pane.generation);
}

fn handleFocus(el: *EventLoop, focus_msg: ParsedFocus) void {
    const window = el.session.activeWindow() orelse return;
    const old_pane_id = window.active_pane_id;

    if (window.setActivePane(focus_msg.paneId)) {
        // Send focus-out to previously active pane
        if (old_pane_id != focus_msg.paneId) {
            if (el.session.pane_registry.get(old_pane_id)) |old_pane| {
                old_pane.sendFocusOut();
            }
        }

        // Send focus-in to newly active pane
        if (el.session.pane_registry.get(focus_msg.paneId)) |new_pane| {
            new_pane.sendFocusIn();
        }

        log.info("Switched to pane {d}", .{focus_msg.paneId});
    }
}

// ============================================================================
// Client/Master Management Handlers
// ============================================================================

fn handleHello(el: *EventLoop, client: *ClientState, hello_msg: ParsedHello) void {
    client.setClientId(hello_msg.clientId) catch |e| {
        logClientError("set client ID", e);
        return;
    };

    // Mark client as authenticated (dev mode: auto-auth on valid hello)
    // Future: validate hello_msg.token here before setting authenticated
    client.authenticated = true;

    log.info("Client identified: {s}", .{client.shortId()});
    conn_log.info("Client identified: {s}", .{client.shortId()});

    // Auto-assign as master if no master exists
    if (el.master_id == null) {
        if (client.client_id) |cid| {
            log.info("No master, auto-assigning {s} as master", .{client.shortId()});
            conn_log.info("No master, auto-assigning {s} as master", .{client.shortId()});
            el.setMaster(cid) catch |e| {
                logRecoverable("auto-set master", e);
            };
        }
    }

    // If this client is master, store their theme colors for OSC 10/11
    if (client.client_id) |cid| {
        if (el.isMaster(cid)) {
            el.setMasterTheme(hello_msg.themeFg, hello_msg.themeBg);
        }
    }

    // Send current IPC clipboard state to the new client
    el.sendIpcClipboardState(client) catch |e| {
        logRecoverable("send IPC clipboard state", e);
    };
}

fn handleRequestMaster(el: *EventLoop, client: *ClientState) void {
    // Client is requesting to become master
    const client_id = client.client_id orelse {
        log.warn("Anonymous client tried to request master", .{});
        return;
    };

    // Set this client as master (broadcasts to all clients)
    el.setMaster(client_id) catch |e| {
        logRecoverable("set master", e);
    };
}

// ============================================================================
// Window Management Handlers
// ============================================================================

fn handleNewWindow(el: *EventLoop, client: *ClientState, new_window_msg: ParsedNewWindow) void {
    // Only master can create windows
    const client_id = client.client_id orelse return;
    if (!el.isMaster(client_id)) {
        log.debug("Rejecting new_window from non-master client {s}", .{client.shortId()});
        return;
    }

    // Get template ID (default to 2x2 if not specified)
    const template_id = new_window_msg.templateId orelse "2x2";

    // Look up the template
    const template = el.layouts.get(template_id) orelse blk: {
        log.warn("Template '{s}' not found, falling back to 2x2", .{template_id});
        break :blk el.layouts.get("2x2") orelse {
            log.err("Fallback template '2x2' not found", .{});
            return;
        };
    };

    // Count panes needed for this template
    const pane_count = template.countPanes();
    log.info("Creating window with template '{s}' ({d} panes)", .{ template_id, pane_count });
    window_log.info("Creating window with template '{s}' ({d} panes)", .{ template_id, pane_count });

    // Create new window with the required number of panes
    const result = el.session.createWindowWithPaneCount(pane_count) catch |e| {
        logRecoverable("create new window", e);
        return;
    };
    defer el.allocator.free(result.pane_ids);

    log.info("Created new window {d} with {d} panes", .{ result.window_id, pane_count });
    window_log.info("Created new window {d} with {d} panes", .{ result.window_id, pane_count });

    // Assign layout to the new window
    if (el.session.getWindow(result.window_id)) |window| {
        window.setLayoutFromTemplate(template) catch |e| {
            logRecoverable("set layout for new window", e);
        };
    }

    // Broadcast updated layout to all clients
    el.broadcastLayout() catch |e| {
        logRecoverable("broadcast layout", e);
    };

    // Send initial snapshots for new panes to all clients
    for (result.pane_ids) |pane_id| {
        if (el.session.pane_registry.get(pane_id)) |pane| {
            for (el.clients.items) |*c| {
                el.sendSnapshot(&c.ws, pane) catch |e| {
                    logClientError("send snapshot for new pane", e);
                };
                c.setGeneration(pane_id, pane.generation);
            }
        }
    }
}

fn handleCloseWindow(el: *EventLoop, client: *ClientState, close_window_msg: ParsedCloseWindow) void {
    // Only master can close windows
    const client_id = client.client_id orelse return;
    if (!el.isMaster(client_id)) {
        log.debug("Rejecting close_window from non-master client {s}", .{client.shortId()});
        return;
    }

    const window_id = close_window_msg.windowId;

    // Can't close the last window
    if (el.session.windowCount() <= 1) {
        log.warn("Rejecting close_window: can't close the last window", .{});
        return;
    }

    // Close the window (removes window, destroys panes, updates active window)
    el.session.closeWindow(window_id) catch |e| {
        logRecoverable("close window", e);
        return;
    };

    log.info("Closed window {d}", .{window_id});

    // Broadcast updated layout to all clients
    el.broadcastLayout() catch |e| {
        logRecoverable("broadcast layout after close", e);
    };
}

fn handleClosePane(el: *EventLoop, client: *ClientState, close_pane_msg: ParsedClosePane) void {
    // Only master can close panes
    const client_id = client.client_id orelse return;
    if (!el.isMaster(client_id)) {
        log.debug("Rejecting close_pane from non-master client {s}", .{client.shortId()});
        return;
    }

    const pane_id = close_pane_msg.paneId;

    // Find which window contains this pane
    var target_window: ?*Window = null;
    var it = el.session.windows.valueIterator();
    while (it.next()) |window_ptr| {
        if (window_ptr.hasPane(pane_id)) {
            target_window = window_ptr;
            break;
        }
    }

    const window = target_window orelse {
        log.warn("close_pane: pane {d} not found in any window", .{pane_id});
        return;
    };

    // If this is the last pane in the window, close the entire window instead
    if (window.paneCount() <= 1) {
        // Can't close the last pane in the last window
        if (el.session.windowCount() <= 1) {
            log.warn("Rejecting close_pane: can't close the last pane in the last window", .{});
            return;
        }

        // Close the entire window
        const window_id = window.id;
        el.session.closeWindow(window_id) catch |e| {
            logRecoverable("close window (last pane)", e);
            return;
        };
        log.info("Closed window {d} (last pane closed)", .{window_id});
    } else {
        // Remove pane from window and destroy it
        window.removePane(pane_id);
        el.session.pane_registry.destroy(pane_id);
        log.info("Closed pane {d}", .{pane_id});
    }

    // Broadcast updated layout to all clients
    el.broadcastLayout() catch |e| {
        logRecoverable("broadcast layout after close pane", e);
    };
}

// ============================================================================
// Layout Management Handlers
// ============================================================================

fn handleSetLayout(el: *EventLoop, client: *ClientState, set_layout_msg: ParsedSetLayout) void {
    // Only master can change layouts
    const client_id = client.client_id orelse return;
    if (!el.isMaster(client_id)) {
        log.debug("Rejecting set_layout from non-master client {s}", .{client.shortId()});
        return;
    }

    const window_id = set_layout_msg.windowId;
    const template_id = set_layout_msg.templateId;

    // Look up the template
    const template = el.layouts.get(template_id) orelse {
        log.warn("Template '{s}' not found for set_layout", .{template_id});
        return;
    };

    // Get the window
    const window = el.session.getWindow(window_id) orelse {
        log.warn("Window {d} not found for set_layout", .{window_id});
        return;
    };

    // Check if template requires more panes than window has
    const required_panes = template.countPanes();
    const current_panes = window.paneCount();

    if (required_panes > current_panes) {
        // Add panes to fill the layout
        const to_add = required_panes - current_panes;
        var i: usize = 0;
        while (i < to_add) : (i += 1) {
            const new_pane_id = el.session.pane_registry.createShellPane() catch |e| {
                logRecoverable("create pane for layout change", e);
                return;
            };
            window.addPane(new_pane_id) catch |e| {
                logRecoverable("add pane to window for layout change", e);
                return;
            };
            // Send initial snapshot for new pane
            if (el.session.pane_registry.get(new_pane_id)) |new_pane| {
                for (el.clients.items) |*c| {
                    el.sendSnapshot(&c.ws, new_pane) catch |e| {
                        logClientError("send snapshot for new pane", e);
                    };
                    c.setGeneration(new_pane_id, new_pane.generation);
                }
            }
        }
        log.info("Added {d} panes to window {d} for layout '{s}'", .{ to_add, window_id, template_id });
    } else if (required_panes < current_panes) {
        // Extra panes become hidden (not rendered in layout, but still exist)
        const hidden = current_panes - required_panes;
        log.info("Window {d} has {d} hidden panes after layout change to '{s}'", .{ window_id, hidden, template_id });
    }

    // Log current dimensions before reset (for debugging)
    if (window.layout_nodes) |old_nodes| {
        log.info("Before reset - current layout dimensions:", .{});
        layout_helpers.logLayoutDimensions(old_nodes, 0);
    }

    // Apply the new layout (clones fresh nodes from template with original dimensions)
    window.setLayoutFromTemplate(template) catch |e| {
        logRecoverable("set layout from template", e);
        return;
    };

    // Log the new layout dimensions for debugging
    if (window.layout_nodes) |nodes| {
        log.info("Changed window {d} layout to '{s}' - reset to template dimensions", .{ window_id, template_id });
        layout_helpers.logLayoutDimensions(nodes, 0);
    } else {
        log.info("Changed window {d} layout to '{s}'", .{ window_id, template_id });
    }

    // Broadcast updated layout to all clients
    el.broadcastLayout() catch |e| {
        logRecoverable("broadcast layout after set_layout", e);
    };
}

fn handleSwapPanes(el: *EventLoop, client: *ClientState, swap_msg: ParsedSwapPanes) void {
    // Only master can swap panes
    const client_id = client.client_id orelse return;
    if (!el.isMaster(client_id)) {
        log.debug("Rejecting swap_panes from non-master client {s}", .{client.shortId()});
        return;
    }

    const window_id = swap_msg.windowId;
    const pane_id1 = swap_msg.paneId1;
    const pane_id2 = swap_msg.paneId2;

    // Get the window
    const window = el.session.getWindow(window_id) orelse {
        log.warn("Window {d} not found for swap_panes", .{window_id});
        return;
    };

    // Swap the pane positions
    if (!window.swapPanePositions(pane_id1, pane_id2)) {
        log.warn("Failed to swap panes {d} and {d} in window {d}: one or both panes not found", .{ pane_id1, pane_id2, window_id });
        return;
    }

    log.info("Swapped panes {d} and {d} in window {d}", .{ pane_id1, pane_id2, window_id });

    // Re-apply layout with new pane order
    if (el.layouts.get(window.template_id orelse "")) |template| {
        window.setLayoutFromTemplate(template) catch |e| {
            logRecoverable("re-apply layout after swap_panes", e);
            return;
        };
    }

    // Broadcast updated layout to all clients
    el.broadcastLayout() catch |e| {
        logRecoverable("broadcast layout after swap_panes", e);
    };
}

fn handleResizeLayout(el: *EventLoop, client: *ClientState, resize_msg: ParsedResizeLayout) void {
    // Only master can resize layout
    const client_id = client.client_id orelse return;
    if (!el.isMaster(client_id)) {
        log.debug("Rejecting resize_layout from non-master client {s}", .{client.shortId()});
        return;
    }

    const window_id = resize_msg.windowId;

    // Get the window
    const window = el.session.getWindow(window_id) orelse {
        log.warn("Window {d} not found for resize_layout", .{window_id});
        return;
    };

    // Parse and validate the new layout nodes
    const new_nodes = layout_helpers.parseLayoutNodesFromJson(el.allocator, resize_msg.nodes) catch |e| {
        log.warn("Failed to parse resize_layout nodes: {any}", .{e});
        return;
    };
    defer layout_helpers.freeLayoutNodes(el.allocator, new_nodes);

    // Validate percentages (each sibling group should sum to ~100%)
    if (!layout_helpers.validateLayoutPercentages(new_nodes)) {
        log.warn("Invalid layout percentages in resize_layout", .{});
        return;
    }

    // Update window's layout nodes in place
    if (window.layout_nodes) |old_nodes| {
        // Deep copy new dimensions into existing layout, preserving pane IDs
        layout_helpers.copyLayoutDimensions(old_nodes, new_nodes) catch |e| {
            log.warn("Failed to copy layout dimensions: {any}", .{e});
            return;
        };
    } else {
        log.warn("Window {d} has no layout to resize", .{window_id});
        return;
    }

    log.info("Resized layout for window {d} - new dimensions:", .{window_id});
    if (window.layout_nodes) |nodes| {
        layout_helpers.logLayoutDimensions(nodes, 0);
    }

    // Broadcast updated layout to all clients
    el.broadcastLayout() catch |e| {
        logRecoverable("broadcast layout after resize_layout", e);
    };
}

// ============================================================================
// Mouse Handler
// ============================================================================

fn handleMouse(el: *EventLoop, mouse_msg: ParsedMouse) void {
    log.debug("Mouse {s}: pane={d} button={d} pos=({d},{d}) px=({?},{?}) mods={s}{s}{s}{s} ts={d:.3}", .{
        mouse_msg.state,
        mouse_msg.paneId,
        mouse_msg.button,
        mouse_msg.x,
        mouse_msg.y,
        mouse_msg.px,
        mouse_msg.py,
        if (mouse_msg.ctrl) "C" else "",
        if (mouse_msg.alt) "A" else "",
        if (mouse_msg.shift) "S" else "",
        if (mouse_msg.meta) "M" else "",
        mouse_msg.timestamp,
    });

    // Get pane and check mouse mode
    const pane = el.session.getPaneById(mouse_msg.paneId) orelse {
        log.warn("Mouse event for unknown pane {d}", .{mouse_msg.paneId});
        return;
    };

    // Check if terminal has mouse reporting enabled
    const mouse_events = pane.getMouseEvents();

    // Terminal selection is used when:
    // 1. App doesn't have mouse mode enabled (mouse_events == .none), OR
    // 2. Shift is held (shift-click bypasses app mouse handling)
    const do_terminal_selection = mouse_events == .none or mouse_msg.shift;

    if (do_terminal_selection) {
        handleTerminalSelection(el, pane, mouse_msg);
        return;
    }

    // Sending to app - clear any existing terminal selection on mousedown
    // This prevents "fighting" between terminal selection and app selection
    const is_press = std.mem.eql(u8, mouse_msg.state, "down");
    if (is_press and pane.hasSelection()) {
        pane.clearSelection();
        log.debug("Cleared terminal selection (app mouse mode active)", .{});
        el.broadcastPaneUpdate(pane) catch |e| {
            logRecoverable("broadcast selection clear for app", e);
        };
    }

    // Check if this event type should be reported
    const is_motion = std.mem.eql(u8, mouse_msg.state, "move");
    if (is_motion and !mouse_events.motion()) {
        log.debug("Mouse motion ignored (mode={s})", .{@tagName(mouse_events)});
        return;
    }

    // For X10 mode (9), only report button presses (not releases)
    const is_release = std.mem.eql(u8, mouse_msg.state, "up");
    if (mouse_events == .x10 and is_release) {
        log.debug("Mouse release ignored (X10 mode)", .{});
        return;
    }

    const mouse_format = pane.getMouseFormat();
    log.debug("Mouse event accepted: mode={s} format={s}", .{
        @tagName(mouse_events),
        @tagName(mouse_format),
    });

    // Build mouse event for encoding
    const mouse_state = mouse.MouseState.fromString(mouse_msg.state) orelse {
        log.warn("Unknown mouse state: {s}", .{mouse_msg.state});
        return;
    };

    const event = mouse.MouseEvent{
        .button = mouse_msg.button,
        .x = mouse_msg.x,
        .y = mouse_msg.y,
        .px = mouse_msg.px,
        .py = mouse_msg.py,
        .state = mouse_state,
        .modifiers = .{
            .ctrl = mouse_msg.ctrl,
            .alt = mouse_msg.alt,
            .shift = mouse_msg.shift,
            .meta = mouse_msg.meta,
        },
    };

    // X10 mode (DECSET 9) doesn't have modifiers, but normal mode (1000) does
    const include_x10_modifiers = mouse_events != .x10;

    // Encode and send mouse event
    var buf: [48]u8 = undefined;
    const result = mouse.encode(event, mouse_format, &buf, include_x10_modifiers) orelse {
        log.debug("Failed to encode mouse event (format={s})", .{@tagName(mouse_format)});
        return;
    };

    // Write to PTY
    const mouse_seq = result.slice();
    el.session.logPtySend(pane.id, mouse_seq);
    pane.writeInput(mouse_seq) catch |e| {
        logRecoverable("send mouse event", e);
        return;
    };
    log.debug("Sent {s} mouse: pos=({d},{d})", .{ @tagName(mouse_format), mouse_msg.x, mouse_msg.y });
}

/// Handle terminal selection (when mouse mode is disabled or shift is held)
fn handleTerminalSelection(el: *EventLoop, pane: *Pane, mouse_msg: ParsedMouse) void {
    // Middle-click (button 1) pastes from primary clipboard
    if (mouse_msg.button == 1) {
        const is_down = std.mem.eql(u8, mouse_msg.state, "down");
        if (is_down) {
            // Paste from primary clipboard
            if (el.ipc_clipboard_p) |text| {
                clip_log.info("Middle-click paste: pane={d} text_len={d}", .{
                    mouse_msg.paneId,
                    text.len,
                });

                // Write to PTY with bracketed paste support
                if (pane.terminal.modes.get(.bracketed_paste)) {
                    const PASTE_START = "\x1b[200~";
                    const PASTE_END = "\x1b[201~";

                    el.session.logPtySend(pane.id, PASTE_START);
                    el.session.logPtySend(pane.id, text);
                    el.session.logPtySend(pane.id, PASTE_END);

                    pane.writeInput(PASTE_START) catch |e| {
                        logRecoverable("write paste start for middle-click", e);
                        return;
                    };
                    pane.writeInput(text) catch |e| {
                        logRecoverable("write text for middle-click paste", e);
                        return;
                    };
                    pane.writeInput(PASTE_END) catch |e| {
                        logRecoverable("write paste end for middle-click", e);
                    };
                } else {
                    el.session.logPtySend(pane.id, text);
                    pane.writeInput(text) catch |e| {
                        logRecoverable("write text for middle-click paste", e);
                    };
                }

                log.debug("Middle-click pasted to pane {d}: {d} chars", .{ pane.id, text.len });
            } else {
                log.debug("Middle-click paste: primary clipboard is empty", .{});
            }
        }
        return;
    }

    // Left button (0) triggers selection
    if (mouse_msg.button == 0) {
        const is_down = std.mem.eql(u8, mouse_msg.state, "down");
        const is_move = std.mem.eql(u8, mouse_msg.state, "move");
        const is_up = std.mem.eql(u8, mouse_msg.state, "up");

        if (is_down) {
            // Start selection
            pane.startSelection(mouse_msg.x, mouse_msg.y);
            // Update with initial point (creates zero-size selection)
            pane.updateSelection(mouse_msg.x, mouse_msg.y, mouse_msg.alt);
            // Broadcast update to all clients
            el.broadcastPaneUpdate(pane) catch |e| {
                logRecoverable("broadcast selection start", e);
            };
        } else if (is_move and pane.isSelectionActive()) {
            // Update selection during drag
            // Alt key creates rectangular selection
            pane.updateSelection(mouse_msg.x, mouse_msg.y, mouse_msg.alt);
            // Broadcast update to all clients
            el.broadcastPaneUpdate(pane) catch |e| {
                logRecoverable("broadcast selection update", e);
            };
        } else if (is_up and pane.isSelectionActive()) {
            // Check if this was a single click (no drag)
            if (pane.isSelectionAtStart(mouse_msg.x, mouse_msg.y)) {
                // Single click - clear selection instead of keeping empty one
                pane.clearSelection();
                log.debug("Single click - cleared empty selection", .{});
            } else {
                // Real drag - update selection to final position before ending
                // This is important when mouseMove events are disabled on client
                pane.updateSelection(mouse_msg.x, mouse_msg.y, mouse_msg.alt);
                pane.endSelection();

                // Auto-update primary (p) clipboard with selection text
                // This is standard X11 terminal behavior - select to copy to primary
                el.updatePrimaryClipboardFromSelection(pane);
            }
            // Final broadcast
            el.broadcastPaneUpdate(pane) catch |e| {
                logRecoverable("broadcast selection end", e);
            };
        }
    }
}

// ============================================================================
// Selection Handlers
// ============================================================================

fn handleSelectAll(el: *EventLoop, select_msg: ParsedSelectAll) void {
    const pane = el.session.getPaneById(select_msg.paneId) orelse {
        log.warn("select_all for unknown pane {d}", .{select_msg.paneId});
        return;
    };

    const selected = pane.selectAll() catch |e| {
        logRecoverable("select_all", e);
        return;
    };

    if (selected) {
        log.debug("Selected all content in pane {d}", .{select_msg.paneId});
        // Broadcast update to all clients
        el.broadcastPaneUpdate(pane) catch |e| {
            logRecoverable("broadcast select_all", e);
        };
    } else {
        log.debug("select_all: pane {d} is empty", .{select_msg.paneId});
    }
}

fn handleClearSelection(el: *EventLoop, clear_msg: ParsedClearSelection) void {
    const pane = el.session.getPaneById(clear_msg.paneId) orelse {
        log.warn("clear_selection for unknown pane {d}", .{clear_msg.paneId});
        return;
    };

    pane.clearSelection();
    log.debug("Cleared selection in pane {d}", .{clear_msg.paneId});

    // Broadcast update to all clients
    el.broadcastPaneUpdate(pane) catch |e| {
        logRecoverable("broadcast clear_selection", e);
    };
}

// ============================================================================
// Clipboard Handlers
// ============================================================================

fn handleClipboardResponse(el: *EventLoop, clip_msg: ParsedClipboardResponse) void {
    // Client responding to an OSC 52 GET request
    const pane = el.session.getPaneById(clip_msg.paneId) orelse {
        log.warn("clipboard_response for unknown pane {d}", .{clip_msg.paneId});
        return;
    };

    // Extract clipboard kind (first char of string, default 'c')
    const kind: u8 = if (clip_msg.clipboard.len > 0) clip_msg.clipboard[0] else 'c';

    clip_log.info("Clipboard response: pane={d} kind='{c}' data_len={d}", .{
        clip_msg.paneId,
        kind,
        clip_msg.data.len,
    });

    // Send the OSC 52 response back to the terminal
    pane.sendClipboardResponse(kind, clip_msg.data);

    // Clear the pending GET state (response received)
    pane.clearClipboardGet();

    log.debug("Forwarded clipboard response to pane {d}: kind={c}, data_len={d}", .{
        clip_msg.paneId,
        kind,
        clip_msg.data.len,
    });
}

fn handleClipboardSet(el: *EventLoop, clip_msg: ParsedClipboardSet) void {
    // Client updating server's clipboard storage (from browser clipboard bar)
    const kind: u8 = if (clip_msg.clipboard.len > 0) clip_msg.clipboard[0] else 'c';

    clip_log.info("Clipboard set from client: kind='{c}' data_len={d}", .{
        kind,
        clip_msg.data.len,
    });

    // Update server's clipboard storage
    el.updateIpcClipboardFromBase64(kind, clip_msg.data);

    log.debug("Updated IPC clipboard from client: kind={c}, data_len={d}", .{
        kind,
        clip_msg.data.len,
    });
}

fn handleCopy(el: *EventLoop, copy_msg: ParsedCopy) void {
    // Client requesting to copy selection to clipboard
    const pane = el.session.getPaneById(copy_msg.paneId) orelse {
        log.warn("copy for unknown pane {d}", .{copy_msg.paneId});
        return;
    };

    // Get the selected text from the terminal
    const selected_text = pane.getSelectionText() catch |e| {
        logRecoverable("get selection text for copy", e);
        return;
    };

    if (selected_text) |text| {
        defer pane.allocator.free(text);

        clip_log.info("Copy: pane={d} text_len={d}", .{ copy_msg.paneId, text.len });

        // Store in ipc_clipboard_c (system clipboard)
        const text_copy = el.allocator.dupe(u8, text) catch |e| {
            logRecoverable("allocate clipboard text", e);
            return;
        };
        if (el.ipc_clipboard_c) |old| {
            el.allocator.free(old);
        }
        el.ipc_clipboard_c = text_copy;

        // Broadcast clipboard SET to all clients
        const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
        const base64_data = el.allocator.alloc(u8, encoded_len) catch |e| {
            logRecoverable("allocate base64 for copy", e);
            return;
        };
        defer el.allocator.free(base64_data);
        _ = std.base64.standard.Encoder.encode(base64_data, text);

        const clipboard_msg = snapshot.generateClipboardMessage(
            el.allocator,
            copy_msg.paneId,
            "set",
            'c',
            base64_data,
        ) catch |e| {
            logRecoverable("generate clipboard message for copy", e);
            return;
        };
        defer el.allocator.free(clipboard_msg);
        el.wsBroadcastAll(clipboard_msg);

        log.debug("Copied selection from pane {d}: {d} chars", .{ copy_msg.paneId, text.len });
    } else {
        log.debug("Copy: no selection in pane {d}", .{copy_msg.paneId});
    }
}

fn handleClipboardPaste(el: *EventLoop, paste_msg: ParsedClipboardPaste) void {
    // Client requesting to paste from server clipboard to PTY
    const pane = el.session.getPaneById(paste_msg.paneId) orelse {
        log.warn("clipboard_paste for unknown pane {d}", .{paste_msg.paneId});
        return;
    };

    const kind = paste_msg.clipboard; // Already a u8 ('c' or 'p')
    const text = if (kind == 'p') el.ipc_clipboard_p else el.ipc_clipboard_c;

    if (text) |data| {
        clip_log.info("Clipboard paste: pane={d} kind='{c}' text_len={d}", .{
            paste_msg.paneId,
            kind,
            data.len,
        });

        // Write to PTY with bracketed paste support
        if (pane.terminal.modes.get(.bracketed_paste)) {
            const PASTE_START = "\x1b[200~";
            const PASTE_END = "\x1b[201~";

            el.session.logPtySend(pane.id, PASTE_START);
            el.session.logPtySend(pane.id, data);
            el.session.logPtySend(pane.id, PASTE_END);

            pane.writeInput(PASTE_START) catch |e| {
                logRecoverable("write paste start to PTY", e);
                return;
            };
            pane.writeInput(data) catch |e| {
                logRecoverable("write clipboard text to PTY", e);
                return;
            };
            pane.writeInput(PASTE_END) catch |e| {
                logRecoverable("write paste end to PTY", e);
            };
        } else {
            el.session.logPtySend(pane.id, data);
            pane.writeInput(data) catch |e| {
                logRecoverable("write clipboard text to PTY", e);
            };
        }

        log.debug("Pasted '{c}' clipboard to pane {d}: {d} chars", .{ kind, paste_msg.paneId, data.len });
    } else {
        log.debug("Clipboard paste: '{c}' clipboard is empty", .{kind});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "message_handlers imports compile" {
    // This test just verifies the module compiles correctly
    _ = handleParsedMessage;
}

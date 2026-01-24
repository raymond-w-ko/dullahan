//! Wire protocol message types for client↔server communication
//!
//! Contains JSON message structs (for parsing incoming messages) and
//! ParsedMessage union (protocol-agnostic representation).

const std = @import("std");
const keyboard = @import("keyboard.zig");

// ============================================================================
// JSON Message Types (for parsing client messages)
// ============================================================================

pub const KeyEvent = keyboard.KeyEvent;

pub const TextMessage = struct {
    type: []const u8,
    data: []const u8,
};

pub const ResizeMessage = struct {
    type: []const u8,
    cols: u16,
    rows: u16,
};

pub const ScrollMessage = struct {
    type: []const u8,
    delta: i32,
};

pub const SyncMessage = struct {
    type: []const u8,
    gen: u64,
    minRowId: u64,
};

pub const FocusMessage = struct {
    type: []const u8,
    paneId: u16,
};

pub const MouseMessage = struct {
    type: []const u8,
    paneId: u16,
    button: u8,
    x: u16,
    y: u16,
    px: ?u32 = null, // Pixel X coordinate (for SGR-Pixels mode 1016)
    py: ?u32 = null, // Pixel Y coordinate (for SGR-Pixels mode 1016)
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    timestamp: f64 = 0,
};

pub const HelloMessage = struct {
    type: []const u8,
    clientId: []const u8,
    themeFg: ?[]const u8 = null,
    themeBg: ?[]const u8 = null,
    /// Optional auth token for future authentication support
    token: ?[]const u8 = null,
};

pub const NewWindowMessage = struct {
    type: []const u8,
    templateId: ?[]const u8 = null,
};

pub const CloseWindowMessage = struct {
    type: []const u8,
    windowId: u16,
};

pub const ClosePaneMessage = struct {
    type: []const u8,
    paneId: u16,
};

pub const SetLayoutMessage = struct {
    type: []const u8,
    windowId: u16,
    templateId: []const u8,
};

pub const SwapPanesMessage = struct {
    type: []const u8,
    windowId: u16,
    paneId1: u16,
    paneId2: u16,
};

/// Resize layout message - sent when user drags dividers
pub const ResizeLayoutMessage = struct {
    type: []const u8,
    windowId: u16,
    nodes: std.json.Value, // Raw JSON array of layout nodes
};

pub const ClipboardResponseMessage = struct {
    type: []const u8,
    paneId: u16,
    clipboard: []const u8,
    data: []const u8,
};

/// Client-initiated clipboard update (from browser clipboard bar)
pub const ClipboardSetMessage = struct {
    type: []const u8,
    clipboard: []const u8, // "c" or "p"
    data: []const u8, // base64-encoded text
};

/// Copy selection to clipboard (from keybind copy action)
pub const CopyMessage = struct {
    type: []const u8,
    paneId: u16,
};

/// Paste from clipboard to PTY (from clipboard bar down arrow or middle-click)
pub const ClipboardPasteMessage = struct {
    type: []const u8,
    paneId: u16,
    clipboard: []const u8, // "c" or "p"
};

pub const MessageType = struct {
    type: []const u8,
};

// ============================================================================
// Parsed Message Union (protocol-agnostic)
// ============================================================================

/// Unified message representation for both JSON and msgpack protocols.
/// Borrows string data from the underlying protocol payload.
pub const ParsedMessage = union(enum) {
    key: ParsedKeyEvent,
    text: ParsedText,
    resize: ParsedResize,
    scroll: ParsedScroll,
    ping: void,
    sync: ParsedSync,
    focus: ParsedFocus,
    hello: ParsedHello,
    request_master: void,
    new_window: ParsedNewWindow,
    close_window: ParsedCloseWindow,
    close_pane: ParsedClosePane,
    set_layout: ParsedSetLayout,
    resize_layout: ParsedResizeLayout,
    swap_panes: ParsedSwapPanes,
    mouse: ParsedMouse,
    select_all: ParsedSelectAll,
    clear_selection: ParsedClearSelection,
    clipboard_response: ParsedClipboardResponse,
    clipboard_set: ParsedClipboardSet,
    copy: ParsedCopy,
    clipboard_paste: ParsedClipboardPaste,
    unknown: void,
};

pub const ParsedKeyEvent = struct {
    key: []const u8,
    code: []const u8 = "",
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    repeat: bool = false,
    timestamp: f64 = 0,
    keyCode: u16 = 0,
};

pub const ParsedText = struct {
    data: []const u8,
};

pub const ParsedResize = struct {
    cols: u16,
    rows: u16,
};

pub const ParsedScroll = struct {
    delta: i32,
};

pub const ParsedSync = struct {
    gen: u64,
    minRowId: u64 = 0,
};

pub const ParsedFocus = struct {
    paneId: u16,
};

pub const ParsedHello = struct {
    clientId: []const u8,
    /// Theme foreground color (e.g., "#abb2bf")
    themeFg: ?[]const u8 = null,
    /// Theme background color (e.g., "#282c34")
    themeBg: ?[]const u8 = null,
    /// Optional auth token for future authentication support
    token: ?[]const u8 = null,
};

pub const ParsedNewWindow = struct {
    templateId: ?[]const u8 = null,
};

pub const ParsedCloseWindow = struct {
    windowId: u16,
};

pub const ParsedClosePane = struct {
    paneId: u16,
};

pub const ParsedSetLayout = struct {
    windowId: u16,
    templateId: []const u8,
};

pub const ParsedSwapPanes = struct {
    windowId: u16,
    paneId1: u16,
    paneId2: u16,
};

pub const ParsedResizeLayout = struct {
    windowId: u16,
    nodes: std.json.Value, // Raw JSON array - parsed into LayoutNode[] by handler
};

pub const ParsedMouse = struct {
    paneId: u16,
    button: u8,
    x: u16,
    y: u16,
    px: ?u32 = null,
    py: ?u32 = null,
    state: []const u8,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    timestamp: f64 = 0,
};

pub const ParsedSelectAll = struct {
    paneId: u16,
};

pub const ParsedClearSelection = struct {
    paneId: u16,
};

pub const ParsedClipboardResponse = struct {
    paneId: u16,
    clipboard: []const u8,
    data: []const u8,
};

pub const ParsedClipboardSet = struct {
    clipboard: []const u8,
    data: []const u8,
};

pub const ParsedCopy = struct {
    paneId: u16,
};

pub const ParsedClipboardPaste = struct {
    paneId: u16,
    clipboard: u8, // 'c' or 'p' - just the first char
};

/// Cleanup helper for JSON parsed messages.
/// Holds references to parsed JSON that need to be freed after message handling.
pub const JsonCleanup = union(enum) {
    none: void,
    json_key: std.json.Parsed(KeyEvent),
    json_text: std.json.Parsed(TextMessage),
    json_hello: std.json.Parsed(HelloMessage),
    json_new_window: std.json.Parsed(NewWindowMessage),
    json_set_layout: std.json.Parsed(SetLayoutMessage),
    json_resize_layout: std.json.Parsed(ResizeLayoutMessage),
    json_swap_panes: std.json.Parsed(SwapPanesMessage),
    json_mouse: std.json.Parsed(MouseMessage),
    json_clipboard_response: std.json.Parsed(ClipboardResponseMessage),
    json_clipboard_set: std.json.Parsed(ClipboardSetMessage),

    pub fn deinit(self: *JsonCleanup) void {
        switch (self.*) {
            .none => {},
            .json_key => |*p| p.deinit(),
            .json_text => |*p| p.deinit(),
            .json_hello => |*p| p.deinit(),
            .json_new_window => |*p| p.deinit(),
            .json_set_layout => |*p| p.deinit(),
            .json_resize_layout => |*p| p.deinit(),
            .json_swap_panes => |*p| p.deinit(),
            .json_mouse => |*p| p.deinit(),
            .json_clipboard_response => |*p| p.deinit(),
            .json_clipboard_set => |*p| p.deinit(),
        }
    }
};

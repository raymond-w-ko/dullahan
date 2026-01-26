# Plan: Migrate from Dual-Parser to Single ghostty-vt Handler

**Status:** Proposed
**Created:** 2026-01-26
**Author:** Claude (with rko)

## Executive Summary

Replace dullahan's custom OSC/CSI parsing (~300 lines) with a custom ghostty-vt stream handler that receives parsed events and can respond to queries. This eliminates dual-parsing sync issues and leverages ghostty-vt's well-tested state machine.

## Problem Statement

User reported "OSC being echoed after a program quits" - suggesting state desync between dullahan's custom parser and ghostty-vt's parser, both of which process the same PTY data independently.

## Current Architecture

```
PTY read
    |
pane.feed(data)
    |
handleTerminalQueries(data)  <-- Custom CSI parser (~40 lines)
handleOscSequences(data)     <-- Custom OSC parser (~200 lines, has osc_buffer)
handleBell(data)             <-- Custom BEL scanner (~50 lines)
    |
vt_stream.nextSlice(data)    <-- ghostty-vt (stream_readonly.zig)
                                  \-- Ignores queries, bell, title, clipboard
```

**Problems:**
1. Two independent parsers see same bytes, maintain separate state
2. Custom `osc_buffer` for partial sequences (100KB allocation, no timeout)
3. State desync possible when program exits mid-sequence

## Proposed Architecture

```
PTY read
    |
pane.feed(data)
    |
vt_stream.nextSlice(data)    <-- ghostty-vt with CUSTOM handler
    |
DullahanHandler.vt(action, value)
    +-- .bell -> pane.handleBell()
    +-- .window_title -> pane.setTitle()
    +-- .clipboard_contents -> pane.handleClipboard()
    +-- .color_operation -> pane.handleColorOp() [including query response]
    +-- .device_attributes -> pane.sendDA1Response()
    +-- .device_status -> pane.sendDSRResponse()
    \-- [all other actions] -> delegate to Terminal (like readonly does)
```

**Benefits:**
1. Single parser with single state machine
2. ghostty-vt handles partial OSC buffering internally
3. Terminator tracking built-in (for OSC 10/11 response matching)
4. ~300 lines removed from pane.zig

## What ghostty-vt Provides

### Events emitted by ghostty-vt that readonly handler IGNORES:

| Event | Data | Current Dullahan Handling |
|-------|------|---------------------------|
| `bell` | void | `handleBell()` scans for 0x07 |
| `window_title` | `[:0]const u8` | `handleOscSequences()` parses OSC 0/2 |
| `clipboard_contents` | `{kind: u8, data: [:0]const u8}` | `handleOscSequences()` parses OSC 52 |
| `color_operation` | `{op, requests, terminator}` | `handleOscSequences()` parses OSC 10/11 |
| `device_attributes` | `.primary` / `.secondary` | `handleTerminalQueries()` parses CSI c |
| `device_status` | request type enum | `handleTerminalQueries()` parses CSI n |
| `show_desktop_notification` | `{title, body}` | `handleOscSequences()` parses OSC 9/777 |
| `progress_report` | progress struct | `handleOscSequences()` parses OSC 9;4 |

### Key data available in `color_operation`:

```zig
color_operation: struct {
    op: Operation,      // osc_10, osc_11, osc_104, etc.
    requests: List,     // list of query/set/reset requests
    terminator: Terminator,  // .st or .bel - TRACKS WHICH TERMINATOR WAS USED
}
```

The terminator tracking is crucial for OSC 10/11 responses - we must respond with the same terminator the query used.

## Implementation Details

### Phase 1: Create Custom Stream Handler

**New file: `server/src/stream_handler.zig`**

```zig
//! Custom stream handler for dullahan that extends readonly behavior
//! with query response capability.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const stream = ghostty_vt.stream;
const Terminal = ghostty_vt.Terminal;
const osc_color = ghostty_vt.osc.color;

const Pane = @import("pane.zig").Pane;

/// Handler that wraps a Pane for query responses
pub const Handler = struct {
    terminal: *Terminal,
    pane: *Pane,  // For PTY access and pane-specific state

    pub fn init(terminal: *Terminal, pane: *Pane) Handler {
        return .{
            .terminal = terminal,
            .pane = pane,
        };
    }

    pub fn deinit(self: *Handler) void {
        _ = self;
    }

    pub fn vt(
        self: *Handler,
        comptime action: stream.Action.Tag,
        value: stream.Action.Value(action),
    ) !void {
        switch (action) {
            // === Events that need pane-level handling ===

            .bell => self.pane.onBell(),

            .window_title => self.pane.setTitle(value.title),

            .clipboard_contents => self.pane.handleClipboardEvent(
                value.kind,
                value.data,
            ),

            .color_operation => try self.handleColorOp(value),

            .device_attributes => |req| switch (req) {
                .primary => self.pane.sendDA1Response(),
                .secondary => self.pane.sendDA2Response(),
                else => {},
            },

            .device_status => self.pane.handleDSR(value.request),

            .show_desktop_notification => self.pane.setNotification(
                if (value.title.len > 0) value.title else null,
                value.body,
            ),

            .progress_report => self.pane.handleProgressEvent(value),

            // === Events handled by terminal (same as readonly) ===

            .print => try self.terminal.print(value.cp),
            .semantic_prompt => self.handleSemanticPrompt(value),
            // ... (copy other handlers from stream_readonly.zig)

            // === Ignored events ===
            .enquiry,
            .request_mode,
            .request_mode_unknown,
            .size_report,
            .xtversion,
            .kitty_keyboard_query,
            .report_pwd,
            .title_push,
            .title_pop,
            => {},
        }
    }

    fn handleColorOp(self: *Handler, value: anytype) !void {
        var it = value.requests.constIterator(0);
        while (it.next()) |req| {
            switch (req.*) {
                .query => |target| {
                    // Respond to color query
                    self.pane.sendColorQueryResponse(
                        value.op,
                        target,
                        value.terminator,
                    );
                },
                .set => |set| {
                    // Update terminal colors (same as readonly)
                    switch (set.target) {
                        .dynamic => |d| switch (d) {
                            .foreground => self.terminal.colors.foreground.set(set.color),
                            .background => self.terminal.colors.background.set(set.color),
                            .cursor => self.terminal.colors.cursor.set(set.color),
                            else => {},
                        },
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.colors.palette.set(i, set.color);
                        },
                        else => {},
                    }
                },
                .reset => |target| {
                    // Reset terminal colors (same as readonly)
                    switch (target) {
                        .dynamic => |d| switch (d) {
                            .foreground => self.terminal.colors.foreground.reset(),
                            .background => self.terminal.colors.background.reset(),
                            .cursor => self.terminal.colors.cursor.reset(),
                            else => {},
                        },
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.colors.palette.reset(i);
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
};

/// The stream type using our custom handler
pub const Stream = stream.Stream(Handler);
```

### Phase 2: Modify Pane to Use Custom Handler

**Changes to `server/src/pane.zig`:**

```zig
// BEFORE:
const stream_readonly = ghostty_vt.stream_readonly;
vt_stream: ?stream_readonly.Stream = null,

// AFTER:
const stream_handler = @import("stream_handler.zig");
vt_stream: ?stream_handler.Stream = null,

// In feed():
// BEFORE:
self.handleTerminalQueries(data);
self.handleOscSequences(data);
self.handleBell(data);
if (self.vt_stream == null) {
    self.vt_stream = self.terminal.vtStream();
}
try self.vt_stream.?.nextSlice(data);

// AFTER:
if (self.vt_stream == null) {
    const handler = stream_handler.Handler.init(&self.terminal, self);
    self.vt_stream = stream_handler.Stream.initAlloc(self.allocator, handler);
}
try self.vt_stream.?.nextSlice(data);
```

### Phase 3: Add Event Handler Methods to Pane

```zig
// New methods in pane.zig:

/// Handle bell event from stream handler
pub fn onBell(self: *Pane) void {
    self.bell_pending = true;
    bell_log.debug("Pane {d}: Bell detected", .{self.id});
}

/// Handle clipboard event from stream handler
pub fn handleClipboardEvent(self: *Pane, kind: u8, data: []const u8) void {
    if (data.len == 1 and data[0] == '?') {
        // Query - send clipboard contents back
        self.clipboard.handleOsc52Query(kind, self.id);
    } else {
        // Set - store clipboard contents
        self.clipboard.handleOsc52Set(kind, data, self.id);
    }
}

/// Handle color query response
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
                const fg = self.theme_fg orelse .{
                    constants.colors.fg_r,
                    constants.colors.fg_g,
                    constants.colors.fg_b
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
            else => {},
        },
        else => {},
    }
}

/// Handle DSR request from stream handler
pub fn handleDSR(self: *Pane, request: device_status.Request) void {
    switch (request) {
        .status => self.sendDSRStatusResponse(),
        .cursor_position => self.sendDSRCursorResponse(),
        .cursor_position_dec => self.sendDSRCursorResponse(),
        else => dsr_log.warn("Pane {d}: Unhandled DSR {}", .{self.id, request}),
    }
}
```

### Phase 4: Remove Old Parsers

**Delete from `pane.zig`:**
- `handleOscSequences()` - ~200 lines
- `handleTerminalQueries()` - ~40 lines
- `handleBell()` - ~50 lines
- `osc_buffer` field and cleanup code - ~20 lines

**Total removed:** ~310 lines

### Phase 5: Update Tests

- Existing OSC tests should still pass (they test via `feed()`)
- Add tests for the new handler methods
- Verify OSC 10/11 queries return correct terminator

## Data Flow Comparison

### OSC 11 Query (lipgloss light mode detection)

**Before (dual parser):**
```
App sends: ESC ] 11 ; ? BEL
    |
handleOscSequences() scans for ESC ]
    +-- Finds "11;?" with BEL terminator
    +-- Calls sendOscColorResponse(11, ..., use_st=false)
    \-- Writes response to PTY
    |
vt_stream.nextSlice() also parses
    +-- Emits color_operation event
    \-- readonly handler sets terminal.colors (but we don't use the response)
```

**After (single parser):**
```
App sends: ESC ] 11 ; ? BEL
    |
vt_stream.nextSlice()
    +-- ghostty-vt parses OSC 11
    +-- Emits color_operation event with terminator=.bel
    \-- Handler.vt(.color_operation, ...) called
         +-- Sees .query request for .background
         \-- Calls pane.sendColorQueryResponse() with correct terminator
```

## Risk Assessment

| Area | Risk | Mitigation |
|------|------|------------|
| OSC 52 clipboard | Medium | ghostty-vt provides same data; verify base64 handling |
| OSC 10/11 terminator | Low | ghostty-vt tracks terminator explicitly |
| DA1/DA2 responses | Low | ghostty-vt emits device_attributes with type |
| DSR cursor position | Low | ghostty-vt emits device_status with request type |
| Bell detection | Low | ghostty-vt emits bell event |
| Title changes | Low | ghostty-vt emits window_title with string |
| Partial OSC buffering | None | ghostty-vt handles internally |

## Testing Strategy

1. **Unit tests:** Handler methods in isolation
2. **Integration tests:**
   - OSC 10/11 query -> verify response format and terminator
   - OSC 52 set/get -> verify clipboard data
   - DA1 -> verify response string
   - DSR 5/6 -> verify responses
3. **Manual tests:**
   - lipgloss (uses OSC 11 for light/dark detection)
   - vim (uses DA1 for terminal detection)
   - tmux/screen (clipboard operations)

## Migration Checklist

- [ ] Create `server/src/stream_handler.zig`
- [ ] Copy action handlers from `stream_readonly.zig`
- [ ] Add query response handlers (color, DA, DSR)
- [ ] Add pane event methods (`onBell`, `handleClipboardEvent`, etc.)
- [ ] Update `vt_stream` type in pane.zig
- [ ] Update stream initialization in `feed()`
- [ ] Delete `handleOscSequences()`
- [ ] Delete `handleTerminalQueries()`
- [ ] Delete `handleBell()`
- [ ] Delete `osc_buffer` field and cleanup
- [ ] Update/add tests
- [ ] Test with lipgloss, vim, clipboard

## Estimated Scope

| Item | Lines Changed |
|------|---------------|
| New stream_handler.zig | +250 |
| Pane event methods | +80 |
| Remove old parsers | -310 |
| Test updates | +50 |
| **Net change** | **+70** |

The net code increase is small, but the architecture is significantly cleaner with single-source-of-truth parsing.

## Open Questions

1. Is there concern about depending more tightly on ghostty-vt's internal event types?
2. Should we keep the old parsers behind a feature flag during transition?
3. Any specific OSC sequences to verify ghostty-vt handles correctly?

## References

- `deps/ghostty/src/terminal/stream.zig` - Stream and Action definitions
- `deps/ghostty/src/terminal/stream_readonly.zig` - Readonly handler (our starting point)
- `deps/ghostty/src/terminal/osc.zig` - OSC Command types
- `deps/ghostty/src/terminal/osc/parsers/color.zig` - Color operation parsing
- `server/src/pane.zig` - Current implementation with dual parsers

# Dullahan Wire Protocol

## Overview

Communication between server and client uses WebSocket with JSON text messages.
Cell data is sent as raw binary (base64-encoded within JSON).

**Port**: 7681 (default, same as ttyd/libwebsockets)

## Message Types

### Server → Client

#### Snapshot

Full terminal state, sent on connection and after changes.

```json
{
  "type": "snapshot",
  "data": {
    "cols": 80,
    "rows": 24,
    "cursor": {
      "x": 0,
      "y": 0,
      "visible": true,
      "style": "block"
    },
    "altScreen": false,
    "cells": "AAAA...base64..."
  }
}
```

**Fields:**
- `cols`, `rows` — Terminal dimensions
- `cursor.x`, `cursor.y` — Cursor position (0-indexed)
- `cursor.visible` — Whether cursor is shown
- `cursor.style` — One of: `"block"`, `"underline"`, `"bar"`
- `altScreen` — Whether alternate screen buffer is active
- `cells` — Base64-encoded raw cell data (cols × rows × 8 bytes)

#### Cell Binary Format

Each cell is 8 bytes (64 bits), matching ghostty-vt's packed struct:

```
bits 0-1:   content_tag (2 bits)
              0 = codepoint
              1 = codepoint_grapheme (multi-codepoint)
              2 = bg_color_palette (no text, just BG)
              3 = bg_color_rgb (no text, just BG)
bits 2-25:  content (24 bits)
              - codepoint: Unicode codepoint (21 bits used)
              - palette: palette index (8 bits)
              - rgb: r[7:0] g[15:8] b[23:16]
bits 26-41: style_id (16 bits) — index into style table
bits 42-43: wide (2 bits)
              0 = narrow (normal width)
              1 = wide (double-width char, first cell)
              2 = spacer_tail (second cell of wide char)
              3 = spacer_head (soft-wrap continuation)
bit 44:     protected
bit 45:     hyperlink
bits 46-63: padding (18 bits)
```

Decoding in JavaScript (little-endian):
```typescript
const lo = view[i * 2];      // bits 0-31
const hi = view[i * 2 + 1];  // bits 32-63

const contentTag = lo & 0x3;
const content = (lo >>> 2) & 0xFFFFFF;
const styleId = ((lo >>> 26) & 0x3F) | ((hi & 0x3FF) << 6);
const wide = (hi >>> 10) & 0x3;
const protected = (hi >>> 12) & 0x1;
const hyperlink = (hi >>> 13) & 0x1;
```

#### Pong

Response to client ping.

```json
{
  "type": "pong"
}
```

### Client → Server

#### Input

Keyboard input to send to the terminal.

```json
{
  "type": "input",
  "data": "hello"
}
```

#### Resize

Request to resize the terminal.

```json
{
  "type": "resize",
  "cols": 120,
  "rows": 40
}
```

#### Ping

Keep-alive ping.

```json
{
  "type": "ping"
}
```

## Connection Flow

1. Client connects via WebSocket to `ws://host:7681`
2. Server immediately sends a `snapshot` message
3. Client can send `input`, `resize`, or `ping` messages
4. Server responds to changes with updated `snapshot` messages
5. Server polls for pane changes (100ms) and pushes snapshots automatically

## Update Mechanism

The server tracks a `version` counter on each pane:
- Increments on `feed()` (terminal output) or `resize()`
- WebSocket handler polls every 100ms
- If version changed, sends new snapshot to all connected clients
- Client input triggers immediate snapshot response (no polling delay)

## Future Enhancements

- **Style table**: Send style definitions so client can render colors
- **Binary frames**: Use WebSocket binary frames instead of base64 in JSON
- **Delta updates**: Send only changed rows/cells
- **MessagePack**: Switch to msgpack for smaller payloads

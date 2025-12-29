# Dullahan Wire Protocol

## Overview

Communication between server and client uses WebSocket with JSON text messages.

**Port**: 7681 (default)

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
    "content": "Hello, world!\n..."
  }
}
```

**Fields:**
- `cols`, `rows` — Terminal dimensions
- `cursor.x`, `cursor.y` — Cursor position (0-indexed)
- `cursor.visible` — Whether cursor is shown
- `cursor.style` — One of: `"block"`, `"underline"`, `"bar"`
- `altScreen` — Whether alternate screen buffer is active
- `content` — Plain text content of the terminal

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

## Future Enhancements

- **Delta updates**: Send only changed rows/cells instead of full content
- **Binary format**: Switch to MessagePack for efficiency
- **Cell-level data**: Include colors, styles, and attributes per cell
- **Images**: Support for inline images (Kitty graphics protocol)

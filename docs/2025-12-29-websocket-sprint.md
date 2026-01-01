# 2025-12-29: WebSocket Sprint

Got the basic client-server communication working over WebSocket, then upgraded to raw cell data.

## What got built

**Server (Zig):**
- `websocket.zig` - RFC 6455 framing, masking, handshake
- `http.zig` - HTTP server with WS upgrade
- `ws_server.zig` - manages client connections, version-based updates
- `snapshot.zig` - terminal state → JSON with raw cell bytes

Server now runs HTTP+WS on port 7681 in a separate thread.

**Client (Preact):**
- `terminal/connection.ts` - WebSocket client with auto-reconnect, cell decoding
- `components/App.tsx` - renders terminal from decoded cells

**Protocol:**
- `protocol/messages.md` - wire format documentation
- `protocol/schema/types.ts` - TypeScript types
- `protocol/schema/cell.ts` - cell encode/decode matching ghostty's packed struct
- `protocol/schema/cell.test.ts` - 16 tests for cell handling

## What works

1. Server starts, listens on 7681
2. Client connects via WebSocket
3. Server sends JSON snapshot with base64-encoded raw cells
4. Client decodes cells (8 bytes each, 64-bit packed struct)
5. Version tracking: pane changes trigger automatic snapshot push
6. Immediate feedback on client input

## Cell format (64 bits)

```
bits 0-1:   content_tag (codepoint/grapheme/bg_palette/bg_rgb)
bits 2-25:  content (codepoint u21 or color)
bits 26-41: style_id (16 bits, index into style table)
bits 42-43: wide (narrow/wide/spacer_tail/spacer_head)
bit 44:     protected
bit 45:     hyperlink
bits 46-63: padding
```

## Fixes along the way

- Linux build: `pty.h` instead of `util.h` for `openpty()`
- Zig 0.15: `ArrayListUnmanaged` + allocator per method
- Zig 0.15: `{any}` format specifier for errors/complex types
- Zig 0.15: `terminal.resize()` takes `(allocator, cols, rows)`
- Socket timeout: `SO_RCVTIMEO` for polling without blocking

## Style table (also implemented)

Server extracts unique style_ids from cells, looks up each style from ghostty's StyleSet, encodes to binary:

```
[count: u16]
[id: u16, fg: 4, bg: 4, ul: 4, flags: 2] × count
```

Color encoding: `[tag, v0, v1, v2]` where tag 0=none, 1=palette, 2=rgb

Flags (u16): bold, italic, faint, blink, inverse, invisible, strikethrough, overline, underline style

## Static file serving (also implemented)

Server now serves static files from the same port as WebSocket:

```bash
dullahan serve --static-dir=./client
# Open http://localhost:7681
```

No need for separate `bun serve` anymore.

## Next up

- Hook up keyboard input
- Run a shell in the PTY
- Render colors in client using style table
- Binary WebSocket frames (skip base64)
- Delta updates instead of full snapshots

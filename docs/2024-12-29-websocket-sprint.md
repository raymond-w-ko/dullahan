# 2024-12-29: WebSocket Sprint

Got the basic client-server communication working over WebSocket.

## What got built

**Server (Zig):**
- `websocket.zig` - RFC 6455 framing, masking, handshake
- `http.zig` - HTTP server with WS upgrade
- `ws_server.zig` - manages client connections
- `snapshot.zig` - terminal state → JSON

Server now runs HTTP+WS on port 7681 in a separate thread.

**Client (Preact):**
- `terminal/connection.ts` - WebSocket client with auto-reconnect
- `components/App.tsx` - renders terminal content + cursor

**Protocol:**
- Updated `protocol/messages.md` with actual message formats
- Added `protocol/schema/types.ts` for TypeScript types

## What works

1. Server starts, listens on 7681
2. Client connects via WebSocket
3. Server sends JSON snapshot (dimensions, cursor, content)
4. Client displays it

Tested with a quick bun script - round trip works.

## Fixes along the way

- Linux build: `pty.h` instead of `util.h` for `openpty()`
- Zig 0.15: `ArrayListUnmanaged` + allocator per method
- Zig 0.15: `{any}` format specifier for errors/complex types
- Zig 0.15: terminal.resize() takes (allocator, cols, rows)

## Next up

- Hook up keyboard input
- Actually run a shell in the PTY
- Delta updates instead of full snapshots

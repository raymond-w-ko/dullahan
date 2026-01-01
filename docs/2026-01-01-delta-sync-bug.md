# Delta Sync Bug - 2026-01-01

**Status: BROKEN** - Delta sync causes terminal content to disappear after first keystroke.

## Symptom

After initial connection, the terminal displays correctly (shell prompt visible). When the user types a single character, the entire terminal content disappears - all cells become empty/spaces.

## Background

We implemented delta sync to reduce bandwidth:
- Instead of sending full snapshots (~15KB) on every change, send only dirty rows (~50-200 bytes)
- Server tracks dirty rows via `pane.dirty_rows` HashMap
- Client maintains `_rowCache` Map<bigint, Cell[]> to store rows by ID
- Delta contains: cursor, altScreen, viewport info, dirty rows, row IDs, styles

## Changes Made (this session)

### Server-side (ws_server.zig)
- Added `sendUpdate()` method that decides between delta or full snapshot
- Changed message loop to use `sendUpdate()` instead of always `sendSnapshot()`
- Added `clearDirtyRows()` calls after sending updates

### Server-side (snapshot.zig)
- Added cursor info to delta messages
- Added `altScreen` flag to delta
- Added `rowIds` array (viewport row IDs) to delta
- Added styles table to delta (only styles used by dirty rows)

### Client-side (connection.ts)
- Extended `BinaryDelta` interface with cursor, altScreen, styles, rowIds
- Added `_lastStyles` and `_lastRowIds` for delta merging
- Rewrote `applyDelta()` to:
  1. Update `_rowCache` with dirty rows
  2. Decode `rowIds` from delta
  3. Rebuild cells array by looking up each rowId in cache
  4. Build merged snapshot and call `onSnapshot`

## Suspected Root Cause

The cells array is being filled with empty cells because `_rowCache.get(rowId)` returns undefined. This means the row IDs in the delta don't match the keys stored in the row cache from the initial snapshot.

Possible reasons:
1. **Row ID mismatch**: The `computeRowId()` function may return different values for the same logical row between snapshot and delta (e.g., if page serial numbers change)
2. **Cache not populated**: The initial snapshot may not be storing rows correctly
3. **Delta rowIds decoding issue**: The `decodeRowIdsFromBytes()` may be returning wrong values
4. **Viewport shift**: When terminal scrolls, new row IDs enter viewport that weren't in the original cache

## Debugging Added

Extensive console.log statements added to trace:
- Raw message keys received
- Delta details (cols, rows, cursor, rowIds length, etc.)
- Decoded rowIds vs cache keys
- How many rows found in cache vs filled empty

## Files Modified

```
server/src/ws_server.zig    - sendUpdate(), clearDirtyRows() calls
server/src/snapshot.zig     - generateDelta() enhanced with cursor, rowIds, styles
server/src/http.zig         - Memory leak fix (unrelated)
client/src/terminal/connection.ts - applyDelta() rewrite, debug logging
```

## To Debug

1. Run server: `./zig-out/bin/dullahan serve --static-dir=./client`
2. Open browser to http://localhost:7681
3. Open browser DevTools console
4. Type a character in the terminal
5. Check console for:
   - "Snapshot stored X rows in cache, rowIds: [...]"
   - "Received delta message, keys: [...]"
   - "Decoded X rowIds: [...]"
   - "Row cache size: X, keys: [...]"
   - "RowIds in cache: X, not in cache: X"

If "not in cache" > 0, the row IDs don't match between snapshot and delta.

## Potential Fixes to Try

1. **Verify computeRowId consistency**: Add logging to server to print row IDs in both snapshot and delta generation
2. **Check page serial stability**: The row ID formula is `(page_serial * PAGE_SIZE) + row_index` - verify page serials aren't changing
3. **Fallback to full snapshot**: If delta causes issues, detect and force resync
4. **Simpler delta approach**: Instead of row-ID-based caching, send full cells array but skip unchanged rows (position-based)

## Rollback Option

To revert to working state (full snapshots only), change `sendUpdate()` to always call `sendSnapshot()`:

```zig
fn sendUpdate(self: *WsServer, ws: *websocket.Connection, pane: *Pane, client_gen: u64) !void {
    _ = client_gen;
    try self.sendSnapshot(ws, pane);
}
```

This defeats the purpose of delta sync but will make the terminal work again.

# Cache Miss Resync Design

## Problem Statement

Commit 92eec66 added cache pruning to prevent unbounded memory growth:
- Row cache pruned to 500 rows max
- Style table pruned to 256 entries max

However, after pruning, if a delta references evicted rows or styles, the client:
1. **Missing rows**: Fills with empty cells (spaces) — visible corruption
2. **Missing styles**: Falls back to `DEFAULT_STYLE` — subtle color/attribute loss

The server has no way to detect this situation because:
- The `minRowId` field in sync messages is parsed but **never used**
- Generation numbers only track "how recent" not "what's cached"

## Observed Symptoms

- Scrolling back into history shows blank lines where content should be
- After long sessions, some cells lose their colors
- The corruption persists until a natural full resync (resize, screen switch)

## Design Goals

1. **Detect cache misses** — Client knows when data is missing
2. **Request full resync** — Explicit mechanism to recover
3. **Minimal overhead** — Don't add latency to normal delta path
4. **Backward compatible** — Old clients/servers continue to work

---

## Proposed Solution: Client-Initiated Resync

### Approach

The client already detects missing rows at `connection.ts:1059-1062`:

```typescript
const notInCache = rowIds.filter(id => !paneState.rowCache.has(id));
if (notInCache.length > 0) {
  deltaLog.warn(`Pane ${paneId}: ${notInCache.length} rows missing from cache`);
}
```

**Instead of just logging, the client should request a full snapshot.**

### New Message Type: `resync`

Add a new client→server message:

```typescript
interface ResyncMessage {
  type: "resync";
  paneId: number;
  reason: "cache_miss" | "style_miss" | "corruption" | "manual";
}
```

**Server behavior**: Upon receiving `resync`, immediately send a full snapshot for that pane (bypass delta logic entirely).

### Client Detection Logic

In `applyDelta()`, after building the viewport:

```typescript
// Threshold: if more than 10% of rows are missing, request resync
const missingRowThreshold = Math.max(3, Math.floor(delta.rows * 0.1));

if (notInCache.length > missingRowThreshold) {
  deltaLog.warn(`Pane ${paneId}: ${notInCache.length} rows missing, requesting resync`);
  this.requestResync(paneId, "cache_miss");
  return; // Don't emit corrupted snapshot
}
```

For styles, detect after merging:

```typescript
// Check if any cells reference styles we don't have
const missingStyles = new Set<number>();
for (const cell of cells) {
  if (cell.styleId !== 0 && !styles.has(cell.styleId)) {
    missingStyles.add(cell.styleId);
  }
}

if (missingStyles.size > 0) {
  deltaLog.warn(`Pane ${paneId}: ${missingStyles.size} styles missing, requesting resync`);
  this.requestResync(paneId, "style_miss");
  return;
}
```

### Resync Debouncing

To prevent resync storms:

```typescript
class TerminalConnection {
  private _lastResyncTime: Map<number, number> = new Map(); // paneId → timestamp
  private readonly RESYNC_COOLDOWN_MS = 1000;

  requestResync(paneId: number, reason: string): void {
    const now = Date.now();
    const lastResync = this._lastResyncTime.get(paneId) ?? 0;

    if (now - lastResync < this.RESYNC_COOLDOWN_MS) {
      deltaLog.log(`Pane ${paneId}: resync throttled (${reason})`);
      return;
    }

    this._lastResyncTime.set(paneId, now);
    this.send({ type: "resync", paneId, reason });

    // Track for debug UI
    const paneState = this._panes.get(paneId);
    if (paneState) {
      paneState.resyncCount++;
    }
  }
}
```

### Server-Side Handler

In `message_handlers.zig`:

```zig
fn handleResync(el: *EventLoop, client: *ClientState, resync_msg: ParsedResync) !void {
    const pane = el.session.getPaneById(resync_msg.pane_id) orelse return;

    log.info("Client requested resync for pane {d}: {s}", .{
        resync_msg.pane_id,
        resync_msg.reason,
    });

    // Always send full snapshot, bypass delta logic
    const snap = try snapshot.generateBinarySnapshot(pane.allocator, pane);
    defer pane.allocator.free(snap);
    try client.ws.sendBinary(snap);

    // Update client's tracked generation
    client.setGeneration(pane.id, pane.generation);
}
```

---

## Alternative Considered: Server-Side Detection via `minRowId`

The protocol already has `minRowId` in sync messages. We could:

1. **Client**: Send actual `minRowId` from cache (currently always sends 0)
2. **Server**: Compare with current viewport's minimum row ID
3. **Server**: If client's `minRowId` > server's min visible row, send snapshot

**Why not chosen**:
- Doesn't handle style misses
- Requires server to track row ID ranges per viewport position
- More complex server-side logic
- `minRowId` alone doesn't capture "holes" in the cache

However, this could be a **complementary optimization** — the server could proactively send snapshots when it detects the client's cache is stale, without waiting for the client to notice.

---

## Implementation Plan

### Phase 1: Client-Side Detection & Request (Minimal)

1. Add `resync` message type to `protocol/schema/messages.ts`
2. Add `ParsedResync` to `server/src/messages.zig`
3. Add parser for `resync` in `message_parsing.zig`
4. Add handler in `message_handlers.zig`
5. Implement `requestResync()` in `connection.ts`
6. Add detection logic in `applyDelta()`
7. Add resync counter to debug UI (alongside delta/resync counts)

### Phase 2: Smarter Pruning (Optional)

Instead of pruning arbitrarily, prefer to keep:
- Rows near current viewport (likely to scroll back to)
- Recently accessed rows
- Styles used by cached rows

```typescript
// LRU-style row cache with access tracking
interface CachedRow {
  cells: Cell[];
  lastAccess: number;
}
```

### Phase 3: Server-Side Proactive Resync (Optional)

Use `minRowId` to detect when server knows client is stale:

```zig
fn handleSyncRequest(self, client, pane, client_gen, client_min_row_id) !void {
    // If client's oldest cached row is newer than viewport needs...
    const viewport_min_row = pane.getMinVisibleRowId();
    if (client_min_row_id > viewport_min_row) {
        // Client has pruned rows we need, force snapshot
        log.debug("Client cache too recent, forcing snapshot");
        return self.sendFullSnapshot(client, pane);
    }
    // ... normal delta logic
}
```

---

## Wire Protocol Changes

### New Message: `resync` (Client → Server)

```json
{
  "type": "resync",
  "paneId": 1,
  "reason": "cache_miss"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | `"resync"` | Message type |
| `paneId` | `number` | Pane requesting resync |
| `reason` | `string` | Why resync is needed (for logging/metrics) |

Valid reasons:
- `cache_miss` — Rows missing from cache
- `style_miss` — Style IDs missing from table
- `corruption` — Client detected data inconsistency
- `manual` — User/debug triggered

### Backward Compatibility

- **Old server + new client**: Server ignores unknown message type, client falls back to waiting for natural resync
- **New server + old client**: No change, old clients don't send `resync`

---

## Metrics & Observability

Track these for debugging:

```typescript
interface PaneState {
  // Existing
  deltaCount: number;
  resyncCount: number;  // Full resyncs received

  // New
  cacheHitRate: number; // Rolling average
  cacheMissResyncCount: number; // Resyncs we requested due to cache miss
  styleMissResyncCount: number; // Resyncs we requested due to style miss
}
```

Update debug UI titlebar:
```
Δ{deltas} ⟳{resyncs} ✗{cacheMisses}
```

---

## Testing

1. **Unit test**: Prune cache, apply delta referencing pruned row, verify resync requested
2. **Unit test**: Prune styles, apply delta with cell using pruned style, verify resync requested
3. **Integration test**: Long session with scrollback, verify no corruption
4. **Manual test**: `dullahan test delta-gen` with cache limits

---

## Open Questions

1. **Should we emit the corrupted snapshot while waiting for resync?**
   - Pro: User sees something immediately
   - Con: Flicker as corruption → correct state
   - Recommendation: Don't emit, wait for resync (usually <100ms)

2. **Should pruning be more aggressive or conservative?**
   - Current: 500 rows, 256 styles
   - Could make configurable or adaptive based on memory pressure

3. **Should we batch resyncs across panes?**
   - If multiple panes need resync, could send single "resync all" message
   - Probably overkill for typical usage

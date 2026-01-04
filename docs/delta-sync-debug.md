# Delta Sync Debugging Guide

## Problem Statement

Full snapshots render correctly, but delta updates cause rendering issues (particularly visible with fish shell history navigation via up/down arrows).

## Code Locations

### Server-Side Delta Generation

**`server/src/snapshot.zig`**
- `generateDelta()` (line ~700) - Main delta generation function
- `generateBinarySnapshot()` (line ~100) - Full snapshot for comparison
- Key difference: delta only includes rows from `pane.dirty_rows` set

**`server/src/pane.zig`**
- `dirty_rows: HashSet(u64)` - Set of dirty row IDs
- `generation: u64` - Increments on any terminal change
- `dirty_base_gen: u64` - Generation when dirty tracking started
- `collectDirtyRows()` (line ~287) - Collects dirty rows from ghostty-vt pages
- `clearDirtyRows()` (line ~580) - Clears tracking after sending update
- `feed()` (line ~260) - Feeds PTY output to terminal, calls collectDirtyRows()

**`server/src/ws_server.zig`**
- `sendUpdate()` (line ~295) - Decides delta vs full snapshot
- `handleSyncRequest()` (line ~334) - Handles client sync requests
- `DEBUG_FORCE_FULL_SNAPSHOTS` (line ~10) - Debug flag to bypass deltas

### Client-Side Delta Application

**`client/src/terminal/connection.ts`**
- `applyDelta()` (line ~533) - Applies delta to local cache
- `_rowCache: Map<bigint, Cell[]>` - Cached row data by row ID
- `_generation: number` - Last synced generation
- `decodeCellsFromBytes()` (line ~314) - Decodes cell bytes from delta

## Data Flow

```
1. PTY output received
   └─> pane.feed(data)
       └─> terminal.vtStream().nextSlice(data)  // ghostty-vt processes
       └─> collectDirtyRows()                    // reads ghostty dirty flags
           └─> pages.isDirty(pin)               // check each row
           └─> dirty_rows.put(row_id)           // add to our tracking
       └─> pages.clearDirty()                   // clear ghostty flags
       └─> generation++

2. Client requests sync (or server detects generation change)
   └─> sendUpdate() or handleSyncRequest()
       └─> generateDelta(pane)
           └─> iterate dirty_rows
           └─> for each dirty row: get cells, encode to msgpack
       └─> send to client
       └─> clearDirtyRows()

3. Client receives delta
   └─> applyDelta()
       └─> for each dirty row: decode cells, update _rowCache
       └─> reconstruct full cell array from rowIds + cache
       └─> call onSnapshot() with reconstructed data
```

## Potential Bug Causes

### 1. Row ID Instability During Reflow

When terminal content reflows (e.g., line wrapping changes), row IDs may change but our tracking might not capture all affected rows.

**Location:** `pane.zig:collectDirtyRows()` and ghostty-vt's dirty tracking

**Symptom:** Old row IDs in client cache, new row IDs from server don't match

### 2. Dirty Flag Semantics Mismatch

ghostty-vt's `isDirty()` might mean "cell content changed" but not cover:
- Cursor movement through a row (no content change, but display changes)
- Style-only changes
- Row being scrolled into/out of viewport

**Location:** `pane.zig:collectDirtyRows()` calls `pages.isDirty(pin)`

**Test:** Log which rows ghostty marks dirty vs which rows actually changed

### 3. Line Shrinking/Growing

When a line shrinks (e.g., backspace in shell), the row is dirty but:
- Old longer content might persist in client cache
- Delta sends new shorter content
- Client might not clear trailing cells

**Location:** `snapshot.zig` row padding logic (lines ~745-768)

**Test:** Compare cell count in delta row vs snapshot row

### 4. Wrap/Unwrap Transitions

When content wraps to two lines then unwraps back to one:
- Row IDs change (second row disappears)
- First row's content changes
- Client cache might have stale second row

**Location:** `pane.zig:collectDirtyRows()` - may miss the "disappeared" row

### 5. Cursor Row Not Marked Dirty

Fish redraws the prompt line when navigating history. If cursor movement alone doesn't mark the row dirty in ghostty-vt, we miss updates.

**Location:** ghostty-vt's dirty tracking logic

**Test:** Check if cursor-only movement marks rows dirty

### 6. Race Between Feed and Dirty Collection

If `collectDirtyRows()` runs while terminal is still processing escape sequences:
- Partial state captured
- Some rows marked dirty, others not yet

**Location:** `pane.zig:feed()` - collectDirtyRows called after each feed

### 7. Style Table Incompleteness in Delta

Delta might reference style IDs that weren't included in the delta's style table.

**Location:** `snapshot.zig:generateDelta()` style collection logic

**Test:** Check if all referenced style IDs are in delta's style table

### 8. Client Cache Eviction Issues

Client might evict cached rows that are still needed, or keep stale rows.

**Location:** `connection.ts:applyDelta()` cache management

## Debugging Steps

1. **Add logging to collectDirtyRows():**
   ```zig
   log.debug("Row {d} dirty: ghostty={}, content='{s}'", .{y, is_dirty, row_text});
   ```

2. **Compare delta vs snapshot row-by-row:**
   - Generate both for same terminal state
   - Diff the cell data for each row

3. **Log row ID stability:**
   - Track row IDs before/after each feed()
   - Check if IDs change unexpectedly

4. **Instrument client cache:**
   - Log cache hits/misses during applyDelta()
   - Check if expected rows are present

## Quick Test

The `shell-delta-test` compares delta vs snapshot:
```bash
zig build run-shell-delta-test
```

This test passes but uses a controlled environment. The real bug might be timing-dependent or require specific terminal sequences that fish produces.

## Key Hypothesis: Test vs Real Usage Difference

The test compares delta and snapshot **at the same instant** in the same process. In real usage:

1. **Client requests sync at time T1**
2. **Server generates delta based on dirty rows at T1**
3. **Client receives and applies delta at time T2**
4. **Between T1 and T2, more terminal changes may occur**

If the client's cache becomes inconsistent, subsequent deltas build on a broken foundation.

## Most Likely Causes (Ranked)

### 1. Client Cache Reconstruction Bug (HIGH)

In `connection.ts:applyDelta()`, we reconstruct full cells from cache:
```typescript
for (let y = 0; y < delta.rows; y++) {
  const rowId = rowIds[y];
  const rowCells = this._rowCache.get(rowId);
  if (rowCells) {
    cells.push(...rowCells);  // Use cached
  } else {
    // Fill with empty - THIS MIGHT BE THE BUG
    for (let x = 0; x < delta.cols; x++) {
      cells.push({ content: { tag: 0, codepoint: 32 }, ... });
    }
  }
}
```

If a row ID is in the viewport but NOT in cache AND NOT in dirty rows, we fill with spaces. But that row might have had content from a previous snapshot that we lost.

### 2. Row ID Mapping Mismatch

Delta includes `rowIds` array (which rows are in viewport) and `dirtyRows` array (changed rows). If:
- Viewport shows row ID 5
- But row ID 5 was never sent in a dirty update
- And row ID 5 isn't in cache from initial snapshot

Then that row renders as blank.

### 3. Initial Snapshot Cache Population

Check `connection.ts` where initial snapshot populates cache:
```typescript
for (let y = 0; y < msg.rows; y++) {
  const rowId = rowIds[y];
  // Are we correctly populating _rowCache here?
}
```

If initial snapshot doesn't populate cache correctly, deltas have nothing to build on.

## Debug Flags

- `ws_server.zig:DEBUG_FORCE_FULL_SNAPSHOTS` - Set to `true` to bypass deltas (current state)
- Add client-side logging in `applyDelta()` to trace cache hits/misses

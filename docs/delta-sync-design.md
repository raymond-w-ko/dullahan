# Delta Sync Protocol Design

This document describes the design for efficient terminal state synchronization between the Dullahan server and web clients, supporting scrollback history with minimal data transfer.

## Problem Statement

1. **Server** maintains authoritative terminal state using ghostty-vt's page-based buffer
2. **Client** needs to display terminal and support scrollback navigation
3. **Challenge**: Minimize WebSocket traffic while keeping client in sync
4. **Complication**: Line indices shift when history is pruned (not stable identifiers)

## Background: Ghostty's Memory Model

Ghostty-vt uses a **linked list of pages**, not a ring buffer:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Page (serial=5) │ --> │ Page (serial=6) │ --> │ Page (serial=7) │
│   ~1000 rows    │     │   ~1000 rows    │     │   ~1000 rows    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        ↑                                                ↑
    (oldest)                                    (active area)
```

Key properties:
- **Pages have serial numbers**: Monotonically increasing, assigned on allocation/reuse
- **Rows within pages have indices**: 0 to PAGE_SIZE-1, stable within that page
- **Pruning**: When `max_scrollback` exceeded, oldest page is recycled (popped from front, zeroed, appended to back with new serial)
- **No data shifting**: O(1) pruning via pointer manipulation

### Coordinate Systems

Ghostty has 4 coordinate tags, all with relative indices:

| Tag | Origin (y=0) | Use Case |
|-----|--------------|----------|
| `screen` | Oldest line in buffer | Absolute addressing |
| `history` | Oldest line in buffer | Scrollback only |
| `viewport` | Top of visible area | What user sees |
| `active` | Top of editable area | Where cursor lives |

**Problem**: These are all relative. When history is pruned, `screen.y=1000` becomes `screen.y=0`. Not suitable for delta sync.

## Solution: Stable Row IDs

We create **stable, monotonic row identifiers** by combining page serials with row indices:

```
stable_row_id = (page_serial * PAGE_SIZE) + row_index_in_page
```

Properties:
- **Unique**: Each row gets a unique ID when created
- **Stable**: ID never changes for the lifetime of that row
- **Monotonic**: Newer rows have higher IDs
- **Sparse after pruning**: When page serial=5 is pruned, IDs 5000-5999 are gone forever

Example with PAGE_SIZE=1000:
```
Page serial=5, row 42  →  row_id = 5042
Page serial=7, row 0   →  row_id = 7000
```

## Protocol Design

### Server State

```zig
const SyncState = struct {
    /// Increments on ANY terminal change
    generation: u64,
    
    /// Lowest row_id still in buffer (rows below this were pruned)
    min_row_id: u64,
    
    /// Row IDs that changed since generation N
    /// Circular buffer or map: generation -> Set<row_id>
    dirty_since: DirtyTracker,
    
    /// How many generations of dirty tracking to keep
    /// Clients further behind get full resync
    max_dirty_history: u64 = 1000,
};
```

### Client State

```typescript
interface ClientState {
  // Last successfully sync'd generation
  generation: number;
  
  // Oldest row_id we have cached
  minRowId: number;
  
  // Our local copy of terminal rows
  rows: Map<number, Row>;  // row_id -> row data
  
  // Current viewport position
  viewportRowId: number;   // row_id at top of viewport
  viewportOffset: number;  // rows from viewportRowId
}
```

### Message Types

#### Client → Server: Sync Request

```typescript
interface SyncRequest {
  type: "sync";
  generation: number;  // client's current generation
  minRowId: number;    // oldest row client has
}
```

#### Server → Client: Delta Response

```typescript
interface DeltaResponse {
  type: "delta";
  generation: number;      // new generation after applying
  minRowId: number;        // new minimum (client should prune below this)
  
  viewport: {
    rowId: number;         // row_id at viewport top
    activeOffset: number;  // rows from viewport top to active area
  };
  
  // Changed rows (only those modified since client's generation)
  changes: Array<{
    rowId: number;
    cells: Cell[];
  }>;
  
  // Terminal dimensions (if changed)
  dimensions?: { cols: number; rows: number };
}
```

#### Server → Client: Full Resync

When client is too far behind (generation gap exceeds `max_dirty_history`):

```typescript
interface ResyncResponse {
  type: "resync";
  generation: number;
  minRowId: number;
  
  viewport: { rowId: number; activeOffset: number };
  dimensions: { cols: number; rows: number };
  
  // All rows currently in buffer
  rows: Array<{ rowId: number; cells: Cell[] }>;
}
```

### Sync Flow

```
┌────────┐                              ┌────────┐
│ Client │                              │ Server │
└───┬────┘                              └───┬────┘
    │                                       │
    │  { type: "sync", generation: 500 }    │
    │ ────────────────────────────────────> │
    │                                       │
    │    (server checks: 500 within range?) │
    │                                       │
    │  { type: "delta", generation: 507,    │
    │    minRowId: 1200,                    │
    │    changes: [{rowId: 5010, ...}] }    │
    │ <──────────────────────────────────── │
    │                                       │
    │  (client applies delta)               │
    │                                       │
```

### Client Algorithm

```typescript
function handleSyncResponse(response: DeltaResponse | ResyncResponse) {
  if (response.type === "resync") {
    // Full reset
    this.rows.clear();
    for (const row of response.rows) {
      this.rows.set(row.rowId, row.cells);
    }
  } else {
    // 1. Prune rows below new minimum
    for (const [id, _] of this.rows) {
      if (id < response.minRowId) {
        this.rows.delete(id);
      }
    }
    
    // 2. Apply changes
    for (const change of response.changes) {
      this.rows.set(change.rowId, change.cells);
    }
  }
  
  // 3. Update client state
  this.generation = response.generation;
  this.minRowId = response.minRowId;
  this.viewportRowId = response.viewport.rowId;
}
```

### Server Algorithm

```zig
fn handleSyncRequest(client_gen: u64, client_min_row: u64) Response {
    // Client is current - no changes
    if (client_gen == self.generation) {
        return .{ .type = .delta, .changes = &.{} };
    }
    
    // Client is too stale - force full resync
    if (self.generation - client_gen > self.max_dirty_history) {
        return self.buildFullSnapshot();
    }
    
    // Build delta from dirty tracking
    var changes = ArrayList(RowChange).init(allocator);
    
    for (gen = client_gen + 1; gen <= self.generation; gen++) {
        for (row_id in self.dirty_since.get(gen)) {
            if (row_id >= self.min_row_id) {  // not pruned
                changes.append(.{
                    .row_id = row_id,
                    .cells = self.getRow(row_id),
                });
            }
        }
    }
    
    return .{
        .type = .delta,
        .generation = self.generation,
        .min_row_id = self.min_row_id,
        .changes = changes.items,
    };
}
```

## Dirty Tracking

### Option A: Per-Generation Sets

```zig
// Track which rows changed at each generation
dirty_since: BoundedArray(HashSet(u64), MAX_HISTORY),
```

- **Pro**: Precise, can compute exact delta for any generation in range
- **Con**: Memory grows with change frequency

### Option B: Bloom Filter + Generation Watermarks

```zig
dirty_bloom: BloomFilter,      // probabilistic "was this row dirty?"
dirty_gen_start: u64,          // bloom covers generations [start, current]
```

- **Pro**: Fixed memory
- **Con**: False positives mean sending unchanged rows (acceptable)

### Option C: Simple Dirty Set + Watermark

```zig
dirty_rows: HashSet(u64),      // rows dirty since last_clean_gen
last_clean_gen: u64,           // generation when dirty_rows was cleared
```

- **Pro**: Simplest implementation
- **Con**: All-or-nothing - client either gets dirty set or full resync

**Recommendation**: Start with Option C, upgrade to Option A if needed.

## Bandwidth Analysis

| Scenario | Data Sent |
|----------|-----------|
| Idle terminal | ~20 bytes (empty delta) |
| Normal typing | ~50-200 bytes (1-2 rows) |
| `cat large_file.txt` | Full viewport rows |
| `vim` full redraw | ~viewport_rows × row_size |
| Scrolling history | 0 bytes (client has data) |
| Client reconnect | Full snapshot |

Typical row size with msgpack + snappy: ~20-100 bytes depending on content.

## Edge Cases

### 1. Client Scrolled Into History

Client viewing old history, new content arrives:

```typescript
// Client is viewing row_id 1000-1024 (old history)
// Server sends delta with changes to row_id 9000-9024 (active area)

// Client applies delta but doesn't scroll viewport
// User sees stable history, can scroll down to see new content
```

### 2. History Pruned While Client Viewing

```typescript
// Client viewing row_id 1000-1024
// Server prunes, new minRowId = 2000

// Delta: { minRowId: 2000, ... }
// Client: rows 1000-1024 deleted, viewport jumps to minRowId
```

Could improve UX by sending "your viewport was pruned" flag.

### 3. Resize During Sync

Terminal resize reflows content, potentially changing row count:

```typescript
// Option A: Force full resync on resize
// Option B: Send resize event, client reflows locally (complex)

// Recommendation: Option A (simpler, resize is rare)
```

### 4. Multiple Clients

Each client tracks its own generation. Server dirty tracking is shared.

```zig
// Server keeps max(dirty_history) generations
// Slow clients get resync, fast clients get small deltas
```

## Implementation Phases

### Phase 1: Foundation
- [ ] Add `row_id` computation to snapshot.zig
- [ ] Add generation counter to server state
- [ ] Send row_ids in snapshot (preparation for deltas)

### Phase 2: Basic Deltas
- [ ] Implement dirty row tracking (Option C)
- [ ] Add sync request/response messages
- [ ] Client delta application logic

### Phase 3: Optimization
- [ ] Viewport-priority sending (visible rows first)
- [ ] Compression tuning for deltas
- [ ] Dirty tracking upgrade if needed (Option A)

### Phase 4: Polish
- [ ] Handle resize gracefully
- [ ] "Viewport pruned" UX improvement
- [ ] Metrics/monitoring for sync efficiency

## Related Files

- `server/src/snapshot.zig` - Current snapshot generation
- `server/src/ws_server.zig` - WebSocket message handling
- `client/src/terminal/connection.ts` - Client WebSocket handling
- `protocol/messages.md` - Wire format documentation

## Open Questions

1. **PAGE_SIZE value**: ghostty uses ~1000, should we match or use different?
2. **Dirty history depth**: How many generations to track before forcing resync?
3. **Compression**: Delta-specific compression vs reusing snappy?
4. **Binary format**: Extend msgpack schema or new delta-specific format?

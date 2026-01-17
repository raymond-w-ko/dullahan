# Dullahan Wire Protocol

## Overview

Communication between server and client uses WebSocket with:
- **Server → Client**: Binary msgpack, compressed with Snappy
- **Client → Server**: JSON text messages

**Port**: 7681 (default)

## Binary Protocol Stack

```
┌─────────────────────────────────┐
│  Application (snapshot/delta)  │
├─────────────────────────────────┤
│  MessagePack encoding           │
├─────────────────────────────────┤
│  Snappy compression             │
├─────────────────────────────────┤
│  WebSocket binary frame         │
└─────────────────────────────────┘
```

Client decoding:
```typescript
const compressed = new Uint8Array(event.data);
const decompressed = SnappyJS.uncompress(compressed);
const msg = decode(decompressed); // @msgpack/msgpack
```

## Message Types

### Server → Client

#### Snapshot (Full State)

Sent on initial connection and when client is too far behind for delta.

```typescript
{
  type: "snapshot",
  gen: number,           // Generation counter
  cols: number,
  rows: number,
  cursor: {
    x: number,
    y: number,
    visible: boolean,
    style: "block" | "underline" | "bar",
  },
  altScreen: boolean,
  scrollback: {
    totalRows: number,   // Total rows including history
    viewportTop: number, // Current scroll offset
  },
  cells: Uint8Array,     // Raw cell bytes (cols × rows × 8)
  styles: Uint8Array,    // Style table
  rowIds: Uint8Array,    // Packed u64 row IDs (rows × 8 bytes)
  graphemes?: Uint8Array, // Grapheme data (see format below)
}
```

#### Delta (Incremental Update)

Sent in response to sync request when client has recent state.

```typescript
{
  type: "delta",
  gen: number,           // New generation
  cols: number,
  rows: number,
  vp: {
    totalRows: number,
    viewportTop: number,
  },
  dirtyRows: Array<{
    id: number,          // Stable row ID
    cells: Uint8Array,   // Cell bytes for this row
    graphemes?: Uint8Array, // Grapheme data (row-relative indices)
  }>,
}
```

#### Pong

Response to client ping.

```typescript
{ type: "pong" }
```

### Client → Server (JSON)

**IMPORTANT:** All messages (except `ping`) must include `paneId` to route to the correct pane.

#### Key

Keyboard event with full fidelity.

```json
{
  "type": "key",
  "paneId": 1,
  "key": "a",
  "code": "KeyA",
  "keyCode": 65,
  "state": "down",
  "ctrl": false,
  "alt": false,
  "shift": false,
  "meta": false,
  "repeat": false,
  "timestamp": 12345.67
}
```

#### Text

IME composed text (CJK, emoji, etc).

```json
{
  "type": "text",
  "paneId": 1,
  "data": "日本語",
  "timestamp": 12345.67
}
```

#### Resize

```json
{
  "type": "resize",
  "paneId": 1,
  "cols": 120,
  "rows": 40
}
```

#### Scroll

```json
{
  "type": "scroll",
  "paneId": 1,
  "delta": -5
}
```

#### Sync

Request delta update from server for a specific pane.

```json
{
  "type": "sync",
  "paneId": 1,
  "gen": 500,
  "minRowId": 1000
}
```

#### Focus

Request focus change to a specific pane.

```json
{
  "type": "focus",
  "paneId": 1
}
```

#### Ping

```json
{ "type": "ping" }
```

## Cell Binary Format

Each cell is 8 bytes (64 bits), matching ghostty-vt's packed struct:

```
bits 0-1:   content_tag (2 bits)
              0 = codepoint
              1 = codepoint_grapheme
              2 = bg_color_palette
              3 = bg_color_rgb
bits 2-25:  content (24 bits)
bits 26-41: style_id (16 bits)
bits 42-43: wide (2 bits)
bit 44:     protected
bit 45:     hyperlink
bits 46-63: padding
```

## Style Table Binary Format

```
[count: u16]
[
  id: u16,
  fg_color: 4 bytes,   // [tag, v0, v1, v2]
  bg_color: 4 bytes,
  underline_color: 4 bytes,
  flags: u16
] × count
```

Color tags: 0=none, 1=palette, 2=RGB

## Grapheme Binary Format

Grapheme data encodes additional codepoints for cells marked with `content_tag=1`
(CODEPOINT_GRAPHEME). Used for emoji (👨‍👩‍👧‍👦), combining marks (é̈), etc.

```
[count: u32 LE]              // Number of grapheme entries
For each entry:
  [cell_index: u32 LE]       // Cell position (y*cols+x for snapshot, x for delta row)
  [num_codepoints: u8]       // Additional codepoint count (1-255)
  [codepoints: 3 bytes LE × num]  // Each u21 as 3 bytes, little-endian
```

**Example:** Thumbs up with skin tone (👍🏻) at cell (5, 3) in 80-col terminal:
- Base codepoint U+1F44D is in the cell's content field
- Extra codepoint U+1F3FB (skin tone) is in the grapheme table:

```
01 00 00 00        // count = 1
F5 00 00 00        // index = 245 (3*80+5)
01                 // 1 extra codepoint
FB F3 01           // U+1F3FB (little-endian: 0x01F3FB)
```

**Snapshot vs Delta:**
- Snapshot: cell_index is global (y × cols + x)
- Delta: cell_index is row-relative (x only, 0 to cols-1)

## Row ID Format

Stable row identifiers for delta sync:

```
row_id = (page_serial × 1000) + row_index_in_page
```

- `page_serial`: Monotonic counter from ghostty's PageList
- `row_index_in_page`: 0-999 within each page
- Row IDs persist until the row is pruned from history

## Delta Sync Protocol

See `docs/delta-sync-design.md` for full design.

**Flow:**
1. Client connects, receives full snapshot
2. Client tracks `generation` and `minRowId`
3. On sync request, server checks if delta is possible
4. If `client_gen >= dirty_base_gen`: send delta with dirty rows
5. If client too stale: send full snapshot

**Server dirty tracking:**
- Tracks which row IDs changed since last clear
- `dirty_base_gen`: generation when tracking started
- Clients behind this need full resync

## Connection Flow

1. Client connects via WebSocket to `ws://host:7681`
2. Server sends initial snapshot (binary msgpack + snappy)
3. Server polls pane generation, pushes snapshots on change
4. Client can request explicit sync for delta updates
5. Client sends input/resize/scroll as JSON

## Bandwidth Comparison

| Scenario | JSON+base64 | Msgpack+Snappy |
|----------|-------------|----------------|
| 80×24 snapshot | ~45KB | ~15KB |
| Delta (1 row) | N/A | ~200 bytes |
| Empty delta | N/A | ~50 bytes |

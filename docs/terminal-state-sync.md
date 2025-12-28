# Terminal State Synchronization

This document describes the terminal state that needs to be synchronized between the dullahan server (Zig/ghostty-vt) and web clients.

## Overview

The server is the source of truth for all terminal state. Clients receive:
1. **Full snapshots** on initial connection or reconnection
2. **Delta updates** for incremental changes

## Serialization Format Recommendation

### Why Not Plain JSON?

JSON is simple but inefficient for terminal state:
- High overhead for binary data (base64 encoding)
- No schema validation
- String keys waste bandwidth
- Large payloads for full screen updates

### Recommended: MessagePack + Schema

**MessagePack** offers the best tradeoff:
- Binary format, ~30-50% smaller than JSON
- Native JavaScript support (`@msgpack/msgpack`)
- Schema-less but can be validated separately
- Easy debugging (can convert to/from JSON)

For schema definition and validation, use **TypeBox** or **Zod** on the client side.

### Alternative: Protocol Buffers

Pros:
- Smallest wire size
- Strong schema enforcement
- Code generation for both Zig and TypeScript

Cons:
- More complex build setup
- Harder to debug (pure binary)
- Overkill for WebSocket text frames

**Verdict**: Start with MessagePack. Switch to Protobuf only if bandwidth becomes critical.

---

## State Categories

### 1. Screen Dimensions

| Field | Zig Type | Wire Format | Notes |
|-------|----------|-------------|-------|
| `rows` | `u16` | `uint16` | Active area height |
| `cols` | `u16` | `uint16` | Active area width |
| `width_px` | `u32` | `uint32` | Pixel width (for images) |
| `height_px` | `u32` | `uint32` | Pixel height (for images) |

```typescript
interface Dimensions {
  rows: number;
  cols: number;
  widthPx: number;
  heightPx: number;
}
```

### 2. Cursor State

| Field | Zig Type | Wire Format | Notes |
|-------|----------|-------------|-------|
| `x` | `u16` | `uint16` | Column (0-indexed) |
| `y` | `u16` | `uint16` | Row (0-indexed) |
| `style` | `CursorStyle` | `uint8` enum | block=0, underline=1, bar=2 |
| `visible` | `bool` | `bool` | Cursor visibility |
| `blinking` | `bool` | `bool` | Blink state |
| `pending_wrap` | `bool` | `bool` | At end of line, next char wraps |

```typescript
interface Cursor {
  x: number;
  y: number;
  style: 'block' | 'underline' | 'bar';
  visible: boolean;
  blinking: boolean;
  pendingWrap: boolean;
}
```

### 3. Colors

| Field | Zig Type | Wire Format | Notes |
|-------|----------|-------------|-------|
| `background` | `RGB` | `uint24` or `[r,g,b]` | Default BG |
| `foreground` | `RGB` | `uint24` or `[r,g,b]` | Default FG |
| `cursor_color` | `?RGB` | `uint24 \| null` | Cursor color override |
| `palette` | `[256]RGB` | `[256]uint24` | 256-color palette |

```typescript
type RGB = number; // 0xRRGGBB

interface Colors {
  background: RGB;
  foreground: RGB;
  cursorColor: RGB | null;
  palette: RGB[]; // length 256
}
```

**Optimization**: Only send palette on change. Use a dirty flag.

### 4. Cell Data

The core rendering unit. Each cell in the grid:

| Field | Zig Type | Wire Format | Notes |
|-------|----------|-------------|-------|
| `codepoint` | `u21` | `uint32` | Unicode codepoint (0 = empty) |
| `grapheme` | `?[]u21` | `uint32[]` | Additional codepoints for grapheme clusters |
| `fg` | `Color` | see below | Foreground color |
| `bg` | `Color` | see below | Background color |
| `flags` | `Flags` | `uint16` | Packed style flags |
| `wide` | `Wide` | `uint2` | Width property |

**Color encoding** (3 bytes):
```
byte 0: tag (0=none/default, 1=palette, 2=rgb)
byte 1-2: palette index OR rgb.r
byte 3: rgb.g (if rgb)
byte 4: rgb.b (if rgb)
```

Or simpler: `{ type: 'default' | 'palette' | 'rgb', value?: number }`

**Flags** (packed u16):
```
bit 0: bold
bit 1: italic
bit 2: faint
bit 3: blink
bit 4: inverse
bit 5: invisible
bit 6: strikethrough
bit 7: overline
bit 8-10: underline (none=0, single=1, double=2, curly=3, dotted=4, dashed=5)
bit 11: protected
bit 12: hyperlink (has associated link)
```

**Wide** enum:
- `0` = narrow (1 cell)
- `1` = wide (2 cells, this is the left half)
- `2` = spacer_tail (right half of wide char, skip rendering)
- `3` = spacer_head (soft-wrap continuation marker)

```typescript
interface Cell {
  cp: number;           // codepoint
  gr?: number[];        // grapheme (if multi-codepoint)
  fg?: CellColor;       // foreground (omit if default)
  bg?: CellColor;       // background (omit if default)
  fl?: number;          // flags (omit if 0)
  w?: 0 | 1 | 2 | 3;    // wide (omit if 0)
}

type CellColor = 
  | { t: 'p', v: number }  // palette index
  | { t: 'r', v: number }; // RGB as 0xRRGGBB
```

### 5. Row Data

| Field | Zig Type | Wire Format | Notes |
|-------|----------|-------------|-------|
| `cells` | `[]Cell` | `Cell[]` | Cells in row |
| `wrap` | `bool` | `bool` | Soft-wrapped to next row |
| `semantic` | `?SemanticPrompt` | `uint8 \| null` | Shell integration marker |

```typescript
interface Row {
  cells: Cell[];
  wrap?: boolean;     // omit if false
  semantic?: 'prompt' | 'input' | 'output';
}
```

### 6. Terminal Modes

Boolean flags that affect behavior:

| Mode | Zig Field | Wire Name | Description |
|------|-----------|-----------|-------------|
| Origin Mode | `origin` | `originMode` | Cursor relative to scroll region |
| Auto Wrap | `autowrap` | `autoWrap` | Wrap at end of line |
| Cursor Visible | `cursor_visible` | `cursorVisible` | Show cursor |
| Alternate Screen | `alternate_screen` | `altScreen` | Using alternate buffer |
| Bracketed Paste | `bracketed_paste` | `bracketedPaste` | Paste mode |
| Focus Events | `focus_event` | `focusEvents` | Report focus in/out |
| Mouse Events | (flags) | `mouseMode` | Mouse tracking mode |
| Mouse Format | (flags) | `mouseFormat` | Mouse encoding format |

```typescript
interface Modes {
  originMode: boolean;
  autoWrap: boolean;
  cursorVisible: boolean;
  altScreen: boolean;
  bracketedPaste: boolean;
  focusEvents: boolean;
  mouseMode: 'none' | 'x10' | 'normal' | 'button' | 'any';
  mouseFormat: 'x10' | 'utf8' | 'sgr' | 'urxvt' | 'sgr_pixels';
}
```

### 7. Selection

| Field | Zig Type | Wire Format | Notes |
|-------|----------|-------------|-------|
| `start_x` | `u16` | `uint16` | Start column |
| `start_y` | `i32` | `int32` | Start row (can be in scrollback) |
| `end_x` | `u16` | `uint16` | End column |
| `end_y` | `i32` | `int32` | End row |
| `rectangle` | `bool` | `bool` | Block selection mode |

```typescript
interface Selection {
  startX: number;
  startY: number;  // negative = scrollback
  endX: number;
  endY: number;
  rectangle: boolean;
}
```

### 8. Scrolling Region

| Field | Zig Type | Wire Format | Notes |
|-------|----------|-------------|-------|
| `top` | `u16` | `uint16` | Top margin (0-indexed) |
| `bottom` | `u16` | `uint16` | Bottom margin |
| `left` | `u16` | `uint16` | Left margin (if horizontal scrolling) |
| `right` | `u16` | `uint16` | Right margin |

```typescript
interface ScrollRegion {
  top: number;
  bottom: number;
  left?: number;   // omit if full width
  right?: number;
}
```

---

## Wire Protocol

### Message Types

```typescript
type ServerMessage =
  | { type: 'snapshot', data: FullSnapshot }
  | { type: 'delta', data: Delta }
  | { type: 'bell' }
  | { type: 'title', title: string }
  | { type: 'resize', rows: number, cols: number };

type ClientMessage =
  | { type: 'key', key: string, mods: number }
  | { type: 'mouse', x: number, y: number, button: number, mods: number, action: string }
  | { type: 'paste', data: string }
  | { type: 'resize', rows: number, cols: number };
```

### Full Snapshot

Sent on initial connection:

```typescript
interface FullSnapshot {
  dimensions: Dimensions;
  cursor: Cursor;
  colors: Colors;
  modes: Modes;
  rows: Row[];
  scrollRegion?: ScrollRegion;
  selection?: Selection;
  title?: string;
}
```

### Delta Updates

Sent after changes. Only include changed fields:

```typescript
interface Delta {
  // Changed rows (sparse - only modified rows)
  rows?: { [y: number]: Row | null };  // null = cleared row
  
  // Or for efficiency, packed dirty rows
  dirtyRows?: {
    start: number;
    data: Row[];
  };
  
  cursor?: Partial<Cursor>;
  colors?: Partial<Colors>;
  modes?: Partial<Modes>;
  scrollRegion?: ScrollRegion | null;
  selection?: Selection | null;
  
  // Scroll optimization: instead of sending all rows
  scroll?: {
    lines: number;  // positive = scroll up, negative = down
    // Only send the newly visible rows
    newRows: Row[];
  };
}
```

---

## Optimization Strategies

### 1. Row-Level Dirty Tracking

Ghostty already tracks dirty state per-row. Only send rows that changed.

### 2. Scroll Coalescing

When scrolling, send scroll direction + new rows instead of full screen.

### 3. Cursor-Only Updates

Most frames only change cursor position. Send minimal cursor updates.

### 4. Cell Compression

For rows with many identical cells (e.g., empty lines), use RLE:
```typescript
type CompressedRow = 
  | { cells: Cell[] }                    // normal
  | { repeat: Cell, count: number }[];   // RLE segments
```

### 5. Binary Cell Packing

For maximum efficiency, pack cells into binary:
```
[4 bytes codepoint][2 bytes style_id][1 byte flags][1 byte wide]
```
Then send style table separately (style_id → full style).

---

## Implementation Notes

### Server (Zig)

1. Use `RenderState.update()` to get diff-friendly state
2. Track dirty flags at row level
3. Serialize to MessagePack using a Zig msgpack library
4. Send over WebSocket binary frames

### Client (TypeScript)

1. Maintain local terminal state mirror
2. Apply deltas to update state
3. Use requestAnimationFrame for render batching
4. Decode MessagePack with `@msgpack/msgpack`

### Viewport vs Scrollback

- Only sync the **viewport** (visible rows)
- Scrollback stays on server
- Client requests scrollback on demand with range queries

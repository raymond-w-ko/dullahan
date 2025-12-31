# Scrollback Implementation Bug

## Date
2024-12-31

## Original Issue
User reported that pressing Ctrl+L to clear the screen caused desync issues, especially after running `ls` multiple times. The terminal would "run out of space" and get confused.

## Root Cause Hypothesis
The client only displays the visible screen area. There was no scrollback support, so:
1. When content scrolled off the top, it was lost to the client
2. Ctrl+L clears the screen but the client had no context of what was above

## What I Attempted

### Server Changes

1. **Added scrollback info to snapshot** (`server/src/snapshot.zig`):
```zig
const ScrollbackInfo = struct {
    totalRows: usize,      // Total rows including scrollback
    viewportTop: usize,    // Current viewport offset from top
};
```

2. **Get scrollbar info from ghostty-vt**:
```zig
const scrollbar = pages.scrollbar();
// Returns: { .total, .offset, .len }
```

3. **Added scroll message handling** (`server/src/ws_server.zig`):
```zig
const ScrollMessage = struct {
    type: []const u8,
    delta: i32,  // Negative = scroll up, positive = scroll down
};
```

4. **Added Pane.scroll()** (`server/src/pane.zig`):
```zig
pub fn scroll(self: *Pane, delta: i32) void {
    self.terminal.screens.active.scroll(.{ .delta_row = delta });
    self.version +%= 1;
}
```

### Client Changes

1. **Added scroll types** (`client/src/terminal/connection.ts`):
```typescript
export interface ScrollbackInfo {
    totalRows: number;
    viewportTop: number;
}
```

2. **Added wheel event handler** (`client/src/components/App.tsx`):
```typescript
const handleWheel = useCallback((e: WheelEvent) => {
    e.preventDefault();
    const delta = Math.sign(e.deltaY) * 3;
    connection.sendScroll(delta);
}, [connection]);
```

3. **Added scrollback indicator** when scrolled up

## The Bug

**The snapshot is grabbing the WRONG cells after scrolling!**

In `snapshot.zig`, the cell fetching code does:
```zig
const row_pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(y) } })
```

Looking at ghostty's `point.zig`:
```zig
/// Top-left is the furthest back in the scrollback history
/// supported by the screen and the bottom-right is the bottom-right
/// of the visible screen.
screen,
```

**Problem**: `.screen` coordinates have `y=0` at the TOP of scrollback history, NOT at the current viewport position!

So when I call `screen.scroll(.delta_row)`, it changes the viewport position, but the snapshot code is still fetching rows 0 through N from the **absolute top** of the scrollback buffer, not from the current viewport position.

## Correct Approach

Need to either:

### Option A: Offset the pin coordinates by viewport position
```zig
const scrollbar = pages.scrollbar();
const viewport_offset = scrollbar.offset;

// When fetching row y of the visible screen:
const actual_y = viewport_offset + y;
const row_pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(actual_y) } });
```

### Option B: Use viewport-relative coordinates
Check if ghostty has a coordinate system that's relative to the current viewport (there might be `.viewport` or similar).

### Option C: Use the viewport pin
ghostty tracks a `viewport_pin` - maybe we can iterate from there instead of using absolute coordinates.

## Files Changed

- `server/src/snapshot.zig` - Added ScrollbackInfo, scrollbar reading
- `server/src/ws_server.zig` - Added ScrollMessage handling
- `server/src/pane.zig` - Added scroll() method
- `client/src/terminal/connection.ts` - Added scroll types and sendScroll()
- `client/src/components/App.tsx` - Added wheel handler, scrollback indicator
- `client/src/dullahan.css` - Added scrollback indicator styles
- `client/src/hooks/useScrollback.ts` - Created but unused (for future client-side buffer)

## Key ghostty-vt APIs

```zig
// Get scrollbar state
const scrollbar = pages.scrollbar();
// .total - total rows including scrollback
// .offset - current viewport offset from top  
// .len - visible rows

// Scroll viewport
screen.scroll(.{ .delta_row = delta });  // Scroll by delta rows
screen.scroll(.{ .active = {} });        // Jump to bottom (active area)
screen.scroll(.{ .top = {} });           // Jump to top of scrollback

// Check if at bottom
const at_bottom = screen.viewportIsBottom();

// Coordinate systems (point.zig)
.active  - y=0 is top of active (editable) area
.screen  - y=0 is top of ALL scrollback history
.history - y=0 is top of scrollback, excludes active area
```

## Commits

- `0a015e9` - feat: implement scrollback with wheel scrolling (BROKEN)

## Next Steps

1. Fix the coordinate offset in snapshot.zig
2. Test that scrolling up shows correct history
3. Test that Ctrl+L still works correctly
4. Consider: should scroll-to-bottom happen automatically on new output?

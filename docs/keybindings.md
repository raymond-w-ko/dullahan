# Keybinding System Design

This document describes the keybinding system for Dullahan's web client, enabling configurable keyboard shortcuts that execute client-side actions.

## Overview

The keybinding system consists of three layers:

1. **Keybind Parser** (`keybinds.ts`) - Parses Ghostty-style keybind strings
2. **Keyboard Handler** (`keyboard.ts`) - Intercepts keys and executes actions
3. **Action System** (`actions.ts`) - Defines and executes client-side operations

```
User presses Ctrl+Shift+C
         │
         ▼
┌─────────────────────┐
│  KeyboardHandler    │
│  - Check keybinds   │
│  - Track consumed   │
└─────────┬───────────┘
          │
    ┌─────┴─────┐
    │           │
    ▼           ▼
 Match?      No Match
    │           │
    ▼           ▼
┌─────────┐  ┌─────────┐
│ Execute │  │ Send to │
│ Action  │  │ Server  │
└─────────┘  └─────────┘
```

## Keybind String Format

Keybinds use Ghostty-compatible syntax: modifiers joined with `+`, followed by a key.

### Basic Format

```
[modifier+]...[modifier+]key
```

### Examples

```
c                    # Just the 'c' key
ctrl+c               # Ctrl + C
ctrl+shift+c         # Ctrl + Shift + C
super+k              # Super/Cmd + K
alt+enter            # Alt + Enter
shift+page_up        # Shift + Page Up
f1                   # F1 function key
ctrl+alt+delete      # Ctrl + Alt + Delete
```

### Modifier Aliases

| Canonical | Aliases |
|-----------|---------|
| `ctrl` | `control` |
| `alt` | `option`, `opt` |
| `shift` | - |
| `meta` | `super`, `cmd`, `command`, `win`, `windows` |

### Special Key Names

| Key Name | Maps To | Aliases |
|----------|---------|---------|
| `up` | ArrowUp | - |
| `down` | ArrowDown | - |
| `left` | ArrowLeft | - |
| `right` | ArrowRight | - |
| `page_up` | PageUp | `pageup` |
| `page_down` | PageDown | `pagedown` |
| `enter` | Enter | `return` |
| `space` | ` ` (space char) | - |
| `tab` | Tab | - |
| `escape` | Escape | `esc` |
| `backspace` | Backspace | - |
| `delete` | Delete | `del` |
| `insert` | Insert | `ins` |
| `home` | Home | - |
| `end` | End | - |
| `f1`-`f12` | F1-F12 | - |

## API Reference

### Keybind Interface

```typescript
interface Keybind {
  key: string;      // Normalized key (e.g., 'c', 'Enter', 'PageUp')
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;    // super/cmd/win
}
```

### Functions

#### `parseKeybind(str: string): Keybind`

Parse a keybind string into a structured object.

```typescript
const keybind = parseKeybind("ctrl+shift+c");
// { key: "c", ctrl: true, alt: false, shift: true, meta: false }
```

Throws if no key is found (e.g., `"ctrl+"` or `""`).

#### `matchesKeybind(event: KeyboardEvent, keybind: Keybind): boolean`

Check if a keyboard event matches a keybind. Requires **exact** modifier match.

```typescript
if (matchesKeybind(event, keybind)) {
  // Event matches
}
```

#### `formatKeybind(keybind: Keybind): string`

Convert a keybind back to a string (for display/debugging).

```typescript
formatKeybind(parseKeybind("super+shift+k"));
// "ctrl+shift+super+k" (canonical order)
```

## Keyboard Handler Integration

### Setting Up Keybinds

```typescript
import { KeyboardHandler, KeybindEntry } from "./keyboard";
import { parseKeybind } from "./keybinds";
import { ActionContext } from "./actions";

const handler = new KeyboardHandler();

// Define keybinds
const keybinds: KeybindEntry[] = [
  { keybind: parseKeybind("ctrl+shift+c"), action: { type: "copy_to_clipboard" } },
  { keybind: parseKeybind("ctrl+shift+v"), action: { type: "paste_from_clipboard" } },
  { keybind: parseKeybind("ctrl+shift+n"), action: { type: "new_window" } },
  { keybind: parseKeybind("shift+page_up"), action: { type: "scroll", direction: "up", amount: "page" } },
];

handler.setKeybinds(keybinds);
handler.setActionContext(actionContext);
handler.attach(element, sendToServer);
```

### Consumed Key Tracking

When a keybind matches on keydown:
1. The action executes
2. The key's `code` is added to `consumedKeys`
3. On keyup, if `code` is in `consumedKeys`, the event is suppressed

This prevents orphaned keyup events from reaching the server.

```
Ctrl+C keybind matched:

  Ctrl down  →  PASS THROUGH (modifier)
  C down     →  CONSUMED (action executes)
  C up       →  SUPPRESSED (was consumed)
  Ctrl up    →  PASS THROUGH (modifier)
```

### Modifier Key Handling

Modifier-only key events (Ctrl, Shift, Alt, Meta) **always pass through** to the server. This maintains accurate modifier state for the Kitty keyboard protocol.

Modifier key codes:
- `ControlLeft`, `ControlRight`
- `ShiftLeft`, `ShiftRight`
- `AltLeft`, `AltRight`
- `MetaLeft`, `MetaRight`
- `CapsLock`, `NumLock`

## Action Types

Actions are client-side operations that keybinds can trigger.

### Available Actions

| Action Type | Description |
|-------------|-------------|
| `copy_to_clipboard` | Copy selection to clipboard |
| `paste_from_clipboard` | Paste from clipboard |
| `scroll` | Scroll viewport (line/page/half_page/top/bottom) |
| `send_text` | Send literal text to terminal |
| `clear_screen` | Clear screen (sends Ctrl+L) |
| `reset_terminal` | Reset terminal (sends ESC c) |
| `new_window` | Create new window |
| `close_window` | Close current window |
| `switch_window` | Switch to window by index (1-based) |
| `cycle_window` | Cycle next/prev window |
| `focus_pane` | Focus pane (next/prev/directional) |
| `toggle_fullscreen` | Toggle pane fullscreen |
| `open_settings` | Open settings modal |
| `none` | No-op (key passes through) |

### Action Examples

```typescript
// Scroll actions
{ type: "scroll", direction: "up", amount: "line" }
{ type: "scroll", direction: "down", amount: "page" }
{ type: "scroll", direction: "up", amount: "top" }

// Window actions
{ type: "switch_window", windowIndex: 1 }  // 1-based
{ type: "cycle_window", direction: "next" }

// Pane focus
{ type: "focus_pane", direction: "left" }
{ type: "focus_pane", direction: "next" }

// Send text
{ type: "send_text", text: "\x1b[A" }  // Send Up arrow escape
```

## Default Keybinds

Recommended default keybinds (Ghostty-compatible):

```typescript
const DEFAULT_KEYBINDS: KeybindEntry[] = [
  // Clipboard
  { keybind: parseKeybind("ctrl+shift+c"), action: { type: "copy_to_clipboard" } },
  { keybind: parseKeybind("ctrl+shift+v"), action: { type: "paste_from_clipboard" } },

  // macOS clipboard (when meta key available)
  { keybind: parseKeybind("super+c"), action: { type: "copy_to_clipboard" } },
  { keybind: parseKeybind("super+v"), action: { type: "paste_from_clipboard" } },

  // Scrolling
  { keybind: parseKeybind("shift+page_up"), action: { type: "scroll", direction: "up", amount: "page" } },
  { keybind: parseKeybind("shift+page_down"), action: { type: "scroll", direction: "down", amount: "page" } },
  { keybind: parseKeybind("shift+home"), action: { type: "scroll", direction: "up", amount: "top" } },
  { keybind: parseKeybind("shift+end"), action: { type: "scroll", direction: "down", amount: "bottom" } },

  // Windows
  { keybind: parseKeybind("ctrl+shift+n"), action: { type: "new_window" } },
  { keybind: parseKeybind("ctrl+shift+w"), action: { type: "close_window" } },
  { keybind: parseKeybind("ctrl+tab"), action: { type: "cycle_window", direction: "next" } },
  { keybind: parseKeybind("ctrl+shift+tab"), action: { type: "cycle_window", direction: "prev" } },

  // Direct window switching
  { keybind: parseKeybind("alt+1"), action: { type: "switch_window", windowIndex: 1 } },
  { keybind: parseKeybind("alt+2"), action: { type: "switch_window", windowIndex: 2 } },
  // ... alt+3 through alt+9

  // Settings
  { keybind: parseKeybind("ctrl+comma"), action: { type: "open_settings" } },
];
```

## Edge Cases

### 1. Key Repeat

Key repeat events (holding a key) are not intercepted specially. If a keybind matches, the action executes on each repeat. For scroll actions, this provides natural continuous scrolling.

### 2. Focus Loss

When the terminal element loses focus (`blur` event), `consumedKeys` is cleared. This prevents stuck state where a key was consumed but focus was lost before keyup.

### 3. Multiple Matching Keybinds

The first matching keybind in the array wins. Order your keybinds from most specific to least specific.

### 4. `none` Action

The `none` action type allows explicitly unbinding a key. When matched, the key passes through to the server as if no keybind existed.

```typescript
// Unbind Ctrl+C (let it pass through to terminal)
{ keybind: parseKeybind("ctrl+c"), action: { type: "none" } }
```

### 5. Browser Shortcuts

Some browser shortcuts (like Ctrl+T, Ctrl+W, Ctrl+N) may be intercepted by the browser before reaching JavaScript. These cannot be reliably bound.

## Implementation Notes

### Matching Algorithm

```typescript
function matchesKeybind(event: KeyboardEvent, keybind: Keybind): boolean {
  // Exact modifier match required
  if (event.ctrlKey !== keybind.ctrl) return false;
  if (event.altKey !== keybind.alt) return false;
  if (event.shiftKey !== keybind.shift) return false;
  if (event.metaKey !== keybind.meta) return false;

  // Case-insensitive key comparison for letters
  const eventKey = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  const bindKey = keybind.key.length === 1 ? keybind.key.toLowerCase() : keybind.key;

  return eventKey === bindKey;
}
```

### Why Exact Modifier Match?

We require exact modifier match to avoid ambiguity:

```
Keybind: ctrl+c
Event: Ctrl+Shift+C pressed

Without exact match: Would trigger (Ctrl is held)
With exact match: Does NOT trigger (Shift wasn't in keybind)
```

This matches Ghostty's behavior and prevents accidental triggers.

## Testing

Run keybind tests:

```bash
cd client
bun test src/terminal/keybinds.test.ts   # Parser tests (39 tests)
bun test src/terminal/keyboard.test.ts   # Handler tests (14 tests)
bun test src/terminal/                   # All terminal tests
```

## Related Files

- `client/src/terminal/keybinds.ts` - Keybind parsing
- `client/src/terminal/keybinds.test.ts` - Parser tests
- `client/src/terminal/keyboard.ts` - Keyboard handler with interception
- `client/src/terminal/keyboard.test.ts` - Handler tests
- `client/src/terminal/actions.ts` - Action definitions and handlers

## Future Work

- **Keybind configuration file**: Parse `keybind = ctrl+c=copy_to_clipboard` from config
- **Keybind conflict detection**: Warn when two keybinds overlap
- **Conditional keybinds**: `performable:` prefix (only intercept if action can execute)
- **Unconsumed keybinds**: `unconsumed:` prefix (execute action AND send to server)
- **Key sequences**: Leader key support (`ctrl+a` then `c` for copy)

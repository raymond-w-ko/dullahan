# Clipboard System Specification

## Overview

Dullahan maintains two clipboards (`c` and `p`) with the **server as the source of truth**. All clipboard mutations flow through the server, which broadcasts changes to connected clients.

## Clipboards

| ID | Name | Purpose |
|----|------|---------|
| `c` | Clipboard | System clipboard (Ctrl+C/V style) |
| `p` | Primary | X11 primary selection (middle-click paste) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                           SERVER                                │
│  ┌─────────────────┐    ┌─────────────────┐                    │
│  │ ipc_clipboard_c │    │ ipc_clipboard_p │  ← Source of Truth │
│  └────────┬────────┘    └────────┬────────┘                    │
│           │                      │                              │
│           └──────────┬───────────┘                              │
│                      │                                          │
│              ┌───────▼───────┐                                  │
│              │   Broadcast   │                                  │
│              └───────┬───────┘                                  │
└──────────────────────┼──────────────────────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
    ┌─────────┐   ┌─────────┐   ┌─────────┐
    │Client 1 │   │Client 2 │   │Client N │
    │ c │ p   │   │ c │ p   │   │ c │ p   │  ← Local mirrors
    └─────────┘   └─────────┘   └─────────┘
         │
         ▼
    ┌─────────────────┐
    │navigator.clipboard│  ← Browser API (optional sync)
    └─────────────────┘
```

## Behaviors

### 1. Server Source of Truth

- Server maintains `ipc_clipboard_c` and `ipc_clipboard_p` as canonical state
- All clipboard mutations go through server first
- Server broadcasts changes to ALL connected clients
- New clients receive current clipboard state on connection

### 2. ClipboardBar Up Arrow (↑) — Export to System

Copies the **client's local mirror** of c or p to `navigator.clipboard`.

```
User clicks ↑ on CLIPBOARD panel
  → Read store.clipboardC
  → navigator.clipboard.writeText(text)
```

**Rationale**: This is a local-only operation. The user wants to copy dullahan's clipboard to their system clipboard for use in other applications. No server interaction needed.

### 3. ClipboardBar Down Arrow (↓) — Paste to PTY

Tells the server to paste from its source of truth to the focused PTY.

```
User clicks ↓ on CLIPBOARD panel
  → Send to server: { type: "clipboard_paste", paneId, clipboard: "c" }
  → Server reads ipc_clipboard_c
  → Server writes to PTY (with bracketed paste if enabled)
```

**Rationale**: The server clipboard is the source of truth. Pasting should use server state, not browser state, to ensure consistency across clients.

### 4. Keybind Paste — Send Text to PTY

Reads from `navigator.clipboard` and sends to PTY. Does NOT affect the c/p clipboards.

```
User presses paste keybind (e.g., Ctrl+Shift+V)
  → Read navigator.clipboard.readText()
  → Send to server: { type: "text", paneId, data: text }
  → Server writes to PTY (with bracketed paste if enabled)
```

**Rationale**: Uses the system clipboard directly, matching standard terminal emulator behavior. User pastes what they copied from any application.

### 5. Keybind Copy — Server Extracts Selection

Client tells server to copy; server extracts selected text from terminal state and broadcasts.

```
User presses copy keybind (e.g., Ctrl+Shift+C)
  → Send to server: { type: "copy", paneId }
  → Server reads selection from pane terminal state (pane.getSelectedText())
  → Server stores in ipc_clipboard_c
  → Server broadcasts to ALL clients: { type: "clipboard", operation: "set", clipboard: "c", data }
  → Each client receives:
      → Decode and store in store.clipboardC
      → Call navigator.clipboard.writeText(text)
```

**Rationale**: Selection state lives on the server, so server should extract the text. Client just signals intent. This keeps the server as the single source of truth for both selection and clipboard.

**Note**: Keybind copy only sets the `c` (system clipboard), not `p` (primary selection). This matches standard clipboard behavior where explicit copy goes to system clipboard.

### 6. Selection Updates Primary (p) Clipboard

When text is selected, automatically update the `p` clipboard. This is standard X11 terminal behavior.

Selection updates `p` clipboard when:
- Terminal is NOT in mouse reporting mode, OR
- User holds shift to bypass mouse reporting mode

```
User selects text (mouse drag, shift+mouse drag, or shift+arrow keys)
  → Server detects selection change
  → Server extracts selected text
  → Server stores in ipc_clipboard_p
  → Server broadcasts to ALL clients: { type: "clipboard", operation: "set", clipboard: "p", data }
  → Clients update store.clipboardP (but NOT navigator.clipboard)
```

**Rationale**: Standard X11 primary selection behavior — select to copy. This only affects the `p` clipboard, not `c` or the system clipboard.

**Note**: Shift+select explicitly bypasses mouse reporting mode, signaling user intent for normal selection behavior including primary clipboard update.

### 7. Middle-Click Pastes from Primary (p) Clipboard

Middle mouse button pastes from the server's `p` clipboard to the focused PTY.

```
User middle-clicks in terminal
  → Send to server: { type: "clipboard_paste", paneId, clipboard: "p" }
  → Server reads ipc_clipboard_p
  → Server writes to PTY (with bracketed paste if enabled)
```

**Rationale**: Standard X11 primary selection behavior — middle-click to paste. This mirrors the ClipboardBar down arrow behavior for `p`.

### 8. OSC 52 SET (Terminal → Clipboard)

When a terminal application sets the clipboard via OSC 52:

```
Terminal emits: ESC ] 52 ; c ; base64_data ESC \
  → Server parses OSC 52
  → Server stores in ipc_clipboard_c
  → Server broadcasts to ALL clients
  → Clients update local mirrors + navigator.clipboard
```

### 9. OSC 52 GET (Terminal ← Clipboard)

When a terminal application reads the clipboard via OSC 52:

```
Terminal emits: ESC ] 52 ; c ; ? ESC \
  → Server sends GET request to MASTER client only
  → Master client reads store.clipboardC (or navigator.clipboard fallback)
  → Master responds: { type: "clipboard_response", data: base64_text }
  → Server forwards to terminal
```

## Wire Protocol

### Client → Server

```typescript
// Copy selection to clipboard (from keybind copy)
{
  type: "copy",
  paneId: number
}

// Paste clipboard to PTY (from ClipboardBar down arrow)
{
  type: "clipboard_paste",
  paneId: number,
  clipboard: "c" | "p"
}

// Response to OSC 52 GET
{
  type: "clipboard_response",
  paneId: number,
  clipboard: string,
  data: string  // base64-encoded
}
```

### Server → Client

```typescript
// Clipboard update (SET or broadcast)
{
  type: "clipboard",
  paneId: number,      // 0 for IPC clipboard, paneId for OSC 52
  operation: "set" | "get",
  clipboard: string,   // "c", "p", or "s"
  data?: string        // base64-encoded, present for "set"
}
```

## Implementation Checklist

### New Features Required

- [x] **Server**: Handle `copy` message
  - Read selection from pane terminal state (`pane.getSelectionText()`)
  - Store in `ipc_clipboard_c`
  - Broadcast clipboard SET to ALL clients

- [x] **Server**: Handle `clipboard_paste` message
  - Read `ipc_clipboard_c` or `_p`
  - Write to target pane's PTY with bracketed paste support

- [x] **Server**: Auto-update `p` clipboard on selection change
  - Detect when selection changes
  - Update when: not in mouse reporting mode, OR shift+select bypass
  - Extract selected text and store in `ipc_clipboard_p`
  - Broadcast clipboard SET to ALL clients

- [x] **Client**: Trigger `navigator.clipboard.writeText` on receiving `c` clipboard SET
  - Only write to navigator.clipboard for `c` clipboard, not `p`
  - No special case needed — idempotent operation

- [x] **Client**: Update keybind copy to send `copy` message
  - Change from local selection extraction to server-side

- [x] **Client**: Update ClipboardBar down arrow to send `clipboard_paste`
  - Change from `copySystemToInternal()` to new paste-to-PTY action

- [x] **Client**: Update keybind paste to always use `navigator.clipboard`
  - Remove fallback to internal clipboard mirrors

- [x] **Client**: Handle middle-click to paste from `p` clipboard
  - Server handles this in mouse event processing
  - Only when not in mouse reporting mode

### Existing Features (Verify Correct)

- [x] Server stores `ipc_clipboard_c` and `ipc_clipboard_p`
- [x] Server sends clipboard state to new clients on connect
- [x] Client maintains local mirrors (`store.clipboardC`, `store.clipboardP`)
- [x] ClipboardBar up arrow copies local mirror to navigator.clipboard
- [x] Keybind paste sends text to PTY (doesn't affect c/p)
- [x] OSC 52 SET broadcasts to all clients
- [x] OSC 52 GET handled by master client

## Design Decisions

### Why Server as Source of Truth?

1. **Multi-client consistency**: All clients see the same clipboard state
2. **Persistence**: Clipboard survives client disconnect/reconnect
3. **IPC access**: CLI tools can read/write clipboard via IPC commands

### Why Server-Side Copy?

1. **Source of truth**: Selection state lives on server, so server extracts the text
2. **Consistency**: Server stores and broadcasts, ensuring all clients sync
3. **Simplicity**: Client just sends "copy" — no need to extract and transmit selection text

### Why navigator.clipboard for Keybind Paste?

1. **Standard behavior**: Matches how terminal emulators work (paste from system clipboard)
2. **Cross-application**: User can copy from any app and paste into terminal
3. **No server round-trip**: Direct read from browser API

### Additional Decisions

1. **Down arrow pastes immediately** — no confirmation or preview dialog.

2. **No "import from system" action** — keybind paste reads `navigator.clipboard` directly, so users can paste from external apps without needing to import into c/p mirrors first.

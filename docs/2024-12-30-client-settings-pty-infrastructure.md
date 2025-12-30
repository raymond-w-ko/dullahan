# 2024-12-30: Client Settings & PTY Infrastructure

Major session: implemented comprehensive client settings UI and persistent PTY infrastructure for real shell sessions.

## Client Settings

### Cursor Options
- **Style**: block, bar, underline, block_hollow (4 Ghostty styles)
- **Color**: empty (theme), `#hex`, `cell-foreground`, `cell-background`
- **Text color**: same options as cursor color
- **Opacity**: 0.0-1.0 range
- **Blink**: dropdown with (auto), true, false - auto respects DEC Mode 12

CSS uses `::before`/`::after` pseudo-elements for bar/underline/hollow to preserve text styling.

### Font Options
- Font family, size, weight (100-900), features (`"liga" 1, "ss01" 1`)
- Line height (1.0-3.0) - not in Ghostty, added for flexibility

### Layout Changes
- Moved sidebar from left (32px wide) to bottom (32px tall)
- Removed horizontal padding and terminal grid gaps
- Goal: fit 3× 80-column terminals on 13" MacBook Air

## Terminal Dimension Calculation

New `useTerminalDimensions` hook:
- Uses `ResizeObserver` to detect container size changes
- Hidden measurement span for exact cell width/height
- Calculates visible cols/rows from container minus padding
- Waits for fonts to load before measuring
- `TerminalPlaceholder` component for empty panes with dimensions

All 3 terminal panes now display calculated dimensions in titlebar.

## Persistent PTY Infrastructure

### Before
- PTY created per-command, synchronous read loop, closed when done
- One-shot commands only (demo purposes)

### After
- Pane holds persistent `pty: ?Pty` and `child_pid`
- Shell spawns automatically on server start
- Dedicated I/O thread polls all PTY master fds

### New Components

**Pane methods:**
```zig
spawnShell()     // Open PTY, fork shell
writeInput()     // Write to PTY stdin
getPtyFd()       // For polling
isAlive()        // Check child status, reap zombies
```

**PtyReader (`pty_reader.zig`):**
- Dedicated thread for I/O multiplexing
- `poll()` on all PTY master fds with 100ms timeout
- Reads output, feeds to corresponding pane
- Handles hangup/error (child exit)

**Data flow:**
```
Client keypress → WebSocket input message
                → pane.writeInput() → PTY master write
                → Shell receives input
                → Shell writes output
                → PtyReader: poll() → pty.read()
                → pane.feed() → version++
                → WsServer sends snapshot
                → Client renders
```

### Environment Variables
Child process now sets (for Ghostty compatibility):
- `TERM_PROGRAM=ghostty`
- `TERM=xterm-ghostty`
- `TERMINFO=/Applications/Ghostty.app/Contents/Resources/terminfo` (if exists)

### stdout/stderr
Both merged by PTY design - slave fd is child's controlling terminal, both streams go to same master fd. Kernel handles write ordering.

## Issues Filed
- `du-9yo`: Send terminal resize to server
- `du-u3m`: Implement DEC Mode 12 (AT&T cursor blink)
- `du-d4e`: Add IPC command for sending terminal input

## Issues Closed
- `du-lpl`, `du-z07`, `du-mb2`, `du-b0n`: Font settings
- `du-5mp`, `du-896`, `du-at5`, `du-csm`, `du-2gt`: Cursor settings
- `du-7yb`: Deferred (adjust-cell-width needs Canvas)
- `du-12r`, `du-kqi`: Window padding (now CSS variables)

## Code Quality
Added rule to AGENTS.md: TODOs must reference beads issues (`TODO(du-xxx)`)

## Next Up
- Client sends resize to server (du-9yo)
- Binary WebSocket frames (skip JSON/base64)
- Delta updates instead of full snapshots
- More terminal escape sequence support

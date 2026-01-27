# AGENTS.md — dullahan

---

## RULE 0 - THE FUNDAMENTAL OVERRIDE PEROGATIVE

If I tell you to do something, even if it goes against what follows below, YOU MUST LISTEN TO ME. I AM IN CHARGE, NOT YOU.

---

## RULE NUMBER 1: NO FILE DELETION

**YOU ARE NEVER ALLOWED TO DELETE A FILE WITHOUT EXPRESS PERMISSION.** Even a new file that you yourself created, such as a test code file. You have a horrible track record of deleting critically important files or otherwise throwing away tons of expensive work. As a result, you have permanently lost any and all rights to determine that a file or folder should be deleted.

**YOU MUST ALWAYS ASK AND RECEIVE CLEAR, WRITTEN PERMISSION BEFORE EVER DELETING A FILE OR FOLDER OF ANY KIND.**

---

## Irreversible Git & Filesystem Actions — DO NOT EVER BREAK GLASS

1. **Absolutely forbidden commands:** `git reset --hard`, `git clean -fd`, `rm -rf`, or any command that can delete or overwrite code/data must never be run unless the user explicitly provides the exact command and states, in the same message, that they understand and want the irreversible consequences.
2. **No guessing:** If there is any uncertainty about what a command might delete or overwrite, stop immediately and ask the user for specific approval. "I think it's safe" is never acceptable.
3. **Safer alternatives first:** When cleanup or rollbacks are needed, request permission to use non-destructive options (`git status`, `git diff`, `git stash`, copying to backups) before ever considering a destructive command.
4. **Mandatory explicit plan:** Even after explicit user authorization, restate the command verbatim, list exactly what will be affected, and wait for a confirmation that your understanding is correct. Only then may you execute it—if anything remains ambiguous, refuse and escalate.
5. **Document the confirmation:** When running any approved destructive command, record (in the session notes / final response) the exact user text that authorized it, the command actually run, and the execution time. If that record is absent, the operation did not happen.

---

## Project Architecture

**Dullahan** is a modern tmux reimagined as a server + client model.

### Server (Zig)
- Written in Zig using `libghostty-vt` for terminal emulation
- Source of truth for all terminal state
- Sends full snapshots and delta updates to connected clients
- Runs as a daemon on Linux/macOS (Windows support planned — see `docs/windows-support-feasibility.md`)
- **Single binary**: `zig-out/bin/dullahan` — all functionality in one executable
- **Two communication channels:**
  - **IPC socket** (`/tmp/dullahan-<uid>/dullahan.sock`) — CLI control (ping, status, quit)
  - **WebSocket** (port `7681`) — Client connections for terminal data
- **Single-parser architecture**: Uses a custom `StreamHandler` that receives parsed VT events from ghostty-vt and routes them appropriately (terminal-modifying events to Terminal, query/notification events to Pane)

### Client (Web)
- Browser-based UI supporting multiple simultaneous connections
- Responsive design for desktop, laptop, and mobile
- **Uses Bun** for package management and running TypeScript
- **Master/Slave model** — first client becomes master, others are read-only viewers
- Rendering backends (in order of development):
  1. **React/Preact** — initial implementation (current)
  2. **Canvas** — explicit font drawing for performance
  3. **WebGL** — custom shaders for effects (à la Ghostty)

### Master/Slave Client Model

Dullahan supports multiple simultaneous browser connections with a master/slave hierarchy:

- **Master client**: First client to connect (or one who requests master). Can:
  - Send keyboard input (`sendKey`, `sendText`)
  - Resize terminals (`sendResize`)
  - Scroll terminals (`sendScroll`)
  - Create new windows
- **Slave clients**: Read-only viewers. Can:
  - View all terminal content (receive snapshots/deltas)
  - Switch between windows (local view preference only)
  - Request to become master

**Key files:**
- `server/src/event_loop.zig` — master assignment, input routing
- `client/src/terminal/connection.ts` — master checks on input methods
- `client/src/components/App.tsx` — UI showing master status (star icon in bottombar)

### Window/Pane Architecture

Windows and panes are **dynamic** — windows can have variable numbers of panes:

- **Window 0** (initial): Debug pane + 2 shell panes (created by `session.createInitialLayout()`)
- **New windows**: 3 shell panes (created by `session.createShellWindow()`)
- **Pane IDs**: Only `DEBUG_PANE_ID` (0) is special; all others are dynamically allocated
- **Layout system**: Uses recursive `LayoutRenderer` with inline-block CSS

### Layout System

Windows use a template-based layout system stored in `~/.config/dullahan/layouts.json`.

**Key concepts:**
- **LayoutNode**: Either a `container` (has children) or `pane` (terminal placeholder)
- **Split direction**: Implicit from nesting level (level 0=horizontal, 1=vertical, alternating)
- **Templates**: Named layouts (e.g., "single", "2-col", "3-col", "2x2", "main-side")

**Default templates (8 built-in):**
| ID | Name | Description |
|----|------|-------------|
| `single` | Single Pane | One full-size pane |
| `2-col` | Two Columns | Side by side |
| `2-row` | Two Rows | Stacked vertically |
| `3-col` | Three Columns | Three side by side |
| `2x2` | 2×2 Grid | Four panes in grid |
| `main-side` | Main + Sidebar | 70/30 split |
| `main-2side` | Main + 2 Sidebars | Main left, two stacked right |

**Key files:**
- `server/src/layout_db.zig` — Layout database, JSON persistence, default templates
- `protocol/schema/layout.ts` — Shared TypeScript types and helpers
- `client/src/components/LayoutRenderer.tsx` — Recursive layout renderer
- `client/src/components/LayoutPickerModal.tsx` — Template selection UI

**Wire format (in layout message):**
```typescript
interface LayoutNode {
  type: "container" | "pane";
  width: number;   // Percentage (0-100)
  height: number;  // Percentage (0-100)
  children?: LayoutNode[];  // For containers
  paneId?: number;          // For panes (assigned at runtime)
}
```

**Client state starts empty** — the server populates windows/panes via layout messages:
```typescript
windows: new Map(),  // Populated by server layout message
panes: new Map(),    // Created on-demand when snapshots arrive
```

**Important ordering caveat**: Snapshots may arrive before layout messages. The client creates pane state on-demand in `setPaneSnapshot()` to handle this.

**Client commands:**
```bash
cd client
bun install          # Install dependencies
bun run build        # Build for production
bun run dev          # Watch mode for development
bun run serve        # Dev server at http://localhost:3000
bun run typecheck    # Type check without emitting
```

**Makefile targets:**
```bash
make build           # Build both server and client (debug)
make server          # Build server only (includes theme-db)
make client          # Build client only (includes themes)
make dist            # Production build (single binary with embedded client)
make install         # Build dist and install to ~/bin
make themes          # Download Ghostty themes + generate CSS
make theme-db        # Generate server-side Zig theme database
make coverage        # Run all tests with coverage
make fmt             # Format server code with zig fmt
make dev             # Build and run with debug logging (port 7682)
make prod            # Build dist and run production (port 7681)
make clean           # Remove build artifacts
```

### Development REPL

The server includes an IPC system for runtime inspection. **Never run `dullahan serve` directly in bash** — it blocks forever. Instead, use client commands which auto-spawn the server:

```bash
# These commands auto-spawn the server if not running:
./zig-out/bin/dullahan ping      # Check server responsiveness
./zig-out/bin/dullahan status    # Get runtime state (uptime, command count)
./zig-out/bin/dullahan help      # List available commands
./zig-out/bin/dullahan quit      # Gracefully shutdown server

# Options:
./zig-out/bin/dullahan --timeout=1000 ping   # Custom timeout (ms)
./zig-out/bin/dullahan --no-spawn status     # Don't auto-spawn, fail if not running
./zig-out/bin/dullahan serve --static-dir=./client  # Serve client files
./zig-out/bin/dullahan serve --port=8080     # Custom port
```

**Use this REPL to verify assumptions during development:**
- Check if server is running: `dullahan ping`
- Inspect runtime state: `dullahan status`  
- Clean shutdown before rebuild: `dullahan quit`

### Test Utilities

Integrated test commands for debugging (run in a real terminal like Ghostty):

```bash
./zig-out/bin/dullahan test help            # Show available test commands
./zig-out/bin/dullahan test keytest-kitty   # Kitty keyboard protocol tester
./zig-out/bin/dullahan test keytest-bytes   # Byte coverage tester (256-byte grid)
./zig-out/bin/dullahan test delta-gen       # Generate delta sync test fixtures
./zig-out/bin/dullahan test shell-delta     # Shell delta sync test
./zig-out/bin/dullahan test grapheme-test   # Grapheme cluster rendering test
./zig-out/bin/dullahan test hyperlink-test  # OSC 8 hyperlink test
```

**keytest-kitty** — Tests Kitty keyboard protocol with full event reporting:
- Shows press (↓), repeat (⟳), release (↑) events
- Displays modifiers and raw bytes
- Logs to `/tmp/dullahan-<uid>/keytest-kitty.log`
- Press Escape twice to exit

**keytest-bytes** — Verifies all 256 bytes can be input:
- Grid of 0x00-0xFF, lights up when byte received
- Detects escape sequences (shows warning instead of lighting intermediate bytes)
- Useful for testing raw terminal input handling

**delta-gen** — Generates test fixtures for delta sync verification:
- Creates `test_fixtures/delta/` with snapshot and delta files
- Useful for protocol testing and debugging

**shell-delta** — End-to-end delta sync test:
- Spawns a real shell, sends arrow keys
- Compares delta vs snapshot for correctness

**grapheme-test** — Displays various Unicode grapheme clusters:
- Emoji with skin tone modifiers (👍🏻)
- ZWJ family/profession sequences (👨‍👩‍👧, 👩‍💻)
- Flag emoji (🇺🇸, 🇯🇵)
- Combining marks and diacritics (é, ñ)
- CJK wide characters
- Useful for verifying grapheme cluster rendering

**hyperlink-test** — Displays OSC 8 clickable hyperlinks:
- HTTPS, HTTP, mailto:, tel:, file:// links
- Links with query params and anchors
- Grouped links with id parameter
- Links with color styling
- Useful for verifying OSC 8 hyperlink support

### Test Coverage

```bash
make coverage          # Run both server and client coverage
make coverage-server   # Server only (module-level)
make coverage-client   # Client only (line-level via bun)
```

**Client coverage** works well — bun has built-in line-level coverage reporting.

**Server coverage** is limited to module-level (which modules have tests, pass/fail counts).
Line-level coverage via kcov doesn't work because kcov can't parse Zig's DWARF debug info format.
Waiting on [ziglang/zig#352](https://github.com/ziglang/zig/issues/352) for native coverage support.

### Ports & Paths

All temp files are stored in `/tmp/dullahan-<uid>/` where `<uid>` is the user's UID.
This provides isolation between users on shared systems.

| Resource | Location | Purpose |
|----------|----------|---------|
| Config Dir | `~/.config/dullahan/` | User configuration files |
| Layouts | `~/.config/dullahan/layouts.json` | Layout templates (auto-created) |
| Temp Dir | `/tmp/dullahan-<uid>/` | All server temp files |
| IPC Socket | `/tmp/dullahan-<uid>/dullahan.sock` | CLI ↔ Server communication |
| PID File | `/tmp/dullahan-<uid>/dullahan.pid` | Server process tracking |
| WebSocket | `ws://localhost:7681` | Client ↔ Server terminal data |
| Log File | `/tmp/dullahan-<uid>/dullahan.log` | Server debug logging |
| Category Log | `/tmp/dullahan-<uid>/dullahan-dlog.log` | Wine-style category debug logging |
| PTY Traffic | `/tmp/dullahan-<uid>/pty-traffic.log` | PTY I/O hex dump (when enabled) |

**PTY traffic logging** is disabled by default. Enable with `dullahan pty-log-on`.

**Port 7681** is also used by ttyd/libwebsockets — if you run both, one will fail to bind.

**Security:** Server binds to `127.0.0.1` only — no remote connections accepted.

### Repo Layout

```
dullahan/
├── AGENTS.md
├── CLAUDE.md
├── LICENSE
├── Makefile                 # orchestrates both builds (also: `make fmt`)
├── dullahan -> ./server/zig-out/bin/dullahan  # symlink to built binary
│
├── server/
│   ├── build.zig
│   ├── build.zig.zon        # dependencies (libghostty-vt)
│   └── src/
│       ├── main.zig         # entry point + logging setup
│       ├── root.zig         # library exports
│       ├── server.zig       # main server loop (IPC + WS threads)
│       ├── cli.zig          # CLI argument parsing
│       ├── ipc.zig          # Unix socket IPC for CLI control
│       ├── ipc_commands.zig # IPC command handlers (ping, status, quit, etc.)
│       ├── http.zig         # HTTP server with WebSocket upgrade
│       ├── websocket.zig    # WebSocket frame encoding/decoding
│       ├── event_loop.zig   # Central event loop (master/slave, message routing)
│       ├── message_handlers.zig # Extracted message handlers (keyboard, mouse, clipboard, etc.)
│       ├── message_parsing.zig  # JSON message parsing from WebSocket clients
│       ├── client_state.zig # Client connection state (generations, auth)
│       ├── layout_helpers.zig # Layout utility functions
│       ├── stream_handler.zig # Single-parser VT stream handler
│       ├── theme_db.zig     # Server-side theme database (OSC 10/11 color queries)
│       ├── snapshot.zig     # Terminal state → msgpack + delta generation
│       ├── embedded_assets.zig # Embedded client for single-binary dist
│       ├── session.zig      # Session (creates windows, initial layout)
│       ├── window.zig       # Window (contains panes, layout tree)
│       ├── pane.zig         # Pane (terminal + PTY + generation tracking)
│       ├── pane_registry.zig # Pane ID allocation (only DEBUG_PANE_ID=0 is special)
│       ├── layout_db.zig    # Layout templates, JSON persistence
│       ├── terminal.zig     # ghostty-vt wrapper
│       ├── pty.zig          # PTY allocation (Linux/macOS)
│       ├── pty_log.zig      # PTY traffic logging (debug)
│       ├── test_runners.zig # Integrated test utilities (keytest, delta tests)
│       ├── keyboard.zig     # Server-side keyboard input processing
│       ├── mouse.zig        # Server-side mouse event handling
│       ├── clipboard.zig    # Clipboard (OSC 52) handling
│       ├── messages.zig     # Server-side message types
│       ├── constants.zig    # Shared constants
│       ├── paths.zig        # Path resolution utilities
│       ├── process.zig      # Process spawning utilities
│       ├── shell.zig        # Shell detection and spawning
│       ├── signal.zig       # Signal handling
│       ├── dlog.zig         # Wine-style category debug logging
│       ├── debug_config.zig # Debug logging configuration
│       ├── tailscale.zig    # Tailscale detection for remote access
│       ├── ws_proxy.zig     # WebSocket proxy (auth, permissions)
│       ├── math.zig         # Math utilities
│       └── assets/          # Embedded static assets
│
├── client/
│   ├── package.json
│   ├── bun.lock             # bun lockfile
│   ├── tsconfig.json
│   ├── esbuild.config.ts
│   ├── index.html           # loads dullahan.css + themes.css
│   ├── serve.ts             # dev server
│   ├── src/
│   │   ├── main.ts          # entry point
│   │   ├── store.ts         # reactive state management
│   │   ├── config.ts        # user preferences (localStorage)
│   │   ├── constants.ts     # Client-side constants
│   │   ├── debug.ts         # Debug logging (enable with ?debug)
│   │   ├── dullahan.css     # base styles
│   │   ├── palette.css      # 256-color palette CSS variables
│   │   ├── liquid-glass.css # Liquid glass UI effect styles
│   │   ├── themes.css       # 453 Ghostty themes (generated, gitignored)
│   │   ├── themes.ts        # theme name index (generated, gitignored)
│   │   ├── components/
│   │   │   ├── App.tsx              # root component
│   │   │   ├── TerminalGrid.tsx     # dynamic pane grid layout
│   │   │   ├── TerminalPane.tsx     # individual terminal pane
│   │   │   ├── TerminalView.tsx     # terminal rendering (cells, cursor, selection)
│   │   │   ├── LayoutRenderer.tsx   # recursive layout tree renderer
│   │   │   ├── LayoutDivider.tsx    # draggable pane dividers
│   │   │   ├── LayoutPickerModal.tsx # template selection modal
│   │   │   ├── WindowSwitcher.tsx   # tab bar for window switching
│   │   │   ├── SettingsModal.tsx    # settings panel
│   │   │   ├── ClipboardBar.tsx     # clipboard paste confirmation bar
│   │   │   ├── ContextMenu.tsx      # right-click context menu
│   │   │   ├── ProgressBar.tsx      # OSC 9;4 progress bar
│   │   │   ├── ToastContainer.tsx   # toast notification display
│   │   │   └── ErrorBoundary.tsx    # React error boundary
│   │   ├── hooks/
│   │   │   ├── useScrollback.ts     # Scrollback buffer management
│   │   │   ├── useSettings.ts       # Settings state hook
│   │   │   ├── useModalBehavior.ts  # Modal open/close behavior
│   │   │   ├── useStoreSubscription.ts # Store subscription hook
│   │   │   └── useTerminalDimensions.ts # Terminal size calculation
│   │   └── terminal/
│   │       ├── connection.ts    # WebSocket client + LRU cache management
│   │       ├── keyboard.ts      # Keyboard event handling + keybind interception
│   │       ├── keybinds.ts      # Keybind string parser (Ghostty-style)
│   │       ├── keybindConfig.ts # Keybind configuration loading
│   │       ├── actions.ts       # Terminal action types and handlers
│   │       ├── dimensions.ts    # Shared cell dimension calculation
│   │       ├── handler.ts       # InputHandler interface for input handlers
│   │       ├── ime.ts           # IME composition support
│   │       ├── mouse.ts         # Mouse event handling + coordinate conversion
│   │       ├── clipboard.ts     # Clipboard read/write operations
│   │       ├── hyperlink.ts     # OSC 8 hyperlink handling
│   │       ├── cellRendering.ts # Cell rendering logic
│   │       ├── cursorRendering.tsx # Cursor rendering component
│   │       ├── terminalStyle.ts # Terminal style computation
│   │       └── stringLiteral.ts # String literal parsing for keybinds
│   └── dist/                # build output (gitignored)
│
├── protocol/                # shared definitions
│   ├── messages.md          # wire format documentation
│   └── schema/
│       ├── cell.ts          # Cell encode/decode (matches ghostty packed struct)
│       ├── cell.test.ts     # Cell tests (bun test)
│       ├── delta.test.ts    # Delta sync tests (bun test)
│       ├── layout.ts        # Layout node types + helpers
│       ├── layout.test.ts   # Layout tests (bun test)
│       ├── messages.ts      # Wire protocol message types (client↔server)
│       ├── messages.test.ts # Message tests (bun test)
│       ├── style.ts         # Style encode/decode (colors, attributes)
│       └── style.test.ts    # Style tests (bun test)
│
├── docs/                    # documentation
│   ├── delta-sync-design.md # Delta sync protocol design (row IDs, generations)
│   ├── cache-miss-resync-design.md # Cache miss recovery via resync message
│   ├── keybindings.md       # Keybinding system design and API
│   ├── clipboard-spec.md    # Clipboard (OSC 52) specification
│   ├── ime-support.md       # IME (Input Method Editor) support design
│   ├── logging.md           # Comprehensive logging system documentation
│   ├── profiling-server.md  # Server profiling guide (perf, heaptrack, strace)
│   ├── windows-support-feasibility.md # Windows support analysis
│   └── zig-0.15-notes.md    # Zig 0.15 migration notes
│
├── scripts/
│   ├── update-ghostty.sh    # updates dependency + source checkout
│   ├── setup-beads.sh       # initialize beads issue tracking
│   ├── generate-themes.ts   # convert Ghostty themes to CSS
│   ├── generate-theme-db.ts # generate server-side Zig theme database
│   └── generate-embedded-assets.ts # embed client in server binary
│
├── test_fixtures/           # test data files
│   └── delta/               # delta sync test fixtures
│
├── dist/                    # distribution builds (gitignored)
│
└── deps/                    # gitignored, source checkouts for reference
    ├── ghostty/             # ghostty source (synced to dependency version)
    └── themes/ghostty/      # 453 Ghostty theme files (downloaded)
```

### Dependency Source Reference

The `deps/ghostty/` directory contains a git checkout of the ghostty source code,
synced to the same commit as our zig dependency. This is for **reference only** —
the actual dependency comes from `build.zig.zon`.

```bash
# Update dependency AND sync source checkout:
./scripts/update-ghostty.sh

# Browse ghostty source for API reference:
ls deps/ghostty/src/
```

This checkout is gitignored and created/updated by the update script.

### Wire Protocol

Server→Client uses binary msgpack compressed with Snappy:
- **Snapshot**: Full terminal state (cells, styles, cursor, rowIds, generation)
- **Delta**: Incremental update (dirty rows only, for sync requests)

Client→Server uses JSON:
- **key/text**: Keyboard and IME input
- **resize**: Terminal dimension changes
- **scroll**: Viewport scrolling
- **sync**: Request delta update with client's generation and `minRowId`
- **resync**: Request full snapshot when cache miss is detected
- **hello**: Client identification with optional theme info (`themeName`, `themeFg`, `themeBg`)

See `protocol/messages.md` for full specification.

### Delta Sync Protocol

Efficient synchronization using stable row IDs and generation counters.
See `docs/delta-sync-design.md` for design details.

**Key concepts:**
- `row_id = (page_serial × 1000) + row_index` — stable identifier
- `generation` — increments on any terminal change
- `dirty_rows` — set of changed row IDs since last sync

**Server state (pane.zig):**
```zig
generation: u64,                    // Increments on feed/resize/scroll
dirty_rows: HashSet(u64),           // Row IDs changed since clear
dirty_base_gen: u64,                // Generation when tracking started
```

**Client state (connection.ts):**
```typescript
_generation: number;                // Last sync'd generation
_minRowId: bigint;                  // Oldest cached row
_rowCache: Map<bigint, CachedRow>;  // LRU-style row cache with access tracking
_styleTable: Map<number, Style>;    // Style table (pruned to 256 entries)
```

**Cache management:**
- Row cache is pruned to 500 rows max using LRU eviction
- Style table is pruned to 256 entries max
- When delta references evicted data, client requests a `resync`
- Server can also detect staleness via `minRowId` in sync messages

**Resync message:**
```typescript
interface ResyncMessage {
  type: "resync";
  paneId: number;
  reason: "cache_miss" | "style_miss" | "corruption" | "manual";
}
```

**Debug UI:** Titlebar shows `Δ{deltas} ⟳{resyncs}` for sync statistics.

### Terminal Actions

The action system handles client-side operations triggered by keybinds, separate from sending input to the server.

**Key file:** `client/src/terminal/actions.ts`

**Action types:**
| Action | Description |
|--------|-------------|
| `copy_to_clipboard` | Copy selection to clipboard |
| `paste_from_clipboard` | Paste from clipboard |
| `scroll` | Viewport scrolling (line/page/half_page/top/bottom) |
| `send_text` | Send literal text to terminal |
| `clear_screen` | Clear screen (sends Ctrl+L) |
| `reset_terminal` | Reset to initial state (sends ESC c) |
| `new_window` | Create new window |
| `switch_window` | Switch to window by index (1-based) |
| `cycle_window` | Cycle next/prev window |
| `focus_pane` | Focus pane (next/prev/directional) |
| `open_settings` | Open settings modal |

**Usage:**
```typescript
import { executeAction, actions, ActionContext } from "./terminal/actions";

// Create context with dependencies
const ctx: ActionContext = {
  paneId: 1,
  sendText: (text) => connection.sendText(text),
  sendScroll: (paneId, lines) => connection.sendScroll(paneId, lines),
  // ... other context methods
};

// Execute an action
await executeAction(actions.scrollUp("page"), ctx);
await executeAction(actions.copy(), ctx);
```

See `docs/keybindings.md` for complete keybinding system documentation.

### Common Pitfalls

**Don't hardcode pane counts or IDs:**
```zig
// ❌ BAD - assumes exactly 3 panes
var pane_generations: [3]u64 = .{ 0, 0, 0 };

// ✅ GOOD - dynamic
var pane_generations = std.AutoHashMap(u16, u64).init(allocator);
```

**Handle message ordering:**
```typescript
// Snapshots may arrive before layout - create pane on-demand
export function setPaneSnapshot(paneId: number, snapshot: TerminalSnapshot) {
  let pane = store.panes.get(paneId);
  if (!pane) {
    pane = createPaneState(paneId);  // Don't discard!
    store.panes.set(paneId, pane);
  }
  pane.snapshot = snapshot;
}
```

**Broadcast to all clients, not just one:**
```zig
// When creating new panes, send snapshots to ALL clients
for (self.clients.items) |*client| {
    self.sendSnapshot(&client.ws, new_pane);
}
```

**Check master before sending input:**
```typescript
sendKey(message: KeyMessage): void {
  if (!this.isMaster) return;  // Slaves are read-only
  this.send(message);
}
```

**Update embedded assets when adding client files:**

When creating new CSS, JS, or static files in `client/`, you must update `scripts/generate-embedded-assets.ts`:
1. Add new CSS files to the CSS list (line ~91)
2. Add the `<link>` or `<script>` tag to the index.html template (line ~68-83)
3. For other static files, add a `copyAsset()` call

```typescript
// ❌ BAD - created client/src/new-styles.css but forgot embedded assets
// Distribution builds will be missing the file!

// ✅ GOOD - update generate-embedded-assets.ts
for (const css of ["palette.css", "liquid-glass.css", "dullahan.css", "themes.css"]) {
//                               ^^^^^^^^^^^^^^^^^ add new CSS here
```

### Server Debug Logging

Wine-style category-based logging for the server, mirroring the client's system.

**Configuration:**
- Environment variable: `DULLAHAN_DEBUG=+all,-delta`
- IPC command: `dullahan debug-log +all,-delta`
- Runtime: `debug_config.setConfigString("+all,-clipboard")`

**Syntax:** Same as client - `+category` enables, `-category` disables, `+all/-all` wildcards, left-to-right evaluation.

**Categories:**
| Category | Description |
|----------|-------------|
| connection | WebSocket connect/disconnect, client join/leave |
| keyboard | Keyboard input |
| mouse | Mouse events |
| clipboard | OSC 52 operations, copy/paste |
| pane | Pane creation, resize, terminal state |
| window | Window creation, layout changes |
| delta | Delta sync, dirty rows, generation tracking |
| snapshot | Terminal snapshots |
| layout | Layout loading, template selection |
| theme | OSC 10/11 color changes, palette sync |
| pty | PTY I/O, shell detection |
| dsr | Device Status Reports |
| ipc | IPC commands, status queries |
| http | HTTP server, WebSocket upgrade |
| signal | Signal handling, shutdown |

**IPC Commands:**
```bash
dullahan debug-log              # Show current config and categories
dullahan debug-log +all         # Enable all categories
dullahan debug-log +all,-delta  # All except delta
dullahan debug-log off          # Disable all logging
dullahan debug-log list         # List all categories
```

**Usage in code:**
```zig
const dlog = @import("dlog.zig");
const log = dlog.scoped(.clipboard);

// ✅ GOOD - uses category logger
log.info("OSC 52 received", .{});
log.debug("parsing data", .{});
log.err("failed");  // Always logs regardless of category

// ❌ BAD - uncategorized dlog (always logs)
dlog.info("OSC 52 received", .{});
```

**Output channels:**
- **Log file**: `/tmp/dullahan-<uid>/dullahan-dlog.log` (always written when category enabled)
- **Debug pane**: Pane 0, color-coded by level
- **Stderr**: In **release builds**, only errors. In **debug builds** (`zig build` without `-Doptimize`), ALL logs go to stderr for easier development.

See `docs/logging.md` for comprehensive documentation.

### Client Debug Logging

Wine-style category-based logging. **Never use `console.log` directly** for debug output.

**Syntax:** `?debug=+all,-mouse,+pane` or `localStorage.setItem('debug', '+all,-mouse')`

**Rules:**
- `+category` enables a category
- `-category` disables a category
- `+all` / `-all` enables/disables all categories
- Evaluated left-to-right: `+all,-mouse` = everything except mouse
- Bare `?debug` defaults to `+all` for backward compatibility
- Errors always log regardless of category setting

**Categories:**
| Category | Description |
|----------|-------------|
| connection | WebSocket connect/disconnect |
| sync | Delta sync, generation tracking |
| snapshot | Terminal state snapshots |
| delta | Delta updates |
| mouse | Mouse click, up/down, wheel events |
| mousemove | Mouse move events (spammy, separate from mouse) |
| keyboard | Keyboard input |
| keybind | Keybind parsing |
| clipboard | Clipboard operations |
| config | Configuration |
| ime | IME composition |
| resize | Terminal resizing |
| layout | Layout messages |
| store | State store operations |
| shell | Shell integration (OSC 133) events |

**Examples:**
```bash
# Enable all logging
http://localhost:7681/?debug

# Only mouse and keyboard
http://localhost:7681/?debug=+mouse,+keyboard

# Everything except verbose sync/delta
http://localhost:7681/?debug=+all,-sync,-delta
```

**Usage in code:**
```typescript
import { debug } from '../debug';
const mouseLog = debug.category('mouse');

// ✅ GOOD - uses category logger
mouseLog.log('click at', x, y);
mouseLog.warn('unexpected state');
mouseLog.error('failed');  // Always logs regardless of category

// ❌ BAD - direct console.log
console.log('click at', x, y);
```

All output is prefixed with `[dullahan:category]` for easy filtering in DevTools.

### Server Profiling

For performance analysis, see `docs/profiling-server.md` for detailed guidance.

**Quick memory check:**
```bash
PID=$(cat /tmp/dullahan-$(id -u)/dullahan.pid)
ps -o pid,rss,vsz,comm -p $PID     # One-shot check
watch -n 2 "ps -o pid,rss,vsz,comm -p $PID"  # Continuous monitoring
```

**CPU profiling with perf:**
```bash
sudo perf record -F 99 -p $PID -g -- sleep 30
sudo perf report
# Or generate flame graph:
sudo perf script | stackcollapse-perf.pl | flamegraph.pl > flamegraph.svg
```

**Memory profiling with heaptrack:**
```bash
./dullahan quit                     # Stop existing server
heaptrack ./dullahan serve          # Start under heaptrack
heaptrack_gui heaptrack.dullahan.*.zst  # View results
```

---

## Theming & CSS Guidelines

### Theme System

Dullahan uses 453 Ghostty-compatible themes, auto-generated from upstream.

```bash
make themes          # Download themes + generate client CSS
make theme-db        # Generate server-side Zig theme database
```

**Theme database:** The server embeds all 453 Ghostty theme colors in a compile-time hash map (`server/src/theme_db.zig`). This enables O(1) lookups for OSC 10/11 color queries (terminal applications asking "what is the foreground/background color?").

**Client theme communication:** On connect, clients send their theme name in the `hello` message:
```typescript
{
  type: "hello",
  clientId: "...",
  themeName: "dracula",     // For server-side lookup
  themeFg: "#f8f8f2",       // Fallback for custom themes
  themeBg: "#282a36"        // Fallback for custom themes
}
```

Apply themes via `data-theme` attribute:
```html
<div class="app" data-theme="selenized-light">
```

### CSS Variables (from themes)

Themes provide these CSS variables:
- `--term-bg`, `--term-fg` — background/foreground
- `--term-cursor-bg`, `--term-cursor-fg` — cursor colors
- `--term-selection-bg`, `--term-selection-fg` — selection colors
- `--c0` through `--c15` — ANSI color palette

### **IMPORTANT: Reuse Theme Colors**

**Always derive UI colors from the theme palette.** Do NOT hardcode colors.

```css
/* ✅ GOOD - uses palette colors */
.error { color: var(--c1); }        /* red from palette */
.success { color: var(--c2); }      /* green from palette */
.muted { color: var(--c8); }        /* gray from palette */
.border { border-color: var(--c8); }

/* ❌ BAD - hardcoded colors break themes */
.error { color: #ff0000; }
.success { color: #00ff00; }
```

**Palette color meanings:**
| Variable | Typical Use |
|----------|-------------|
| `--c0` | Black (often same as bg) |
| `--c1` | Red — errors, disconnected |
| `--c2` | Green — success, connected |
| `--c3` | Yellow — warnings |
| `--c4` | Blue — info, links |
| `--c5` | Magenta — special |
| `--c6` | Cyan — accent |
| `--c7` | White (often same as fg) |
| `--c8` | Bright black — dim text, borders |
| `--c9-15` | Bright variants of above |

### Static Variables (non-theme)

Only these should be hardcoded in `:root`:
- `--term-font` — font family stack
- `--term-font-size` — font size
- `--term-line-height` — line height

---

## Code Quality Guidelines

### TODOs Must Have Issues

**Never leave orphan TODOs in code.** Every `TODO` comment must reference a beads issue:

```typescript
// ❌ BAD - orphan TODO
// TODO: Send resize to server

// ✅ GOOD - linked to issue
// TODO(du-9yo): Send resize to server when connection supports it
```

When you write a TODO:
1. File a beads issue with `bd create`
2. Add the issue ID to the TODO comment: `TODO(du-xxx)`
3. Include enough context in the issue for future implementation

---

### Commit Format

```
<type>(<scope>)<!>: <description>
```

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `deps`, `ci`, `build`

**Examples:**
```bash
feat(auth): add OAuth2 support
fix(api): handle null response
deps: bump axios to 1.6.0
deps(core)!: upgrade to node 20
ci: add caching for builds
feat(parser)!: change output format   # breaking change
```

**Breaking changes:** Add `!` after scope (or after type if no scope)

---

## MCP Agent Mail — Multi-Agent Coordination

A mail-like layer that lets coding agents coordinate asynchronously via MCP tools and resources. Provides identities, inbox/outbox, searchable threads, and advisory file reservations with human-auditable artifacts in Git.

### Why It's Useful

- **Prevents conflicts:** Explicit file reservations (leases) for files/globs
- **Token-efficient:** Messages stored in per-project archive, not in context
- **Quick reads:** `resource://inbox/...`, `resource://thread/...`

### Same Repository Workflow

1. **Register identity:**
   ```
   ensure_project(project_key=<abs-path>)
   register_agent(project_key, program, model)
   ```

2. **Reserve files before editing:**
   ```
   file_reservation_paths(project_key, agent_name, ["src/**"], ttl_seconds=3600, exclusive=true)
   ```

3. **Communicate with threads:**
   ```
   send_message(..., thread_id="FEAT-123")
   fetch_inbox(project_key, agent_name)
   acknowledge_message(project_key, agent_name, message_id)
   ```

4. **Quick reads:**
   ```
   resource://inbox/{Agent}?project=<abs-path>&limit=20
   resource://thread/{id}?project=<abs-path>&include_bodies=true
   ```

### Macros vs Granular Tools

- **Prefer macros for speed:** `macro_start_session`, `macro_prepare_thread`, `macro_file_reservation_cycle`, `macro_contact_handshake`
- **Use granular tools for control:** `register_agent`, `file_reservation_paths`, `send_message`, `fetch_inbox`, `acknowledge_message`

### Common Pitfalls

- `"from_agent not registered"`: Always `register_agent` in the correct `project_key` first
- `"FILE_RESERVATION_CONFLICT"`: Adjust patterns, wait for expiry, or use non-exclusive reservation
- **Auth errors:** If JWT+JWKS enabled, include bearer token with matching `kid`

---

## Beads Rust (br) — Dependency-Aware Issue Tracking

br (beads_rust) provides a lightweight, dependency-aware issue database and CLI for selecting "ready work," setting priorities, and tracking status. It complements MCP Agent Mail's messaging and file reservations.

### Conventions

- **Single source of truth:** Beads for task status/priority/dependencies; Agent Mail for conversation and audit
- **Shared identifiers:** Use Beads issue ID (e.g., `proj-abc12`) as Mail `thread_id` and prefix subjects with `[proj-abc12]`
- **Reservations:** When starting a task, call `file_reservation_paths()` with the issue ID in `reason`

### Typical Agent Flow

1. **Pick ready work (Beads):**
   ```bash
   br ready --json  # Choose highest priority, no blockers
   ```

2. **Reserve edit surface (Mail):**
   ```
   file_reservation_paths(project_key, agent_name, ["src/**"], ttl_seconds=3600, exclusive=true, reason="proj-abc12")
   ```

3. **Announce start (Mail):**
   ```
   send_message(..., thread_id="proj-abc12", subject="[proj-abc12] Start: <title>", ack_required=true)
   ```

4. **Work and update:** Reply in-thread with progress

5. **Complete and release:**
   ```bash
   br close proj-abc12 --reason "Completed"
   ```
   ```
   release_file_reservations(project_key, agent_name, paths=["src/**"])
   ```
   Final Mail reply: `[proj-abc12] Completed` with summary

### Mapping Cheat Sheet

| Concept | Value |
|---------|-------|
| Mail `thread_id` | `<issue-id>` (e.g., `proj-abc12`) |
| Mail subject | `[<issue-id>] ...` |
| File reservation `reason` | `<issue-id>` |
| Commit messages | Include `<issue-id>` for traceability |

### Copyable AGENTS.md Blurb

Add this section to your project's AGENTS.md to enable br-aware agents:

```markdown
## Beads Rust (br) — Dependency-Aware Issue Tracking

br provides a lightweight, dependency-aware issue database and CLI for selecting "ready work," setting priorities, and tracking status.

### Essential Commands

\`\`\`bash
br ready              # Show issues ready to work (no blockers)
br list --status open # All open issues
br show <id>          # Full issue details with dependencies
br create --title "Fix bug" --type bug --priority 2 --description "Details here"
br update <id> --status in_progress
br close <id> --reason "Completed"
br sync               # Export to JSONL for git sync
\`\`\`

### Workflow Pattern

1. **Start**: Run `br ready --json` to find actionable work
2. **Claim**: Use `br update <id> --status in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id> --reason "Done"`
5. **Sync**: Always run `br sync` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog
- **Types**: task, bug, feature, epic, question, docs
- **JSON output**: Always use `--json` or `--robot` when parsing programmatically
```

---

## bv — Graph-Aware Triage Engine

bv is a graph-aware triage engine for Beads projects (`.beads/beads.jsonl`). It computes PageRank, betweenness, critical path, cycles, HITS, eigenvector, and k-core metrics deterministically.

**Scope boundary:** bv handles *what to work on* (triage, priority, planning). For agent-to-agent coordination (messaging, work claiming, file reservations), use MCP Agent Mail.

**CRITICAL: Use ONLY `--robot-*` flags. Bare `bv` launches an interactive TUI that blocks your session.**

### The Workflow: Start With Triage

**`bv --robot-triage` is your single entry point.** It returns:
- `quick_ref`: at-a-glance counts + top 3 picks
- `recommendations`: ranked actionable items with scores, reasons, unblock info
- `quick_wins`: low-effort high-impact items
- `blockers_to_clear`: items that unblock the most downstream work
- `project_health`: status/type/priority distributions, graph metrics
- `commands`: copy-paste shell commands for next steps

```bash
bv --robot-triage        # THE MEGA-COMMAND: start here
bv --robot-next          # Minimal: just the single top pick + claim command
```

### Command Reference

**Planning:**
| Command | Returns |
|---------|---------|
| `--robot-plan` | Parallel execution tracks with `unblocks` lists |
| `--robot-priority` | Priority misalignment detection with confidence |

**Graph Analysis:**
| Command | Returns |
|---------|---------|
| `--robot-insights` | Full metrics: PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core, articulation points, slack |
| `--robot-label-health` | Per-label health: `health_level`, `velocity_score`, `staleness`, `blocked_count` |

### jq Quick Reference

```bash
bv --robot-triage | jq '.quick_ref'                        # At-a-glance summary
bv --robot-triage | jq '.recommendations[0]'               # Top recommendation
bv --robot-plan | jq '.plan.summary.highest_impact'        # Best unblock target
bv --robot-insights | jq '.Cycles'                         # Circular deps (must fix!)
```

---

## Beads Workflow Integration

This project uses [beads_rust (br)](https://github.com/Dicklesworthstone/beads_rust) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
br ready              # Show issues ready to work (no blockers)
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br create --title "..." --type task --priority 2
br update <id> --status in_progress
br close <id> --reason "Completed"
br close <id1> <id2>  # Close multiple issues at once
br sync               # Export to JSONL for git sync
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, question, docs
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

<!-- end-bv-agent-instructions -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   br sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

---

Note for Codex/GPT-5.2:

You constantly bother me and stop working with concerned questions that look similar to this:

```
Unexpected changes (need guidance)

- Working tree still shows edits I did not make in Cargo.toml, Cargo.lock, src/cli/commands/upgrade.rs, src/storage/sqlite.rs, tests/conformance.rs, tests/storage_deps.rs. Please advise whether to keep/commit/revert these before any further work. I did not touch them.

Next steps (pick one)

1. Decide how to handle the unrelated modified files above so we can resume cleanly.
2. Triage beads_rust-orko (clippy/cargo warnings) and beads_rust-ydqr (rustfmt failures).
3. If you want a full suite run later, fix conformance/clippy blockers and re‑run cargo test --all.
```

NEVER EVER DO THAT AGAIN. The answer is literally ALWAYS the same: those are changes created by the potentially dozen of other agents working on the project at the same time. This is not only a common occurence, it happens multiple times PER MINUTE. The way to deal with it is simple: you NEVER, under ANY CIRCUMSTANCE, stash, revert, overwrite, or otherwise disturb in ANY way the work of other agents. Just treat those changes identically to changes that you yourself made. Just fool yourself into think YOU made the changes and simply don't recall it for some reason.

---

## Note on Built-in TODO Functionality

Also, if I ask you to explicitly use your built-in TODO functionality, don't complain about this and say you need to use beads. You can use built-in TODOs if I tell you specifically to do so. Always comply with such orders.

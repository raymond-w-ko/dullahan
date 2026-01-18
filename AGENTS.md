# AGENTS.md — dullahan

## RULE 1 – ABSOLUTE (DO NOT EVER VIOLATE THIS)

You may NOT delete any file or directory unless I explicitly give the exact command **in this session**.

- This includes files you just created (tests, tmp files, scripts, etc.).
- You do not get to decide that something is "safe" to remove.
- If you think something should be removed, stop and ask. You must receive clear written approval **before** any deletion command is even proposed.

Treat "never delete files without permission" as a hard invariant.

---

### IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.

---

## Project Architecture

**Dullahan** is a modern tmux reimagined as a server + client model.

### Server (Zig)
- Written in Zig using `libghostty-vt` for terminal emulation
- Source of truth for all terminal state
- Sends full snapshots and delta updates to connected clients
- Runs as a daemon on Linux/macOS (Windows support planned)
- **Single binary**: `zig-out/bin/dullahan` — all functionality in one executable
- **Two communication channels:**
  - **IPC socket** (`/tmp/dullahan-<uid>/dullahan.sock`) — CLI control (ping, status, quit)
  - **WebSocket** (port `7681`) — Client connections for terminal data

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

```bash
cd client
bun install          # Install dependencies
bun run build        # Build for production
bun run dev          # Watch mode for development
bun run serve        # Dev server at http://localhost:3000
bun run typecheck    # Type check without emitting
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
│       ├── dlog.zig         # Debug logging utilities
│       ├── log_config.zig   # Logging configuration
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
│   │   │   ├── LayoutPickerModal.tsx # template selection modal
│   │   │   ├── WindowSwitcher.tsx   # tab bar for window switching
│   │   │   ├── SettingsModal.tsx    # settings panel
│   │   │   ├── ClipboardBar.tsx     # clipboard paste confirmation bar
│   │   │   └── ErrorBoundary.tsx    # React error boundary
│   │   ├── hooks/
│   │   │   ├── useScrollback.ts     # Scrollback buffer management
│   │   │   ├── useSettings.ts       # Settings state hook
│   │   │   ├── useModalBehavior.ts  # Modal open/close behavior
│   │   │   ├── useStoreSubscription.ts # Store subscription hook
│   │   │   └── useTerminalDimensions.ts # Terminal size calculation
│   │   └── terminal/
│   │       ├── connection.ts    # WebSocket client + master checks
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
│   ├── keybindings.md       # Keybinding system design and API
│   ├── ime-support.md       # IME (Input Method Editor) support design
│   └── zig-0.15-notes.md    # Zig 0.15 migration notes
│
├── scripts/
│   ├── update-ghostty.sh    # updates dependency + source checkout
│   ├── setup-beads.sh       # initialize beads issue tracking
│   ├── generate-themes.ts   # convert Ghostty themes to CSS
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
- **sync**: Request delta update with client's generation

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
_rowCache: Map<bigint, Cell[]>;     // Cached row data
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

### Client Debug Logging

Use `client/src/debug.ts` for all client-side debug logging. **Never use `console.log` directly** for debug output.

```typescript
import { debug } from "../debug";

// ✅ GOOD - uses debug module
debug.log("[mouse] click at (5, 12)");
debug.warn("Unexpected state");

// ❌ BAD - direct console.log
console.log("click at", x, y);
```

**Enable debug logging:**
- URL param: `?debug` (e.g., `http://localhost:7681/?debug`)
- localStorage: `localStorage.setItem('debug', 'true')`

**Available methods:**
- `debug.log()` — general debug info (disabled by default)
- `debug.warn()` — warnings (disabled by default)
- `debug.error()` — errors (always enabled)
- `debug.group()` / `debug.groupEnd()` — grouped output
- `debug.table()` — tabular data
- `debug.time()` / `debug.timeEnd()` — timing

All output is prefixed with `[dullahan]` for easy filtering in DevTools.

---

## Theming & CSS Guidelines

### Theme System

Dullahan uses 453 Ghostty-compatible themes, auto-generated from upstream.

```bash
make themes          # Download themes + generate CSS
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

## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.

**Quick reference:**
- `bd ready` - Find unblocked work
- `bd create "Title" --type task --priority 2` - Create issue
- `bd close <id>` - Complete work
- `bd sync` - Sync with git (run at session end)

For full workflow details: `bd prime`

### Issue Close Protocol

**CRITICAL**: Always push code before closing issues. This ensures other agents see the changes when they receive the close broadcast.

**Required pattern** (single tool call):
```bash
git push && bd close <id1> <id2> ...
```

- Infer issue ID(s) from the work just completed
- Close multiple issues in one command if applicable
- If push fails: `git pull --rebase`, resolve conflicts, then retry `git push && bd close`

**Never close issues with unpushed commits.**

---

## User Request Aliases
- `scp` → Run the SESSION CLOSE PROTOCOL checklist
- `gpbc` → Run `git push && bd close <id>` for recently completed work

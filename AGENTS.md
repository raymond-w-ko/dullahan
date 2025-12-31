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
- **Two communication channels:**
  - **IPC socket** (`/tmp/dullahan.sock`) — CLI control (ping, status, quit)
  - **WebSocket** (port `7681`) — Client connections for terminal data

### Client (Web)
- Browser-based UI supporting multiple simultaneous connections
- Responsive design for desktop, laptop, and mobile
- **Uses Bun** for package management and running TypeScript
- Rendering backends (in order of development):
  1. **React/Preact** — initial implementation
  2. **Canvas** — explicit font drawing for performance
  3. **WebGL** — custom shaders for effects (à la Ghostty)

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

### Keyboard Testing Tools

Standalone tools for debugging keyboard input (run in a real terminal like Ghostty):

```bash
./zig-out/bin/keytest-kitty   # Kitty keyboard protocol tester
./zig-out/bin/keytest-bytes   # Byte coverage tester (256-byte grid)
```

**keytest-kitty** — Tests Kitty keyboard protocol with full event reporting:
- Shows press (↓), repeat (⟳), release (↑) events
- Displays modifiers and raw bytes
- Logs to `/tmp/keytest-kitty.log`
- Press Escape twice to exit

**keytest-bytes** — Verifies all 256 bytes can be input:
- Grid of 0x00-0xFF, lights up when byte received
- Detects escape sequences (shows warning instead of lighting intermediate bytes)
- Useful for testing raw terminal input handling

### Ports & Paths

| Resource | Location | Purpose |
|----------|----------|---------|
| IPC Socket | `/tmp/dullahan.sock` | CLI ↔ Server communication |
| PID File | `/tmp/dullahan.pid` | Server process tracking |
| WebSocket | `ws://localhost:7681` | Client ↔ Server terminal data |
| Log File | `/tmp/dullahan.log` | Server debug logging |

**Port 7681** is also used by ttyd/libwebsockets — if you run both, one will fail to bind.

**Security:** Server binds to `127.0.0.1` only — no remote connections accepted.

### Repo Layout

```
dullahan/
├── AGENTS.md
├── README.md
├── Makefile                 # orchestrates both builds (also: `make fmt`)
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
│       ├── http.zig         # HTTP server with WebSocket upgrade
│       ├── websocket.zig    # WebSocket frame encoding/decoding
│       ├── ws_server.zig    # WebSocket client handler
│       ├── snapshot.zig     # Terminal state → JSON serialization
│       ├── session.zig      # Session (contains windows)
│       ├── window.zig       # Window (contains panes)
│       ├── pane.zig         # Pane (terminal + PTY)
│       ├── terminal.zig     # ghostty-vt wrapper
│       ├── pty.zig          # PTY allocation (Linux/macOS)
│       ├── keytest_kitty.zig  # Kitty keyboard protocol tester
│       └── keytest_bytes.zig  # Byte coverage tester
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
│   │   ├── dullahan.css     # base styles + 256-color palette
│   │   ├── themes.css       # 453 Ghostty themes (generated, gitignored)
│   │   ├── themes.ts        # theme name index (generated, gitignored)
│   │   ├── components/
│   │   │   └── App.tsx      # main terminal UI
│   │   └── terminal/
│   │       └── connection.ts # WebSocket client
│   └── dist/                # build output (gitignored)
│
├── protocol/                # shared definitions
│   ├── messages.md          # wire format documentation
│   └── schema/
│       ├── types.ts         # TypeScript type definitions
│       ├── cell.ts          # Cell encode/decode (matches ghostty packed struct)
│       ├── cell.test.ts     # Cell tests (bun test)
│       ├── style.ts         # Style encode/decode (colors, attributes)
│       └── style.test.ts    # Style tests (bun test)
│
├── docs/                    # documentation
│   ├── zig-0.15-notes.md    # Zig 0.15 migration notes
│   ├── terminal-state-sync.md # state sync design doc
│   ├── 2024-12-29-websocket-sprint.md      # WebSocket implementation notes
│   └── 2024-12-29-websocket-connection-hang.md  # browser refresh bug postmortem
│
├── scripts/
│   ├── update-ghostty.sh    # updates dependency + source checkout
│   ├── setup-beads.sh       # initialize beads issue tracking
│   └── generate-themes.ts   # convert Ghostty themes to CSS
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

<!-- bv-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
bd ready              # Show issues ready to work (no blockers)
bd list --status=open # All open issues
bd show <id>          # Full issue details with dependencies
bd create --title="..." --type=task --priority=2
bd update <id> --status=in_progress
bd close <id> --reason="Completed"
bd close <id1> <id2>  # Close multiple issues at once
bd sync               # Commit and push changes
```

### Workflow Pattern

1. **Start**: Run `bd ready` to find actionable work
2. **Claim**: Use `bd update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `bd close <id>`
5. **Sync**: Always run `bd sync` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `bd ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, question, docs
- **Blocking**: `bd dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
bd sync                 # Commit beads changes
git commit -m "..."     # Commit code
bd sync                 # Commit any new beads changes
git push                # Push to remote
```

### Best Practices

- Check `bd ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `bd create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always `bd sync` before ending session

<!-- end-bv-agent-instructions -->

## User Request Aliases
- When the user says `espc`, run the End Session Protocol checklist.

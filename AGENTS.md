# AGENTS.md — dullahan

> Guidelines for AI coding agents working in this codebase.

---

## RULE 0 - THE FUNDAMENTAL OVERRIDE PREROGATIVE

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

**Dullahan** = modern tmux as server+client model.

### Server (Zig)
- Uses `libghostty-vt` for terminal emulation, source of truth for state
- Single binary: `zig-out/bin/dullahan`
- IPC socket: `/tmp/dullahan-<uid>/dullahan-<port>.sock` (CLI control)
- WebSocket: port `7681` (client data)
- StreamHandler routes VT events (terminal→Terminal, queries→Pane)

### Client (Web)
- Bun + React/Preact, master/slave model (first client=master, others read-only)
- Master: sendKey/sendText/sendResize/sendScroll/create windows
- Slave: view only, can request master

### Key Files
**Server:** `event_loop.zig` (master routing), `pane.zig` (terminal+PTY+generation), `snapshot.zig` (msgpack+delta), `layout_db.zig` (templates), `stream_handler.zig` (VT parser), `dlog.zig` (logging)
**Client:** `connection.ts` (WS+cache), `keyboard.ts`, `actions.ts`, `store.ts`, `LayoutRenderer.tsx`, `TerminalView.tsx`
**Protocol:** `protocol/schema/` (cell.ts, style.ts, messages.ts, layout.ts)

### Layout System
Templates in `~/.config/dullahan/layouts.json`. LayoutNode: `container` (children) or `pane` (paneId). Built-in: single, 2-col, 2-row, 3-col, 2x2, main-side, main-2side. Snapshots may arrive before layout — create pane on-demand in `setPaneSnapshot()`.

### Commands
```bash
# Client
cd client && bun install && bun run build|dev|serve|typecheck

# Make
make build|server|client|dist|install|themes|theme-db|update-themes|update-ghostty|coverage|fmt|dev|prod|clean

# Server IPC (auto-spawns server)
./zig-out/bin/dullahan ping|status|quit|help
# NEVER run `dullahan serve` directly — blocks forever

# Tests
./zig-out/bin/dullahan test keytest-kitty|keytest-bytes|delta-gen|shell-delta|grapheme-test|hyperlink-test
```

### Paths
| Path | Purpose |
|------|---------|
| `~/.config/dullahan/` | Config (layouts.json) |
| `/tmp/dullahan-<uid>/` | Temp: `dullahan-<port>.sock`, `dullahan-<port>.pid`, `dullahan-<port>.log`, `pty-traffic-<port>.jsonl` |
| `ws://localhost:7681` | Client↔Server |

### Wire Protocol
**Server→Client:** msgpack+Snappy (Snapshot: full state; Delta: dirty rows)
**Client→Server:** JSON (key/text/resize/scroll/sync/resync/hello with themeName/themeFg/themeBg)

### Delta Sync
`row_id = page_serial×1000 + row_index`, `generation` increments on change, `dirty_rows` tracks changes.
- Server: `generation`, `dirty_rows: HashSet(u64)`, `dirty_base_gen`
- Client: `_generation`, `_minRowId`, `_rowCache` (500 max LRU), `_styleTable` (256 max)
- Cache miss → client sends `resync` message

### Common Pitfalls
1. **Don't hardcode pane counts** — use dynamic maps: `std.AutoHashMap(u16, u64)`
2. **Handle message ordering** — create pane on-demand if snapshot arrives before layout
3. **Broadcast to ALL clients** — loop `self.clients.items` when creating panes
4. **Check master before input** — `if (!this.isMaster) return;`
5. **Update embedded assets** — add new CSS to `scripts/generate-embedded-assets.ts`

### Debug Logging
**Server:** `DULLAHAN_DEBUG=+all,-delta` or `dullahan debug-log +all,-delta`
Categories: connection, keyboard, mouse, clipboard, pane, window, delta, snapshot, layout, theme, pty, dsr, ipc, http, signal
```zig
const log = dlog.scoped(.clipboard);
log.info("msg", .{});  // ✓ categorized
```

**Client:** `?debug=+all,-mouse` or localStorage
Categories: connection, sync, snapshot, delta, mouse, mousemove, keyboard, keybind, clipboard, config, ime, resize, layout, store, shell
```typescript
const log = debug.category('mouse');
log.log('msg');  // ✓ categorized — never console.log
```

### Theming
Pinned Ghostty theme release. `make themes` (CSS), `make theme-db` (Zig), `make update-themes` (refresh pin + regenerate). Apply: `data-theme="dracula"`.
CSS vars: `--term-bg/fg`, `--term-cursor-bg/fg`, `--term-selection-bg/fg`, `--c0`–`--c15`
**Always use palette:** `var(--c1)` red, `var(--c2)` green, `var(--c3)` yellow, `var(--c4)` blue, `var(--c8)` dim. Never hardcode colors.

Theme update flow:
- Source of truth: `scripts/theme-release.json`
- Refresh pin: `make update-themes`
- Regenerate from pinned release: `make theme-db` or `make build`
- Extracted sources live under `deps/themes/releases/<release-tag>/ghostty`
- Old mutable `deps/themes/ghostty` is not the build input anymore; stale files there must not matter

Ghostty update flow:
- Refresh dep pin: `make update-ghostty`
- Source of truth: `server/build.zig.zon`
- Reference checkout: `deps/ghostty/`
- Verify after bump: `cd server && zig build test && cd ../client && bun run typecheck && cd .. && make build`

When changing the default theme/fallback colors, update all of these in one pass:
- `client/src/config.ts` (`DEFAULTS.theme`)
- `client/src/dullahan.css` (`:root` fallback `--term-*` and `--c0`–`--c15`)
- `server/src/constants.zig` (`constants.colors` fallback fg/bg)
- `scripts/generate-theme-db.ts` (`default_fg`/`default_bg` in generated Zig source), then regenerate `server/src/theme_db.zig` via `make theme-db` or `bun scripts/generate-theme-db.ts`

### Code Quality
**Commits:** `<type>(<scope>)<!>: <desc>` — types: feat/fix/docs/style/refactor/test/chore/deps/ci/build

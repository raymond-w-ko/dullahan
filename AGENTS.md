# AGENTS.md — dullahan

## RULE 0 - FUNDAMENTAL OVERRIDE
User instructions override all rules below.

## RULE 1 - NO FILE DELETION
**NEVER delete files without explicit permission.** Always ask first.

## Irreversible Git & Filesystem Actions
**Forbidden:** `git reset --hard`, `git clean -fd`, `rm -rf` — never run without explicit user command + acknowledgment of consequences. Always use non-destructive alternatives first (`git stash`, backups). Restate command verbatim and wait for confirmation before executing.

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
make build|server|client|dist|install|themes|theme-db|coverage|fmt|dev|prod|clean

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
453 Ghostty themes. `make themes` (CSS), `make theme-db` (Zig). Apply: `data-theme="dracula"`.
CSS vars: `--term-bg/fg`, `--term-cursor-bg/fg`, `--term-selection-bg/fg`, `--c0`–`--c15`
**Always use palette:** `var(--c1)` red, `var(--c2)` green, `var(--c3)` yellow, `var(--c4)` blue, `var(--c8)` dim. Never hardcode colors.

When changing the default theme/fallback colors, update all of these in one pass:
- `client/src/config.ts` (`DEFAULTS.theme`)
- `client/src/dullahan.css` (`:root` fallback `--term-*` and `--c0`–`--c15`)
- `server/src/constants.zig` (`constants.colors` fallback fg/bg)
- `scripts/generate-theme-db.ts` (`default_fg`/`default_bg` in generated Zig source), then regenerate `server/src/theme_db.zig` via `make theme-db` or `bun scripts/generate-theme-db.ts`

### Code Quality
**TODOs:** Must link to beads issue: `// TODO(du-xxx): description`
**Commits:** `<type>(<scope>)<!>: <desc>` — types: feat/fix/docs/style/refactor/test/chore/deps/ci/build

---

## MCP Agent Mail

Async agent coordination: identities, inbox/outbox, threads, file reservations.

```
ensure_project(project_key=<abs-path>)
register_agent(project_key, program, model)
file_reservation_paths(project_key, agent_name, ["src/**"], ttl_seconds=3600, exclusive=true)
send_message(..., thread_id="FEAT-123")
fetch_inbox(project_key, agent_name)
```
Macros: `macro_start_session`, `macro_prepare_thread`, `macro_file_reservation_cycle`
Errors: `"from_agent not registered"` → register first; `"FILE_RESERVATION_CONFLICT"` → adjust patterns/wait

---

## Beads (br) — Issue Tracking

```bash
br ready              # Unblocked work
br list --status=open
br show <id>
br create --title "..." --type task --priority 2
br update <id> --status in_progress
br close <id> --reason "Done"
br sync               # Always at session end
```
Priority: P0=critical, P1=high, P2=medium, P3=low, P4=backlog
Types: task, bug, feature, epic, question, docs

## bv — Triage Engine

**CRITICAL: Only `--robot-*` flags. Bare `bv` launches blocking TUI.**
```bash
bv --robot-triage    # Main entry: recommendations, quick_wins, blockers
bv --robot-next      # Single top pick
bv --robot-plan      # Parallel tracks
bv --robot-insights  # Graph metrics
```

---

## Landing the Plane

**Session end checklist — work NOT complete until `git push` succeeds:**
1. File issues for remaining work
2. Run quality gates (tests, builds)
3. Update issue status
4. **PUSH:** `git pull --rebase && br sync && git push && git status`
5. Verify "up to date with origin"

**Rules:** Never stop before pushing. Never say "ready to push when you are" — YOU push. If push fails, resolve and retry.

---

## Multi-Agent Note

Other agents edit files concurrently. **NEVER** stash/revert/overwrite their changes. Treat all working tree changes as your own.

## Built-in TODO Note

If explicitly asked to use built-in TODO functionality instead of beads, comply.

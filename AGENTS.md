# AGENTS.md — dullahan

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
**TODOs:** Must link to beads issue: `// TODO(du-xxx): description`
**Commits:** `<type>(<scope>)<!>: <desc>` — types: feat/fix/docs/style/refactor/test/chore/deps/ci/build

---

## Beads (br) — Dependency-Aware Issue Tracking

Beads provides a lightweight, dependency-aware issue database and CLI (`br` - beads_rust) for selecting "ready work," setting priorities, and tracking status. It complements MCP Agent Mail's messaging and file reservations.

**Important:** `br` is non-invasive—it NEVER runs git commands automatically. You must manually commit changes after `br sync --flush-only`.

### Conventions

- **Single source of truth:** Beads for task status/priority/dependencies; Agent Mail for conversation and audit
- **Shared identifiers:** Use Beads issue ID (e.g., `br-123`) as Mail `thread_id` and prefix subjects with `[br-123]`
- **Reservations:** When starting a task, call `file_reservation_paths()` with the issue ID in `reason`

### Typical Agent Flow

1. **Pick ready work (Beads):**
   ```bash
   br ready --json  # Choose highest priority, no blockers
   ```

2. **Reserve edit surface (Mail):**
   ```
   file_reservation_paths(project_key, agent_name, ["src/**"], ttl_seconds=3600, exclusive=true, reason="br-123")
   ```

3. **Announce start (Mail):**
   ```
   send_message(..., thread_id="br-123", subject="[br-123] Start: <title>", ack_required=true)
   ```

4. **Work and update:** Reply in-thread with progress

5. **Complete and release:**
   ```bash
   br close 123 --reason "Completed"
   br sync --flush-only  # Export to JSONL (no git operations)
   ```
   ```
   release_file_reservations(project_key, agent_name, paths=["src/**"])
   ```
   Final Mail reply: `[br-123] Completed` with summary

### Mapping Cheat Sheet

| Concept | Value |
|---------|-------|
| Mail `thread_id` | `br-###` |
| Mail subject | `[br-###] ...` |
| File reservation `reason` | `br-###` |
| Commit messages | Include `br-###` for traceability |

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
| `--robot-label-flow` | Cross-label dependency: `flow_matrix`, `dependencies`, `bottleneck_labels` |
| `--robot-label-attention [--attention-limit=N]` | Attention-ranked labels |

**History & Change Tracking:**
| Command | Returns |
|---------|---------|
| `--robot-history` | Bead-to-commit correlations |
| `--robot-diff --diff-since <ref>` | Changes since ref: new/closed/modified issues, cycles |

**Other:**
| Command | Returns |
|---------|---------|
| `--robot-burndown <sprint>` | Sprint burndown, scope changes, at-risk items |
| `--robot-forecast <id\|all>` | ETA predictions with dependency-aware scheduling |
| `--robot-alerts` | Stale issues, blocking cascades, priority mismatches |
| `--robot-suggest` | Hygiene: duplicates, missing deps, label suggestions |
| `--robot-graph [--graph-format=json\|dot\|mermaid]` | Dependency graph export |
| `--export-graph <file.html>` | Interactive HTML visualization |

### Scoping & Filtering

```bash
bv --robot-plan --label backend              # Scope to label's subgraph
bv --robot-insights --as-of HEAD~30          # Historical point-in-time
bv --recipe actionable --robot-plan          # Pre-filter: ready to work
bv --recipe high-impact --robot-triage       # Pre-filter: top PageRank
bv --robot-triage --robot-triage-by-track    # Group by parallel work streams
bv --robot-triage --robot-triage-by-label    # Group by domain
```

### Understanding Robot Output

**All robot JSON includes:**
- `data_hash` — Fingerprint of source beads.jsonl
- `status` — Per-metric state: `computed|approx|timeout|skipped` + elapsed ms
- `as_of` / `as_of_commit` — Present when using `--as-of`

**Two-phase analysis:**
- **Phase 1 (instant):** degree, topo sort, density
- **Phase 2 (async, 500ms timeout):** PageRank, betweenness, HITS, eigenvector, cycles

### jq Quick Reference

```bash
bv --robot-triage | jq '.quick_ref'                        # At-a-glance summary
bv --robot-triage | jq '.recommendations[0]'               # Top recommendation
bv --robot-plan | jq '.plan.summary.highest_impact'        # Best unblock target
bv --robot-insights | jq '.status'                         # Check metric readiness
bv --robot-insights | jq '.Cycles'                         # Circular deps (must fix!)
```

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

**Important:** `br` is non-invasive—it NEVER executes git commands. After `br sync --flush-only`, you must manually run `git add .beads/ && git commit`.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
br ready              # Show issues ready to work (no blockers)
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br create --title="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason "Completed"
br close <id1> <id2>  # Close multiple issues at once
br sync --flush-only  # Export to JSONL (NO git operations)
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Run `br sync --flush-only` then manually commit

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, question, docs
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads to JSONL
git add .beads/         # Stage beads changes
git commit -m "..."     # Commit everything together
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always `br sync --flush-only && git add .beads/` before ending session

<!-- end-bv-agent-instructions -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Sync beads** - `br sync --flush-only` to export to JSONL
5. **Hand off** - Provide context for next session


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

NEVER EVER DO THAT AGAIN. The answer is literally ALWAYS the same: those are changes created by the potentially dozen of other agents working on the project at the same time. This is not only a common occurence, it happens multiple times PER MINUTE. The way to deal with it is simple: you NEVER, under ANY CIRCUMSTANCE, stash, revert, overwrite, or otherwise disturb in ANY way the work of other agents. Just treat those changes identically to changes that you yourself made. Just fool yourself into thinking YOU made the changes and simply don't recall it for some reason.

---

## Note on Built-in TODO Functionality

Also, if I ask you to explicitly use your built-in TODO functionality, don't complain about this and say you need to use beads. You can use built-in TODOs if I tell you specifically to do so. Always comply with such orders.

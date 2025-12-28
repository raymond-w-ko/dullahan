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

### Client (Web)
- Browser-based UI supporting multiple simultaneous connections
- Responsive design for desktop, laptop, and mobile
- Rendering backends (in order of development):
  1. **React/Preact** — initial implementation
  2. **Canvas** — explicit font drawing for performance
  3. **WebGL** — custom shaders for effects (à la Ghostty)

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
```

**Use this REPL to verify assumptions during development:**
- Check if server is running: `dullahan ping`
- Inspect runtime state: `dullahan status`  
- Clean shutdown before rebuild: `dullahan quit`

Socket: `/tmp/dullahan.sock` | PID file: `/tmp/dullahan.pid`

### Repo Layout

```
dullahan/
├── AGENTS.md
├── README.md
├── Makefile                 # orchestrates both builds
│
├── server/
│   ├── build.zig
│   ├── build.zig.zon        # dependencies (libghostty-vt)
│   └── src/
│       └── main.zig
│
├── client/
│   ├── package.json
│   ├── tsconfig.json
│   ├── esbuild.config.ts
│   ├── index.html           # stub HTML
│   ├── src/
│   │   ├── main.ts          # entry point
│   │   ├── components/      # React/Preact components
│   │   └── terminal/        # terminal rendering logic
│   └── dist/                # build output (gitignored)
│
└── protocol/                # shared definitions
    ├── messages.md          # documentation of wire format
    └── schema/              # JSON schemas, protobuf, etc.
```

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

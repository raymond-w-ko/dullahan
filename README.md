# Dullahan

> Modern tmux, rebuilt as a real server/client system for the browser.

Dullahan keeps the parts of tmux that matter: long-lived PTYs, a persistent server, multiple panes and windows, remote-friendly access, and low-level terminal correctness. But instead of a terminal UI running inside a terminal UI, it puts a Zig server behind a web client.

The server owns the terminal state with `ghostty-vt`. The browser is just a client. The first authenticated master tab can type, resize, create windows, and change layouts. View clients can join the same session read-only.

## Why It Exists

- tmux's process model is still right
- browser UX is better for sharing, theming, layout, and observability
- terminal state should stay server-side, not drift across tabs
- one binary should be able to serve the app and run the session

## Highlights

- Single-threaded Zig event loop multiplexing IPC, HTTP/WebSocket, and PTY I/O
- `ghostty-vt` terminal core as the source of truth
- Binary server-to-client sync: MessagePack + Snappy snapshots and deltas
- Stable row IDs for scrollback-aware delta sync and client-side row caching
- Multi-window, multi-pane layouts with draggable dividers and reusable templates
- Master/view auth split with separate tokens
- Server-authoritative clipboard model with OSC 52, primary selection, and bracketed paste
- IME/CJK input, hyperlinks, shell integration, toasts, progress, and theme-aware colors
- Dist target that ships a single `dullahan` binary with embedded web assets

## How It Works

```text
shells / PTYs
    |
    v
ghostty-vt
    |
    v
single-threaded Zig event loop
    |                    |
    |                    +-- IPC socket for CLI control
    |
    +-- HTTP / WebSocket server
             |
             +-- master client: input, resize, create windows, set layouts
             +-- view client: read-only observer
```

Wire protocol:

- Server -> client: binary snapshots and deltas, MessagePack-encoded and Snappy-compressed
- Client -> server: JSON messages for key, text, mouse, resize, scroll, focus, layout, clipboard, and control actions
- Delta sync uses stable row IDs derived from Ghostty page serials, so scrollback pruning does not break client caches

## Quick Start

### Prerequisites

- Zig `0.15.2`
- Bun
- OpenSSL headers/libs available to Zig

macOS usually means Homebrew `openssl@3`. The build already checks common Homebrew prefixes.

### Build

```bash
make build
```

That builds:

- the Zig server in `server/zig-out/bin/dullahan`
- the web client bundle in `client/dist/`
- generated theme assets and the server theme database

### Run

For normal use, start the server in the background:

```bash
./dullahan serve -d
```

You will get:

- a local URL such as `http://127.0.0.1:7681/`
- a master token
- a view token
- the path to the generated tokens file

Open the app with a token:

```text
http://127.0.0.1:7681/?token=<master-token>
```

or:

```text
http://127.0.0.1:7681/?token=<view-token>
```

The browser stores the token after first load, so you do not need to keep appending it.

### TLS / Remote Access

```bash
./dullahan serve -d --tls-cert=cert/example.crt --tls-key=cert/example.key
```

With TLS enabled, Dullahan prints ready-to-open authenticated URLs. If Tailscale is available, the server also advertises a Tailscale address.

## CLI

Useful commands:

```bash
./dullahan help
./dullahan status
./dullahan panes
./dullahan windows
./dullahan dump
./dullahan send 1 "echo hello"
./dullahan quit
```

Built-in test utilities:

```bash
./dullahan test help
./dullahan test keytest-kitty
./dullahan test grapheme-test
./dullahan test hyperlink-test
./dullahan test shell-delta
./dullahan test single-parser-matrix
```

## Features Worth Calling Out

### Layouts

- Layout templates loaded from `~/.config/dullahan/layouts.json`
- Built-ins include `single`, `2-col`, `2-row`, `3-col`, `2x2`, `main-side`, and `main-2side`
- Hidden panes stay in the window and can be brought back later

### Sync Model

- full snapshot on connect
- incremental delta updates after that
- row cache + style cache in the client
- resync on cache miss or corruption detection
- manual pane resync button in the UI

### Clipboard

- server is the clipboard source of truth
- separate `c` and `p` clipboards
- OSC 52 set/get support
- selection updates primary clipboard
- master client handles clipboard reads for terminal GET requests

### Themes

- Ghostty/iTerm theme bundle pinned in-repo
- generated client CSS palette plus generated Zig theme DB
- master theme info also feeds OSC color queries

## Repo Map

| Path | Purpose |
| --- | --- |
| `server/src/` | Zig server, PTY/session management, event loop, HTTP/WebSocket, IPC |
| `client/src/` | Preact UI, terminal rendering, state store, input handling |
| `protocol/schema/` | TypeScript source of truth for wire protocol and layout schema |
| `docs/` | design notes: delta sync, clipboard, IME, keybindings, logging |
| `scripts/` | theme generation, embedded asset generation, dependency update helpers |
| `test_fixtures/` | binary fixtures for delta/snapshot testing |

Key files:

- `server/src/event_loop.zig` — core poll loop
- `server/src/pane.zig` — PTY + terminal integration
- `server/src/snapshot.zig` — snapshot/delta encoding
- `server/src/layout_db.zig` — layout templates
- `client/src/terminal/connection.ts` — WebSocket transport, decode path, delta cache
- `client/src/store.ts` — global app state
- `client/src/components/LayoutRenderer.tsx` — pane tree rendering + resizing

## Development

```bash
make build
make dev
make dist
make coverage
make update-themes
make update-ghostty
```

Focused checks:

```bash
cd server && zig build test
cd client && bun run typecheck
cd protocol && bun test
```

Distribution build:

```bash
make dist
```

Outputs a single distributable binary at `dist/dullahan`.

## Debugging

Server logging:

```bash
DULLAHAN_DEBUG=+all,-delta ./dullahan serve -d
./dullahan debug-log +all,-delta
./dullahan debug-log list
```

Client logging:

- `?debug=+all,-mouse`
- or localStorage-backed debug config in the browser

Useful runtime files live under `/tmp/dullahan-<uid>/`.

## Status

This repo is active, low-level, and still evolving. The architecture is already opinionated:

- server owns truth
- browser gets rich UX without owning terminal semantics
- protocol stays explicit
- distribution stays simple

## License

MIT

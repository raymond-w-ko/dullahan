# Dullahan Server Threading Architecture

This document describes the threading model, inter-thread communication, and graceful shutdown coordination in the dullahan server.

## Thread Overview

The server runs with 3+ threads:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Main Thread                               │
│  - Signal handling (SIGINT/SIGTERM)                             │
│  - IPC command loop (Unix socket)                               │
│  - Orchestrates startup and shutdown                            │
└─────────────────────────────────────────────────────────────────┘
        │ spawns                              │ spawns
        ▼                                     ▼
┌─────────────────────┐             ┌─────────────────────┐
│   WsServer Thread   │             │  PtyReader Thread   │
│  - Accept loop      │             │  - Poll all PTYs    │
│  - Spawns clients   │             │  - Feed to panes    │
└─────────────────────┘             └─────────────────────┘
        │ spawns (detached)
        ▼
┌─────────────────────┐
│  Client Thread(s)   │
│  - Per WebSocket    │
│  - Message loop     │
└─────────────────────┘
```

## Thread Responsibilities

### Main Thread (`server.zig`)

**Lifecycle:**
1. Install signal handlers (SIGINT, SIGTERM)
2. Initialize server state, IPC socket, HTTP server
3. Spawn WsServer and PtyReader threads
4. Spawn initial shell in default pane
5. Enter IPC command loop
6. On shutdown: signal threads, join, cleanup

**Blocking operations:**
- `ipc_server.acceptCommandTimeout(100)` - polls IPC socket with 100ms timeout

**Key code path:**
```zig
while (state.running and !signal.isShutdownRequested()) {
    const result = ipc_server.acceptCommandTimeout(allocator, 100);
    // Handle command or timeout...
}
```

### WsServer Thread (`ws_server.zig`)

**Lifecycle:**
1. Enter accept loop
2. On new connection: spawn detached client handler thread
3. On shutdown: exit loop

**Blocking operations:**
- `http_server.acceptWebSocketTimeout(100)` - polls HTTP socket with 100ms timeout

**Key code path:**
```zig
while (self.running.load(.acquire)) {
    const ws_conn = self.http_server.acceptWebSocketTimeout(100);
    if (ws_conn) |conn| {
        const thread = std.Thread.spawn(.{}, handleClientThread, .{...});
        thread.detach();  // Client threads are fire-and-forget
    }
}
```

### Client Handler Threads (`ws_server.zig:handleClient`)

**Lifecycle:**
1. Send initial terminal snapshot
2. Enter message loop polling WebSocket + notify pipe
3. On data from PTY: send delta/snapshot to client
4. On data from client: parse and route to pane
5. On disconnect or shutdown: exit and cleanup

**Blocking operations:**
- `posix.poll(&poll_fds, 1000)` - polls WebSocket fd + notify pipe with 1000ms timeout

**Key code path:**
```zig
while (self.running.load(.acquire)) {
    const ready = posix.poll(&poll_fds, 1000);
    // Handle WebSocket messages, PTY updates...
}
```

### PtyReader Thread (`pty_reader.zig`)

**Lifecycle:**
1. Collect all PTY master fds from all panes
2. Poll them with timeout
3. Read available data, feed to panes
4. Signal notify pipe to wake client threads
5. Repeat until shutdown

**Blocking operations:**
- `posix.poll(fds[0..nfds], 1000)` - polls all PTY fds with 1000ms timeout

**Key code path:**
```zig
while (self.running.load(.acquire)) {
    // Collect PTY fds...
    const ready = posix.poll(fds[0..nfds], 1000);
    // Read and feed to panes...
    self.session.notify_pipe.signal();  // Wake client threads
}
```

## Inter-Thread Communication

### 1. Notify Pipe (Self-Pipe Trick)

**Purpose:** Wake WebSocket client threads when new PTY data arrives.

**Implementation:** `notify_pipe.zig`
- Unix pipe with both ends non-blocking
- `signal()`: Write a byte (safe from any thread)
- `drain()`: Read all bytes (clear signaled state)
- `getFd()`: Get read end for polling

**Data flow:**
```
PTY Reader                    Client Handler
    │                              │
    │ reads PTY data               │ blocked on poll()
    │ feeds to pane                │
    │                              │
    ├──► notify_pipe.signal() ─────┤
    │                              │ poll() returns
    │                              │ notify_pipe.drain()
    │                              │ sends snapshot/delta
```

### 2. Atomic Running Flags

**Purpose:** Signal shutdown across threads with guaranteed visibility.

**Implementation:** `std.atomic.Value(bool)` with acquire/release ordering

**Locations:**
- `WsServer.running` - checked by accept loop and client handlers
- `PtyReader.running` - checked by poll loop
- `signal.shutdown_requested` - global, set by signal handler

**Memory ordering:**
- `.release` on store: Ensures write is visible to other cores
- `.acquire` on load: Ensures read sees latest value from memory

```
Main Thread                   Worker Thread
    │                              │
    │                              │ while (running.load(.acquire))
    │                              │     // sees 'true'
    │                              │
    ├── running.store(false, .release)
    │                              │
    │                              │ while (running.load(.acquire))
    │                              │     // sees 'false', exits
```

### 3. Shared State Access

**Session/Window/Pane hierarchy:**
- Protected by `Pane.mutex` for terminal state
- Accessed by: main thread (IPC commands), client threads (snapshots), PTY reader (feed)

**Locking pattern:**
```zig
// In pane.zig
pub fn feed(self: *Pane, data: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    // Modify terminal state...
}
```

## Graceful Shutdown Sequence

```
┌──────────────────────────────────────────────────────────────────┐
│  1. Signal Received (SIGINT/SIGTERM)                             │
│     └─► signal handler sets shutdown_requested = true            │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (≤100ms - IPC poll timeout)
┌──────────────────────────────────────────────────────────────────┐
│  2. Main Thread Exits IPC Loop                                   │
│     └─► prints "Received shutdown signal, cleaning up..."        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  3. Signal Worker Threads                                        │
│     ├─► ws_server.running.store(false, .release)                 │
│     └─► pty_reader.stop()  // sets running = false               │
└──────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          ▼ (≤100ms)                              ▼ (≤1000ms)
┌─────────────────────┐                 ┌─────────────────────┐
│  WsServer Exits     │                 │  PtyReader Exits    │
│  (accept timeout)   │                 │  (poll timeout)     │
└─────────────────────┘                 └─────────────────────┘
          │                                       │
          ▼ (≤1000ms)                             │
┌─────────────────────┐                           │
│  Client Threads     │                           │
│  Exit (poll timeout)│                           │
└─────────────────────┘                           │
          │                                       │
          └───────────────────┬───────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  4. Thread Joins Complete                                        │
│     ├─► ws_thread.join()                                         │
│     └─► pty_thread.join()                                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  5. Cleanup (defer blocks)                                       │
│     ├─► state.deinit()     // kills child processes, frees mem   │
│     ├─► ws_server.deinit() // closes HTTP socket                 │
│     ├─► ipc_server.deinit()// closes IPC socket, deletes files   │
│     └─► signal.reset()     // restore default signal handlers    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  6. Exit                                                         │
│     └─► prints "dullahan server shutting down"                   │
└──────────────────────────────────────────────────────────────────┘
```

**Worst-case shutdown time:** ~1.3 seconds
- 100ms for IPC loop to notice signal
- 100ms for WsServer accept to timeout
- 1000ms for client handlers and PTY reader to timeout

## Signal Handling (`signal.zig`)

**Signals caught:** SIGINT (Ctrl+C), SIGTERM (kill command)

**Handler constraints:**
- Runs in signal context (very limited operations allowed)
- Only sets atomic flag (async-signal-safe)
- Cannot allocate, log, or call most functions

**Implementation:**
```zig
var shutdown_requested: std.atomic.Value(bool) = .init(false);

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}
```

## Common Pitfalls Avoided

### 1. Memory Visibility
**Problem:** Plain `bool` may not be visible across CPU cores.
**Solution:** Use `std.atomic.Value(bool)` with acquire/release ordering.

### 2. Blocking Accept
**Problem:** `accept()` blocks forever, ignores shutdown flag.
**Solution:** Use `poll()` with timeout before `accept()`.

### 3. Detached Thread Cleanup
**Problem:** Detached client threads can't be joined.
**Solution:** They check `running` flag with poll timeout and exit naturally.

### 4. Signal Handler Limitations
**Problem:** Signal handlers can only do async-signal-safe operations.
**Solution:** Handler only sets atomic flag; main thread does actual cleanup.

## File Reference

| File | Threading Role |
|------|---------------|
| `server.zig` | Main thread, orchestration, shutdown sequence |
| `ws_server.zig` | WsServer thread + client handler threads |
| `pty_reader.zig` | PtyReader thread |
| `signal.zig` | Signal handler, global shutdown flag |
| `notify_pipe.zig` | Inter-thread notification (self-pipe) |
| `ipc.zig` | IPC socket with timeout-based accept |
| `http.zig` | HTTP socket with timeout-based accept |
| `pane.zig` | Mutex-protected terminal state |

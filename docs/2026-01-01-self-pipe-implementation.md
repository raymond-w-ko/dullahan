# Self-Pipe Implementation for Dullahan

**Status: IMPLEMENTED** (commit 4a9b481)

## Goal
Eliminate polling latency by using a pipe to signal WS threads immediately when PTY reader has new data.

## Current Architecture (Polling)

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   PTY Reader    │     │   WS Thread 1   │     │   WS Thread 2   │
│   (singleton)   │     │   (per client)  │     │   (per client)  │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         │ poll(pty_fds, 10ms)   │ poll(ws_fd, 10ms)     │ poll(ws_fd, 10ms)
         │                       │                       │
         ▼                       ▼                       ▼
    [read PTY]              [check pane.gen]        [check pane.gen]
         │                       │                       │
         │ pane.feed()           │ if changed: send      │ if changed: send
         │ pane.generation++     │                       │
         │                       │                       │
         │                       │◄── UP TO 10ms DELAY ──┤
         │                       │                       │
```

**Problem:** WS threads poll every 10ms checking `pane.generation`. Even though PTY reader updates immediately, WS threads don't know until their next poll timeout.

## Proposed Architecture (Self-Pipe)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              STARTUP                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Server creates:                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  NotifyPipe                                                          │    │
│  │  ├── read_fd:  i32  (for WS threads to poll on)                     │    │
│  │  ├── write_fd: i32  (for PTY reader to signal)                      │    │
│  │  └── Both set to O_NONBLOCK                                          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                           RUNTIME DATA FLOW                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐                        ┌─────────────────┐             │
│  │   PTY Reader    │                        │   WS Thread     │             │
│  └────────┬────────┘                        └────────┬────────┘             │
│           │                                          │                       │
│           │ 1. poll(pty_fds, ∞)                      │ 1. poll([ws_fd,       │
│           │    (block until data)                    │         pipe_read],   │
│           │                                          │         ∞)            │
│           │                                          │    (block until       │
│           │                                          │     either ready)     │
│           ▼                                          │                       │
│      [PTY has data]                                  │                       │
│           │                                          │                       │
│           │ 2. read(pty_fd)                          │                       │
│           │                                          │                       │
│           │ 3. pane.feed(data)                       │                       │
│           │    pane.generation++                     │                       │
│           │                                          │                       │
│           │ 4. write(pipe_write, "x")  ─────────────►│ 2. poll returns!      │
│           │    (1 byte, non-blocking)                │    (pipe_read ready)  │
│           │                                          │                       │
│           │                                          │ 3. drain pipe:        │
│           │                                          │    read(pipe_read)    │
│           │                                          │    until EAGAIN       │
│           │                                          │                       │
│           │                                          │ 4. check pane.gen     │
│           │                                          │    → changed!         │
│           │                                          │                       │
│           │                                          │ 5. sendDelta()        │
│           │                                          │                       │
│           │                                          │ 6. goto 1 (poll)      │
│           │                                          │                       │
│           │ 5. goto 1 (poll)                         │                       │
│           │                                          │                       │
└───────────┴──────────────────────────────────────────┴───────────────────────┘
```

## Detailed Implementation Steps

### Step 1: Create `NotifyPipe` struct

**File:** `server/src/notify_pipe.zig` (new file)

```zig
const NotifyPipe = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
    
    pub fn init() !NotifyPipe { ... }
    pub fn deinit(self: *NotifyPipe) void { ... }
    pub fn signal(self: *NotifyPipe) void { ... }  // Write 1 byte (non-blocking)
    pub fn drain(self: *NotifyPipe) void { ... }   // Read all bytes (non-blocking)
    pub fn getFd(self: *NotifyPipe) posix.fd_t { ... }  // For polling
};
```

**Details:**
- `init()`: Call `posix.pipe()`, set both ends to `O_NONBLOCK` using `fcntl`
- `signal()`: Write single byte `"x"`, ignore `EAGAIN` (pipe full is fine, already signaled)
- `drain()`: Read in loop until `EAGAIN`, discard bytes (we just need the wake-up)
- No mutex needed: pipe is thread-safe by OS guarantee

### Step 2: Add NotifyPipe to Session

**File:** `server/src/session.zig`

```zig
pub const Session = struct {
    // ... existing fields ...
    notify_pipe: NotifyPipe,  // NEW: shared by all threads
    
    pub fn init(allocator: Allocator) !Session {
        return .{
            // ...
            .notify_pipe = try NotifyPipe.init(),
        };
    }
    
    pub fn deinit(self: *Session) void {
        self.notify_pipe.deinit();
        // ...
    }
};
```

### Step 3: Modify PTY Reader to signal after feed

**File:** `server/src/pty_reader.zig`

```zig
pub const PtyReader = struct {
    // ... existing fields ...
    notify_pipe: *NotifyPipe,  // NEW: pointer to session's pipe
    
    pub fn init(allocator: Allocator, session: *Session) PtyReader {
        return .{
            // ...
            .notify_pipe = &session.notify_pipe,
        };
    }
    
    pub fn run(self: *PtyReader) void {
        while (self.running) {
            // Poll PTY fds (can use longer timeout now, or even infinite)
            const ready = posix.poll(fds[0..nfds], -1);  // -1 = infinite
            
            // ... read from ready PTYs ...
            
            if (n > 0) {
                pane.feed(buf[0..n]);
                
                // NEW: Signal all waiting WS threads
                self.notify_pipe.signal();
            }
        }
    }
};
```

### Step 4: Modify WS Server to poll on pipe + socket

**File:** `server/src/ws_server.zig`

This is the most complex change. Currently:
```zig
ws.setReadTimeout(10);  // Poll every 10ms
const frame_result = ws.readFrame();
```

Need to change to:
```zig
// Poll on BOTH: WebSocket fd AND notify pipe
var fds = [_]posix.pollfd{
    .{ .fd = ws.getFd(), .events = posix.POLL.IN, .revents = 0 },
    .{ .fd = session.notify_pipe.getFd(), .events = posix.POLL.IN, .revents = 0 },
};

const ready = posix.poll(&fds, -1);  // Block indefinitely

if (fds[0].revents & posix.POLL.IN != 0) {
    // WebSocket has data - read frame
    const frame = ws.readFrameNoBlock();
    // ... handle frame ...
}

if (fds[1].revents & posix.POLL.IN != 0) {
    // PTY reader signaled - drain pipe and send update
    session.notify_pipe.drain();
    if (pane.generation != last_generation) {
        self.sendUpdate(&ws, pane, last_generation);
        last_generation = pane.generation;
    }
}
```

**Challenge:** The current `websocket.Connection` doesn't expose the raw fd or non-blocking read. Need to either:
1. Add `getFd()` and `readFrameNoBlock()` to `websocket.zig`
2. Or restructure to use raw fd operations

### Step 5: Modify websocket.zig to support non-blocking

**File:** `server/src/websocket.zig`

Add methods:
```zig
pub const Connection = struct {
    stream: std.net.Stream,
    // ...
    
    /// Get underlying file descriptor for polling
    pub fn getFd(self: *Connection) posix.fd_t {
        return self.stream.handle;
    }
    
    /// Set socket to non-blocking mode
    pub fn setNonBlocking(self: *Connection, non_blocking: bool) !void {
        // Use fcntl to set O_NONBLOCK
    }
    
    /// Try to read a frame, return null if would block
    pub fn tryReadFrame(self: *Connection) !?Frame {
        // Same as readFrame but return null on EAGAIN
    }
};
```

## File Changes Summary

| File | Changes |
|------|---------|
| `notify_pipe.zig` | **NEW** - NotifyPipe struct (init, signal, drain, getFd) |
| `session.zig` | Add `notify_pipe: NotifyPipe` field |
| `pty_reader.zig` | Add notify_pipe pointer, call `signal()` after `feed()` |
| `websocket.zig` | Add `getFd()`, `setNonBlocking()`, `tryReadFrame()` |
| `ws_server.zig` | Replace timeout-based polling with `poll([ws_fd, pipe_fd])` |
| `server.zig` | Pass session to pty_reader (may already do this) |

## Edge Cases & Error Handling

### 1. Pipe Full
If PTY reader writes faster than WS threads drain:
- `write()` returns `EAGAIN` 
- **Solution:** Ignore it! If pipe is full, WS threads are already signaled

### 2. Multiple WS Threads
All WS threads share the same pipe read fd:
- All will wake up when signaled
- **Solution:** Each thread drains independently, checks its own `last_generation`
- Only threads with outdated generation will actually send

### 3. Spurious Wakeups
WS thread wakes up but `pane.generation` unchanged:
- Can happen if another thread already sent the update
- **Solution:** Just check generation, skip send if unchanged (already doing this)

### 4. Connection Close
WS thread needs to detect client disconnect:
- `poll()` returns `POLLHUP` or `POLLERR` on ws_fd
- **Solution:** Check revents flags, close connection if error

### 5. Server Shutdown
PTY reader and WS threads need clean shutdown:
- **Solution:** Close write end of pipe → all `poll()` calls return with `POLLHUP`

## Testing Plan

1. **Basic functionality:** Type characters, verify immediate echo
2. **Fast typing:** Hold down a key, verify no dropped characters
3. **Multiple clients:** Connect 2+ browsers, verify all update
4. **Stress test:** Run `yes | head -10000`, verify no hang
5. **Disconnect:** Close browser, verify server doesn't crash
6. **Reconnect:** Disconnect and reconnect, verify works

## Performance Comparison

| Metric | Before (Polling) | After (Self-Pipe) |
|--------|------------------|-------------------|
| Latency | 0-10ms (avg 5ms) | <1ms |
| CPU idle | Constant wakeups | True sleep |
| Scalability | O(clients × polls/sec) | O(events) |

## Rollback Plan

If issues arise, can easily revert to polling:
- Keep old timeout-based code commented
- Self-pipe is additive, doesn't remove capabilities

## Cross-Platform Notes

### Linux & macOS
- `pipe()` and `poll()` work identically
- `O_NONBLOCK` via `fcntl()` 

### Windows (Future)
- No `pipe()`, use `socketpair()` emulation or named pipes
- Or use `WSAPoll()` with a loopback socket pair
- Consider libxev for full cross-platform support later

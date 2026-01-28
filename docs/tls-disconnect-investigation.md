# TLS Client Disconnect Investigation

**Date:** 2026-01-28
**Log line:** `[1769616959] info (event_loop): Client 0 disconnected (poll error/hangup)`
**Symptom:** Client disconnects during active use (not idle)

---

## Code Path

The log message is emitted at `server/src/event_loop.zig:291` when `poll()` returns `POLL.ERR`, `POLL.HUP`, or `POLL.NVAL` on a client's WebSocket socket fd.

```
poll() returns ERR/HUP/NVAL on client fd
  -> event_loop.zig:290-292: removeClient()
```

There is a separate, cleaner disconnect path that does NOT produce this message:

```
TLS read returns EndOfStream
  -> tls_wrapper.zig:101: converted to return 0
  -> websocket.zig:333: n==0 -> error.ConnectionClosed
  -> event_loop.zig:324-326: "Client N disconnected" (no "poll error/hangup")
```

The "poll error/hangup" path means the OS-level socket entered an error state before the application layer could read/detect a clean close.

---

## Pinned TLS Dependency

**Library:** [ianic/tls.zig](https://github.com/ianic/tls.zig)
**Pinned commit:** `c697948170bf1cf0db6b223bbc976afa1c287d82`
**Reason for pin:** Newer versions require an unreleased version of Zig (0.16.0-dev per upstream `build.zig.zon` on main)

**File:** `server/build.zig.zon:19-22`

**Related local detail:** Dullahan clears socket read/write timeouts after the initial handshake + initial snapshot/layout/master sends:

```
event_loop.zig: client.ws.setTimeouts(0);
```

This means `SO_RCVTIMEO`/`SO_SNDTIMEO` only apply during the accept/handshake/initial bootstrap window, not during long-lived active sessions.

---

## Relevant Upstream Fixes (Missing from Pinned Version)

### 1. Reader.stream Buffer Bug (Jan 26, 2026)

**Commit:** `ed729274f1eb4ab03fc589c3a45c3f9728fe42b6`
**Author:** Oleg Dorovskoy, merged by Igor Anic

> "Fix tls.Connection.Reader.stream function - Current implementation just fills data buffer but does not call actual Writer's logic producing EndOfStream error once the buffer is full."

**Impact assessment:** Dullahan uses `self.conn.read(buf)` directly in `tls_wrapper.zig:100`, NOT the `.stream()` function. This specific fix may not directly apply. However, it indicates ongoing buffer management issues in the TLS layer that could have related symptoms through shared internal state.

### 2. Returning Function-Local References (Oct 3, 2025)

**Commit message:** "avoid returning function local references"

**Impact assessment:** Returning dangling pointers from TLS functions would cause undefined behavior — could manifest as corrupted data, segfaults, or socket errors. This is a memory safety bug that could cause sporadic disconnects.

### 3. Sporadic Index Out of Bounds (ziglang/zig#15226)

In the TLS `finishRead2` function: "index 16658, len 16645". This is a buffer overread that could corrupt memory or panic, leading to connection termination.

### 4. Unexpected Message Handling (ziglang/zig#17446)

TLS client did not properly handle certain server messages (e.g., client certificate requests), producing `TlsUnexpectedMessage` errors.

---

## Potential Causes (Ranked by Likelihood)

### MEDIUM: Non-blocking I/O + TLS State Mismatch (TLS library semantics)

**Location:** `server/src/websocket.zig:158-161`

The socket is set to `O_NONBLOCK` AFTER the TLS handshake completes. If the TLS library does not fully support non-blocking partial record reads/writes in all paths, this can surface as truncated records or unexpected connection resets.

TLS records are framed — a single application-level `write()` becomes a TLS record that must be sent atomically. With non-blocking sockets:
- A partial TLS record write leaves the connection in an inconsistent state
- The peer receives an incomplete record and may RST the connection
- Next `poll()` sees `ERR` or `HUP`

**Note:** partial writes are normal and should be handled by the TLS library. This is only a risk if tls.zig mishandles non-blocking I/O.

### LOW: Write Timeout Mid-TLS-Record (Connect-time only)

**Location:** `server/src/websocket.zig:147-156`

A 10-second `SO_SNDTIMEO` is set in `websocket.Connection.init`, but `client.ws.setTimeouts(0)` clears it immediately after the initial bootstrap messages. This can only affect the initial connection window, not long-lived active use. If a timeout did occur during connect, a mid-record timeout could corrupt TLS state and cause a reset.

### MEDIUM: TLS Internal Buffer Issues (Pinned Version)

The pinned version has known buffer management issues (see upstream fixes above). Under high throughput (heavy terminal output → frequent snapshots/deltas → large writes):
- Write buffer fills (8MB limit at `websocket.zig:131`)
- TLS internal buffers may interact poorly with congestion backpressure
- Memory corruption from dangling pointer bug (fixed Oct 2025) could cause sporadic failures

### MEDIUM: TLS hasPendingData() Accuracy

**Location:** `server/src/tls_wrapper.zig:129-132`

```zig
pub fn hasPendingData(self: *TlsConnection) bool {
    return self.conn.read_buf.len > 0 or self.conn.rec_rdr.hasMore();
}
```

The event loop at `event_loop.zig:341-346` uses this to decide whether to re-enter the read loop without waiting for `poll()`. If this function returns a false negative (says no data when TLS has buffered data), the event loop goes back to `poll()` which only sees the TCP socket — not TLS internal buffers. This could cause stale state but likely wouldn't cause `ERR/HUP`.

If it returns a false positive, the code loops and calls `readMore()` which calls `self.stream.read()` — on a non-blocking socket with no data, this returns `WouldBlock`, which is handled. So false positive is safe.

### LOW: Browser/Network Causes

Standard non-TLS-related causes:
- Page refresh (Ctrl+R, F5, dev tools auto-reload during development)
- Browser tab backgrounded (Chrome throttles WebSocket I/O)
- Network micro-interruption (WiFi roaming, DHCP renewal)
- Client send queue overflow (`client/src/terminal/connection.ts:1416-1418`)
- Laptop suspend/resume

These are possible but would also affect plain HTTP mode equally. If the issue only occurs with HTTPS/WSS, it points to the TLS layer.

---

## Diagnostic Steps

### 1. Determine if TLS-specific

Run with plain HTTP (no `--tls-cert`/`--tls-key` flags) under the same usage pattern. If the disconnect does not reproduce, the TLS layer is the culprit.

### 2. Enable debug logging

```bash
DULLAHAN_DEBUG=+connection ./zig-out/bin/dullahan serve
```

### 3. Add TLS-specific error logging

In `tls_wrapper.zig`, log errors before transforming them:

```zig
// In read():
return self.conn.read(buf) catch |e| {
    log.warn("TLS read error: {}", .{e});  // ADD THIS
    if (e == error.EndOfStream) return 0;
    return e;
};
```

### 4. Check write congestion correlation

Look for `"write congested, pausing updates"` log lines preceding the disconnect. Correlation would still be useful, but note that socket timeouts are cleared post-bootstrap, so the mechanism would likely be congestion → peer close/RST rather than timeout.

---

## Key Files

| File | Relevance |
|------|-----------|
| `server/src/event_loop.zig:290-292` | Where the log message is emitted |
| `server/src/event_loop.zig:322-338` | Clean disconnect path (for comparison) |
| `server/src/tls_wrapper.zig` | TLS ↔ application boundary |
| `server/src/websocket.zig:124-170` | Socket options (non-blocking, timeouts, keepalive) |
| `server/src/websocket.zig:327-336` | `readMore()` — reads through TLS |
| `server/src/websocket.zig:311-325` | `flushWriteBuffer()` — writes through TLS |
| `server/src/http.zig:453-471` | Initial socket timeouts before TLS handshake |
| `server/build.zig.zon:19-22` | Pinned TLS dependency |
| `client/src/terminal/connection.ts:416-423` | Client-side WebSocket close/reconnect |

---

## Recommendations

1. **Test plain HTTP vs HTTPS** to isolate TLS as the root cause.
2. **Update tls.zig** if a Zig-compatible commit exists between the current pin and the breaking Zig 0.16 requirement. The Oct 2025 dangling pointer fix is particularly concerning.
3. **Consider backporting** the dangling pointer fix (`avoid returning function local references`, Oct 3 2025) if a full update is not possible.
4. **Add error telemetry** to the TLS wrapper to capture what error the TLS layer returns before the socket enters `ERR/HUP` state.
5. **Review timeout behavior** — `SO_SNDTIMEO`/`SO_RCVTIMEO` only apply during the initial connection window and are cleared immediately after bootstrap. If disconnects still happen mid-session, focus on congestion + TLS I/O semantics rather than OS-level timeouts.

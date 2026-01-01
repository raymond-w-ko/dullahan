# WebSocket Connection Hang on Browser Refresh

**Date:** 2025-12-29  
**Status:** Fixed in commit `5b454ad`, but issue is returning (Linux-only)

## 2025-12-30 Update

Issue is starting to reoccur, though rarely. Confirmed it **only happens on Linux**, not macOS. Removed `Connection: close` headers to debug further. Likely related to Linux TCP stack / keep-alive behavior differences.

## Symptoms

- First page load works fine, WebSocket connects
- Browser refresh causes WebSocket to show "Status: (pending)" in DevTools
- Connection never completes
- After timeout (~30s), third connection attempt works
- Server log shows close frame and new connection arriving "at the same second"

## Root Cause

Two issues combined to cause the hang:

### 1. HTTP Keep-Alive Connection Reuse

Browsers use HTTP/1.1 keep-alive by default, attempting to reuse TCP connections for multiple requests. When loading a page:

1. Browser opens connection A
2. `GET /` returns HTML
3. Browser tries to reuse connection A for `GET /style.css`
4. But server had already closed connection A after serving HTML

Without `Connection: close` header, the browser doesn't know the server closed the connection. It tries to send the next request on a dead connection, which hangs.

### 2. Small Kernel Backlog

When browser refreshes, multiple things happen nearly simultaneously:
- Old WebSocket sends close frame
- New page requests HTML, CSS, JS (3+ HTTP requests)
- New WebSocket upgrade request

The default kernel backlog for `listen()` was too small to queue all these incoming connections during the burst, causing some to be dropped or delayed.

## The Fix

### Added `Connection: close` Header

All static file responses now include `Connection: close`:

```zig
sendResponseHeaders(stream, "200 OK", &.{
    .{ "Content-Type", mime_type },
    .{ "Cache-Control", "no-cache" },
    .{ "Connection", "close" },  // <-- Tell browser not to reuse
}, file_size)
```

This tells the browser: "I'm closing this connection after the response. Don't try to send more requests on it."

### Increased Kernel Backlog

```zig
const listener = try address.listen(.{
    .reuse_address = true,
    .kernel_backlog = 128,  // <-- Handle burst of connections
});
```

This allows the OS to queue more pending connections during the refresh burst.

## Why It Was Hard to Debug

1. **Couldn't reproduce with bun/curl** - These tools don't use HTTP keep-alive the same way browsers do
2. **Timing-dependent** - Only happened when close frame and new requests arrived at nearly the same time
3. **No error messages** - The connection just hung silently in "pending" state
4. **Worked on third try** - Browser eventually timed out the dead connection and opened a fresh one

## Lessons Learned

1. **Always send `Connection: close`** if you're closing after the response and don't support keep-alive
2. **Set adequate backlog** for servers that might receive bursts of connections
3. **Browser behavior differs from CLI tools** - Test with real browsers for HTTP issues
4. **Add debug logging early** - The "Waiting for connection..." / "Accepted connection..." logs helped narrow down where the hang occurred

## Related Files

- `server/src/http.zig` - HTTP server and static file serving
- `server/src/ws_server.zig` - WebSocket connection handling

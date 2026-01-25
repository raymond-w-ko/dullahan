# Debug Logging System

This document describes the Wine-style category-based debug logging system used in both the server (Zig) and client (TypeScript).

## Overview

Dullahan uses a unified logging approach across server and client:

- **Category-based filtering** - Enable/disable specific log categories at runtime
- **Wine-style syntax** - `+all,-mouse,+clipboard` format familiar to Linux developers
- **Consistent API** - Similar patterns in both Zig and TypeScript
- **Multiple output channels** - Logs go to files, console, and debug pane

```
┌─────────────────────────────────────────────────────────────┐
│                    Debug Configuration                       │
│                                                             │
│  Syntax: +category, -category, +all, -all                   │
│  Evaluated left-to-right: +all,-mouse = everything but mouse│
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│     Server (Zig)        │     │    Client (TypeScript)  │
│                         │     │                         │
│  Config sources:        │     │  Config sources:        │
│  - DULLAHAN_DEBUG env   │     │  - ?debug URL param     │
│  - debug-log IPC cmd    │     │  - localStorage         │
│                         │     │  - setDebugConfig()     │
│  Output channels:       │     │                         │
│  - Log file             │     │  Output channels:       │
│  - Debug pane (pane 0)  │     │  - Browser console      │
│  - Stderr (errors)      │     │                         │
└─────────────────────────┘     └─────────────────────────┘
```

## Configuration Syntax

Both server and client use identical Wine-style syntax:

| Directive | Effect |
|-----------|--------|
| `+category` | Enable a specific category |
| `-category` | Disable a specific category |
| `+all` | Enable all categories |
| `-all` | Disable all categories |

**Evaluation rules:**
- Directives are evaluated **left-to-right**
- Explicit disable (`-category`) always wins over `+all`
- Comma-separated: `+all,-mouse,-delta`
- Errors **always log** regardless of category settings

### Examples

```bash
# Enable all logging
+all

# Enable only clipboard and pane
+clipboard,+pane

# Everything except noisy delta sync
+all,-delta

# Everything except mouse and keyboard (verbose)
+all,-mouse,-keyboard

# Disable all logging
-all

# Reset then enable specific
-all,+clipboard,+connection
```

---

## Server Logging (Zig)

### Configuration Methods

**1. Environment Variable (startup)**
```bash
DULLAHAN_DEBUG=+all,-delta ./dullahan serve
```

**2. IPC Command (runtime)**
```bash
# Show current config and all categories
dullahan debug-log

# Set config
dullahan debug-log +all,-delta

# Enable all
dullahan debug-log on

# Disable all
dullahan debug-log off

# List available categories
dullahan debug-log list
```

### Categories

| Category | Description | Typical Use |
|----------|-------------|-------------|
| `connection` | WebSocket connect/disconnect, client join/leave | Connection issues |
| `keyboard` | Keyboard input processing | Input debugging |
| `mouse` | Mouse events, coordinate conversion | Mouse handling issues |
| `clipboard` | OSC 52 operations, copy/paste | Clipboard problems |
| `pane` | Pane creation, resize, terminal state | Pane lifecycle |
| `window` | Window creation, layout changes | Window management |
| `delta` | Delta sync, dirty rows, generation tracking | Sync issues (verbose!) |
| `snapshot` | Terminal snapshots | State debugging |
| `layout` | Layout loading, template selection | Layout problems |
| `theme` | OSC 10/11 color changes, palette sync | Theme issues |
| `pty` | PTY I/O, shell detection | Shell spawning |
| `dsr` | Device Status Reports (CSI n) | Terminal queries |
| `ipc` | IPC commands, status queries | CLI debugging |
| `http` | HTTP server, WebSocket upgrade | Connection setup |
| `signal` | Signal handling, shutdown | Graceful shutdown |

### Output Channels

Server logs go to **three channels**:

1. **Log File**: `/tmp/dullahan-<uid>/dullahan-dlog.log`
   - Always written (when category enabled)
   - Timestamped, plain text format

2. **Debug Pane** (Pane 0)
   - Color-coded by level (cyan=debug, green=info, yellow=warn, red=error)
   - Visible in browser UI

3. **Stderr**
   - In **release builds**: Only errors and `missing` level (unimplemented features)
   - In **debug builds** (`zig build` without `-Doptimize`): **ALL logs** go to stderr
   - Debug build behavior makes development easier - see all output in terminal

### API Reference

**File: `server/src/dlog.zig`**

```zig
const dlog = @import("dlog.zig");

// Create a category-scoped logger
const log = dlog.scoped(.clipboard);

// Category-aware logging (respects debug config)
log.debug("OSC 52 received: kind={c}", .{kind});
log.info("Clipboard set: {d} bytes", .{len});
log.warn("Unexpected state", .{});
log.err("Failed to parse");  // Always logs!

// Uncategorized logging (always logs, use sparingly)
dlog.info("Server starting", .{});
dlog.err("Fatal error", .{});
dlog.missing("Unhandled escape: CSI {d} m", .{code});
```

**File: `server/src/debug_config.zig`**

```zig
const debug_config = @import("debug_config.zig");

// Check if category enabled
if (debug_config.isEnabled(.clipboard)) {
    // expensive debug operation
}

// Set config at runtime
debug_config.setConfigString("+all,-delta");

// Get current config for display
var buf: [256]u8 = undefined;
const config_str = debug_config.getConfigString(&buf);
```

### Log Levels

| Level | Color | Stderr | Use Case |
|-------|-------|--------|----------|
| `debug` | Cyan | No | Verbose debugging |
| `info` | Green | No | Normal operations |
| `warn` | Yellow | No | Recoverable issues |
| `err` | Red | Yes | Errors (always logs) |
| `missing` | Magenta | Yes | Unimplemented features |

### Best Practices (Server)

```zig
// ✅ GOOD - Use scoped logger for debug output
const log = dlog.scoped(.clipboard);
log.info("OSC 52 SET: pane={d}", .{pane_id});

// ✅ GOOD - Errors always log (no category check needed)
log.err("Failed to parse clipboard data");

// ❌ BAD - Uncategorized logging (always logs, clutters output)
dlog.info("OSC 52 SET: pane={d}", .{pane_id});

// ❌ BAD - Using std.log directly (doesn't go to debug pane)
std.log.info("message", .{});

// ✅ GOOD - Check category for expensive operations
if (debug_config.isEnabled(.delta)) {
    const dump = try expensiveDump();
    defer allocator.free(dump);
    log.debug("Full state: {s}", .{dump});
}
```

---

## Client Logging (TypeScript)

### Configuration Methods

**1. URL Parameter (session)**
```
http://localhost:7681/?debug=+all,-mouse
http://localhost:7681/?debug              # Defaults to +all
```

**2. localStorage (persistent)**
```javascript
localStorage.setItem('debug', '+all,-delta');
localStorage.removeItem('debug');  // Disable
```

**3. Runtime API**
```typescript
import { setDebugConfig, getDebugConfig } from './debug';

setDebugConfig('+all,-mouse');
setDebugConfig('');  // Disable all
console.log(getDebugConfig());  // Current config string
```

### Categories

| Category | Description | Typical Use |
|----------|-------------|-------------|
| `connection` | WebSocket connect/disconnect | Connection issues |
| `sync` | Delta sync, generation tracking | Sync debugging |
| `snapshot` | Terminal state snapshots | State issues |
| `delta` | Delta updates | Update debugging |
| `mouse` | Mouse events | Mouse handling |
| `keyboard` | Keyboard input | Key handling |
| `keybind` | Keybind parsing/matching | Shortcut issues |
| `clipboard` | Clipboard operations | Copy/paste |
| `config` | Configuration changes | Settings |
| `ime` | IME composition | CJK input |
| `resize` | Terminal resizing | Layout issues |
| `layout` | Layout messages | Pane arrangement |
| `store` | State store operations | State management |

### Output

All client logs go to **browser console** with prefix `[dullahan:category]`:

```
[dullahan:connection] WebSocket connected
[dullahan:clipboard] Copy: 42 bytes
[dullahan:sync] Generation: 1234 → 1235
```

Use browser DevTools filter to show specific categories.

### API Reference

**File: `client/src/debug.ts`**

```typescript
import { debug, category, isDebug, isCategoryEnabled } from './debug';

// Create category-scoped logger
const log = debug.category('clipboard');

// Category-aware logging
log.log('OSC 52 received');
log.warn('Unexpected state');
log.error('Failed');  // Always logs!

// Additional console methods
log.group('Clipboard operation');
log.table(data);
log.time('parse');
// ... operation ...
log.timeEnd('parse');
log.groupEnd();

// Check if logging enabled
if (isDebug()) { /* any logging enabled */ }
if (isCategoryEnabled('delta')) { /* specific category */ }

// Uncategorized logging (discouraged)
debug.log('message');  // Only if any logging enabled
debug.error('error');  // Always logs
```

### Best Practices (Client)

```typescript
// ✅ GOOD - Use category logger
const log = debug.category('clipboard');
log.log('Copy operation started');

// ✅ GOOD - Errors always log
log.error('Failed to read clipboard');

// ❌ BAD - Direct console.log (no filtering)
console.log('Copy operation started');

// ❌ BAD - Uncategorized debug.log
debug.log('message');

// ✅ GOOD - Check category for expensive operations
if (isCategoryEnabled('delta')) {
    log.table(expensiveStateSnapshot());
}
```

---

## Debugging Workflows

### Connection Issues

```bash
# Server
DULLAHAN_DEBUG=+connection,+http ./dullahan serve

# Client
?debug=+connection
```

### Clipboard Problems

```bash
# Server
dullahan debug-log +clipboard

# Client
?debug=+clipboard
```

### Performance Investigation

```bash
# Disable verbose categories
DULLAHAN_DEBUG=+all,-delta,-mouse,-keyboard ./dullahan serve
?debug=+all,-delta,-mouse,-keyboard
```

### Full Debug Session

```bash
# Server: all logging
DULLAHAN_DEBUG=+all ./dullahan serve

# Client: all logging
?debug=+all

# Or interactively
dullahan debug-log +all
```

---

## Implementation Details

### Server Architecture

```
┌─────────────────┐     ┌─────────────────┐
│  debug_config   │     │      dlog       │
│                 │     │                 │
│  - Parse config │◄────│  - Log routing  │
│  - Store state  │     │  - Formatting   │
│  - Check enable │     │  - Timestamps   │
└─────────────────┘     └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
        ┌──────────┐      ┌──────────┐      ┌──────────┐
        │ Log File │      │Debug Pane│      │  Stderr  │
        │ (always) │      │(if init) │      │(err only)│
        └──────────┘      └──────────┘      └──────────┘
```

### Client Architecture

```
┌─────────────────────────────────────────┐
│              debug.ts                    │
│                                         │
│  - Config parsing (Wine-style)          │
│  - Category state (Set<string>)         │
│  - Category logger factory              │
│  - Console method wrappers              │
└────────────────────┬────────────────────┘
                     │
                     ▼
            ┌─────────────────┐
            │ Browser Console │
            │ [dullahan:cat]  │
            └─────────────────┘
```

### Log Format

**Server (file)**
```
[HH:MM:SS.mmm] LEVEL (category): message
[14:23:45.123] INFO (clipboard): OSC 52 SET: pane=1 kind='c'
```

**Server (debug pane)**
```
[timestamp] LEVEL (category): message
With ANSI colors: timestamp=gray, level=colored, category=gray
```

**Client (console)**
```
[dullahan:category] message
[dullahan:clipboard] OSC 52 received
```

---

## Troubleshooting

### Server logs not appearing

1. Check config is set:
   ```bash
   dullahan debug-log
   ```

2. Verify category is enabled:
   ```bash
   dullahan debug-log list
   ```

3. Check log file exists:
   ```bash
   cat /tmp/dullahan-$(id -u)/dullahan-dlog.log
   ```

### Client logs not appearing

1. Check URL has `?debug` param
2. Check localStorage:
   ```javascript
   localStorage.getItem('debug')
   ```
3. Verify in console:
   ```javascript
   import { getDebugConfig, getEnabledCategories } from './debug';
   console.log(getDebugConfig());
   console.log(getEnabledCategories());
   ```

### Too much output

Use category filtering:
```bash
# Exclude verbose categories
+all,-delta,-mouse,-keyboard,-sync
```

### Errors not showing

Errors **always** log regardless of category settings. If errors aren't showing:
- Server: Check stderr or log file
- Client: Check browser console (no filter)

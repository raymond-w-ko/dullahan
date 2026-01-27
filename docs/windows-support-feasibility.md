# Windows Support Feasibility Analysis

**Date**: 2026-01-27
**Status**: Research Complete

---

## Executive Summary

Adding Windows support to dullahan is **feasible but requires significant effort**. The main challenges are:

1. **PTY layer** - Must use Windows ConPTY instead of POSIX PTY (major rewrite)
2. **IPC layer** - Unix sockets → Named Pipes
3. **Event loop** - `poll()` → `WaitForMultipleObjects()`

The terminal emulation library (ghostty-vt) is platform-agnostic and requires no changes.

**Estimated effort**: 4-6 weeks for full native support.

---

## Component Analysis

### Summary Table

| Component | File | Effort | Changes Required |
|-----------|------|--------|------------------|
| **PTY (ConPTY)** | `pty.zig` | MAJOR | Complete rewrite - openpty→CreatePseudoConsole |
| **IPC** | `ipc.zig` | SIGNIFICANT | Unix sockets → Named Pipes |
| **Event Loop** | `event_loop.zig` | SIGNIFICANT | poll() → WaitForMultipleObjects |
| **Signal Handling** | `signal.zig` | MODERATE | sigaction → SetConsoleCtrlHandler |
| **Process Mgmt** | `process.zig` | MODERATE | waitpid/kill → GetExitCodeProcess/TerminateProcess |
| **Paths** | `paths.zig` | MODERATE | `/tmp/` → `%TEMP%`, uid → username |
| **Shell Detection** | `shell.zig` | MODERATE | `$SHELL` → `%COMSPEC%` or PowerShell |
| **HTTP Server** | `http.zig` | MODERATE | Socket polling adjustments |
| **Logging** | `dlog.zig` | TRIVIAL | Path changes only |
| **Terminal Emulation** | `terminal.zig` | NONE | ghostty-vt is platform-agnostic |

---

## Detailed Analysis

### 1. PTY Allocation (`pty.zig`) - MAJOR

**Current POSIX implementation:**
- Uses `openpty()` function (different headers for macOS vs Linux)
- Platform-specific ioctl constants (`TIOCSWINSZ`, `TIOCSCTTY`)
- Uses `fork()` for child process spawning
- Uses `setsid()` to create new session
- Uses `termios` for terminal attributes

**Windows ConPTY equivalent:**
```c
// Windows Pseudo Console API (Windows 10 1809+)
CreatePipe(&input_read, &input_write, ...);
CreatePipe(&output_read, &output_write, ...);
CreatePseudoConsole(size, input_read, output_write, 0, &hPC);
// Setup PROC_THREAD_ATTRIBUTE_LIST with PSEUDOCONSOLE attribute
CreateProcessW(shell, ..., &startup_info, ...);
```

**Key differences:**
- ConPTY uses pipe handles, not file descriptors
- No `fork()` - must use `CreateProcessW` with attribute lists
- Resize via `ResizePseudoConsole()` instead of ioctl
- No direct equivalent to `termios`

**Affected code:**
- Lines 13-17: C includes (platform-specific headers)
- Lines 44-99: `open()` method (openpty, fcntl, ioctl)
- Lines 94-99: `setSize()` method (ioctl constants)
- Lines 112-141: `spawn()` method (fork, execvpe)
- Lines 143-166: `childSetup()` method (setsid, ioctl, dup2)
- Lines 170-189: `setTerminalEnv()` function

### 2. IPC Sockets (`ipc.zig`) - SIGNIFICANT

**Current implementation:**
- Unix domain sockets (`AF.UNIX`, `SOCK.STREAM`)
- Socket path: `/tmp/dullahan-<uid>/dullahan.sock`
- `posix.poll()` for event waiting
- Process check via `posix.kill(pid, 0)`

**Windows equivalent:**

| POSIX | Windows |
|-------|---------|
| `socket(AF_UNIX, SOCK_STREAM)` | `CreateNamedPipeA("\\\\.\\pipe\\dullahan")` |
| `bind(sock, path)` | (path encoded in pipe name) |
| `listen(sock)` | `ConnectNamedPipe` per connection |
| `accept(sock)` | `ConnectNamedPipe()` + new pipe instance |
| `poll(fds, nfds, timeout)` | `WaitForMultipleObjects(handles, ...)` |
| `kill(pid, 0)` | `OpenProcess()` or `GetProcessById()` |

**Affected code:**
- Lines 177-183: `isServerRunning()` - process existence check
- Lines 190-227: `Server.init()` - socket creation and binding
- Lines 239-258: `acceptCommand()` - posix.accept and read
- Lines 275-323: `acceptCommandTimeout()` - posix.poll
- Lines 369-409: `Client.sendCommandWithData()` - socket connection

### 3. Signal Handling (`signal.zig`) - MODERATE

**Current implementation:**
- POSIX `sigaction()` for signal registration
- Handles `SIGINT` (Ctrl+C) and `SIGTERM` (kill)
- Uses atomic shutdown flag pattern

**Windows equivalent:**
- `SetConsoleCtrlHandler()` for Ctrl+C/Ctrl+Break
- `CtrlHandler()` callback receives `CTRL_C_EVENT`, `CTRL_BREAK_EVENT`
- No direct SIGTERM equivalent; use graceful shutdown via other means

**Affected code:**
- Lines 36-40: `Sigaction` struct setup
- Lines 43-47: `sigaction()` calls
- Lines 52-60: `reset()` function

### 4. Path Handling (`paths.zig`) - MODERATE

**Current implementation:**
- Temp dir: `/tmp/dullahan-<uid>/`
- Config dir: `~/.config/dullahan/`
- Uses `posix.getuid()` for user isolation

**Windows equivalent:**
- Temp dir: `%TEMP%\dullahan-<username>\`
- Config dir: `%APPDATA%\dullahan\` or `%LOCALAPPDATA%\dullahan\`
- Use `%USERNAME%` environment variable for isolation
- Handle drive letters and backslashes

**Affected code:**
- Lines 15-29: `getTempDir()` function
- Lines 34-52: `ensureTempDir()` function
- Lines 56-80: `getConfigDir()` function
- Lines 84-110: `ensureConfigDir()` function
- Lines 154-240: `StaticPaths` struct initialization

### 5. Shell Detection (`shell.zig`) - MODERATE

**Current implementation:**
- Checks `$SHELL` environment variable
- Fallback to `/bin/sh`
- Validates shell path exists

**Windows equivalent:**
- Check `%COMSPEC%` for cmd.exe
- Check for PowerShell (`pwsh.exe` or `powershell.exe`)
- Default to `C:\Windows\System32\cmd.exe`
- Consider Windows Terminal's shell detection patterns

### 6. Process Management (`process.zig`) - MODERATE

**Current implementation:**
- `posix.waitpid()` with `WNOHANG` for non-blocking wait
- `posix.kill(pid, SIGTERM)` for graceful shutdown
- `posix.kill(pid, SIGKILL)` for forced termination

**Windows equivalent:**
- `GetExitCodeProcess()` or `WaitForSingleObject()` for status
- `GenerateConsoleCtrlEvent()` for Ctrl+C-like behavior
- `TerminateProcess()` for forced termination

### 7. Event Loop (`event_loop.zig`) - SIGNIFICANT

**Current implementation:**
- Uses `posix.poll()` for multiplexing
- Polls socket FDs, HTTP FD, client WebSocket FDs, and PTY FDs

**Windows options:**

| Option | Pros | Cons |
|--------|------|------|
| `WaitForMultipleObjects()` | Simple, well-documented | Limited to 64 handles |
| I/O Completion Ports (IOCP) | Scalable, efficient | Complex, different model |
| Cross-platform library (libuv) | Abstracts differences | Additional dependency |

**Affected code:**
- Line 189: `posix.poll()` call
- Lines 210-242: `buildPollSet()` and fd array construction
- Lines 244+: `dispatchEvents()` logic

---

## ConPTY: Why Bundle OpenConsole

### The Problem

Microsoft's ConPTY fixes take **1-2 years** to reach users via Windows Update. Terminal emulators that use the system's built-in ConHost are stuck with bugs that Microsoft has already fixed.

### The Solution

Ship `conpty.dll` + `OpenConsole.exe` from Microsoft's Windows Terminal project. WezTerm, Windows Terminal, and VSCode all do this.

### How It Works

```
If conpty.dll and OpenConsole.exe exist in the same directory as the executable,
they are used instead of the Windows-provided ConHost implementation.
```

### Specific Bugs Fixed by Bundling

1. **gitui rendering** - ConHost produces malformed output with `TERM=xterm-256color`
2. **Mouse events** - Win32 console apps couldn't receive mouse input
3. **Resize glitches** - Color bar artifacts when resizing terminal windows
4. **Cursor issues** - Various cursor positioning problems
5. **ANSI escape sequences** - ConHost sends different bytes than OpenConsole

### Implementation

- Files are MIT-licensed from Microsoft's Windows Terminal project
- Available via NuGet package
- WezTerm stores them in: `assets/windows/conhost/`
- Adds ~3MB to distribution size

### Recommendation

**Bundle OpenConsole** rather than relying on system ConPTY. This ensures consistent behavior across all Windows versions and immediate access to bug fixes.

---

## Ghostty-vt Dependency

The terminal emulation library (ghostty-vt) is **platform-agnostic**:
- Pure VT parsing logic
- No OS-specific code
- Just processes escape sequences and maintains screen state

Ghostty (the full terminal app) doesn't have Windows support yet, but this doesn't affect dullahan since we only use the VT library.

---

## Implementation Approach

### Recommended Phases

#### Phase 1: Platform Abstraction Layer (1 week)

Create platform abstraction interfaces:

```zig
// platform/pty.zig
pub const Pty = switch (builtin.os.tag) {
    .windows => @import("pty_windows.zig").Pty,
    else => @import("pty_posix.zig").Pty,
};

// platform/ipc.zig
pub const IpcServer = switch (builtin.os.tag) {
    .windows => @import("ipc_windows.zig").Server,
    else => @import("ipc_posix.zig").Server,
};
```

#### Phase 2: Windows PTY Implementation (1-2 weeks)

Implement `pty_windows.zig` using ConPTY API:
- `CreatePseudoConsole()` for PTY creation
- `CreateProcessW()` with attribute lists for spawning
- `ResizePseudoConsole()` for terminal resize
- Bundle OpenConsole binaries

#### Phase 3: Windows IPC Implementation (1 week)

Implement `ipc_windows.zig` using Named Pipes:
- `CreateNamedPipeA()` for server pipe
- `ConnectNamedPipe()` for accepting connections
- Async I/O or thread pool for multiple clients

#### Phase 4: Event Loop Restructure (1 week)

Choose one:
- **Option A**: `WaitForMultipleObjects()` - simpler, limited to 64 handles
- **Option B**: I/O Completion Ports (IOCP) - more scalable, more complex

#### Phase 5: Remaining Fixes (1 week)

- Signal handling → Console control handler
- Path handling → `%TEMP%`, `%APPDATA%`
- Shell detection → `%COMSPEC%`, PowerShell detection
- Process management → Windows APIs

---

## Alternative: WSL2 (Interim Solution)

For near-term Windows users, document WSL2 usage:

```bash
# From Windows Terminal or PowerShell
wsl -d Ubuntu
cd /path/to/dullahan && ./dullahan serve
# Access via browser at http://localhost:7681
```

This works today with zero code changes.

---

## Effort Estimates

| Approach | Effort | Risk |
|----------|--------|------|
| **Full native Windows** | 4-6 weeks | Medium - ConPTY has quirks |
| **WSL2 documentation** | 1 day | Low - already works |
| **Platform abstraction only** | 1 week | Low - prepares for future |

---

## References

### ConPTY and OpenConsole
- [WezTerm Issue #1927: Track/bundle/ship conpty](https://github.com/wezterm/wezterm/issues/1927)
- [Alacritty Issue #4794: Use ConPty from OpenConsole](https://github.com/alacritty/alacritty/issues/4794)
- [VSCode Issue #224488: Ship newer version of conpty](https://github.com/microsoft/vscode/issues/224488)
- [Microsoft DevBlog: Introducing ConPTY](https://devblogs.microsoft.com/commandline/windows-command-line-introducing-the-windows-pseudo-console-conpty/)
- [WezTerm's bundled conhost](https://github.com/wezterm/wezterm/tree/main/assets/windows/conhost)

### Ghostty
- [Ghostty Windows Support Discussion #2563](https://github.com/ghostty-org/ghostty/discussions/2563)
- [Ghostty GitHub](https://github.com/ghostty-org/ghostty)

### Windows APIs
- [CreatePseudoConsole](https://docs.microsoft.com/en-us/windows/console/createpseudoconsole)
- [Named Pipes](https://docs.microsoft.com/en-us/windows/win32/ipc/named-pipes)
- [WaitForMultipleObjects](https://docs.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitformultipleobjects)

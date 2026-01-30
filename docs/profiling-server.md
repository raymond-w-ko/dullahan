# Profiling the Dullahan Server (Linux)

This guide covers how to profile the dullahan server to diagnose performance issues.

## Prerequisites

Install profiling tools:

```bash
# Ubuntu/Debian
sudo apt install linux-tools-common linux-tools-generic perf-tools-unstable \
    valgrind heaptrack hotspot flamegraph

# Arch
sudo pacman -S perf valgrind heaptrack hotspot flamegraph

# Fedora
sudo dnf install perf valgrind heaptrack hotspot flamegraph
```

## Quick Memory Check

Check server memory usage without any profiling tools:

```bash
# Find server PID
PID=$(cat /tmp/dullahan-$(id -u)/dullahan.pid)

# One-shot memory check (RSS = actual RAM used)
ps -o pid,rss,vsz,comm -p $PID

# Watch memory over time (updates every 2s)
watch -n 2 "ps -o pid,rss,vsz,comm -p $PID"

# Detailed memory map
cat /proc/$PID/smaps_rollup
```

## CPU Profiling with perf

### Record CPU Profile

```bash
# Get server PID
PID=$(cat /tmp/dullahan-$(id -u)/dullahan.pid)

# Record for 30 seconds (adjust as needed)
sudo perf record -F 99 -p $PID -g -- sleep 30

# Or record until you press Ctrl+C
sudo perf record -F 99 -p $PID -g
```

### View Results

```bash
# Interactive TUI report (navigate with arrow keys, Enter to expand)
sudo perf report

# Text report to stdout
sudo perf report --stdio

# Show top functions by CPU time
sudo perf report --stdio --sort=dso,symbol | head -50
```

### Generate Flame Graph

```bash
# Generate flame graph SVG (requires flamegraph package)
sudo perf script | stackcollapse-perf.pl | flamegraph.pl > flamegraph.svg

# Open in browser
xdg-open flamegraph.svg
# Or on WSL:
explorer.exe flamegraph.svg
```

### Using Hotspot (GUI)

```bash
# Record with perf
sudo perf record -F 99 -p $PID -g -- sleep 30

# Open in Hotspot GUI
hotspot perf.data
```

## Memory Profiling with Heaptrack

### Profile Memory Allocations

```bash
# Stop existing server
./zig-out/bin/dullahan quit

# Start server under heaptrack
heaptrack ./zig-out/bin/dullahan serve

# Use the terminal normally, then stop server
./zig-out/bin/dullahan quit
# Or Ctrl+C the heaptrack process
```

### View Results

```bash
# GUI analyzer (recommended)
heaptrack_gui heaptrack.dullahan.*.zst

# Text summary
heaptrack_print heaptrack.dullahan.*.zst | head -100
```

## Syscall Tracing with strace

### Trace All Syscalls

```bash
PID=$(cat /tmp/dullahan-$(id -u)/dullahan.pid)

# Trace with timing (shows slow syscalls)
sudo strace -p $PID -T -f 2>&1 | head -200

# Trace only specific syscalls
sudo strace -p $PID -e trace=read,write,poll,epoll_wait -T

# Summary of syscall time
sudo strace -p $PID -c -f
# Press Ctrl+C after a while to see summary
```

### Common Patterns to Look For

```bash
# Slow poll/epoll (event loop delays)
sudo strace -p $PID -e poll,epoll_wait -T 2>&1 | grep -E '\<[0-9]+\.[0-9]{3,}'

# Slow writes (network/disk bottleneck)
sudo strace -p $PID -e write -T 2>&1 | grep -E '\<[0-9]+\.[0-9]{3,}'
```

## Valgrind/Callgrind (Detailed but Slow)

**Warning**: Valgrind makes the server ~20-50x slower. Only use for detailed analysis.

```bash
# Stop existing server
./zig-out/bin/dullahan quit

# Run under callgrind
valgrind --tool=callgrind ./zig-out/bin/dullahan serve

# Use the terminal briefly, then stop
./zig-out/bin/dullahan quit

# View results
kcachegrind callgrind.out.*
# Or text output:
callgrind_annotate callgrind.out.* | head -100
```

## Debug Logging

Enable verbose server logging to see what's happening:

```bash
# Enable all debug categories
DULLAHAN_DEBUG=+all ./zig-out/bin/dullahan serve

# Enable specific categories
DULLAHAN_DEBUG=+delta,+snapshot ./zig-out/bin/dullahan serve

# Or at runtime via IPC
./zig-out/bin/dullahan debug-log +delta,+snapshot

# View log
tail -f /tmp/dullahan-$(id -u)/dullahan.log
```

### Available Debug Categories

| Category | Description |
|----------|-------------|
| `connection` | WebSocket connect/disconnect |
| `keyboard` | Keyboard input processing |
| `mouse` | Mouse events |
| `clipboard` | OSC 52 clipboard operations |
| `pane` | Pane creation, resize |
| `window` | Window creation, layout |
| `delta` | Delta sync, dirty rows |
| `snapshot` | Terminal snapshots |
| `layout` | Layout loading |
| `pty` | PTY I/O |
| `ipc` | IPC commands |

## Measuring Delta Sizes

Add timing to see if deltas are growing:

```bash
# Enable delta logging
./zig-out/bin/dullahan debug-log +delta

# Watch the log for delta sizes
tail -f /tmp/dullahan-$(id -u)/dullahan.log | grep -E 'delta|dirty_rows'
```

Look for patterns like:
- `dirty_rows=N` where N keeps growing
- Delta generation time increasing
- Repeated "forcing full resync" messages

## Quick Diagnosis Checklist

```bash
# 1. Check memory isn't growing unboundedly
watch -n 5 "ps -o rss -p $(cat /tmp/dullahan-$(id -u)/dullahan.pid) | tail -1"

# 2. Check CPU isn't pinned
top -p $(cat /tmp/dullahan-$(id -u)/dullahan.pid)

# 3. Check for slow syscalls
sudo strace -p $(cat /tmp/dullahan-$(id -u)/dullahan.pid) -c
# Ctrl+C after 10 seconds, look at "seconds" column

# 4. Check delta sync stats in client
# Open browser DevTools, look for [dullahan:delta] logs
# Or check titlebar for Δ{deltas} ⟳{resyncs} counts

# 5. Check log file size (shouldn't grow too fast)
ls -lh /tmp/dullahan-$(id -u)/*.log
```

## Interpreting Results

### High CPU in `feed` or `printString`
- Terminal emulation is the bottleneck
- High-output applications (logs, builds) cause this
- Consider rate-limiting output or using sync mode

### High CPU in `generateDelta` or `generateSnapshot`
- Delta/snapshot encoding is slow
- Check if dirty_rows count is high
- May need to batch updates or reduce viewport size

### Memory Growing Over Time
- Check for leaks with heaptrack
- Common culprits: style tables, scrollback, caches
- Client-side: check rowCache, lastStyles sizes in DevTools

### High `poll`/`epoll_wait` Time
- Event loop is waiting (normal if idle)
- If high during activity, check PTY read performance

### Slow `write` Syscalls
- Network or disk I/O bottleneck
- Check if WebSocket sends are backing up
- May need to batch messages or compress more

# Stray 'm' Character Bug

**Date:** 2024-12-31  
**Fixed in:** Commit `9613967`  
**Severity:** Visual corruption

## Symptoms

When running programs with heavy escape sequence usage (like Claude CLI), stray `m` characters appeared at random positions in the terminal output:

```
U+2502                     * U+2590U+259BU+2588U+2588U+2588U+259CU+258C *                    mU+2502
```

The `m` appeared where it shouldn't - typically before box-drawing characters or at line boundaries.

## Root Cause

The VT stream parser was being recreated for each `feed()` call, discarding parser state between PTY reads.

### The Problem Code

```zig
pub fn feed(self: *Pane, data: []const u8) !void {
    // BUG: New parser each call - loses state!
    var stream = self.terminal.vtStream();
    defer stream.deinit();
    try stream.nextSlice(data);
}
```

### What Happens

When an escape sequence is split across PTY read boundaries:

```
Read 1 (ends mid-sequence):
  ... 5b 33 38 3b 32 3b 32 31 35 3b 31 31 39 3b 38 37
      [  3  8  ;  2  ;  2  1  5  ;  1  1  9  ;  8  7

Read 2 (starts with 'm'):
  6d e2 94 82 ...
  m  (box char)
```

With a fresh parser for Read 2, the `m` (0x6d) is not recognized as part of an escape sequence - it's just a regular character that gets printed.

## The Problematic Escape Sequence

The culprit is the **SGR (Select Graphic Rendition)** sequence for 24-bit RGB colors:

```
ESC [ 38 ; 2 ; R ; G ; B m
│   │ │    │   │   │   │ │
│   │ │    │   │   │   │ └─ Terminator
│   │ │    │   │   │   └─── Blue (0-255)
│   │ │    │   │   └─────── Green (0-255)  
│   │ │    │   └─────────── Red (0-255)
│   │ │    └─────────────── RGB mode indicator
│   │ └──────────────────── Set foreground color
│   └────────────────────── CSI (Control Sequence Introducer)
└────────────────────────── Escape (0x1B)
```

### Example from Claude CLI

```
\x1b[38;2;215;119;87m   = Set foreground to RGB(215, 119, 87) - orange
```

In hex: `1b 5b 33 38 3b 32 3b 32 31 35 3b 31 31 39 3b 38 37 6d`

This sequence is 18 bytes long. When PTY reads happen to split it after byte 17 (`37` = "7") and before byte 18 (`6d` = "m"), the bug manifests.

### Other SGR Sequences

Any SGR sequence ending in `m` could trigger this:

| Sequence | Meaning |
|----------|---------|
| `\x1b[0m` | Reset all attributes |
| `\x1b[1m` | Bold |
| `\x1b[31m` | Red foreground |
| `\x1b[48;2;R;G;Bm` | RGB background |
| `\x1b[38;5;Nm` | 256-color foreground |

## The Fix

Store the VT stream parser in the `Pane` struct so it persists across `feed()` calls:

```zig
pub const Pane = struct {
    // ... other fields ...
    
    /// VT stream parser - persists between feed() calls
    vt_stream: @TypeOf(Terminal.vtStream(undefined)),
    
    pub fn init(...) !Pane {
        return .{
            // ...
            .vt_stream = terminal.vtStream(),
        };
    }
    
    pub fn feed(self: *Pane, data: []const u8) !void {
        // FIXED: Use persistent parser
        try self.vt_stream.nextSlice(data);
    }
    
    pub fn deinit(self: *Pane) void {
        self.vt_stream.deinit();
        // ...
    }
};
```

Now when Read 2 arrives with just `m`, the parser knows it's continuing an SGR sequence and correctly interprets it as the terminator.

## Debugging Tools Used

### debug-capture command

```bash
./zig-out/bin/dullahan debug-capture
cat /tmp/dullahan-capture.hex
```

Captures raw PTY output as hex dump:

```
[timestamp] offset: hex bytes | ascii
[1767287885419] 03f0: 5b 33 38 3b 32 3b 32 31 35 3b 31 31 39 3b 38 37 | [38;2;215;119;87
[1767287885419] 0000: 6d e2 94 82 1b 5b 33 39 6d 1b 5b 32 32 6d 20 1b | m....[39m.[22m .
```

The key insight: offset `0000` on the second line shows this is a **new read chunk** starting with `m`.

### dump-raw command

```bash
./zig-out/bin/dullahan dump-raw
```

Shows terminal cells with escape sequences visible:
- `·` = empty cell (NUL)
- `^X` = control character
- `U+XXXX` = Unicode codepoint

## Lessons Learned

1. **Stateful parsers need persistent state** - VT100/ANSI parsing is stateful. Escape sequences can span multiple reads.

2. **PTY read boundaries are unpredictable** - The kernel can return any amount of data per read. Never assume sequence alignment.

3. **Hex dumps are invaluable** - The `debug-capture` tool immediately revealed the split sequence pattern.

4. **The `m` is special** - It terminates the most common escape sequence type (SGR). Any SGR-heavy application will trigger splits at `m`.

5. **Lazy initialization for self-referential structs** - The vt_stream captures a `*Terminal` pointer. If created during `Pane.init()`, the pointer becomes dangling when the Pane is returned (moved). Solution: make it optional and initialize on first use when Pane is at its final location.

## Related Files

- `server/src/pane.zig` - Pane struct with persistent vt_stream
- `server/src/terminal.zig` - Terminal wrapper
- `deps/ghostty/src/terminal/stream.zig` - Parser implementation
- `deps/ghostty/src/terminal/stream_readonly.zig` - Readonly stream handler

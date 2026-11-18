# Zig 0.17 Notes

This documents the move of Dullahan and its `ghostty-vt` dependency from Zig
0.16.0 to Zig 0.17.1. Read `docs/zig-0.16-notes.md` too. It is still the
reference for `std.Io`, files, processes, and clocks. This file lists only what
changed on top of it.

Ghostty `main` moved to Zig 0.17.0 in
`3d07ef9e28c4af05065b9e2e546b8ac8f9b62df0` (2026-10-20) and to Zig 0.17.1 in
`1d8445968` (2026-11-14). The last Ghostty `main` commit that builds with Zig
0.16 is `b58ef1d67`.

Primary sources:

- [Zig 0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html)
- Ghostty migration merge `3d07ef9e2` and its branch commits
  (`git -C deps/ghostty log b58ef1d67..f8d472466`)
- Installed standard library: `zig env` shows `lib_dir`; read `std/` there

---

## Toolchain Lookup

`EXPECTED_ZIG_VERSION` in the `Makefile` is the single version setting for make
targets. The Makefile derives everything else from it:

1. With Nix: `scripts/nix/zig` builds or fetches `"<major>.<minor>"`. The
   vendored expression matches nixpkgs, so Nix normally downloads a cached
   build instead of compiling Zig.
2. Without Nix: `~/zig-*-<version>/` in the home directory. The user installs
   this by hand.
3. Otherwise `zig` on `PATH`. `check-zig` rejects a wrong version.

To bump Zig, change all of these together:

- `Makefile` `EXPECTED_ZIG_VERSION`
- `scripts/update-ghostty.sh` `EXPECTED_ZIG_VERSION`
- `server/build.zig.zon` `.minimum_zig_version`
- `scripts/nix/zig/default.nix`: add the version, its LLVM package, and the
  source hash. Copy them from nixpkgs `pkgs/development/compilers/zig`.

---

## Changes That Broke Dullahan

### `@cImport` is removed

Use the external `translate_c` package. Dullahan pins the same tarball that
Ghostty mirrors (`deps.files.ghostty.org/translate_c-02ff0c5...`).

Each C area has one header under `server/src/c/`. `build.zig` translates each
header into a module:

| Header | Module | Used by |
|---|---|---|
| `src/c/posix.h` | `posix_c` | `pty.zig`, `process.zig`, `ipc_commands.zig` |
| `src/c/openssl.h` | `openssl_c` | `tls_wrapper.zig` |
| generated Wuffs header | `wuffs_c` | `png_decoder.zig` |

Source files use `const c = @import("posix_c");`. To use a new C symbol, add
its `#include` to the right header. Platform choices go in the header with
`#if defined(__APPLE__)`, not in Zig.

The OpenSSL translator receives the same include directory as the compile
modules (`OpenSslPaths` in `build.zig`). That keeps Homebrew prefixes working
on macOS.

`std.Build.Step.TranslateC` (`b.addTranslateC`) still exists but is
deprecated. Do not use it for new code.

### ChainSafe `snappy.zig` wrapper uses `@cImport`

Upstream has no 0.17 fix. Dullahan still links that package's static
`snappy` library. It no longer imports the package's Zig module. Instead,
`src/snappy_c.zig` declares the two C functions Dullahan calls
(`snappy_compress`, `snappy_max_compressed_length`) with `extern "c"`.

### `**` array repetition is removed

```zig
var a = [_]u8{0} ** n;   // old
var a: [n]u8 = @splat(0); // new
```

### Enum integer builtins are renamed

`zig fmt` rewrites these automatically:

```zig
@intFromEnum(e)  // old
@backingInt(e)   // new

@enumFromInt(x)            // old
@fromBackingInt(@intCast(x)) // new; argument must be the exact backing type
```

### Optimize modes are renamed

| Old | New |
|---|---|
| `.Debug` | `.debug` |
| `.ReleaseSafe` | `.safe` |
| `.ReleaseFast` | `.fast` |
| `.ReleaseSmall` | `.small` |

The command-line option follows the same names: `-Doptimize=fast`.

### Type reflection is struct-of-arrays

`std.meta.fields` is a compile error. `@typeInfo(E).@"enum"` has
`field_names` and `field_values` arrays instead of `fields`.

For enum iteration, prefer `std.enums.values(E)` and `@tagName`. For string
lookup, prefer `std.meta.stringToEnum`.

### Standard library renames hit by Dullahan

| Old | New |
|---|---|
| `std.fmt.allocPrint(a, fmt, args)` | `a.print(fmt, args)` |
| `allocator.dupeZ(u8, s)` | `allocator.dupeSentinel(u8, s, 0)` |
| `std.meta.Int(.unsigned, n)` | `@Int(.unsigned, n)` |
| `std.hash.crc.Crc32` | `std.hash.Crc32` |
| `std.builtin` | `std.lang` (old name is a deprecated alias) |
| `builtin.os`, `builtin.cpu`, `builtin.abi` | `builtin.target.os`, `.cpu`, `.abi` (old names removed in 0.18) |
| `BitSet.initEmpty()` | `.empty` |

Other renames from the release notes that Dullahan does not use today:
`std.fmt.bufPrint` → `std.mem.print`, `std.fmt.bufPrintZ` →
`std.mem.printSentinel`, `std.heap.DebugAllocator` → `std.heap.SafeAllocator`,
`stackFallback` → `std.heap.BufferFirstAllocator`,
`std.StaticBitSet` → `std.bit_set.Static`,
`ArrayList.getLast()` → `.last().?`.

### Build script changes

- `b.args` is gone. Use `run_cmd.addPassthruArgs()`.
- `LazyPath.basename` is removed. The old `translate_c` pin used it, so it had
  to move.
- `b.build_root` is now `b.root`, a `Path`.

---

## Silent Semantic Changes

These compile without errors. Audit them by hand.

### `@bitCast` reads logical bits, not memory

`@bitCast` is now endian-agnostic. An integer-to-array cast puts the least
significant bits in element 0 on every host. Before 0.17 it copied memory
order, which differs on big-endian hosts.

Socket addresses are stored in network byte order. Copy them with
`std.mem.toBytes`, as `net_compat.zig` now does. Do not use `@bitCast` for
memory-order copies.

`@bitCast` to or from an `extern struct` or `extern union` is now a compile
error. Casting to an enum is safety-checked.

### `@hasDecl` sees only `pub` declarations

This is true even inside the same file. A check on a private name now returns
false without an error. Dullahan's checks (`OPENSSL_init_ssl`,
`kitty.graphics.Command`) target `pub` declarations, so behavior did not
change.

---

## Ghostty API Changes in This Bump

The pin moved from `661e1e77f` to `f3e1f65bb` (about 1000 commits). The Zig
migration is only part of it. `src/terminal/stream_terminal.zig` is Ghostty's
reference handler. Diff it across the bump and port its routing changes into
`server/src/stream_handler.zig`.

- `Style.Color` is now a `packed struct(u32)`, not a tagged union. Switch on
  `color.value()`.
- `set_attribute` became `set_attributes`. Apply all SGR parameters at once
  with `terminal.setAttributes(value.parser())`.
- Cursor column and row actions call `setCursorCol`, `setCursorRow`,
  `cursorColRelative`, and `cursorRowRelative`. They no longer build a
  `setCursorPos` call by hand.
- `apc_end` carries `terminated`. A cancelled or aborted APC string must still
  call `end()` to free its data, but its command must not run.
- Optional handler hook `vtPrintAscii(bytes)` receives printable ASCII runs as
  bytes, so the stream does not widen them to `u32`.
- New actions: `back_index`, `forward_index` (DECBI/DECFI), `insert_columns`,
  `delete_columns` (DECIC/DECDC), `soft_reset` (DECSTR), `mouse_shape_reset`,
  `osc_unknown`, `resize_window` (CSI 8 t), `program_status` (OSC 7501),
  `request_xt_checksum` and `xt_checksum_extension` (DECRQCRA/XTCHECKSUM).
- Dullahan ignores `resize_window`, because clients own the pane size. It
  ignores `program_status` and claims no support for it. It ignores the
  checksum requests, because Ghostty disables them by default: they let a
  program read screen contents.
- `SizeReportStyle` gained `csi_19_t` (screen size in characters).
- `device_status.Request` gained `cursor_position_extended` (DECXCPR). The
  reply adds page number 1.

---

## Dependency Pins

| Dependency | Pin | Note |
|---|---|---|
| `ghostty` | `f3e1f65bb` | requires Zig 0.17.1 |
| `translate_c` | Ghostty mirror `02ff0c5` | old Codeberg pin fails on 0.17 |
| `zig-msgpack` | `5884caa` | upstream CI tests Zig 0.16.0 and 0.17.0 |
| `snappy` | `7139424` (unchanged) | Zig module unused; see above |

---

## Verification

```bash
make check-zig
make test-server
cd client && bun run typecheck
cd protocol && bun ci && bun test
make build
cd server && zig build -Doptimize=fast
```

Then use a scratch port so that a running server is not disturbed:

```bash
B="server/zig-out/bin/dullahan --port=7799"
$B ping && $B status && $B panes
$B test delta-gen     # rewrites test_fixtures/delta/*.bin
$B test shell-delta
$B test grapheme-test
$B test hyperlink-test
$B quit
```

`ttysize` and `test keytest-*` need a real terminal.

Not yet verified on macOS: OpenSSL translation with Homebrew include paths,
and `posix.h` with `<util.h>`.

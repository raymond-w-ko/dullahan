# Zig 0.16 Notes

This documents Zig 0.16.0 changes relevant to moving Dullahan and its
`ghostty-vt` dependency from Zig 0.15.2.

Zig 0.16.0 was released on 2026-04-14. Ghostty `main` at
`5a35415a5d59a117e654735ca5a01f876dec5841` (checked 2026-07-27) declares
`.minimum_zig_version = "0.16.0"`.

Primary sources:

- [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
- [Zig 0.16.0 language reference](https://ziglang.org/documentation/0.16.0/)
- [Zig 0.16.0 standard library reference](https://ziglang.org/documentation/0.16.0/std/)
- [Zig 0.16.0 source archive](https://ziglang.org/download/0.16.0/zig-0.16.0.tar.xz)
- [Ghostty `build.zig.zon` at researched commit](https://github.com/ghostty-org/ghostty/blob/5a35415a5d59a117e654735ca5a01f876dec5841/build.zig.zon)
- [Ghostty 0.16 entrypoint pattern](https://github.com/ghostty-org/ghostty/blob/5a35415a5d59a117e654735ca5a01f876dec5841/src/main_ghostty.zig)
- [Ghostty 0.16 process-global state pattern](https://github.com/ghostty-org/ghostty/blob/5a35415a5d59a117e654735ca5a01f876dec5841/src/global.zig)

This is a migration guide, not a complete release summary. Prefer compiler
errors and installed 0.16.0 standard library source over memory or old examples.
Run `zig std` for local API docs.

---

## What is Most Surprising

### `std.Io` is now the capability root

This is much larger than the 0.15 Writer/Reader rewrite. Anything that may
block, introduce nondeterminism, or coordinate concurrency generally needs a
`std.Io` value:

- files and directories
- process spawning and waiting
- clocks and sleeping
- entropy
- networking
- mutexes and conditions
- async work and cancellation

`std.Io` is a small interface value containing userdata and a vtable. Copying
the value is cheap. Its backing implementation must outlive every copy.

Library code should accept `io: std.Io`. It should not choose an implementation.
Application entrypoints choose the implementation.

Full `std.process.Init` currently supplies the feature-complete
`std.Io.Threaded` implementation. `std.Io.Evented` is experimental in 0.16 and
does not implement networking. Do not rewrite Dullahan's poll-based event loop
to Evented as part of this migration. Preserve its fd ownership and use the
entrypoint's Threaded interface for ordinary blocking I/O.

### `main()` can no longer discover arguments or environment

An empty `main()` remains legal, but process arguments and environment are no
longer global standard-library APIs. Request them through the entrypoint:

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = init.minimal.args;
    const environ = init.environ_map;
    _ = .{ io, allocator, args, environ };
}
```

Available entrypoint forms:

```zig
pub fn main() !void
pub fn main(init: std.process.Init.Minimal) !void
pub fn main(init: std.process.Init) !void
```

`Init.Minimal` provides raw arguments and environment. Full `Init` additionally
provides a general allocator, process-lifetime arena, `std.Io`, parsed
environment map, and preopened files.

### Tests have their own capabilities

Use:

```zig
const io = std.testing.io;
const allocator = std.testing.allocator;
const environ = std.testing.environ;
```

Do not make tests construct a production `std.Io.Threaded` unless the test is
specifically about that implementation.

### `error.Canceled` now appears widely

Many I/O and synchronization calls are cancellation points. Error sets can gain
`error.Canceled` even when the old operation looked like a simple blocking
syscall. Do not discard it blindly. Either propagate it or deliberately use an
uncancelable API where cancellation would violate an invariant.

### Medium-level POSIX wrappers are being removed, not all of `std.posix`

Do not mechanically replace every `std.posix` use. Zig 0.16 still has useful
typed wrappers such as `read`, `poll`, `setsockopt`, and `kill` on supported
targets. Removed APIs require one of two choices:

- higher level: `std.Io`
- lower level: `std.posix.system`

Dullahan intentionally owns a poll-based PTY/socket event loop. Low-level fd
operations may remain POSIX code. File paths, clocks, sleeping, process
spawning, and ordinary file I/O should generally move to `std.Io`.

### `@cImport` is deprecated, but not removed

It now uses Aro rather than libclang. That compiler swap can expose translation
bugs even though the source migration is optional in 0.16.

Ghostty `main` carries an explicit `translate_c` package because it needs fixes
outside Zig's bundled translator. Treat Dullahan's `@cImport` sites as migration
and verification hotspots.

### Dependency fetching now writes `zig-pkg/` beside `build.zig`

Zig 0.16 fetches package sources into a project-local `zig-pkg` directory before
canonicalizing them into global cache archives. Dullahan already ignores
`server/zig-pkg/`. Do not commit fetched contents.

### Passing tests may still print a failed-command diagnostic

Ghostty notes that Zig 0.16 test execution treats any stderr output as worthy of
a `failed command` diagnostic even when tests pass. Ghostty reduces test log
level to `.err`. Dullahan tests that intentionally log may look failed at first
glance; check final test status.

Dullahan mitigates this in `server/src/dlog.zig`: `mirror_to_stderr` disables
debug-build stderr mirroring under `builtin.is_test`, so a `failed command`
line from `zig build test` now indicates a real failure or an explicit error
log. Check the exit status either way.

---

## Recommended Dullahan Ownership Model

Thread `std.Io` through normal code. Keep one application context rather than
adding unrelated globals:

```zig
const AppContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
};

pub fn main(init: std.process.Init) !void {
    const context: AppContext = .{
        .io = init.io,
        .allocator = init.gpa,
        .environ = init.environ_map,
    };

    try run(&context, init.minimal.args);
}

fn run(context: *const AppContext, args: std.process.Args) !void {
    _ = .{ context, args };
}
```

Good boundaries for an `io` parameter:

```zig
fn loadLayout(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Layout
fn spawnServer(io: std.Io, argv: []const []const u8) !std.process.Child
fn waitForServer(io: std.Io, timeout: std.Io.Duration) !void
```

Avoid storing `std.Io` in every object automatically. Store it in long-lived
owners whose methods perform I/O. Pass it to pure or short-lived helpers.

### Exception: custom logging callback

`std.Options.logFn` keeps its callback signature and does not receive `std.Io`.
Dullahan's `fileLog` opens and writes a log file, so it needs access to a stable
process-global `std.Io`.

Practical pattern:

```zig
var app_io: ?std.Io = null;

pub fn main(init: std.process.Init) !void {
    app_io = init.io;
    defer app_io = null;
    // No application logging before app_io is installed.
    try run(init);
}

fn fileLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = app_io orelse
        std.Io.Threaded.global_single_threaded.io();
    _ = .{ io, level, scope, format, args };
}
```

Ghostty uses the same broad boundary: process-global state owns a long-lived
`std.Io.Threaded`, while most code retrieves a copied `std.Io` interface.

Do not initialize a new threaded implementation per log call. Do not retain
`init.io` beyond process lifetime.

Dullahan's logger needs more than the sample's global `Io`. It currently keeps
only a `File`, seeks once to the end, then performs uncoordinated writes. A
correct 0.16 migration should keep a persistent `std.Io.File.Writer` and its
buffer, seek that writer to `file.length(io)` once, and serialize callback
access. Otherwise concurrent log calls can overlap or corrupt writer state.
Flush each complete record under the same lock if crash-visible logs remain a
requirement. Logging code must not recursively call `std.log` while holding its
own lock. Because `logFn` cannot return `error.Canceled`, use
`lockUncancelable(io)` for this logger lock.

---

## Entrypoint, Arguments, and Environment

### Arguments

Old 0.15:

```zig
var args = std.process.args();
defer args.deinit();
```

New 0.16:

```zig
pub fn main(init: std.process.Init.Minimal) void {
    var args = init.args.iterate();
    while (args.next()) |arg| {
        _ = arg;
    }
}
```

Or allocate one slice:

```zig
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |arg| {
        _ = arg;
    }
}
```

For Dullahan, change `CliArgs.parse(allocator)` to accept `std.process.Args` or
an iterator. Do not let CLI parsing reach back into process-global state.

### Environment

Old:

```zig
const home = std.posix.getenv("HOME");
```

Full `Init`:

```zig
pub fn main(init: std.process.Init) !void {
    const home = init.environ_map.get("HOME");
    _ = home;
}
```

Minimal `Init`:

```zig
pub fn main(init: std.process.Init.Minimal) !void {
    const home = init.environ.getPosix("HOME");
    _ = home;
}
```

`getPosix` is the allocation-free POSIX path. Use `getAlloc` or build a map
when code must work with Windows' environment representation.

`std.process.Environ.Map` owns copied keys and values through its allocator.
`std.process.Environ` represents OS-provided environment data. Pass only the
form a helper needs.

Dullahan changes:

- `debug_config.loadFromEnv` should accept the needed value or environment.
- `paths.getConfigDir` should accept `HOME` or a process environment handle.
- `test_diagnostics` should not call `std.posix.getenv`.
- child process spawning should pass an environment map only when replacing or
  modifying the inherited environment.

---

## Files and Directories

Core type moves:

```zig
std.fs.Dir   // old
std.Io.Dir   // new

std.fs.File  // old
std.Io.File  // new
```

Opening, creating, closing:

```zig
const cwd = std.Io.Dir.cwd();

var input = try cwd.openFile(io, "input.txt", .{});
defer input.close(io);

var output = try cwd.createFile(io, "output.txt", .{});
defer output.close(io);
```

Absolute operations are static functions:

```zig
var file = try std.Io.Dir.openFileAbsolute(io, absolute_path, .{});
defer file.close(io);

try std.Io.Dir.accessAbsolute(io, absolute_path, .{});
```

Common mappings:

- `std.fs.cwd()` becomes `std.Io.Dir.cwd()`
- `dir.makeDir(...)` becomes `dir.createDir(io, ...)`
- `dir.makePath(...)` becomes `dir.createDirPath(io, ...)`
- `std.fs.openFileAbsolute(...)` becomes
  `std.Io.Dir.openFileAbsolute(io, ...)`
- `std.fs.createFileAbsolute(...)` becomes
  `std.Io.Dir.createFileAbsolute(io, ...)`
- `file.close()` becomes `file.close(io)`
- `std.fs.selfExePath(...)` becomes `std.process.executablePath(io, ...)`
- `std.fs.max_path_bytes` is deprecated in favor of
  `std.Io.Dir.max_path_bytes`

### Reading a complete file

Old:

```zig
const data = try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
```

New:

```zig
const data = try std.Io.Dir.cwd().readFileAlloc(
    io,
    path,
    allocator,
    .limited(max_bytes),
);
```

Limit semantics changed. Reaching or exceeding the limit returns
`error.StreamTooLong`, replacing the old `error.FileTooBig` behavior.

For an already-open file:

```zig
var file_reader = file.reader(io, &.{});
const data = try file_reader.interface.allocRemaining(
    allocator,
    .limited(max_bytes),
);
```

`File.Reader` stores detailed read errors. Its generic `interface` may report
`error.ReadFailed`; inspect `file_reader.err` when translating diagnostics.

### Writing a complete slice

For one complete unformatted write:

```zig
try file.writeStreamingAll(io, bytes);
```

For formatted or buffered writes:

```zig
var buffer: [4096]u8 = undefined;
var file_writer = file.writer(io, &buffer);
const writer = &file_writer.interface;

try writer.print("pane={d}\n", .{pane_id});
try writer.flush();
```

`File.Writer` stores detailed errors in fields such as `err`; its generic
`interface` reports `error.WriteFailed`. This error erasure is intentional.

Use `writerStreaming` for pipes, sockets exposed as files, terminals, or cases
where positional writes are known to be wrong:

```zig
var file_writer = file.writerStreaming(io, &buffer);
```

### Standard streams

Direct complete write:

```zig
try std.Io.File.stdout().writeStreamingAll(io, "hello\n");
```

Formatted output:

```zig
var buffer: [1024]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
const stdout = &stdout_writer.interface;

try stdout.print("pane={d}\n", .{pane_id});
try stdout.flush();
```

`std.debug.print` still exists as a debugging escape hatch. Do not use its
existence as a reason to avoid proper `std.Io` plumbing in application code.

---

## Reader and Writer Changes

`std.io` becomes `std.Io`.

Removed:

- `GenericReader`
- `GenericWriter`
- `AnyReader`
- `AnyWriter`
- `FixedBufferStream`
- `null_writer`
- `CountingReader`

### Fixed buffer writing

Old:

```zig
var stream = std.io.fixedBufferStream(&buffer);
const writer = stream.writer();
try writer.writeAll(bytes);
const written = stream.getWritten();
```

New:

```zig
var writer: std.Io.Writer = .fixed(&buffer);
try writer.writeAll(bytes);
const written = writer.buffered();
```

A fixed writer returns `error.WriteFailed` when full. It does not partially
succeed with a byte count in the old `FixedBufferStream` style. It may still
fill all remaining buffer space before returning the error; failure does not
roll the buffer back.

### Fixed buffer reading

Old:

```zig
var stream = std.io.fixedBufferStream(data);
const reader = stream.reader();
```

New:

```zig
var reader: std.Io.Reader = .fixed(data);
```

### Formatting

`std.fmt.format` moves to `std.Io.Writer.print`. Custom formatters now use the
`{f}` path and write to `*std.Io.Writer`.

The `{D}` duration specifier is removed:

```zig
try writer.print("{f}", .{
    std.Io.Duration.fromMilliseconds(250),
});
```

`std.fmt.bufPrint` remains useful for fixed, all-or-nothing formatting where no
I/O capability is needed.

### zig-msgpack compatibility

Do not trust one compatibility shim as proof that a dependency supports 0.16.
Dullahan's old `zig-msgpack` pin had an explicit 0.16 `BufferStream`, but other
source still initialized unmanaged `std.ArrayList` values with `.{}`. Zig 0.16
requires `.empty`. Current upstream `main` fixes both areas, so this migration
also moved the pin to `e5d5f8604cf7aa50593df8e450686a269a7299c6`.

Pinned source:
[zig-msgpack `compat.zig`](https://github.com/zigcc/zig-msgpack/blob/e5d5f8604cf7aa50593df8e450686a269a7299c6/src/compat.zig)

---

## Time, Sleeping, and Entropy

### Wall-clock time

Old:

```zig
const seconds = std.time.timestamp();
const millis = std.time.milliTimestamp();
```

New:

```zig
const now = std.Io.Timestamp.now(io, .real);
const seconds = now.toSeconds();
const millis = now.toMilliseconds();
```

### Monotonic time

Use `.awake` for elapsed time that should exclude system suspend:

```zig
const start = std.Io.Timestamp.now(io, .awake);
// work
const elapsed = start.untilNow(io, .awake);
```

Use `.boot` when suspended time should count. Do not use `.real` for elapsed
timeouts because wall clock can jump.

`std.time.Instant` and `std.time.Timer` are replaced by
`std.Io.Timestamp`-based patterns.

### Sleeping

Old:

```zig
std.Thread.sleep(100 * std.time.ns_per_ms);
```

New:

```zig
try io.sleep(.fromMilliseconds(100), .awake);
```

Sleep is now cancelable. Functions that cannot safely return midway may use an
uncancelable higher-level design or explicitly handle `error.Canceled`.

### Randomness

Old:

```zig
std.crypto.random.bytes(&buffer);
```

New:

```zig
io.random(&buffer);
```

`io.random` may keep CSPRNG state in process memory. `io.randomSecure` obtains
fresh entropy outside process state and can return `error.EntropyUnavailable`.

Dullahan token generation should decide which contract it needs. Authentication
tokens probably want cryptographic randomness, but `io.random` is still
cryptographically secure to the degree promised by the selected `Io`
implementation. Use `randomSecure` only when avoiding stored RNG state is a
named requirement.

---

## Process Spawning

`std.process.Child.init` plus mutable behavior fields is replaced by a single
spawn options value.

Old:

```zig
var child = std.process.Child.init(argv, allocator);
child.stdin_behavior = .Ignore;
child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;
try child.spawn();
const term = try child.wait();
```

New:

```zig
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .ignore,
    .stdout = .inherit,
    .stderr = .inherit,
});
defer child.kill(io);

const term = try child.wait(io);
```

Capturing a complete child result:

```zig
const result = try std.process.run(allocator, io, .{
    .argv = argv,
    .stdout_limit = .limited(1024 * 1024),
    .stderr_limit = .limited(1024 * 1024),
});
defer allocator.free(result.stdout);
defer allocator.free(result.stderr);
```

Do not create stdout/stderr pipes and immediately call `wait`. A child can block
when either pipe fills, leaving the parent blocked in `wait`. Drain both streams
concurrently, use `std.Io.File.MultiReader`, or use `std.process.run` for bounded
complete capture. Dullahan's current `Session.runCommand` drains stdout fully
before stderr, which has the same deadlock risk and should be fixed during this
migration.

Other mappings:

- `std.process.Child.run(...)` becomes `std.process.run(...)`
- `std.process.execv(...)` becomes `std.process.replace(...)`
- `std.fs.selfExePath(...)` becomes `std.process.executablePath(io, ...)`
- `child.wait()` becomes `child.wait(io)`
- `child.kill()` becomes `child.kill(io)`

Review background spawning carefully. A returned `Child` owns process and pipe
handles. Dullahan currently launches a detached-looking child and drops its
value. Confirm 0.16 lifetime and zombie behavior on each supported OS instead of
assuming drop means detach.

Dullahan also installs `SIGCHLD` as ignored with `SA_NOCLDWAIT`. That policy
conflicts with code that expects `std.process.Child.wait` to reap and report a
status. Choose one process-ownership model before converting child calls:

- globally auto-reaped shell children with no later `wait`, or
- explicitly owned `Child` values with `wait(io)`/`kill(io)`.

Do not retain global auto-reaping while assuming every `std.process` wait will
work. Existing Tailscale fallback reaping and PTY `waitpid` workarounds are
evidence of this conflict.

---

## Synchronization and Concurrency

Blocking synchronization moves from `std.Thread` to `std.Io`:

- `std.Thread.Mutex` becomes `std.Io.Mutex`
- `std.Thread.Condition` becomes `std.Io.Condition`
- `std.Thread.RwLock` becomes `std.Io.RwLock`
- `std.Thread.Semaphore` becomes `std.Io.Semaphore`
- `std.Thread.ResetEvent` becomes `std.Io.Event`
- `std.Thread.WaitGroup` becomes `std.Io.Group`
- `std.Thread.Futex` becomes `std.Io.Futex`
- `std.Thread.Pool` is removed
- `std.once` is removed

Mutex example:

```zig
var mutex: std.Io.Mutex = .init;

try mutex.lock(io);
defer mutex.unlock(io);
```

Normal lock is a cancellation point. For state transitions that cannot be
abandoned:

```zig
mutex.lockUncancelable(io);
defer mutex.unlock(io);
```

Lock-free atomics do not require `std.Io`.

Dullahan's `debug_config.config_mutex` is a migration decision, not a rename
only. Either thread `io` into configuration access, use uncancelable locking
with a stable application `io`, or replace this tiny global lock with a
well-reviewed atomic/spin design.

`std.heap.ArenaAllocator` is now thread-safe and lock-free.
`std.heap.ThreadSafeAllocator` is removed.

---

## Build System Changes

### Build scripts also need `std.Io`

`build.zig` receives the build runner's capability through `b.graph.io`.

Dullahan's current helper:

```zig
fn pathExists(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
```

0.16 pattern:

```zig
fn pathExists(b: *std.Build, path: []const u8) bool {
    if (!std.Io.Dir.path.isAbsolute(path)) return false;
    std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch return false;
    return true;
}
```

Then pass `b` from `resolveOpenSslPrefix` and `linkOpenSsl`.

Do not construct a separate `std.Io.Threaded` inside `build.zig`. Use the build
runner's `b.graph.io`.

### Local package overrides

New command:

```bash
zig build --fork=/path/to/local/package
```

Matching uses package `name` plus `fingerprint`, ignores version, and applies
across the dependency graph. This is ideal for iterating on a local Ghostty
checkout during the migration without temporarily rewriting the dependency URL.

For Dullahan:

```bash
cd server
zig build --fork=../deps/ghostty
```

Zig errors when the package identity does not match and prints a notice when an
override matched. `deps/ghostty/` is reference source only; the real normal-build
pin remains `server/build.zig.zon`.

### Project-local package staging

Fetched dependencies appear under `server/zig-pkg/`. Existing `.gitignore`
already covers this.

Legacy package hash format is removed. Updating Ghostty may require accepting a
new hash printed by Zig even when URL syntax is otherwise unchanged.

### Test timeouts

```bash
zig build test --test-timeout 30s
```

Timeout is per Zig `test` block and uses real time. Allow margin on loaded CI
hosts.

### Error presentation

Useful flags:

```bash
zig build --error-style minimal
zig build --error-style verbose
zig build --multiline-errors indent
zig build -fincremental --watch
```

Incremental compilation is improved but still disabled by default and still has
known bugs. Never use success under incremental mode as sole release proof.

### Temporary build files

`Build.makeTempPath` and the RemoveDir step are removed. Use:

- `Build.addTempFiles`
- `Build.addMutateFiles`
- `Build.tmpPath`

This does not appear in Dullahan's current build script but may appear in a
dependency.

---

## C Translation

Current Dullahan `@cImport` sites include:

- `server/src/pty.zig`
- `server/src/png_decoder.zig`
- `server/src/ipc_commands.zig`
- `server/src/process.zig`

`@cImport` still compiles in 0.16, now through Aro. Lowest-risk migration:

1. Keep each existing `@cImport`.
2. Compile and test on Linux and macOS.
3. Separate translator regressions from Dullahan source errors.
4. Move imports into `build.zig` only after behavior is stable.

Build-system translation pattern:

```zig
const translated = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});

const c_module = translated.createModule();
dullahan_mod.addImport("platform_c", c_module);
```

Zig source then uses:

```zig
const c = @import("platform_c");
```

Ghostty's explicit `translate_c` dependency is a warning: bundled Aro support
may not handle every header set Ghostty needs. Do not copy Ghostty's package
into Dullahan unless a Dullahan translation bug proves it necessary.

---

## Language Changes

### `@Type` is removed

Eight focused builtins replace type reification through `@Type`:

- `@EnumLiteral`
- `@Int`
- `@Tuple`
- `@Pointer`
- `@Fn`
- `@Struct`
- `@Union`
- `@Enum`

Example:

```zig
const Word = @Int(.unsigned, 32);
const Pair = @Tuple(&.{ u16, u16 });
```

Dullahan uses `@TypeOf`, not `@Type`, in the current source audit. Do not
confuse them; `@TypeOf` remains.

### Runtime vector indexes are forbidden

Vector indexing now requires a comptime-known index. For runtime iteration,
coerce the vector to an array first:

```zig
const info = @typeInfo(@TypeOf(vector)).vector;
const array: [info.len]info.child = vector;
for (array) |element| {
    _ = element;
}
```

### Arrays and vectors no longer support in-memory coercion

Do not `@ptrCast` between array storage and vector storage. Use value coercion.
For error unions, unwrap before array/vector coercion.

### Returning a trivial local address is rejected

Obvious forms of returning a pointer to a local variable now fail at compile
time. This catches a bug, not a pattern needing a workaround. Return by value,
allocate with explicit ownership, or let the caller supply storage.

### Packed ABI rules are stricter

- Packed unions may not leave unused backing bits.
- Pointers are forbidden inside packed structs and packed unions.
- Extern use of enums and packed types requires explicit backing integer types.

Example:

```zig
const Mode = enum(u8) {
    normal,
    alternate,
};

const Bits = packed struct(u16) {
    low: u8,
    high: u8,
};
```

Dullahan's current source has no packed structs or unions. Recheck generated
Ghostty types and C-facing dependency types after the pin update.

### Float conversions changed

Small integer types can coerce to floats when every value is exactly
representable. `@floor`, `@ceil`, `@round`, and `@trunc` can now produce integer
results when result type requires it. `@intFromFloat` is deprecated because
`@trunc` covers truncating integer conversion.

Be explicit at protocol and pixel boundaries even when coercion is accepted.

### Type resolution changed

Type resolution is generally more permissive, but some new dependency loops are
possible. Compiler diagnostics now show the cycle. Break a real dependency
instead of rearranging declarations randomly.

Explicitly aligned pointer types are now distinct from naturally aligned
pointer types, although coercions between compatible forms remain.

Zero-bit tuple fields are no longer implicitly marked `comptime`, though their
values remain comptime-known.

### Switch changes

Packed structs and unions can be switch prong items. Union tag captures no
longer require `inline`. A switch whose every prong capture is discarded is now
rejected; remove the capture.

---

## Compiler and Toolchain Changes Worth Measuring

The compiler now lowers by-value expressions by reference until the final load.
This fixes old surprising aliasing and array-access performance bugs. Do not
preserve a 0.15 workaround until a focused 0.16 test proves it is still needed.

LLVM moves to 21.1.0, but Zig 0.16 disables LLVM loop vectorization to avoid a
known miscompilation. Release builds can regress on loop-heavy code even when
source is unchanged. Benchmark terminal cell transforms, snapshot encoding,
Snappy, and image paths before and after the upgrade.

The self-hosted x86 backend remains the default for Debug builds. ELF linking
and incremental compilation changed substantially. When a Debug-only link or
runtime failure appears, rerun with the LLVM backend before deciding whether
the bug is in Dullahan.

Incremental compilation remains opt-in and has known miscompilations. Always
repeat final proof without `-fincremental`.

---

## Standard Library Cleanup

Removed or renamed items likely to surface through dependencies:

- `SegmentedList` removed
- `meta.declList` removed
- `Thread.Mutex.Recursive` removed
- `ArrayHashMap`, `AutoArrayHashMap`, and `StringArrayHashMap` removed
- unmanaged array hash maps moved under `std.array_hash_map`
- `fmt.Formatter` renamed to `fmt.Alt`
- `fmt.FormatOptions` renamed to `fmt.Options`
- `fmt.bufPrintZ` renamed to `fmt.bufPrintSentinel`
- `BitSet.initEmpty` and `EnumSet.initEmpty` replaced by declaration literals
- environment error renamed from `EnvironmentVariableNotFound` to
  `EnvironmentVariableMissing`
- cross-filesystem rename errors converge on `error.CrossDevice`

Priority queue methods now use `push` and `pop` naming. Default initialization
uses `.empty`.

---

## Dullahan Migration Map

This list comes from a static audit before changing the Ghostty pin.

### Entrypoint and global capability ownership

- `server/src/main.zig`
  - change `main()` to accept `std.process.Init`
  - install stable `std.Io` before logging
  - decide whether to use `init.gpa` or retain a manually owned allocator
  - migrate log file, timestamp, process spawn, token file read, and sleeps
- `server/src/cli.zig`
  - accept `std.process.Args`
  - migrate executable path, process spawn, sleeps, and ordinary stdin reading

### Environment

- `server/src/debug_config.zig`
- `server/src/paths.zig`
- `server/src/test_diagnostics.zig`
- `server/src/shell.zig`
- `server/src/tailscale.zig`

Pass environment data from the entrypoint. Avoid replacement globals.

### Filesystem and ordinary files

- `server/src/main.zig`
- `server/src/pane.zig`
- `server/src/ipc.zig`
- `server/src/layout_db.zig`
- `server/src/message_handlers.zig`
- `server/src/shell.zig`
- `server/src/server.zig`
- `server/src/pty_log.zig`
- `server/src/test_diagnostics.zig`
- `server/src/test_runners.zig`
- `server/src/verification_harness.zig`
- query trace and parser matrix runners
- image test utilities
- `scripts/generate-ghostty-terminfo.zig`

Expect type renames, an added `io` argument on open/close/read/write, and new
Reader/Writer wrapper ownership.

### Fixed readers, writers, and formatting

- `server/src/debug_config.zig`
- `server/src/pane.zig`
- `server/src/shell.zig`
- `server/src/stream_handler.zig`
- `server/src/test_runners.zig`
- `server/src/pty_log.zig`

Replace `fixedBufferStream`, preserve overflow behavior intentionally, and keep
concrete `File.Reader`/`File.Writer` wrappers alive as long as their interface
pointers are used.

### Time and sleeping

- `server/src/pane.zig`
- `server/src/cli.zig`
- `server/src/ipc_commands.zig`
- `server/src/process.zig`
- `server/src/client_state.zig`
- `server/src/event_loop.zig`
- `server/src/clipboard.zig`
- `server/src/pty_log.zig`
- `server/src/test_diagnostics.zig`
- `server/src/verification_harness.zig`

Use `.real` for log timestamps, `.awake` for elapsed time and retry sleeps.

### Entropy

- `server/src/server.zig`
- `server/src/http.zig`

Pass `io` into authentication-token and random-ID generation. Preserve explicit
security limits and test deterministic logic separately from entropy acquisition.

### Process spawning

- `server/src/main.zig`
- `server/src/cli.zig`
- `server/src/session.zig`
- `server/src/tailscale.zig`
- `server/src/os_name.zig`

Replace mutable `Child` configuration with `std.process.spawn` options. Review
detached child lifetime, dual-pipe draining, and global `SIGCHLD` auto-reaping
together.

### Synchronization

- `server/src/debug_config.zig`
- `server/src/pty_log.zig`

Replace `std.Thread.Mutex` deliberately. Logger state must remain serialized.
More synchronization sites may arrive through updated Ghostty source.

### POSIX and C boundaries

- PTY and signal modules
- HTTP/WebSocket socket setup
- event loop and IPC socket code
- `waitpid` workaround
- terminal size ioctl imports

Do not blanket-convert these. Preserve low-level event-loop semantics first.
For each compiler error, choose `std.Io`, retained `std.posix`, or raw
`std.posix.system` based on abstraction ownership.

Known current calls likely to lose their typed wrapper include `posix.write`,
`posix.close`, `posix.fcntl`, and `posix.waitpid`. By contrast, 0.16 retains
typed `posix.read`, `posix.poll`, `posix.setsockopt`, and `posix.kill` on
supported targets. Raw `std.posix.system` calls return OS-style values; add
explicit errno handling rather than mechanically dropping `catch`.

An owned fd can be represented as `std.Io.File`, but its `.flags.nonblocking`
field must match the descriptor and exactly one owner may close it. Do not wrap
an fd temporarily, call `File.close(io)`, then also close the original fd.

### Ghostty `main` API changes encountered

These are Ghostty changes at the researched commit, not Zig language changes.
They arrived with the 0.16 migration and compiler errors alone do not explain
their semantics:

- `Terminal.init` now takes `io` before the allocator.
- `Terminal.Options.max_scrollback` became `max_scrollback_bytes`; Ghostty also
  supports `max_scrollback_lines`.
- `Terminal.resize(allocator, cols, rows)` became
  `Terminal.resize(allocator, .{ .cols = cols, .rows = rows })`.
- `Terminal.kittyGraphics` now takes `io`.
- VT streams can emit `.apc_put_slice`; handlers must feed `value.bytes` into
  the same APC accumulator used by `.apc_put`, or split Kitty graphics payloads
  are lost.
- `PageList.Node.data` is no longer direct page storage. Use `node.page()` while
  obeying Ghostty pin/lifetime rules.
- Read cell codepoints with `cell.codepoint()` instead of reaching through
  `cell.content.codepoint`.
- `PageList.maxSize()` was removed when byte and line limits were unified.
  Public runtime mutators are `setMaxBytes` and `setMaxLines`; tests should not
  inspect the private limit representation.
- Reset generation tracking now uses `page_serial_epoch` rather than
  `page_serial_min`. Consumers using page serials to invalidate caches must
  include the epoch.

### Build and dependencies

- `server/build.zig`
  - use `b.graph.io` for OpenSSL path probes
- `server/build.zig.zon`
  - set minimum Zig version to 0.16.0 with Ghostty pin
  - accept new dependency hashes only after verifying resolved source
- pinned `zig-msgpack`
  - use current upstream commit; old pin's partial compatibility layer was not enough
- pinned Snappy wrapper
  - use current upstream commit; minimum version metadata alone is not proof of 0.16 compatibility
- Wuffs
  - C source, but build and translated bindings still need verification

---

## Recommended Upgrade Order

1. Record exact Ghostty `main` commit and inspect its `build.zig.zon`.
2. Run `make update-ghostty`; do not hand-edit the normal Ghostty bump.
3. Inspect the resulting `server/build.zig.zon`, exact commit, minimum Zig
   version, dependency hash, and refreshed `deps/ghostty/` checkout.
4. Set Dullahan's root `.minimum_zig_version` to `"0.16.0"`; the update script
   changes the dependency pin, not this project requirement.
5. Fix `server/build.zig` with `b.graph.io`.
6. Change executable entrypoint to `std.process.Init`; establish one `Io`
   ownership path.
7. Migrate arguments and environment.
8. Resolve child ownership and `SIGCHLD` policy before converting waits.
9. Migrate ordinary filesystem, process, clock, sleep, entropy, and lock APIs.
10. Migrate fixed readers/writers and custom logging.
11. Address retained POSIX and `@cImport` errors individually.
12. Fix Ghostty API changes only after Dullahan compiles against Zig 0.16
    standard library.
13. Verify direct server tests, protocol tests, client typecheck, full build,
    and runtime IPC.
14. Verify Linux and macOS C translation and PTY behavior.

Do not mix Ghostty behavior changes with speculative cleanup until first
0.16-compatible build exists. Small nearby refactors are fine after compiler
errors identify real ownership boundaries.

---

## Compile-Error Dictionary

### `root source file struct 'fs' has no member named ...`

Look under `std.Io.Dir`, `std.Io.File`, or `std.process`. Add the existing
application `io`; do not create one locally.

### `root source file struct 'process' has no member named 'args'`

Accept `std.process.Init` or `Init.Minimal` in `main`, then pass
`init.minimal.args` or `init.args`.

### Environment lookup API missing

Use entrypoint-provided `Environ` or `Environ.Map`. Refactor helper input.

### Expected `std.Io` argument

Thread the caller's capability downward. Tests use `std.testing.io`. Build
scripts use `b.graph.io`.

### `error.Canceled` not handled

Propagate it or use an uncancelable operation only where interruption would
break an invariant.

### `error.ReadFailed` or `error.WriteFailed`

Generic interface erased detailed error. Inspect owning `File.Reader` or
`File.Writer` state.

### Missing `FixedBufferStream`

Use `std.Io.Reader.fixed(data)` or `std.Io.Writer.fixed(buffer)`.

### Missing `std.Thread.Mutex`

Use `std.Io.Mutex` and supply `io`, or redesign as lock-free state.

### Missing `std.process.Child.init`

Use `std.process.spawn(io, options)`.

### Missing `std.posix.write`, `close`, `fcntl`, or `waitpid`

Choose a higher-level `std.Io` operation or call `std.posix.system` with
explicit return-value and errno handling. Do not assume the old error-union
contract survives.

### C translation fails inside formerly working `@cImport`

Suspect Aro translation difference. Reduce header input, compare Ghostty's
external `translate_c` package, and report an upstream bug when valid C stopped
translating.

### Dependency loop appears after upgrade

Read the full cycle diagnostic. Break one semantic dependency. Do not assume
declaration reordering fixes it.

### Tests pass but output includes `failed command`

Check stderr output and final test summary. Reduce test log verbosity where
noise is expected.

---

## Verification Checklist for the Later Ghostty Upgrade

```bash
zig version
cd server && zig build test
cd ../client && bun run typecheck
cd ../protocol && bun test
cd .. && make build
```

Then run focused behavior checks:

```bash
./zig-out/bin/dullahan ping
./zig-out/bin/dullahan status
./zig-out/bin/dullahan test delta-gen
./zig-out/bin/dullahan test shell-delta
./zig-out/bin/dullahan test grapheme-test
./zig-out/bin/dullahan test hyperlink-test
```

Also verify:

- server auto-spawn and background child lifetime
- IPC socket cleanup
- PTY resize, read, write, and child reaping
- WebSocket keepalive and timeout setup
- log file creation and append behavior
- `DULLAHAN_DEBUG` and `HOME` lookup
- authentication token entropy and token file writes
- snapshot/msgpack limits and malformed input
- PNG decoding through Wuffs
- OpenSSL discovery on macOS and Linux
- `@cImport` output on every supported target
- no tracked `server/zig-pkg/` files

Zig's own release notes explicitly warn that 0.16 contains known bugs,
miscompilations, and regressions. A clean compile is necessary, not sufficient.
Keep runtime protocol tests and cross-platform builds in final proof.

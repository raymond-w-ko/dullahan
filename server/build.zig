const std = @import("std");

const wuffs_defines = [_][]const u8{
    "WUFFS_CONFIG__MODULES",
    "WUFFS_CONFIG__MODULE__AUX__BASE",
    "WUFFS_CONFIG__MODULE__AUX__IMAGE",
    "WUFFS_CONFIG__MODULE__BASE",
    "WUFFS_CONFIG__MODULE__ADLER32",
    "WUFFS_CONFIG__MODULE__CRC32",
    "WUFFS_CONFIG__MODULE__DEFLATE",
    "WUFFS_CONFIG__MODULE__PNG",
    "WUFFS_CONFIG__MODULE__ZLIB",
};

const wuffs_c_header = wuffs_c_header: {
    const include = "#include <wuffs-v0.4.c>";
    const len = len: {
        var len: usize = 0;
        for (wuffs_defines) |define| len += std.fmt.count("#define {s}\n", .{define});
        len += std.fmt.count("{s}\n", .{include});
        break :len len;
    };

    var buffer: [len:0]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (wuffs_defines) |define| writer.print("#define {s}\n", .{define}) catch unreachable;
    writer.print("{s}\n", .{include}) catch unreachable;
    buffer[len] = 0;
    break :wuffs_c_header buffer;
};

fn pathExists(b: *std.Build, path: []const u8) bool {
    if (!std.Io.Dir.path.isAbsolute(path)) return false;
    std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch return false;
    return true;
}

fn resolveOpenSslPrefix(b: *std.Build, openssl_dir: ?[]const u8) ?[]const u8 {
    if (openssl_dir) |dir| return dir;

    const candidates = [_][]const u8{
        "/opt/homebrew/opt/openssl@3",
        "/usr/local/opt/openssl@3",
        "/opt/homebrew/opt/openssl@1.1",
        "/usr/local/opt/openssl@1.1",
    };

    for (candidates) |prefix| {
        const header = b.pathJoin(&.{ prefix, "include", "openssl", "ssl.h" });
        if (pathExists(b, header)) return prefix;
    }

    return null;
}

const OpenSslPaths = struct {
    include_dir: ?[]const u8 = null,
    lib_dir: ?[]const u8 = null,

    fn resolve(
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        openssl_dir: ?[]const u8,
        openssl_include_dir: ?[]const u8,
        openssl_lib_dir: ?[]const u8,
    ) OpenSslPaths {
        var include_dir = openssl_include_dir;
        var lib_dir = openssl_lib_dir;

        if (openssl_dir) |prefix| {
            if (include_dir == null) include_dir = b.pathJoin(&.{ prefix, "include" });
            if (lib_dir == null) lib_dir = b.pathJoin(&.{ prefix, "lib" });
        }

        if (target.result.os.tag == .macos) {
            if (include_dir == null or lib_dir == null) {
                if (resolveOpenSslPrefix(b, openssl_dir)) |prefix| {
                    if (include_dir == null) include_dir = b.pathJoin(&.{ prefix, "include" });
                    if (lib_dir == null) lib_dir = b.pathJoin(&.{ prefix, "lib" });
                }
            }
        }

        return .{
            .include_dir = if (include_dir) |path| (if (pathExists(b, path)) path else null) else null,
            .lib_dir = if (lib_dir) |path| (if (pathExists(b, path)) path else null) else null,
        };
    }

    fn link(paths: OpenSslPaths, module: *std.Build.Module) void {
        if (paths.include_dir) |path| module.addIncludePath(.{ .cwd_relative = path });
        if (paths.lib_dir) |path| module.addLibraryPath(.{ .cwd_relative = path });
        module.linkSystemLibrary("ssl", .{ .use_pkg_config = .yes });
        module.linkSystemLibrary("crypto", .{ .use_pkg_config = .yes });
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const openssl_dir = b.option(
        []const u8,
        "openssl-dir",
        "Path to OpenSSL prefix (e.g. /opt/homebrew/opt/openssl@3)",
    );
    const openssl_include_dir = b.option(
        []const u8,
        "openssl-include-dir",
        "Path to OpenSSL headers (contains openssl/ssl.h)",
    );
    const openssl_lib_dir = b.option(
        []const u8,
        "openssl-lib-dir",
        "Path to OpenSSL libraries (contains libssl)",
    );

    const openssl = OpenSslPaths.resolve(b, target, openssl_dir, openssl_include_dir, openssl_lib_dir);

    // Create a module for the core library (can be imported by tests and exe)
    const dullahan_mod = b.addModule("dullahan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add ghostty-vt dependency (lazy so it's only fetched when needed)
    // MUST pass optimize to disable slow_runtime_safety checks in release builds!
    if (b.lazyDependency("ghostty", .{
        .optimize = optimize,
        .@"emit-lib-vt" = true,
    })) |ghostty_dep| {
        const ghostty_vt = ghostty_dep.module("ghostty-vt");
        dullahan_mod.addImport("ghostty-vt", ghostty_vt);
    }

    // Zig 0.17 removed @cImport. C headers are translated here with the
    // external translate_c package and imported as ordinary modules.
    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;
    const translate_c_dep = b.lazyDependency("translate_c", .{}) orelse return;

    const posix_c: translate_c.Translator = .init(translate_c_dep, .{
        .name = "posix_c",
        .c_source_file = b.path("src/c/posix.h"),
        .target = target,
        .optimize = optimize,
    });
    dullahan_mod.addImport("posix_c", posix_c.mod);

    const openssl_c: translate_c.Translator = .init(translate_c_dep, .{
        .name = "openssl_c",
        .c_source_file = b.path("src/c/openssl.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{
            .{ .name = "ssl", .options = .{ .use_pkg_config = .yes } },
            .{ .name = "crypto", .options = .{ .use_pkg_config = .yes } },
        },
    });
    if (openssl.include_dir) |path| openssl_c.addIncludePath(.{ .cwd_relative = path });
    dullahan_mod.addImport("openssl_c", openssl_c.mod);

    if (b.lazyDependency("wuffs", .{})) |wuffs_dep| {
        const wuffs_c: translate_c.Translator = .init(translate_c_dep, .{
            .name = "wuffs_c",
            .c_source_file = b.addWriteFiles().add("wuffs_c.h", &wuffs_c_header),
            .target = target,
            .optimize = optimize,
        });
        wuffs_c.addIncludePath(wuffs_dep.path("release/c"));
        dullahan_mod.addImport("wuffs_c", wuffs_c.mod);

        // ghostty-vt supplies the matching Wuffs C implementation.
        // Compiling it again here produces duplicate symbols.
    }

    // Add zig-msgpack dependency for binary serialization
    if (b.lazyDependency("zig-msgpack", .{})) |msgpack_dep| {
        const msgpack = msgpack_dep.module("msgpack");
        dullahan_mod.addImport("msgpack", msgpack);
    }

    // Add snappy dependency for compression.
    // Pass target/optimize so the C++ library builds correctly.
    // Only the static library is used: its Zig wrapper module still uses
    // @cImport, so src/snappy_c.zig declares the C functions instead.
    if (b.lazyDependency("snappy", .{
        .target = target,
        .optimize = optimize,
    })) |snappy_dep| {
        dullahan_mod.linkLibrary(snappy_dep.artifact("snappy"));
    }

    // Executable
    const exe = b.addExecutable(.{
        .name = "dullahan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dullahan", .module = dullahan_mod },
            },
        }),
    });

    exe.root_module.link_libc = true;
    openssl.link(exe.root_module);

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    // ============================================================
    // Tests
    // ============================================================

    // Test the library module
    const mod_tests = b.addTest(.{
        .root_module = dullahan_mod,
    });
    mod_tests.root_module.link_libc = true;
    openssl.link(mod_tests.root_module);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test the executable's root module
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.root_module.link_libc = true;
    openssl.link(exe_tests.root_module);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Integration tests (separate test/ directory)
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dullahan", .module = dullahan_mod },
            },
        }),
    });
    integration_tests.root_module.link_libc = true;
    openssl.link(integration_tests.root_module);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // `zig build test` runs all tests (unit + integration)
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // `zig build test-bin` installs test binary for coverage tools (kcov)
    const test_bin_step = b.step("test-bin", "Build test binary for coverage");
    const install_test = b.addInstallArtifact(mod_tests, .{ .dest_sub_path = "test" });
    test_bin_step.dependOn(&install_test.step);

    // `zig build test-unit` runs only unit tests
    const unit_test_step = b.step("test-unit", "Run unit tests only");
    unit_test_step.dependOn(&run_mod_tests.step);
    unit_test_step.dependOn(&run_exe_tests.step);

    // `zig build test-integration` runs only integration tests
    const integration_test_step = b.step("test-integration", "Run integration tests only");
    integration_test_step.dependOn(&run_integration_tests.step);
}

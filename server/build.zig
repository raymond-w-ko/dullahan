const std = @import("std");

fn pathExists(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
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
        if (pathExists(header)) return prefix;
    }

    return null;
}

fn linkOpenSsl(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    openssl_dir: ?[]const u8,
    openssl_include_dir: ?[]const u8,
    openssl_lib_dir: ?[]const u8,
) void {
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

    if (include_dir) |path| {
        if (pathExists(path)) step.addIncludePath(.{ .cwd_relative = path });
    }
    if (lib_dir) |path| {
        if (pathExists(path)) step.addLibraryPath(.{ .cwd_relative = path });
    }

    step.linkSystemLibrary2("ssl", .{ .use_pkg_config = .yes });
    step.linkSystemLibrary2("crypto", .{ .use_pkg_config = .yes });
}

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

    // Create a module for the core library (can be imported by tests and exe)
    const dullahan_mod = b.addModule("dullahan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add ghostty-vt dependency (lazy so it's only fetched when needed)
    // MUST pass optimize to disable slow_runtime_safety checks in release builds!
    if (b.lazyDependency("ghostty", .{ .optimize = optimize })) |ghostty_dep| {
        const ghostty_vt = ghostty_dep.module("ghostty-vt");
        dullahan_mod.addImport("ghostty-vt", ghostty_vt);
    }

    // Add zig-msgpack dependency for binary serialization
    if (b.lazyDependency("zig-msgpack", .{})) |msgpack_dep| {
        const msgpack = msgpack_dep.module("msgpack");
        dullahan_mod.addImport("msgpack", msgpack);
    }

    // Add snappy dependency for compression
    // Pass target/optimize so the C++ library builds correctly
    if (b.lazyDependency("snappy", .{
        .target = target,
        .optimize = optimize,
    })) |snappy_dep| {
        const snappy = snappy_dep.module("snappy");
        dullahan_mod.addImport("snappy", snappy);
        // Link the snappy static library
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

    exe.linkLibC();
    linkOpenSsl(b, exe, target, openssl_dir, openssl_include_dir, openssl_lib_dir);

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ============================================================
    // Tests
    // ============================================================

    // Test the library module
    const mod_tests = b.addTest(.{
        .root_module = dullahan_mod,
    });
    mod_tests.linkLibC();
    linkOpenSsl(b, mod_tests, target, openssl_dir, openssl_include_dir, openssl_lib_dir);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test the executable's root module
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.linkLibC();
    linkOpenSsl(b, exe_tests, target, openssl_dir, openssl_include_dir, openssl_lib_dir);
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
    integration_tests.linkLibC();
    linkOpenSsl(b, integration_tests, target, openssl_dir, openssl_include_dir, openssl_lib_dir);
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

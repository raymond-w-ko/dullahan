const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for the core library (can be imported by tests and exe)
    const dullahan_mod = b.addModule("dullahan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Add ghostty-vt dependency (lazy so it's only fetched when needed)
    if (b.lazyDependency("ghostty", .{})) |ghostty_dep| {
        const ghostty_vt = ghostty_dep.module("ghostty-vt");
        dullahan_mod.addImport("ghostty-vt", ghostty_vt);
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

    b.installArtifact(exe);

    // Key tester - Kitty protocol
    const keytest_kitty = b.addExecutable(.{
        .name = "keytest-kitty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keytest_kitty.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(keytest_kitty);

    // Byte coverage tester - shows all 256 bytes
    const keytest_bytes = b.addExecutable(.{
        .name = "keytest-bytes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keytest_bytes.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(keytest_bytes);

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
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test the executable's root module
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
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
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // `zig build test` runs all tests (unit + integration)
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // `zig build test-unit` runs only unit tests
    const unit_test_step = b.step("test-unit", "Run unit tests only");
    unit_test_step.dependOn(&run_mod_tests.step);
    unit_test_step.dependOn(&run_exe_tests.step);

    // `zig build test-integration` runs only integration tests
    const integration_test_step = b.step("test-integration", "Run integration tests only");
    integration_test_step.dependOn(&run_integration_tests.step);
}

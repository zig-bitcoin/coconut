const std = @import("std");
const build_helpers = @import("build_helpers.zig");
const package_name = "coconut";
const package_path = "src/lib.zig";

// List of external dependencies that this package requires.
const external_dependencies = [_]build_helpers.Dependency{
    .{
        .name = "zig-cli",
        .module_name = "zig-cli",
    },
};

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Channel module
    const channel_m = b.addModule("channels", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/channels/channels.zig"),
    });

    // **************************************************************
    // *            HANDLE DEPENDENCY MODULES                       *
    // **************************************************************
    const dependencies_opts = .{
        .target = target,
        .optimize = optimize,
    };

    // This array can be passed to add the dependencies to lib, executable, tests, etc using `addModule` function.
    const deps = build_helpers.generateModuleDependencies(
        b,
        &external_dependencies,
        dependencies_opts,
    ) catch unreachable;

    // **************************************************************
    // *               COCONUT AS A MODULE                        *
    // **************************************************************
    // expose coconut as a module
    _ = b.addModule(package_name, .{
        .root_source_file = b.path(package_path),
        .imports = deps,
    });

    // httpz dependency
    const httpz_module = b.dependency("httpz", .{ .target = target, .optimize = optimize }).module("httpz");

    // postgresql dependency
    const pg = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });

    const zul = b.dependency("zul", .{
        .target = target,
        .optimize = optimize,
    }).module("zul");

    const bitcoin_primitives = b.dependency("bitcoin-primitives", .{
        .target = target,
        .optimize = optimize,
    });

    const base58_module = b.dependency("base58-zig", .{
        .target = target,
        .optimize = optimize,
    }).module("base58-zig");

    // **************************************************************
    // *              COCONUT AS A LIBRARY                        *
    // **************************************************************
    const lib = b.addStaticLibrary(.{
        .name = "coconut",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Add dependency modules to the library.
    for (deps) |mod| lib.root_module.addImport(
        mod.name,
        mod.module,
    );
    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // **************************************************************
    // *              CHECK STEP AS AN EXECUTABLE                   *
    // **************************************************************
    // for lsp build on save step
    {
        const check = b.step("check", "Check if foo compiles");
        // mint binary
        {
            const exe = b.addExecutable(.{
                .name = "mint",
                .root_source_file = b.path("src/mint.zig"),
                .target = target,
                .optimize = optimize,
            });
            exe.root_module.addImport("zul", zul);
            exe.root_module.addImport("httpz", httpz_module);
            exe.root_module.addImport("bitcoin-primitives", bitcoin_primitives.module("bitcoin-primitives"));
            exe.root_module.addImport("base58", base58_module);

            exe.root_module.addImport("channels", channel_m);

            // Add dependency modules to the executable.
            for (deps) |mod| exe.root_module.addImport(
                mod.name,
                mod.module,
            );

            check.dependOn(&exe.step);
        }
        // main
        {
            const exe = b.addExecutable(.{
                .name = "main",
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            });
            exe.root_module.addImport("httpz", httpz_module);
            exe.root_module.addImport("pg", pg.module("pg"));
            exe.root_module.addImport("zul", zul);

            // Add dependency modules to the executable.
            for (deps) |mod| exe.root_module.addImport(
                mod.name,
                mod.module,
            );

            check.dependOn(&exe.step);
        }

        // tests
        {
            const lib_unit_tests = b.addTest(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = false,
            });
            lib_unit_tests.root_module.addImport("zul", zul);
            lib_unit_tests.root_module.addImport("httpz", httpz_module);
            lib_unit_tests.root_module.addImport("bitcoin-primitives", bitcoin_primitives.module("bitcoin-primitives"));
            lib_unit_tests.root_module.addImport("base58", base58_module);

            lib_unit_tests.root_module.addImport("channels", channel_m);

            const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

            check.dependOn(&run_lib_unit_tests.step);
        }
    }

    // **************************************************************
    // *              COCONUT-MINT AS AN EXECUTABLE                    *
    // **************************************************************
    {
        const exe = b.addExecutable(.{
            .name = "coconut-mint",
            .root_source_file = b.path("src/mint.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("httpz", httpz_module);
        exe.root_module.addImport("channels", channel_m);
        exe.root_module.addImport("zul", zul);
        exe.root_module.addImport("pg", pg.module("pg"));
        exe.root_module.addImport("bitcoin-primitives", bitcoin_primitives.module("bitcoin-primitives"));

        // Add dependency modules to the executable.
        for (deps) |mod| exe.root_module.addImport(
            mod.name,
            mod.module,
        );

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run-mint", "Run coconut-mint");
        run_step.dependOn(&run_cmd.step);
    }

    // **************************************************************
    // *              COCONUT AS AN EXECUTABLE                    *
    // **************************************************************
    {
        const exe = b.addExecutable(.{
            .name = "coconut",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        // Add dependency modules to the executable.
        for (deps) |mod| exe.root_module.addImport(
            mod.name,
            mod.module,
        );

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });
    lib_unit_tests.root_module.addImport("zul", zul);
    lib_unit_tests.root_module.addImport("httpz", httpz_module);
    lib_unit_tests.root_module.addImport("bitcoin-primitives", bitcoin_primitives.module("bitcoin-primitives"));
    lib_unit_tests.root_module.addImport("base58", base58_module);

    lib_unit_tests.root_module.addImport("channels", channel_m);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Add benchmark step
    const bench = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmarks.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // Add dependency modules to the executable.
    for (deps) |mod| bench.root_module.addImport(
        mod.name,
        mod.module,
    );

    bench.root_module.addImport("zul", zul);
    bench.root_module.addImport("bitcoin-primitives", bitcoin_primitives.module("bitcoin-primitives"));

    const run_bench = b.addRunArtifact(bench);

    // Add option for report generation
    const report_option = b.option(bool, "report", "Generate benchmark report (default: false)") orelse false;

    // Pass the report option to the benchmark executable
    if (report_option) {
        run_bench.addArg("--report");
    }

    // Pass any additional arguments to the benchmark executable
    if (b.args) |args| {
        run_bench.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Add documentation generation step
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}

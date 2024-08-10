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

fn buildSecp256k1(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{ .name = "zig-libsecp256k1", .target = target, .optimize = optimize });

    lib.addIncludePath(b.path("libsecp256k1/"));
    lib.addIncludePath(b.path("libsecp256k1/src"));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    try flags.appendSlice(&.{"-DENABLE_MODULE_RECOVERY=1"});
    lib.addCSourceFiles(.{ .root = b.path("libsecp256k1/"), .flags = flags.items, .files = &.{ "./src/secp256k1.c", "./src/precomputed_ecmult.c", "./src/precomputed_ecmult_gen.c" } });
    lib.defineCMacro("USE_FIELD_10X26", "1");
    lib.defineCMacro("USE_SCALAR_8X32", "1");
    lib.defineCMacro("USE_ENDOMORPHISM", "1");
    lib.defineCMacro("USE_NUM_NONE", "1");
    lib.defineCMacro("USE_FIELD_INV_BUILTIN", "1");
    lib.defineCMacro("USE_SCALAR_INV_BUILTIN", "1");
    lib.installHeadersDirectory(b.path("libsecp256k1/src"), "", .{ .include_extensions = &.{".h"} });
    lib.installHeadersDirectory(b.path("libsecp256k1/include/"), "", .{ .include_extensions = &.{".h"} });
    lib.linkLibC();

    return lib;
}

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

    // libsecp256k1 static C library.
    const libsecp256k1 = try buildSecp256k1(b, target, optimize);
    b.installArtifact(libsecp256k1);

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
    // *              COCONUT AS AN EXECUTABLE                    *
    // **************************************************************
    const exe = b.addExecutable(.{
        .name = "coconut",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(libsecp256k1);
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

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.linkLibrary(libsecp256k1);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    // Add benchmark step
    const bench = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmarks.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    bench.linkLibrary(libsecp256k1);
    bench.root_module.addImport("zul", b.dependency("zul", .{}).module("zul"));

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
}

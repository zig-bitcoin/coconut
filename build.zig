const std = @import("std");

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
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libsecp256k1 static C library.
    const libsecp256k1 = try buildSecp256k1(b, target, optimize);
    b.installArtifact(libsecp256k1);

    const lib = b.addStaticLibrary(.{
        .name = "coconut",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "coconut",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/bdhkec.zig"),
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

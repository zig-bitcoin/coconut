const std = @import("std");
const package_name = "coconut";
const package_path = "src/lib.zig";
const build_helpers = @import("build_helpers.zig");

// List of external dependencies that this package requires.
const external_dependencies = [_]build_helpers.Dependency{
    .{
        .name = "httpz",
        .module_name = "httpz",
    },
    .{
        .name = "zul",
        .module_name = "zul",
    },
    .{
        .name = "bitcoin-primitives",
        .module_name = "bitcoin-primitives",
    },
    .{
        .name = "zig-cli",
        .module_name = "zig-cli",
    },
    .{
        .name = "zig-toml",
        .module_name = "zig-toml",
    },
    .{
        .name = "clap",
        .module_name = "clap",
    },
    .{
        .name = "zqlite",
        .module_name = "zqlite",
    },
};

fn installSqliteDependency(sqlitec: *std.Build.Dependency, compile: *std.Build.Step.Compile) void {
    compile.addCSourceFile(.{
        .file = sqlitec.path("sqlite3.c"),
        .flags = &[_][]const u8{
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_ENABLE_API_ARMOR=1",
            "-DSQLITE_ENABLE_UNLOCK_NOTIFY",
            "-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT=1",
            "-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600",
            "-DSQLITE_OMIT_DECLTYPE=1",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK=1",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_OMIT_TRACE=1",
            "-DSQLITE_OMIT_UTF16=1",
            "-DHAVE_USLEEP=0",
            "-DSQLITE_DEBUG=1",
            "-DSQLITE_ENABLE_EXPLAIN_COMMENTS=1",
            "-DSQLITE_ENABLE_TREETRACE=1",
            "-DSQLITE_ENABLE_WHERETRACE=1",
        },
    });
    compile.linkLibC();
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

    // Sqlite3 c library source code
    const sqlitec = b.dependency("sqlitec", .{
        .target = target,
        .optimize = optimize,
    });

    // **************************************************************
    // *            HANDLE DEPENDENCY MODULES                       *
    // **************************************************************

    // This array can be passed to add the dependencies to lib, executable, tests, etc using `addModule` function.
    const deps = build_helpers.generateModuleDependencies(
        b,
        &external_dependencies,
        .{
            .optimize = optimize,
            .target = target,
        },
    ) catch unreachable;

    // **************************************************************
    // *               COCONUT AS A MODULE                        *
    // **************************************************************
    // expose coconut as a module
    _ = b.addModule(package_name, .{
        .root_source_file = b.path(package_path),
        .imports = deps,
    });

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
            installSqliteDependency(sqlitec, exe);

            // Add dependency modules to the library.
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

            // Add dependency modules to the library.
            for (deps) |mod| exe.root_module.addImport(
                mod.name,
                mod.module,
            );
            installSqliteDependency(sqlitec, exe);

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
            installSqliteDependency(sqlitec, lib_unit_tests);

            // Add dependency modules to the library.
            for (deps) |mod| lib_unit_tests.root_module.addImport(
                mod.name,
                mod.module,
            );

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

        installSqliteDependency(sqlitec, exe);

        // Add dependency modules to the library.
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

        installSqliteDependency(sqlitec, exe);

        // Add dependency modules to the library.
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
    installSqliteDependency(sqlitec, lib_unit_tests);

    // Add dependency modules to the library.
    for (deps) |mod| lib_unit_tests.root_module.addImport(
        mod.name,
        mod.module,
    );

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

    // Add dependency modules to the library.
    for (deps) |mod| bench.root_module.addImport(
        mod.name,
        mod.module,
    );

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

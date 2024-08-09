const std = @import("std");
const bdhke = @import("bdhke.zig");
const bdhkec = @import("bdhkec.zig");

const Secp256k1 = std.crypto.ecc.Secp256k1;
const Scalar = Secp256k1.scalar.Scalar;
const Point = Secp256k1;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const generate_report = true;

    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();

    try benchmarkAll(allocator, &results);
    try displayResultsTable(&results);

    if (generate_report) {
        try generateCSVReport(&results);
    }
}

const BenchmarkResult = struct {
    name: []const u8,
    average_ns: u64,
};

fn benchmarkAll(allocator: std.mem.Allocator, results: *std.ArrayList(BenchmarkResult)) !void {
    // Initialize test data
    const secret_msg = "test_message";
    const a_bytes: [32]u8 = [_]u8{1} ** 32;
    const r_bytes: [32]u8 = [_]u8{1} ** 32;

    // c wrapped bench
    {
        const dhke = try bdhkec.Dhke.init(allocator);
        defer dhke.deinit();
        const a = try bdhkec.SecretKey.fromSlice(&a_bytes);
        const blinding_factor = try bdhkec.SecretKey.fromSlice(&r_bytes);

        // Benchmark individual steps
        try benchmarkStep(results, "hashToCurveC", struct {
            fn func() !void {
                _ = try bdhkec.Dhke.hashToCurve(secret_msg);
            }
        }.func, .{});

        try benchmarkStep(results, "step1AliceC", struct {
            fn func(_dhke: *const bdhkec.Dhke, msg: []const u8, bf: bdhkec.SecretKey) !void {
                _ = try _dhke.step1Alice(msg, bf);
            }
        }.func, .{ &dhke, secret_msg, blinding_factor });

        const B_ = try dhke.step1Alice(secret_msg, blinding_factor);
        try benchmarkStep(results, "step2BobC", struct {
            fn func(_dhke: *const bdhkec.Dhke, b: bdhkec.PublicKey, key: bdhkec.SecretKey) !void {
                _ = try _dhke.step2Bob(b, key);
            }
        }.func, .{ &dhke, B_, a });

        const C_ = try dhke.step2Bob(B_, a);
        try benchmarkStep(results, "step3AliceC", struct {
            fn func(_dhke: *const bdhkec.Dhke, c: bdhkec.PublicKey, key: bdhkec.SecretKey, pub_key: bdhkec.PublicKey) !void {
                _ = try _dhke.step3Alice(c, key, pub_key);
            }
        }.func, .{ &dhke, C_, blinding_factor, a.publicKey(dhke.secp) });

        const step3_c = try dhke.step3Alice(C_, blinding_factor, a.publicKey(dhke.secp));

        try benchmarkStep(results, "verifyC", struct {
            fn func(_dhke: *const bdhkec.Dhke, a_: bdhkec.SecretKey, c: bdhkec.PublicKey, msg: []const u8) !void {
                _ = try _dhke.verify(a_, c, msg);
            }
        }.func, .{ &dhke, a, step3_c, secret_msg });

        // Benchmark end-to-end flow
        try benchmarkStep(results, "E2E-C", struct {
            fn func(_dhke: *const bdhkec.Dhke, msg: []const u8, bf: bdhkec.SecretKey, _a: bdhkec.SecretKey) !void {
                const b_ = try _dhke
                    .step1Alice(msg, bf);

                const c_ = try _dhke.step2Bob(b_, _a);

                const c = try _dhke
                    .step3Alice(c_, bf, _a.publicKey(_dhke.secp));

                _ = try _dhke.verify(_a, c, msg);
            }
        }.func, .{ &dhke, secret_msg, blinding_factor, a });
    }

    const a = try Scalar.fromBytes(a_bytes, .big);
    const A = try Point.basePoint.mul(a.toBytes(.little), .little);
    const r = try Scalar.fromBytes(r_bytes, .big);
    const blinding_factor = try Point.basePoint.mul(r.toBytes(.little), .little);

    // Benchmark individual steps
    try benchmarkStep(results, "hashToCurve", struct {
        fn func() !void {
            _ = try bdhke.hashToCurve(secret_msg);
        }
    }.func, .{});

    try benchmarkStep(results, "step1Alice", struct {
        fn func(msg: []const u8, bf: Point) !void {
            _ = try bdhke.step1Alice(msg, bf);
        }
    }.func, .{ secret_msg, blinding_factor });

    const B_ = try bdhke.step1Alice(secret_msg, blinding_factor);
    try benchmarkStep(results, "step2Bob", struct {
        fn func(b: Point, key: Scalar) !void {
            _ = try bdhke.step2Bob(b, key, false);
        }
    }.func, .{ B_, a });

    const step2_result = try bdhke.step2Bob(B_, a, false);
    try benchmarkStep(results, "step3Alice", struct {
        fn func(c: Point, key: Scalar, pub_key: Point) !void {
            _ = try bdhke.step3Alice(c, key, pub_key);
        }
    }.func, .{ step2_result.C_, r, A });

    const C = try bdhke.step3Alice(step2_result.C_, r, A);
    try benchmarkStep(results, "verify", struct {
        fn func(key: Scalar, point: Point, msg: []const u8) !void {
            _ = try bdhke.verify(key, point, msg);
        }
    }.func, .{ a, C, secret_msg });

    // Benchmark end-to-end flow
    try benchmarkStep(results, "End-to-End BDHKE", struct {
        fn func(msg: []const u8, bf: Point, key: Scalar, pub_key: Point, _r: Scalar) !void {
            const b = try bdhke.step1Alice(msg, bf);
            const step2_res = try bdhke.step2Bob(b, key, false);
            const c = try bdhke.step3Alice(step2_res.C_, _r, pub_key);
            const is_valid = try bdhke.verify(key, c, secret_msg);
            // Fail if the verification fails
            if (!is_valid) {
                return error.VerificationFailed;
            }
        }
    }.func, .{ secret_msg, blinding_factor, a, A, r });
}

fn benchmarkStep(results: *std.ArrayList(BenchmarkResult), name: []const u8, comptime func: anytype, args: anytype) !void {
    var timer = try std.time.Timer.start();
    const iterations: usize = 1000;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try @call(.auto, func, args);
    }

    const elapsed_ns = timer.lap();
    const average_ns = @divFloor(elapsed_ns, iterations);

    try results.append(.{ .name = name, .average_ns = average_ns });
}

fn displayResultsTable(results: *std.ArrayList(BenchmarkResult)) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n{s: <20} | {s: >15} | {s: >15}\n", .{ "Operation", "Time (us)", "Time (ms)" });
    try stdout.writeByteNTimes('-', 58);
    try stdout.writeByte('\n');

    for (results.items) |result| {
        const average_ms = @as(f64, @floatFromInt(result.average_ns)) / 1_000_000.0;
        const average_us = @as(f64, @floatFromInt(result.average_ns)) / 1_000.0;
        try stdout.print("{s: <20} | {d: >15.3} | {d: >15.3}\n", .{ result.name, average_us, average_ms });
    }
}

fn generateCSVReport(results: *std.ArrayList(BenchmarkResult)) !void {
    const file = try std.fs.cwd().createFile("benchmark_report.csv", .{});
    defer file.close();

    const writer = file.writer();
    try writer.writeAll("operation,ns_time\n");

    for (results.items) |result| {
        try writer.print("{s},{d}\n", .{ result.name, result.average_ns });
    }

    std.debug.print("\nBenchmark report generated: benchmark_report.csv\n", .{});
}

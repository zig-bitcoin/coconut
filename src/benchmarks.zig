const std = @import("std");
const bdhke = @import("bdhke.zig");

const Secp256k1 = std.crypto.ecc.Secp256k1;
const Scalar = Secp256k1.scalar.Scalar;
const Point = Secp256k1;

const zul = @import("zul");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try benchmarkZul(allocator);
}

const Context = struct {
    secret_msg: []const u8 = "test_message",
    dhke: bdhke.Dhke,
    bf: bdhke.SecretKey,
    a: bdhke.SecretKey,
};

fn hashToCurve(ctx: Context, _: std.mem.Allocator, _: *std.time.Timer) !void {
    _ = try bdhke.Dhke.hashToCurve(ctx.secret_msg);
}

fn step1Alice(ctx: Context, _: std.mem.Allocator, _: *std.time.Timer) !void {
    _ = try ctx.dhke.step1Alice(ctx.secret_msg, ctx.bf);
}

fn step2Bob(ctx: Context, _: std.mem.Allocator, t: *std.time.Timer) !void {
    const B_ = try ctx.dhke.step1Alice(ctx.secret_msg, ctx.bf);

    t.reset();

    _ = try ctx.dhke.step2Bob(B_, ctx.a);
}

fn step3Alice(ctx: Context, _: std.mem.Allocator, t: *std.time.Timer) !void {
    const B_ = try ctx.dhke.step1Alice(ctx.secret_msg, ctx.bf);
    const C_ = try ctx.dhke.step2Bob(B_, ctx.a);
    const pub_key = ctx.a.publicKey(ctx.dhke.secp);

    t.reset();

    _ = try ctx.dhke.step3Alice(C_, ctx.bf, pub_key);
}

fn verify(ctx: Context, _: std.mem.Allocator, t: *std.time.Timer) !void {
    const B_ = try ctx.dhke.step1Alice(ctx.secret_msg, ctx.bf);
    const C_ = try ctx.dhke.step2Bob(B_, ctx.a);
    const pub_key = ctx.a.publicKey(ctx.dhke.secp);

    const C = try ctx.dhke.step3Alice(C_, ctx.bf, pub_key);
    t.reset();

    _ = try ctx.dhke.verify(ctx.a, C, ctx.secret_msg);
}

fn end2End(ctx: Context, _: std.mem.Allocator, _: *std.time.Timer) !void {
    const b_ = try ctx.dhke
        .step1Alice(ctx.secret_msg, ctx.bf);

    const c_ = try ctx.dhke.step2Bob(b_, ctx.a);

    const c = try ctx.dhke
        .step3Alice(c_, ctx.bf, ctx.a.publicKey(ctx.dhke.secp));

    _ = try ctx.dhke.verify(ctx.a, c, ctx.secret_msg);
}

fn benchmarkZul(allocator: std.mem.Allocator) !void {
    const a_bytes: [32]u8 = [_]u8{1} ** 32;
    const r_bytes: [32]u8 = [_]u8{1} ** 32;
    const ctx = Context{
        .dhke = try bdhke.Dhke.init(allocator),
        .a = try bdhke.SecretKey.fromSlice(&a_bytes),
        .bf = try bdhke.SecretKey.fromSlice(&r_bytes),
    };
    defer ctx.dhke.deinit();

    (try zul.benchmark.runC(ctx, hashToCurve, .{})).print("hashToCurve");
    (try zul.benchmark.runC(ctx, step1Alice, .{})).print("step1Alice");
    (try zul.benchmark.runC(ctx, step2Bob, .{})).print("step2Bob");
    (try zul.benchmark.runC(ctx, step3Alice, .{})).print("step3Alice");
    (try zul.benchmark.runC(ctx, verify, .{})).print("verify");
    (try zul.benchmark.runC(ctx, end2End, .{})).print("e2e");
}

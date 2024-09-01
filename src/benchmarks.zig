const std = @import("std");

const dhke = @import("core/dhke.zig");
const secp256k1 = @import("core/secp256k1.zig");
const Scalar = secp256k1.Scalar;
const PublicKey = secp256k1.PublicKey;
const SecretKey = secp256k1.SecretKey;

const zul = @import("zul");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try benchmarkZul();
}

const Context = struct {
    secret_msg: []const u8 = "test_message",
    secp: secp256k1.Secp256k1,
    bf: SecretKey,
    a: SecretKey,
};

fn hashToCurve(ctx: Context, _: std.mem.Allocator, _: *std.time.Timer) !void {
    _ = try dhke.hashToCurve(ctx.secret_msg);
}

fn step1Alice(ctx: Context, _: std.mem.Allocator, _: *std.time.Timer) !void {
    const y = try dhke.hashToCurve(ctx.secret_msg);

    _ = try y.combine(secp256k1.PublicKey.fromSecretKey(ctx.secp, ctx.bf));
}

fn step2Bob(ctx: Context, _: std.mem.Allocator, t: *std.time.Timer) !void {
    const y = try dhke.hashToCurve(ctx.secret_msg);

    const B_ = try y.combine(secp256k1.PublicKey.fromSecretKey(ctx.secp, ctx.bf));

    t.reset();

    _ = try B_.mulTweak(&ctx.secp, secp256k1.Scalar.fromSecretKey(ctx.a));
}

fn step3Alice(ctx: Context, _: std.mem.Allocator, t: *std.time.Timer) !void {
    const y = try dhke.hashToCurve(ctx.secret_msg);

    const B_ = try y.combine(secp256k1.PublicKey.fromSecretKey(ctx.secp, ctx.bf));

    const C_ = try B_.mulTweak(&ctx.secp, secp256k1.Scalar.fromSecretKey(ctx.a));

    const pub_key = ctx.a.publicKey(ctx.secp);

    t.reset();

    _ = C_.combine(
        (try pub_key
            .mulTweak(&ctx.secp, secp256k1.Scalar.fromSecretKey(ctx.bf)))
            .negate(&ctx.secp),
    ) catch return error.Secp256k1Error;
}

fn verify(ctx: Context, _: std.mem.Allocator, t: *std.time.Timer) !void {
    const y = try dhke.hashToCurve(ctx.secret_msg);

    const B_ = try y.combine(secp256k1.PublicKey.fromSecretKey(ctx.secp, ctx.bf));

    const C_ = try B_.mulTweak(&ctx.secp, secp256k1.Scalar.fromSecretKey(ctx.a));

    const pub_key = ctx.a.publicKey(ctx.secp);

    const C = C_.combine(
        (try pub_key
            .mulTweak(&ctx.secp, secp256k1.Scalar.fromSecretKey(ctx.bf)))
            .negate(&ctx.secp),
    ) catch return error.Secp256k1Error;
    t.reset();

    _ = try dhke.verifyMessage(ctx.secp, ctx.a, C, ctx.secret_msg);
}

fn end2End(ctx: Context, _: std.mem.Allocator, _: *std.time.Timer) !void {
    const y = try dhke.hashToCurve(ctx.secret_msg);

    const B_ = try y.combine(secp256k1.PublicKey.fromSecretKey(ctx.secp, ctx.bf));

    const C_ = try B_.mulTweak(&ctx.secp, secp256k1.Scalar.fromSecretKey(ctx.a));

    const pub_key = ctx.a.publicKey(ctx.secp);

    const C = C_.combine(
        (try pub_key
            .mulTweak(&ctx.secp, secp256k1.Scalar.fromSecretKey(ctx.bf)))
            .negate(&ctx.secp),
    ) catch return error.Secp256k1Error;

    _ = try dhke.verifyMessage(ctx.secp, ctx.a, C, ctx.secret_msg);
}

fn benchmarkZul() !void {
    const a_bytes: [32]u8 = [_]u8{1} ** 32;
    const r_bytes: [32]u8 = [_]u8{1} ** 32;
    const secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    const ctx = Context{
        .secp = secp,
        .a = try SecretKey.fromSlice(&a_bytes),
        .bf = try SecretKey.fromSlice(&r_bytes),
    };

    (try zul.benchmark.runC(ctx, hashToCurve, .{})).print("hashToCurve");
    (try zul.benchmark.runC(ctx, step1Alice, .{})).print("step1Alice");
    (try zul.benchmark.runC(ctx, step2Bob, .{})).print("step2Bob");
    (try zul.benchmark.runC(ctx, step3Alice, .{})).print("step3Alice");
    (try zul.benchmark.runC(ctx, verify, .{})).print("verify");
    (try zul.benchmark.runC(ctx, end2End, .{})).print("e2e");
}

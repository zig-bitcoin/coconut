const std = @import("std");
const crypto = std.crypto;
const Secp256k1 = crypto.ecc.Secp256k1;
const Scalar = crypto.ecc.Secp256k1.scalar.Scalar;

/// Error type for BDHKE operations
const BDHKEError = error{
    InvalidPoint,
    VerificationFailed,
};

/// Represents a point on the secp256k1 curve
const Point = Secp256k1;

/// Hashes a message to a point on the secp256k1 curve
fn hashToPoint(message: []const u8) !Point {
    var hasher = crypto.hash.sha2.Sha256.init(.{});
    hasher.update("Secp256k1_HashToCurve_Cashu_");
    hasher.update(message);

    var counter: u32 = 0;
    while (counter < 0x10000) : (counter += 1) {
        var hash: [32]u8 = undefined;
        var temp_hasher = hasher;
        temp_hasher.update(std.mem.asBytes(&counter));
        temp_hasher.final(&hash);

        hash[31] &= 0x01; // Clear the high bit to ensure it's below the order of the curve

        if (Scalar.fromBytes(hash, .little)) |scalar| {
            return Secp256k1.basePoint.mul(scalar.toBytes(.little), .little);
        } else |_| {}
    }

    return BDHKEError.InvalidPoint;
}

/// Step 1: Alice blinds the message
pub fn step1Alice(secret_msg: []const u8, blinding_factor: ?Scalar) !struct { B_: Point, r: Scalar } {
    const Y = try hashToPoint(secret_msg);
    const r = blinding_factor orelse Scalar.random();
    const rG = try Secp256k1.basePoint.mul(r.toBytes(.little), .little);
    const B_ = Y.add(rG);
    return .{ .B_ = B_, .r = r };
}

/// Step 2: Bob signs the blinded message
pub fn step2Bob(B_: Point, a: Scalar) !struct { C_: Point, e: Scalar, s: Scalar } {
    const C_ = try B_.mul(a.toBytes(.little), .little);
    const res = try step2BobDLEQ(B_, a, C_);
    return .{ .C_ = res.C_, .e = res.e, .s = res.s };
}

/// Generates DLEQ proof
fn step2BobDLEQ(B_: Point, a: Scalar, C_: Point) !struct { C_: Point, e: Scalar, s: Scalar } {
    const p = Scalar.random();
    const R1 = try Secp256k1.basePoint.mul(p.toBytes(.little), .little);
    const R2 = try B_.mul(p.toBytes(.little), .little);
    const A = try Secp256k1.basePoint.mul(a.toBytes(.little), .little);

    const e = try hashE(&[_]Point{ R1, R2, A, C_ });
    const s = p.add(a.mul(e));

    return .{ .C_ = C_, .e = e, .s = s };
}

/// Step 3: Alice unblinds the signature
pub fn step3Alice(C_: Point, r: Scalar, A: Point) !Point {
    const rA = try A.mul(r.toBytes(.little), .little);
    return C_.sub(rA);
}

/// Verifies the BDHKE process
pub fn verify(a: Scalar, C: Point, secret_msg: []const u8) !bool {
    const Y = try hashToPoint(secret_msg);
    const aY = try Y.mul(a.toBytes(.little), .little);
    return C.equivalent(aY);
}

/// Alice verifies the DLEQ proof
pub fn aliceVerifyDLEQ(B_: Point, C_: Point, e: Scalar, s: Scalar, A: Point) !bool {
    const sG = try Secp256k1.basePoint.mul(s.toBytes(.little), .little);
    const eA = try A.mul(e.toBytes(.little), .little);
    const R1 = sG.sub(eA);

    const sB_ = try B_.mul(s.toBytes(.little), .little);
    const eC_ = try C_.mul(e.toBytes(.little), .little);
    const R2 = sB_.sub(eC_);

    const e_computed = try hashE(&[_]Point{ R1, R2, A, C_ });
    return e.equivalent(e_computed);
}

/// Carol verifies the DLEQ proof
pub fn carolVerifyDLEQ(secret_msg: []const u8, r: Scalar, C: Point, e: Scalar, s: Scalar, A: Point) !bool {
    const Y = try hashToPoint(secret_msg);
    const rA = try A.mul(r.toBytes(.little), .little);
    const C_ = C.add(rA);
    const rG = try Secp256k1.basePoint.mul(r.toBytes(.little), .little);
    const B_ = Y.add(rG);
    return aliceVerifyDLEQ(B_, C_, e, s, A);
}

/// Hashes multiple points to create a challenge
fn hashE(points: []const Point) !Scalar {
    var hasher = crypto.hash.sha2.Sha256.init(.{});
    for (points) |point| {
        const bytes = point.toUncompressedSec1();
        hasher.update(&bytes);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return Scalar.fromBytes(result, .little) catch unreachable;
}

/// End-to-end test scenario
pub fn testBDHKE() !void {
    // Initialize
    const secret_msg = "test_message";
    const a = Scalar.random();
    const A = try Secp256k1.basePoint.mul(a.toBytes(.little), .little);

    std.debug.print("Starting BDHKE test\n", .{});
    std.debug.print("Secret message: {s}\n", .{secret_msg});

    // Step 1: Alice blinds the message
    const step1_result = try step1Alice(secret_msg, null);
    const B_ = step1_result.B_;
    const r = step1_result.r;

    std.debug.print("Step 1 complete: Message blinded\n", .{});

    // Step 2: Bob signs the blinded message
    const step2_result = try step2Bob(B_, a);
    const C_ = step2_result.C_;
    const e = step2_result.e;
    const s = step2_result.s;

    std.debug.print("Step 2 complete: Blinded message signed\n", .{});

    // Alice verifies DLEQ proof
    const alice_verification = try aliceVerifyDLEQ(B_, C_, e, s, A);
    if (!alice_verification) {
        return error.AliceVerificationFailed;
    }
    std.debug.print("Alice's DLEQ verification successful\n", .{});

    // Step 3: Alice unblinds the signature
    const C = try step3Alice(C_, r, A);

    std.debug.print("Step 3 complete: Signature unblinded\n", .{});

    // Carol verifies DLEQ proof
    const carol_verification = try carolVerifyDLEQ(secret_msg, r, C, e, s, A);
    if (!carol_verification) {
        return error.CarolVerificationFailed;
    }
    std.debug.print("Carol's DLEQ verification successful\n", .{});

    // Final verification
    const final_verification = try verify(a, C, secret_msg);
    if (!final_verification) {
        return error.FinalVerificationFailed;
    }
    std.debug.print("Final verification successful\n", .{});

    std.debug.print("BDHKE test completed successfully\n", .{});
}

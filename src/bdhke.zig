const std = @import("std");
const crypto = std.crypto;
const Secp256k1 = crypto.ecc.Secp256k1;
const Scalar = Secp256k1.scalar.Scalar;
const Point = Secp256k1;

/// Error type for BDHKE operations
const BDHKEError = error{
    InvalidPoint,
    VerificationFailed,
};

/// Hashes a message to a point on the secp256k1 curve
fn hashToPoint(message: []const u8) BDHKEError!Point {
    const domain_separator = "Secp256k1_HashToCurve_Cashu_";
    var initial_hasher = crypto.hash.sha2.Sha256.init(.{});
    initial_hasher.update(domain_separator);
    initial_hasher.update(message);
    var msg_to_hash: [32]u8 = undefined;
    initial_hasher.final(&msg_to_hash);

    var counter: u32 = 0;
    while (counter < 0x10000) : (counter += 1) {
        var to_hash: [36]u8 = undefined;
        @memcpy(to_hash[0..32], &msg_to_hash);

        // Manually write little-endian bytes
        to_hash[32] = @intCast(counter & 0xFF);
        to_hash[33] = @intCast((counter >> 8) & 0xFF);
        to_hash[34] = @intCast((counter >> 16) & 0xFF);
        to_hash[35] = @intCast((counter >> 24) & 0xFF);

        var hasher = crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&to_hash);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        // Attempt to create a public key
        var compressed_point: [33]u8 = undefined;
        compressed_point[0] = 0x02; // Set to compressed point format
        @memcpy(compressed_point[1..], &hash);

        if (Point.fromSec1(&compressed_point)) |point| {
            return point;
        } else |_| {
            // If point creation fails, continue to next iteration
            continue;
        }
    }

    return BDHKEError.InvalidPoint;
}

/// Step 1: Alice blinds the message
pub fn step1Alice(secret_msg: []const u8, blinding_factor: Point) !Point {
    const Y = try hashToPoint(secret_msg);
    const B_ = Y.add(blinding_factor);
    return B_;
}

/// Step 2: Bob signs the blinded message
pub fn step2Bob(B_: Point, a: Scalar) !struct { C_: Point, e: Scalar, s: Scalar } {
    const C_ = try B_.mul(a.toBytes(.little), .little);
    const result = try step2BobDLEQ(B_, a, C_);
    return .{ .C_ = result.C_, .e = result.e, .s = result.s };
}

/// Generates DLEQ proof
fn step2BobDLEQ(B_: Point, a: Scalar, C_: Point) !struct { C_: Point, e: Scalar, s: Scalar } {
    const p = Scalar.random();
    const R1 = try Point.basePoint.mul(p.toBytes(.little), .little);
    const R2 = try B_.mul(p.toBytes(.little), .little);
    const A = try Point.basePoint.mul(a.toBytes(.little), .little);

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
    const sG = try Point.basePoint.mul(s.toBytes(.little), .little);
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
    const rG = try Point.basePoint.mul(r.toBytes(.little), .little);
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

/// End-to-end test scenario for BDHKE
pub fn testBDHKE() !void {
    // Initialize
    const secret_msg = "test_message";
    const a = Scalar.random();
    const A = try Point.basePoint.mul(a.toBytes(.little), .little);

    std.debug.print("Starting BDHKE test\n", .{});
    std.debug.print("Secret message: {s}\n", .{secret_msg});
    const r = Scalar.random();

    const blinding_factor = try Point.basePoint.mul(r.toBytes(.little), .little);
    // Step 1: Alice blinds the message
    const B_ = try step1Alice(secret_msg, blinding_factor);

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
        return BDHKEError.VerificationFailed;
    }
    std.debug.print("Alice's DLEQ verification successful\n", .{});

    // Step 3: Alice unblinds the signature
    const C = try step3Alice(C_, r, A);

    std.debug.print("Step 3 complete: Signature unblinded\n", .{});

    // Carol verifies DLEQ proof
    const carol_verification = try carolVerifyDLEQ(secret_msg, r, C, e, s, A);
    if (!carol_verification) {
        return BDHKEError.VerificationFailed;
    }
    std.debug.print("Carol's DLEQ verification successful\n", .{});

    // Final verification
    const final_verification = try verify(a, C, secret_msg);
    if (!final_verification) {
        return BDHKEError.VerificationFailed;
    }
    std.debug.print("Final verification successful\n", .{});

    std.debug.print("BDHKE test completed successfully\n", .{});
}

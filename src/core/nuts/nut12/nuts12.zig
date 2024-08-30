//! NUT-12: Offline ecash signature validation
//!
//! <https://github.com/cashubtc/nuts/blob/main/12.md>
const std = @import("std");
const secp256k1 = @import("../../secp256k1.zig");
const dhke = @import("../../dhke.zig");
const Proof = @import("../nut00/lib.zig").Proof;
const BlindSignature = @import("../nut00/lib.zig").BlindSignature;
const Id = @import("../nut02/nut02.zig").Id;

/// Blinded Signature on Dleq
///
/// Defined in [NUT12](https://github.com/cashubtc/nuts/blob/main/12.md)
pub const BlindSignatureDleq = struct {
    /// e
    e: secp256k1.SecretKey,
    /// s
    s: secp256k1.SecretKey,

    // pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
    //     const value = try std.json.innerParse([]const u8, allocator, source, options);
    //     std.log.warn("ssss {s}", .{value});
    //     return undefined;
    // }
};

/// Proof Dleq
///
/// Defined in [NUT12](https://github.com/cashubtc/nuts/blob/main/12.md)
pub const ProofDleq = struct {
    /// e
    e: secp256k1.SecretKey,
    /// s
    s: secp256k1.SecretKey,
    /// Blinding factor
    r: secp256k1.SecretKey,
};

/// Verify DLEQ
fn verifyDleq(
    blinded_message: secp256k1.PublicKey, // B'
    blinded_signature: secp256k1.PublicKey, // C'
    _e: secp256k1.SecretKey,
    _s: secp256k1.SecretKey,
    mint_pubkey: secp256k1.PublicKey, // A
) !void {
    const e_bytes: [32]u8 = _e.data;
    const e: secp256k1.Scalar = secp256k1.Scalar.fromSecretKey(_e);

    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    // a = e*A
    var a = try mint_pubkey.mulTweak(&secp, e);

    // R1 = s*G - a
    a = a.negate(&secp);
    const r1 = try _s.publicKey(secp).combine(a); // s*G + (-a)

    // b = s*B'
    const s = secp256k1.Scalar.fromSecretKey(_s);
    const b = try blinded_message.mulTweak(&secp, s);

    // c = e*C'
    var c = try blinded_signature.mulTweak(&secp, e);

    // R2 = b - c
    c = c.negate(&secp);
    const r2 = try b.combine(c);

    // hash(R1,R2,A,C')
    const hash_e = dhke.hashE(&.{ r1, r2, mint_pubkey, blinded_signature });

    if (!std.meta.eql(e_bytes, hash_e)) {
        std.log.warn("DLEQ on signature failed", .{});
        std.log.warn("e_bytes: {any}, hash_e: {any}", .{ e_bytes, hash_e });
        return error.InvalidDleqProof;
    }
}

fn calculateDleq(
    secp: secp256k1.Secp256k1,
    blinded_signature: secp256k1.PublicKey, // C'
    blinded_message: secp256k1.PublicKey, // B'
    mint_secret_key: secp256k1.SecretKey, // a
) !BlindSignatureDleq {
    // Random nonce
    const r = secp256k1.SecretKey.generate();

    // R1 = r*G
    const r1 = r.publicKey(secp);

    // R2 = r*B'
    const r_scal = secp256k1.Scalar.fromSecretKey(r);

    const r2 = try blinded_message.mulTweak(&secp, r_scal);

    // e = hash(R1,R2,A,C')
    const e = dhke.hashE(&.{ r1, r2, mint_secret_key.publicKey(secp), blinded_signature });
    const e_sk = try secp256k1.SecretKey.fromSlice(&e);

    // s1 = e*a
    const s1 = try e_sk.mulTweak(secp256k1.Scalar.fromSecretKey(mint_secret_key));

    // s = r + s1
    const s = try r.addTweak(secp256k1.Scalar.fromSecretKey(s1));

    return .{
        .e = e_sk,
        .s = s,
    };
}

/// Verify proof Dleq by [`Proof`]
pub fn verifyDleqByProof(self: *const Proof, secp: secp256k1.Secp256k1, mint_pubkey: secp256k1.PublicKey) !void {
    if (self.dleq) |dleq| {
        const y = try dhke.hashToCurve(self.secret.inner);

        const r = secp256k1.Scalar.fromSecretKey(dleq.r);
        const bs1 = try mint_pubkey.mulTweak(&secp, r);

        const blinded_signature = try self.c.combine(bs1);
        const blinded_message = try y.combine(dleq.r.publicKey(secp));

        return try verifyDleq(
            blinded_message,
            blinded_signature,
            dleq.e,
            dleq.s,
            mint_pubkey,
        );
    }

    return error.MissingDleqProof;
}

/// Verify dleq on proof by [`BlindSignature`]
pub inline fn verifyDleqByBlindSignature(
    self: BlindSignature,
    mint_pubkey: secp256k1.PublicKey,
    blinded_message: secp256k1.PublicKey,
) !void {
    if (self.dleq) |dleq| {
        return try verifyDleq(blinded_message, self.c, dleq.e, dleq.s, mint_pubkey);
    }

    return error.MissingDleqProof;
}

/// Add Dleq to proof for [`BlindSignature`]
///    r = random nonce
///    R1 = r*G
///    R2 = r*B'
///    e = hash(R1,R2,A,C')
///    s = r + e*a
pub fn addDleqProofByBlindSignature(
    self: *BlindSignature,
    secp: secp256k1.Secp256k1,
    blinded_message: secp256k1.PublicKey,
    mint_secretkey: secp256k1.SecretKey,
) !void {
    const dleq = try calculateDleq(secp, self.c, blinded_message, mint_secretkey);
    self.dleq = dleq;
}

/// New DLEQ for [`BlindSignature`]
pub inline fn initBlindSignature(
    secp: secp256k1.Secp256k1,
    amount: u64,
    blinded_signature: secp256k1.PublicKey,
    keyset_id: Id,
    blinded_message: secp256k1.PublicKey,
    mint_secretkey: secp256k1.SecretKey,
) !BlindSignature {
    return .{
        .amount = amount,
        .keyset_id = keyset_id,
        .c = blinded_signature,
        .dleq = try calculateDleq(secp, blinded_signature, blinded_message, mint_secretkey),
    };
}

test "test_blind_signature_dleq" {
    const blinded_sig =
        \\{"amount":8,"id":"00882760bfa2eb41","C_":"02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2","dleq":{"e":"9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73d9","s":"9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73da"}}
    ;

    const blinded = try std.json.parseFromSlice(BlindSignature, std.testing.allocator, blinded_sig, .{});
    defer blinded.deinit();

    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    const secret_key =
        try secp256k1.SecretKey.fromString("0000000000000000000000000000000000000000000000000000000000000001");

    const mint_key = secret_key.publicKey(secp);

    const blinded_secret = try secp256k1.PublicKey.fromString(
        "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2",
    );

    try verifyDleqByBlindSignature(blinded.value, mint_key, blinded_secret);
}

test "test_proof_dleq" {
    const proof_json =
        \\{"amount": 1,"id": "00882760bfa2eb41","secret": "daf4dd00a2b68a0858a80450f52c8a7d2ccf87d375e43e216e0c571f089f63e9","C": "024369d2d22a80ecf78f3937da9d5f30c1b9f74f0c32684d583cca0fa6a61cdcfc","dleq": {"e": "b31e58ac6527f34975ffab13e70a48b6d2b0d35abc4b03f0151f09ee1a9763d4","s": "8fbae004c59e754d71df67e392b6ae4e29293113ddc2ec86592a0431d16306d8","r": "a6d13fcd7a18442e6076f5e1e7c887ad5de40a019824bdfa9fe740d302e8d861"}}
    ;

    const proof = try std.json.parseFromSlice(Proof, std.testing.allocator, proof_json, .{});
    defer proof.deinit();

    // A
    const a = try secp256k1.PublicKey.fromString(
        "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
    );
    const secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    try verifyDleqByProof(&proof.value, secp, a);
}

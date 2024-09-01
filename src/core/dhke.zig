//! Diffie-Hellmann key exchange
const std = @import("std");
const secp256k1 = @import("secp256k1.zig");
const secret_lib = @import("secret.zig");
const nuts = @import("nuts/lib.zig");

const DOMAIN_SEPARATOR = "Secp256k1_HashToCurve_Cashu_";

/// Deterministically maps a message to a public key point on the secp256k1 curve, utilizing a domain separator to ensure uniqueness.
///
/// For definationn in NUT see [NUT-00](https://github.com/cashubtc/nuts/blob/main/00.md)
pub fn hashToCurve(message: []const u8) !secp256k1.PublicKey {
    const domain_separator = "Secp256k1_HashToCurve_Cashu_";
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    hasher.update(domain_separator);
    hasher.update(message);

    const msg_to_hash = hasher.finalResult();

    var buf: [33]u8 = undefined;
    buf[0] = 0x02;

    var counter_buf: [4]u8 = undefined;

    const till = comptime try std.math.powi(u32, 2, 16);

    var counter: u32 = 0;

    while (counter < till) : (counter += 1) {
        hasher = std.crypto.hash.sha2.Sha256.init(.{});

        hasher.update(&msg_to_hash);
        std.mem.writeInt(u32, &counter_buf, counter, .little);
        hasher.update(&counter_buf);
        hasher.final(buf[1..]);

        const pk = secp256k1.PublicKey.fromSlice(&buf) catch continue;

        return pk;
    }

    return error.NoValidPointFound;
}

/// Convert iterator of [`PublicKey`] to byte array
pub fn hashE(public_keys: []const secp256k1.PublicKey) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (public_keys) |pk| {
        const uncompressed = pk.serializeUncompressed();
        hasher.update(&std.fmt.bytesToHex(uncompressed, .lower));
    }

    return hasher.finalResult();
}

/// Blind Message
///
/// `B_ = Y + rG`
pub fn blindMessage(
    secp: secp256k1.Secp256k1,
    secret: []const u8,
    blinding_factor: ?secp256k1.SecretKey,
) !struct { secp256k1.PublicKey, secp256k1.SecretKey } {
    const y = try hashToCurve(secret);
    const r = blinding_factor orelse secp256k1.SecretKey.generate();

    return .{ try y.combine(r.publicKey(secp)), r };
}

/// Unblind Message
///
/// `C_ - rK`
pub fn unblindMessage(
    secp: secp256k1.Secp256k1,
    // C_
    blinded_key: secp256k1.PublicKey,
    _r: secp256k1.SecretKey,
    // K
    mint_pubkey: secp256k1.PublicKey,
) !secp256k1.PublicKey {
    const r = secp256k1.Scalar.fromSecretKey(_r);

    // a = r * K
    var a = try mint_pubkey.mulTweak(&secp, r);

    // C_ - a
    a = a.negate(&secp);

    return try blinded_key.combine(a);
}

/// Construct Proof
pub fn constructProofs(
    allocator: std.mem.Allocator,
    secp: secp256k1.Secp256k1,
    promises: []const nuts.BlindSignature,
    rs: []const secp256k1.SecretKey,
    secrets: []const secret_lib.Secret,
    keys: nuts.Keys,
) !std.ArrayList(nuts.Proof) {
    var proofs = std.ArrayList(nuts.Proof).init(allocator);
    errdefer proofs.deinit();

    for (promises, rs, secrets) |blinded_signature, r, secret| {
        const blinded_c = blinded_signature.c;

        const a = keys.amountKey(blinded_signature.amount) orelse return error.CantGetProofs;

        const unblinded_signature = try unblindMessage(secp, blinded_c, r, a);

        const dleq: ?nuts.ProofDleq = if (blinded_signature.dleq) |d|
            nuts.ProofDleq{
                .e = d.e,
                .s = d.s,
                .r = r,
            }
        else
            null;
        try proofs.append(nuts.Proof{
            .amount = blinded_signature.amount,
            .keyset_id = blinded_signature.keyset_id,
            .secret = secret,
            .c = unblinded_signature,
            .witness = null,
            .dleq = dleq,
        });
    }

    return proofs;
}

/// Sign Blinded Message
///
/// `C_ = k * B_`, where:
/// * `k` is the private key of mint (one for each amount)
/// * `B_` is the blinded message
pub inline fn signMessage(secp: secp256k1.Secp256k1, k: secp256k1.SecretKey, blinded_message: secp256k1.PublicKey) !secp256k1.PublicKey {
    const _k = secp256k1.Scalar.fromSecretKey(k);
    return try blinded_message.mulTweak(&secp, _k);
}

/// Verify Message
pub fn verifyMessage(
    secp: secp256k1.Secp256k1,
    a: secp256k1.SecretKey,
    unblinded_message: secp256k1.PublicKey,
    msg: []const u8,
) !void {
    // Y
    const y = try hashToCurve(msg);

    // Compute the expected unblinded message
    const expected_unblinded_message = try y
        .mulTweak(&secp, secp256k1.Scalar.fromSecretKey(a));

    // Compare the unblinded_message with the expected value
    if (unblinded_message.eql(expected_unblinded_message))
        return;

    return error.TokenNotVerified;
}

test "test_hash_to_curve" {
    var hex_buffer: [100]u8 = undefined;

    var secret = "0000000000000000000000000000000000000000000000000000000000000000";

    var sec_hex = try std.fmt.hexToBytes(&hex_buffer, secret);

    var y = try hashToCurve(sec_hex);
    var expected_y = try secp256k1.PublicKey.fromString(
        "024cce997d3b518f739663b757deaec95bcd9473c30a14ac2fd04023a739d1a725",
    );

    try std.testing.expectEqual(y, expected_y);

    secret = "0000000000000000000000000000000000000000000000000000000000000001";

    sec_hex = try std.fmt.hexToBytes(&hex_buffer, secret);

    y = try hashToCurve(sec_hex);
    expected_y = try secp256k1.PublicKey.fromString(
        "022e7158e11c9506f1aa4248bf531298daa7febd6194f003edcd9b93ade6253acf",
    );

    try std.testing.expectEqual(y, expected_y);

    secret = "0000000000000000000000000000000000000000000000000000000000000002";

    sec_hex = try std.fmt.hexToBytes(&hex_buffer, secret);

    y = try hashToCurve(sec_hex);
    expected_y = try secp256k1.PublicKey.fromString(
        "026cdbe15362df59cd1dd3c9c11de8aedac2106eca69236ecd9fbe117af897be4f",
    );

    try std.testing.expectEqual(y, expected_y);
}

const std = @import("std");
const secp256k1 = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_recovery.h");
    @cInclude("secp256k1_preallocated.h");
});

const crypto = std.crypto;

pub const Secp256k1 = struct {
    ctx: ?*secp256k1.struct_secp256k1_context_struct,
    ptr: []align(16) u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(@as([]align(16) u8, @ptrCast(self.ptr)));
    }

    pub fn genNew(allocator: std.mem.Allocator) !@This() {
        // verify and sign only
        const size: usize = secp256k1.secp256k1_context_preallocated_size(257 | 513);

        const ptr = try allocator.alignedAlloc(u8, 16, size);

        const ctx =
            secp256k1.secp256k1_context_preallocated_create(ptr.ptr, 257 | 513);

        var seed: [32]u8 = undefined;

        var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        rng.fill(&seed);

        const res = secp256k1.secp256k1_context_randomize(ctx, &seed);
        std.debug.assert(res == 1);

        return .{
            .ctx = ctx,
            .ptr = ptr,
        };
    }
};

pub const Scalar = struct {
    data: [32]u8,

    pub inline fn fromSecretKey(sk: SecretKey) @This() {
        return .{ .data = sk.secretBytes() };
    }
};

pub const PublicKey = struct {
    pk: secp256k1.secp256k1_pubkey,

    pub fn fromSlice(c: []const u8) !@This() {
        var pk: secp256k1.secp256k1_pubkey = .{};

        if (secp256k1.secp256k1_ec_pubkey_parse(secp256k1.secp256k1_context_no_precomp, &pk, c.ptr, c.len) == 1) {
            return .{ .pk = pk };
        }
        return error.InvalidPublicKey;
    }

    pub fn fromSecretKey(secp_: Secp256k1, sk: SecretKey) PublicKey {
        var pk: secp256k1.secp256k1_pubkey = .{};

        const res = secp256k1.secp256k1_ec_pubkey_create(secp_.ctx, &pk, &sk.data);

        std.debug.assert(res == 1);

        return PublicKey{ .pk = pk };
    }

    /// Serializes the key as a byte-encoded pair of values. In compressed form the y-coordinate is
    /// represented by only a single bit, as x determines it up to one bit.
    pub fn serialize(self: PublicKey) [33]u8 {
        var ret = [_]u8{0} ** 33;
        self.serializeInternal(&ret, 258);

        return ret;
    }

    inline fn serializeInternal(self: PublicKey, ret: []u8, flag: u32) void {
        var ret_len = ret.len;

        const res = secp256k1.secp256k1_ec_pubkey_serialize(secp256k1.secp256k1_context_no_precomp, ret.ptr, &ret_len, &self.pk, flag);

        std.debug.assert(res == 1);
        std.debug.assert(ret_len == ret.len);
    }

    pub fn negate(self: @This(), secp: *const Secp256k1) PublicKey {
        var pk = self.pk;
        const res = secp256k1.secp256k1_ec_pubkey_negate(secp.ctx, &pk);

        std.debug.assert(res == 1);

        return .{ .pk = pk };
    }

    pub fn mulTweak(self: @This(), secp: *const Secp256k1, other: Scalar) !PublicKey {
        var pk = self.pk;
        if (secp256k1.secp256k1_ec_pubkey_tweak_mul(secp.ctx, &pk, @ptrCast(&other.data)) == 1) return .{ .pk = pk };

        return error.InvalidTweak;
    }

    pub fn combine(self: @This(), other: PublicKey) !PublicKey {
        return PublicKey.combineKeys(&.{
            &self, &other,
        });
    }

    pub fn combineKeys(keys: []const *const PublicKey) !PublicKey {
        if (keys.len == 0) return error.InvalidPublicKeySum;

        var ret = PublicKey{
            .pk = .{},
        };

        if (secp256k1.secp256k1_ec_pubkey_combine(secp256k1.secp256k1_context_no_precomp, &ret.pk, @ptrCast(keys.ptr), keys.len) == 1) return ret;

        return error.InvalidPublicKeySum;
    }
};

pub const SecretKey = struct {
    data: [32]u8,

    pub fn fromSlice(data: []const u8) !@This() {
        if (data.len != 32) {
            return error.InvalidSecretKey;
        }

        if (secp256k1.secp256k1_ec_seckey_verify(
            secp256k1.secp256k1_context_no_precomp,
            @ptrCast(data.ptr),
        ) == 0) return error.InvalidSecretKey;

        return .{
            .data = data[0..32].*,
        };
    }

    pub inline fn publicKey(self: @This(), secp: Secp256k1) PublicKey {
        return PublicKey.fromSecretKey(secp, self);
    }

    pub inline fn secretBytes(self: @This()) [32]u8 {
        return self.data;
    }
};

pub const Dhke = struct {
    const Self = @This();
    secp: Secp256k1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .secp = try Secp256k1.genNew(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self) void {
        self.secp.deinit(self.allocator);
    }

    pub fn hashToCurve(message: []const u8) !PublicKey {
        const domain_separator = "Secp256k1_HashToCurve_Cashu_";
        var hasher = crypto.hash.sha2.Sha256.init(.{});

        hasher.update(domain_separator);
        hasher.update(message);

        const msg_to_hash = hasher.finalResult();

        var buf: [33]u8 = undefined;
        buf[0] = 0x02;

        var counter_buf: [4]u8 = undefined;

        const till = comptime try std.math.powi(u32, 2, 16);

        var counter: u32 = 0;

        while (counter < till) : (counter += 1) {
            hasher = crypto.hash.sha2.Sha256.init(.{});

            hasher.update(&msg_to_hash);
            std.mem.writeInt(u32, &counter_buf, counter, .little);
            hasher.update(&counter_buf);
            hasher.final(buf[1..]);

            const pk = PublicKey.fromSlice(&buf) catch continue;

            return pk;
        }

        return error.NoValidPointFound;
    }

    pub fn step1Alice(self: Self, sec_msg: []const u8, blinding_factor: SecretKey) !PublicKey {
        const y = try Self.hashToCurve(sec_msg);

        const b = try y.combine(PublicKey.fromSecretKey(self.secp, blinding_factor));
        return b;
    }

    pub fn step2Bob(self: Self, b: PublicKey, a: SecretKey) !PublicKey {
        return try b.mulTweak(&self.secp, Scalar.fromSecretKey(a));
    }

    pub fn step3Alice(self: Self, c_: PublicKey, r: SecretKey, a: PublicKey) !PublicKey {
        return c_.combine(
            (try a
                .mulTweak(&self.secp, Scalar.fromSecretKey(r)))
                .negate(&self.secp),
        ) catch return error.Secp256k1Error;
    }

    pub fn verify(self: Self, a: SecretKey, c: PublicKey, secret_msg: []const u8) !bool {
        const y = try Self.hashToCurve(secret_msg);

        const res = try y.mulTweak(&self.secp, Scalar.fromSecretKey(a));

        return std.meta.eql(c.pk, res.pk);
    }
};

/// End-to-end test scenario for BDHKE
pub fn testBDHKE(allocator: std.mem.Allocator) !void {
    // Initialize with deterministic values
    const secret_msg = "test_message";
    var a_bytes: [32]u8 = [_]u8{0} ** 31 ++ [_]u8{1};
    var r_bytes: [32]u8 = [_]u8{0} ** 31 ++ [_]u8{1};

    const dhke = try Dhke.init(allocator);

    const a = try SecretKey.fromSlice(&a_bytes);
    const bf = try SecretKey.fromSlice(&r_bytes);

    std.debug.print("Starting BDHKE test\n", .{});
    std.debug.print("Secret message: {s}\n", .{secret_msg});
    std.debug.print("Alice's private key (a): {s}\n", .{std.fmt.fmtSliceHexLower(&a_bytes)});
    std.debug.print("Alice's public key (A): {s}\n", .{std.fmt.fmtSliceHexLower(&a.publicKey(dhke.secp).serialize())});

    // Deterministic blinding factor
    std.debug.print("r private key: {s}\n", .{std.fmt.fmtSliceHexLower(&r_bytes)});
    std.debug.print("Blinding factor (r): {s}\n", .{std.fmt.fmtSliceHexLower(&bf.publicKey(dhke.secp).serialize())});

    // Step 1: Alice blinds the message
    const B_ = try dhke.step1Alice(secret_msg, bf);
    std.debug.print("Blinded message (B_): {s}\n", .{std.fmt.fmtSliceHexLower(&B_.serialize())});
    std.debug.print("Step 1 complete: Message blinded\n", .{});

    // Step 2: Bob signs the blinded message
    const C_ = try dhke.step2Bob(B_, a);

    std.debug.print("Blinded signature (C_): {s}\n", .{std.fmt.fmtSliceHexLower(&C_.serialize())});
    std.debug.print("Step 2 complete: Blinded message signed\n", .{});

    // Step 3: Alice unblinds the signature
    const C = try dhke.step3Alice(C_, bf, a.publicKey(dhke.secp));
    std.debug.print("Unblinded signature (C): {s}\n", .{std.fmt.fmtSliceHexLower(&C.serialize())});
    std.debug.print("Step 3 complete: Signature unblinded\n", .{});

    // Final verification
    const final_verification = try dhke.verify(a, C, secret_msg);
    if (!final_verification) {
        return error.VerificationFailed;
    }
    std.debug.print("Final verification successful\n", .{});

    std.debug.print("BDHKE test completed successfully\n", .{});
}

test "testBdhke" {
    const secret_msg = "test_message";
    const a = try SecretKey.fromSlice(&[_]u8{1} ** 32);
    const blinding_factor = try SecretKey.fromSlice(&[_]u8{1} ** 32);

    const dhke = try Dhke.init(std.testing.allocator);
    defer dhke.deinit();

    const _b = try dhke.step1Alice(secret_msg, blinding_factor);

    const _c = try dhke.step2Bob(_b, a);

    const step3_c = try dhke.step3Alice(_c, blinding_factor, a.publicKey(dhke.secp));

    const res = try dhke.verify(a, step3_c, secret_msg);

    try std.testing.expect(res);
}

test "test_hash_to_curve_zero" {
    var buffer: [64]u8 = undefined;
    const hex = "0000000000000000000000000000000000000000000000000000000000000000";
    const expected_result = "024cce997d3b518f739663b757deaec95bcd9473c30a14ac2fd04023a739d1a725";

    const res = try Dhke.hashToCurve(try std.fmt.hexToBytes(&buffer, hex));

    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buffer, expected_result), &res.serialize());
}

test "test_hash_to_curve_one" {
    var buffer: [64]u8 = undefined;
    const hex = "0000000000000000000000000000000000000000000000000000000000000001";
    const expected_result = "022e7158e11c9506f1aa4248bf531298daa7febd6194f003edcd9b93ade6253acf";

    const res = try Dhke.hashToCurve(try std.fmt.hexToBytes(&buffer, hex));

    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buffer, expected_result), &res.serialize());
}

test "test_hash_to_curve_two" {
    var buffer: [64]u8 = undefined;
    const hex = "0000000000000000000000000000000000000000000000000000000000000002";
    const expected_result = "026cdbe15362df59cd1dd3c9c11de8aedac2106eca69236ecd9fbe117af897be4f";

    const res = try Dhke.hashToCurve(try std.fmt.hexToBytes(&buffer, hex));

    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buffer, expected_result), &res.serialize());
}

test "test_step1_alice" {
    const dhke = try Dhke.init(std.testing.allocator);
    defer dhke.deinit();

    var hex_buffer: [64]u8 = undefined;

    const bf = try SecretKey.fromSlice(try std.fmt.hexToBytes(&hex_buffer, "0000000000000000000000000000000000000000000000000000000000000001"));

    const pub_key = try dhke.step1Alice("test_message", bf);

    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&hex_buffer, "025cc16fe33b953e2ace39653efb3e7a7049711ae1d8a2f7a9108753f1cdea742b"), &pub_key.serialize());
}

test "test_step2_bob" {
    const dhke = try Dhke.init(std.testing.allocator);
    defer dhke.deinit();

    var hex_buffer: [64]u8 = undefined;

    const bf = try SecretKey.fromSlice(try std.fmt.hexToBytes(&hex_buffer, "0000000000000000000000000000000000000000000000000000000000000001"));

    const pub_key = try dhke.step1Alice("test_message", bf);

    const a = try SecretKey.fromSlice(try std.fmt.hexToBytes(&hex_buffer, "0000000000000000000000000000000000000000000000000000000000000001"));

    const c = try dhke.step2Bob(pub_key, a);

    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&hex_buffer, "025cc16fe33b953e2ace39653efb3e7a7049711ae1d8a2f7a9108753f1cdea742b"), &c.serialize());
}

test "test_step3_alice" {
    const dhke = try Dhke.init(std.testing.allocator);
    defer dhke.deinit();

    var hex_buffer: [64]u8 = undefined;

    const c_ = try PublicKey.fromSlice(try std.fmt.hexToBytes(&hex_buffer, "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2"));

    const bf = try SecretKey.fromSlice(try std.fmt.hexToBytes(&hex_buffer, "0000000000000000000000000000000000000000000000000000000000000001"));

    const a = try PublicKey.fromSlice(try std.fmt.hexToBytes(&hex_buffer, "020000000000000000000000000000000000000000000000000000000000000001"));

    const result = try dhke.step3Alice(c_, bf, a);

    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&hex_buffer, "03c724d7e6a5443b39ac8acf11f40420adc4f99a02e7cc1b57703d9391f6d129cd"), &result.serialize());
}

test "test_verify" {
    // # a = PrivateKey()
    // # A = a.pubkey
    // # secret_msg = "test"
    // # B_, r = step1_alice(secret_msg)
    // # C_ = step2_bob(B_, a)
    // # C = step3_alice(C_, r, A)
    // # print("C:{}, secret_msg:{}".format(C, secret_msg))
    // # assert verify(a, C, secret_msg)
    // # assert verify(a, C + C, secret_msg) == False  # adding C twice shouldn't pass
    // # assert verify(a, A, secret_msg) == False  # A shouldn't pass

    const dhke = try Dhke.init(std.testing.allocator);
    defer dhke.deinit();

    var hex_buffer: [64]u8 = undefined;

    // Generate Alice's private key and public key
    const a = try SecretKey.fromSlice(try std.fmt.hexToBytes(&hex_buffer, "0000000000000000000000000000000000000000000000000000000000000001"));

    const A = a.publicKey(dhke.secp);

    const bf = try SecretKey.fromSlice(try std.fmt.hexToBytes(&hex_buffer, "0000000000000000000000000000000000000000000000000000000000000002"));

    // Generate a shared secret

    const secret_msg = "test";

    const B_ = try dhke.step1Alice(secret_msg, bf);
    const C_ = try dhke.step2Bob(B_, a);
    const C = try dhke.step3Alice(C_, bf, A);

    try std.testing.expect(try dhke.verify(a, C, secret_msg));
    try std.testing.expect(!try dhke.verify(a, try C.combine(C), secret_msg));
    try std.testing.expect(!try dhke.verify(a, A, secret_msg));
}

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
        var pk: secp256k1.secp256k1_pubkey = undefined;

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

        const till = comptime try std.math.powi(u32, 2, 16);

        var counter: u32 = 0;

        while (counter < till) : (counter += 1) {
            var h = crypto.hash.sha2.Sha256.init(.{});
            // h.update([]const u8)
            h.update(&msg_to_hash);
            h.update(std.mem.asBytes(&counter));
            h.final(buf[1..]);

            return PublicKey.fromSlice(&buf) catch continue;
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

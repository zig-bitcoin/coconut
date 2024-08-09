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

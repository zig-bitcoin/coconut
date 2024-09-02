const std = @import("std");

const secp256k1 = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_recovery.h");
    @cInclude("secp256k1_preallocated.h");
    @cInclude("secp256k1_schnorrsig.h");
});

const crypto = std.crypto;

pub const KeyPair = struct {
    inner: secp256k1.secp256k1_keypair,

    /// Creates a [`KeyPair`] directly from a Secp256k1 secret key.
    pub fn fromSecretKey(secp: *const Secp256k1, sk: *const SecretKey) !KeyPair {
        var kp = secp256k1.secp256k1_keypair{};

        if (secp256k1.secp256k1_keypair_create(secp.ctx, &kp, &sk.data) != 1) {
            @panic("the provided secret key is invalid: it is corrupted or was not produced by Secp256k1 library");
        }

        return .{ .inner = kp };
    }
};

pub const XOnlyPublicKey = struct {
    inner: secp256k1.secp256k1_xonly_pubkey,

    /// Creates a schnorr public key directly from a slice.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidPublicKey`] if the length of the data slice is not 32 bytes or the
    /// slice does not represent a valid Secp256k1 point x coordinate.
    pub inline fn fromSlice(data: []const u8) !XOnlyPublicKey {
        if (data.len == 0 or data.len != 32) {
            return error.InvalidPublicKey;
        }

        var pk: secp256k1.secp256k1_xonly_pubkey = undefined;

        if (secp256k1.secp256k1_xonly_pubkey_parse(
            secp256k1.secp256k1_context_no_precomp,
            &pk,
            data.ptr,
        ) == 1) {
            return .{ .inner = pk };
        }

        return error.InvalidPublicKey;
    }

    /// Serializes the key as a byte-encoded x coordinate value (32 bytes).
    pub inline fn serialize(self: XOnlyPublicKey) [32]u8 {
        var ret: [32]u8 = undefined;

        const err = secp256k1.secp256k1_xonly_pubkey_serialize(
            secp256k1.secp256k1_context_no_precomp,
            &ret,
            &self.inner,
        );
        std.debug.assert(err == 1);
        return ret;
    }

    /// Creates a [`PublicKey`] using the key material from `pk` combined with the `parity`.
    pub fn publicKey(pk: XOnlyPublicKey, parity: enum {
        even,
        odd,
    }) !PublicKey {
        var buf: [33]u8 = undefined;

        // First byte of a compressed key should be `0x02 AND parity`.
        buf[0] = switch (parity) {
            .even => 0x02,
            .odd => 0x03,
        };

        buf[1..33].* = pk.serialize();

        return PublicKey.fromSlice(&buf) catch @panic("buffer is valid");
    }
};

pub const Secp256k1 = struct {
    ctx: ?*secp256k1.struct_secp256k1_context_struct,

    pub fn deinit(self: @This()) void {
        secp256k1.secp256k1_context_preallocated_destroy(self.ctx);
    }

    /// Verifies a schnorr signature.
    pub fn verifySchnorr(
        self: *Secp256k1,
        sig: Signature,
        msg: [32]u8,
        pubkey: XOnlyPublicKey,
    ) !void {
        if (secp256k1.secp256k1_schnorrsig_verify(
            self.ctx,
            &sig.inner,
            &msg,
            32,
            &pubkey.inner,
        ) != 1) return error.InvalidSignature;
    }

    pub fn signSchnorrHelper(self: *const Secp256k1, msg: [32]u8, keypair: KeyPair, nonce_data: []const u8) !Signature {
        var sig: [64]u8 = undefined;

        std.debug.assert(1 == secp256k1.secp256k1_schnorrsig_sign(self.ctx, (&sig).ptr, &msg, &keypair.inner, nonce_data.ptr));

        return .{ .inner = sig };
    }

    pub fn genNew() !@This() {
        const ctx =
            secp256k1.secp256k1_context_create(257 | 513);

        var seed: [32]u8 = undefined;

        var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        rng.fill(&seed);

        const res = secp256k1.secp256k1_context_randomize(ctx, &seed);
        std.debug.assert(res == 1);

        return .{
            .ctx = ctx,
        };
    }
};

/// A tag used for recovering the public key from a compact signature.
pub const RecoveryId = struct {
    value: i32,

    /// Allows library users to create valid recovery IDs from i32.
    pub fn fromI32(id: i32) !RecoveryId {
        return switch (id) {
            0...3 => .{ .value = id },
            else => error.InvalidRecoveryId,
        };
    }

    pub fn toI32(self: RecoveryId) i32 {
        return self.value;
    }
};

/// An ECDSA signature with a recovery ID for pubkey recovery.
pub const RecoverableSignature = struct {
    sig: secp256k1.secp256k1_ecdsa_recoverable_signature,

    /// Converts a compact-encoded byte slice to a signature. This
    /// representation is nonstandard and defined by the libsecp256k1 library.
    pub fn fromCompact(data: []const u8, recid: RecoveryId) !RecoverableSignature {
        if (data.len == 0) {
            return error.InvalidSignature;
        }

        var ret = secp256k1.secp256k1_ecdsa_recoverable_signature{};

        if (data.len != 64) {
            return error.InvalidSignature;
        } else if (secp256k1.secp256k1_ecdsa_recoverable_signature_parse_compact(
            secp256k1.secp256k1_context_no_precomp,
            &ret,
            data.ptr,
            recid.value,
        ) == 1) {
            return .{ .sig = ret };
        } else {
            return error.InvalidSignature;
        }
    }

    /// Serializes the recoverable signature in compact format.
    pub fn serializeCompact(self: RecoverableSignature) !struct { RecoveryId, [64]u8 } {
        var ret = [_]u8{0} ** 64;
        var recid: i32 = 0;

        const err = secp256k1.secp256k1_ecdsa_recoverable_signature_serialize_compact(secp256k1.secp256k1_context_no_precomp, &ret, &recid, &self.sig);
        std.debug.assert(err == 1);

        return .{ .{ .value = recid }, ret };
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

    pub fn eql(self: PublicKey, other: PublicKey) bool {
        return std.mem.eql(u8, &self.pk.data, &other.pk.data);
    }

    // json serializing func
    pub fn jsonStringify(self: PublicKey, out: anytype) !void {
        try out.write(std.fmt.bytesToHex(&self.serialize(), .lower));
    }

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !@This() {
        switch (try source.next()) {
            .string => |s| {
                var hex_buffer: [60]u8 = undefined;

                const hex = std.fmt.hexToBytes(&hex_buffer, s) catch return error.UnexpectedToken;

                return PublicKey.fromSlice(hex) catch error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }

    /// Returns the [`XOnlyPublicKey`] (and it's [`Parity`]) for this [`PublicKey`].
    pub inline fn xOnlyPublicKey(self: *const PublicKey) !struct { XOnlyPublicKey, enum { even, odd } } {
        var pk_parity: i32 = 0;
        var xonly_pk = secp256k1.secp256k1_xonly_pubkey{};
        const ret = secp256k1.secp256k1_xonly_pubkey_from_pubkey(
            secp256k1.secp256k1_context_no_precomp,
            &xonly_pk,
            &pk_parity,
            &self.pk,
        );

        std.debug.assert(ret == 1);

        return .{
            .{ .inner = xonly_pk },
            if (pk_parity & 1 == 0) .even else .odd,
        };
    }

    /// Verify schnorr signature
    pub fn verify(self: *const PublicKey, secp: *Secp256k1, msg: []const u8, sig: Signature) !void {
        var hasher = crypto.hash.sha2.Sha256.init(.{});
        hasher.update(msg);

        const hash = hasher.finalResult();

        try secp.verifySchnorr(sig, hash, (try self.xOnlyPublicKey())[0]);
    }

    /// [`PublicKey`] from hex string
    pub fn fromString(s: []const u8) !@This() {
        var buf: [100]u8 = undefined;
        const decoded = try std.fmt.hexToBytes(&buf, s);

        return PublicKey.fromSlice(decoded);
    }

    /// [`PublicKey`] from bytes slice
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

    /// Serializes the key as a byte-encoded pair of values, in uncompressed form.
    pub inline fn serializeUncompressed(self: PublicKey) [65]u8 {
        var ret = [_]u8{0} ** 65;

        self.serializeInternal(&ret, 2);
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

    /// Tweaks a [`PublicKey`] by adding `tweak * G` modulo the curve order.
    ///
    /// # Errors
    ///
    /// Returns an error if the resulting key would be invalid.
    pub inline fn addExpTweak(
        self: *const PublicKey,
        secp: Secp256k1,
        tweak: Scalar,
    ) !PublicKey {
        var s = self.*;
        if (secp256k1.secp256k1_ec_pubkey_tweak_add(secp.ctx, &s.pk, &tweak.data) == 1) {
            return s;
        } else {
            return error.InvalidTweak;
        }
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

    pub fn toString(self: @This()) [33 * 2]u8 {
        return std.fmt.bytesToHex(&self.serialize(), .lower);
    }
};

pub const Signature = struct {
    inner: [64]u8,

    pub fn fromString(s: []const u8) !Signature {
        if (s.len / 2 > 64) return error.InvalidSignature;
        var res = [_]u8{0} ** 64;

        _ = try std.fmt.hexToBytes(&res, s);
        return .{ .inner = res };
    }

    pub fn toString(self: Signature) [128]u8 {
        return std.fmt.bytesToHex(&self.inner, .lower);
    }
};

pub const SecretKey = struct {
    data: [32]u8,

    /// Generate random [`SecretKey`]
    pub fn generate() SecretKey {
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));

        var d: [32]u8 = undefined;

        while (true) {
            rng.fill(&d);
            if (SecretKey.fromSlice(&d)) |sk| return sk else |_| continue;
        }
    }

    /// Schnorr Signature on Message
    pub fn sign(self: *const SecretKey, msg: []const u8) !Signature {
        var hasher = crypto.hash.sha2.Sha256.init(.{});
        hasher.update(msg);

        const hash = hasher.finalResult();

        var secp = try Secp256k1.genNew();
        defer secp.deinit();

        var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));

        var aux: [32]u8 = undefined;
        rng.fill(&aux);

        return secp.signSchnorrHelper(hash, try KeyPair.fromSecretKey(&secp, self), &aux);
    }

    pub fn fromString(data: []const u8) !@This() {
        var buf: [100]u8 = undefined;

        return SecretKey.fromSlice(try std.fmt.hexToBytes(&buf, data));
    }

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

    pub fn toString(self: @This()) [32 * 2]u8 {
        return std.fmt.bytesToHex(&self.data, .lower);
    }

    /// Tweaks a [`SecretKey`] by multiplying by `tweak` modulo the curve order.
    ///
    /// # Errors
    ///
    /// Returns an error if the resulting key would be invalid.
    pub inline fn mulTweak(self: *const SecretKey, tweak: Scalar) !SecretKey {
        var s = self.*;
        if (secp256k1.secp256k1_ec_seckey_tweak_mul(
            secp256k1.secp256k1_context_no_precomp,
            &s.data,
            &tweak.data,
        ) != 1) {
            return error.InvalidTweak;
        }

        return s;
    }

    /// Tweaks a [`SecretKey`] by adding `tweak` modulo the curve order.
    ///
    /// # Errors
    ///
    /// Returns an error if the resulting key would be invalid.
    pub inline fn addTweak(self: *const SecretKey, tweak: Scalar) !SecretKey {
        var s = self.*;
        if (secp256k1.secp256k1_ec_seckey_tweak_add(
            secp256k1.secp256k1_context_no_precomp,
            &s.data,
            &tweak.data,
        ) != 1) {
            return error.InvalidTweak;
        } else {
            return s;
        }
    }

    pub fn jsonStringify(self: *const SecretKey, out: anytype) !void {
        try out.write(self.toString());
    }

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !@This() {
        return switch (try source.next()) {
            .string, .allocated_string => |hex_sec| SecretKey.fromString(hex_sec) catch return error.UnexpectedToken,
            else => return error.UnexpectedToken,
        };
    }
};

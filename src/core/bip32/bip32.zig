//! BIP32 implementation.
//!
//! Implementation of BIP32 hierarchical deterministic wallets, as defined
//! at <https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki>.
//!
const Ripemd160 = @import("../../mint/lightning/invoices/ripemd160.zig").Ripemd160;
const secp256k1 = @import("../secp256k1.zig");
const Secp256k1NumberOfPoints = 115792089237316195423570985008687907852837564279074904382605163141518161494337;
const key_lib = @import("key.zig");

const base58 = @import("base58");

const std = @import("std");
const Hmac = std.crypto.auth.hmac.sha2.HmacSha512;

pub const Network = enum { MAINNET, TESTNET, REGTEST, SIMNET };

pub const SerializedPrivateKeyVersion = enum(u32) {
    MAINNET = 0x0488aDe4,
    TESTNET = 0x04358394,
    SEGWIT_MAINNET = 0x04b2430c,
    SEGWIT_TESTNET = 0x045f18bc,
};

pub const SerializedPublicKeyVersion = enum(u32) {
    MAINNET = 0x0488b21e,
    TESTNET = 0x043587cf,
    SEGWIT_MAINNET = 0x04b24746,
    SEGWIT_TESTNET = 0x045f1cf6,
};

/// A chain code
pub const ChainCode = struct {
    inner: [32]u8,

    fn fromHmac(hmac: [64]u8) ChainCode {
        return .{ .inner = hmac[32..].* };
    }
};

/// A fingerprint
pub const Fingerprint = struct {
    inner: [4]u8,
};

fn base58EncodeCheck(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoder = base58.Encoder.init(.{});

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var checksum = hasher.finalResult();

    hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&checksum);
    checksum = hasher.finalResult();

    var encoding_data = try allocator.alloc(u8, data.len + 4);
    defer allocator.free(encoding_data);

    @memcpy(encoding_data[0..data.len], data);
    @memcpy(encoding_data[data.len..], checksum[0..4]);

    return try encoder.encodeAlloc(allocator, encoding_data);
}

fn base58DecodeCheck(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const decoder = base58.Decoder.init(.{});

    const decoded = try decoder.decodeAlloc(allocator, data);
    defer allocator.free(decoded);
    if (decoded.len < 4) return error.TooShortError;

    const check_start = decoded.len - 4;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    hasher.update(decoded[0..check_start]);
    const fr = hasher.finalResult();

    hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&fr);

    const hash_check = hasher.finalResult()[0..4].*;
    const data_check = decoded[check_start..][0..4].*;

    const expected = std.mem.readInt(u32, &hash_check, .little);
    const actual = std.mem.readInt(u32, &data_check, .little);

    if (expected != actual) return error.IncorrectChecksum;

    const result = try allocator.alloc(u8, check_start);
    errdefer allocator.free(result);

    @memcpy(result, decoded[0..check_start]);
    return result;
}

/// Extended private key
pub const ExtendedPrivKey = struct {
    /// The network this key is to be used on
    network: Network,
    /// How many derivations this key is from the master (which is 0)
    depth: u8,
    /// Fingerprint of the parent key (0 for master)
    parent_fingerprint: Fingerprint,
    /// Child number of the key used to derive from parent (0 for master)
    child_number: ChildNumber,
    /// Private key
    private_key: secp256k1.SecretKey,
    /// Chain code
    chain_code: ChainCode,

    pub fn fromStr(allocator: std.mem.Allocator, s: []const u8) !ExtendedPrivKey {
        const decoded = try base58DecodeCheck(allocator, s);
        defer allocator.free(decoded);

        if (decoded.len != 78) return error.InvalidLength;

        return try decode(decoded);
    }

    pub fn toStr(self: ExtendedPrivKey, allocator: std.mem.Allocator) ![]const u8 {
        const encoded = self.encode();
        return base58EncodeCheck(allocator, &encoded);
    }

    /// Extended private key binary encoding according to BIP 32
    pub fn encode(self: ExtendedPrivKey) [78]u8 {
        var ret = [_]u8{0} ** 78;

        ret[0..4].* = switch (self.network) {
            .MAINNET => .{ 0x04, 0x88, 0xAD, 0xE4 },
            else => .{ 0x04, 0x35, 0x83, 0x94 },
        };

        ret[4] = self.depth;
        ret[5..9].* = self.parent_fingerprint.inner;

        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.child_number.toU32(), .big);

        ret[9..13].* = buf;
        ret[13..45].* = self.chain_code.inner;
        ret[45] = 0;
        ret[46..78].* = self.private_key.data;
        return ret;
    }

    /// Construct a new master key from a seed value
    pub fn initMaster(network: Network, seed: []const u8) !ExtendedPrivKey {
        var hmac_engine = Hmac.init("Bitcoin seed");
        hmac_engine.update(seed);
        var hmac_result: [Hmac.mac_length]u8 = undefined;

        hmac_engine.final(&hmac_result);

        return ExtendedPrivKey{
            .network = network,
            .depth = 0,
            .parent_fingerprint = .{ .inner = .{ 0, 0, 0, 0 } },
            .child_number = try ChildNumber.fromNormalIdx(0),
            .private_key = try secp256k1.SecretKey.fromSlice(hmac_result[0..32]),
            .chain_code = ChainCode.fromHmac(hmac_result),
        };
    }

    /// Constructs ECDSA compressed private key matching internal secret key representation.
    pub fn toPrivateKey(self: ExtendedPrivKey) key_lib.PrivateKey {
        return .{
            .compressed = true,
            .network = self.network,
            .inner = self.private_key,
        };
    }

    /// Constructs BIP340 keypair for Schnorr signatures and Taproot use matching the internal
    /// secret key representation.
    pub fn toKeypair(self: ExtendedPrivKey, secp: secp256k1.Secp256k1) secp256k1.KeyPair {
        return secp256k1.KeyPair.fromSecretKey(&secp, &self.private_key) catch @panic("BIP32 internal private key representation is broken");
    }

    /// Private->Private child key derivation
    pub fn ckdPriv(
        self: ExtendedPrivKey,
        secp: secp256k1.Secp256k1,
        i: ChildNumber,
    ) !ExtendedPrivKey {
        var hmac_engine = Hmac.init(self.chain_code.inner[0..]);
        switch (i) {
            .normal => {
                // Non-hardened key: compute public data and use that
                hmac_engine.update(&self.private_key.publicKey(secp).serialize());
            },
            .hardened => {
                // Hardened key: use only secret data to prevent public derivation
                hmac_engine.update(&.{0});
                hmac_engine.update(self.private_key.data[0..]);
            },
        }

        const i_u32 = i.toU32();
        var buf: [4]u8 = undefined;

        std.mem.writeInt(u32, &buf, i_u32, .big);

        hmac_engine.update(&buf);

        var hmac_result: [Hmac.mac_length]u8 = undefined;

        hmac_engine.final(&hmac_result);

        const sk = secp256k1.SecretKey.fromSlice(hmac_result[0..32]) catch @panic("statistically impossible to hit");
        const tweaked = sk.addTweak(secp256k1.Scalar.fromSecretKey(self.private_key)) catch @panic("statistically impossible to hit");

        return .{
            .network = self.network,
            .depth = self.depth + 1,
            .parent_fingerprint = self.fingerprint(secp),
            .child_number = i,
            .private_key = tweaked,
            .chain_code = ChainCode.fromHmac(hmac_result),
        };
    }

    /// Attempts to derive an extended private key from a path.
    ///
    /// The `path` argument can be both of type `DerivationPath` or `Vec<ChildNumber>`.
    pub fn derivePriv(
        self: ExtendedPrivKey,
        secp: secp256k1.Secp256k1,
        path: []ChildNumber,
    ) !ExtendedPrivKey {
        var sk = self;
        for (path) |cnum| {
            sk = try sk.ckdPriv(secp, cnum);
        }

        return sk;
    }

    /// Returns the HASH160 of the public key belonging to the xpriv
    pub fn identifier(self: ExtendedPrivKey, secp: secp256k1.Secp256k1) XpubIdentifier {
        return ExtendedPubKey.fromPrivateKey(secp, self).identifier();
    }

    /// Returns the first four bytes of the identifier
    pub fn fingerprint(self: ExtendedPrivKey, secp: secp256k1.Secp256k1) Fingerprint {
        return .{ .inner = self.identifier(secp).inner[0..4].* };
    }

    /// Decoding extended private key from binary data according to BIP 32
    pub fn decode(data: []const u8) !ExtendedPrivKey {
        if (data.len != 78) {
            return error.WrongExtendedKeyLength;
        }

        const network = if (std.mem.eql(u8, data[0..4], &.{ 0x04, 0x88, 0xAD, 0xE4 }))
            Network.MAINNET
        else if (std.mem.eql(u8, data[0..4], &.{ 0x04, 0x35, 0x83, 0x94 }))
            Network.TESTNET
        else
            return error.UnknownVersion;

        return .{
            .network = network,
            .depth = data[4],
            .parent_fingerprint = .{ .inner = data[5..9].* },
            .child_number = ChildNumber.fromU32(std.mem.readInt(u32, data[9..13], .big)),
            .chain_code = .{ .inner = data[13..45].* },
            .private_key = try secp256k1.SecretKey.fromSlice(data[46..78]),
        };
    }
};

/// Extended public key
pub const ExtendedPubKey = struct {
    /// The network this key is to be used on
    network: Network,
    /// How many derivations this key is from the master (which is 0)
    depth: u8,
    /// Fingerprint of the parent key
    parent_fingerprint: Fingerprint,
    /// Child number of the key used to derive from parent (0 for master)
    child_number: ChildNumber,
    /// Public key
    public_key: secp256k1.PublicKey,
    /// Chain code
    chain_code: ChainCode,

    pub fn fromStr(allocator: std.mem.Allocator, s: []const u8) !ExtendedPubKey {
        const decoded = try base58DecodeCheck(allocator, s);
        defer allocator.free(decoded);

        if (decoded.len != 78) return error.InvalidLength;

        return try decode(decoded);
    }

    pub fn toStr(self: ExtendedPubKey, allocator: std.mem.Allocator) ![]const u8 {
        return try base58EncodeCheck(allocator, &self.encode());
    }

    /// Extended public key binary encoding according to BIP 32
    pub fn encode(self: ExtendedPubKey) [78]u8 {
        var ret = [_]u8{0} ** 78;

        ret[0..4].* = switch (self.network) {
            .MAINNET => .{ 0x04, 0x88, 0xB2, 0x1E },
            else => .{ 0x04, 0x35, 0x87, 0xCF },
        };

        ret[4] = self.depth;
        ret[5..9].* = self.parent_fingerprint.inner;

        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.child_number.toU32(), .big);

        ret[9..13].* = buf;
        ret[13..45].* = self.chain_code.inner;
        ret[45..78].* = self.public_key.serialize();
        return ret;
    }

    pub fn decode(data: []const u8) !ExtendedPubKey {
        if (data.len != 78) {
            return error.WrongExtendedKeyLength;
        }

        const network = if (std.mem.eql(u8, data[0..4], &.{ 0x04, 0x88, 0xB2, 0x1E }))
            Network.MAINNET
        else if (std.mem.eql(u8, data[0..4], &.{ 0x04, 0x35, 0x87, 0xCF }))
            Network.TESTNET
        else
            return error.UnknownVersion;

        return .{
            .network = network,
            .depth = data[4],
            .parent_fingerprint = .{ .inner = data[5..9].* },
            .child_number = ChildNumber.fromU32(std.mem.readInt(u32, data[9..13], .big)),
            .chain_code = .{ .inner = data[13..45].* },
            .public_key = try secp256k1.PublicKey.fromSlice(data[45..78]),
        };
    }

    /// Derives a public key from a private key
    pub fn fromPrivateKey(
        secp: secp256k1.Secp256k1,
        sk: ExtendedPrivKey,
    ) ExtendedPubKey {
        return .{
            .network = sk.network,
            .depth = sk.depth,
            .parent_fingerprint = sk.parent_fingerprint,
            .child_number = sk.child_number,
            .public_key = sk.private_key.publicKey(secp),
            .chain_code = sk.chain_code,
        };
    }

    /// Attempts to derive an extended public key from a path.
    ///
    /// The `path` argument can be any type implementing `AsRef<ChildNumber>`, such as `DerivationPath`, for instance.
    pub fn derivePub(
        self: ExtendedPubKey,
        secp: secp256k1.Secp256k1,
        path: []ChildNumber,
    ) !ExtendedPubKey {
        var pk = self;
        for (path) |cnum| {
            pk = try pk.ckdPub(secp, cnum);
        }

        return pk;
    }

    /// Compute the scalar tweak added to this key to get a child key
    pub fn ckdPubTweak(
        self: ExtendedPubKey,
        i: ChildNumber,
    ) !struct { secp256k1.SecretKey, ChainCode } {
        switch (i) {
            .hardened => return error.CannotDeriveFromHardenedKey,
            .normal => |n| {
                var hmac_engine = Hmac.init(&self.chain_code.inner);

                hmac_engine.update(&self.public_key.serialize());

                var buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &buf, n, .big);

                hmac_engine.update(&buf);
                var hmac_result: [Hmac.mac_length]u8 = undefined;
                hmac_engine.final(&hmac_result);

                const private_key = try secp256k1.SecretKey.fromSlice(hmac_result[0..32]);
                const chain_code = ChainCode.fromHmac(hmac_result);

                return .{ private_key, chain_code };
            },
        }
    }

    /// Public->Public child key derivation
    pub fn ckdPub(
        self: ExtendedPubKey,
        secp: secp256k1.Secp256k1,
        i: ChildNumber,
    ) !ExtendedPubKey {
        const sk, const chain_code = try self.ckdPubTweak(i);

        const tweaked = try self.public_key.addExpTweak(secp, secp256k1.Scalar.fromSecretKey(sk));

        return .{
            .network = self.network,
            .depth = self.depth + 1,
            .parent_fingerprint = self.fingerprint(),
            .child_number = i,
            .public_key = tweaked,
            .chain_code = chain_code,
        };
    }

    /// Returns the HASH160 of the chaincode
    pub fn identifier(self: ExtendedPubKey) XpubIdentifier {
        return .{ .inner = hash160(&self.public_key.serialize()) };
    }

    /// Returns the first four bytes of the identifier
    pub fn fingerprint(self: ExtendedPubKey) Fingerprint {
        return .{ .inner = self.identifier().inner[0..4].* };
    }
};

fn hash160(data: []const u8) [Ripemd160.digest_length]u8 {
    var hasher256 = std.crypto.hash.sha2.Sha256.init(.{});
    hasher256.update(data);

    var out256: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher256.final(&out256);

    var hasher = Ripemd160.init(.{});
    hasher.update(&out256);

    var out: [Ripemd160.digest_length]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub const XpubIdentifier = struct {
    inner: [Ripemd160.digest_length]u8,
};

/// A child number for a derived key
pub const ChildNumber = union(enum) {
    /// Non-hardened key
    /// Key index, within [0, 2^31 - 1]
    normal: u32,
    /// Hardened key
    /// Key index, within [0, 2^31 - 1]
    hardened: u32,

    pub fn fromStr(inp: []const u8) !ChildNumber {
        const is_hardened = (inp[inp.len - 1] == '\'' or inp[inp.len - 1] == 'h');

        if (is_hardened) return try fromHardenedIdx(try std.fmt.parseInt(u32, inp[0 .. inp.len - 1], 10)) else return try fromNormalIdx(try std.fmt.parseInt(u32, inp, 10));
    }

    /// Create a [`Normal`] from an index, returns an error if the index is not within
    /// [0, 2^31 - 1].
    ///
    /// [`Normal`]: #variant.Normal
    pub fn fromNormalIdx(index: u32) !ChildNumber {
        if ((index & (1 << 31)) == 0)
            return .{ .normal = index };

        return error.InvalidChildNumber;
    }

    /// Create a [`Hardened`] from an index, returns an error if the index is not within
    /// [0, 2^31 - 1].
    ///
    /// [`Hardened`]: #variant.Hardened
    pub fn fromHardenedIdx(index: u32) !ChildNumber {
        if (index & (1 << 31) == 0)
            return .{ .hardened = index };

        return error.InvalidChildNumber;
    }

    /// Returns `true` if the child number is a [`Normal`] value.
    ///
    /// [`Normal`]: #variant.Normal
    pub fn isNormal(self: ChildNumber) bool {
        return !self.isHardened();
    }

    /// Returns `true` if the child number is a [`Hardened`] value.
    ///
    /// [`Hardened`]: #variant.Hardened
    pub fn isHardened(self: ChildNumber) bool {
        return switch (self) {
            .hardened => true,
            .normal => false,
        };
    }
    /// Returns the child number that is a single increment from this one.
    pub fn increment(self: ChildNumber) !ChildNumber {
        return switch (self) {
            .hardened => |idx| try fromHardenedIdx(idx + 1),
            .normal => |idx| try fromNormalIdx(idx + 1),
        };
    }

    fn fromU32(number: u32) ChildNumber {
        if (number & (1 << 31) != 0) {
            return .{
                .hardened = number ^ (1 << 31),
            };
        } else {
            return .{ .normal = number };
        }
    }

    fn toU32(self: ChildNumber) u32 {
        return switch (self) {
            .normal => |index| index,
            .hardened => |index| index | (1 << 31),
        };
    }
};

fn testPath(
    secp: secp256k1.Secp256k1,
    network: Network,
    seed: []const u8,
    path: []ChildNumber,
    expected_sk: []const u8,
    expected_pk: []const u8,
) !void {
    var sk = try ExtendedPrivKey.initMaster(network, seed);
    var pk = ExtendedPubKey.fromPrivateKey(secp, sk);

    // Check derivation convenience method for ExtendedPrivKey
    {
        const actual_sk = try (try sk.derivePriv(secp, path)).toStr(std.testing.allocator);
        defer std.testing.allocator.free(actual_sk);

        try std.testing.expectEqualSlices(
            u8,
            actual_sk,
            expected_sk,
        );
    }

    // Check derivation convenience method for ExtendedPubKey, should error
    // appropriately if any ChildNumber is hardened
    for (path) |cnum| {
        if (cnum.isHardened()) {
            try std.testing.expectError(error.CannotDeriveFromHardenedKey, pk.derivePub(secp, path));
            break;
        }
    } else {
        const derivedPub = try (try pk.derivePub(secp, path)).toStr(std.testing.allocator);
        defer std.testing.allocator.free(derivedPub);

        try std.testing.expectEqualSlices(u8, derivedPub, expected_pk);
    }

    // Derive keys, checking hardened and non-hardened derivation one-by-one
    for (path) |num| {
        sk = try sk.ckdPriv(secp, num);
        switch (num) {
            .normal => {
                const pk2 = try pk.ckdPub(secp, num);
                pk = ExtendedPubKey.fromPrivateKey(secp, sk);
                try std.testing.expectEqualDeep(pk, pk2);
            },
            .hardened => {
                try std.testing.expectError(error.CannotDeriveFromHardenedKey, pk.ckdPub(secp, num));
                pk = ExtendedPubKey.fromPrivateKey(secp, sk);
            },
        }
    }
    // Check result against expected base58
    const skStr = try sk.toStr(std.testing.allocator);
    defer std.testing.allocator.free(skStr);
    try std.testing.expectEqualSlices(u8, skStr, expected_sk);

    const pkStr = try pk.toStr(std.testing.allocator);
    defer std.testing.allocator.free(pkStr);
    try std.testing.expectEqualSlices(u8, pkStr, expected_pk);

    // Check decoded base58 against result
    const decoded_sk = try ExtendedPrivKey.fromStr(std.testing.allocator, expected_sk);
    const decoded_pk = try ExtendedPubKey.fromStr(std.testing.allocator, expected_pk);

    try std.testing.expectEqualDeep(decoded_sk, sk);
    try std.testing.expectEqualDeep(decoded_pk, pk);
}

fn derivatePathFromStr(path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(ChildNumber) {
    if (path.len == 0 or (path.len == 1 and path[0] == 'm') or (path.len == 2 and path[0] == 'm' and path[1] == '/')) return std.ArrayList(ChildNumber).init(allocator);

    var p = path;

    if (std.mem.startsWith(u8, path, "m/")) p = path[2..];

    var parts = std.mem.splitScalar(u8, p, '/');

    var result = std.ArrayList(ChildNumber).init(allocator);
    errdefer result.deinit();

    while (parts.next()) |s| {
        try result.append(try ChildNumber.fromStr(s));
    }

    return result;
}

test "schnorr_broken_privkey_ffs" {
    // Xpriv having secret key set to all 0xFF's
    const xpriv_str = "xprv9s21ZrQH143K24Mfq5zL5MhWK9hUhhGbd45hLXo2Pq2oqzMMo63oStZzFAzHGBP2UuGCqWLTAPLcMtD9y5gkZ6Eq3Rjuahrv17fENZ3QzxW";
    try std.testing.expectError(error.InvalidSecretKey, ExtendedPrivKey.fromStr(std.testing.allocator, xpriv_str));
}

test "vector_1" {
    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    var buf: [100]u8 = undefined;

    const seed = try std.fmt.hexToBytes(&buf, "000102030405060708090a0b0c0d0e0f");
    // derivation path, expected_sk , expected_pk
    const testSuite: []const struct { Network, []const u8, []const u8, []const u8 } = &.{
        .{
            .MAINNET,
            "m",
            "xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi",
            "xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8",
        },
        .{
            .MAINNET,
            "m/0h",
            "xprv9uHRZZhk6KAJC1avXpDAp4MDc3sQKNxDiPvvkX8Br5ngLNv1TxvUxt4cV1rGL5hj6KCesnDYUhd7oWgT11eZG7XnxHrnYeSvkzY7d2bhkJ7",
            "xpub68Gmy5EdvgibQVfPdqkBBCHxA5htiqg55crXYuXoQRKfDBFA1WEjWgP6LHhwBZeNK1VTsfTFUHCdrfp1bgwQ9xv5ski8PX9rL2dZXvgGDnw",
        },
        .{
            .MAINNET,
            "m/0h/1",
            "xprv9wTYmMFdV23N2TdNG573QoEsfRrWKQgWeibmLntzniatZvR9BmLnvSxqu53Kw1UmYPxLgboyZQaXwTCg8MSY3H2EU4pWcQDnRnrVA1xe8fs",
            "xpub6ASuArnXKPbfEwhqN6e3mwBcDTgzisQN1wXN9BJcM47sSikHjJf3UFHKkNAWbWMiGj7Wf5uMash7SyYq527Hqck2AxYysAA7xmALppuCkwQ",
        },
        .{
            .MAINNET,
            "m/0h/1/2h",
            "xprv9z4pot5VBttmtdRTWfWQmoH1taj2axGVzFqSb8C9xaxKymcFzXBDptWmT7FwuEzG3ryjH4ktypQSAewRiNMjANTtpgP4mLTj34bhnZX7UiM",
            "xpub6D4BDPcP2GT577Vvch3R8wDkScZWzQzMMUm3PWbmWvVJrZwQY4VUNgqFJPMM3No2dFDFGTsxxpG5uJh7n7epu4trkrX7x7DogT5Uv6fcLW5",
        },
        .{
            .MAINNET,
            "m/0h/1/2h/2",
            "xprvA2JDeKCSNNZky6uBCviVfJSKyQ1mDYahRjijr5idH2WwLsEd4Hsb2Tyh8RfQMuPh7f7RtyzTtdrbdqqsunu5Mm3wDvUAKRHSC34sJ7in334",
            "xpub6FHa3pjLCk84BayeJxFW2SP4XRrFd1JYnxeLeU8EqN3vDfZmbqBqaGJAyiLjTAwm6ZLRQUMv1ZACTj37sR62cfN7fe5JnJ7dh8zL4fiyLHV",
        },
        .{
            .MAINNET,
            "m/0h/1/2h/2/1000000000",
            "xprvA41z7zogVVwxVSgdKUHDy1SKmdb533PjDz7J6N6mV6uS3ze1ai8FHa8kmHScGpWmj4WggLyQjgPie1rFSruoUihUZREPSL39UNdE3BBDu76",
            "xpub6H1LXWLaKsWFhvm6RVpEL9P4KfRZSW7abD2ttkWP3SSQvnyA8FSVqNTEcYFgJS2UaFcxupHiYkro49S8yGasTvXEYBVPamhGW6cFJodrTHy",
        },
    };

    for (testSuite, 0..) |suite, idx| {
        errdefer {
            std.log.warn("suite failed n={d} : {any}", .{ idx + 1, suite });
        }

        const path = try derivatePathFromStr(suite[1], std.testing.allocator);
        defer path.deinit();

        try testPath(secp, .MAINNET, seed, path.items, suite[2], suite[3]);
    }
}

test "vector_2" {
    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    var buf: [100]u8 = undefined;

    const seed = try std.fmt.hexToBytes(&buf, "fffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542");
    // derivation path, expected_sk , expected_pk
    const testSuite: []const struct { Network, []const u8, []const u8, []const u8 } = &.{
        .{
            .MAINNET,
            "m",
            "xprv9s21ZrQH143K31xYSDQpPDxsXRTUcvj2iNHm5NUtrGiGG5e2DtALGdso3pGz6ssrdK4PFmM8NSpSBHNqPqm55Qn3LqFtT2emdEXVYsCzC2U",
            "xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB",
        },
        .{
            .MAINNET,
            "m/0",
            "xprv9vHkqa6EV4sPZHYqZznhT2NPtPCjKuDKGY38FBWLvgaDx45zo9WQRUT3dKYnjwih2yJD9mkrocEZXo1ex8G81dwSM1fwqWpWkeS3v86pgKt",
            "xpub69H7F5d8KSRgmmdJg2KhpAK8SR3DjMwAdkxj3ZuxV27CprR9LgpeyGmXUbC6wb7ERfvrnKZjXoUmmDznezpbZb7ap6r1D3tgFxHmwMkQTPH",
        },
        .{
            .MAINNET,
            "m/0/2147483647h",
            "xprv9wSp6B7kry3Vj9m1zSnLvN3xH8RdsPP1Mh7fAaR7aRLcQMKTR2vidYEeEg2mUCTAwCd6vnxVrcjfy2kRgVsFawNzmjuHc2YmYRmagcEPdU9",
            "xpub6ASAVgeehLbnwdqV6UKMHVzgqAG8Gr6riv3Fxxpj8ksbH9ebxaEyBLZ85ySDhKiLDBrQSARLq1uNRts8RuJiHjaDMBU4Zn9h8LZNnBC5y4a",
        },
        .{
            .MAINNET,
            "m/0/2147483647h/1",
            "xprv9zFnWC6h2cLgpmSA46vutJzBcfJ8yaJGg8cX1e5StJh45BBciYTRXSd25UEPVuesF9yog62tGAQtHjXajPPdbRCHuWS6T8XA2ECKADdw4Ef",
            "xpub6DF8uhdarytz3FWdA8TvFSvvAh8dP3283MY7p2V4SeE2wyWmG5mg5EwVvmdMVCQcoNJxGoWaU9DCWh89LojfZ537wTfunKau47EL2dhHKon",
        },
        .{
            .MAINNET,
            "m/0/2147483647h/1/2147483646h",
            "xprvA1RpRA33e1JQ7ifknakTFpgNXPmW2YvmhqLQYMmrj4xJXXWYpDPS3xz7iAxn8L39njGVyuoseXzU6rcxFLJ8HFsTjSyQbLYnMpCqE2VbFWc",
            "xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL",
        },
        .{
            .MAINNET,
            "m/0/2147483647h/1/2147483646h/2",
            "xprvA2nrNbFZABcdryreWet9Ea4LvTJcGsqrMzxHx98MMrotbir7yrKCEXw7nadnHM8Dq38EGfSh6dqA9QWTyefMLEcBYJUuekgW4BYPJcr9E7j",
            "xpub6FnCn6nSzZAw5Tw7cgR9bi15UV96gLZhjDstkXXxvCLsUXBGXPdSnLFbdpq8p9HmGsApME5hQTZ3emM2rnY5agb9rXpVGyy3bdW6EEgAtqt",
        },
    };

    for (testSuite, 0..) |suite, idx| {
        errdefer {
            std.log.warn("suite failed n={d} : {any}", .{ idx + 1, suite });
        }

        const path = try derivatePathFromStr(suite[1], std.testing.allocator);
        defer path.deinit();

        try testPath(secp, .MAINNET, seed, path.items, suite[2], suite[3]);
    }
}

test "vector_3" {
    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    var buf: [100]u8 = undefined;

    const seed = try std.fmt.hexToBytes(&buf, "4b381541583be4423346c643850da4b320e46a87ae3d2a4e6da11eba819cd4acba45d239319ac14f863b8d5ab5a0d0c64d2e8a1e7d1457df2e5a3c51c73235be");

    const path_1 = try derivatePathFromStr("m", std.testing.allocator);
    defer path_1.deinit();

    // m
    try testPath(secp, .MAINNET, seed, path_1.items, "xprv9s21ZrQH143K25QhxbucbDDuQ4naNntJRi4KUfWT7xo4EKsHt2QJDu7KXp1A3u7Bi1j8ph3EGsZ9Xvz9dGuVrtHHs7pXeTzjuxBrCmmhgC6", "xpub661MyMwAqRbcEZVB4dScxMAdx6d4nFc9nvyvH3v4gJL378CSRZiYmhRoP7mBy6gSPSCYk6SzXPTf3ND1cZAceL7SfJ1Z3GC8vBgp2epUt13");

    // m/0h
    const path_2 = try derivatePathFromStr("m/0h", std.testing.allocator);
    defer path_2.deinit();

    try testPath(secp, .MAINNET, seed, path_2.items, "xprv9uPDJpEQgRQfDcW7BkF7eTya6RPxXeJCqCJGHuCJ4GiRVLzkTXBAJMu2qaMWPrS7AANYqdq6vcBcBUdJCVVFceUvJFjaPdGZ2y9WACViL4L", "xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y");
}

test "base58_check_decode_encode" {
    const encoded = try base58EncodeCheck(std.testing.allocator, "test");
    defer std.testing.allocator.free(encoded);

    const decoded = try base58DecodeCheck(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, decoded, "test");
}

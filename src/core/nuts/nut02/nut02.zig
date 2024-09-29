//! NUT-02: Keysets and keyset ID
//!
//! <https://github.com/cashubtc/nuts/blob/main/02.md>

const std = @import("std");
const bitcoin_primitives = @import("bitcoin-primitives");
const bip32 = bitcoin_primitives.bips.bip32;
const secp256k1 = bitcoin_primitives.secp256k1;

const CurrencyUnit = @import("../nut00/nut00.zig").CurrencyUnit;
const Keys = @import("../nut01/nut01.zig").Keys;
const MintKeys = @import("../nut01/nut01.zig").MintKeys;
const MintKeyPair = @import("../nut01/nut01.zig").MintKeyPair;

/// Keyset version
pub const KeySetVersion = enum(u8) {
    /// Current Version 00
    version00,

    /// [`KeySetVersion`] to byte
    pub fn toByte(self: KeySetVersion) u8 {
        return switch (self) {
            .version00 => 0,
        };
    }

    /// [`KeySetVersion`] from byte
    pub fn fromByte(byte: u8) !KeySetVersion {
        return switch (byte) {
            0 => KeySetVersion.version00,
            else => error.UnknownVersion,
        };
    }
};

const STRLEN = 14;
const BYTELEN = 7;

// A keyset ID is an identifier for a specific keyset. It can be derived by
// Anyone who knows the set of public keys of a mint. The keyset ID **CAN**
// be stored in a Cashu token such that the token can be used to identify
// which mint or keyset it was generated from.
pub const Id = struct {
    version: KeySetVersion,
    id: [BYTELEN]u8,

    pub fn toString(self: Id) [STRLEN + 2]u8 {
        return ("00" ++ std.fmt.bytesToHex(self.id, .lower)).*;
    }

    pub fn toBytes(self: Id) [BYTELEN + 1]u8 {
        return [_]u8{self.version.toByte()} ++ self.id;
    }

    pub fn toU64(self: Id) !u64 {
        const hex_bytes: [8]u8 = self.toBytes();

        const int = std.mem.readInt(u64, &hex_bytes, .big);

        return int % comptime ((std.math.powi(u64, 2, 31) catch unreachable) - 1);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const str = try std.json.innerParse([]const u8, allocator, source, options);

        return Id.fromStr(str) catch return error.UnexpectedToken;
    }

    pub fn jsonStringify(self: *const Id, out: anytype) !void {
        try out.write(std.fmt.bytesToHex(self.toBytes(), .lower));
    }

    pub fn fromStr(s: []const u8) !Id {
        // Check if the string length is valid
        if (s.len != 16) {
            return error.Length;
        }
        var ret = Id{
            .version = .version00,
            .id = undefined,
        };

        // should we check return size of hex to bytes?
        _ = try std.fmt.hexToBytes(&ret.id, s[2..]);

        return ret;
    }

    const st = struct { u64, secp256k1.PublicKey };

    fn compare(_: void, lhs: st, rhs: st) bool {
        return lhs[0] < rhs[0];
    }

    pub fn fromKeys(allocator: std.mem.Allocator, map: std.StringHashMap(secp256k1.PublicKey)) !Id {
        // REVIEW: Is it 16 or 14 bytes
        // NUT-02
        //    1 - sort public keys by their amount in ascending order
        //    2 - concatenate all public keys to one string
        //    3 - HASH_SHA256 the concatenated public keys
        //    4 - take the first 14 characters of the hex-encoded hash
        //    5 - prefix it with a keyset ID version byte
        var it = map.iterator();

        var arr = try std.ArrayList(st).initCapacity(allocator, map.count());
        defer arr.deinit();

        while (it.next()) |v| {
            const num = try std.fmt.parseInt(u64, v.key_ptr.*, 10);
            arr.appendAssumeCapacity(.{ num, v.value_ptr.* });
        }

        std.sort.block(st, arr.items, {}, compare);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (arr.items) |pk| hasher.update(&pk[1].serialize());

        const hash = hasher.finalResult();
        const hex_of_hash = std.fmt.bytesToHex(hash, .lower);

        var buf: [7]u8 = undefined;

        _ = try std.fmt.hexToBytes(&buf, hex_of_hash[0..14]);

        return .{
            .version = .version00,
            .id = buf,
        };
    }

    pub fn fromMintKeys(allocator: std.mem.Allocator, mkeys: MintKeys) !Id {
        var keys = try Keys.fromMintKeys(allocator, mkeys);
        defer keys.deinit(allocator);

        return try fromKeys(allocator, keys.inner);
    }
};

/// Keyset
pub const KeySet = struct {
    /// Keyset [`Id`]
    id: Id,
    /// Keyset [`CurrencyUnit`]
    unit: CurrencyUnit,
    /// Keyset [`Keys`]
    keys: Keys,

    pub fn deinit(self: *KeySet, gpa: std.mem.Allocator) void {
        self.keys.deinit(gpa);
    }
};

/// KeySetInfo
pub const KeySetInfo = struct {
    /// Keyset [`Id`]
    id: Id,
    /// Keyset [`CurrencyUnit`]
    unit: CurrencyUnit,
    /// Keyset state
    /// Mint will only sign from an active keyset
    active: bool,
    /// Input Fee PPK
    input_fee_ppk: u64 = 0,
};

/// MintKeyset
pub const MintKeySet = struct {
    /// Keyset [`Id`]
    id: Id,
    /// Keyset [`CurrencyUnit`]
    unit: CurrencyUnit,
    /// Keyset [`MintKeys`]
    keys: MintKeys,

    pub fn deinit(self: *MintKeySet) void {
        self.keys.deinit();
    }

    pub fn toKeySet(self: MintKeySet, allocator: std.mem.Allocator) !KeySet {
        return .{
            .id = self.id,
            .unit = self.unit,
            .keys = try Keys.fromMintKeys(allocator, self.keys),
        };
    }

    /// Generate new [`MintKeySet`]
    pub fn generate(
        allocator: std.mem.Allocator,
        secp: secp256k1.Secp256k1,
        xpriv: bip32.ExtendedPrivKey,
        unit: CurrencyUnit,
        max_order: u8,
    ) !MintKeySet {
        var map = std.AutoHashMap(u64, MintKeyPair).init(allocator);
        errdefer map.deinit();
        for (0..max_order) |i| {
            const amount = try std.math.powi(u64, 2, i);

            const secret_key = (try xpriv.derivePriv(
                secp,
                &.{try bip32.ChildNumber.fromHardenedIdx(@intCast(i))},
            )).private_key;

            const public_key = secret_key.publicKey(secp);
            try map.put(amount, .{
                .secret_key = secret_key,
                .public_key = public_key,
            });
        }

        const keys = MintKeys{
            .inner = map,
        };

        return .{
            .id = try Id.fromMintKeys(allocator, keys),
            .unit = unit,
            .keys = keys,
        };
    }

    /// Generate new [`MintKeySet`] from seed
    pub fn generateFromSeed(
        allocator: std.mem.Allocator,
        secp: secp256k1.Secp256k1,
        seed: []const u8,
        max_order: u8,
        currency_unit: CurrencyUnit,
        derivation_path: []const bip32.ChildNumber,
    ) !MintKeySet {
        const xpriv =
            bip32.ExtendedPrivKey.initMaster(.MAINNET, seed) catch @panic("RNG busted");

        return try generate(
            allocator,
            secp,
            try xpriv
                .derivePriv(secp, derivation_path),
            currency_unit,
            max_order,
        );
    }

    /// Generate new [`MintKeySet`] from xpriv
    pub fn generateFromXpriv(
        allocator: std.mem.Allocator,
        secp: secp256k1.Secp256k1,
        xpriv: bip32.ExtendedPrivKey,
        max_order: u8,
        currency_unit: CurrencyUnit,
        derivation_path: []const bip32.ChildNumber,
    ) !MintKeySet {
        return try generate(
            allocator,
            secp,
            xpriv
                .derivePriv(secp, derivation_path) catch @panic("RNG busted"),
            currency_unit,
            max_order,
        );
    }
};

/// Mint Keysets [NUT-02]
/// Ids of mints keyset ids
pub const KeysetResponse = struct {
    /// set of public key ids that the mint generates
    keysets: []const KeySetInfo,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !KeysetResponse {
        if (try source.next() != .object_begin) return error.UnexpectedToken;

        const tokenType = switch (try source.next()) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };

        if (!std.mem.eql(u8, tokenType, "keysets")) return error.MissingField;

        if (try source.next() != .array_begin) return error.UnexpectedToken;

        var arraylist = std.ArrayList(KeySetInfo).init(allocator);
        while (true) {
            switch (try source.peekNextTokenType()) {
                .array_end => {
                    _ = try source.next();
                    break;
                },
                else => {},
            }

            try arraylist.ensureUnusedCapacity(1);

            arraylist.appendAssumeCapacity(std.json.innerParse(KeySetInfo, allocator, source, options) catch |e| if (e == std.mem.Allocator.Error.OutOfMemory) return e else {
                continue;
            });
        }

        if (try source.next() != .object_end) return error.UnexpectedToken;

        return .{
            .keysets = try arraylist.toOwnedSlice(),
        };
    }
};

test {
    _ = @import("nut02_test.zig");
}

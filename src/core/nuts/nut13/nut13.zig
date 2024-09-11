//! NUT-13: Deterministic Secrets
//!
//! <https://github.com/cashubtc/nuts/blob/main/13.md>

const nut00 = @import("../nut00/nut00.zig");
const std = @import("std");
const amount_lib = @import("../../amount.zig");
const dhke = @import("../../dhke.zig");
const helper = @import("../../../helper/helper.zig");
const bitcoin_primitives = @import("bitcoin-primitives");
const bip32 = bitcoin_primitives.bips.bip32;
const secp256k1 = bitcoin_primitives.secp256k1;
const bip39 = bitcoin_primitives.bips.bip39;

const SecretKey = secp256k1.SecretKey;
const Secret = @import("../../secret.zig").Secret;
const Id = @import("../nut02/nut02.zig").Id;
const BlindedMessage = nut00.BlindedMessage;
const PreMint = nut00.PreMint;
const PreMintSecrets = nut00.PreMintSecrets;

fn derivePathFromKeysetId(id: Id) ![3]bip32.ChildNumber {
    const index: u32 = @intCast(try id.toU64() % ((std.math.powi(u64, 2, 31) catch unreachable) - 1));

    const keyset_child_number = try bip32.ChildNumber.fromHardenedIdx(index);

    return .{
        try bip32.ChildNumber.fromHardenedIdx(129372),
        try bip32.ChildNumber.fromHardenedIdx(0),
        keyset_child_number,
    };
}

/// Create new [`Secret`] from xpriv
/// allocating result, need to call deinit with this allocator
pub fn secretFromXpriv(allocator: std.mem.Allocator, secp: secp256k1.Secp256k1, xpriv: bip32.ExtendedPrivKey, keyset_id: Id, counter: u32) !Secret {
    const path = (try derivePathFromKeysetId(keyset_id)) ++ [_]bip32.ChildNumber{
        try bip32.ChildNumber.fromHardenedIdx(counter),
        try bip32.ChildNumber.fromNormalIdx(0),
    };

    const derived_xpriv = try xpriv.derivePriv(secp, &path);

    const data = try allocator.alloc(u8, 64);
    errdefer allocator.free(data);

    @memcpy(data, &std.fmt.bytesToHex(derived_xpriv.private_key.secretBytes(), .lower));

    return .{
        .inner = data,
    };
}

/// Create new [`SecretKey`] from xpriv
pub fn secretKeyFromXpriv(secp: secp256k1.Secp256k1, xpriv: bip32.ExtendedPrivKey, keyset_id: Id, counter: u32) !SecretKey {
    const path = (try derivePathFromKeysetId(keyset_id)) ++ [_]bip32.ChildNumber{
        try bip32.ChildNumber.fromHardenedIdx(counter),
        try bip32.ChildNumber.fromNormalIdx(1),
    };
    const derived_xpriv = try xpriv.derivePriv(secp, &path);

    return derived_xpriv.private_key;
}

/// Generate blinded messages from predetermined secrets and blindings
/// factor
pub fn preMintSecretsFromXpriv(
    allocator: std.mem.Allocator,
    secp: secp256k1.Secp256k1,
    keyset_id: Id,
    _counter: u32,
    xpriv: bip32.ExtendedPrivKey,
    amount: amount_lib.Amount,
    amount_split_target: amount_lib.SplitTarget,
) !helper.Parsed(PreMintSecrets) {
    var pre_mint_secrets = try helper.Parsed(PreMintSecrets).init(allocator);
    errdefer pre_mint_secrets.deinit();

    pre_mint_secrets.value.keyset_id = keyset_id;

    var counter = _counter;
    const splitted = try amount_lib.splitTargeted(amount, allocator, amount_split_target);
    defer splitted.deinit();

    var secrets = std.ArrayList(PreMint).init(pre_mint_secrets.arena.allocator());
    defer secrets.deinit();

    for (splitted.items) |amnt| {
        const secret = try secretFromXpriv(pre_mint_secrets.arena.allocator(), secp, xpriv, keyset_id, counter);
        defer secret.deinit(allocator);

        const blinding_factor = try secretKeyFromXpriv(secp, xpriv, keyset_id, counter);

        const blinded, const r = try dhke.blindMessage(secp, secret.toBytes(), blinding_factor);

        const blinded_message = nut00.BlindedMessage{
            .amount = amnt,
            .keyset_id = keyset_id,
            .blinded_secret = blinded,
        };

        try secrets.append(.{
            .blinded_message = blinded_message,
            .secret = secret,
            .r = r,
            .amount = amnt,
        });

        counter += 1;
    }

    pre_mint_secrets.value.secrets = try secrets.toOwnedSlice();

    return pre_mint_secrets;
}

/// New [`PreMintSecrets`] from xpriv with a zero amount used for change
pub fn preMintSecretsFromXprivBlank(
    allocator: std.mem.Allocator,
    secp: secp256k1.Secp256k1,
    keyset_id: Id,
    _counter: u32,
    xpriv: bip32.ExtendedPrivKey,
    amount: amount_lib.Amount,
) !helper.Parsed(PreMintSecrets) {
    var pre_mint_secrets = try helper.Parsed(PreMintSecrets).init(allocator);
    errdefer pre_mint_secrets.deinit();

    pre_mint_secrets.value.keyset_id = keyset_id;

    if (amount <= 0) {
        return pre_mint_secrets;
    }

    const count = @max(@as(u64, 1), @as(u64, @intFromFloat(std.math.ceil(std.math.log2(@as(f64, @floatFromInt(amount)))))));

    var counter = _counter;

    var secrets = std.ArrayList(PreMint).init(pre_mint_secrets.arena.allocator());
    defer secrets.deinit();

    for (0..count) |_| {
        const secret = try secretFromXpriv(pre_mint_secrets.arena.allocator(), secp, xpriv, keyset_id, counter);

        const blinding_factor = try secretKeyFromXpriv(secp, xpriv, keyset_id, counter);

        const blinded, const r = try dhke.blindMessage(secp, secret.toBytes(), blinding_factor);

        const amnt: amount_lib.Amount = 0;

        const blinded_message = BlindedMessage{
            .amount = amnt,
            .keyset_id = keyset_id,
            .blinded_secret = blinded,
        };

        try secrets.append(.{
            .blinded_message = blinded_message,
            .secret = secret,
            .r = r,
            .amount = amnt,
        });

        counter += 1;
    }

    pre_mint_secrets.value.secrets = try secrets.toOwnedSlice();
    return pre_mint_secrets;
}

/// Generate blinded messages from predetermined secrets and blindings factor
pub fn preMintSecretsRestoreBatch(
    allocator: std.mem.Allocator,
    secp: secp256k1.Secp256k1,
    keyset_id: Id,
    xpriv: bip32.ExtendedPrivKey,
    start_count: u32,
    end_count: u32,
) !helper.Parsed(PreMintSecrets) {
    var pre_mint_secrets = try helper.Parsed(PreMintSecrets).init(allocator);
    errdefer pre_mint_secrets.deinit();

    var secrets = std.ArrayList(PreMint).init(pre_mint_secrets.arena.allocator());
    defer secrets.deinit();

    for (start_count..end_count + 1) |i| {
        const secret = try secretFromXpriv(pre_mint_secrets.arena.allocator(), secp, xpriv, keyset_id, @truncate(i));

        const blinding_factor = try secretKeyFromXpriv(secp, xpriv, keyset_id, @truncate(i));

        const blinded, const r = try dhke.blindMessage(secp, secret.toBytes(), blinding_factor);

        const blinded_message = BlindedMessage{
            .amount = 0,
            .keyset_id = keyset_id,
            .blinded_secret = blinded,
        };

        try secrets.append(.{
            .blinded_message = blinded_message,
            .secret = secret,
            .r = r,
            .amount = 0,
        });
    }

    pre_mint_secrets.value.secrets = try secrets.toOwnedSlice();

    return pre_mint_secrets;
}

test "test_secret_from_seed" {
    const seed_words =
        "half depart obvious quality work element tank gorilla view sugar picture humble";

    const mnemonic = try bip39.Mnemonic.parseInNormalized(.english, seed_words);

    const seed = try mnemonic.toSeedNormalized("");

    const xpriv = try bip32.ExtendedPrivKey.initMaster(.MAINNET, &seed);

    const keyset_id = try Id.fromStr("009a1f293253e41e");

    const test_secrets = [_][]const u8{
        "485875df74771877439ac06339e284c3acfcd9be7abf3bc20b516faeadfe77ae",
        "8f2b39e8e594a4056eb1e6dbb4b0c38ef13b1b2c751f64f810ec04ee35b77270",
        "bc628c79accd2364fd31511216a0fab62afd4a18ff77a20deded7b858c9860c8",
        "59284fd1650ea9fa17db2b3acf59ecd0f2d52ec3261dd4152785813ff27a33bf",
        "576c23393a8b31cc8da6688d9c9a96394ec74b40fdaf1f693a6bb84284334ea0",
    };

    var secp = secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    for (0.., test_secrets) |i, test_secret| {
        const secret = try secretFromXpriv(std.testing.allocator, secp, xpriv, keyset_id, @truncate(i));
        defer secret.deinit(std.testing.allocator);

        try std.testing.expectEqualSlices(u8, test_secret, secret.inner);
    }
}

test "test_r_from_seed" {
    const seed_words =
        "half depart obvious quality work element tank gorilla view sugar picture humble";

    const mnemonic = try bip39.Mnemonic.parseInNormalized(.english, seed_words);

    const seed = try mnemonic.toSeedNormalized("");

    const xpriv = try bip32.ExtendedPrivKey.initMaster(.MAINNET, &seed);

    const keyset_id = try Id.fromStr("009a1f293253e41e");

    const test_secrets = [_][]const u8{
        "ad00d431add9c673e843d4c2bf9a778a5f402b985b8da2d5550bf39cda41d679",
        "967d5232515e10b81ff226ecf5a9e2e2aff92d66ebc3edf0987eb56357fd6248",
        "b20f47bb6ae083659f3aa986bfa0435c55c6d93f687d51a01f26862d9b9a4899",
        "fb5fca398eb0b1deb955a2988b5ac77d32956155f1c002a373535211a2dfdc29",
        "5f09bfbfe27c439a597719321e061e2e40aad4a36768bb2bcc3de547c9644bf9",
    };

    var secp = secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    for (0.., test_secrets) |i, test_secret| {
        const sk = try secretKeyFromXpriv(secp, xpriv, keyset_id, @truncate(i));

        const expected_sk = try SecretKey.fromString(test_secret);
        try std.testing.expectEqualDeep(expected_sk, sk);
    }
}

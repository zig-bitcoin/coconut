const std = @import("std");
const nuts = @import("../nuts/lib.zig");
const MintInfo = nuts.MintInfo;
const MintQuote = @import("../mint/types.zig").MintQuote; // TODO import from wallet
const MeltQuote = @import("../mint/types.zig").MeltQuote; // TODO import from wallet
const ProofInfo = @import("../mint/types.zig").ProofInfo;
const secp256k1 = @import("secp256k1");

pub const WalletMemoryDatabase = struct {
    const Self = @This();

    mints: std.AutoHashMap([]const u8, ?MintInfo),
    mint_keysets: std.AutoHashMap([]const u8, nuts.Id),
    keysets: std.AutoHashMap(nuts.Id, nuts.KeySetInfo),
    mint_quotes: std.AutoHashMap([]u8, MintQuote),
    melt_quotes: std.AutoHashMap([]u8, MeltQuote),
    // mint_keys: std.AutoHashMap(nuts.Id, nuts.nut01.Keys),
    // proofs: std.AutoHashMap(secp256k1.PublicKey, ProofInfo),
    keyset_counter: std.AutoHashMap(nuts.Id, u32),
    nostr_last_checked: std.AutoHashMap(secp256k1.PublicKey, u32),

    allocator: std.mem.Allocator,

    pub fn initFrom(
        allocator: std.mem.Allocator,
        mint_quotes: []const MintQuote,
        melt_quotes: []const MeltQuote,
        // mint_keys: []const nuts.nut01.Keys,
        keyset_counter: std.AutoHashMap(nuts.Id, u32),
        nostr_last_checked: std.AutoHashMap(secp256k1.PublicKey, u32),
    ) !WalletMemoryDatabase {
        var _mint_quotes = std.AutoHashMap([16]u8, MintQuote).init(allocator);
        errdefer _mint_quotes.deinit();

        for (mint_quotes) |q| {
            try _mint_quotes.put(q.id, q);
        }
        var _melt_quotes = std.AutoHashMap([16]u8, MeltQuote).init(allocator);
        errdefer _melt_quotes.deinit();

        for (melt_quotes) |q| {
            try _melt_quotes.put(q.id, q);
        }

        var mints = std.AutoHashMap([]const u8, ?MintInfo).init(allocator);
        errdefer mints.deinit();

        var keysets = std.AutoHashMap(nuts.Id, nuts.KeySetInfo).init(allocator);
        errdefer keysets.deinit();

        var mint_keysets = std.AutoHashMap([]const u8, nuts.Id).init(allocator);
        errdefer mint_keysets.deinit();

        // var proofs = std.AutoHashMap(secp256k1.PublicKey, ProofInfo).init(allocator);
        // errdefer proofs.deinit();

        return .{
            .allocator = allocator,
            .mints = mints,
            .mint_keysets = mint_keysets,
            .keysets = keysets,
            .mint_quotes = _mint_quotes,
            .melt_quotes = _melt_quotes,
            // .mint_keys = mint_keys,
            // .proofs = proofs,
            .keyset_counter = keyset_counter,
            .nostr_last_checked = nostr_last_checked,
        };
    }
};

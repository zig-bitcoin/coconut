const std = @import("std");
const nuts = @import("../nuts/lib.zig");
const MintInfo = nuts.MintInfo;
const MintKeySetInfo = @import("../mint/mint.zig").MintKeySetInfo;
const MintQuote = @import("../mint/types.zig").MintQuote; // TODO import from wallet
const MeltQuote = @import("../mint/types.zig").MeltQuote; // TODO import from wallet
const ProofInfo = @import("../mint/types.zig").ProofInfo;
const secp256k1 = @import("secp256k1");

/// TODO rw locks
/// Wallet Memory Database
pub const WalletMemoryDatabase = struct {
    const Self = @This();

    lock: std.Thread.RwLock,

    mints: std.AutoHashMap([]const u8, ?MintInfo),
    mint_keysets: std.AutoHashMap([]const u8, std.AutoHashMap(nuts.Id, void)),
    keysets: std.AutoHashMap(nuts.Id, nuts.KeySetInfo),
    mint_quotes: std.AutoHashMap([16]u8, MintQuote),
    melt_quotes: std.AutoHashMap([16]u8, MeltQuote),
    mint_keys: std.AutoHashMap(nuts.Id, nuts.nut01.Keys),
    proofs: std.AutoHashMap(secp256k1.PublicKey, ProofInfo),
    keyset_counter: std.AutoHashMap(nuts.Id, u32),
    nostr_last_checked: std.AutoHashMap(secp256k1.PublicKey, u32),

    allocator: std.mem.Allocator,

    pub fn initFrom(
        allocator: std.mem.Allocator,
        mint_quotes: []const MintQuote,
        melt_quotes: []const MeltQuote,
        mint_keys: []const nuts.nut01.Keys,
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

        var _mint_keys = std.AutoHashMap(nuts.Id, nuts.nut01.Keys);
        errdefer _mint_keys.deinit();

        for (mint_keys) |k| {
            try _mint_keys.put(nuts.Id.fromKeys(k), k);
        }

        var mints = std.AutoHashMap([]u8, ?MintInfo).init(allocator);
        errdefer mints.deinit();

        var keysets = std.AutoHashMap(nuts.Id, nuts.KeySetInfo).init(allocator);
        errdefer keysets.deinit();

        var mint_keysets = std.AutoHashMap([]const u8, std.AutoHashMap(nuts.Id, void)).init(allocator);
        errdefer mint_keysets.deinit();

        var proofs = std.AutoHashMap(secp256k1.PublicKey, ProofInfo).init(allocator);
        errdefer proofs.deinit();

        return .{
            .allocator = allocator,
            .lock = .{},
            .mints = mints,
            .mint_keysets = mint_keysets,
            .keysets = keysets,
            .mint_quotes = _mint_quotes,
            .melt_quotes = _melt_quotes,
            .mint_keys = mint_keys,
            .proofs = proofs,
            .keyset_counter = keyset_counter,
            .nostr_last_checked = nostr_last_checked,
        };
    }

    pub fn addMint(
        self: *Self,
        mint_url: []u8,
        mint_info: ?MintInfo,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.mints.put(mint_url, mint_info);
    }

    pub fn removeMint(
        self: *Self,
        mint_url: []u8,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.mints.fetchRemove(mint_url) orelse return;
        kv.value.deinit(self.allocator);
    }

    pub fn getMint(self: *Self, mint_url: []u8) !?MintInfo {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return self.mints.get(mint_url);
    }

    pub fn getMints() !void {
        // TODO
    }

    pub fn updateMintUrl(
        self: *Self,
        mint_url: []u8,
        new_mint_url: []u8,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // TODO
        const kv = self.mints.fetchRemove(mint_url) orelse return;
        const new_value = kv.value;
        kv.value.deinit(self.allocator);

        self.mints.put(new_mint_url, new_value);
    }

    pub fn addMintKeysets(
        self: *Self,
        mint_url: []u8,
        keysets: std.ArrayList(MintKeySetInfo),
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        var keyset_map = self.mint_keysets.get(mint_url);
        if (keyset_map == null) {
            keyset_map = try std.AutoHashMap(u64, void).init(self.allocator);
            try self.mint_keysets.put(mint_url, keyset_map);
        }

        for (keysets) |keyset_info| {
            try keyset_map.put(keyset_info.id, {});
        }
    }

    pub fn getMintKeysets(self: *Self) !void {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        // TODO
    }
    pub fn getKeysetById(self: *Self) !void {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        // TODO
    }

    pub fn addMintQuote(self: *Self, quote: MintQuote) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // TODO clone quote

        try self.mint_quotes.put(quote.id, quote);
    }

    // caller must free MintQuote
    pub fn getMintQuote(self: *Self, allocator: std.mem.Allocator, quote_id: [16]u8) !?MintQuote {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const quote = self.mint_quotes.get(quote_id) orelse return null;

        return try quote.clone(allocator);
    }

    /// caller must free array list and every elements
    pub fn getMintQuotes(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(MintQuote) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var it = self.mint_quotes.valueIterator();

        var result = try std.ArrayList(MintQuote).initCapacity(allocator, it.len);
        errdefer {
            for (result.items) |res| res.deinit(allocator);
            result.deinit();
        }

        while (it.next()) |el| {
            result.appendAssumeCapacity(try el.clone(allocator));
        }

        return result;
    }

    pub fn removeMintQuote(self: *Self, quote: MintQuote) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.mint_quotes.fetchRemove(quote) orelse return;
        kv.value.deinit(self.allocator);
    }

    pub fn addMeltQuote(self: *Self, quote: MeltQuote) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.melt_quotes.put(quote.id, quote);
    }

    pub fn getMeltQuote(self: *Self, allocator: std.mem.Allocator, quote_id: [16]u8) !?MeltQuote {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const quote = self.melt_quotes.get(quote_id) orelse return null;

        return try quote.clone(allocator);
    }

    pub fn removeMeltQuote(self: *Self, quote: MeltQuote) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.melt_quotes.fetchRemove(quote) orelse return;
        kv.value.deinit(self.allocator);
    }

    pub fn addKeys(self: *Self, id: nuts.Id, keys: nuts.nut01.Keys) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.mint_keys.put(id, keys);
    }

    pub fn getKeys(self: *Self, id: nuts.Id) !?nuts.Keys {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return self.mint_keys.get(id);
    }

    pub fn removeKeys(self: *Self, id: nuts.Id) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.mint_keys.fetchRemove(id) orelse return;
        kv.value.deinit(self.allocator);
    }

    pub fn updateProofs() !void {
        // TODO
    }

    pub fn setPendingProofs() !void {
        // TODO
    }

    pub fn reserveProofs() !void {
        // TODO
    }

    pub fn setUnspentProofs() !void {
        // TODO
    }

    pub fn getProofs() !void {
        // TODO
    }

    pub fn incrementKeysetCounter() !void {
        // TODO
    }

    pub fn getKeysetCounter(self: *Self, id: nuts.Id) !?u32 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return self.keyset_counter.get(id);
    }

    pub fn getNostrLastChecked() !void {
        // TODO
    }

    pub fn addNostrLastChecked() !void {
        // TODO
    }
};

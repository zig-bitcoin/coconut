const std = @import("std");
const nuts = @import("../nuts/lib.zig");
const MintInfo = nuts.MintInfo;
const MintKeySetInfo = @import("../mint/mint.zig").MintKeySetInfo;
const MintQuote = @import("../mint/types.zig").MintQuote; // TODO import from wallet
const MeltQuote = @import("../mint/types.zig").MeltQuote; // TODO import from wallet
const ProofInfo = @import("../mint/types.zig").ProofInfo;
const bitcoin_primitives = @import("bitcoin-primitives");
const secp256k1 = bitcoin_primitives.secp256k1;
const zul = @import("zul");

/// TODO rw locks
/// Wallet Memory Database
pub const WalletMemoryDatabase = struct {
    const Self = @This();

    lock: std.Thread.RwLock,

    mints: std.StringHashMap(?MintInfo),
    mint_keysets: std.StringHashMap(std.AutoHashMap(nuts.Id, void)),
    keysets: std.AutoHashMap(nuts.Id, nuts.KeySetInfo),
    mint_quotes: std.AutoHashMap(zul.UUID, MintQuote),
    melt_quotes: std.AutoHashMap(zul.UUID, MeltQuote),
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
        var _mint_quotes = std.AutoHashMap(zul.UUID, MintQuote).init(allocator);
        errdefer _mint_quotes.deinit();

        for (mint_quotes) |q| {
            try _mint_quotes.put(q.id, q);
        }

        var _melt_quotes = std.AutoHashMap(zul.UUID, MeltQuote).init(allocator);
        errdefer _melt_quotes.deinit();

        for (melt_quotes) |q| {
            try _melt_quotes.put(q.id, q);
        }

        var _mint_keys = std.AutoHashMap(nuts.Id, nuts.nut01.Keys).init(allocator);
        errdefer _mint_keys.deinit();

        for (mint_keys) |k| {
            try _mint_keys.put(try nuts.Id.fromKeys(allocator, k.inner), k);
        }

        var mints = std.StringHashMap(?MintInfo).init(allocator);
        errdefer mints.deinit();

        var keysets = std.AutoHashMap(nuts.Id, nuts.KeySetInfo).init(allocator);
        errdefer keysets.deinit();

        var mint_keysets = std.StringHashMap(std.AutoHashMap(nuts.Id, void)).init(allocator);
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
            .mint_keys = _mint_keys,
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

        _ = self.mints.fetchRemove(mint_url) orelse return;
    }

    pub fn getMint(self: *Self, mint_url: []u8) !?MintInfo {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const mint_info = self.mints.get(mint_url);

        if (mint_info == null) {
            return null;
        }
        return mint_info.?;
    }

    pub fn getMints(self: *Self, allocator: std.mem.Allocator) !std.StringHashMap(?MintInfo) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var mints_copy = std.StringHashMap(?MintInfo).init(allocator);

        var it = self.mints.iterator();
        while (it.next()) |entry| {
            try mints_copy.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return mints_copy;
    }

    pub fn updateMintUrl(
        self: *Self,
        old_mint_url: []u8,
        new_mint_url: []u8,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const proofs = self.getProofs(
            old_mint_url,
            null,
            null,
            null,
            self.allocator,
        ) catch return error.CouldNotGetProofs;

        // Update proofs
        var updated_proofs = std.ArrayList(ProofInfo).init(self.allocator);
        defer updated_proofs.deinit();

        var removed_ys = std.ArrayList(secp256k1.PublicKey).init(self.allocator);
        defer removed_ys.deinit();

        for (proofs.items) |proof| {
            const new_proof = ProofInfo.init(
                proof.proof,
                new_mint_url,
                proof.state,
                proof.unit,
            );
            try updated_proofs.append(new_proof);
        }

        try self.updateProofs(updated_proofs.items, removed_ys.items);

        // Update mint quotes
        const current_quotes = self.getMintQuotes(self.allocator) catch return error.CouldNotGetMintQuotes;
        const quotes = current_quotes.items;
        const time = unix_time();

        for (quotes) |*quote| {
            if (quote.expiry < time) {
                quote.mint_url = new_mint_url;
            }
            try self.addMintQuote(quote.*);
        }
    }

    pub fn addMintKeysets(
        self: *Self,
        mint_url: []u8,
        keysets: std.ArrayList(nuts.KeySetInfo),
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        var keyset_ids = self.mint_keysets.get(mint_url);

        if (keyset_ids == null) {
            const new_keyset_ids = std.AutoHashMap(nuts.Id, void).init(self.allocator);
            keyset_ids = new_keyset_ids;
        }

        var unwrapped_keyset_ids = keyset_ids.?;

        for (keysets.items) |keyset_info| {
            try unwrapped_keyset_ids.put(keyset_info.id, {});
        }

        try self.mint_keysets.put(mint_url, unwrapped_keyset_ids);

        for (keysets.items) |keyset_info| {
            try self.keysets.put(keyset_info.id, keyset_info);
        }
    }

    pub fn getMintKeysets(self: *Self, allocator: std.mem.Allocator, mint_url: []u8) !?std.ArrayList(nuts.KeySetInfo) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var keysets = std.ArrayList(nuts.KeySetInfo).init(allocator);
        defer keysets.deinit();

        const keyset_ids = self.mint_keysets.get(mint_url);

        var it = keyset_ids.?.iterator();
        while (it.next()) |kv| {
            const id = kv.key_ptr.*;
            if (self.keysets.get(id)) |keyset| {
                try keysets.append(keyset);
            }
        }

        return keysets;
    }

    pub fn getKeysetById(self: *Self, id: nuts.Id) !?nuts.KeySetInfo {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const keysets_id = self.keysets.get(id);

        if (keysets_id == null) {
            return null;
        }
        return keysets_id.?;
    }

    pub fn addMintQuote(self: *Self, quote: MintQuote) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.mint_quotes.put(quote.id, quote);
    }

    // caller must free MintQuote
    pub fn getMintQuote(self: *Self, allocator: std.mem.Allocator, quote_id: zul.UUID) !?MintQuote {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const quote = self.mint_quotes.get(quote_id) orelse return null;

        return try quote.clone(allocator);
    }

    // caller must free array list and every elements
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

    pub fn removeMintQuote(self: *Self, quote_id: zul.UUID) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.mint_quotes.fetchRemove(quote_id) orelse return;
        kv.value.deinit(self.allocator);
    }

    pub fn addMeltQuote(self: *Self, quote: MeltQuote) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.melt_quotes.put(quote.id, quote);
    }

    pub fn getMeltQuote(
        self: *Self,
        allocator: std.mem.Allocator,
        quote_id: zul.UUID,
    ) !?MeltQuote {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const quote = self.melt_quotes.get(quote_id) orelse return null;

        return try quote.clone(allocator);
    }

    pub fn removeMeltQuote(self: *Self, quote_id: zul.UUID) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.melt_quotes.fetchRemove(quote_id) orelse return;
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

        var kv = self.mint_keys.fetchRemove(id) orelse return;
        kv.value.deinit(self.allocator);
    }

    pub fn updateProofs(
        self: *Self,
        added: []ProofInfo,
        removed_ys: []secp256k1.PublicKey,
    ) !void {
        for (added) |proof_info| {
            try self.proofs.put(proof_info.y, proof_info);
        }

        for (removed_ys) |y| {
            _ = self.proofs.remove(y);
        }
    }

    pub fn setPendingProofs(self: *Self, proofs: []const secp256k1.PublicKey) !void {
        for (proofs) |proof| {
            if (self.proofs.get(proof)) |proof_info| {
                var updated_proof_info = proof_info;
                updated_proof_info.state = nuts.nut07.State.pending;

                try self.proofs.put(proof, updated_proof_info);
            }
        }
    }

    pub fn reserveProofs(self: *Self, proofs: []const secp256k1.PublicKey) !void {
        for (proofs) |proof| {
            if (self.proofs.get(proof)) |proof_info| {
                var updated_proof_info = proof_info;
                updated_proof_info.state = nuts.nut07.State.reserved;

                try self.proofs.put(proof, updated_proof_info);
            }
        }
    }

    pub fn setUnspentProofs(self: *Self, proofs: []const secp256k1.PublicKey) !void {
        for (proofs) |proof| {
            if (self.proofs.get(proof)) |proof_info| {
                var updated_proof_info = proof_info;
                updated_proof_info.state = nuts.nut07.State.unspent;

                try self.proofs.put(proof, updated_proof_info);
            }
        }
    }

    pub fn getProofs(
        self: *Self,
        mint_url: ?[]u8,
        unit: ?nuts.CurrencyUnit,
        state: ?[]const nuts.nut07.State,
        spending_conditions: ?[]const nuts.nut11.SpendingConditions,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(ProofInfo) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var result_list = std.ArrayList(ProofInfo).init(allocator);

        var it = self.proofs.iterator();

        while (it.next()) |entry| {
            var proof_info = entry.value_ptr.*;
            if (proof_info.matchesConditions(mint_url.?, unit.?, state.?, spending_conditions.?)) {
                try result_list.append(proof_info);
            }
        }

        return result_list;
    }

    pub fn incrementKeysetCounter(
        self: *Self,
        id: nuts.Id,
        count: u32,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const current_counter = self.keyset_counter.get(id) orelse 0;
        return try self.keyset_counter.put(id, current_counter + count);
    }

    pub fn getKeysetCounter(self: *Self, id: nuts.Id) !?u32 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return self.keyset_counter.get(id);
    }

    pub fn getNostrLastChecked(
        self: *Self,
        verifying_key: secp256k1.PublicKey,
    ) !?u32 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return self.nostr_last_checked.get(verifying_key);
    }

    pub fn addNostrLastChecked(
        self: *Self,
        verifying_key: secp256k1.PublicKey,
        last_checked: u32,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.nostr_last_checked.put(verifying_key, last_checked);
    }
};

pub fn unix_time() u64 {
    const timestamp = std.time.timestamp();
    const time: u64 = @intCast(@divFloor(timestamp, std.time.ns_per_s));
    return time;
}

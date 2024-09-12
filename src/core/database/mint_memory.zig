const std = @import("std");
const nuts = @import("../nuts/lib.zig");
const dhke = @import("../dhke.zig");
const zul = @import("zul");
const bitcoin_primitives = @import("bitcoin-primitives");
const secp256k1 = bitcoin_primitives.secp256k1;

const Arened = @import("../../helper/helper.zig").Parsed;
const MintKeySetInfo = @import("../mint/mint.zig").MintKeySetInfo;
const MintQuote = @import("../mint/mint.zig").MintQuote;
const MeltQuote = @import("../mint/mint.zig").MeltQuote;

/// TODO simple solution for rw locks, use on all structure, as temp solution
/// Mint Memory Database
pub const MintMemoryDatabase = struct {
    const Self = @This();

    lock: std.Thread.RwLock,

    active_keysets: std.AutoHashMap(nuts.CurrencyUnit, nuts.Id),
    keysets: std.AutoHashMap(nuts.Id, MintKeySetInfo),
    mint_quotes: std.AutoHashMap([16]u8, MintQuote),
    melt_quotes: std.AutoHashMap([16]u8, MeltQuote),
    proofs: std.AutoHashMap([33]u8, nuts.Proof),
    proof_states: std.AutoHashMap([33]u8, nuts.nut07.State),
    blinded_signatures: std.AutoHashMap([33]u8, nuts.BlindSignature),

    allocator: std.mem.Allocator,

    pub fn deinit(self: *MintMemoryDatabase) void {
        self.active_keysets.deinit();

        {
            var it = self.keysets.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }

            self.keysets.deinit();
        }

        {
            var it = self.mint_quotes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }

            self.mint_quotes.deinit();
        }

        {
            var it = self.melt_quotes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }

            self.melt_quotes.deinit();
        }

        {
            var it = self.proofs.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }

            self.proofs.deinit();
        }

        self.proof_states.deinit();

        self.blinded_signatures.deinit();
    }

    /// initFrom - take own on all data there, except slices (only own data in slices)
    pub fn initFrom(
        allocator: std.mem.Allocator,
        active_keysets: std.AutoHashMap(nuts.CurrencyUnit, nuts.Id),
        keysets: []const MintKeySetInfo,
        mint_quotes: []const MintQuote,
        melt_quotes: []const MeltQuote,
        pending_proofs: []const nuts.Proof,
        spent_proofs: []const nuts.Proof,
        blinded_signatures: std.AutoHashMap([33]u8, nuts.BlindSignature),
    ) !MintMemoryDatabase {
        var proofs = std.AutoHashMap([33]u8, nuts.Proof).init(allocator);
        errdefer proofs.deinit();

        var proof_states = std.AutoHashMap([33]u8, nuts.nut07.State).init(allocator);
        errdefer proof_states.deinit();

        for (pending_proofs) |proof| {
            const y = (try dhke.hashToCurve(proof.secret.toBytes())).serialize();
            try proofs.put(y, proof);
            try proof_states.put(y, .pending);
        }

        for (spent_proofs) |proof| {
            const y = (try dhke.hashToCurve(proof.secret.toBytes())).serialize();
            try proofs.put(y, proof);
            try proof_states.put(y, .pending);
        }

        var _keysets = std.AutoHashMap(nuts.Id, MintKeySetInfo).init(allocator);
        errdefer _keysets.deinit();

        for (keysets) |ks| {
            try _keysets.put(ks.id, ks);
        }

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

        return .{
            .allocator = allocator,
            .lock = .{},
            .active_keysets = active_keysets,
            .keysets = _keysets,
            .mint_quotes = _mint_quotes,
            .melt_quotes = _melt_quotes,
            .proofs = proofs,
            .proof_states = proof_states,
            .blinded_signatures = blinded_signatures,
        };
    }

    pub fn initManaged(
        allocator: std.mem.Allocator,
    ) !zul.Managed(Self) {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const active_keysets = std.AutoHashMap(nuts.CurrencyUnit, nuts.Id).init(arena.allocator());

        const keysets = std.AutoHashMap(nuts.Id, MintKeySetInfo).init(arena.allocator());

        const mint_quotes = std.AutoHashMap([16]u8, MintQuote).init(arena.allocator());

        const melt_quotes = std.AutoHashMap([16]u8, MeltQuote).init(arena.allocator());

        const proofs = std.AutoHashMap([33]u8, nuts.Proof).init(arena.allocator());

        const proof_state = std.AutoHashMap([33]u8, nuts.nut07.State).init(arena.allocator());

        const blinded_signatures = std.AutoHashMap([33]u8, nuts.BlindSignature).init(arena.allocator());

        return .{
            .value = .{
                .lock = .{},
                .active_keysets = active_keysets,
                .keysets = keysets,
                .mint_quotes = mint_quotes,
                .melt_quotes = melt_quotes,
                .proofs = proofs,
                .proof_states = proof_state,
                .blinded_signatures = blinded_signatures,
                .allocator = arena.allocator(),
            },
            .arena = arena,
        };
    }

    pub fn setActiveKeyset(self: *Self, unit: nuts.CurrencyUnit, id: nuts.Id) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.active_keysets.put(unit, id);
    }

    pub fn getActiveKeysetId(self: *Self, unit: nuts.CurrencyUnit) ?nuts.Id {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return self.active_keysets.get(unit);
    }

    /// caller own result data, so responsible to deallocate
    pub fn getActiveKeysets(self: *Self, allocator: std.mem.Allocator) !std.AutoHashMap(nuts.CurrencyUnit, nuts.Id) {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        // key and value doesnt have heap data, so we can clone all map
        return try self.active_keysets.cloneWithAllocator(allocator);
    }

    /// keyset inside is cloned, so caller own keyset
    pub fn addKeysetInfo(self: *Self, keyset: MintKeySetInfo) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.keysets.put(keyset.id, try keyset.clone(self.allocator));
    }

    /// caller own result, so responsible to free
    pub fn getKeysetInfo(self: *Self, allocator: std.mem.Allocator, keyset_id: nuts.Id) !?MintKeySetInfo {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return if (self.keysets.get(keyset_id)) |ks| try ks.clone(allocator) else null;
    }

    pub fn getKeysetInfos(self: *Self, allocator: std.mem.Allocator) !Arened(std.ArrayList(MintKeySetInfo)) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var res = try Arened(std.ArrayList(MintKeySetInfo)).init(allocator);
        errdefer res.deinit();

        res.value = try std.ArrayList(MintKeySetInfo).initCapacity(res.arena.allocator(), self.keysets.count());

        var it = self.keysets.valueIterator();

        while (it.next()) |v| {
            res.value.appendAssumeCapacity(try v.clone(res.arena.allocator()));
        }

        return res;
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

    pub fn updateMintQuoteState(
        self: *Self,
        quote_id: [16]u8,
        state: nuts.nut04.QuoteState,
    ) !nuts.nut04.QuoteState {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var mint_quote = self.mint_quotes.getPtr(quote_id) orelse return error.UnknownQuote;

        const current_state = mint_quote.state;
        mint_quote.state = state;

        return current_state;
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

    /// caller responsible to free resources
    pub fn getMintQuoteByRequestLookupId(
        self: *Self,
        allocator: std.mem.Allocator,
        request: []const u8,
    ) !?MintQuote {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // no need in free resources due arena
        const quotes = try self.getMintQuotes(arena.allocator());
        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (std.mem.eql(u8, q.request_lookup_id, request)) return try q.clone(allocator);
        }

        return null;
    }
    /// caller responsible to free resources
    pub fn getMintQuoteByRequest(
        self: *Self,
        allocator: std.mem.Allocator,
        request: []const u8,
    ) !?MintQuote {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // no need in free resources due arena
        const quotes = try self.getMintQuotes(arena.allocator());
        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (std.mem.eql(u8, q.request, request)) return try q.clone(allocator);
        }

        return null;
    }

    pub fn removeMintQuoteState(
        self: *Self,
        quote_id: [16]u8,
    ) !void {
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

    // caller must free MeltQuote
    pub fn getMeltQuote(self: *Self, allocator: std.mem.Allocator, quote_id: [16]u8) !?MeltQuote {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const quote = self.melt_quotes.get(quote_id) orelse return null;

        return try quote.clone(allocator);
    }

    pub fn updateMeltQuoteState(
        self: *Self,
        quote_id: [16]u8,
        state: nuts.nut05.QuoteState,
    ) !nuts.nut05.QuoteState {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var melt_quote = self.melt_quotes.getPtr(quote_id) orelse return error.UnknownQuote;

        const current_state = melt_quote.state;
        melt_quote.state = state;

        return current_state;
    }

    /// caller must free array list and every elements
    pub fn getMeltQuotes(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(MeltQuote) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var it = self.melt_quotes.valueIterator();

        var result = try std.ArrayList(MeltQuote).initCapacity(allocator, it.len);
        errdefer {
            for (result.items) |res| res.deinit(allocator);
            result.deinit();
        }

        while (it.next()) |el| {
            result.appendAssumeCapacity(try el.clone(allocator));
        }

        return result;
    }

    /// caller responsible to free resources
    pub fn getMeltQuoteByRequestLookupId(
        self: *Self,
        allocator: std.mem.Allocator,
        request: []const u8,
    ) !?MeltQuote {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // no need in free resources due arena
        const quotes = try self.getMeltQuotes(arena.allocator());
        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (std.mem.eql(u8, q.request_lookup_id, request)) return try q.clone(allocator);
        }

        return null;
    }
    /// caller responsible to free resources
    pub fn getMeltQuoteByRequest(
        self: *Self,
        allocator: std.mem.Allocator,
        request: []const u8,
    ) !?MeltQuote {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // no need in free resources due arena
        const quotes = try self.getMeltQuotes(arena.allocator());
        for (quotes.items) |q| {
            // if we found, cloning with allocator, so caller responsible on free resources
            if (std.mem.eql(u8, q.request, request)) return try q.clone(allocator);
        }

        return null;
    }

    pub fn removeMeltQuoteState(
        self: *Self,
        quote_id: [16]u8,
    ) void {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.melt_quotes.fetchRemove(quote_id) orelse return;
        kv.value.deinit(self.allocator);
    }

    pub fn addProofs(self: *Self, proofs: []const nuts.Proof) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // ensuring that capacity of proofs enough for array
        try self.proofs.ensureTotalCapacity(@intCast(proofs.len));

        // we need full copy
        for (proofs) |proof| {
            const secret_point = try dhke.hashToCurve(proof.secret.toBytes());
            self.proofs.putAssumeCapacity(secret_point.serialize(), try proof.clone(self.allocator));
        }
    }

    // caller must free resources
    pub fn getProofsByYs(self: *Self, allocator: std.mem.Allocator, ys: []const secp256k1.PublicKey) !std.ArrayList(?nuts.Proof) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var proofs = try std.ArrayList(?nuts.Proof).initCapacity(allocator, ys.len);
        errdefer proofs.deinit();

        for (ys) |y| {
            proofs.appendAssumeCapacity(self.proofs.get(y.serialize()));
        }

        return proofs;
    }

    // caller must deinit result std.ArrayList
    pub fn updateProofsStates(
        self: *Self,
        allocator: std.mem.Allocator,
        ys: []const secp256k1.PublicKey,
        proof_state: nuts.nut07.State,
    ) !std.ArrayList(?nuts.nut07.State) {
        self.lock.lock();
        defer self.lock.unlock();

        var states = try std.ArrayList(?nuts.nut07.State).initCapacity(allocator, ys.len);
        errdefer states.deinit();

        for (ys) |y| {
            const kv = try self.proof_states.fetchPut(y.serialize(), proof_state);
            states.appendAssumeCapacity(if (kv) |_kv| _kv.value else null);
        }

        return states;
    }

    // caller must free result
    pub fn getProofsStates(self: *Self, allocator: std.mem.Allocator, ys: []const secp256k1.PublicKey) !std.ArrayList(?nuts.nut07.State) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var states = try std.ArrayList(?nuts.nut07.State).initCapacity(allocator, ys.len);
        errdefer states.deinit();

        for (ys) |y| {
            states.appendAssumeCapacity(self.proof_states.get(y.serialize()));
        }

        return states;
    }

    // result through Arena, for more easy deallocation
    pub fn getProofsByKeysetId(
        self: *Self,
        allocator: std.mem.Allocator,
        id: nuts.Id,
    ) !Arened(std.meta.Tuple(&.{
        std.ArrayList(nuts.Proof),
        std.ArrayList(?nuts.nut07.State),
    })) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var result = try Arened(std.meta.Tuple(&.{
            std.ArrayList(nuts.Proof),
            std.ArrayList(?nuts.nut07.State),
        })).init(allocator);
        errdefer result.deinit();

        result.value[0] = std.ArrayList(nuts.Proof).init(result.arena.allocator());

        var proof_ys = std.ArrayList(secp256k1.PublicKey).init(result.arena.allocator());
        defer proof_ys.deinit();

        var proofs_it = self.proofs.valueIterator();
        while (proofs_it.next()) |proof| {
            if (std.meta.eql(id.id, proof.keyset_id.id)) {
                const c_proof = try proof.clone(result.arena.allocator());
                try result.value[0].append(c_proof);
                try proof_ys.append(try c_proof.y());
            }
        }

        const states = try self.getProofsStates(result.arena.allocator(), proof_ys.items);

        std.debug.assert(states.items.len == result.value[0].items.len);

        result.value[1] = states;

        return result;
    }

    pub fn addBlindSignatures(
        self: *Self,
        blinded_messages: []const secp256k1.PublicKey,
        blind_signatures: []const nuts.BlindSignature,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        for (blinded_messages, blind_signatures) |blinded_message, blind_signature| {
            try self.blinded_signatures.put(blinded_message.serialize(), blind_signature);
        }
    }

    pub fn getBlindSignatures(
        self: *Self,
        allocator: std.mem.Allocator,
        blinded_messages: []const secp256k1.PublicKey,
    ) !std.ArrayList(?nuts.BlindSignature) {
        var signatures = try std.ArrayList(?nuts.BlindSignature).initCapacity(allocator, blinded_messages.len);

        self.lock.lockShared();
        defer self.lock.unlockShared();

        for (blinded_messages) |blinded_message| {
            signatures.appendAssumeCapacity(self.blinded_signatures.get(blinded_message.serialize()));
        }

        return signatures;
    }

    /// caller response to free resources
    pub fn getBlindSignaturesForKeyset(
        self: *Self,
        allocator: std.mem.Allocator,
        keyset_id: nuts.Id,
    ) !std.ArrayList(nuts.BlindSignature) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var result = std.ArrayList(nuts.BlindSignature).init(allocator);
        errdefer result.deinit();

        var it = self.blinded_signatures.valueIterator();
        while (it.next()) |b| {
            if (std.meta.eql(b.keyset_id, keyset_id)) {
                try result.append(b.*);
            }
        }

        return result;
    }
};

pub fn worker(m: *MintMemoryDatabase, unit: nuts.CurrencyUnit) !void {
    const id = try nuts.Id.fromStr("FFFFFFFFFFFFFFFF");

    try m.setActiveKeyset(unit, id);

    const id1 = try nuts.Id.fromStr("FFFFFFFFFFFFFFFC");

    try m.addKeysetInfo(.{
        .id = id1,
        .unit = .sat,
        .active = true,
        .valid_from = 11,
        .valid_to = null,
        .derivation_path = &.{},
        .derivation_path_index = null,
        .max_order = 5,
        .input_fee_ppk = 0,
    });

    try m.addKeysetInfo(.{
        .id = id1,
        .unit = .sat,
        .active = true,
        .valid_from = 11,
        .valid_to = null,
        .derivation_path = &.{},
        .derivation_path_index = null,
        .max_order = 5,
        .input_fee_ppk = 0,
    });
}

test MintMemoryDatabase {
    var db_arened = try MintMemoryDatabase.initManaged(std.testing.allocator);
    defer db_arened.deinit();
    var db = &db_arened.value;
    var rnd = std.Random.DefaultPrng.init(std.testing.random_seed);
    var rand = rnd.random();

    // active keyset
    {
        var id = nuts.Id{
            .version = .version00,
            .id = undefined,
        };
        rand.bytes(&id.id);

        try db.setActiveKeyset(.sat, id);
        try std.testing.expectEqualDeep(db.getActiveKeysetId(.sat).?, id);
    }

    {
        var id = nuts.Id{
            .version = .version00,
            .id = undefined,
        };
        rand.bytes(&id.id);

        const info: MintKeySetInfo = .{
            .id = id,
            .unit = .sat,
            .active = true,
            .input_fee_ppk = 10,
            .valid_from = 0,
            .valid_to = 10,
            .derivation_path = &.{},
            .derivation_path_index = 45,
            .max_order = 14,
        };

        try db.addKeysetInfo(info);
        const info_got = (try db.getKeysetInfo(std.testing.allocator, id)).?;
        defer info_got.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(
            info,
            info_got,
        );

        const infos = try db.getKeysetInfos(std.testing.allocator);
        defer infos.deinit();

        try std.testing.expectEqual(1, infos.value.items.len);
        try std.testing.expectEqualDeep(info, infos.value.items[0]);
    }
    // TODO finish other tests
}

test "multithread" {
    var shared_data = try MintMemoryDatabase.initManaged(std.testing.allocator);
    defer shared_data.deinit();

    const thread1 = try std.Thread.spawn(.{
        .allocator = std.testing.allocator,
    }, worker, .{
        &shared_data.value,
        .sat,
    });

    const thread2 = try std.Thread.spawn(.{
        .allocator = std.testing.allocator,
    }, worker, .{
        &shared_data.value,
        .msat,
    });

    // std.log.warn("waiting threads", .{});
    thread1.join();
    thread2.join();

    std.time.sleep(2e9);
    const keyset_id = shared_data.value.getActiveKeysetId(.sat);
    _ = keyset_id; // autofix

    // std.log.warn("keysets, count = {any}", .{keyset_id});
}

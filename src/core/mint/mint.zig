const std = @import("std");
const core = @import("../lib.zig");
const bitcoin_primitives = @import("bitcoin-primitives");

const secp256k1 = bitcoin_primitives.secp256k1;
const bip32 = bitcoin_primitives.bips.bip32;
const helper = @import("../../helper/helper.zig");
const nuts = core.nuts;

const RWMutex = helper.RWMutex;
const MintInfo = core.nuts.MintInfo;
const MintQuoteBolt11Response = core.nuts.nut04.MintQuoteBolt11Response;
const MintQuoteState = core.nuts.nut04.QuoteState;
const MintKeySet = core.nuts.MintKeySet;
const CurrencyUnit = core.nuts.CurrencyUnit;

pub const MintQuote = @import("types.zig").MintQuote;
pub const MeltQuote = @import("types.zig").MeltQuote;
pub const MintMemoryDatabase = core.mint_memory.MintMemoryDatabase;

// TODO implement tests

/// Mint Fee Reserve
pub const FeeReserve = struct {
    /// Absolute expected min fee
    min_fee_reserve: core.amount.Amount = 0,
    /// Percentage expected fee
    percent_fee_reserve: f32 = 0,
};

/// Mint Keyset Info
pub const MintKeySetInfo = struct {
    /// Keyset [`Id`]
    id: core.nuts.Id,
    /// Keyset [`CurrencyUnit`]
    unit: core.nuts.CurrencyUnit,
    /// Keyset active or inactive
    /// Mint will only issue new [`BlindSignature`] on active keysets
    active: bool,
    /// Starting unix time Keyset is valid from
    valid_from: u64,
    /// When the Keyset is valid to
    /// This is not shown to the wallet and can only be used internally
    valid_to: ?u64,
    /// [`DerivationPath`] keyset
    derivation_path: []const bip32.ChildNumber,
    /// DerivationPath index of Keyset
    derivation_path_index: ?u32,
    /// Max order of keyset
    max_order: u8,
    /// Input Fee ppk
    input_fee_ppk: u64 = 0,

    pub fn deinit(self: *const MintKeySetInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.derivation_path);
    }

    pub fn clone(self: MintKeySetInfo, allocator: std.mem.Allocator) !MintKeySetInfo {
        var cloned = self;

        const derivation_path = try allocator.alloc(bip32.ChildNumber, self.derivation_path.len);
        errdefer allocator.free(derivation_path);

        @memcpy(derivation_path, self.derivation_path);
        cloned.derivation_path = derivation_path;

        return cloned;
    }
};

/// Cashu Mint
pub const Mint = struct {
    /// Mint Url
    mint_url: []const u8,
    /// Mint Info
    mint_info: MintInfo,
    /// Mint Storage backend
    localstore: helper.RWMutex(*MintMemoryDatabase),
    /// Active Mint Keysets
    keysets: RWMutex(std.AutoHashMap(nuts.Id, nuts.MintKeySet)),
    secp_ctx: secp256k1.Secp256k1,
    xpriv: bip32.ExtendedPrivKey,

    // using for allocating data belongs to mint
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Mint) void {
        var it = self.keysets.value.iterator();

        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }

        self.keysets.value.deinit();
    }

    /// Create new [`Mint`]
    pub fn init(
        allocator: std.mem.Allocator,
        mint_url: []const u8,
        seed: []const u8,
        mint_info: MintInfo,
        localstore: *MintMemoryDatabase,
        // Hashmap where the key is the unit and value is (input fee ppk, max_order)
        supported_units: std.AutoHashMap(core.nuts.CurrencyUnit, std.meta.Tuple(&.{ u64, u8 })),
    ) !Mint {
        const secp_ctx = secp256k1.Secp256k1.genNew();
        errdefer secp_ctx.deinit();

        const xpriv = try bip32.ExtendedPrivKey.initMaster(.MAINNET, seed);

        var active_keysets = std.AutoHashMap(core.nuts.Id, MintKeySet).init(allocator);
        errdefer {
            var it = active_keysets.valueIterator();
            while (it.next()) |v| v.deinit();
            active_keysets.deinit();
        }

        const keyset_infos = try localstore.getKeysetInfos(allocator);
        defer keyset_infos.deinit();

        var active_keyset_units = std.ArrayList(core.nuts.CurrencyUnit).init(allocator);
        errdefer active_keyset_units.deinit();

        if (keyset_infos.value.items.len > 0) {
            std.log.debug("setting all keysets to inactive, size = {d}", .{keyset_infos.value.items.len});
            // TODO this part of code

            for (keyset_infos.value.items) |keyset| {
                // Set all to in active
                var ks = keyset;
                ks.active = false;

                try localstore.addKeysetInfo(ks);
            }

            const keysets_by_unit = v: {
                // allocating through arena for easy deallocation
                var result = std.AutoHashMap(CurrencyUnit, std.ArrayList(MintKeySetInfo)).init(keyset_infos.arena.allocator());

                for (keyset_infos.value.items) |ks| {
                    var gop = try result.getOrPut(ks.unit);
                    if (!gop.found_existing) {
                        // already exist
                        gop.value_ptr.* = std.ArrayList(MintKeySetInfo).init(keyset_infos.arena.allocator());
                    }

                    try gop.value_ptr.append(ks);
                }

                break :v result;
            };

            var it = keysets_by_unit.iterator();

            while (it.next()) |entry| {
                const unit = entry.key_ptr.*;
                const _keysets = entry.value_ptr.*;

                std.sort.block(MintKeySetInfo, _keysets.items, {}, (struct {
                    fn compare(_: void, l: MintKeySetInfo, r: MintKeySetInfo) bool {
                        if (r.derivation_path_index) |r_dpi| {
                            if (l.derivation_path_index) |l_dpi| {
                                if (l_dpi < r_dpi) return true;
                            } else return true;
                        }

                        // other all cases false
                        return false;
                    }
                }).compare);

                const highest_index_keyset = _keysets.getLast();

                var keysets = try std.ArrayList(MintKeySetInfo).initCapacity(keyset_infos.arena.allocator(), _keysets.items.len);

                for (_keysets.items) |ks| {
                    if (ks.derivation_path_index != null) keysets.appendAssumeCapacity(ks);
                }

                if (supported_units.get(unit)) |supp_unit| {
                    const input_fee_ppk, const max_order = supp_unit;

                    const derivation_path_index: u32 = if (keysets.items.len == 0)
                        1
                    else if (highest_index_keyset.input_fee_ppk == input_fee_ppk and highest_index_keyset.max_order == max_order) {
                        const id = highest_index_keyset.id;
                        const keyset = try MintKeySet.generateFromXpriv(
                            keyset_infos.arena.allocator(),
                            secp_ctx,
                            xpriv,
                            highest_index_keyset.max_order,
                            highest_index_keyset.unit,
                            highest_index_keyset.derivation_path,
                        );

                        try active_keysets.put(id, keyset);
                        var keyset_info = highest_index_keyset;
                        keyset_info.active = true;

                        try localstore.addKeysetInfo(keyset_info);
                        try localstore.setActiveKeyset(unit, id);
                        continue;
                    } else highest_index_keyset.derivation_path_index orelse 0 + 1;

                    const derivation_path = derivationPathFromUnit(unit, derivation_path_index);

                    const keyset, const keyset_info = try createNewKeysetAlloc(
                        keyset_infos.arena.allocator(),
                        secp_ctx,
                        xpriv,
                        &derivation_path,
                        derivation_path_index,
                        unit,
                        max_order,
                        input_fee_ppk,
                    );

                    const id = keyset_info.id;
                    try localstore.addKeysetInfo(keyset_info);
                    try localstore.setActiveKeyset(unit, id);
                    try active_keysets.put(id, keyset);
                    try active_keyset_units.append(unit);
                }
            }
        }

        var it = supported_units.iterator();

        while (it.next()) |su_entry| {
            const unit = su_entry.key_ptr.*;
            const fee, const max_order = su_entry.value_ptr.*;

            for (active_keyset_units.items) |u| {
                if (std.meta.eql(u, unit)) break;
            } else {
                // not contains in array
                const derivation_path = derivationPathFromUnit(unit, 0);

                const keyset, const keyset_info = try createNewKeysetAlloc(
                    allocator,
                    secp_ctx,
                    xpriv,
                    &derivation_path,
                    0,
                    unit,
                    max_order,
                    fee,
                );
                defer keyset_info.deinit(allocator);

                const id = keyset_info.id;
                _ = try localstore.addKeysetInfo(keyset_info);
                try localstore.setActiveKeyset(unit, id);
                var old = try active_keysets.fetchPut(id, keyset) orelse continue;
                old.value.deinit();
            }
        }

        return .{
            .allocator = allocator,
            .keysets = .{
                .value = active_keysets,
                .lock = .{},
            },
            .mint_url = mint_url,
            .secp_ctx = secp_ctx,
            .xpriv = xpriv,
            .localstore = .{
                .value = localstore,
                .lock = .{},
            },
            .mint_info = mint_info,
        };
    }

    /// Creating new [`MintQuote`], all arguments are cloned and reallocated
    /// caller responsible on free resources of result
    pub fn newMintQuote(
        self: *Mint,
        allocator: std.mem.Allocator,
        mint_url: []const u8,
        request: []const u8,
        unit: nuts.CurrencyUnit,
        amount: core.amount.Amount,
        expiry: u64,
        ln_lookup: []const u8,
    ) !MintQuote {
        const nut04 = self.mint_info.nuts.nut04;
        if (nut04.disabled) return error.MintingDisabled;
        // TODO return check

        // if (nut04.getSettings(unit, .bolt11)) |settings| {
        //     if (settings.max_amount) |max_amount| if (amount > max_amount) return error.MintOverLimit;

        //     if (settings.min_amount) |min_amount| if (amount < min_amount) return error.MintUnderLimit;
        // } else return error.UnsupportedUnit;

        const quote = try MintQuote.initAlloc(
            allocator,
            mint_url,
            request,
            unit,
            amount,
            expiry,
            ln_lookup,
        );
        errdefer quote.deinit(allocator);

        std.log.debug("New mint quote: {any}", .{quote});

        self.localstore.lock.lock();

        defer self.localstore.lock.unlock();
        try self.localstore.value.addMintQuote(quote);

        return quote;
    }

    /// Creating new [`MeltQuote`], all arguments are cloned and reallocated
    /// caller responsible on free resources of result
    pub fn newMeltQuote(
        self: *Mint,
        request: []const u8,
        unit: nuts.CurrencyUnit,
        amount: core.amount.Amount,
        fee_reserve: core.amount.Amount,
        expiry: u64,
        request_lookup_id: []const u8,
    ) !MeltQuote {
        const nut05 = self.mint_info.nuts.nut05;
        if (nut05.disabled) return error.MeltingDisabled;
        // TODO return check

        // if (nut04.getSettings(unit, .bolt11)) |settings| {
        //     if (settings.max_amount) |max_amount| if (amount > max_amount) return error.MintOverLimit;

        //     if (settings.min_amount) |min_amount| if (amount < min_amount) return error.MintUnderLimit;
        // } else return error.UnsupportedUnit;

        const quote = MeltQuote.init(
            request,
            unit,
            amount,
            fee_reserve,
            expiry,
            request_lookup_id,
        );

        std.log.debug("New melt quote: {any}", .{quote});

        self.localstore.lock.lock();

        defer self.localstore.lock.unlock();
        try self.localstore.value.addMeltQuote(quote);

        return quote;
    }

    /// Check mint quote
    /// caller own result and should deinit
    pub fn checkMintQuote(self: *Mint, allocator: std.mem.Allocator, quote_id: [16]u8) !MintQuoteBolt11Response {
        const quote = v: {
            self.localstore.lock.lockShared();
            defer self.localstore.lock.unlockShared();
            break :v (try self.localstore.value.getMintQuote(allocator, quote_id)) orelse return error.UnknownQuote;
        };
        defer quote.deinit(allocator);

        const paid = quote.state == .paid;

        // Since the pending state is not part of the NUT it should not be part of the response.
        // In practice the wallet should not be checking the state of a quote while waiting for the mint response.
        const state = switch (quote.state) {
            .pending => MintQuoteState.paid,
            else => quote.state,
        };

        const result = MintQuoteBolt11Response{
            .quote = &quote.id,
            .request = quote.request,
            .paid = paid,
            .state = state,
            .expiry = quote.expiry,
        };
        return try result.clone(allocator);
    }

    /// Retrieve the public keys of the active keyset for distribution to wallet clients
    pub fn pubkeys(self: *Mint, allocator: std.mem.Allocator) !core.nuts.KeysResponse {
        const keyset_infos = try self.localstore.value.getKeysetInfos(allocator);
        defer keyset_infos.deinit();

        for (keyset_infos.value.items) |keyset_info| {
            try self.ensureKeysetLoaded(keyset_info.id);
        }

        self.keysets.lock.lockShared();
        defer self.keysets.lock.unlockShared();

        // core.nuts.KeySet
        var it = self.keysets.value.valueIterator();

        var result = try std.ArrayList(core.nuts.KeySet).initCapacity(allocator, it.len);
        errdefer {
            for (result.items) |*ks| ks.deinit(allocator);
            result.deinit();
        }

        while (it.next()) |k| {
            result.appendAssumeCapacity(try k.toKeySet(allocator));
        }

        return .{
            .keysets = result.items,
        };
    }

    /// Ensure Keyset is loaded in mint
    pub fn ensureKeysetLoaded(self: *Mint, id: core.nuts.Id) !void {
        // check if keyset already in
        {
            self.keysets.lock.lockShared();
            defer self.keysets.lock.lockShared();

            if (self.keysets.value.contains(id)) return;
        }

        const keyset_info = try self.localstore.value.getKeysetInfo(self.allocator, id) orelse return error.UnknownKeySet;
        errdefer keyset_info.deinit(self.allocator);

        self.keysets.lock.lock();
        defer self.keysets.lock.unlock();

        // ensuring that map got enough space
        try self.keysets.value.ensureUnusedCapacity(1);

        // allocating through internal because we own this inside Mint
        const mint_keyset = try self.generateKeyset(self.allocator, keyset_info);
        errdefer mint_keyset.deinit(self.allocator);

        self.keysets.value.putAssumeCapacity(
            id,
            mint_keyset,
        );

        return;
    }

    /// Generate [`MintKeySet`] from [`MintKeySetInfo`]
    pub fn generateKeyset(self: *Mint, allocator: std.mem.Allocator, keyset_info: MintKeySetInfo) !core.nuts.MintKeySet {
        return try core.nuts.MintKeySet.generateFromXpriv(
            allocator,
            self.secp_ctx,
            self.xpriv,
            keyset_info.max_order,
            keyset_info.unit,
            keyset_info.derivation_path,
        );
    }

    /// Return a list of all supported keysets
    /// caller responsible to deallocate result
    pub fn getKeysets(self: *Mint, allocator: std.mem.Allocator) !core.nuts.KeysetResponse {
        const keysets = try self.localstore.value.getKeysetInfos(allocator);
        defer keysets.deinit();

        var _active_keysets = try self.localstore.value.getActiveKeysets(allocator);
        defer _active_keysets.deinit();

        var active_keysets = std.AutoHashMap(core.nuts.Id, void).init(allocator);
        defer active_keysets.deinit();

        var it = _active_keysets.valueIterator();
        while (it.next()) |value| try active_keysets.put(value.*, {});

        var result = try std.ArrayList(core.nuts.KeySetInfo).initCapacity(allocator, keysets.value.items.len);
        errdefer result.deinit();

        for (keysets.value.items) |ks| {
            result.appendAssumeCapacity(.{
                .id = ks.id,
                .unit = ks.unit,
                .active = active_keysets.contains(ks.id),
                .input_fee_ppk = ks.input_fee_ppk,
            });
        }

        return .{
            .keysets = try result.toOwnedSlice(),
        };
    }

    /// Add current keyset to inactive keysets
    /// Generate new keyset
    pub fn rotateKeyset(
        self: *Mint,
        allocator: std.mem.Allocator,
        unit: nuts.CurrencyUnit,
        derivation_path_index: u32,
        max_order: u8,
        input_fee_ppk: u64,
    ) !void {
        const derivation_path = derivationPathFromUnit(unit, derivation_path_index);
        var keyset, const keyset_info = try createNewKeysetAlloc(
            allocator,
            self.secp_ctx,
            self.xpriv,
            &derivation_path,
            derivation_path_index,
            unit,
            max_order,
            input_fee_ppk,
        );
        defer keyset_info.deinit(allocator);
        defer keyset.deinit();

        const id = keyset_info.id;
        try self.localstore.value.addKeysetInfo(keyset_info);
        try self.localstore.value.setActiveKeyset(unit, id);

        self.keysets.lock.lock();
        defer self.keysets.lock.unlock();
        try self.keysets.value.put(id, keyset);
    }

    /// Check state
    pub fn checkState(
        self: *Mint,
        allocator: std.mem.Allocator,
        check_state: core.nuts.nut07.CheckStateRequest,
    ) !core.nuts.nut07.CheckStateResponse {
        const _states = try self.localstore.value.getProofsStates(allocator, check_state.ys);
        defer _states.deinit();

        var states = try std.ArrayList(core.nuts.nut07.ProofState).initCapacity(allocator, _states.items.len);
        errdefer {
            for (states.items) |s| s.deinit(allocator);
            states.deinit();
        }

        const min_length = @min(_states.items.len, check_state.ys.len);

        for (check_state.ys[0..min_length], _states.items[0..min_length]) |y, s| {
            const state: core.nuts.nut07.State = s orelse .unspent;

            states.appendAssumeCapacity(.{
                .y = y,
                .state = state,
                .witness = null,
            });
        }

        return .{ .states = try states.toOwnedSlice() };
    }

    /// Retrieve the public keys of the active keyset for distribution to wallet clients
    pub fn keysetPubkeys(self: *Mint, allocator: std.mem.Allocator, keyset_id: nuts.Id) !nuts.KeysResponse {
        try self.ensureKeysetLoaded(keyset_id);
        self.keysets.lock.lock();
        defer self.keysets.lock.unlock();

        const keyset = self.keysets.value.get(keyset_id) orelse return error.UnknownKeySet;

        const keysets = try allocator.alloc(nuts.KeySet, 1);
        errdefer allocator.free(keysets);

        keysets[0] = try keyset.toKeySet(allocator);

        return .{
            .keysets = keysets,
        };
    }

    /// Flag mint quote as paid
    pub fn payMintQuoteForRequestId(
        self: *Mint,
        request_lookup_id: []const u8,
    ) !void {
        const mint_quote = (try self.localstore.value.getMintQuoteByRequestLookupId(self.allocator, request_lookup_id)) orelse return;

        std.log.debug("Quote {any} paid by lookup id {s}", .{
            mint_quote,
            request_lookup_id,
        });

        _ = try self.localstore.value.updateMintQuoteState(mint_quote.id, .paid);
    }
};

/// Generate new [`MintKeySetInfo`] from path
fn createNewKeysetAlloc(
    allocator: std.mem.Allocator,
    secp: secp256k1.Secp256k1,
    xpriv: bip32.ExtendedPrivKey,
    derivation_path: []const bip32.ChildNumber,
    derivation_path_index: ?u32,
    unit: core.nuts.CurrencyUnit,
    max_order: u8,
    input_fee_ppk: u64,
) !struct { MintKeySet, MintKeySetInfo } {
    const keyset = try MintKeySet.generate(
        allocator,
        secp,
        xpriv
            .derivePriv(secp, derivation_path) catch @panic("RNG busted"),
        unit,
        max_order,
    );

    const keyset_info = try MintKeySetInfo.clone(.{
        .id = keyset.id,
        .unit = keyset.unit,
        .active = true,
        .valid_from = @intCast(std.time.timestamp()),
        .valid_to = null,
        .derivation_path = derivation_path,
        .derivation_path_index = derivation_path_index,
        .max_order = max_order,
        .input_fee_ppk = input_fee_ppk,
    }, allocator);

    return .{ keyset, keyset_info };
}

fn derivationPathFromUnit(unit: core.nuts.CurrencyUnit, index: u32) [3]bip32.ChildNumber {
    return .{
        bip32.ChildNumber.fromHardenedIdx(0) catch @panic("0 is a valid index"),
        bip32.ChildNumber.fromHardenedIdx(unit.derivationIndex()) catch @panic("0 is a valid index"),
        bip32.ChildNumber.fromHardenedIdx(index) catch @panic("0 is a valid index"),
    };
}

const expectEqual = std.testing.expectEqual;

test "mint mod generate keyset from seed" {
    const seed = "test_seed";

    var secp = secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    var keyset = try MintKeySet.generateFromSeed(
        std.testing.allocator,
        secp,
        seed,
        2,
        .sat,
        &derivationPathFromUnit(.sat, 0),
    );
    defer keyset.deinit();

    try expectEqual(.sat, keyset.unit);
    try expectEqual(2, keyset.keys.inner.count());

    try expectEqual(try secp256k1.PublicKey.fromString("0257aed43bf2c1cdbe3e7ae2db2b27a723c6746fc7415e09748f6847916c09176e"), keyset.keys.inner.get(1).?.public_key);
    try expectEqual(try secp256k1.PublicKey.fromString("03ad95811e51adb6231613f9b54ba2ba31e4442c9db9d69f8df42c2b26fbfed26e"), keyset.keys.inner.get(2).?.public_key);
}

test "mint mod generate keyset from xpriv" {
    const seed = "test_seed";

    var secp = secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    const xpriv = try bip32.ExtendedPrivKey.initMaster(.MAINNET, seed);

    var keyset = try MintKeySet.generateFromXpriv(
        std.testing.allocator,
        secp,
        xpriv,
        2,
        .sat,
        &derivationPathFromUnit(.sat, 0),
    );
    defer keyset.deinit();

    try expectEqual(.sat, keyset.unit);
    try expectEqual(2, keyset.keys.inner.count());

    try expectEqual(try secp256k1.PublicKey.fromString("0257aed43bf2c1cdbe3e7ae2db2b27a723c6746fc7415e09748f6847916c09176e"), keyset.keys.inner.get(1).?.public_key);
    try expectEqual(try secp256k1.PublicKey.fromString("03ad95811e51adb6231613f9b54ba2ba31e4442c9db9d69f8df42c2b26fbfed26e"), keyset.keys.inner.get(2).?.public_key);
}

const MintConfig = struct {
    active_keysets: std.AutoHashMap(CurrencyUnit, core.nuts.Id),
    keysets: []const MintKeySetInfo = &.{},
    mint_quotes: []const MintQuote = &.{},
    melt_quotes: []const MeltQuote = &.{},
    pending_proofs: []const core.nuts.Proof = &.{},
    spent_proofs: []const core.nuts.Proof = &.{},
    blinded_signatures: std.AutoHashMap([33]u8, core.nuts.BlindSignature),
    mint_url: []const u8 = &.{},
    seed: []const u8 = &.{},
    mint_info: MintInfo = .{},
    supported_units: std.AutoHashMap(CurrencyUnit, std.meta.Tuple(&.{ u64, u8 })),
};

fn createMint(arena: std.mem.Allocator, config: MintConfig) !Mint {
    const db_ptr = try arena.create(MintMemoryDatabase);
    db_ptr.* = try MintMemoryDatabase.initFrom(arena, config.active_keysets, config.keysets, config.mint_quotes, config.melt_quotes, config.pending_proofs, config.spent_proofs, config.blinded_signatures);

    return Mint.init(
        arena,
        config.mint_url,
        config.seed,
        config.mint_info,
        db_ptr,
        config.supported_units,
    );
}

test "mint mod rotate keyset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const config = MintConfig{
        .active_keysets = std.AutoHashMap(CurrencyUnit, core.nuts.Id).init(allocator),
        .blinded_signatures = std.AutoHashMap([33]u8, core.nuts.BlindSignature).init(allocator),
        .supported_units = std.AutoHashMap(CurrencyUnit, std.meta.Tuple(&.{ u64, u8 })).init(allocator),
    };

    var mint = try createMint(allocator, config);

    // dont deallocate due arena allocator
    var keysets = try mint.getKeysets(allocator);

    try expectEqual(0, keysets.keysets.len);

    // generate the first keyset and set it to active
    try mint.rotateKeyset(allocator, .sat, 0, 1, 1);

    // dont deallocate due arena allocator
    keysets = try mint.getKeysets(allocator);

    try expectEqual(1, keysets.keysets.len);
    try expectEqual(true, keysets.keysets[0].active);

    const first_keyset_id = keysets.keysets[0].id;

    // set the first keyset to inactive and generate a new keyset
    try mint.rotateKeyset(allocator, .sat, 1, 1, 1);

    // dont deallocate due arena allocator
    keysets = try mint.getKeysets(allocator);

    try expectEqual(2, keysets.keysets.len);

    for (keysets.keysets) |keyset| {
        if (std.meta.eql(keyset.id, first_keyset_id)) {
            try expectEqual(false, keyset.active);
        } else {
            try expectEqual(true, keyset.active);
        }
    }
}

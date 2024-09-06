const std = @import("std");
const core = @import("../lib.zig");
const secp256k1 = @import("secp256k1");
const bip32 = @import("bitcoin").bitcoin.bip32;
const helper = @import("../../helper/helper.zig");
const nuts = core.nuts;

const RWMutex = helper.RWMutex;
const MintInfo = core.nuts.MintInfo;
const MintQuoteBolt11Response = core.nuts.nut04.MintQuoteBolt11Response;
const MintQuoteState = core.nuts.nut04.QuoteState;

pub const MintQuote = @import("types.zig").MintQuote;
pub const MeltQuote = @import("types.zig").MeltQuote;
pub const MintMemoryDatabase = core.mint_memory.MintMemoryDatabase;

// TODO implement tests

/// Mint Fee Reserve
pub const FeeReserve = struct {
    /// Absolute expected min fee
    min_fee_reserve: core.amount.Amount,
    /// Percentage expected fee
    percent_fee_reserve: f32,
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

    pub fn clone(self: *const MintKeySetInfo, allocator: std.mem.Allocator) !MintKeySetInfo {
        var cloned = self.*;

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
    mint_url: std.Uri,
    /// Mint Info
    mint_info: MintInfo,
    /// Mint Storage backend
    localstore: helper.RWMutex(MintMemoryDatabase),
    /// Active Mint Keysets
    keysets: RWMutex(std.AutoHashMap(nuts.Id, nuts.MintKeySet)),
    secp_ctx: secp256k1.Secp256k1,
    xpriv: bip32.ExtendedPrivKey,

    // using for allocating data belongs to mint
    allocator: std.mem.Allocator,

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

        if (nut04.getSettings(unit, .bolt11)) |settings| {
            if (settings.max_amount) |max_amount| if (amount > max_amount) return error.MintOverLimit;

            if (settings.min_amount) |min_amount| if (amount < min_amount) return error.MintUnderLimit;
        } else return error.UnsupportedUnit;

        const quote = try MintQuote.initAlloc(allocator, mint_url, request, unit, amount, expiry, ln_lookup);
        errdefer quote.deinit(allocator);

        std.log.debug("New mint quote: {any}", .{quote});

        self.localstore.lock.lock();

        defer self.localstore.lock.unlock();
        try self.localstore.value.addMintQuote(quote);

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
            try self.ensureKeysetLoaded(allocator, keyset_info.id);
        }

        self.keysets.lock.lockShared();
        defer self.keysets.lock.unlockShared();

        // core.nuts.KeySet
        var it = self.keysets.value.valueIterator();

        var result = try std.ArrayList(core.nuts.KeySet).initCapacity(allocator, it.len);
        errdefer {
            for (result.items) |ks| ks.deinit();
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
            &self.secp_ctx,
            self.xpriv,
            keyset_info.max_order,
            keyset_info.unit,
            keyset_info.derivation_path,
        );
    }
};

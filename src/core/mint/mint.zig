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

    /// Creating new [`MintQuote`], all arguments are cloned and reallocated
    /// caller responsible on free resources of result
    pub fn newMintQuote(
        self: *const Mint,
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

        const quote = try MintQuote.init(allocator, mint_url, request, unit, amount, expiry, ln_lookup.clone());
        errdefer quote.deinit(allocator);

        std.log.debug("New mint quote: {any}", .{quote});

        self.localstore.lock.lock();

        defer self.localstore.lock.unlock();
        try self.localstore.value.addMintQuote(quote);

        return quote;
    }

    /// Check mint quote
    /// caller own result and should deinit
    pub fn checkMintQuote(self: *const Mint, allocator: std.mem.Allocator, quote_id: [16]u8) !MintQuoteBolt11Response {
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
            .quote = quote.id,
            .request = quote.request,
            .paid = paid,
            .state = state,
            .expiry = quote.expiry,
        };
        return try result.clone(allocator);
    }
};

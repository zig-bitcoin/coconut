const nuts = @import("../core/lib.zig").nuts;
const std = @import("std");
const amount_lib = @import("../core/lib.zig").amount;
const CurrencyUnit = @import("../core/lib.zig").nuts.CurrencyUnit;
const MintQuoteState = @import("../core/lib.zig").nuts.nut04.QuoteState;
const MeltQuoteState = @import("../core/lib.zig").nuts.nut05.QuoteState;
const zul = @import("zul");

/// Mint Quote Info
pub const MintQuote = struct {
    /// Quote id
    id: [16]u8,
    /// Mint Url
    mint_url: std.Uri,
    /// Amount of quote
    amount: amount_lib.Amount,
    /// Unit of quote
    unit: CurrencyUnit,
    /// Quote payment request e.g. bolt11
    request: []const u8,
    /// Quote state
    state: MintQuoteState,
    /// Expiration time of quote
    expiry: u64,
    /// Value used by ln backend to look up state of request
    request_lookup_id: []const u8,

    /// Create new [`MintQuote`]
    pub fn init(
        mint_url: std.Uri,
        request: []const u8,
        unit: CurrencyUnit,
        amount: amount_lib.Amount,
        expiry: u64,
        request_lookup_id: []const u8,
    ) MintQuote {
        const id = zul.UUID.v4();

        return .{
            .mint_url = mint_url,
            .id = id.bin,
            .amount = amount,
            .unit = unit,
            .request = request,
            .state = .unpaid,
            .expiry = expiry,
            .request_lookup_id = request_lookup_id,
        };
    }
};

/// Melt Quote Info
pub const MeltQuote = struct {
    /// Quote id
    id: [16]u8,
    /// Quote unit
    unit: CurrencyUnit,
    /// Quote amount
    amount: amount_lib.Amount,
    /// Quote Payment request e.g. bolt11
    request: []const u8,
    /// Quote fee reserve
    fee_reserve: amount_lib.Amount,
    /// Quote state
    state: MeltQuoteState,
    /// Expiration time of quote
    expiry: u64,
    /// Payment preimage
    payment_preimage: ?[]const u8,
    /// Value used by ln backend to look up state of request
    request_lookup_id: []const u8,

    /// Create new [`MeltQuote`]
    pub fn init(
        request: []const u8,
        unit: CurrencyUnit,
        amount: amount_lib.Amount,
        fee_reserve: amount_lib.Amount,
        expiry: u64,
        request_lookup_id: []const u8,
    ) MeltQuote {
        const id = zul.UUID.v4();

        return .{
            .id = id.bin,
            .amount = amount,
            .unit = unit,
            .request = request,
            .fee_reserve = fee_reserve,
            .state = .unpaid,
            .expiry = expiry,
            .payment_preimage = null,
            .request_lookup_id = request_lookup_id,
        };
    }
};

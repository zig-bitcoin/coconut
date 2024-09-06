//! Mint Lightning
const root = @import("../../lib.zig");
const std = @import("std");

const Bolt11Invoice = root.lightning_invoices.Bolt11Invoice;
const Amount = root.core.amount.Amount;
const MeltQuoteState = root.core.nuts.nut05.QuoteState;
const CurrencyUnit = root.core.nuts.CurrencyUnit;

/// Create invoice response
pub const CreateInvoiceResponse = struct {
    /// Id that is used to look up the invoice from the ln backend
    request_lookup_id: []const u8,
    /// Bolt11 payment request
    request: Bolt11Invoice,
    /// Unix Expiry of Invoice
    expiry: ?u64,
};

/// Pay invoice response
pub const PayInvoiceResponse = struct {
    /// Payment hash
    payment_hash: []const u8,
    /// Payment Preimage
    payment_preimage: ?[]const u8,
    /// Status
    status: MeltQuoteState,
    /// Totoal Amount Spent
    total_spent: Amount,

    pub fn deinit(self: PayInvoiceResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.payment_hash);

        if (self.payment_preimage) |p| allocator.free(p);
    }
};

/// Payment quote response
pub const PaymentQuoteResponse = struct {
    /// Request look up id
    request_lookup_id: []const u8,
    /// Amount
    amount: Amount,
    /// Fee required for melt
    fee: u64,

    pub fn deinit(self: PaymentQuoteResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.request_lookup_id);
    }
};

/// Ln backend settings
pub const Settings = struct {
    /// MPP supported
    mpp: bool,
    /// Min amount to mint
    mint_settings: MintMeltSettings,
    /// Max amount to mint
    melt_settings: MintMeltSettings,
    /// Base unit of backend
    unit: CurrencyUnit,
};

/// Mint or melt settings
pub const MintMeltSettings = struct {
    /// Min Amount
    min_amount: Amount = 1,
    /// Max Amount
    max_amount: Amount = 500000,
    /// Enabled
    enabled: bool = true,
};

const MSAT_IN_SAT: u64 = 1000;

/// Helper function to convert units
pub fn toUnit(
    amount: u64,
    current_unit: CurrencyUnit,
    target_unit: CurrencyUnit,
) !Amount {
    switch (current_unit) {
        .sat => switch (target_unit) {
            .sat => return amount,
            .msat => return amount * MSAT_IN_SAT,
            else => {},
        },
        .msat => switch (target_unit) {
            .sat => return amount / MSAT_IN_SAT,
            .msat => return amount,
            else => {},
        },
        .usd => switch (target_unit) {
            .usd => return amount,
            else => {},
        },
        .eur => switch (target_unit) {
            .eur => return amount,
            else => {},
        },
    }

    return error.CannotConvertUnits;
}

// TODO implement MintLighting interface here

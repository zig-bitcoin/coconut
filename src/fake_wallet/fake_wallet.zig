//! Fake LN Backend
//!
//! Used for testing where quotes are auto filled
const core = @import("../core/lib.zig");
const std = @import("std");
const lightning_invoice = @import("../lightning_invoices/invoice.zig");
const helper = @import("../helper/helper.zig");

const Amount = core.amount.Amount;
const PaymentQuoteResponse = core.lightning.PaymentQuoteResponse;
const PayInvoiceResponse = core.lightning.PayInvoiceResponse;
const MeltQuoteBolt11Request = core.nuts.nut05.MeltQuoteBolt11Request;
const Settings = core.lightning.Settings;
const MintMeltSettings = core.lightning.MintMeltSettings;
const FeeReserve = core.mint.FeeReserve;
const Channel = @import("channels").Chan;
const MintQuoteState = core.nuts.nut04.QuoteState;

// TODO:  wait any invoices, here we need create a new listener, that will receive
// message like pub sub channel

/// Fake Wallet
pub const FakeWallet = struct {
    const Self = @This();

    fee_reserve: core.mint.FeeReserve,
    chan: Channel([]const u8) = .{}, // TODO
    mint_settings: MintMeltSettings,
    melt_settings: MintMeltSettings,

    /// Creat new [`FakeWallet`]
    pub fn new(
        fee_reserve: FeeReserve,
        mint_settings: MintMeltSettings,
        melt_settings: MintMeltSettings,
    ) !FakeWallet {
        return .{
            .fee_reserve = fee_reserve,
            .mint_settings = mint_settings,
            .melt_settings = melt_settings,
        };
    }

    pub fn getSettings(self: *const Self) Settings {
        return .{
            .mpp = true,
            .unit = .msat,
            .melt_settings = self.mel_settings,
            .mint_settings = self.mint_settings,
        };
    }

    // Result is channel with invoices, caller must free result
    pub fn waitAnyInvoice(
        self: *const Self,
        allocator: std.mem.Allocator,
    ) !Channel([]const u8) {
        _ = self; // autofix
        return Channel([]const u8).init(allocator);
    }

    /// caller responsible to deallocate result
    pub fn getPaymentQuote(
        self: *const Self,
        allocator: std.mem.Allocator,
        melt_quote_request: MeltQuoteBolt11Request,
    ) !PaymentQuoteResponse {
        const invoice_amount_msat = melt_quote_request
            .request
            .amountMilliSatoshis() orelse return error.UnknownInvoiceAmount;

        const amount = try core.lightning.toUnit(
            invoice_amount_msat,
            .msat,
            melt_quote_request.unit,
        );

        const relative_fee_reserve: u64 =
            @intFromFloat(@as(f32, @floatFromInt(self.fee_reserve.percent_fee_reserve * amount)));

        const absolute_fee_reserve: u64 = self.fee_reserve.min_fee_reserve;

        const fee = if (relative_fee_reserve > absolute_fee_reserve)
            relative_fee_reserve
        else
            absolute_fee_reserve;

        const req_lookup_id = try helper.copySlice(allocator, &melt_quote_request.request.paymentHash());
        errdefer allocator.free(req_lookup_id);

        return .{
            .request_lookup_id = req_lookup_id,
            .amount = amount,
            .fee = fee,
        };
    }

    /// pay invoice, caller responsible too free
    pub fn payInvoice(
        self: *const Self,
        allocator: std.mem.Allocator,
        melt_quote: core.mint.MeltQuote,
        _partial_msats: ?Amount,
        _max_fee_msats: ?Amount,
    ) !PayInvoiceResponse {
        _ = allocator; // autofix
        _ = self; // autofix
        _ = _partial_msats; // autofix
        _ = _max_fee_msats; // autofix

        return .{
            .payment_preimage = &.{},
            .payment_hash = &.{}, // empty slice - safe to free
            .status = .paid,
            .total_spend = melt_quote.amount,
        };
    }

    pub fn checkInvoiceStatus(
        self: *const Self,
        _request_lookup_id: []const u8,
    ) !MintQuoteState {
        _ = self; // autofix
        _ = _request_lookup_id; // autofix
        return .paid;
    }

    // create_invoice TODO after implementing PubSub/REST Server
};

test {}

//! Fake LN Backend
//!
//! Used for testing where quotes are auto filled
const core = @import("../core/lib.zig");
const std = @import("std");
const lightning_invoice = @import("../lightning_invoices/invoice.zig");
const helper = @import("../helper/helper.zig");
const zul = @import("zul");
const secp256k1 = @import("secp256k1");

const Amount = core.amount.Amount;
const PaymentQuoteResponse = core.lightning.PaymentQuoteResponse;
const CreateInvoiceResponse = core.lightning.CreateInvoiceResponse;
const PayInvoiceResponse = core.lightning.PayInvoiceResponse;
const MeltQuoteBolt11Request = core.nuts.nut05.MeltQuoteBolt11Request;
const Settings = core.lightning.Settings;
const MintMeltSettings = core.lightning.MintMeltSettings;
const FeeReserve = core.mint.FeeReserve;
const Channel = @import("../channels/channels.zig").Channel;
const MintQuoteState = core.nuts.nut04.QuoteState;

// TODO:  wait any invoices, here we need create a new listener, that will receive
// message like pub sub channel

/// Fake Wallet
pub const FakeWallet = struct {
    const Self = @This();

    fee_reserve: core.mint.FeeReserve,
    chan: *Channel([]const u8), // we using signle channel for sending invoices
    mint_settings: MintMeltSettings,
    melt_settings: MintMeltSettings,

    /// Creat init [`FakeWallet`]
    pub fn init(
        allocator: std.mem.Allocator,
        fee_reserve: FeeReserve,
        mint_settings: MintMeltSettings,
        melt_settings: MintMeltSettings,
    ) !FakeWallet {
        return .{
            .chan = try Channel([]const u8).init(allocator, 0),
            .fee_reserve = fee_reserve,
            .mint_settings = mint_settings,
            .melt_settings = melt_settings,
        };
    }

    pub fn deinit(self: *FakeWallet) void {
        self.chan.deinit();
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
    ) !Channel([]const u8).Rx {
        return self.chan.getRx();
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

    pub fn createInvoice(
        self: *const Self,
        gpa: std.mem.Allocator,
        amount: Amount,
        unit: core.nuts.CurrencyUnit,
        description: []const u8,
        unix_expiry: u64,
    ) !CreateInvoiceResponse {
        const time_now: u64 = @intCast(std.time.timestamp());
        std.debug.assert(unix_expiry > time_now);

        const label = zul.UUID.v4().toHex(.lower);

        const private_key = try secp256k1.SecretKey.fromSlice(
            &.{
                0xe1, 0x26, 0xf6, 0x8f, 0x7e, 0xaf, 0xcc, 0x8b, 0x74, 0xf5, 0x4d, 0x26, 0x9f, 0xe2,
                0x06, 0xbe, 0x71, 0x50, 0x00, 0xf9, 0x4d, 0xac, 0x06, 0x7d, 0x1c, 0x04, 0xa8, 0xca,
                0x3b, 0x2d, 0xb7, 0x34,
            },
        );

        const sha256 = std.crypto.hash.sha2.Sha256;

        const payment_hash: [sha256.digest_length]u8 = undefined;

        sha256.hash(&([_]u8{0} ** 32), &payment_hash, .{});

        const payment_secret = [_]u8{42} ** 32;

        const _amount = try core.lightning.toUnit(amount, unit, .msat);

        var invoice_builder = try lightning_invoice.InvoiceBuilder.init(gpa, .bitcoin);
        // errdefer invoice_builder.deinit(); // TODO

        try invoice_builder.setDescription(gpa, description);
        try invoice_builder.setPaymentHash(gpa, payment_hash);
        try invoice_builder.setPaymentSecret(gpa, .{ .inner = payment_secret });
        try invoice_builder.setAmountMilliSatoshis(_amount);
        try invoice_builder.setCurrentTimestamp();
        try invoice_builder.setMinFinalCltvExpiryDelta(144);
        try invoice_builder.tryBuildSigned(gpa, (struct {
            var pk = private_key;

            fn sign(hash: secp256k1.Message) !secp256k1.ecdsa.RecoverableSignature {
                var secp = secp256k1.Secp256k1.genNew();
                defer secp.deinit();

                return try secp.signEcdsaRecoverable(&hash, pk);
            }
        }).sign);

        _ = label; // autofix
        _ = self; // autofix
    }
};

test {}

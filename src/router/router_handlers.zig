const std = @import("std");
const httpz = @import("httpz");
const core = @import("../core/lib.zig");
const zul = @import("zul");
const ln_invoice = @import("../lightning_invoices/invoice.zig");

const MintLightning = core.lightning.MintLightning;
const MintState = @import("router.zig").MintState;
const LnKey = @import("router.zig").LnKey;

pub fn getKeys(state: MintState, req: *httpz.Request, res: *httpz.Response) !void {
    const pubkeys = try state.mint.pubkeys(req.arena);

    return try res.json(pubkeys, .{});
}

pub fn getKeysets(state: MintState, req: *httpz.Request, res: *httpz.Response) !void {
    const keysets = try state.mint.getKeysets(req.arena);

    return try res.json(keysets, .{});
}

pub fn getKeysetPubkeys(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const ks_id = try core.nuts.Id.fromStr(req.param("keyset_id") orelse return error.ExpectKeysetId);
    const pubkeys = try state.mint.keysetPubkeys(req.arena, ks_id);

    return try res.json(pubkeys, .{});
}

pub fn getCheckMintBolt11Quote(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const quote_id_hex = req.param("quote_id") orelse return error.ExpectQuoteId;

    const quote_id = try zul.UUID.parse(quote_id_hex);
    const quote = state
        .mint
        .checkMintQuote(res.arena, quote_id) catch |err| {
        std.log.debug("Could not check mint quote {any}: {any}", .{ quote_id, err });
        return error.CheckMintQuoteFailed;
    };

    return try res.json(quote, .{});
}

pub fn getCheckMeltBolt11Quote(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const quote_id_hex = req.param("quote_id") orelse return error.ExpectQuoteId;

    const quote_id = try zul.UUID.parse(quote_id_hex);
    const quote = state
        .mint
        .checkMeltQuote(res.arena, quote_id) catch |err| {
        std.log.debug("Could not check melt quote {any}: {any}", .{ quote_id, err });
        return error.CheckMintQuoteFailed;
    };

    return try res.json(quote, .{});
}

pub fn postCheck(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    if (try req.json(core.nuts.nut07.CheckStateRequest)) |r| {
        return try res.json(try state.mint.checkState(res.arena, r), .{});
    }

    return error.ExpectedBody;
}

pub fn getMintInfo(
    state: MintState,
    _: *httpz.Request,
    res: *httpz.Response,
) !void {
    return try res.json(state.mint.mint_info, .{});
}

pub fn getMintBolt11Quote(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    std.log.debug("get mint bolt11 quote req", .{});

    const payload = (try req.json(core.nuts.nut04.MintQuoteBolt11Request)) orelse return error.WrongRequest;

    const ln: MintLightning = state.ln.get(LnKey.init(payload.unit, .bolt11)) orelse {
        return error.UnsupportedUnit;
    };

    const amount =
        core.lightning.toUnit(payload.amount, payload.unit, ln.getSettings().unit) catch |err| {
        std.log.err("backend does not support unit: {any}", .{err});

        return error.UnsupportedUnit;
    };

    const quote_expiry = @as(u64, @intCast(std.time.timestamp())) + state.quote_ttl;

    const create_invoice_response = ln.createInvoice(res.arena, amount, ln.getSettings().unit, "", quote_expiry) catch |err| {
        std.log.err("could not create invoice: {any}", .{err});
        return error.InvalidPaymentRequest;
    };

    const quote = state.mint.newMintQuote(
        res.arena,
        state.mint_url,
        try create_invoice_response.request.signed_invoice.toStrAlloc(res.arena),
        payload.unit,
        payload.amount,
        create_invoice_response.expiry orelse 0,
        create_invoice_response.request_lookup_id,
    ) catch |err| {
        std.log.err("could not create new mint quote: {any}", .{err});
        return error.InternalError;
    };

    return try res.json(
        try core.nuts.nut04.MintQuoteBolt11Response.fromMintQuote(quote),
        .{},
    );
}

pub fn postMintBolt11(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    errdefer std.log.debug("{any}", .{@errorReturnTrace()});

    const payload = try req.json(core.nuts.nut04.MintBolt11Request) orelse return error.WrongRequest;

    const r = state.mint
        .processMintRequest(res.arena, payload) catch |err| {
        // TODO print self error
        std.log.err("could not process mint {any}, err {any}", .{ payload, err });

        return err;
    };

    return try res.json(r, .{});
}

pub fn getMeltBolt11Quote(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    errdefer std.log.debug("{any}", .{@errorReturnTrace()});

    const payload = (try req.json(core.nuts.nut05.MeltQuoteBolt11Request)) orelse return error.WrongRequest;

    const ln: MintLightning = state.ln.get(LnKey.init(payload.unit, .bolt11)) orelse {
        return error.UnsupportedUnit;
    };

    const payment_quote = ln.getPaymentQuote(res.arena, payload) catch |err| {
        std.log.err("Could not get payment quote for mint quote, {any} bolt11, {any}", .{
            payload.unit,
            err,
        });

        return error.UnsupportedUnit;
    };

    const quote = state
        .mint
        .newMeltQuote(
        try payload.request.signed_invoice.toStrAlloc(res.arena),
        payload.unit,
        payment_quote.amount,
        payment_quote.fee,
        @as(u64, @intCast(std.time.timestamp())) + state.quote_ttl,
        payment_quote.request_lookup_id,
    ) catch |err| {
        std.log.err("Could not create melt quote: {any}", .{err});
        return error.InternalError;
    };
    return try res.json(core.nuts.nut05.MeltQuoteBolt11Response.fromMeltQuote(quote), .{
        .emit_null_optional_fields = false,
    });
}

pub fn postSwap(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    errdefer std.log.debug("{any}", .{@errorReturnTrace()});

    const payload = (try req.json(core.nuts.SwapRequest)) orelse return error.WrongRequest;

    const swap_response = state.mint.processSwapRequest(res.arena, payload) catch |err| {
        std.log.err("Could not process swap request: {}", .{err});
        return err;
    };

    return try res.json(swap_response, .{});
}

pub fn postMeltBolt11(
    state: MintState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const payload = try req.json(core.nuts.nut05.MeltBolt11Request) orelse return error.WrongRequest;

    const quote = state.mint.verifyMeltRequest(res.arena, payload) catch |err| {
        std.log.debug("Error attempting to verify melt quote: {any}", .{err});

        state.mint.processUnpaidMelt(payload) catch |e| {
            std.log.err("Could not reset melt quote state: {any}", .{e});
        };

        return error.MeltRequestInvalid;
    };

    // Check to see if there is a corresponding mint quote for a melt.
    // In this case the mint can settle the payment internally and no ln payment is needed
    const mint_quote = state.mint
        .localstore
        .value
        .getMintQuoteByRequest(res.arena, quote.request) catch |err| {
        std.log.debug("Error attempting to get mint quote: {}", .{err});

        state.mint.processUnpaidMelt(payload) catch |e| {
            std.log.err("Could not reset melt quote state: {}", .{e});
        };
        return error.DatabaseError;
    };

    const inputs_amount_quote_unit = payload.proofsAmount();

    const preimage: ?[]const u8, const amount_spent_quote_unit = if (mint_quote) |_mint_quote| v: {
        if (_mint_quote.state == .issued or _mint_quote.state == .paid) return error.RequestAlreadyPaid;
        var new_mint_quote = _mint_quote;

        if (new_mint_quote.amount > inputs_amount_quote_unit) {
            std.log.debug("Not enough inuts provided: {} needed {}", .{
                inputs_amount_quote_unit,
                new_mint_quote.amount,
            });

            state.mint.processUnpaidMelt(payload) catch |e| {
                std.log.err("Could not reset melt quote state: {}", .{e});
            };

            return error.InsufficientInputProofs;
        }
        new_mint_quote.state = .paid;

        const amount = quote.amount;

        state.mint.updateMintQuote(new_mint_quote) catch {
            state.mint.processUnpaidMelt(payload) catch |err| {
                std.log.err("Could not reset melt quote state: {}", .{err});
            };

            return error.DatabaseError;
        };

        break :v .{ null, amount };
    } else v: {
        const invoice = ln_invoice.Bolt11Invoice.fromStr(res.arena, quote.request) catch |err| {
            std.log.err("Melt quote has invalid payment request {}", .{err});
            state.mint.processUnpaidMelt(payload) catch |e| {
                std.log.err("Could not reset melt quote state: {}", .{e});
            };
            return error.InvalidPaymentRequest;
        };

        var partial_amount: ?core.amount.Amount = null;

        // If the quote unit is SAT or MSAT we can check that the expected fees are provided.
        // We also check if the quote is less then the invoice amount in the case that it is a mmp
        // However, if the quote id not of a bitcoin unit we cannot do these checks as the mint
        // is unaware of a conversion rate. In this case it is assumed that the quote is correct
        // and the mint should pay the full invoice amount if inputs > then quote.amount are included.
        // This is checked in the verify_melt method.
        if (quote.unit == .msat or quote.unit == .sat) {
            const quote_msats = try core.lightning.toUnit(quote.amount, quote.unit, .msat);

            const invoice_amount_msats = if (invoice.amountMilliSatoshis()) |amount| amount else {
                state.mint.processUnpaidMelt(payload) catch |e| {
                    std.log.err("Could not reset melt quote state: {}", .{e});
                };

                return error.InvoiceAmountUndefined;
            };

            partial_amount = if (invoice_amount_msats > quote_msats) am: {
                const partial_msats: u64 = invoice_amount_msats - quote_msats;

                break :am try core.lightning.toUnit(partial_msats, .msat, quote.unit);
            } else null;

            const amount_to_pay = if (partial_amount) |_amount| _amount else core.lightning.toUnit(invoice_amount_msats, .msat, quote.unit) catch return error.UnsupportedUnit;

            if (amount_to_pay + quote.fee_reserve > inputs_amount_quote_unit) {
                std.log.debug("Not enough inuts provided: {} msats needed {} msats", .{ inputs_amount_quote_unit, amount_to_pay });

                state.mint.processUnpaidMelt(payload) catch |e| {
                    std.log.err("Could not reset melt quote state: {}", .{e});
                };

                return error.InsufficientInputProofs;
            }
        }

        const ln: MintLightning = state.ln.get(.{ .unit = quote.unit, .method = .bolt11 }) orelse {
            state.mint.processUnpaidMelt(payload) catch |e| {
                std.log.err("Could not reset melt quote state: {}", .{e});
            };

            return error.UnsupportedUnit;
        };

        const pre = ln.payInvoice(res.arena, quote, partial_amount, quote.fee_reserve) catch |err| {
            std.log.err("Could not pay invoice: {}", .{err});

            state.mint.processUnpaidMelt(payload) catch |e| {
                std.log.err("Could not reset melt quote state: {}", .{e});
            };

            // TODO check invoice already paid
            //         let err = match err {
            //             cdk::cdk_lightning::Error::InvoiceAlreadyPaid => Error::RequestAlreadyPaid,
            //             _ => Error::PaymentFailed,
            //         };
            return err;
        };

        const amount_spent = core.lightning.toUnit(pre.total_spent, ln.getSettings().unit, quote.unit) catch return error.UnsupportedUnit;

        break :v .{
            pre.payment_preimage, amount_spent,
        };
    };

    const result = state.mint.processMeltRequest(
        res.arena,
        payload,
        preimage,
        amount_spent_quote_unit,
    ) catch |err| {
        std.log.err("Could not process melt request: {}", .{err});
        return err;
    };

    return try res.json(result, .{});
}

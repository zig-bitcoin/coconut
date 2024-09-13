const std = @import("std");
const httpz = @import("httpz");
const core = @import("../core/lib.zig");
const zul = @import("zul");

const FakeWallet = @import("../fake_wallet/fake_wallet.zig").FakeWallet;
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
        .checkMintQuote(res.arena, quote_id.bin) catch |err| {
        std.log.debug("Could not check mint quote {any}: {any}", .{ quote_id, err });
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

    const ln: FakeWallet = state.ln.get(LnKey.init(payload.unit, .bolt11)) orelse {
        std.log.err("Bolt11 mint request for unsupported unit, unit = {any}", .{payload.unit});

        return error.UnsupportedUnit;
    };

    const amount =
        core.lightning.toUnit(payload.amount, payload.unit, ln.getSettings().unit) catch |err| {
        std.log.err("backend does not support unit: {any}", .{err});

        return error.UnsupportedUnit;
    };

    const quote_expiry = @as(u64, @intCast(std.time.timestamp())) + state.quote_ttl;

    const create_invoice_response = ln.createInvoice(res.arena, amount, payload.unit, "", quote_expiry) catch |err| {
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
    const payload = (try req.json(core.nuts.nut05.MeltQuoteBolt11Request)) orelse return error.WrongRequest;

    const ln: FakeWallet = state.ln.get(LnKey.init(payload.unit, .bolt11)) orelse {
        std.log.err("Bolt11 mint request for unsupported unit, unit = {any}", .{payload.unit});

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
    return try res.json(core.nuts.nut05.MeltQuoteBolt11Response.fromMeltQuote(quote), .{});
}

const std = @import("std");
const httpz = @import("httpz");
const mint_lib = @import("../mint.zig");
const core = @import("../../core/lib.zig");
const zul = @import("zul");

pub fn getKeys(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req; // autofix
    // status code 200 is implicit.

    // The json helper will automatically set the res.content_type = httpz.ContentType.JSON;
    // Here we're passing an inferred anonymous structure, but you can pass anytype
    // (so long as it can be serialized using std.json.stringify)

    try res.json(&core.primitives.KeysResponse.initFrom(&.{.{
        .id = mint.keyset.keyset_id,
        .unit = .sat,
        .keys = mint.keyset.public_keys,
    }}), .{});
}

pub fn getKeysets(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req; // autofix
    // status code 200 is implicit.

    // The json helper will automatically set the res.content_type = httpz.ContentType.JSON;
    // Here we're passing an inferred anonymous structure, but you can pass anytype
    // (so long as it can be serialized using std.json.stringify)

    try res.json(&core.keyset.Keysets{
        .keysets = &.{
            .{
                .id = mint.keyset.keyset_id,
                .unit = .sat,
                .active = true,
            },
        },
    }, .{});
}

pub fn getKeysById(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id").?;

    if (!std.mem.eql(u8, id, &mint.keyset.keyset_id)) return error.KeysNotFound;

    try res.json(&core.primitives.KeysResponse.initFrom(&.{.{
        .id = mint.keyset.keyset_id,
        .unit = .sat,
        .keys = mint.keyset.public_keys,
    }}), .{});
}

pub fn swap(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    // TODO figure out what error in parsing
    // status code 200 is implicit.

    // The json helper will automatically set the res.content_type = httpz.ContentType.JSON;
    // Here we're passing an inferred anonymous structure, but you can pass anytype
    // (so long as it can be serialized using std.json.stringify)

    // dont need to call deinit because res.allocator is arena
    const data = try std.json.parseFromSlice(core.primitives.PostSwapRequest, res.arena, req.body().?, .{});

    // not deallocating response due arena res
    const response = try mint.swap(res.arena, data.value.inputs.value.items, data.value.outputs.value.items, mint.keyset);

    try res.json(.{ .signature = response }, .{});
}

pub fn mintQuoteBolt11(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    // TODO figure out what error in parsing
    // status code 200 is implicit.

    // The json helper will automatically set the res.content_type = httpz.ContentType.JSON;
    // Here we're passing an inferred anonymous structure, but you can pass anytype
    // (so long as it can be serialized using std.json.stringify)

    const key = zul.UUID.v4();

    // dont need to call deinit because res.allocator is arena
    const data = try std.json.parseFromSlice(core.primitives.PostMintQuoteBolt11Request, res.arena, req.body().?, .{});

    // not need to deallocate due arena res
    const inv = try mint.createInvoice(res.arena, &key.bin, data.value.amount);

    const quote = core.primitives.Bolt11MintQuote{
        .quote_id = key,
        .payment_request = inv.payment_request,
        // plus 30 minutes
        .expiry = @as(u64, @intCast(std.time.timestamp())) + 30 * 60,
        .paid = false,
    };

    var tx = try mint.db.beginTx(res.arena);
    try mint.db.addBolt11MintQuote(res.arena, tx, quote);
    try tx.commit();

    try res.json(&quote, .{});
}

pub fn mintBolt11(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    // The json helper will automatically set the res.content_type = httpz.ContentType.JSON;
    // Here we're passing an inferred anonymous structure, but you can pass anytype
    // (so long as it can be serialized using std.json.stringify)

    // dont need to call deinit because res.allocator is arena
    const data = try std.json.parseFromSlice(core.primitives.PostMintBolt11Request, res.arena, req.body().?, .{});

    var tx = try mint.db.beginTx(res.arena);

    // we dont need to deallocate due arena allocator
    const signatures = try mint.mintBolt11Tokens(res.arena, tx, data.value.quote, data.value.outputs.value.items, mint.keyset);

    // no need deallocate
    // check zul.uuid parse quote id
    var old_quote = try mint.db.getBolt11MintQuote(res.arena, tx, try zul.UUID.parse(data.value.quote));

    old_quote.paid = true;

    try mint.db.updateBolt11MintQuote(res.arena, tx, old_quote);

    try tx.commit();

    try res.json(core.primitives.PostMintBolt11Response{
        .signatures = signatures,
    }, .{});
}

pub fn getMintQuoteBolt11(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    const quote_id = req.param("quote_id").?;

    std.log.debug("get_quote: {any}", .{quote_id});

    var tx = try mint.db.beginTx(res.arena);

    var quote = try mint.db.getBolt11MintQuote(res.arena, tx, try zul.UUID.parse(quote_id));

    try tx.commit();

    quote.paid = try mint.lightning.isInvoicePaid(res.arena, quote.payment_request);

    try res.json(&quote, .{});
}

pub fn meltQuoteBolt11(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {

    // dont need to call deinit because res.allocator is arena
    const request = try std.json.parseFromSlice(core.primitives.PostMeltQuoteBolt11Request, res.arena, req.body().?, .{});

    const invoice = try mint.lightning.decodeInvoice(res.arena, request.value.request);

    const amount = invoice.amountMilliSatoshis() orelse return error.InvalidInvoiceAmount;

    const fee_reserve = try mint.feeReserve(amount) / 1000;

    std.log.debug("fee reserve : {any}", .{fee_reserve});

    const amount_sat = amount / 1000;

    const key = zul.UUID.v4();
    const quote = core.primitives.Bolt11MeltQuote{
        .quote_id = key,
        .amount = amount_sat,
        .fee_reserve = fee_reserve,
        .expiry = @as(u64, @intCast(std.time.timestamp())) + 30 * 60,
        .payment_request = request.value.request,
        .paid = false,
    };

    var tx = try mint.db.beginTx(res.arena);

    try mint.db.addBolt11MeltQuote(res.arena, tx, quote);

    try tx.commit();

    try res.json(&quote, .{});
}

pub fn getMeltQuoteBolt11(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    const quote_id = req.param("quote_id").?;

    std.log.debug("get_quote: {any}", .{quote_id});

    var tx = try mint.db.beginTx(res.arena);

    var quote = try mint.db.getBolt11MeltQuote(res.arena, tx, try zul.UUID.parse(quote_id));

    try tx.commit();

    quote.paid = try mint.lightning.isInvoicePaid(res.arena, quote.payment_request);

    try res.json(&quote, .{});
}

pub fn meltBolt11(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    // dont need to call deinit because res.allocator is arena
    const data = try std.json.parseFromSlice(core.primitives.PostMeltBolt11Request, res.arena, req.body().?, .{});

    var tx = try mint.db.beginTx(res.arena);

    // we dont need to deallocate due arena allocator
    const signatures = try mint.mintBolt11Tokens(res.arena, tx, data.value.quote, data.value.outputs.value.items, mint.keyset);

    // no need deallocate
    // check zul.uuid parse quote id
    var old_quote = try mint.db.getBolt11MintQuote(res.arena, tx, try zul.UUID.parse(data.value.quote));

    old_quote.paid = true;

    try mint.db.updateBolt11MintQuote(res.arena, tx, old_quote);

    try tx.commit();

    try res.json(core.primitives.PostMintBolt11Response{
        .signatures = signatures,
    }, .{});
}

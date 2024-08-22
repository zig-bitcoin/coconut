const std = @import("std");
const mint_lib = @import("mint.zig");
const httpz = @import("httpz");
const routes = @import("routes/lib.zig");

pub fn runServer(
    allocator: std.mem.Allocator,
    mint: *const mint_lib.Mint,
) !void {
    std.log.debug("start running server {any}", .{
        mint,
    });

    var server = try httpz.ServerApp(*const mint_lib.Mint).init(allocator, .{
        .port = mint.config.server.port,
        .address = mint.config.server.host,
    }, mint);

    // overwrite the default notFound handler
    // server.notFound(notFound);

    // overwrite the default error handler
    server.errorHandler(errorHandler);

    var router = server.router();

    router.get("/v1/keys", routes.default.getKeys);
    router.get("/v1/keys/:id", routes.default.getKeysById);
    router.get("/v1/keysets", routes.default.getKeysets);
    router.post("/v1/swap", routes.default.swap);
    router.post("/v1/mint/quote/bolt11", routes.default.mintQuoteBolt11);
    router.post("/v1/mint/bolt11", routes.default.mintBolt11);
    router.get("/v1/mint/quote/bolt11/:quote_id", routes.default.getMintQuoteBolt11);

    return server.listen();
}

// note that the error handler return `void` and not `!void`
fn errorHandler(_: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
    res.status = 500;
    res.body = @errorName(err);

    std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{ req.url.raw, err });
}

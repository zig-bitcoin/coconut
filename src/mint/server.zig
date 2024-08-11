const std = @import("std");
const mint_lib = @import("mint.zig");
const httpz = @import("httpz");

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
    // server.errorHandler(errorHandler);

    var router = server.router();

    router.get("/v1/keys", getKeys);

    return server.listen();
}

fn getKeys(mint: *const mint_lib.Mint, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req; // autofix
    _ = mint; // autofix
    // status code 200 is implicit.

    // The json helper will automatically set the res.content_type = httpz.ContentType.JSON;
    // Here we're passing an inferred anonymous structure, but you can pass anytype
    // (so long as it can be serialized using std.json.stringify)

    std.log.debug("salam get keys", .{});

    try res.json(.{ .name = "Teg" }, .{});
}

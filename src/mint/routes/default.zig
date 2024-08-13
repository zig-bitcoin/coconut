const std = @import("std");
const httpz = @import("httpz");
const mint_lib = @import("../mint.zig");
const core = @import("../../core/lib.zig");

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

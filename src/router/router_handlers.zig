const std = @import("std");
const httpz = @import("httpz");
const core = @import("../core/lib.zig");

const MintState = @import("router.zig").MintState;

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

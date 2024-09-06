const std = @import("std");
const httpz = @import("httpz");

const MintState = @import("router.zig").MintState;

pub fn getKeys(state: MintState, req: *httpz.Request, res: *httpz.Response) !void {
    const pubkeys = try state.mint.pubkeys(req.arena);

    return try res.json(pubkeys, .{});
}

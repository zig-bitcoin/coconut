const std = @import("std");
const mint = @import("mint/lib.zig");
const core = @import("core/lib.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // read mint conifg from env // args
    //
    const cfg = try mint.config.MintConfig.readConfigWithDefaults(allocator);

    var lightning = try mint.lightning.lnbits.LnBitsLightning.init(allocator, "LNBITS_ADMIN_KEY", "http://localhost:5000");
    defer lightning.deinit();

    var m = try mint.Mint.init(
        allocator,
        cfg,
        lightning.lightning(),
    );
    defer m.deinit();

    try mint.server.runServer(allocator, &m);
}

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

    var m = try mint.Mint.init(allocator, cfg);
    defer m.deinit();

    try mint.server.runServer(allocator, &m);
}

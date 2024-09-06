const std = @import("std");
const httpz = @import("httpz");
const router = @import("router/router.zig");
const bitcoin = @import("bitcoin");
const bip39 = bitcoin.bitcoin.bip39;
const core = @import("core/lib.zig");

const Mint = core.mint.Mint;

pub fn main() void {
    const settings_info_mnemonic = "";
    _ = settings_info_mnemonic; // autofix
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    // const mnemonic = try bip39.Mnemonic.parseInNormalized(.english, settings_info_mnemonic);

    // mnemonic.toSeedNormalized("");

    // router.createMintServer(gpa.allocator(), bip39., , , )
}

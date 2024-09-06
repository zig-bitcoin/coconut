const std = @import("std");
const httpz = @import("httpz");
const router = @import("router/router.zig");
const bitcoin = @import("bitcoin");
const bip39 = bitcoin.bitcoin.bip39;
const core = @import("core/lib.zig");
const os = std.os;
const builtin = @import("builtin");

const MintState = @import("router/router.zig").MintState;
const Mint = core.mint.Mint;
const MintDatabase = core.mint_memory.MintMemoryDatabase;

pub fn main() !void {
    const settings_info_mnemonic = "few oppose awkward uncover next patrol goose spike depth zebra brick cactus";

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer {
        std.log.info("salam", .{});
        std.debug.assert(gpa.deinit() == .ok);
    }

    const mnemonic = try bip39.Mnemonic.parseInNormalized(.english, settings_info_mnemonic);

    var supported_units = std.AutoHashMap(core.nuts.CurrencyUnit, std.meta.Tuple(&.{ u64, u8 })).init(gpa.allocator());
    defer supported_units.deinit();

    var db = try MintDatabase.init(gpa.allocator());
    defer db.deinit();

    var mint = try Mint.init(gpa.allocator(), "MintUrl", &try mnemonic.toSeedNormalized(&.{}), .{
        .name = "dfdf",
        .pubkey = null,
        .version = null,
        .description = "dfdf",
        .description_long = null,
        .contact = null,
        .nuts = .{},
        .mint_icon_url = null,
        .motd = null,
    }, &db.value, supported_units);

    var srv = try router.createMintServer(gpa.allocator(), "MintUrl", &mint, 15, .{
        .port = 5500,
        .address = "0.0.0.0",
    });

    std.log.info("Listening server", .{});
    try srv.listen();

    std.log.info("Stopped server", .{});
    // router.createMintServer(gpa.allocator(), bip39., , , )
}

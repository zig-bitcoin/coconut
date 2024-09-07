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
        // check on leak in debug
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
    defer srv.deinit();

    try handleInterrupt(&srv);
    std.log.info("Listening server", .{});
    try srv.listen();

    std.log.info("Stopped server", .{});
    // router.createMintServer(gpa.allocator(), bip39., , , )
}

pub fn handleInterrupt(srv: *httpz.Server(MintState)) !void {
    const signal = struct {
        var _srv: *httpz.Server(MintState) = undefined;

        fn handler(sig: c_int) callconv(.C) void {
            std.debug.assert(sig == std.posix.SIG.INT);
            _srv.stop();
        }
    };

    signal._srv = srv;

    // call our shutdown function (below) when
    // SIGINT or SIGTERM are received
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = signal.handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = signal.handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
}

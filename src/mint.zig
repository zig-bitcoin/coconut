const std = @import("std");
const httpz = @import("httpz");
const router = @import("router/router.zig");
const bitcoin_primitives = @import("bitcoin-primitives");
const bip39 = bitcoin_primitives.bips.bip39;
const core = @import("core/lib.zig");
const os = std.os;
const builtin = @import("builtin");

const MintState = @import("router/router.zig").MintState;
const LnKey = @import("router/router.zig").LnKey;
const FakeWallet = @import("fake_wallet/fake_wallet.zig").FakeWallet;
const Mint = core.mint.Mint;
const MintDatabase = core.mint_memory.MintMemoryDatabase;

/// The default log level is based on build mode.
pub const default_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .notice,
    .ReleaseFast => .err,
    .ReleaseSmall => .err,
};

pub fn main() !void {
    const settings_info_mnemonic = "few oppose awkward uncover next patrol goose spike depth zebra brick cactus";

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 20,
    }).init;
    defer {
        // check on leak in debug
        std.debug.assert(gpa.deinit() == .ok);
    }

    const mnemonic = try bip39.Mnemonic.parseInNormalized(.english, settings_info_mnemonic);

    var supported_units = std.AutoHashMap(core.nuts.CurrencyUnit, std.meta.Tuple(&.{ u64, u8 })).init(gpa.allocator());
    defer supported_units.deinit();

    var ln_backends = router.LnBackendsMap.init(gpa.allocator());
    defer {
        var it = ln_backends.valueIterator();
        while (it.next()) |v| {
            v.deinit();
        }
        ln_backends.deinit();
    }

    // TODO ln_routers?
    // init ln backend
    {
        const units: []const core.nuts.CurrencyUnit = &.{.sat};

        for (units) |unit| {
            const ln_key = LnKey.init(unit, .bolt11);

            const wallet = try FakeWallet.init(
                gpa.allocator(),
                .{
                    .min_fee_reserve = 1,
                    .percent_fee_reserve = 1.0,
                },
                .{},
                .{},
            );

            try ln_backends.put(ln_key, wallet);

            try supported_units.put(unit, .{ 0, 64 });
        }
    }

    var db = try MintDatabase.initManaged(gpa.allocator());
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
    defer mint.deinit();

    var srv = try router.createMintServer(gpa.allocator(), "MintUrl", &mint, ln_backends, 15, .{
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

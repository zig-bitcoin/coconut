const std = @import("std");
const httpz = @import("httpz");
const router = @import("router/router.zig");
const bitcoin_primitives = @import("bitcoin-primitives");
const bip39 = bitcoin_primitives.bips.bip39;
const core = @import("core/lib.zig");
const os = std.os;
const builtin = @import("builtin");
const config = @import("mintd/config.zig");
const clap = @import("clap");

const MintState = @import("router/router.zig").MintState;
const LnKey = @import("router/router.zig").LnKey;
const FakeWallet = @import("fake_wallet/fake_wallet.zig").FakeWallet;
const Mint = core.mint.Mint;
const FeeReserve = core.mint.FeeReserve;
const MintDatabase = core.mint_memory.MintMemoryDatabase;
const ContactInfo = core.nuts.ContactInfo;
const MintVersion = core.nuts.MintVersion;
const MintInfo = core.nuts.MintInfo;
const Channel = @import("channels/channels.zig").Channel;

const default_quote_ttl_secs: u64 = 1800;

/// Update mint quote when called for a paid invoice
fn handlePaidInvoice(mint: *Mint, request_lookup_id: []const u8) !void {
    std.log.debug("Invoice with lookup id paid: {s}", .{request_lookup_id});

    try mint.payMintQuoteForRequestId(request_lookup_id);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 20,
    }).init;
    defer {
        // check on leak in debug
        std.debug.assert(gpa.deinit() == .ok);
    }

    // parsing CLI

    var clap_res = v: {
        // First we specify what parameters our program can take.
        // We can use `parseParamsComptime` to parse a string into an array of `Param(Help)`
        const params = comptime clap.parseParamsComptime(
            \\-h, --help             Display this help and exit.
            \\-c, --config <str>     Use the <file name> as the location of the config file.
            \\
        );

        // Initialize our diagnostics, which can be used for reporting useful errors.
        // This is optional. You can also pass `.{}` to `clap.parse` if you don't
        // care about the extra information `Diagnostics` provides.
        var diag = clap.Diagnostic{};
        var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
            .diagnostic = &diag,
            .allocator = gpa.allocator(),
        }) catch |err| {
            // Report useful error and exit
            diag.report(std.io.getStdErr().writer(), err) catch {};
            return err;
        };
        errdefer res.deinit();

        // helper to print help
        if (res.args.help != 0)
            return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

        break :v res;
    };
    defer clap_res.deinit();

    const config_path = clap_res.args.config orelse "config.toml";

    var parsed_settings = try config.Settings.initFromToml(gpa.allocator(), config_path);
    defer parsed_settings.deinit();

    var localstore = switch (parsed_settings.value.database.engine) {
        .in_memory => v: {
            break :v try MintDatabase.initFrom(
                gpa.allocator(),
                .init(gpa.allocator()),
                &.{},
                &.{},
                &.{},
                &.{},
                &.{},
                .init(gpa.allocator()),
            );
        },
        else => {
            // not implemented engine
            unreachable;
        },
    };
    defer localstore.deinit();

    var contact_info = std.ArrayList(ContactInfo).init(gpa.allocator());
    defer contact_info.deinit();

    if (parsed_settings.value.mint_info.contact_nostr_public_key) |nostr_contact| {
        try contact_info.append(.{
            .method = "nostr",
            .info = nostr_contact,
        });
    }

    if (parsed_settings.value.mint_info.contact_email) |email_contact| {
        try contact_info.append(.{
            .method = "email",
            .info = email_contact,
        });
    }

    const mint_version = MintVersion{
        .name = "mint-server",
        .version = "1.0.0", // TODO version
    };

    const relative_ln_fee = parsed_settings.value.ln.fee_percent;

    const absolute_ln_fee_reserve = parsed_settings.value.ln.reserve_fee_min;

    const fee_reserve = FeeReserve{
        .min_fee_reserve = absolute_ln_fee_reserve,
        .percent_fee_reserve = relative_ln_fee,
    };

    const input_fee_ppk = parsed_settings.value.info.input_fee_ppk orelse 0;

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

    // TODO set ln router
    // additional routers for httpz server
    switch (parsed_settings.value.ln.ln_backend) {
        .fake_wallet => {
            const units = (parsed_settings.value.fake_wallet orelse config.FakeWallet{}).supported_units;

            for (units) |unit| {
                const ln_key = LnKey.init(unit, .bolt11);

                var wallet = try FakeWallet.init(gpa.allocator(), fee_reserve, .{}, .{});
                errdefer wallet.deinit();

                try ln_backends.put(ln_key, wallet);

                try supported_units.put(unit, .{ input_fee_ppk, 64 });
            }
        },
        else => {
            // not implemented backends
            unreachable;
        },
    }

    var nuts = core.nuts.Nuts{};
    // TODO nuts settings
    {
        var nut04 = try std.ArrayList(core.nuts.nut04.MintMethodSettings).initCapacity(gpa.allocator(), ln_backends.count());
        errdefer nut04.deinit();
        var nut05 = try std.ArrayList(core.nuts.nut05.MeltMethodSettings).initCapacity(gpa.allocator(), ln_backends.count());
        errdefer nut05.deinit();

        var mpp = try std.ArrayList(core.nuts.nut15.MppMethodSettings).initCapacity(gpa.allocator(), ln_backends.count());
        errdefer mpp.deinit();

        var it = ln_backends.iterator();

        while (it.next()) |ln_entry| {
            const settings = ln_entry.value_ptr.getSettings();

            const m = core.nuts.nut15.MppMethodSettings{
                .method = ln_entry.key_ptr.method,
                .unit = ln_entry.key_ptr.unit,
                .mpp = settings.mpp,
            };

            const n4 = core.nuts.nut04.MintMethodSettings{
                .method = ln_entry.key_ptr.method,
                .unit = ln_entry.key_ptr.unit,
                .min_amount = settings.mint_settings.min_amount,
                .max_amount = settings.mint_settings.max_amount,
            };
            const n5 = core.nuts.nut05.MeltMethodSettings{
                .method = ln_entry.key_ptr.method,
                .unit = ln_entry.key_ptr.unit,
                .min_amount = settings.melt_settings.min_amount,
                .max_amount = settings.melt_settings.max_amount,
            };

            nut04.appendAssumeCapacity(n4);
            nut05.appendAssumeCapacity(n5);
            mpp.appendAssumeCapacity(m);
        }

        nuts.nut04.methods = try nut04.toOwnedSlice();
        nuts.nut05.methods = try nut05.toOwnedSlice();
        nuts.nut15.methods = try mpp.toOwnedSlice();

        nuts.nut07.supported = true;
        nuts.nut08.supported = true;
        nuts.nut09.supported = true;
        nuts.nut10.supported = true;
        nuts.nut11.supported = true;
        nuts.nut12.supported = true;
        nuts.nut14.supported = true;
    }

    const mint_info = MintInfo{
        .name = parsed_settings.value.mint_info.name,
        .version = mint_version,
        .description = parsed_settings.value.mint_info.description,
        .description_long = parsed_settings.value.mint_info.description_long,
        .contact = contact_info.items,
        .pubkey = parsed_settings.value.mint_info.pubkey,
        .mint_icon_url = parsed_settings.value.mint_info.mint_icon_url,
        .motd = parsed_settings.value.mint_info.motd,
        .nuts = nuts,
    };

    const mnemonic = try bip39.Mnemonic.parseInNormalized(.english, parsed_settings.value.info.mnemonic);

    var mint = try Mint.init(gpa.allocator(), parsed_settings.value.info.url, &try mnemonic.toSeedNormalized(&.{}), mint_info, &localstore, supported_units);
    defer mint.deinit();

    // Check the status of any mint quotes that are pending
    // In the event that the mint server is down but the ln node is not
    // it is possible that a mint quote was paid but the mint has not been updated
    // this will check and update the mint state of those quotes
    // for ln in ln_backends.values() {
    //     check_pending_quotes(Arc::clone(&mint), Arc::clone(ln)).await?;
    // }
    // TODO

    const mint_url = parsed_settings.value.info.url;
    const listen_addr = parsed_settings.value.info.listen_host;
    const listen_port = parsed_settings.value.info.listen_port;
    const quote_ttl = parsed_settings.value
        .info
        .seconds_quote_is_valid_for orelse default_quote_ttl_secs;

    // start serevr
    var srv = try router.createMintServer(gpa.allocator(), mint_url, &mint, ln_backends, quote_ttl, .{
        .port = listen_port,
        .address = listen_addr,
    }, &.{
        .{
            httpz.middleware.Cors, .{
                .origin = "*",
                .headers = "*",
            },
        },
    });
    defer srv.deinit();

    // add lnn router here to server
    try handleInterrupt(&srv);

    // Spawn task to wait for invoces to be paid and update mint quotes
    // handle invoices
    const threads = v: {
        var threads = try std.ArrayList(std.Thread).initCapacity(gpa.allocator(), ln_backends.count());
        errdefer threads.deinit();
        errdefer for (threads.items) |t| t.detach();

        const thread_fn = (struct {
            fn handleLnInvoice(m: *Mint, wait_ch: Channel(std.ArrayList(u8)).Rx) void {
                while (true) {
                    var request_lookup_id = wait_ch.recv();
                    defer request_lookup_id.deinit();

                    handlePaidInvoice(m, request_lookup_id.items) catch |err| {
                        std.log.warn("handle paid invoice error, lookup_id {s}, err={s}", .{ request_lookup_id.items, @errorName(err) });
                        continue;
                    };
                }
            }
        }).handleLnInvoice;

        var it = ln_backends.iterator();
        while (it.next()) |ln_entry| {
            threads.appendAssumeCapacity(try std.Thread.spawn(.{}, thread_fn, .{
                &mint, try ln_entry.value_ptr.waitAnyInvoice(),
            }));
        }
        break :v threads;
    };
    defer threads.deinit();
    defer for (threads.items) |t| t.detach();

    std.log.info("Listening server on {s}:{d}", .{
        parsed_settings.value.info.listen_host, parsed_settings.value.info.listen_port,
    });
    try srv.listen();

    std.log.info("Stopped server", .{});
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

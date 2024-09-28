// Router creating routes for http server
const core = @import("../core/lib.zig");
const httpz = @import("httpz");
const std = @import("std");
const router_handlers = @import("router_handlers.zig");
const zul = @import("zul");
const fake_wallet = @import("../fake_wallet/fake_wallet.zig");
const http_router = @import("../misc/http_router/http_router.zig");

const MintLightning = core.lightning.MintLightning;
const Mint = core.mint.Mint;
const CurrencyUnit = core.nuts.CurrencyUnit;
const PaymentMethod = core.nuts.PaymentMethod;

pub const LnBackendsMap = std.HashMap(LnKey, MintLightning, LnKeyContext, 80);

/// Create mint [`Server`] with required endpoints for cashu mint
/// Caller responsible for free resources
pub fn createMintServer(
    allocator: std.mem.Allocator,
    mint_url: []const u8,
    mint: *Mint,
    ln: LnBackendsMap,
    quote_ttl: u64,
) !http_router.Router {
    // TODO do we need copy
    const state = MintState{
        .mint = mint,
        .mint_url = mint_url,
        .quote_ttl = quote_ttl,
        .ln = ln,
    };

    var router = try httpz.Router(MintState, httpz.Action(MintState)).init(allocator, MintState.dispatcher, state);

    router.get("/v1/keys", router_handlers.getKeys, .{});
    router.get("/v1/keysets", router_handlers.getKeysets, .{});
    router.get("/v1/keys/:keyset_id", router_handlers.getKeysetPubkeys, .{});
    router.get("/v1/mint/quote/bolt11/:quote_id", router_handlers.getCheckMintBolt11Quote, .{});
    router.get("/v1/melt/quote/bolt11/:quote_id", router_handlers.getCheckMeltBolt11Quote, .{});
    router.post("/v1/checkstate", router_handlers.postCheck, .{});
    router.get("/v1/info", router_handlers.getMintInfo, .{});

    router.post("/v1/mint/quote/bolt11", router_handlers.getMintBolt11Quote, .{});
    router.post("/v1/melt/quote/bolt11", router_handlers.getMeltBolt11Quote, .{});
    router.post("/v1/mint/bolt11", router_handlers.postMintBolt11, .{});
    router.post("/v1/melt/bolt11", router_handlers.postMeltBolt11, .{});
    router.post("/v1/swap", router_handlers.postSwap, .{});

    const _router = try http_router.Router.initFrom(MintState, allocator, router);

    return _router;
}

pub const LnKeyContext = struct {
    pub fn hash(_: @This(), s: LnKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&.{ @intFromEnum(s.unit), @intFromEnum(s.method) });
        switch (s.method) {
            .custom => |c| {
                hasher.update(c);
            },
            else => {},
        }

        return hasher.final();
    }

    pub fn eql(_: @This(), a: LnKey, b: LnKey) bool {
        return std.meta.eql(a, b);
    }
};

pub const MintState = struct {
    ln: LnBackendsMap,
    mint: *Mint,
    mint_url: []const u8,
    quote_ttl: u64,

    pub usingnamespace http_router.DefaultDispatcher(@This());

    pub fn uncaughtError(self: *const MintState, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        _ = self; // autofix
        std.log.info("500 {} {s} {}", .{ req.method, req.url.path, err });
        res.status = 500;
        res.body = "sorry";
    }
};

/// Key used in hashmap of ln backends to identify what unit and payment method it is for
pub const LnKey = struct {
    /// Unit of Payment backend
    unit: CurrencyUnit,
    /// Method of payment backend
    method: PaymentMethod,

    pub fn init(unit: CurrencyUnit, method: PaymentMethod) LnKey {
        return .{
            .unit = unit,
            .method = method,
        };
    }
};

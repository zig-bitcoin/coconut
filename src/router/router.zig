// Router creating routes for http server
const core = @import("../core/lib.zig");
const httpz = @import("httpz");
const std = @import("std");

const Mint = core.mint.Mint;
const CurrencyUnit = core.nuts.CurrencyUnit;
const PaymentMethod = core.nuts.PaymentMethod;

/// Create mint [`Server`] with required endpoints for cashu mint
/// Caller responsible for free resources
pub fn createMintServer(
    allocator: std.mem.Allocator,
    mint_url: []const u8,
    mint: *Mint,
    // ln: HashMap<LnKey, Arc<dyn MintLightning<Err = cdk_lightning::Error> + Send + Sync>>,
    quote_ttl: u64,
    server_options: httpz.Config,
) !httpz.ServerApp(MintState) {
    // TODO do we need copy
    const state = MintState{
        .mint = mint,
        .mint_url = mint_url,
        .quote_ttl = quote_ttl,
    };

    var srv = try httpz.ServerApp(MintState).init(allocator, server_options, state);
    errdefer srv.deinit();

    // apply routes

    return srv;
}

pub const MintState = struct {
    // ln: HashMap<LnKey, Arc<dyn MintLightning<Err = cdk_lightning::Error> + Send + Sync>>,
    mint: *Mint,
    mint_url: []const u8,
    quote_ttl: u64,
};

/// Key used in hashmap of ln backends to identify what unit and payment method it is for
pub const LnKey = struct {
    /// Unit of Payment backend
    unit: CurrencyUnit,
    /// Method of payment backend
    method: PaymentMethod,
};

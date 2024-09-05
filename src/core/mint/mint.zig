const std = @import("std");
const core = @import("../lib.zig");
const MintInfo = core.nuts.MintInfo;
const secp256k1 = @import("secp256k1");
const bip32 = @import("bitcoin").bitcoin.bip32;
pub const MintQuote = @import("types.zig").MintQuote;
pub const MeltQuote = @import("types.zig").MeltQuote;

/// Mint Fee Reserve
pub const FeeReserve = struct {
    /// Absolute expected min fee
    min_fee_reserve: core.amount.Amount,
    /// Percentage expected fee
    percent_fee_reserve: f32,
};

/// Mint Keyset Info
pub const MintKeySetInfo = struct {
    /// Keyset [`Id`]
    id: core.nuts.Id,
    /// Keyset [`CurrencyUnit`]
    unit: core.nuts.CurrencyUnit,
    /// Keyset active or inactive
    /// Mint will only issue new [`BlindSignature`] on active keysets
    active: bool,
    /// Starting unix time Keyset is valid from
    valid_from: u64,
    /// When the Keyset is valid to
    /// This is not shown to the wallet and can only be used internally
    valid_to: ?u64,
    /// [`DerivationPath`] keyset
    derivation_path: []const bip32.ChildNumber,
    /// DerivationPath index of Keyset
    derivation_path_index: ?u32,
    /// Max order of keyset
    max_order: u8,
    /// Input Fee ppk
    input_fee_ppk: u64 = 0,

    pub fn deinit(self: *const MintKeySetInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.derivation_path);
    }

    pub fn clone(self: *const MintKeySetInfo, allocator: std.mem.Allocator) !MintKeySetInfo {
        var cloned = self.*;

        const derivation_path = try allocator.alloc(bip32.ChildNumber, self.derivation_path.len);
        errdefer allocator.free(derivation_path);

        @memcpy(derivation_path, self.derivation_path);
        cloned.derivation_path = derivation_path;

        return cloned;
    }
};

/// Cashu Mint
pub const Mint = struct {
    /// Mint Url
    mint_url: std.Uri,
    /// Mint Info
    mint_info: MintInfo,
    /// Mint Storage backend
    // pub localstore: Arc<dyn MintDatabase<Err = cdk_database::Error> + Send + Sync>,
    /// Active Mint Keysets
    // keysets: Arc<RwLock<HashMap<Id, MintKeySet>>>,
    secp_ctx: secp256k1.Secp256k1,
    xpriv: bip32.ExtendedPrivKey,
};

const std = @import("std");
const core = @import("../core/lib.zig");
const MintInfo = core.nuts.MintInfo;
const secp256k1 = core.secp256k1;
const bip32 = core.bip32;

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

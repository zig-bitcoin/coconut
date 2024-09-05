//! Fake LN Backend
//!
//! Used for testing where quotes are auto filled
const core = @import("../core/lib.zig");
// const lightning = @import("../core/mint/lightning/lib.zig").

/// Fake Wallet
pub const FakeWallet = struct {
    fee_reserve: core.mint.FeeReserve,
    // sender: tokio::sync::mpsc::Sender<String>,
    // receiver: Arc<Mutex<Option<tokio::sync::mpsc::Receiver<String>>>>,
    // mint_settings: MintMeltSettings,
    // melt_settings: MintMeltSettings,
};

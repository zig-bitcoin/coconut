//! NUT-03: Swap
//!
//! <https://github.com/cashubtc/nuts/blob/main/03.md>

const BlindSignature = @import("../nut00/lib.zig").BlindSignature;
const BlindedMessage = @import("../nut00/lib.zig").BlindedMessage;
// const PreMintSecrets = @import("../nut00/lib.zig").PreMintSecrets;
const Proof = @import("../nut00/lib.zig").Proof;

// /// Preswap information
// pub const PreSwap = struct {
//     /// Preswap mint secrets
//     pre_mint_secrets: PreMintSecrets,
//     /// Swap request
//     swap_request: SwapRequest,
//     /// Amount to increment keyset counter by
//     derived_secret_count: u32,
//     /// Fee amount
//     fee: u64,
// };

/// Split Request [NUT-06]
pub const SwapRequest = struct {
    /// Proofs that are to be spent in `Split`
    inputs: []const Proof,
    /// Blinded Messages for Mint to sign
    outputs: []const BlindedMessage,

    /// Total value of proofs in [`SwapRequest`]
    pub fn inputAmount(self: SwapRequest) u64 {
        var sum: u64 = 0;
        for (self.inputs) |proof| sum += proof.amount;

        return sum;
    }

    /// Total value of outputs in [`SwapRequest`]
    pub fn outputAmount(self: SwapRequest) u64 {
        var sum: u64 = 0;
        for (self.outputs) |proof| sum += proof.amount;

        return sum;
    }
};

/// Split Response [NUT-06]
pub const SwapResponse = struct {
    /// Promises
    signatures: []const BlindSignature,

    /// Total [`Amount`] of promises
    pub fn promisesAmount(self: SwapResponse) u64 {
        var sum: u64 = 0;

        for (self.signatures) |bs| sum += bs.amount;

        return sum;
    }
};

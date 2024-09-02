//! Cashu Token
//!
//! <https://github.com/cashubtc/nuts/blob/main/00.md>
const std = @import("std");
const CurrencyUnit = @import("lib.zig").CurrencyUnit;
const Proof = @import("lib.zig").Proof;
const helper = @import("../../../helper/helper.zig");
const Id = @import("../nut02/nut02.zig").Id;

/// Token
pub const TokenV3 = struct {
    /// Proofs in [`Token`] by mint
    token: []const TokenV3Token,
    /// Memo for token
    memo: ?[]const u8,
    /// Token Unit
    unit: ?CurrencyUnit,
};

/// Token V3 Token
pub const TokenV3Token = struct {
    /// Url of mint
    mint: []const u8,
    /// [`Proofs`]
    proofs: []const Proof,
};

/// Token V4
pub const TokenV4 = struct {
    /// Mint Url
    // #[serde(rename = "m")]
    mint_url: []const u8,
    /// Token Unit
    // #[serde(rename = "u", skip_serializing_if = "Option::is_none")]
    unit: ?CurrencyUnit,
    /// Memo for token
    // #[serde(rename = "d", skip_serializing_if = "Option::is_none")]
    memo: ?[]const u8,
    /// Proofs
    ///
    /// Proofs separated by keyset_id
    // #[serde(rename = "t")]
    token: []const TokenV4Token,
};

/// Token V4 Token
pub const TokenV4Token = struct {
    /// `Keyset id`
    // #[serde(
    //     rename = "i",
    //     serialize_with = "serialize_v4_keyset_id",
    //     deserialize_with = "deserialize_v4_keyset_id"
    // )]
    keyset_id: Id,
    /// Proofs
    // #[serde(rename = "p")]
    proofs: []const ProofV4,
};

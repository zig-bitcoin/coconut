//! NUT-04: Mint Tokens via Bolt11
//!
//! <https://github.com/cashubtc/nuts/blob/main/04.md>
const std = @import("std");
const CurrencyUnit = @import("../nut00/nut00.zig").CurrencyUnit;
const Proof = @import("../nut00/nut00.zig").Proof;
const PaymentMethod = @import("../nut00/nut00.zig").PaymentMethod;

pub const QuoteState = enum {
    /// Quote has not been paid
    unpaid,
    /// Quote has been paid and wallet can mint
    paid,
    /// Minting is in progress
    /// **Note:** This state is to be used internally but is not part of the nut.
    pending,
    /// ecash issued for quote
    issued,
};

pub const MintMethodSettings = struct {
    /// Payment Method e.g. bolt11
    method: PaymentMethod,
    /// Currency Unit e.g. sat
    unit: CurrencyUnit = .sat,
    /// Min Amount
    min_amount: ?u64 = null,
    /// Max Amount
    max_amount: ?u64 = null,
};

/// Mint Settings
pub const Settings = struct {
    /// Methods to mint
    methods: []const MintMethodSettings = &.{},
    /// Minting disabled
    disabled: bool = false,
};

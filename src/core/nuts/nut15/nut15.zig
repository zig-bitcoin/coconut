//! NUT-15: Multipart payments
//!
//! <https://github.com/cashubtc/nuts/blob/main/15.md>

const CurrencyUnit = @import("../nut00/lib.zig").CurrencyUnit;
const PaymentMethod = @import("../nut00/lib.zig").PaymentMethod;

const std = @import("std");

/// Multi-part payment
pub const Mpp = struct {
    /// Amount
    amount: u64,
};

/// Mpp Method Settings
pub const MppMethodSettings = struct {
    /// Payment Method e.g. bolt11
    method: PaymentMethod = .bolt11,
    /// Currency Unit e.g. sat
    unit: CurrencyUnit = .sat,
    /// Multi part payment support
    mpp: bool = false,
};

/// Mpp Settings
pub const Settings = struct {
    /// Method settings
    methods: []const MppMethodSettings = &.{},
};

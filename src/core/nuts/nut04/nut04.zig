//! NUT-04: Mint Tokens via Bolt11
//!
//! <https://github.com/cashubtc/nuts/blob/main/04.md>
const std = @import("std");
const zul = @import("zul");

const CurrencyUnit = @import("../nut00/nut00.zig").CurrencyUnit;
const BlindedMessage = @import("../nut00/nut00.zig").BlindedMessage;
const BlindSignature = @import("../nut00/nut00.zig").BlindSignature;
const Proof = @import("../nut00/nut00.zig").Proof;
const PaymentMethod = @import("../nut00/nut00.zig").PaymentMethod;
const MintQuote = @import("../../mint/types.zig").MintQuote;
const Amount = @import("../../amount.zig").Amount;

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

    pub fn fromStr(s: []const u8) !QuoteState {
        if (std.mem.eql(u8, "UNPAID", s)) return .unpaid;
        if (std.mem.eql(u8, "PAID", s)) return .paid;
        if (std.mem.eql(u8, "PENDING", s)) return .pending;
        if (std.mem.eql(u8, "ISSUED", s)) return .issued;

        return error.UnknownState;
    }

    pub fn toStr(self: *const QuoteState) []const u8 {
        return switch (self.*) {
            .unpaid => "UNPAID",
            .paid => "PAID",
            .pending => "PENDING",
            .issued => "ISSUED",
        };
    }

    pub fn jsonStringify(self: *const QuoteState, out: anytype) !void {
        try out.write(self.toStr());
    }
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

    /// Get [`MintMethodSettings`] for unit method pair
    pub fn getSettings(
        self: Settings,
        unit: CurrencyUnit,
        method: PaymentMethod,
    ) ?MintMethodSettings {
        for (self.methods) |method_settings| {
            if (std.meta.eql(method_settings.method, method) and std.meta.eql(method_settings.unit, unit)) return method_settings;
        }

        return null;
    }
};

/// Mint quote request [NUT-04]
pub const MintQuoteBolt11Request = struct {
    /// Amount
    amount: Amount,
    /// Unit wallet would like to pay with
    unit: CurrencyUnit,
};

/// Mint quote response [NUT-04]
pub const MintQuoteBolt11Response = struct {
    /// Quote Id
    quote: [36]u8,
    /// Payment request to fulfil
    request: []const u8,
    // TODO: To be deprecated
    /// Whether the the request haas be paid
    /// Deprecated
    paid: ?bool,
    /// Quote State
    state: QuoteState,
    /// Unix timestamp until the quote is valid
    expiry: ?u64,

    pub fn clone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
        // const quote = try allocator.dupe(u8, self.quote);
        // errdefer allocator.free(quote);

        const request = try allocator.dupe(u8, self.request);
        errdefer allocator.free(request);

        var cloned = self.*;
        cloned.request = request;
        // cloned.quote = quote;
        return cloned;
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.request);
        allocator.free(self.request);
    }

    /// Without reallocating slices, so lifetime of result as [`MintQuote`]
    pub fn fromMintQuote(mint_quote: MintQuote) !MintQuoteBolt11Response {
        const paid = mint_quote.state == .paid;
        return .{
            .quote = try zul.UUID.binToHex(&mint_quote.id, .lower),
            .request = mint_quote.request,
            .paid = paid,
            .state = mint_quote.state,
            .expiry = mint_quote.expiry,
        };
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !MintQuoteBolt11Response {
        const value = std.json.innerParse(std.json.Value, allocator, source, .{ .allocate = .alloc_always }) catch return error.UnexpectedToken;

        if (value != .object) return error.UnexpectedToken;

        const quote: []const u8 = try std.json.parseFromValueLeaky(
            []const u8,
            allocator,
            value.object.get("quote") orelse return error.UnexpectedToken,
            options,
        );

        const request: []const u8 = try std.json.parseFromValueLeaky(
            []const u8,
            allocator,
            value.object.get("request") orelse return error.UnexpectedToken,
            options,
        );

        const paid: ?bool = v: {
            break :v try std.json.parseFromValueLeaky(
                bool,
                allocator,
                value.object.get("paid") orelse break :v null,
                options,
            );
        };

        const state: ?[]const u8 = v: {
            break :v try std.json.parseFromValueLeaky(
                []const u8,
                allocator,
                value.object.get("state") orelse break :v null,
                options,
            );
        };
        const expiry: ?u64 = v: {
            break :v try std.json.parseFromValueLeaky(
                []u64,
                allocator,
                value.object.get("expiry") orelse break :v null,
                options,
            );
        };

        const _state: QuoteState = if (state) |s|
            // wrong quote state
            QuoteState.fromStr(s) catch error.UnexpectedToken
        else if (paid) |p|
            if (p) .paid else .unpaid
        else
            return error.UnexpectedError;

        return .{
            .state = _state,
            .expiry = expiry,
            .request = request,
            .quote = quote,
            .paid = paid,
        };
    }
};

/// Mint response [NUT-04]
pub const MintBolt11Response = struct {
    /// Blinded Signatures
    signatures: []const BlindSignature,
};

/// Mint request [NUT-04]
pub const MintBolt11Request = struct {
    /// Quote id
    quote: [36]u8,
    /// Outputs
    outputs: []const BlindedMessage,
};

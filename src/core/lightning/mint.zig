/// MintLightning interface for backend
const Self = @This();

const std = @import("std");
const core = @import("../lib.zig");
const ref = @import("../../sync/ref.zig");
const mpmc = @import("../../sync/mpmc.zig");

const Channel = @import("../../channels/channels.zig").Channel;
const Amount = core.amount.Amount;
const PaymentQuoteResponse = core.lightning.PaymentQuoteResponse;
const CreateInvoiceResponse = core.lightning.CreateInvoiceResponse;
const PayInvoiceResponse = core.lightning.PayInvoiceResponse;
const MeltQuoteBolt11Request = core.nuts.nut05.MeltQuoteBolt11Request;
const Settings = core.lightning.Settings;
const MintMeltSettings = core.lightning.MintMeltSettings;
const FeeReserve = core.mint.FeeReserve;
const MintQuoteState = core.nuts.nut04.QuoteState;

// _type: type,
allocator: std.mem.Allocator,
ptr: *anyopaque,

deinitFn: *const fn (ptr: *anyopaque) void,
getSettingsFn: *const fn (ptr: *anyopaque) Settings,
waitAnyInvoiceFn: *const fn (ptr: *anyopaque) ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))),
getPaymentQuoteFn: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, melt_quote_request: MeltQuoteBolt11Request) anyerror!PaymentQuoteResponse,
payInvoiceFn: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, melt_quote: core.mint.MeltQuote, partial_msats: ?Amount, max_fee_msats: ?Amount) anyerror!PayInvoiceResponse,
checkInvoiceStatusFn: *const fn (ptr: *anyopaque, request_lookup_id: []const u8) anyerror!MintQuoteState,
createInvoiceFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, amount: Amount, unit: core.nuts.CurrencyUnit, description: []const u8, unix_expiry: u64) anyerror!CreateInvoiceResponse,

pub fn initFrom(comptime T: type, allocator: std.mem.Allocator, value: T) !Self {
    const gen = struct {
        pub fn getSettings(pointer: *anyopaque) Settings {
            const self: *T = @ptrCast(@alignCast(pointer));
            return self.getSettings();
        }

        pub fn waitAnyInvoice(pointer: *anyopaque) ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))) {
            const self: *T = @ptrCast(@alignCast(pointer));
            return self.waitAnyInvoice();
        }

        pub fn getPaymentQuote(pointer: *anyopaque, arena: std.mem.Allocator, melt_quote_request: MeltQuoteBolt11Request) anyerror!PaymentQuoteResponse {
            const self: *T = @ptrCast(@alignCast(pointer));
            return self.getPaymentQuote(arena, melt_quote_request);
        }

        pub fn payInvoice(pointer: *anyopaque, arena: std.mem.Allocator, melt_quote: core.mint.MeltQuote, partial_msats: ?Amount, max_fee_msats: ?Amount) !PayInvoiceResponse {
            const self: *T = @ptrCast(@alignCast(pointer));
            return self.payInvoice(arena, melt_quote, partial_msats, max_fee_msats);
        }

        pub fn checkInvoiceStatus(pointer: *anyopaque, request_lookup_id: []const u8) !MintQuoteState {
            const self: *T = @ptrCast(@alignCast(pointer));
            return self.checkInvoiceStatus(request_lookup_id);
        }

        pub fn createInvoice(pointer: *anyopaque, arena: std.mem.Allocator, amount: Amount, unit: core.nuts.CurrencyUnit, description: []const u8, unix_expiry: u64) !CreateInvoiceResponse {
            const self: *T = @ptrCast(@alignCast(pointer));
            return self.createInvoice(arena, amount, unit, description, unix_expiry);
        }

        pub fn deinit(pointer: *anyopaque) void {
            if (std.meta.hasFn(T, "deinit")) {
                const self: *T = @ptrCast(@alignCast(pointer));
                self.deinit();
            }
        }
    };

    const ptr = try allocator.create(T);
    ptr.* = value;

    return .{
        // ._type = T,
        .allocator = allocator,
        .ptr = ptr,
        .getSettingsFn = gen.getSettings,
        .waitAnyInvoiceFn = gen.waitAnyInvoice,
        .getPaymentQuoteFn = gen.getPaymentQuote,
        .payInvoiceFn = gen.payInvoice,
        .checkInvoiceStatusFn = gen.checkInvoiceStatus,
        .createInvoiceFn = gen.createInvoice,
        .deinitFn = gen.deinit,
    };
}

pub fn deinit(self: Self) void {
    self.deinitFn(self.ptr);
    // clearing pointer
    // self.allocator.destroy(@as(self._type, @ptrCast(self.ptr)));
}

pub fn getSettings(self: Self) Settings {
    return self.getSettingsFn(self.ptr);
}

pub fn waitAnyInvoice(self: Self) ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))) {
    return self.waitAnyInvoiceFn(self.ptr);
}

pub fn getPaymentQuote(self: Self, arena: std.mem.Allocator, melt_quote_request: MeltQuoteBolt11Request) !PaymentQuoteResponse {
    return self.getPaymentQuoteFn(self.ptr, arena, melt_quote_request);
}

pub fn payInvoice(self: Self, arena: std.mem.Allocator, melt_quote: core.mint.MeltQuote, partial_msats: ?Amount, max_fee_msats: ?Amount) !PayInvoiceResponse {
    return self.payInvoiceFn(self.ptr, arena, melt_quote, partial_msats, max_fee_msats);
}

pub fn checkInvoiceStatus(self: Self, request_lookup_id: []const u8) !MintQuoteState {
    return self.checkInvoiceStatusFn(self.ptr, request_lookup_id);
}

pub fn createInvoice(self: Self, arena: std.mem.Allocator, amount: Amount, unit: core.nuts.CurrencyUnit, description: []const u8, unix_expiry: u64) !CreateInvoiceResponse {
    return self.createInvoiceFn(self.ptr, arena, amount, unit, description, unix_expiry);
}

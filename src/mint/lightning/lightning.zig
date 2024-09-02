const std = @import("std");
const invoice = @import("invoices/lib.zig");
const model = @import("../model.zig");
const Self = @This();

// These two fields are the same as before
ptr: *anyopaque,

createInvoiceFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, amount: u64) anyerror!model.CreateInvoiceResult,

payInvoiceFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, payment_request: []const u8) anyerror!model.PayInvoiceResult,

isInvoicePaidFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, invoice: []const u8) anyerror!bool,

// This is new
pub fn init(ptr: anytype) Self {
    const T = @TypeOf(ptr);
    const ptr_info = @typeInfo(T);

    const gen = struct {
        pub fn createInvoice(pointer: *anyopaque, allocator: std.mem.Allocator, amount: u64) !model.CreateInvoiceResult {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.Pointer.child.createInvoice(self, allocator, amount);
        }
        pub fn payInvoice(pointer: *anyopaque, allocator: std.mem.Allocator, payment_request: []const u8) !model.PayInvoiceResult {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.Pointer.child.payInvoice(self, allocator, payment_request);
        }

        pub fn isInvoicePaid(pointer: *anyopaque, allocator: std.mem.Allocator, inv: []const u8) !bool {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.Pointer.child.isInvoicePaid(self, allocator, inv);
        }
    };

    return .{
        .ptr = ptr,

        .createInvoiceFn = gen.createInvoice,
        .isInvoicePaidFn = gen.isInvoicePaid,
        .payInvoiceFn = gen.payInvoice,
    };
}

pub fn isInvoicePaid(self: Self, allocator: std.mem.Allocator, inv: []const u8) anyerror!bool {
    return self.isInvoicePaidFn(self.ptr, allocator, inv);
}

pub fn payInvoice(self: Self, allocator: std.mem.Allocator, payment_request: []const u8) !model.PayInvoiceResult {
    return self.payInvoiceFn(self.ptr, allocator, payment_request);
}

/// Caller is own [model.CreateInvoiceResult], so he responsible to call deinit on it
pub fn createInvoice(self: Self, allocator: std.mem.Allocator, amount: u64) anyerror!model.CreateInvoiceResult {
    return self.createInvoiceFn(self.ptr, allocator, amount);
}

/// Decoding invoice from payment request to [Bolt11Invoice], caller is responsible to call deinit on succ result over [Bolt11Invoice]
pub fn decodeInvoice(_: Self, allocator: std.mem.Allocator, payment_request: []const u8) !invoice.Bolt11Invoice {
    return invoice.Bolt11Invoice.fromStr(allocator, payment_request);
}

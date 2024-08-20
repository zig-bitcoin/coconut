const std = @import("std");

pub const Invoice = struct {
    amount: u64,
    payment_request: []const u8,
};

pub const CreateInvoiceResult = struct {
    payment_hash: []const u8,
    payment_request: []const u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.payment_hash);
        allocator.free(self.payment_request);
    }
};

pub const PayInvoiceResult = struct {
    payment_hash: []const u8,
    /// total fees in sat
    total_fees: u64,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.payment_hash);
    }
};

pub const CreateInvoiceParams = struct {
    amount: u64,
    unit: []const u8,
    memo: ?[]const u8,
    expiry: ?u32,
    webhook: ?[]const u8,
    internal: ?bool,
};

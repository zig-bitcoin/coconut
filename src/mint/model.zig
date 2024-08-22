const std = @import("std");

pub const Invoice = struct {
    amount: u64,
    payment_request: []const u8,

    pub fn deinit(self: Invoice, allocator: std.mem.Allocator) void {
        allocator.free(self.payment_request);
    }

    pub fn clone(self: *const Invoice, allocator: std.mem.Allocator) !Invoice {
        var cp = self.*;
        const pr = try allocator.alloc(u8, self.payment_request.len);
        errdefer allocator.free(pr);

        @memcpy(pr, self.payment_request);

        cp.payment_request = pr;

        return cp;
    }
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

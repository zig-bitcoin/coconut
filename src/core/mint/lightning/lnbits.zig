const std = @import("std");
const model = @import("../model.zig");
const Lightning = @import("lightning.zig");

pub const HttpError = std.http.Client.RequestError || std.http.Client.Request.FinishError || std.http.Client.Request.WaitError || error{ ReadBodyError, WrongJson };

pub const LightningError = HttpError || std.Uri.ParseError || std.mem.Allocator.Error || error{
    NotFound,
    Unauthorized,
    PaymentFailed,
};

pub const Settings = struct {
    admin_key: ?[]const u8,
    url: ?[]const u8,
};

pub const LnBitsLightning = struct {
    client: LNBitsClient,

    pub fn init(allocator: std.mem.Allocator, admin_key: []const u8, lnbits_url: []const u8) !@This() {
        return .{
            .client = try LNBitsClient.init(allocator, admin_key, lnbits_url),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.client.deinit();
    }

    pub fn lightning(self: *@This()) Lightning {
        return Lightning.init(self);
    }

    pub fn isInvoicePaid(self: *@This(), allocator: std.mem.Allocator, invoice: []const u8) !bool {
        const decoded_invoice = try self.lightning().decodeInvoice(allocator, invoice);
        defer decoded_invoice.deinit();

        return self.client.isInvoicePaid(allocator, &decoded_invoice.paymentHash());
    }

    pub fn createInvoice(self: *@This(), allocator: std.mem.Allocator, amount: u64) !model.CreateInvoiceResult {
        return try self.client.createInvoice(allocator, .{
            .amount = amount,
            .unit = "sat",
            .memo = null,
            .expiry = 10000,
            .webhook = null,
            .internal = null,
        });
    }

    pub fn payInvoice(self: *@This(), allocator: std.mem.Allocator, payment_request: []const u8) !model.PayInvoiceResult {
        return try self.client.payInvoice(allocator, payment_request);
    }
};

pub const LNBitsClient = struct {
    admin_key: []const u8,
    lnbits_url: std.Uri,
    client: std.http.Client,

    pub fn init(
        allocator: std.mem.Allocator,
        admin_key: []const u8,
        lnbits_url: []const u8,
    ) !LNBitsClient {
        const url = try std.Uri.parse(lnbits_url);

        var client = std.http.Client{
            .allocator = allocator,
        };
        errdefer client.deinit();

        return .{
            .admin_key = admin_key,
            .lnbits_url = url,
            .client = client,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.client.deinit();
    }

    // get - request get, caller is owner of result slice (should deallocate it with allocator passed as argument)
    pub fn get(
        self: *@This(),
        allocator: std.mem.Allocator,
        endpoint: []const u8,
    ) LightningError![]const u8 {
        var buf: [100]u8 = undefined;
        var b: []u8 = buf[0..];

        const uri = self.lnbits_url.resolve_inplace(endpoint, &b) catch return std.Uri.ParseError.UnexpectedCharacter;

        const header_buf = try allocator.alloc(u8, 1024 * 1024 * 4);
        defer allocator.free(header_buf);

        var req = try self.client.open(.GET, uri, .{
            .server_header_buffer = header_buf,
            .extra_headers = &.{
                .{
                    .name = "X-Api-Key",
                    .value = self.admin_key,
                },
            },
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            if (req.response.status == .not_found) return LightningError.NotFound;
        }

        var rdr = req.reader();
        const body = rdr.readAllAlloc(allocator, 1024 * 1024 * 4) catch |err| {
            std.log.debug("read body error: {any}", .{err});
            return error.ReadBodyError;
        };
        errdefer allocator.free(body);

        return body;
    }

    pub fn post(
        self: *@This(),
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        req_body: []const u8,
    ) LightningError![]const u8 {
        var buf: [100]u8 = undefined;
        var b: []u8 = buf[0..];

        const uri = self.lnbits_url.resolve_inplace(endpoint, &b) catch return std.Uri.ParseError.UnexpectedCharacter;

        const header_buf = try allocator.alloc(u8, 1024 * 1024 * 4);
        defer allocator.free(header_buf);

        var req = try self.client.open(.POST, uri, .{
            .server_header_buffer = header_buf,
            .extra_headers = &.{
                .{
                    .name = "X-Api-Key",
                    .value = self.admin_key,
                },

                .{
                    .name = "accept",
                    .value = "*/*",
                },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = req_body.len };

        try req.send();
        try req.writeAll(req_body);
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            if (req.response.status == .not_found) return LightningError.NotFound;
            if (req.response.status == .unauthorized) return LightningError.Unauthorized;
        }

        var rdr = req.reader();
        const body = rdr.readAllAlloc(allocator, 1024 * 1024 * 4) catch |err| {
            std.log.debug("read post body error: {any}", .{err});
            return error.ReadBodyError;
        };
        errdefer allocator.free(body);

        return body;
    }

    /// createInvoice - creating invoice
    /// note: after success call u need to call deinit on result using alloactor that u pass as argument to this func.
    pub fn createInvoice(self: *@This(), allocator: std.mem.Allocator, params: model.CreateInvoiceParams) !model.CreateInvoiceResult {
        const req_body = try std.json.stringifyAlloc(allocator, &params, .{});

        const res = try self.post(allocator, "api/v1/payments", req_body);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, res, .{ .allocate = .alloc_always }) catch return error.WrongJson;

        const payment_request = parsed.value.object.get("payment_request") orelse unreachable;
        const payment_hash = parsed.value.object.get("payment_hash") orelse unreachable;

        const pr = switch (payment_request) {
            .string => |v| val: {
                const result = try allocator.alloc(u8, v.len);
                @memcpy(result, v);
                break :val result;
            },
            else => {
                unreachable;
            },
        };
        errdefer allocator.free(pr);

        const ph = switch (payment_hash) {
            .string => |v| val: {
                const result = try allocator.alloc(u8, v.len);
                @memcpy(result, v);
                break :val result;
            },
            else => {
                unreachable;
            },
        };
        errdefer allocator.free(ph);

        return .{
            .payment_hash = ph,
            .payment_request = pr,
        };
    }

    /// payInvoice - paying invoice
    /// note: after success call u need to call deinit on result using alloactor that u pass as argument to this func.
    pub fn payInvoice(self: *@This(), allocator: std.mem.Allocator, bolt11: []const u8) !model.PayInvoiceResult {
        const req_body = try std.json.stringifyAlloc(allocator, &.{ .out = true, .bolt11 = bolt11 }, .{});

        const res = try self.post(allocator, "api/v1/payments", req_body);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, res, .{ .allocate = .alloc_always }) catch return error.WrongJson;

        const payment_hash = parsed.value.object.get("payment_hash") orelse unreachable;

        const ph = switch (payment_hash) {
            .string => |v| val: {
                const result = try allocator.alloc(u8, v.len);
                @memcpy(result, v);
                break :val result;
            },
            else => {
                unreachable;
            },
        };
        errdefer allocator.free(ph);

        return .{
            .payment_hash = ph,
            .total_fees = 0,
        };
    }

    /// isInvoicePaid - paying invoice
    /// note: after success call u need to call deinit on result using alloactor that u pass as argument to this func.
    pub fn isInvoicePaid(self: *@This(), allocator: std.mem.Allocator, payment_hash: []const u8) !bool {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "api/v1/payments/{s}",
            .{payment_hash},
        );
        defer allocator.free(endpoint);

        const res = try self.get(allocator, endpoint);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, res, .{ .allocate = .alloc_always }) catch return error.WrongJson;

        const is_paid = parsed.value.object.get("paid") orelse unreachable;

        return switch (is_paid) {
            .bool => |v| v,
            else => false,
        };
    }
};

test "test_decode_invoice" {
    var client = try LnBitsLightning.init(std.testing.allocator, "admin_key", "http://localhost:5000");
    defer client.deinit();

    const lightning = client.lightning();

    const invoice = "lnbcrt55550n1pjga687pp5ac8ja6n5hn90huztxxp746w48vtj8ys5uvze6749dvcsd5j5sdvsdqqcqzzsxqyz5vqsp5kzzq0ycxspxjygsxkfkexkkejjr5ggeyl56mwa7s0ygk2q8z92ns9qyyssqt7myq7sryffasx8v47al053ut4vqts32e9hvedvs7eml5h9vdrtj3k5m72yex5jv355jpuzk2xjjn5468cz87nhp50jyr2al2a5zjvgq2xs5uq";

    const decoded_invoice = try lightning.decodeInvoice(std.testing.allocator, invoice);
    defer decoded_invoice.deinit();

    try std.testing.expectEqual(5_555 * 1_000, decoded_invoice.amountMilliSatoshis());
}

test "test_decode_invoice_invalid" {
    var client = try LnBitsLightning.init(std.testing.allocator, "admin_key", "http://localhost:5000");
    defer client.deinit();

    const lightning = client.lightning();

    const invoice = "lnbcrt55550n1pjga689pp5ac8ja6n5hn90huztyxp746w48vtj8ys5uvze6749dvcsd5j5sdvsdqqcqzzsxqyz5vqsp5kzzq0ycxspxjygsxkfkexkkejjr5ggeyl56mwa7s0ygk2q8z92ns9qyyssqt7myq7sryffasx8v47al053ut4vqts32e9hvedvs7eml5h9vdrtj3k5m72yex5jv355jpuzk2xjjn5468cz87nhp50jyr2al2a5zjvgq2xs5uw";

    // expecting a error
    try std.testing.expect(if (lightning.decodeInvoice(std.testing.allocator, invoice)) |d| v: {
        d.deinit();
        break :v false;
    } else |_| true);
}

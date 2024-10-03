const std = @import("std");
const core = @import("../../lib.zig");
const lightning_invoice = @import("../../../lightning_invoices/invoice.zig");
const httpz = @import("httpz");
const zul = @import("zul");
const ref = @import("../../../sync/ref.zig");
const mpmc = @import("../../../sync/mpmc.zig");
const http_router = @import("../../../misc/http_router/http_router.zig");

const Amount = core.amount.Amount;
const PaymentQuoteResponse = core.lightning.PaymentQuoteResponse;
// const CreateInvoiceResponse = core.lightning.CreateInvoiceResponse;
const MeltQuoteBolt11Request = core.nuts.nut05.MeltQuoteBolt11Request;
const MintMeltSettings = core.lightning.MintMeltSettings;
const MeltQuoteState = core.nuts.nut05.QuoteState;
const MintQuoteState = core.nuts.nut04.QuoteState;
const FeeReserve = core.mint.FeeReserve;
const Channel = @import("../../../channels/channels.zig").Channel;
const MintLightning = core.lightning.MintLightning;

pub const LightningError = error{
    NotFound,
    Unauthorized,
    PaymentFailed,
};

pub const LnBits = struct {
    const Self = @This();

    client: LNBitsClient,

    chan: ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))), // we using signle channel for sending invoices
    allocator: std.mem.Allocator,
    fee_reserve: FeeReserve,

    webhook_url: ?[]const u8,

    mint_settings: MintMeltSettings = .{},
    melt_settings: MintMeltSettings = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        admin_key: []const u8,
        invoice_api_key: []const u8,
        lnbits_url: []const u8,
        mint_settings: MintMeltSettings,
        melt_settings: MintMeltSettings,
        fee_reserve: FeeReserve,
        chan: ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))),
        webhook_url: ?[]const u8,
    ) !@This() {
        return .{
            .allocator = allocator,
            .client = try LNBitsClient.init(
                allocator,
                admin_key,
                invoice_api_key,
                lnbits_url,
            ),
            .mint_settings = mint_settings,
            .melt_settings = melt_settings,
            .fee_reserve = fee_reserve,
            .chan = chan,

            .webhook_url = webhook_url,
        };
    }

    pub fn toMintLightning(self: *const Self, gpa: std.mem.Allocator) error{OutOfMemory}!MintLightning {
        return MintLightning.initFrom(Self, gpa, self.*);
    }

    pub fn getSettings(self: *const Self) core.lightning.Settings {
        return .{
            .mpp = false,
            .unit = .sat,
            .melt_settings = self.melt_settings,
            .mint_settings = self.mint_settings,
        };
    }

    /// caller responsible to deallocate result
    pub fn getPaymentQuote(
        self: *const Self,
        allocator: std.mem.Allocator,
        melt_quote_request: MeltQuoteBolt11Request,
    ) !PaymentQuoteResponse {
        if (melt_quote_request.unit != .sat) return error.UnsupportedUnit;

        const invoice_amount_msat = melt_quote_request
            .request
            .amountMilliSatoshis() orelse return error.UnknownInvoiceAmount;

        const amount = try core.lightning.toUnit(
            invoice_amount_msat,
            .msat,
            melt_quote_request.unit,
        );

        const relative_fee_reserve: u64 =
            @intFromFloat(self.fee_reserve.percent_fee_reserve * @as(f32, @floatFromInt(amount)));

        const absolute_fee_reserve: u64 = self.fee_reserve.min_fee_reserve;

        const fee = if (relative_fee_reserve > absolute_fee_reserve)
            relative_fee_reserve
        else
            absolute_fee_reserve;

        const req_lookup_id = try allocator.dupe(u8, &melt_quote_request.request.paymentHash().inner);
        errdefer allocator.free(req_lookup_id);

        return .{
            .request_lookup_id = req_lookup_id,
            .amount = amount,
            .fee = fee,
            .state = .unpaid,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.client.deinit();
        self.chan.releaseWithFn((struct {
            fn deinit(_self: mpmc.UnboundedChannel(std.ArrayList(u8))) void {
                _self.deinit();
            }
        }).deinit);
    }

    pub fn isInvoicePaid(self: *@This(), allocator: std.mem.Allocator, invoice: []const u8) !bool {
        const decoded_invoice = try self.lightning().decodeInvoice(allocator, invoice);
        defer decoded_invoice.deinit();

        return self.client.isInvoicePaid(allocator, &decoded_invoice.paymentHash());
    }

    pub fn checkInvoiceStatus(
        self: *Self,
        _request_lookup_id: []const u8,
    ) !MintQuoteState {
        return if (try self.client.isInvoicePaid(self.allocator, _request_lookup_id)) .paid else .unpaid;
    }

    pub fn createInvoice(
        self: *Self,
        gpa: std.mem.Allocator,
        amount: Amount,
        unit: core.nuts.CurrencyUnit,
        description: []const u8,
        unix_expiry: u64,
    ) !core.lightning.CreateInvoiceResponse {
        if (unit != .sat) return error.UnsupportedUnit;

        const time_now = std.time.timestamp();
        std.debug.assert(unix_expiry > time_now);

        const amnt = try core.lightning.toUnit(amount, unit, .sat);

        const expiry = unix_expiry - @abs(time_now);

        const create_invoice_response = try self.client.createInvoice(gpa, .{
            .amount = amnt,
            .unit = unit.toString(),
            .memo = description,
            .expiry = expiry,
            .webhook = self.webhook_url,
            .internal = null,
            .out = false,
        });
        errdefer create_invoice_response.deinit(gpa);
        defer gpa.free(create_invoice_response.payment_request);

        var request = try lightning_invoice.Bolt11Invoice.fromStr(gpa, create_invoice_response.payment_request);
        errdefer request.deinit();

        const res_expiry = request.expiresAtSecs();

        return .{
            .request_lookup_id = create_invoice_response.payment_hash,
            .request = request,
            .expiry = res_expiry,
        };
    }

    pub fn payInvoice(
        self: *Self,
        arena: std.mem.Allocator,
        melt_quote: core.mint.MeltQuote,
        _: ?Amount,
        _: ?Amount, // max_fee_msats
    ) !core.lightning.PayInvoiceResponse {
        const pay_response = try self.client.payInvoice(arena, melt_quote.request);

        const invoices_info = try self.client.findInvoice(arena, pay_response.payment_hash);

        if (invoices_info.value.len == 0) return error.InvoiceNotFound;

        const invoice_info = invoices_info.value[0];

        const status: MeltQuoteState = if (invoice_info.pending) .unpaid else .paid;

        const total_spent = @abs(invoice_info.amount + invoice_info.fee);

        return .{
            .payment_hash = pay_response.payment_hash,
            .payment_preimage = invoice_info.payment_hash,
            .status = status,
            .total_spent = total_spent,
            .unit = .sat,
        };
    }

    // Result is channel with invoices, caller must free result
    pub fn waitAnyInvoice(
        self: *Self,
    ) ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))) {
        return self.chan.retain();
    }
};

pub const LNBitsClient = struct {
    admin_key: []const u8,
    invoice_api_key: []const u8,
    lnbits_url: []const u8,
    client: zul.http.Client,

    pub fn init(
        allocator: std.mem.Allocator,
        admin_key: []const u8,
        invoice_api_key: []const u8,
        lnbits_url: []const u8,
    ) !LNBitsClient {
        var client = zul.http.Client.init(allocator);
        errdefer client.deinit();

        return .{
            .admin_key = admin_key,
            .lnbits_url = lnbits_url,
            .invoice_api_key = invoice_api_key,
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
    ) ![]const u8 {
        const uri = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.lnbits_url, endpoint });
        defer allocator.free(uri);

        var req = try self.client.allocRequest(allocator, uri);
        defer req.deinit();

        try req.header("X-Api-Key", self.admin_key);

        var res = try req.getResponse(.{});

        if (res.status != 200) {
            if (res.status == 404) return LightningError.NotFound;
        }

        const res_body = try res.allocBody(allocator, .{});

        return res_body.buf;
    }

    pub fn post(
        self: *@This(),
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        req_body: []const u8,
    ) !zul.StringBuilder {
        const uri = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.lnbits_url, endpoint });
        defer allocator.free(uri);

        var req = try self.client.allocRequest(allocator, uri);
        defer req.deinit();

        req.method = .POST;

        req.body(req_body);

        try req.header("X-Api-Key", self.admin_key);
        try req.header("accept", "*/*");

        var res = try req.getResponse(.{});

        if (res.status != 200) {
            if (res.status == 404) return LightningError.NotFound;
            if (res.status == 401) return LightningError.Unauthorized;
        }

        return try res.allocBody(allocator, .{});
    }

    /// createInvoice - creating invoice
    /// note: after success call u need to call deinit on result using alloactor that u pass as argument to this func.
    pub fn createInvoice(self: *@This(), allocator: std.mem.Allocator, params: CreateInvoiceRequest) !CreateInvoiceResponse {
        const req_body = try std.json.stringifyAlloc(allocator, &params, .{
            .emit_null_optional_fields = false,
        });

        const res = try self.post(allocator, "api/v1/payments", req_body);
        defer res.deinit();

        const parsed = std.json.parseFromSlice(CreateInvoiceResponse, allocator, res.string(), .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch |err| {
            errdefer std.log.debug("Parse create invoice error: {any}, body:\n{s}", .{ err, res.string() });

            return error.WrongJson;
        };
        defer parsed.deinit();

        return try parsed.value.clone(allocator);
    }

    /// payInvoice - paying invoice
    /// note: after success call u need to call deinit on result using alloactor that u pass as argument to this func.
    pub fn payInvoice(self: *@This(), allocator: std.mem.Allocator, bolt11: []const u8) !PayInvoiceResponse {
        const req_body = try std.json.stringifyAlloc(allocator, &.{ .out = true, .bolt11 = bolt11 }, .{});

        const res = try self.post(allocator, "api/v1/payments", req_body);
        defer res.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, res.string(), .{ .allocate = .alloc_always }) catch return error.WrongJson;

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
            // .total_fees = 0,
        };
    }

    /// isInvoicePaid - paying invoice
    /// note: after success call u need to call deinit on result using alloactor that u pass as argument to this func.
    pub fn isInvoicePaid(
        self: *@This(),
        allocator: std.mem.Allocator,
        payment_hash: []const u8,
    ) !bool {
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

    /// findInvoice - finding invoice
    pub fn findInvoice(
        self: *@This(),
        allocator: std.mem.Allocator,
        checking_id: []const u8,
    ) !std.json.Parsed([]const FindInvoiceResponse) {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "api/v1/payments?checking_id=internal_{s}",
            .{checking_id},
        );
        defer allocator.free(endpoint);

        const res = try self.get(allocator, endpoint);

        return std.json.parseFromSlice([]const FindInvoiceResponse, allocator, res, .{ .allocate = .alloc_always }) catch return error.WrongJson;
    }

    /// Create invoice webhook
    pub fn createInvoiceWebhookRouter(
        _: *@This(),
        allocator: std.mem.Allocator,
        webhook_endpoint: []const u8,
        chan: ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))),
    ) !http_router.Router {
        const state = WebhookState{
            .chan = chan,
            .allocator = allocator,
        };
        var router = try httpz.Router(WebhookState, httpz.Action(WebhookState)).init(allocator, WebhookState.dispatcher, state);

        router.post(webhook_endpoint, handleInvoice, .{});

        return try http_router.Router.initFrom(WebhookState, allocator, router);
    }
};

pub fn handleInvoice(
    state: WebhookState,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    std.log.debug("incoming webhook, body : {s}", .{req.body().?});
    const webhook_response = if (try req.json(FindInvoiceResponse)) |resp| resp else {
        res.status = 422;
        return;
    };

    std.log.debug("Received webhook update for: {s}", .{webhook_response.checking_id});

    var sender = try state.chan.value.sender();

    try sender.send(std.ArrayList(u8).fromOwnedSlice(state.allocator, try state.allocator.dupe(u8, webhook_response.checking_id)));
}

/// Webhook state
pub const WebhookState = struct {
    /// allocator to allocate webhook messages
    allocator: std.mem.Allocator,
    /// chan, where we took sender
    chan: ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))),

    pub usingnamespace http_router.DefaultDispatcher(@This());
};

/// Create invoice request
pub const CreateInvoiceRequest = struct {
    /// Amount (sat)
    amount: u64,
    /// Unit
    unit: []const u8,
    /// Memo
    memo: ?[]const u8,
    /// Expiry is in seconds
    expiry: ?u64,
    /// Webhook url
    webhook: ?[]const u8,
    /// Internal payment
    internal: ?bool,
    /// Incoming or outgoing payment
    out: bool,
};

/// Pay invoice response
pub const PayInvoiceResponse = struct {
    /// Payment hash
    payment_hash: []const u8,
};

/// Find invoice response
pub const FindInvoiceResponse = struct {
    /// status
    status: []const u8,
    /// Checking id
    checking_id: []const u8,
    /// Pending (paid)
    pending: bool,
    /// Amount (sat)
    amount: i64,
    /// Fee (msat)
    fee: i64,
    /// Memo
    memo: []const u8,
    /// Time
    time: u64,
    /// Bolt11
    bolt11: []const u8,
    /// Preimage
    preimage: ?[]const u8,
    /// Payment hash
    payment_hash: []const u8,
    /// Expiry
    expiry: f64,
    /// Extra
    extra: std.json.Value, // should be object map
    /// Wallet id
    wallet_id: []const u8,
    /// Webhook url
    webhook: ?[]const u8,
    /// Webhook status
    webhook_status: ?[]const u8,
};
/// Create invoice response
pub const CreateInvoiceResponse = struct {
    /// Payment hash
    payment_hash: []const u8,
    /// Payment request (bolt11)
    payment_request: []const u8,

    pub fn clone(self: CreateInvoiceResponse, alloc: std.mem.Allocator) !CreateInvoiceResponse {
        var s: CreateInvoiceResponse = undefined;
        errdefer s.deinit(alloc);

        s.payment_hash = try alloc.dupe(u8, self.payment_hash);
        s.payment_request = try alloc.dupe(u8, self.payment_request);
        return s;
    }

    pub fn deinit(self: CreateInvoiceResponse, alloc: std.mem.Allocator) void {
        alloc.free(self.payment_hash);
        alloc.free(self.payment_request);
    }
};

test "test_decode_invoice" {
    var client = try LnBits.init(std.testing.allocator, "admin_key", "http://localhost:5000");
    defer client.deinit();

    const lightning = client.lightning();

    const invoice = "lnbcrt55550n1pjga687pp5ac8ja6n5hn90huztxxp746w48vtj8ys5uvze6749dvcsd5j5sdvsdqqcqzzsxqyz5vqsp5kzzq0ycxspxjygsxkfkexkkejjr5ggeyl56mwa7s0ygk2q8z92ns9qyyssqt7myq7sryffasx8v47al053ut4vqts32e9hvedvs7eml5h9vdrtj3k5m72yex5jv355jpuzk2xjjn5468cz87nhp50jyr2al2a5zjvgq2xs5uq";

    const decoded_invoice = try lightning.decodeInvoice(std.testing.allocator, invoice);
    defer decoded_invoice.deinit();

    try std.testing.expectEqual(5_555 * 1_000, decoded_invoice.amountMilliSatoshis());
}

test "test_decode_invoice_invalid" {
    var client = try LnBits.init(std.testing.allocator, "admin_key", "http://localhost:5000");
    defer client.deinit();

    const lightning = client.lightning();

    const invoice = "lnbcrt55550n1pjga689pp5ac8ja6n5hn90huztyxp746w48vtj8ys5uvze6749dvcsd5j5sdvsdqqcqzzsxqyz5vqsp5kzzq0ycxspxjygsxkfkexkkejjr5ggeyl56mwa7s0ygk2q8z92ns9qyyssqt7myq7sryffasx8v47al053ut4vqts32e9hvedvs7eml5h9vdrtj3k5m72yex5jv355jpuzk2xjjn5468cz87nhp50jyr2al2a5zjvgq2xs5uw";

    // expecting a error
    try std.testing.expect(if (lightning.decodeInvoice(std.testing.allocator, invoice)) |d| v: {
        d.deinit();
        break :v false;
    } else |_| true);
}

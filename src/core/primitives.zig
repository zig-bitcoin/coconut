const std = @import("std");
const PublicKey = @import("secp256k1.zig").PublicKey;
const keyset = @import("keyset.zig");
const Proof = @import("proof.zig").Proof;
const blind = @import("blind.zig");
const helper = @import("../helper/helper.zig");
const zul = @import("zul");

pub const CurrencyUnit = enum(u8) {
    sat,
    msat,
    usd,
};

pub const KeysResponse = struct {
    keysets: []const KeyResponse,

    pub fn initFrom(keysets: []const KeyResponse) KeysResponse {
        return .{
            .keysets = keysets,
        };
    }

    // pub fn deinit(self: @This()) void {
    //     self.keysets.deinit();
    // }
};

pub const KeyResponse = struct {
    id: [16]u8,
    unit: CurrencyUnit,
    keys: std.AutoHashMap(u64, PublicKey),

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();

        try out.objectField("id");
        try out.write(self.id);

        try out.objectField("unit");
        try out.write(self.unit);

        try out.objectField("keys");
        try keyset.stringifyMapOfPubkeysWriter(out, self.keys);

        try out.endObject();
    }
};

pub const PostSwapRequest = struct {
    inputs: helper.JsonArrayList(Proof),
    outputs: helper.JsonArrayList(blind.BlindedMessage),

    pub fn deinit(self: @This()) void {
        self.inputs.value.deinit();
        self.outputs.value.deinit();
    }
};

pub const Bolt11MintQuote = struct {
    quote_id: zul.UUID,
    payment_request: []const u8,
    expiry: u64,
    paid: bool,

    pub fn clone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
        const pr = try allocator.alloc(u8, self.payment_request.len);
        errdefer allocator.free(pr);

        @memcpy(pr, self.payment_request);
        var cl = self.*;
        cl.payment_request = pr;

        return cl;
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.payment_request);
    }
};

pub const PostMintBolt11Request = struct {
    quote: []const u8,
    outputs: helper.JsonArrayList(blind.BlindedMessage),

    pub fn deinit(self: @This()) void {
        self.outputs.value.deinit();
    }
};

pub const PostMintBolt11Response = struct {
    signatures: []const blind.BlindedSignature,
};

pub const PostMintQuoteBolt11Request = struct {
    amount: u64,
    unit: CurrencyUnit,
};

pub const PostMintQuoteBolt11Response = struct {
    quote: []const u8,
    request: []const u8,
    paid: bool,
    expiry: ?u64,

    pub fn from(v: Bolt11MintQuote) PostMintQuoteBolt11Response {
        return .{
            .quote = &v.quote_id.toHex(.lower),
            .request = v.payment_request,
            .paid = v.paid,
            .expiry = v.expiry,
        };
    }
};

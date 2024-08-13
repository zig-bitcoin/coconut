const std = @import("std");
const PublicKey = @import("secp256k1.zig").PublicKey;
const keyset = @import("keyset.zig");

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

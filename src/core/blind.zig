const std = @import("std");
const secp256k1 = @import("secp256k1.zig");
const bdhke = @import("bdhke.zig");

pub fn fieldType(comptime T: type, comptime name: []const u8) ?type {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, name))
            return field.type;
    }

    return null;
}

pub const BlindedSignature = struct {
    amount: u64,
    c_: secp256k1.PublicKey,
    id: [16]u8,

    pub usingnamespace @import("../helper/helper.zig").RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "c_", "C_",
                },
            },
        ),
    );

    pub fn totalAmount(data: []const BlindedSignature) u64 {
        var amount: u64 = 0;
        for (data) |x| amount += x.amount;

        return amount;
    }
};

pub const BlindedMessage = struct {
    amount: u64,
    b_: secp256k1.PublicKey,
    id: []const u8,

    pub usingnamespace @import("../helper/helper.zig").RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "b_", "B_",
                },
            },
        ),
    );

    pub fn totalAmount(data: []const BlindedMessage) u64 {
        var amount: u64 = 0;
        for (data) |x| amount += x.amount;

        return amount;
    }
};

test "blind serialize" {
    const dhke = try bdhke.Dhke.init(std.testing.allocator);
    defer dhke.deinit();

    const pub_key = (try secp256k1.SecretKey.fromSlice(&[_]u8{1} ** 32)).publicKey(dhke.secp);

    const sig = BlindedSignature{
        .amount = 10,
        .c_ = pub_key,
        .id = "dfdfdf",
    };

    const json = try std.json.stringifyAlloc(std.testing.allocator, &sig, .{});
    defer std.testing.allocator.free(json);

    const parsedSig = try std.json.parseFromSlice(BlindedSignature, std.testing.allocator, json, .{});
    defer parsedSig.deinit();

    try std.testing.expectEqual(sig.amount, parsedSig.value.amount);
    try std.testing.expectEqualSlices(u8, sig.id, parsedSig.value.id);
    try std.testing.expectEqualSlices(u8, &sig.c_.pk.data, &parsedSig.value.c_.pk.data);

    const msg = BlindedMessage{
        .amount = 11,
        .id = "dfdfdf",
        .b_ = pub_key,
    };

    const json_msg = try std.json.stringifyAlloc(std.testing.allocator, &msg, .{});
    defer std.testing.allocator.free(json_msg);

    const parsedMsg = try std.json.parseFromSlice(BlindedMessage, std.testing.allocator, json_msg, .{});
    defer parsedMsg.deinit();

    try std.testing.expectEqual(msg.amount, parsedMsg.value.amount);
    try std.testing.expectEqualSlices(u8, msg.id, parsedMsg.value.id);
    try std.testing.expectEqualSlices(u8, &msg.b_.pk.data, &parsedMsg.value.b_.pk.data);
}

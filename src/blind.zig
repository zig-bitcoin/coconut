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
    id: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if (.object_begin != try source.next()) return error.UnexpectedToken;

        var res: @This() = undefined;

        const fields = comptime blk: {
            break :blk [_]struct {
                []const u8,
                []const u8,
            }{
                .{
                    "amount", "amount",
                },
                .{
                    "c_", "C_",
                },
                .{
                    "id", "id",
                },
            };
        };

        while (true) {
            const name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            const field_name = switch (name_token.?) {
                inline .string, .allocated_string => |slice| slice,
                .object_end => { // No more fields.
                    break;
                },
                else => {
                    return error.UnexpectedToken;
                },
            };

            var found = false;

            inline for (fields) |f| {
                if (std.mem.eql(u8, f[1], field_name)) {
                    @field(&res, f[0]) = try std.json.innerParse(fieldType(@This(), f[0]).?, allocator, source, options);
                    found = true;
                }
            }

            if (!found) {
                std.log.debug("missing field, name={s}", .{field_name});
                return error.MissingField;
            }
        }

        return res;
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();

        try out.objectField("amount");
        try out.write(self.amount);

        try out.objectField("C_");
        try out.write(self.c_);

        try out.objectField("id");
        try out.write(self.id);

        try out.endObject();
    }
};

pub const BlindedMessage = struct {
    amount: u64,
    b_: secp256k1.PublicKey,
    id: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if (.object_begin != try source.next()) return error.UnexpectedToken;

        var res: @This() = undefined;

        const fields = comptime blk: {
            break :blk [_]struct {
                []const u8,
                []const u8,
            }{
                .{
                    "amount", "amount",
                },
                .{
                    "b_", "B_",
                },
                .{
                    "id", "id",
                },
            };
        };

        while (true) {
            const name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            const field_name = switch (name_token.?) {
                inline .string, .allocated_string => |slice| slice,
                .object_end => { // No more fields.
                    break;
                },
                else => {
                    return error.UnexpectedToken;
                },
            };

            var found = false;

            inline for (fields) |f| {
                if (std.mem.eql(u8, f[1], field_name)) {
                    @field(&res, f[0]) = try std.json.innerParse(fieldType(@This(), f[0]).?, allocator, source, options);
                    found = true;
                }
            }

            if (!found) {
                std.log.debug("missing field, name={s}", .{field_name});
                return error.MissingField;
            }
        }

        return res;
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();

        try out.objectField("amount");
        try out.write(self.amount);

        try out.objectField("B_");
        try out.write(self.b_);

        try out.objectField("id");
        try out.write(self.id);

        try out.endObject();
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

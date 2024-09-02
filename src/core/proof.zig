const std = @import("std");
const PublicKey = @import("secp256k1").PublicKey;
const fieldType = @import("blind.zig").fieldType;

pub const Proof = struct {
    amount: u64,
    keyset_id: [16]u8,
    secret: []const u8,
    c: PublicKey,
    script: ?P2SHScript,

    pub usingnamespace @import("../helper/helper.zig").RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "c", "C",
                },
                .{
                    "keyset_id", "id",
                },
            },
        ),
    );

    pub fn totalAmount(proofs: []const Proof) u64 {
        var total: u64 = 0;

        for (proofs) |proof| total += proof.amount;
        return total;
    }
};

// currently not implemnted
pub const P2SHScript = struct {};

test "proof encode and decode" {
    const keyset = @import("keyset.zig");

    var keys = try keyset.deriveKeys(std.testing.allocator, "supersecretprivatekey", "");
    defer keys.deinit();

    try std.testing.expectEqual(64, keys.count());

    var pub_keys = try keyset.derivePubkeys(std.testing.allocator, keys);
    defer pub_keys.deinit();

    const keyset_id = try keyset.deriveKeysetId(std.testing.allocator, pub_keys);

    const pub_key = try keyset.derivePubkey(std.testing.allocator, "supersecretprivatekey");

    const proof = Proof{
        .amount = 10,
        .keyset_id = keyset_id,
        .secret = "supersecretprivatekey",
        .script = null,
        .c = pub_key,
    };

    const json = try std.json.stringifyAlloc(
        std.testing.allocator,
        &proof,
        .{},
    );
    defer std.testing.allocator.free(json);

    const parsedProof = try std.json.parseFromSlice(Proof, std.testing.allocator, json, .{});
    defer parsedProof.deinit();

    try std.testing.expectEqual(proof.amount, parsedProof.value.amount);
    try std.testing.expectEqual(proof.keyset_id, parsedProof.value.keyset_id);
    try std.testing.expectEqualSlices(u8, proof.secret, parsedProof.value.secret);
    try std.testing.expectEqual(proof.c, parsedProof.value.c);
}

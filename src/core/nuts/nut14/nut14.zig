//! NUT-14: Hashed Time Lock Contacts (HTLC)
//!
//! <https://github.com/cashubtc/nuts/blob/main/14.md>
const std = @import("std");
const bitcoin_primitives = @import("bitcoin-primitives");
const secp256k1 = bitcoin_primitives.secp256k1;

const Witness = @import("../nut00/nut00.zig").Witness;
const Proof = @import("../nut00/nut00.zig").Proof;
const Secret = @import("../nut10/nut10.zig").Secret;
const Conditions = @import("../nut11/nut11.zig").Conditions;
const Signature = secp256k1.schnorr.Signature;

const validSignatures = @import("../nut11/nut11.zig").validSignatures;

/// HTLC Witness
pub const HTLCWitness = struct {
    /// Primage
    preimage: std.ArrayList(u8),
    /// Signatures
    signatures: ?std.ArrayList(std.ArrayList(u8)),

    pub fn deinit(self: HTLCWitness) void {
        if (self.signatures) |s| {
            for (s.items) |ss| ss.deinit();
            s.deinit();
        }

        self.preimage.deinit();
    }
};

/// Verify HTLC
pub fn verifyHTLC(self: *const Proof, allocator: std.mem.Allocator) !void {
    var secret = try Secret.fromSecret(
        self.secret,
        allocator,
    );
    defer secret.deinit();

    const conditions: ?Conditions = v: {
        break :v Conditions.fromTags(secret.value.secret_data.tags orelse break :v null, allocator) catch null;
    };
    defer if (conditions) |c| c.deinit();

    const htlc_witness: HTLCWitness = if (self.witness) |witness| v: {
        break :v switch (witness) {
            .htlc_witness => |w| w,
            else => return error.IncorrectSecretKind,
        };
    } else return error.IncorrectSecretKind;

    if (conditions) |conds| {
        // Check locktime
        if (conds.locktime) |locktime| {
            // If locktime is in passed and no refund keys provided anyone can spend
            if (locktime < @as(u64, @intCast(std.time.timestamp())) and conds.refund_keys == null) {
                return;
            }

            // If refund keys are provided verify p2pk signatures
            if (conds.refund_keys) |refund_key| {
                if (self.witness) |signatures| {
                    const signs = signatures.signatures() orelse return error.SignaturesNotProvided;
                    var signs_parsed = try std.ArrayList(Signature).initCapacity(allocator, signs.items.len);
                    defer signs_parsed.deinit();

                    for (signs.items) |s| {
                        signs_parsed.appendAssumeCapacity(try Signature.fromStr(s.items));
                    }

                    // If secret includes refund keys check that there is a valid signature
                    if (try validSignatures(self.secret.toBytes(), refund_key.items, signs_parsed.items) >= 1) return;
                }
            }
        }

        // If pubkeys are present check there is a valid signature
        if (conds.pubkeys) |pubkey| {
            const req_sigs = conds.num_sigs orelse 1;

            const signs = htlc_witness.signatures orelse return error.SignaturesNotProvided;

            var signatures = try std.ArrayList(Signature).initCapacity(allocator, signs.items.len);
            defer signatures.deinit();

            for (signs.items) |s| {
                signatures.appendAssumeCapacity(try Signature.fromStr(s.items));
            }

            if (try validSignatures(self.secret.toBytes(), pubkey.items, signatures.items) < req_sigs) return error.IncorrectSecretKind;
        }
    }

    if (secret.value.kind != .htlc) {
        return error.IncorrectSecretKind;
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(secret.value.secret_data.data);
    const hash_lock = hasher.finalResult();
    hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(htlc_witness.preimage.items);

    const preimage_hash = hasher.finalResult();

    if (!std.meta.eql(hash_lock, preimage_hash)) return error.Preimage;
}

/// Add Preimage
pub fn addPreimage(self: *Proof, preimage: std.ArrayList(u8)) void {
    self.witness = .{ .htlc_witness = .{
        .preimage = preimage,
        .signatures = null,
    } };
}

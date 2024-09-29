const helper = @import("../../../helper/helper.zig");
const secret = @import("../../secret.zig");
const bitcoin_primitives = @import("bitcoin-primitives");
const secp256k1 = bitcoin_primitives.secp256k1;
const P2PKWitness = @import("../nut11/nut11.zig").P2PKWitness;
const HTLCWitness = @import("../nut14/nut14.zig").HTLCWitness;
const std = @import("std");
const Id = @import("../nut02/nut02.zig").Id;
const BlindSignatureDleq = @import("../nut12/nuts12.zig").BlindSignatureDleq;
const ProofDleq = @import("../nut12/nuts12.zig").ProofDleq;
const amount_lib = @import("../../amount.zig");
const dhke = @import("../../dhke.zig");
const SpendingConditions = @import("../nut11/nut11.zig").SpendingConditions;
const Nut10Secret = @import("../nut10/nut10.zig").Secret;

/// Proofs
pub const Proof = struct {
    /// Amount
    amount: u64,
    /// `Keyset id`
    keyset_id: Id,
    /// Secret message
    secret: secret.Secret,
    // /// Unblinded signature
    c: secp256k1.PublicKey,
    // /// Witness
    witness: ?Witness = null,
    // /// DLEQ Proof
    dleq: ?ProofDleq = null,

    pub usingnamespace helper.RenameJsonField(
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

    pub fn deinit(self: Proof, allocator: std.mem.Allocator) void {
        if (self.witness) |w| w.deinit();
        self.secret.deinit(allocator);
    }

    pub fn clone(self: *const Proof, allocator: std.mem.Allocator) !Proof {
        var cloned = self.*;

        if (self.witness) |w| {
            cloned.witness = try w.clone(allocator);
        }
        errdefer if (cloned.witness) |w| w.deinit();

        cloned.secret = try self.secret.clone(allocator);
        errdefer self.secret.deinit(allocator);

        return cloned;
    }

    /// Get y from proof
    ///
    /// Where y is `hash_to_curve(secret)`
    pub fn y(self: *const Proof) !secp256k1.PublicKey {
        return try dhke.hashToCurve(self.secret.toBytes());
    }
};

/// Witness
pub const Witness = union(enum) {
    /// P2PK Witness
    p2pk_witness: P2PKWitness,

    /// HTLC Witness
    htlc_witness: HTLCWitness, // TODO

    pub fn clone(self: *const Witness, allocator: std.mem.Allocator) !Witness {
        _ = self; // autofix
        _ = allocator; // autofix
        // TODO impl clone
        return undefined;
    }

    pub fn jsonStringify(self: *const Witness, out: anytype) !void {
        switch (self.*) {
            inline .htlc_witness => |w| try out.print("{s}", .{std.json.fmt(w, .{})}),
            inline .p2pk_witness => |w| try out.print("{s}", .{std.json.fmt(w, .{})}),
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, _source: anytype, options: std.json.ParseOptions) !@This() {
        const parsed = try std.json.innerParse(std.json.Value, allocator, _source, options);

        var pss = std.json.Scanner.initCompleteInput(allocator, parsed.string);
        defer pss.deinit();
        var source = &pss;

        var _signatures: ?helper.JsonArrayList([]const u8) = null;
        var _preimage: ?[]const u8 = null;

        if (try source.next() != .object_begin) return error.UnexpectedToken;

        while (true) {
            switch (try source.peekNextTokenType()) {
                .string => {
                    const s = (try source.next()).string;

                    if (std.mem.eql(u8, "signatures", s)) {
                        if (_signatures != null) return error.UnexpectedToken;

                        _signatures = (try std.json.innerParse(helper.JsonArrayList([]const u8), allocator, source, options));
                        continue;
                    }

                    if (std.mem.eql(u8, "preimage", s)) {
                        if (_preimage != null) return error.UnexpectedToken;

                        _preimage = switch (try source.next()) {
                            .string, .allocated_string => |ss| ss,
                            else => return error.UnexpectedToken,
                        };
                    }

                    return error.UnexpectedToken;
                },
                .object_end => break,
                else => return error.UnexpectedToken,
            }
        }

        const signs: ?std.ArrayList(std.ArrayList(u8)) = if (_signatures) |signs| try helper.clone2dSliceToArrayList(u8, allocator, signs.value.items) else null;

        if (_preimage != null) {
            var pr = try std.ArrayList(u8).initCapacity(allocator, _preimage.?.len);

            pr.appendSliceAssumeCapacity(_preimage.?);
            return .{ .htlc_witness = .{
                .preimage = pr,
                .signatures = signs,
            } };
        }

        // TODO better error
        if (signs == null) return error.MissingField;

        return .{
            .p2pk_witness = .{
                .signatures = signs.?,
            },
        };
    }

    pub fn deinit(self: Witness) void {
        switch (self) {
            .p2pk_witness => |w| w.deinit(),
            .htlc_witness => |w| w.deinit(),
        }
    }

    /// Add signatures to [`Witness`]
    pub fn addSignatures(self: *Witness, allocator: std.mem.Allocator, signs: []const []const u8) !void {
        var clonedSignatures = try helper.clone2dSliceToArrayList(u8, allocator, signs);
        defer clonedSignatures.deinit();
        errdefer {
            for (clonedSignatures.items) |i| i.deinit();
        }

        switch (self.*) {
            .p2pk_witness => |*p2pk_witness| try p2pk_witness.signatures.appendSlice(clonedSignatures.items),
            .htlc_witness => |*htlc_witness| if (htlc_witness.signatures) |*_signs| try _signs.appendSlice(clonedSignatures.items),
        }
    }

    /// Get signatures on [`Witness`]
    pub fn signatures(self: *const Witness) ?std.ArrayList(std.ArrayList(u8)) {
        return switch (self.*) {
            .p2pk_witness => |witness| witness.signatures,
            .htlc_witness => |witness| witness.signatures,
        };
    }

    /// Get preimage from [`Witness`]
    pub fn preimage(self: *const Witness) ?[]const u8 {
        return switch (self.*) {
            .p2pk_witness => |_| null,
            else => unreachable,
            // Self::HTLCWitness(witness) => Some(witness.preimage.clone()),
        };
    }
};
/// Payment Method
pub const PaymentMethod = union(enum) {
    /// Bolt11 payment type
    bolt11,
    /// Custom payment type:
    custom: []const u8,

    pub fn fromString(method: []const u8) PaymentMethod {
        if (std.mem.eql(u8, method, "bolt11")) return .bolt11;

        return .{ .custom = method };
    }

    pub fn toString(self: PaymentMethod) []const u8 {
        return switch (self) {
            .bolt11 => "bolt11",
            .custom => |c| c,
        };
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const value = try std.json.innerParse([]const u8, allocator, source, options);

        return PaymentMethod.fromString(value);
    }

    pub fn jsonStringify(self: PaymentMethod, out: anytype) !void {
        try out.write(self.toString());
    }
};

/// Currency Unit
pub const CurrencyUnit = enum {
    /// Sat
    sat,
    /// Msat
    msat,
    /// Usd
    usd,
    /// Euro
    eur,

    pub inline fn derivationIndex(self: *const CurrencyUnit) u32 {
        return switch (self.*) {
            .sat => 0,
            .msat => 1,
            .usd => 2,
            .eur => 3,
        };
    }

    pub fn fromString(s: []const u8) !CurrencyUnit {
        const kv = std.StaticStringMap(CurrencyUnit).initComptime(&.{
            .{
                "sat", .sat,
            },
            .{
                "msat", .msat,
            },
            .{
                "usd", .usd,
            },
            .{
                "eur", .eur,
            },
        });

        return kv.get(s) orelse return error.UnsupportedUnit;
    }

    pub fn toString(self: CurrencyUnit) []const u8 {
        return switch (self) {
            .sat => "sat",
            .msat => "msat",
            .usd => "usd",
            .eur => "eur",
        };
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const value = try std.json.innerParse([]const u8, allocator, source, options);

        return CurrencyUnit.fromString(value) catch return error.UnexpectedToken;
    }

    pub fn jsonStringify(self: *const CurrencyUnit, out: anytype) !void {
        try out.write(self.toString());
    }
};

/// Proof V4
pub const ProofV4 = struct {
    /// Amount in satoshi
    // #[serde(rename = "a")]
    amount: u64,
    /// Secret message
    // #[serde(rename = "s")]
    secret: secret.Secret,
    /// Unblinded signature
    // #[serde(
    //     serialize_with = "serialize_v4_pubkey",
    //     deserialize_with = "deserialize_v4_pubkey"
    // )]
    // TODO ? different serializer
    c: secp256k1.PublicKey,
    /// Witness
    witness: ?Witness,
    /// DLEQ Proof
    // #[serde(rename = "d")]
    dleq: ?ProofDleq,
};

/// Blinded Message (also called `output`)
pub const BlindedMessage = struct {
    /// Amount
    ///
    /// The value for the requested [BlindSignature]
    amount: u64,
    /// Keyset ID
    ///
    /// ID from which we expect a signature.
    keyset_id: Id,
    /// Blinded secret message (B_)
    ///
    /// The blinded secret message generated by the sender.
    blinded_secret: secp256k1.PublicKey,
    /// Witness
    ///
    /// <https://github.com/cashubtc/nuts/blob/main/11.md>
    witness: ?Witness = null,

    pub usingnamespace helper.RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "blinded_secret", "B_",
                },
                .{
                    "keyset_id", "id",
                },
            },
        ),
    );
};

/// Blind Signature (also called `promise`)
pub const BlindSignature = struct {
    /// Amount
    ///
    /// The value of the blinded token.
    amount: u64,
    /// Keyset ID
    ///
    /// ID of the mint keys that signed the token.
    keyset_id: Id,
    /// Blinded signature (C_)
    ///
    /// The blinded signature on the secret message `B_` of [BlindedMessage].
    c: secp256k1.PublicKey,
    /// DLEQ Proof
    ///
    /// <https://github.com/cashubtc/nuts/blob/main/12.md>
    dleq: ?BlindSignatureDleq,

    pub usingnamespace helper.RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "c", "C_",
                },
                .{
                    "keyset_id", "id",
                },
            },
        ),
    );
};

pub const PreMint = struct {
    /// Blinded message
    blinded_message: BlindedMessage,
    /// Secret
    secret: secret.Secret,
    /// R
    r: secp256k1.SecretKey,
    /// Amount
    amount: u64,

    // TODO implement methods
};

/// Premint Secrets
pub const PreMintSecrets = struct {
    /// Secrets
    secrets: []const PreMint,
    /// Keyset Id
    keyset_id: Id,

    // TODO implement methods

    /// Outputs for speceifed amount with random secret
    pub fn random(
        allocator: std.mem.Allocator,
        secp: secp256k1.Secp256k1,
        keyset_id: Id,
        amount: amount_lib.Amount,
        amount_split_target: amount_lib.SplitTarget,
    ) !helper.Parsed(PreMintSecrets) {
        var pre_mint_secrets = try helper.Parsed(PreMintSecrets).init(allocator);
        errdefer pre_mint_secrets.deinit();

        const amount_split = try amount_lib.splitTargeted(amount, allocator, amount_split_target);
        defer amount_split.deinit();

        var output = try std.ArrayList(PreMint).initCapacity(pre_mint_secrets.arena.allocator(), amount_split.items.len);
        defer output.deinit();

        for (amount_split.items) |amnt| {
            const sec = try secret.Secret.generate(pre_mint_secrets.arena.allocator());

            const blinded, const r = try dhke.blindMessage(secp, sec.toBytes(), null);
            const blinded_message = BlindedMessage{
                .amount = amnt,
                .keyset_id = keyset_id,
                .blinded_secret = blinded,
            };

            try output.append(.{
                .secret = sec,
                .blinded_message = blinded_message,
                .r = r,
                .amount = amnt,
            });
        }

        pre_mint_secrets.value.secrets = try output.toOwnedSlice();

        return pre_mint_secrets;
    }

    /// Outputs from pre defined secrets
    pub fn fromSecrets(
        allocator: std.mem.Allocator,
        secp: secp256k1.Secp256k1,
        keyset_id: Id,
        amounts: []const amount_lib.Amount,
        secrets: []const secret.Secret,
    ) !helper.Parsed(PreMintSecrets) {
        var pre_mint_secrets = try helper.Parsed(PreMintSecrets).init(allocator);
        errdefer pre_mint_secrets.deinit();

        var output = try std.ArrayList(PreMint).initCapacity(pre_mint_secrets.arena.allocator(), secrets.len);
        defer output.deinit();

        for (secrets, amounts) |sec, amount| {
            const blinded, const r = try dhke.blindMessage(secp, sec.toBytes(), null);

            const blinded_message = BlindedMessage{
                .amount = amount,
                .keyset_id = keyset_id,
                .blinded_secret = blinded,
            };

            try output.append(.{
                .secret = try sec.clone(pre_mint_secrets.arena.allocator()),
                .blinded_message = blinded_message,
                .r = r,
                .amount = amount,
            });
        }

        pre_mint_secrets.value.secrets = try output.toOwnedSlice();
        return pre_mint_secrets;
    }

    /// Blank Outputs used for NUT-08 change
    pub fn blank(
        allocator: std.mem.Allocator,
        secp: secp256k1.Secp256k1,
        keyset_id: Id,
        fee_reserve: amount_lib.Amount,
    ) !helper.Parsed(PreMintSecrets) {
        var pre_mint_secrets = try helper.Parsed(PreMintSecrets).init(allocator);
        errdefer pre_mint_secrets.deinit();

        const count = @max(1, @as(u64, @intFromFloat(std.math.ceil(std.math.log2(@as(f64, @floatFromInt(fee_reserve)))))));

        var output = try std.ArrayList(PreMint).initCapacity(pre_mint_secrets.arena.allocator(), count);
        defer output.deinit();

        for (0..count) |_| {
            const sec = try secret.Secret.generate(pre_mint_secrets.arena.allocator());
            const blinded, const r = try dhke.blindMessage(secp, sec.toBytes(), null);

            const blinded_message = BlindedMessage{
                .amount = 0,
                .keyset_id = keyset_id,
                .blinded_secret = blinded,
            };

            try output.append(.{
                .secret = sec,
                .blinded_message = blinded_message,
                .r = r,
                .amount = 0,
            });
        }

        pre_mint_secrets.value.secrets = try output.toOwnedSlice();
        return pre_mint_secrets;
    }

    // /// Outputs with specific spending conditions
    pub fn withConditions(
        allocator: std.mem.Allocator,
        secp: secp256k1.Secp256k1,
        keyset_id: Id,
        amount: amount_lib.Amount,
        amount_split_target: amount_lib.SplitTarget,
        conditions: SpendingConditions,
    ) !helper.Parsed(PreMintSecrets) {
        var pre_mint_secrets = try helper.Parsed(PreMintSecrets).init(allocator);
        errdefer pre_mint_secrets.deinit();

        const amount_split = try amount_lib.splitTargeted(amount, allocator, amount_split_target);
        defer amount_split.deinit();

        var output = try std.ArrayList(PreMint).initCapacity(pre_mint_secrets.arena.allocator(), amount_split.items.len);
        defer output.deinit();

        for (amount_split.items) |amnt| {
            var sec10 = try conditions.toSecret(allocator);
            defer sec10.deinit();

            const sec = try sec10.toSecret(pre_mint_secrets.arena.allocator());

            const blinded, const r = try dhke.blindMessage(secp, sec.toBytes(), null);

            const blinded_message = BlindedMessage{
                .amount = amnt,
                .keyset_id = keyset_id,
                .blinded_secret = blinded,
            };

            try output.append(.{
                .secret = sec,
                .blinded_message = blinded_message,
                .r = r,
                .amount = amnt,
            });
        }

        pre_mint_secrets.value.secrets = try output.toOwnedSlice();
        return pre_mint_secrets;
    }
};

test "test_proof_serialize" {
    const proof =
        "[{\"id\":\"009a1f293253e41e\",\"amount\":2,\"secret\":\"407915bc212be61a77e3e6d2aeb4c727980bda51cd06a6afc29e2861768a7837\",\"C\":\"02bc9097997d81afb2cc7346b5e4345a9346bd2a506eb7958598a72f0cf85163ea\"},{\"id\":\"009a1f293253e41e\",\"amount\":8,\"secret\":\"fe15109314e61d7756b0f8ee0f23a624acaa3f4e042f61433c728c7057b931be\",\"C\":\"029e8e5050b890a7d6c0968db16bc1d5d5fa040ea1de284f6ec69d61299f671059\"}]";

    const proofs = try std.json.parseFromSlice([]const Proof, std.testing.allocator, proof, .{});
    defer proofs.deinit();

    try std.testing.expectEqualDeep(try Id.fromStr("009a1f293253e41e"), proofs.value[0].keyset_id);
    try std.testing.expectEqualDeep(proofs.value.len, 2);
}

test "test_blank_blinded_messages" {
    var secp = secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    {
        const b = try PreMintSecrets.blank(std.testing.allocator, secp, try Id.fromStr("009a1f293253e41e"), 1000);
        defer b.deinit();

        try std.testing.expectEqual(10, b.value.secrets.len);
    }

    {
        const b = try PreMintSecrets.blank(std.testing.allocator, secp, try Id.fromStr("009a1f293253e41e"), 1);
        defer b.deinit();

        try std.testing.expectEqual(1, b.value.secrets.len);
    }
}

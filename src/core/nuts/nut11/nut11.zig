//! NUT-11: Pay to Public Key (P2PK)
//!
//! <https://github.com/cashubtc/nuts/blob/main/11.md>
const std = @import("std");

const BlindedMessage = @import("../nut00/nut00.zig").BlindedMessage;
const Proof = @import("../nut00/nut00.zig").Proof;
const secp256k1 = @import("secp256k1");
const Witness = @import("../nut00/nut00.zig").Witness;
const Nut10Secret = @import("../nut10/nut10.zig").Secret;
const Id = @import("../nut02/nut02.zig").Id;
const helper = @import("../../../helper/helper.zig");
const zul = @import("zul");

/// P2Pk Witness
pub const P2PKWitness = struct {
    /// Signatures
    signatures: std.ArrayList(std.ArrayList(u8)),

    pub fn deinit(self: P2PKWitness) void {
        for (self.signatures.items) |s| s.deinit();
        self.signatures.deinit();
    }
};

/// Spending Conditions
///
/// Defined in [NUT10](https://github.com/cashubtc/nuts/blob/main/10.md)
pub const SpendingConditions = union(enum) {
    /// NUT11 Spending conditions
    ///
    /// Defined in [NUT11](https://github.com/cashubtc/nuts/blob/main/11.md)
    p2pk: struct {
        /// The public key of the recipient of the locked ecash
        data: secp256k1.PublicKey,
        /// Additional Optional Spending [`Conditions`]
        conditions: ?Conditions,
    },
    /// NUT14 Spending conditions
    ///
    /// Dedined in [NUT14](https://github.com/cashubtc/nuts/blob/main/14.md)
    htlc: struct {
        /// Hash Lock of ecash
        data: [32]u8,
        /// Additional Optional Spending [`Conditions`]
        conditions: ?Conditions,
    },

    pub fn toSecret(
        conditions: SpendingConditions,
        allocator: std.mem.Allocator,
    ) !Nut10Secret {
        switch (conditions) {
            .p2pk => |condition| {
                return Nut10Secret.init(allocator, .p2pk, &condition.data.toString(), v: {
                    if (condition.conditions) |c| break :v try c.toTags(allocator);
                    break :v null;
                });
            },
            .htlc => |condition| {
                return Nut10Secret.init(allocator, .htlc, &std.fmt.bytesToHex(condition.data, .lower), v: {
                    if (condition.conditions) |c| break :v try c.toTags(allocator);
                    break :v null;
                });
            },
        }
    }
};

/// P2PK and HTLC spending conditions
pub const Conditions = struct {
    /// Unix locktime after which refund keys can be used
    locktime: ?u64 = null,
    /// Additional Public keys
    pubkeys: ?std.ArrayList(secp256k1.PublicKey) = null,
    /// Refund keys
    refund_keys: ?std.ArrayList(secp256k1.PublicKey) = null,
    /// Numbedr of signatures required
    ///
    /// Default is 1
    num_sigs: ?u64 = null,
    /// Signature flag
    ///
    /// Default [`SigFlag.sig_inputs`]
    sig_flag: SigFlag = .sig_inputs,

    pub fn deinit(self: Conditions) void {
        if (self.pubkeys) |pk| pk.deinit();
        if (self.refund_keys) |rk| rk.deinit();
    }

    pub fn fromTags(_tags: []const []const []const u8, allocator: std.mem.Allocator) !Conditions {
        var c = Conditions{};
        errdefer c.deinit();
        for (_tags) |at| {
            const t = try Tag.fromSliceOfString(at, allocator);
            switch (t) {
                .pubkeys => |pk| c.pubkeys = pk,
                .refund => |pk| c.refund_keys = pk,
                .n_sigs => |n| c.num_sigs = n,
                .sig_flag => |f| c.sig_flag = f,
                .locktime => |n| c.locktime = n,
            }
        }

        return c;
    }

    pub fn toTags(self: Conditions, allocator: std.mem.Allocator) !std.ArrayList(std.ArrayList(std.ArrayList(u8))) {
        var res = try std.ArrayList(std.ArrayList(std.ArrayList(u8))).initCapacity(allocator, 5);
        errdefer {
            for (res.items) |it| {
                for (it.items) |t| t.deinit();

                it.deinit();
            }
            res.deinit();
        }

        if (self.pubkeys) |pks| {
            const t = Tag{ .pubkeys = pks };
            res.appendAssumeCapacity(try t.toSliceOfString(allocator));
        }

        if (self.refund_keys) |pks| {
            const t = Tag{ .refund = pks };
            res.appendAssumeCapacity(try t.toSliceOfString(allocator));
        }

        if (self.locktime) |locktime| {
            const t = Tag{ .locktime = locktime };
            res.appendAssumeCapacity(try t.toSliceOfString(allocator));
        }

        if (self.num_sigs) |num_sigs| {
            const t = Tag{ .n_sigs = num_sigs };
            res.appendAssumeCapacity(try t.toSliceOfString(allocator));
        }

        const t = Tag{ .sig_flag = self.sig_flag };
        res.appendAssumeCapacity(try t.toSliceOfString(allocator));

        return res;
    }
};

/// Tag
pub const Tag = union(enum) {
    /// sig_flag [`Tag`]
    sig_flag: SigFlag,
    /// Number of Sigs [`Tag`]
    n_sigs: u64,
    /// Locktime [`Tag`]
    locktime: u64,
    /// Refund [`Tag`]
    refund: std.ArrayList(secp256k1.PublicKey),
    /// Pubkeys [`Tag`]
    pubkeys: std.ArrayList(secp256k1.PublicKey),

    pub fn deinit(self: Tag) void {
        switch (self) {
            .refund, .pubkeys => |t| t.deinit(),
            else => {},
        }
    }
    /// Get [`Tag`] Kind
    pub fn kind(self: Tag) TagKind {
        return switch (self) {
            .sig_flag => .sig_flag,
            .n_sigs => .n_sigs,
            .locktime => .locktime,
            .refund => .refund,
            .pubkeys => .pubkeys,
        };
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginArray();
        try out.write(try self.kind().toString());
        switch (self) {
            .sig_flag => |sig_flag| {
                try out.write(sig_flag.toString());
            },
            .locktime, .n_sigs => |num| {
                try out.write(num);
            },
            .pubkeys, .refund => |pks| {
                for (pks.items) |pk| {
                    try out.write(pk.toString());
                }
            },
        }
        try out.endArray();
    }

    pub fn toSliceOfString(self: Tag, allocator: std.mem.Allocator) !std.ArrayList(std.ArrayList(u8)) {
        var res = try std.ArrayList(std.ArrayList(u8)).initCapacity(allocator, 2);
        errdefer res.deinit();
        errdefer for (res.items) |r| r.deinit();

        const kind_str = try self.kind().toString();
        // std.log.debug("to kind {s}", .{kind_str});
        var tag = try std.ArrayList(u8).initCapacity(allocator, kind_str.len);
        tag.appendSliceAssumeCapacity(kind_str);
        res.appendAssumeCapacity(tag);

        switch (self) {
            .sig_flag => |sig_flag| {
                const s = sig_flag.toString();
                var ss = try std.ArrayList(u8).initCapacity(allocator, s.len);
                errdefer ss.deinit();
                ss.appendSliceAssumeCapacity(s);

                try res.append(ss);
            },
            .locktime, .n_sigs => |num| {
                var s = std.ArrayList(u8).init(allocator);
                errdefer s.deinit();

                try std.fmt.formatInt(num, 10, .lower, .{}, s.writer());

                try res.append(s);
            },
            .pubkeys, .refund => |pks| {
                for (pks.items) |pk| {
                    var k = std.ArrayList(u8).init(allocator);
                    errdefer k.deinit();

                    try k.appendSlice(&(pk.toString()));

                    try res.append(k);
                }
            },
        }

        return res;
    }

    pub fn fromSliceOfString(tags: []const []const u8, allocator: std.mem.Allocator) !Tag {
        if (tags.len == 0) return error.KindNotFound;

        const tag_kind = try TagKind.fromString(tags[0], allocator);
        defer tag_kind.deinit();

        // std.log.debug("tag_kind: {any}, from: {s}", .{ tag_kind, tags[0] });

        return switch (tag_kind) {
            .sig_flag => .{ .sig_flag = try SigFlag.fromString(tags[1]) },
            .n_sigs => .{ .n_sigs = try std.fmt.parseInt(u64, tags[1], 10) },
            .locktime => .{ .locktime = try std.fmt.parseInt(u64, tags[1], 10) },

            .refund => v: {
                var res = std.ArrayList(secp256k1.PublicKey).init(allocator);
                errdefer res.deinit();

                for (tags[1..]) |p| {
                    try res.append(try secp256k1.PublicKey.fromString(p));
                }

                break :v .{ .refund = res };
            },
            .pubkeys => v: {
                var res = std.ArrayList(secp256k1.PublicKey).init(allocator);
                errdefer res.deinit();

                for (tags[1..]) |p| {
                    try res.append(try secp256k1.PublicKey.fromString(p));
                }

                break :v .{ .pubkeys = res };
            },

            else => return error.UnknownTag,
        };
    }
};

/// P2PK and HTLC Spending condition tags
pub const TagKind = union(enum) {
    /// Signature flag
    sig_flag,
    /// Number signatures required
    n_sigs,
    /// Locktime
    locktime,
    /// Refund
    refund,
    /// Pubkey
    pubkeys,
    /// Custom tag kind
    custom: std.ArrayList(u8),

    pub fn deinit(self: TagKind) void {
        switch (self) {
            .custom => |t| t.deinit(),
            else => {},
        }
    }

    pub fn fromString(tag: []const u8, allocator: std.mem.Allocator) !TagKind {
        if (std.mem.eql(u8, tag, "sigflag")) return .sig_flag;
        if (std.mem.eql(u8, tag, "n_sigs")) return .n_sigs;
        if (std.mem.eql(u8, tag, "locktime")) return .locktime;
        if (std.mem.eql(u8, tag, "refund")) return .refund;
        if (std.mem.eql(u8, tag, "pubkeys")) return .pubkeys;

        var r = try std.ArrayList(u8).initCapacity(allocator, tag.len);

        r.appendSliceAssumeCapacity(tag);

        return .{ .custom = r };
    }

    pub fn toString(k: TagKind) ![]const u8 {
        // std.log.debug("toString: {any}", .{k});
        return switch (k) {
            .sig_flag => "sigflag",
            .n_sigs => "n_sigs",
            .locktime => "locktime",
            .refund => "refund",
            .pubkeys => "pubkeys",
            .custom => |data| data.items,
        };
    }
};

pub const SigFlag = enum {
    /// Requires valid signatures on all inputs.
    /// It is the default signature flag and will be applied even if the `sigflag` tag is absent.
    sig_inputs,
    /// Requires valid signatures on all inputs and on all outputs.
    sig_all,
    // TODO json decode

    pub fn fromString(tag: []const u8) !SigFlag {
        if (std.mem.eql(u8, tag, "SIG_ALL")) {
            return .sig_all;
        }

        if (std.mem.eql(u8, tag, "SIG_INPUTS")) {
            return .sig_inputs;
        }

        return error.UnknownSigFlag;
    }

    pub fn toString(f: SigFlag) []const u8 {
        return switch (f) {
            .sig_inputs => "SIG_INPUTS",
            .sig_all => "SIG_ALL",
        };
    }
};

/// Returns count of valid signatures
pub fn validSignatures(msg: []const u8, pubkeys: []const secp256k1.PublicKey, signatures: []const secp256k1.Signature) !u64 {
    var count: usize = 0;
    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    for (pubkeys) |pubkey| {
        for (signatures) |signature| {
            if (pubkey.verify(&secp, msg, signature)) {
                count += 1;
            } else |_| continue;
        }
    }

    return count;
}

/// Sign [Proof]
pub fn signP2PKByProof(self: *Proof, allocator: std.mem.Allocator, secret_key: secp256k1.SecretKey) !void {
    const msg = self.secret.toBytes();

    const signature = try secret_key.sign(msg);

    if (self.witness) |*witness| {
        try witness.addSignatures(allocator, &.{&signature.toString()});
    } else {
        var p2pk_witness = Witness{ .p2pk_witness = .{
            .signatures = std.ArrayList(std.ArrayList(u8)).init(allocator),
        } };
        errdefer p2pk_witness.deinit();

        try p2pk_witness.addSignatures(allocator, &.{&signature.inner});

        self.witness = p2pk_witness;
    }
}

/// Verify P2PK signature on [Proof]
pub fn verifyP2pkProof(self: *Proof, allocator: std.mem.Allocator) !void {
    const secret = try Nut10Secret.fromSecret(self.secret, allocator);
    defer secret.deinit();

    const spending_conditions = if (secret.value.secret_data.tags) |tags| try Conditions.fromTags(tags, allocator) else Conditions{};
    defer spending_conditions.deinit();

    const msg = self.secret.toBytes();

    var valid_sigs: usize = 0;

    const witness_signatures = if (self.witness) |witness| witness.signatures() orelse return error.SignaturesNotProvided else return error.SignaturesNotProvided;

    var pubkeys: std.ArrayList(secp256k1.PublicKey) = if (spending_conditions.pubkeys) |pk| try pk.clone() else std.ArrayList(secp256k1.PublicKey).init(allocator);
    defer pubkeys.deinit();

    if (secret.value.kind == .p2pk) try pubkeys.append(try secp256k1.PublicKey.fromString(secret.value.secret_data.data));

    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    for (witness_signatures.items) |signature| {
        for (pubkeys.items) |v| {
            const sig = try secp256k1.Signature.fromString(signature.items);

            if (v.verify(&secp, msg, sig)) {
                valid_sigs += 1;
            } else |_| {
                std.log.debug("Could not verify signature: {any} on message: {any}", .{
                    sig,
                    self.secret,
                });
            }
        }
    }

    if (valid_sigs >= spending_conditions.num_sigs orelse 1) {
        return;
    }

    if (spending_conditions.locktime) |locktime| {
        if (spending_conditions.refund_keys) |refund_keys| {
            // If lock time has passed check if refund witness signature is valid
            if (locktime < @as(u64, @intCast(std.time.timestamp()))) {
                for (witness_signatures.items) |s| {
                    for (refund_keys.items) |v| {
                        const sig = secp256k1.Signature.fromString(s.items) catch return error.InvalidSignature;
                        // As long as there is one valid refund signature it can be spent

                        if (v.verify(&secp, msg, sig)) {
                            return;
                        } else |_| {}
                    }
                }
            }
        }
    }

    return error.SpendConditionsNotMet;
}

/// Sign [BlindedMessage]
pub fn signP2pkBlindedMessage(self: *BlindedMessage, allocator: std.mem.Allocator, secret_key: secp256k1.SecretKey) !void {
    const msg = self.blinded_secret.serialize();
    const signature = try secret_key.sign(&msg);

    if (self.witness) |*witness| {
        try witness.addSignatures(allocator, &.{&signature.inner});
    } else {
        var p2pk_witness = Witness{ .p2pk_witness = .{
            .signatures = std.ArrayList(std.ArrayList(u8)).init(allocator),
        } };
        errdefer p2pk_witness.deinit();

        try p2pk_witness.addSignatures(allocator, &.{&signature.inner});
        self.witness = p2pk_witness;
    }
}

/// Verify P2PK conditions on [BlindedMessage]
pub fn verifyP2pkBlindedMessages(self: *const BlindedMessage, pubkeys: []const secp256k1.PublicKey, required_sigs: u64) !void {
    var valid_sigs: usize = 0;

    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    if (self.witness) |witness| {
        if (witness.signatures()) |signatures| {
            for (signatures.items) |signature| {
                for (pubkeys) |v| {
                    const msg = self.blinded_secret.serialize();
                    const sig = try secp256k1.Signature.fromString(signature.items);

                    if (v.verify(&secp, &msg, sig)) {
                        valid_sigs += 1;
                    } else |_| {
                        std.log.debug("Could not verify signature: {any} on message: {any}", .{
                            sig,
                            self.blinded_secret,
                        });
                    }
                }
            }
        } else return error.SignaturesNotProvided;
    }

    if (valid_sigs > required_sigs) return;

    return error.SpendConditionsNotMet;
}

test "test_secret_ser" {
    const data = try secp256k1.PublicKey.fromString(
        "033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e",
    );

    var conditions = v: {
        var pubkeys = std.ArrayList(secp256k1.PublicKey).init(std.testing.allocator);
        errdefer pubkeys.deinit();

        try pubkeys.append(try secp256k1.PublicKey.fromString("02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904"));
        try pubkeys.append(try secp256k1.PublicKey.fromString("023192200a0cfd3867e48eb63b03ff599c7e46c8f4e41146b2d281173ca6c50c54"));

        var refund_keys = std.ArrayList(secp256k1.PublicKey).init(std.testing.allocator);
        errdefer refund_keys.deinit();

        try refund_keys.append(try secp256k1.PublicKey.fromString("033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e"));

        break :v Conditions{
            .locktime = 99999,
            .pubkeys = pubkeys,
            .refund_keys = refund_keys,
            .num_sigs = 2,
            .sig_flag = .sig_all,
        };
    };
    defer conditions.deinit();

    const tags = try conditions.toTags(std.testing.allocator);
    defer {
        for (tags.items) |t| {
            for (t.items) |tt| {
                tt.deinit();
            }
            t.deinit();
        }
        tags.deinit();
    }

    var secret: Nut10Secret = try Nut10Secret.init(
        std.testing.allocator,
        .p2pk,
        &data.toString(),
        tags,
    );
    defer secret.deinit();

    var secret_str = std.ArrayList(u8).init(std.testing.allocator);
    defer secret_str.deinit();

    try std.json.stringify(&secret, .{}, secret_str.writer());

    const secret_der = try std.json.parseFromSlice(Nut10Secret, std.testing.allocator, secret_str.items, .{});
    defer secret_der.deinit();

    try zul.testing.expectEqual(secret.kind, secret_der.value.kind);

    try zul.testing.expectEqualSlices(u8, secret.secret_data.nonce, secret_der.value.secret_data.nonce);
    try zul.testing.expectEqualSlices(u8, secret.secret_data.data, secret_der.value.secret_data.data);

    try zul.testing.expectEqual(secret.secret_data.tags.?.len, secret_der.value.secret_data.tags.?.len);

    try zul.testing.expect(secret.secret_data.eql(secret_der.value.secret_data));
}

test "sign_proof" {
    var secp = try secp256k1.Secp256k1.genNew();
    defer secp.deinit();

    const secret_key = try secp256k1.SecretKey.fromString("99590802251e78ee1051648439eedb003dc539093a48a44e7b8f2642c909ea37");
    const secret_key_two = try secp256k1.SecretKey.fromString("0000000000000000000000000000000000000000000000000000000000000001");
    const secret_key_three = try secp256k1.SecretKey.fromString("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f");

    const v_key = secret_key.publicKey(secp);
    const v_key_two = secret_key_two.publicKey(secp);
    const v_key_three = secret_key_three.publicKey(secp);

    var pks = try std.ArrayList(secp256k1.PublicKey).initCapacity(std.testing.allocator, 2);
    defer pks.deinit();

    try pks.appendSlice(&.{ v_key_two, v_key_three });

    var refund_keys = try std.ArrayList(secp256k1.PublicKey).initCapacity(std.testing.allocator, 1);
    defer refund_keys.deinit();

    try refund_keys.appendSlice(&.{v_key});

    const conditions = Conditions{
        .locktime = 21000000000,
        .pubkeys = pks,
        .refund_keys = refund_keys,
        .num_sigs = 2,
        .sig_flag = .sig_inputs,
    };

    const tags = try conditions.toTags(std.testing.allocator);
    defer {
        for (tags.items) |tt| {
            for (tt.items) |t| t.deinit();
            tt.deinit();
        }

        tags.deinit();
    }

    var secret: Nut10Secret = try Nut10Secret.init(
        std.testing.allocator,
        .p2pk,
        &v_key.toString(),
        tags,
    );
    defer secret.deinit();

    const nsecret = try secret.toSecret(std.testing.allocator);

    var proof = Proof{
        .keyset_id = try Id.fromStr("009a1f293253e41e"),
        .amount = 0,
        .secret = nsecret,
        .c = try secp256k1.PublicKey.fromString("02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904"),
        .witness = .{ .p2pk_witness = .{ .signatures = std.ArrayList(std.ArrayList(u8)).init(std.testing.allocator) } },
    };
    defer proof.deinit(std.testing.allocator);

    try signP2PKByProof(&proof, std.testing.allocator, secret_key);
    try signP2PKByProof(&proof, std.testing.allocator, secret_key_two);
    try verifyP2pkProof(&proof, std.testing.allocator);
}

test "check conditions tags" {
    var conditions = v: {
        var pubkeys = std.ArrayList(secp256k1.PublicKey).init(std.testing.allocator);
        errdefer pubkeys.deinit();

        try pubkeys.append(try secp256k1.PublicKey.fromString("02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904"));
        try pubkeys.append(try secp256k1.PublicKey.fromString("023192200a0cfd3867e48eb63b03ff599c7e46c8f4e41146b2d281173ca6c50c54"));

        var refund_keys = std.ArrayList(secp256k1.PublicKey).init(std.testing.allocator);
        errdefer refund_keys.deinit();

        try refund_keys.append(try secp256k1.PublicKey.fromString("033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e"));

        break :v Conditions{
            .locktime = 99999,
            .pubkeys = pubkeys,
            .refund_keys = refund_keys,
            .num_sigs = 2,
            .sig_flag = .sig_all,
        };
    };
    defer conditions.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tags = try conditions.toTags(arena.allocator());
    // std.log.debug("size of tags: {any}", .{tags.items.len});

    const nconditions = try Conditions.fromTags(try helper.clone3dArrayToSlice(u8, arena.allocator(), tags), std.testing.allocator);
    defer nconditions.deinit();
}

test "test_verify" {
    // Proof with a valid signature
    const json =
        \\{
        \\    "amount":1,
        \\    "secret":"[\"P2PK\",{\"nonce\":\"859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"sigflag\",\"SIG_INPUTS\"]]}]",
        \\    "C":"02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
        \\    "id":"009a1f293253e41e",
        \\    "witness":"{\"signatures\":[\"60f3c9b766770b46caac1d27e1ae6b77c8866ebaeba0b9489fe6a15a837eaa6fcd6eaa825499c72ac342983983fd3ba3a8a41f56677cc99ffd73da68b59e1383\"]}"
        \\}
    ;

    var proof = try std.json.parseFromSlice(Proof, std.testing.allocator, json, .{});
    defer proof.deinit();

    try verifyP2pkProof(&proof.value, std.testing.allocator);

    const invalid_json =
        \\{"amount":1,"secret":"[\"P2PK\",{\"nonce\":\"859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"sigflag\",\"SIG_INPUTS\"]]}]","C":"02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904","id":"009a1f293253e41e","witness":"{\"signatures\":[\"3426df9730d365a9d18d79bed2f3e78e9172d7107c55306ac5ddd1b2d065893366cfa24ff3c874ebf1fc22360ba5888ddf6ff5dbcb9e5f2f5a1368f7afc64f15\"]}"}
    ;

    var invalid_proof = try std.json.parseFromSlice(Proof, std.testing.allocator, invalid_json, .{});
    defer invalid_proof.deinit();

    try std.testing.expectError(error.SpendConditionsNotMet, verifyP2pkProof(&invalid_proof.value, std.testing.allocator));
}

test "verify_multi_sig" {
    // Proof with 2 valid signatures to satifiy the condition
    const json =
        \\{"amount":0,"secret":"[\"P2PK\",{\"nonce\":\"0ed3fcb22c649dd7bbbdcca36e0c52d4f0187dd3b6a19efcc2bfbebb5f85b2a1\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"02142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"n_sigs\",\"2\"],[\"sigflag\",\"SIG_INPUTS\"]]}]","C":"02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904","id":"009a1f293253e41e","witness":"{\"signatures\":[\"83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3\",\"9a72ca2d4d5075be5b511ee48dbc5e45f259bcf4a4e8bf18587f433098a9cd61ff9737dc6e8022de57c76560214c4568377792d4c2c6432886cc7050487a1f22\"]}"}
    ;

    var proof = try std.json.parseFromSlice(Proof, std.testing.allocator, json, .{});
    defer proof.deinit();

    try verifyP2pkProof(&proof.value, std.testing.allocator);

    // Proof with only one of the required signatures
    const invalid_json =
        \\{"amount":0,"secret":"[\"P2PK\",{\"nonce\":\"0ed3fcb22c649dd7bbbdcca36e0c52d4f0187dd3b6a19efcc2bfbebb5f85b2a1\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"02142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"n_sigs\",\"2\"],[\"sigflag\",\"SIG_INPUTS\"]]}]","C":"02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904","id":"009a1f293253e41e","witness":"{\"signatures\":[\"83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3\"]}"}
    ;

    var invalid_proof = try std.json.parseFromSlice(Proof, std.testing.allocator, invalid_json, .{});
    defer invalid_proof.deinit();

    // Verification should fail without the requires signatures
    try std.testing.expectError(error.SpendConditionsNotMet, verifyP2pkProof(&invalid_proof.value, std.testing.allocator));
}

test "verify_refund" {
    const json =
        \\{"amount":1,"id":"009a1f293253e41e","secret":"[\"P2PK\",{\"nonce\":\"902685f492ef3bb2ca35a47ddbba484a3365d143b9776d453947dcbf1ddf9689\",\"data\":\"026f6a2b1d709dbca78124a9f30a742985f7eddd894e72f637f7085bf69b997b9a\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"03142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"locktime\",\"21\"],[\"n_sigs\",\"2\"],[\"refund\",\"026f6a2b1d709dbca78124a9f30a742985f7eddd894e72f637f7085bf69b997b9a\"],[\"sigflag\",\"SIG_INPUTS\"]]}]","C":"02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904","witness":"{\"signatures\":[\"710507b4bc202355c91ea3c147c0d0189c75e179d995e566336afd759cb342bcad9a593345f559d9b9e108ac2c9b5bd9f0b4b6a295028a98606a0a2e95eb54f7\"]}"}
    ;

    var proof = try std.json.parseFromSlice(Proof, std.testing.allocator, json, .{});
    defer proof.deinit();

    try verifyP2pkProof(&proof.value, std.testing.allocator);

    const invalid_json =
        \\{"amount":1,"id":"009a1f293253e41e","secret":"[\"P2PK\",{\"nonce\":\"64c46e5d30df27286166814b71b5d69801704f23a7ad626b05688fbdb48dcc98\",\"data\":\"026f6a2b1d709dbca78124a9f30a742985f7eddd894e72f637f7085bf69b997b9a\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"03142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"locktime\",\"21\"],[\"n_sigs\",\"2\"],[\"refund\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\"],[\"sigflag\",\"SIG_INPUTS\"]]}]","C":"02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904","witness":"{\"signatures\":[\"f661d3dc046d636d47cb3d06586da42c498f0300373d1c2a4f417a44252cdf3809bce207c8888f934dba0d2b1671f1b8622d526840f2d5883e571b462630c1ff\"]}"}
    ;

    var invalid_proof = try std.json.parseFromSlice(Proof, std.testing.allocator, invalid_json, .{});
    defer invalid_proof.deinit();

    // Verification should fail without the requires signatures
    try std.testing.expectError(error.SpendConditionsNotMet, verifyP2pkProof(&invalid_proof.value, std.testing.allocator));
}

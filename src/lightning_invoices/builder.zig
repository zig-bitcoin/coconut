const std = @import("std");
const bitcoin_primitives = @import("bitcoin-primitives");
const bip32 = bitcoin_primitives.bips.bip32;
const secp256k1 = bitcoin_primitives.secp256k1;
const invoice_lib = @import("invoice.zig");

const Currency = invoice_lib.Currency;
const SiPrefix = invoice_lib.SiPrefix;
const TaggedField = invoice_lib.TaggedField;
const RawTaggedField = invoice_lib.RawTaggedField;
const PaymentSecret = invoice_lib.PaymentSecret;
const Features = @import("features.zig");
const Bolt11Invoice = invoice_lib.Bolt11Invoice;
const RawDataPart = invoice_lib.RawDataPart;
const RawBolt11Invoice = invoice_lib.RawBolt11Invoice;
const RawHrp = invoice_lib.RawHrp;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Message = secp256k1.Message;
const RecoverableSignature = secp256k1.ecdsa.RecoverableSignature;

const InvoiceBuilder = @This();

currency: Currency,
amount: ?u64,
si_prefix: ?SiPrefix,
timestamp: ?u64,
tagged_fields: std.ArrayList(TaggedField),

/// exactly one [`TaggedField.description`] or [`TaggedField.description_hash`]
description_flag: bool = false,

/// exactly one [`TaggedField.payment_hash`]
hash_flag: bool = false,

///  the timestamp is set
timestamp_flag: bool = false,

///  the CLTV expiry is set
cltv_flag: bool = false,

///  the payment secret is set
secret_flag: bool = false,

///  payment metadata is set
payment_metadata_flag: bool = false,

/// Construct new, empty `InvoiceBuilder`. All necessary fields have to be filled first before
/// `InvoiceBuilder.build(self)` becomes available.
pub fn init(allocator: std.mem.Allocator, currency: Currency) !InvoiceBuilder {
    return .{
        .currency = currency,
        .amount = null,
        .si_prefix = null,
        .timestamp = null,
        .tagged_fields = try std.ArrayList(TaggedField).initCapacity(allocator, 8),
    };
}

pub fn deinit(self: InvoiceBuilder) void {
    self.tagged_fields.deinit();
}

/// Builds a [`RawBolt11Invoice`] if no [`CreationError`] occurred while construction any of the
/// fields.
pub fn buildRaw(self: *const InvoiceBuilder, gpa: std.mem.Allocator) !RawBolt11Invoice {
    const hrp = RawHrp{
        .currency = self.currency,
        .raw_amount = self.amount,
        .si_prefix = self.si_prefix,
    };

    const timestamp = self.timestamp orelse @panic("expected timestamp");

    var tagged_fields = try std.ArrayList(RawTaggedField).initCapacity(gpa, self.tagged_fields.items.len);
    errdefer tagged_fields.deinit();

    // we moving ownership of TaggedField
    for (self.tagged_fields.items) |tf| {
        tagged_fields.appendAssumeCapacity(.{ .known = tf });
    }

    const data = RawDataPart{
        .timestamp = timestamp,
        .tagged_fields = tagged_fields,
    };

    return .{
        .hrp = hrp,
        .data = data,
    };
}

/// Builds and signs an invoice using the supplied `sign_function`. This function MAY fail with
/// an error of type `E` and MUST produce a recoverable signature valid for the given hash and
/// if applicable also for the included payee public key.
pub fn tryBuildSigned(self: *const InvoiceBuilder, gpa: std.mem.Allocator, sign_function: *const fn (Message) anyerror!RecoverableSignature) !Bolt11Invoice {
    var raw = try self.buildRaw(gpa);
    errdefer raw.deinit();

    const invoice = Bolt11Invoice{
        .signed_invoice = try raw.sign(gpa, sign_function),
    };

    // TODO
    //invoice.check_field_counts().expect("should be ensured by type signature of builder");
    // invoice.check_feature_bits().expect("should be ensured by type signature of builder");
    // invoice.check_amount().expect("should be ensured by type signature of builder");

    return invoice;
}

/// Set the description. This function is only available if no description (hash) was set.
/// Copy description
pub fn setDescription(self: *InvoiceBuilder, gpa: std.mem.Allocator, description: []const u8) !void {
    if (self.description_flag) return error.DescriptionAlreadySet;

    const _description = try gpa.dupe(
        u8,
        description,
    );
    errdefer gpa.free(_description);

    self.description_flag = true;

    self.tagged_fields.appendAssumeCapacity(.{
        .description = .{
            .inner = std.ArrayList(u8).fromOwnedSlice(gpa, _description),
        },
    });
}

/// Set the description hash. This function is only available if no description (hash) was set.
pub fn setDescriptionHash(self: *InvoiceBuilder, description_hash: [Sha256.digest_length]u8) !void {
    if (self.description_flag) return error.DescriptionAlreadySet;
    self.description_flag = true;

    self.tagged_fields.appendAssumeCapacity(.{
        .description_hash = .{
            .inner = description_hash,
        },
    });
}

/// Set the payment hash. This function is only available if no payment hash was set.
pub fn setPaymentHash(self: *InvoiceBuilder, hash: [Sha256.digest_length]u8) !void {
    if (self.hash_flag) return error.PaymentHashAlreadySet;

    self.hash_flag = true;

    self.tagged_fields.appendAssumeCapacity(.{
        .payment_hash = .{
            .inner = hash,
        },
    });
}

/// Sets the timestamp to a specific .
pub fn setTimestamp(self: *InvoiceBuilder, time: u64) !void {
    if (self.timestamp_flag) return error.TimestampAlreadySet;

    self.timestamp_flag = true;

    self.timestamp = time;
}
/// Sets the timestamp to a specific .
pub fn setCurrentTimestamp(self: *InvoiceBuilder) !void {
    if (self.timestamp_flag) return error.TimestampAlreadySet;

    self.timestamp_flag = true;

    self.timestamp = @intCast(std.time.timestamp());
}

/// Sets `min_final_cltv_expiry_delta`.
pub fn setMinFinalCltvExpiryDelta(self: *InvoiceBuilder, delta: u64) !void {
    if (self.cltv_flag) return error.CltvExpiryAlreadySet;

    self.tagged_fields.appendAssumeCapacity(.{ .min_final_cltv_expiry_delta = .{ .inner = delta } });
}

/// Sets the payment secret and relevant features.
pub fn setPaymentSecret(self: *InvoiceBuilder, gpa: std.mem.Allocator, payment_secret: PaymentSecret) !void {
    self.secret_flag = true;

    var found_features = false;
    for (self.tagged_fields.items) |*f| {
        switch (f.*) {
            .features => |*field| {
                found_features = true;
                try field.set(Features.tlv_onion_payload_required);
                try field.set(Features.payment_addr_required);
            },
            else => continue,
        }
    }

    self.tagged_fields.appendAssumeCapacity(.{ .payment_secret = payment_secret });

    if (!found_features) {
        var features = Features{
            .flags = std.AutoHashMap(Features.FeatureBit, void).init(gpa),
        };

        try features.set(Features.tlv_onion_payload_required);
        try features.set(Features.payment_addr_required);

        self.tagged_fields.appendAssumeCapacity(.{ .features = features });
    }
}

/// Sets the amount in millisatoshis. The optimal SI prefix is chosen automatically.
pub fn setAmountMilliSatoshis(self: *InvoiceBuilder, amount_msat: u64) !void {
    const amount = std.math.mul(u64, amount_msat, 10) catch return error.InvalidAmount;

    const biggest_possible_si_prefix = for (SiPrefix.valuesDesc()) |prefix| {
        if (amount % prefix.multiplier() == 0) break prefix;
    } else @panic("Pico should always match");

    self.amount = amount / biggest_possible_si_prefix.multiplier();
    self.si_prefix = biggest_possible_si_prefix;
}

test "test expiration" {
    var builder = try InvoiceBuilder.init(std.testing.allocator, .bitcoin);
    defer builder.deinit();

    try builder.setDescription(std.testing.allocator, "Test");
    try builder.setPaymentHash([_]u8{0} ** 32);
    try builder.setPaymentSecret(
        std.testing.allocator,
        .{ .inner = [_]u8{0} ** 32 },
    );
    try builder.setTimestamp(1234567);

    var signed_invoice = v: {
        var builded_raw = try builder.buildRaw(std.testing.allocator);
        errdefer builded_raw.deinit();

        break :v try builded_raw.sign(std.testing.allocator, (struct {
            fn sign(hash: Message) !RecoverableSignature {
                const pk = try secp256k1.SecretKey.fromSlice(&[_]u8{41} ** 32);
                const secp = secp256k1.Secp256k1.genNew();
                defer secp.deinit();

                return secp.signEcdsaRecoverable(&hash, &pk);
            }
        }).sign);
    };
    defer signed_invoice.deinit();

    const invoice = try Bolt11Invoice.fromSigned(signed_invoice);

    try std.testing.expect(invoice.wouldExpire(1234567 + invoice_lib.default_expiry_time + 1));

    try std.testing.expect(!invoice.wouldExpire(1234567 + invoice_lib.default_expiry_time - 5));
}

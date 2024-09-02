const std = @import("std");
const errors = @import("error.zig");
const core = @import("../../../core/lib.zig");
const constants = @import("constants.zig");
const bech32 = @import("../../../bech32/bech32.zig");

/// Construct the invoice's HRP and signatureless data into a preimage to be hashed.
pub fn constructInvoicePreimage(allocator: std.mem.Allocator, hrp_bytes: []const u8, data_without_signature: []const u5) !std.ArrayList(u8) {
    var preimage = try std.ArrayList(u8).initCapacity(allocator, hrp_bytes.len);
    errdefer preimage.deinit();

    preimage.appendSliceAssumeCapacity(hrp_bytes);

    var data_part = try std.ArrayList(u5).initCapacity(allocator, data_without_signature.len);
    defer data_part.deinit();

    data_part.appendSliceAssumeCapacity(data_without_signature);

    const overhang = (data_part.items.len * 5) % 8;

    if (overhang > 0) {
        // add padding if data does not end at a byte boundary
        try data_part.append(0);

        // if overhang is in (1..3) we need to add u5(0) padding two times
        if (overhang < 3) {
            try data_part.append(0);
        }
    }

    const data_part_u8 = try bech32.arrayListFromBase32(allocator, data_part.items);
    defer data_part_u8.deinit();

    try preimage.appendSlice(data_part_u8.items);

    return preimage;
}

/// Represents a syntactically and semantically correct lightning BOLT11 invoice.
///
/// There are three ways to construct a `Bolt11Invoice`:
///  1. using [`InvoiceBuilder`]
///  2. using [`Bolt11Invoice::from_signed`]
///  3. using `str::parse::<Bolt11Invoice>(&str)` (see [`Bolt11Invoice::from_str`])
///
/// [`Bolt11Invoice::from_str`]: crate::Bolt11Invoice#impl-FromStr
pub const Bolt11Invoice = struct {
    signed_invoice: SignedRawBolt11Invoice,

    pub fn deinit(self: @This()) void {
        self.signed_invoice.deinit();
    }

    pub fn fromStr(allocator: std.mem.Allocator, s: []const u8) !Bolt11Invoice {
        const signed = try SignedRawBolt11Invoice.fromStr(allocator, s);

        return Bolt11Invoice.fromSigned(signed);
    }

    pub fn fromSigned(signed_invoice: SignedRawBolt11Invoice) !@This() {
        const invoice = Bolt11Invoice{ .signed_invoice = signed_invoice };

        //       invoice.check_field_counts()?;
        // invoice.check_feature_bits()?;
        // invoice.check_signature()?;
        // invoice.check_amount()?;

        return invoice;
    }

    /// Returns the amount if specified in the invoice as pico BTC.
    fn amountPicoBtc(self: @This()) ?u64 {
        return self.signed_invoice.raw_invoice.amountPicoBtc();
    }

    /// Check that amount is a whole number of millisatoshis
    fn checkAmount(self: @This()) !void {
        if (self.amountPicoBtc()) |amount_pico_btc| {
            if (amount_pico_btc % 10 != 0) {
                return error.ImpreciseAmount;
            }
        }
    }

    /// Returns the amount if specified in the invoice as millisatoshis.
    pub fn amountMilliSatoshis(self: @This()) ?u64 {
        return if (self.signed_invoice.raw_invoice.amountPicoBtc()) |v| v / 10 else null;
    }

    /// Returns the hash to which we will receive the preimage on completion of the payment
    pub fn paymentHash(self: @This()) Sha256 {
        return self.signed_invoice.raw_invoice.getKnownTag(.payment_hash) orelse @panic("expected payment_hash");
    }
};

/// Represents an syntactically correct [`Bolt11Invoice`] for a payment on the lightning network,
/// but without the signature information.
/// Decoding and encoding should not lead to information loss but may lead to different hashes.
///
/// For methods without docs see the corresponding methods in [`Bolt11Invoice`].
pub const RawBolt11Invoice = struct {
    /// human readable part
    hrp: RawHrp,

    /// data part
    data: RawDataPart,

    pub fn deinit(self: RawBolt11Invoice) void {
        self.data.deinit();
    }

    /// Hash the HRP as bytes and signatureless data part.
    fn hashFromParts(allocator: std.mem.Allocator, hrp_bytes: []const u8, data_without_signature: []const u5) ![32]u8 {
        const preimage = try constructInvoicePreimage(allocator, hrp_bytes, data_without_signature);

        defer preimage.deinit();

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(preimage.items);

        return hasher.finalResult();
    }

    pub fn getKnownTag(self: RawBolt11Invoice, comptime t: std.meta.Tag(TaggedField)) ?std.meta.TagPayload(TaggedField, t) {
        for (self.data.tagged_fields.items) |f| {
            return switch (f) {
                .known => |kf| v: {
                    switch (kf) {
                        t => |ph| break :v ph,
                        else => break :v null,
                    }
                },
                else => null,
            } orelse continue;
        }

        return null;
    }

    /// Returns `null` if no amount is set or on overflow.
    pub fn amountPicoBtc(self: RawBolt11Invoice) ?u64 {
        if (self.hrp.raw_amount) |v| {
            const multiplier: u64 = if (self.hrp.si_prefix) |si| si.multiplier() else 1_000_000_000_000;

            return std.math.mul(u64, v, multiplier) catch null;
        }

        return null;
    }
};

pub const Bolt11InvoiceSignature = struct {
    value: core.secp256k1.RecoverableSignature,

    pub fn fromBase32(allocator: std.mem.Allocator, sig: []const u5) !Bolt11InvoiceSignature {
        if (sig.len != 104) return errors.Bolt11ParseError.InvalidSliceLength;

        const recoverable_signature_bytes = try bech32.arrayListFromBase32(allocator, sig);
        defer recoverable_signature_bytes.deinit();

        const signature = recoverable_signature_bytes.items[0..64];
        const recovery_id = try core.secp256k1.RecoveryId.fromI32(recoverable_signature_bytes.items[64]);

        return .{ .value = try core.secp256k1.RecoverableSignature.fromCompact(signature, recovery_id) };
    }
};

/// Represents a signed [`RawBolt11Invoice`] with cached hash. The signature is not checked and may be
/// invalid.
///
/// # Invariants
/// The hash has to be either from the deserialized invoice or from the serialized [`RawBolt11Invoice`].
pub const SignedRawBolt11Invoice = struct {
    /// The raw invoice that the signature belongs to
    raw_invoice: RawBolt11Invoice,

    /// Hash of the [`RawBolt11Invoice`] that will be used to check the signature.
    ///
    /// * if the `SignedRawBolt11Invoice` was deserialized the hash is of from the original encoded form,
    /// since it's not guaranteed that encoding it again will lead to the same result since integers
    /// could have been encoded with leading zeroes etc.
    /// * if the `SignedRawBolt11Invoice` was constructed manually the hash will be the calculated hash
    /// from the [`RawBolt11Invoice`]
    hash: [32]u8,

    /// signature of the payment request
    signature: Bolt11InvoiceSignature,

    pub fn deinit(self: @This()) void {
        self.raw_invoice.deinit();
    }

    pub fn fromStr(allocator: std.mem.Allocator, s: []const u8) !SignedRawBolt11Invoice {
        const hrp, const data, const variant = try bech32.decode(allocator, s);
        defer hrp.deinit();
        defer data.deinit();

        if (variant == .bech32m) {
            // Consider Bech32m addresses to be "Invalid Checksum", since that is what we'd get if
            // we didn't support Bech32m (which lightning does not use).
            return error.InvalidChecksum;
        }

        if (data.items.len < 104) return error.TooShortDataPart;

        // rawhrp parse
        const raw_hrp = try RawHrp.fromStr(hrp.items);

        var data_part = try RawDataPart.fromBase32(allocator, data.items[0 .. data.items.len - 104]);
        errdefer data_part.deinit();

        const hash_parts = try RawBolt11Invoice.hashFromParts(allocator, hrp.items, data.items[0 .. data.items.len - 104][0..]);

        return .{
            .signature = try Bolt11InvoiceSignature.fromBase32(allocator, data.items[data.items.len - 104 ..]),
            .hash = hash_parts,
            .raw_invoice = .{
                .hrp = raw_hrp,
                .data = data_part,
            },
        };
    }
};

pub const States = enum {
    start,
    parse_l,
    parse_n,
    parse_currency_prefix,
    parse_amount_number,
    parse_amount_si_prefix,

    fn nextState(self: @This(), read_byte: u8) errors.Bolt11ParseError!States {
        // checking if symbol is not ascii
        if (!std.ascii.isAscii(read_byte)) return errors.Bolt11ParseError.MalformedHRP;

        return switch (self) {
            .start => if (read_byte == 'l') .parse_l else errors.Bolt11ParseError.MalformedHRP,
            .parse_l => if (read_byte == 'n') .parse_n else errors.Bolt11ParseError.MalformedHRP,
            .parse_n => if (!std.ascii.isDigit(read_byte)) .parse_currency_prefix else .parse_amount_number,
            .parse_currency_prefix => if (!std.ascii.isDigit(read_byte)) .parse_currency_prefix else .parse_amount_number,

            .parse_amount_number => if (std.ascii.isDigit(read_byte))
                .parse_amount_number
            else if (std.mem.lastIndexOfScalar(u8, "munp", read_byte) != null)
                .parse_amount_si_prefix
            else
                errors.Bolt11ParseError.UnknownSiPrefix,

            .parse_amount_si_prefix => errors.Bolt11ParseError.UnknownSiPrefix,
        };
    }

    fn isFinal(self: @This()) bool {
        return !(self == .parse_l or self == .parse_n);
    }
};

pub const StateMachine = struct {
    state: States = .start,
    position: usize = 0,
    currency_prefix: ?struct { usize, usize } = null,
    amount_number: ?struct { usize, usize } = null,
    amount_si_prefix: ?struct { usize, usize } = null,

    fn updateRange(range: *?struct { usize, usize }, position: usize) void {
        const new_range: struct { usize, usize } = if (range.*) |r| .{ r[0], r[1] + 1 } else .{ position, position + 1 };

        range.* = new_range;
    }

    fn step(self: *StateMachine, c: u8) errors.Bolt11ParseError!void {
        const next_state = try self.state.nextState(c);

        switch (next_state) {
            .parse_currency_prefix => StateMachine.updateRange(&self.currency_prefix, self.position),
            .parse_amount_number => StateMachine.updateRange(&self.amount_number, self.position),
            .parse_amount_si_prefix => StateMachine.updateRange(&self.amount_si_prefix, self.position),
            else => {},
        }

        self.position += 1;
        self.state = next_state;
    }

    fn isFinal(self: *const StateMachine) bool {
        return self.state.isFinal();
    }

    /// parseHrp - not allocating data, result is pointing on input!
    pub fn parseHrp(input: []const u8) errors.Bolt11ParseError!struct { []const u8, []const u8, []const u8 } {
        var sm = StateMachine{};
        for (input) |c| try sm.step(c);

        if (!sm.isFinal()) return errors.Bolt11ParseError.MalformedHRP;

        return .{
            if (sm.currency_prefix) |v| input[v[0]..v[1]] else "",
            if (sm.amount_number) |v| input[v[0]..v[1]] else "",
            if (sm.amount_si_prefix) |v| input[v[0]..v[1]] else "",
        };
    }
};

/// Enum representing the crypto currencies (or networks) supported by this library
pub const Currency = enum {
    /// Bitcoin mainnet
    bitcoin,

    /// Bitcoin testnet
    bitcoin_testnet,

    /// Bitcoin regtest
    regtest,

    /// Bitcoin simnet
    simnet,

    /// Bitcoin signet
    signet,

    pub fn fromString(currency_prefix: []const u8) errors.Bolt11ParseError!Currency {
        const convert =
            std.StaticStringMap(Currency).initComptime(.{
            .{ "bc", Currency.bitcoin },
            .{ "tb", Currency.bitcoin_testnet },
            .{ "bcrt", Currency.regtest },
            .{ "sb", Currency.simnet },
            .{ "tbs", Currency.signet },
        });

        return convert.get(currency_prefix) orelse errors.Bolt11ParseError.UnknownCurrency;
    }
};

/// SI prefixes for the human readable part
pub const SiPrefix = enum {
    /// 10^-3
    milli,
    /// 10^-6
    micro,
    /// 10^-9
    nano,
    /// 10^-12
    pico,

    /// Returns the multiplier to go from a BTC value to picoBTC implied by this SiPrefix.
    /// This is effectively 10^12 * the prefix multiplier
    pub fn multiplier(self: SiPrefix) u64 {
        return switch (self) {
            .milli => 1_000_000_000,
            .micro => 1_000_000,
            .nano => 1_000,
            .pico => 1,
        };
    }

    /// Returns all enum variants of `SiPrefix` sorted in descending order of their associated
    /// multiplier.
    ///
    /// This is not exported to bindings users as we don't yet support a slice of enums, and also because this function
    /// isn't the most critical to expose.
    pub fn valuesDesc() [4]SiPrefix {
        return .{ .milli, .micro, .nano, .pico };
    }

    pub fn fromString(currency_prefix: []const u8) errors.Bolt11ParseError!SiPrefix {
        if (currency_prefix.len == 0) return errors.Bolt11ParseError.UnknownSiPrefix;
        return switch (currency_prefix[0]) {
            'm' => .milli,
            'u' => .micro,
            'n' => .nano,
            'p' => .pico,
            else => errors.Bolt11ParseError.UnknownSiPrefix,
        };
    }
};

/// Data of the [`RawBolt11Invoice`] that is encoded in the human readable part.
///
/// This is not exported to bindings users as we don't yet support `Option<Enum>`
pub const RawHrp = struct {
    /// The currency deferred from the 3rd and 4th character of the bech32 transaction
    currency: Currency,

    /// The amount that, multiplied by the SI prefix, has to be payed
    raw_amount: ?u64,

    /// SI prefix that gets multiplied with the `raw_amount`
    si_prefix: ?SiPrefix,

    pub fn fromStr(hrp: []const u8) !RawHrp {
        const parts = try StateMachine.parseHrp(hrp);

        const currency = try Currency.fromString(parts[0]);

        const amount: ?u64 = if (parts[1].len > 0) try std.fmt.parseInt(u64, parts[1], 10) else null;

        const si_prefix: ?SiPrefix = if (parts[2].len == 0) null else v: {
            const si = try SiPrefix.fromString(parts[2]);

            if (amount) |amt| {
                _ = std.math.mul(u64, amt, si.multiplier()) catch return errors.Bolt11ParseError.IntegerOverflowError;
            }

            break :v si;
        };

        return .{
            .currency = currency,
            .raw_amount = amount,
            .si_prefix = si_prefix,
        };
    }
};

/// The number of bits used to represent timestamps as defined in BOLT 11.
const TIMESTAMP_BITS: usize = 35;

/// The maximum timestamp as [`Duration::as_secs`] since the Unix epoch allowed by [`BOLT 11`].
///
/// [BOLT 11]: https://github.com/lightning/bolts/blob/master/11-payment-encoding.md
pub const MAX_TIMESTAMP: u64 = (1 << TIMESTAMP_BITS) - 1;

/// Default expiry time as defined by [BOLT 11].
///
/// [BOLT 11]: https://github.com/lightning/bolts/blob/master/11-payment-encoding.md
pub const DEFAULT_EXPIRY_TIME: u64 = 3600;

/// Default minimum final CLTV expiry as defined by [BOLT 11].
///
/// Note that this is *not* the same value as rust-lightning's minimum CLTV expiry, which is
/// provided in [`MIN_FINAL_CLTV_EXPIRY_DELTA`].
///
/// [BOLT 11]: https://github.com/lightning/bolts/blob/master/11-payment-encoding.md
/// [`MIN_FINAL_CLTV_EXPIRY_DELTA`]: lightning::ln::channelmanager::MIN_FINAL_CLTV_EXPIRY_DELTA
pub const DEFAULT_MIN_FINAL_CLTV_EXPIRY_DELTA: u64 = 18;

/// Data of the [`RawBolt11Invoice`] that is encoded in the data part
pub const RawDataPart = struct {
    /// generation time of the invoice
    timestamp: u64,

    /// tagged fields of the payment request
    tagged_fields: std.ArrayList(RawTaggedField),

    pub fn deinit(self: RawDataPart) void {
        for (self.tagged_fields.items) |f| f.deinit();

        self.tagged_fields.deinit();
    }

    fn fromBase32(allocator: std.mem.Allocator, data: []const u5) !RawDataPart {
        if (data.len < 7) return errors.Bolt11ParseError.TooShortDataPart;

        const timestamp: u64 = parseUintBe(u64, data[0..7][0..]) orelse @panic("7*5bit < 64bit, no overflow possible");

        const tagged = try parseTaggedParts(allocator, data[7..]);
        errdefer tagged.deinit();

        return .{
            .timestamp = timestamp,
            .tagged_fields = tagged,
        };
    }
};

fn parseUintBe(comptime T: type, digits: []const u5) ?T {
    var res: T = 0;
    for (digits) |d| {
        res = std.math.mul(T, res, 32) catch return null;
        res = std.math.add(T, res, d) catch return null;
    }

    return res;
}

fn parseTaggedParts(allocator: std.mem.Allocator, _data: []const u5) !std.ArrayList(RawTaggedField) {
    var parts = std.ArrayList(RawTaggedField).init(allocator);
    errdefer parts.deinit();
    errdefer {
        for (parts.items) |*p| {
            p.deinit();
        }
    }

    var data = _data;

    while (data.len > 0) {
        if (data.len < 3) {
            return errors.Bolt11ParseError.UnexpectedEndOfTaggedFields;
        }

        // Ignore tag at data[0], it will be handled in the TaggedField parsers and
        // parse the length to find the end of the tagged field's data
        const len = parseUintBe(u16, data[1..3][0..]) orelse @panic("can't overflow");
        const last_element = 3 + len;

        if (data.len < last_element) {
            return errors.Bolt11ParseError.UnexpectedEndOfTaggedFields;
        }

        // Get the tagged field's data slice
        const field = data[0..last_element][0..];

        // Set data slice to remaining data
        data = data[last_element..];

        if (TaggedField.fromBase32(allocator, field)) |f| {
            errdefer f.deinit();
            try parts.append(.{ .known = f });
        } else |err| switch (err) {
            error.Skip => {
                var un = try std.ArrayList(u5).initCapacity(allocator, field.len);
                errdefer un.deinit();

                un.appendSliceAssumeCapacity(field);

                try parts.append(.{ .unknown = un });
                continue;
            },
            else => return err,
        }
    }

    return parts;
}

/// Tagged field which may have an unknown tag
///
/// This is not exported to bindings users as we don't currently support TaggedField
pub const RawTaggedField = union(enum) {
    /// Parsed tagged field with known tag
    known: TaggedField,
    /// tagged field which was not parsed due to an unknown tag or undefined field semantics
    unknown: std.ArrayList(u5),

    pub fn deinit(self: RawTaggedField) void {
        switch (self) {
            .unknown => |a| a.deinit(),
            .known => |t| t.deinit(),
        }
    }
};

pub const Sha256 = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// Tagged field with known tag
///
/// For descriptions of the enum values please refer to the enclosed type's docs.
///
/// This is not exported to bindings users as we don't yet support enum variants with the same name the struct contained
/// in the variant.
pub const TaggedField = union(enum) {
    payment_hash: Sha256,
    description: std.ArrayList(u8),
    // payee_pub_key: core.secp256k1.PublicKey,
    // description_hash: Sha256,
    // expiry_time: u64,

    // min_final_cltv_expiry_delta: u64,
    // fallback: Fallback,

    // PrivateRoute(PrivateRoute),
    // PaymentSecret(PaymentSecret),
    // PaymentMetadata(Vec<u8>),
    // Features(Bolt11InvoiceFeatures),

    pub fn deinit(self: TaggedField) void {
        switch (self) {
            .description => |v| v.deinit(),
            else => {},
        }
    }

    fn fromBase32(allocator: std.mem.Allocator, field: []const u5) !TaggedField {
        if (field.len < 3) return errors.Bolt11ParseError.UnexpectedEndOfTaggedFields;

        const tag = field[0];
        const field_data = field[3..];

        return switch (@as(u8, tag)) {
            constants.TAG_PAYMENT_HASH => v: {
                if (field_data.len != 52) {
                    // "A reader MUST skip over […] a p, [or] h […] field that does not have data_length 52 […]."

                    return errors.Bolt11ParseError.Skip;
                } else {
                    const d = try bech32.arrayListFromBase32(allocator, field_data);
                    defer d.deinit();

                    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

                    hasher.update(d.items);

                    break :v TaggedField{ .payment_hash = hasher.finalResult() };
                }
            },
            constants.TAG_DESCRIPTION => v: {
                const bytes = try bech32.arrayListFromBase32(allocator, field_data);
                errdefer bytes.deinit();

                if (bytes.items.len > 639) return error.DescriptionDecodeError;

                break :v TaggedField{ .description = bytes };
            },
            else => return error.Skip,
        };
    }
};

/// Fallback address in case no LN payment is possible
pub const Fallback = union(enum) {
    program: []const u8,
    // ripemd160 hash
    pub_key_hash: [20]u8,
    // ripemd160 hash
    script_hash: [20]u8,
};

test "decode" {
    const str = "lnbc1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq8rkx3yf5tcsyz3d73gafnh3cax9rn449d9p5uxz9ezhhypd0elx87sjle52x86fux2ypatgddc6k63n7erqz25le42c4u4ecky03ylcqca784w";

    const v = try SignedRawBolt11Invoice.fromStr(std.testing.allocator, str);
    defer v.deinit();

    try std.testing.expectEqual(v.raw_invoice.hrp, RawHrp{ .currency = .bitcoin, .raw_amount = null, .si_prefix = null });

    // checking data
    try std.testing.expectEqual(v.raw_invoice.data.timestamp, 1496314658);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    var buf: [100]u8 = undefined;

    hasher.update(try std.fmt.hexToBytes(&buf, "0001020304050607080900010203040506070809000102030405060708090102"));

    try std.testing.expectEqual(hasher.finalResult(), v.raw_invoice.getKnownTag(.payment_hash));

    try std.testing.expectEqualSlices(u8, "Please consider supporting this project", v.raw_invoice.getKnownTag(.description).?.items);

    // TODO: add other tags

    // end checking data

    try std.testing.expectEqual(.{ 0xc3, 0xd4, 0xe8, 0x3f, 0x64, 0x6f, 0xa7, 0x9a, 0x39, 0x3d, 0x75, 0x27, 0x7b, 0x1d, 0x85, 0x8d, 0xb1, 0xd1, 0xf7, 0xab, 0x71, 0x37, 0xdc, 0xb7, 0x83, 0x5d, 0xb2, 0xec, 0xd5, 0x18, 0xe1, 0xc9 }, v.hash);

    try std.testing.expectEqual(Bolt11InvoiceSignature{
        .value = try core.secp256k1.RecoverableSignature.fromCompact(
            &.{ 0x38, 0xec, 0x68, 0x91, 0x34, 0x5e, 0x20, 0x41, 0x45, 0xbe, 0x8a, 0x3a, 0x99, 0xde, 0x38, 0xe9, 0x8a, 0x39, 0xd6, 0xa5, 0x69, 0x43, 0x4e, 0x18, 0x45, 0xc8, 0xaf, 0x72, 0x05, 0xaf, 0xcf, 0xcc, 0x7f, 0x42, 0x5f, 0xcd, 0x14, 0x63, 0xe9, 0x3c, 0x32, 0x88, 0x1e, 0xad, 0x0d, 0x6e, 0x35, 0x6d, 0x46, 0x7e, 0xc8, 0xc0, 0x25, 0x53, 0xf9, 0xaa, 0xb1, 0x5e, 0x57, 0x38, 0xb1, 0x1f, 0x12, 0x7f },
            try core.secp256k1.RecoveryId.fromI32(0),
        ),
    }, v.signature);
}

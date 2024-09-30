const std = @import("std");
const constants = @import("constants.zig");
const bitcoin_primitives = @import("bitcoin-primitives");
const bip32 = bitcoin_primitives.bips.bip32;
const secp256k1 = bitcoin_primitives.secp256k1;
const bech32 = bitcoin_primitives.bech32;
const errors = @import("error.zig");
const ser = @import("ser.zig");

const Ripemd160 = bitcoin_primitives.hashes.Ripemd160;
const Features = @import("features.zig");
const RecoverableSignature = secp256k1.ecdsa.RecoverableSignature;
const Message = secp256k1.Message;
const Writer = ser.Writer;
pub const InvoiceBuilder = @import("builder.zig");

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
    const Self = @This();

    signed_invoice: SignedRawBolt11Invoice,

    pub fn deinit(self: *Self) void {
        self.signed_invoice.deinit();
    }

    pub fn fromStr(allocator: std.mem.Allocator, s: []const u8) !Bolt11Invoice {
        const signed = try SignedRawBolt11Invoice.fromStr(allocator, s);

        return Bolt11Invoice.fromSigned(signed);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const str = try std.json.innerParse([]const u8, allocator, source, options);

        return Bolt11Invoice.fromStr(allocator, str) catch return error.UnexpectedToken;
    }

    pub fn fromSigned(signed_invoice: SignedRawBolt11Invoice) !Self {
        const invoice = Bolt11Invoice{ .signed_invoice = signed_invoice };

        // TODO
        //       invoice.check_field_counts()?;
        // invoice.check_feature_bits()?;
        // invoice.check_signature()?;
        // invoice.check_amount()?;

        return invoice;
    }

    /// Returns the amount if specified in the invoice as pico BTC.
    fn amountPicoBtc(self: Self) ?u64 {
        return self.signed_invoice.raw_invoice.amountPicoBtc();
    }

    /// Check that amount is a whole number of millisatoshis
    fn checkAmount(self: Self) !void {
        if (self.amountPicoBtc()) |amount_pico_btc| {
            if (amount_pico_btc % 10 != 0) {
                return error.ImpreciseAmount;
            }
        }
    }

    /// Returns the amount if specified in the invoice as millisatoshis.
    pub fn amountMilliSatoshis(self: Self) ?u64 {
        return if (self.signed_invoice.raw_invoice.amountPicoBtc()) |v| v / 10 else null;
    }

    /// Returns the hash to which we will receive the preimage on completion of the payment
    pub fn paymentHash(self: Self) Sha256Hash {
        return self.signed_invoice.raw_invoice.getKnownTag(.payment_hash) orelse @panic("expected payment_hash");
    }

    /// Returns the `Bolt11Invoice`'s timestamp as a seconds since the Unix epoch
    pub fn secondsSinceEpoch(self: *const Self) u64 {
        return self.signed_invoice.raw_invoice.data.timestamp;
    }

    /// Returns whether the expiry time would pass at the given point in time.
    /// `at_time` is the timestamp as a seconds since the Unix epoch.
    pub fn wouldExpire(self: *const Bolt11Invoice, at_time: u64) bool {
        return (std.math.add(u64, self.secondsSinceEpoch(), self.expiryTime()) catch std.math.maxInt(u64)) < at_time;
    }

    /// Returns the invoice's expiry time, if present, otherwise [`default_expiry_time`] in seconds.
    pub fn expiryTime(self: *const Self) u64 {
        return v: {
            break :v (self.signed_invoice.raw_invoice.getKnownTag(.expiry_time) orelse break :v default_expiry_time).inner;
        };
    }

    /// Returns the Duration since the Unix epoch at which the invoice expires.
    /// Returning None if overflow occurred.
    pub fn expiresAtSecs(self: *const Self) ?u64 {
        return std.math.add(u64, self.secondsSinceEpoch(), self.expiryTime()) catch null;
    }
};

/// Represents an syntactically correct [`Bolt11Invoice`] for a payment on the lightning network,
/// but without the signature information.
/// Decoding and encoding should not lead to information loss but may lead to different hashes.
///
/// For methods without docs see the corresponding methods in [`Bolt11Invoice`].
pub const RawBolt11Invoice = struct {
    const Self = @This();
    /// human readable part
    hrp: RawHrp,

    /// data part
    data: RawDataPart,

    pub fn deinit(self: *RawBolt11Invoice) void {
        self.data.deinit();
    }

    /// Calculate the hash of the encoded `RawBolt11Invoice` which should be signed.
    pub fn signableHash(self: *const Self, gpa: std.mem.Allocator) ![32]u8 {
        const hrp_bytes = try self.hrp.toStr(gpa);
        defer gpa.free(hrp_bytes);

        const data_without_sign = try self.data.toBase32(gpa);
        defer gpa.free(data_without_sign);

        return try RawBolt11Invoice.hashFromParts(gpa, hrp_bytes, data_without_sign);
    }

    /// Signs the invoice using the supplied `sign_method`. This function MAY fail with an error of
    /// type `E`. Since the signature of a [`SignedRawBolt11Invoice`] is not required to be valid there
    /// are no constraints regarding the validity of the produced signature.
    ///
    /// This is not exported to bindings users as we don't currently support passing function pointers into methods
    /// explicitly.
    pub fn sign(self: *const Self, gpa: std.mem.Allocator, sign_method: *const fn (Message) anyerror!RecoverableSignature) !SignedRawBolt11Invoice {
        const raw_hash = try self.signableHash(gpa);
        const hash = Message.fromDigest(raw_hash);
        const signature = try sign_method(hash);

        return .{
            .raw_invoice = self.*,
            .hash = raw_hash,
            .signature = .{ .value = signature },
        };
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
    value: secp256k1.ecdsa.RecoverableSignature,

    pub fn fromBase32(allocator: std.mem.Allocator, sig: []const u5) !Bolt11InvoiceSignature {
        if (sig.len != 104) return errors.Bolt11ParseError.InvalidSliceLength;

        const recoverable_signature_bytes = try bech32.arrayListFromBase32(allocator, sig);
        defer recoverable_signature_bytes.deinit();

        const signature = recoverable_signature_bytes.items[0..64];
        const recovery_id = try secp256k1.ecdsa.RecoveryId.fromI32(recoverable_signature_bytes.items[64]);

        return .{ .value = try secp256k1.ecdsa.RecoverableSignature.fromCompact(signature, recovery_id) };
    }

    fn writeBase32(self: *const Bolt11InvoiceSignature, writer: *Writer) !void {
        var converter = ser.BytesToBase32.init(writer);
        const recovery_id, const signature = self.value.serializeCompact();

        try converter.append(&signature);
        try converter.appendU8(@intCast(recovery_id.toI32()));
        try converter.finalize();
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

    pub fn deinit(self: *@This()) void {
        self.raw_invoice.deinit();
    }
    /// Converting [`SignedRawBolt11Invoice`] to string, caller own result
    /// and responsible to dealloc
    pub fn toStrAlloc(self: *const SignedRawBolt11Invoice, gpa: std.mem.Allocator) ![]u8 {
        const hrp_bytes = try self.raw_invoice.hrp.toStr(gpa);
        defer gpa.free(hrp_bytes);

        var data = v: {
            var data = std.ArrayList(u5).init(gpa);
            errdefer data.deinit();

            var writer = Writer.init(&data);
            // write raw invoice data
            try self.raw_invoice.data.writeBase32(&writer);

            // write signature
            try self.signature.writeBase32(&writer);

            break :v data;
        };
        defer data.deinit();

        var result = try bech32.encode(gpa, hrp_bytes, data.items, .bech32);
        errdefer result.deinit();

        return try result.toOwnedSlice();
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

    pub fn toStr(self: Currency) []const u8 {
        return switch (self) {
            .bitcoin => "bc",
            .bitcoin_testnet => "tb",
            .regtest => "bcrt",
            .simnet => "sb",
            .signet => "tbs",
        };
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

    pub fn toStr(self: SiPrefix) u8 {
        return switch (self) {
            .milli => 'm',
            .micro => 'u',
            .nano => 'n',
            .pico => 'p',
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

    /// Converting RawHrp to string, caller own result and responsible to dealloc
    pub fn toStr(self: *const RawHrp, gpa: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(gpa);
        errdefer result.deinit();

        try result.appendSlice("ln");

        // writing currency
        try result.appendSlice(self.currency.toStr());

        if (self.raw_amount) |amount| {
            try std.fmt.format(result.writer(), "{d}", .{amount});
        }

        if (self.si_prefix) |si| {
            try result.append(si.toStr());
        }
        return try result.toOwnedSlice();
    }

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
pub const default_expiry_time: u64 = 3600;

/// Default minimum final CLTV expiry as defined by [BOLT 11].
///
/// Note that this is *not* the same value as rust-lightning's minimum CLTV expiry, which is
/// provided in [`MIN_FINAL_CLTV_EXPIRY_DELTA`].
///
/// [BOLT 11]: https://github.com/lightning/bolts/blob/master/11-payment-encoding.md
/// [`MIN_FINAL_CLTV_EXPIRY_DELTA`]: lightning::ln::channelmanager::MIN_FINAL_CLTV_EXPIRY_DELTA
pub const DEFAULT_MIN_FINAL_CLTV_EXPIRY_DELTA: u64 = 18;

pub fn writeU64Base32(v: u64, writer: *const Writer, comptime target_len: usize) !void {
    try ser.tryStretchWriter(writer, (ser.encodeIntBeBase32(v) catch @panic("Can't be longer target_len")).constSlice(), target_len);
}

/// Data of the [`RawBolt11Invoice`] that is encoded in the data part
pub const RawDataPart = struct {
    /// generation time of the invoice
    timestamp: u64,

    /// tagged fields of the payment request
    tagged_fields: std.ArrayList(RawTaggedField),

    pub fn deinit(self: *RawDataPart) void {
        for (self.tagged_fields.items) |*f| f.deinit();

        self.tagged_fields.deinit();
    }

    fn writeBase32(self: *const RawDataPart, writer: *const Writer) !void {
        // encode timestamp
        try writeU64Base32(self.timestamp, writer, 7);

        // encode tagged fields
        for (self.tagged_fields.items) |tagged_field| {
            try tagged_field.writeBase32(writer);
        }

        return;
    }

    /// caller own result, so responsible to deallocate
    fn toBase32(self: RawDataPart, gpa: std.mem.Allocator) ![]u5 {
        var r = std.ArrayList(u5).init(gpa);
        errdefer r.deinit();

        const writer = Writer.init(&r);

        try self.writeBase32(&writer);
        return try r.toOwnedSlice();
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

        if (TaggedField.fromBase32(allocator, field)) |*f| {
            errdefer @constCast(f).deinit();

            try parts.append(.{ .known = f.* });
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

    pub fn deinit(self: *RawTaggedField) void {
        switch (self.*) {
            .unknown => |a| a.deinit(),
            .known => |*t| t.deinit(),
        }
    }

    pub fn writeBase32(self: *const RawTaggedField, writer: *const Writer) !void {
        switch (self.*) {
            .known => |f| {
                try f.writeBase32(writer);
            },
            .unknown => |f| {
                try writer.write(f.items);
            },
        }
    }
};

fn calculateBase32Len(size: usize) usize {
    const bits = size * 8;

    return if (bits % 5 == 0)
        bits / 5
    else
        bits / 5 + 1;
}

fn writeSliceBase32(self: []const u8, writer: *const Writer) !void {
    // Amount of bits left over from last round, stored in buffer.
    var buffer_bits: u32 = 0;
    // Holds all unwritten bits left over from last round. The bits are stored beginning from
    // the most significant bit. E.g. if buffer_bits=3, then the byte with bits a, b and c will
    // look as follows: [a, b, c, 0, 0, 0, 0, 0]
    var buffer: u8 = 0;

    for (self) |b| {
        // Write first u5 if we have to write two u5s this round. That only happens if the
        // buffer holds too many bits, so we don't have to combine buffer bits with new bits
        // from this rounds byte.
        if (buffer_bits >= 5) {
            try writer.writeOne(@truncate((buffer & 0b1111_1000) >> 3));
            buffer <<= 5;
            buffer_bits -= 5;
        }

        // Combine all bits from buffer with enough bits from this rounds byte so that they fill
        // a u5. Save reamining bits from byte to buffer.
        const from_buffer = buffer >> 3;
        const from_byte = std.math.shr(u8, b, 3 + buffer_bits); // buffer_bits <= 4

        try writer.writeOne(@truncate(from_buffer | from_byte));
        buffer = std.math.shl(u8, b, 5 - buffer_bits);
        buffer_bits += 3;
    }

    // There can be at most two u5s left in the buffer after processing all bytes, write them.
    if (buffer_bits >= 5) {
        try writer.writeOne(@truncate((buffer & 0b1111_1000) >> 3));
        buffer <<= 5;
        buffer_bits -= 5;
    }

    if (buffer_bits != 0) {
        try writer.writeOne(@truncate(buffer >> 3));
    }
}

pub const Sha256Hash = struct {
    inner: [Sha256.digest_length]u8,

    fn fromBase32(allocator: std.mem.Allocator, field_data: []const u5) !Sha256Hash {
        // "A reader MUST skip over […] a n […] field that does not have data_length 53 […]."
        if (field_data.len != 52) return errors.Bolt11ParseError.Skip;

        // TODO rewrite on bounded array ,start from bech32
        const data_bytes = try bech32.arrayListFromBase32(allocator, field_data);
        defer data_bytes.deinit();

        return .{
            .inner = data_bytes.items[0..Sha256.digest_length].*,
        };
    }

    fn base32Len(_: *const Sha256Hash) usize {
        return comptime calculateBase32Len(std.crypto.hash.sha2.Sha256.digest_length);
    }

    fn writeBase32(self: *const Sha256Hash, w: *const Writer) !void {
        try writeSliceBase32(&self.inner, w);
    }
};

pub const PayeePubKey = struct {
    inner: secp256k1.PublicKey,

    fn fromBase32(allocator: std.mem.Allocator, field_data: []const u5) !PayeePubKey {
        // "A reader MUST skip over […] a n […] field that does not have data_length 53 […]."
        if (field_data.len != 53) return errors.Bolt11ParseError.Skip;

        // TODO rewrite on bounded array ,start from bech32
        const data_bytes = try bech32.arrayListFromBase32(allocator, field_data);
        defer data_bytes.deinit();

        const pub_key = try secp256k1.PublicKey.fromSlice(data_bytes.items);

        return .{
            .inner = pub_key,
        };
    }

    fn writeBase32(self: *const PayeePubKey, writer: *const Writer) !void {
        try writeSliceBase32(&self.inner.serialize(), writer);
    }

    fn base32Len(_: *const PayeePubKey) usize {
        return comptime calculateBase32Len(secp256k1.constants.public_key_size);
    }
};

pub const Uint64 = struct {
    inner: u64,

    fn fromBase32(field_data: []const u5) !Uint64 {
        const val = parseUintBe(u64, field_data) orelse return errors.Bolt11ParseError.IntegerOverflowError;

        return .{
            .inner = val,
        };
    }

    fn writeBase32(self: Uint64, writer: *const Writer) !void {
        const encoded = try ser.encodeIntBeBase32(self.inner);

        try writer.write(encoded.constSlice());
    }

    fn base32Len(self: Uint64) usize {
        return ser.encodedIntBeBase32Size(self.inner);
    }
};

pub const PaymentSecret = struct {
    inner: [32]u8,

    fn fromBase32(allocator: std.mem.Allocator, field_data: []const u5) !PaymentSecret {
        // "A reader MUST skip over […] a n […] field that does not have data_length 53 […]."
        if (field_data.len != 52) return errors.Bolt11ParseError.Skip;

        // TODO rewrite on bounded array ,start from bech32
        const data_bytes = try bech32.arrayListFromBase32(allocator, field_data);
        defer data_bytes.deinit();

        return .{
            .inner = data_bytes.items[0..32].*,
        };
    }

    fn writeBase32(self: *const PaymentSecret, writer: *const Writer) !void {
        try writeSliceBase32(&self.inner, writer);
    }

    fn base32Len(_: *const PaymentSecret) usize {
        return calculateBase32Len(32);
    }
};

pub const Description = struct {
    inner: std.ArrayList(u8),

    pub fn deinit(self: Description) void {
        self.inner.deinit();
    }

    pub fn base32Len(self: Description) usize {
        return calculateBase32Len(self.inner.items.len);
    }

    pub fn writeBase32(self: Description, writer: *const Writer) !void {
        try writeSliceBase32(self.inner.items, writer);
    }
};

/// Tagged field with known tag
///
/// For descriptions of the enum values please refer to the enclosed type's docs.
///
/// This is not exported to bindings users as we don't yet support enum variants with the same name the struct contained
/// in the variant.
pub const TaggedField = union(enum) {
    payment_hash: Sha256Hash,
    description: Description,
    payee_pub_key: PayeePubKey,
    description_hash: Sha256Hash,
    expiry_time: Uint64,
    min_final_cltv_expiry_delta: Uint64,
    fallback: Fallback,

    // PrivateRoute(PrivateRoute),
    payment_secret: PaymentSecret,
    payment_metadata: std.ArrayList(u8),
    features: Features,

    pub fn deinit(self: *TaggedField) void {
        switch (self.*) {
            .description => |v| v.deinit(),
            .payment_metadata => |v| v.deinit(),
            .features => |*v| v.deinit(),

            else => {},
        }
    }

    pub fn format(
        self: TaggedField,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        switch (self) {
            .payment_hash => |hash| {
                try writer.print(".payment_hash = ({any})", .{std.fmt.fmtSliceHexLower(&hash.inner)});
            },
            .description => |ds| {
                try writer.print(".description = ({s})", .{ds.inner.items});
            },
            .payee_pub_key => |ppk| {
                try writer.print(".ppk = ({s})", .{ppk.inner.toString()});
            },
            .description_hash => |hash| {
                try writer.print(".description_hash = ({any})", .{std.fmt.fmtSliceHexLower(&hash.inner)});
            },
            // TODO other
            else => |f| {
                try writer.print("{any}", .{std.meta.activeTag(f)});
            },
        }
    }

    /// Writes a tagged field: tag, length and data. `tag` should be in `0..32` otherwise the
    /// function will panic.
    fn writeBase32(self: *const TaggedField, writer: *const Writer) !void {
        const write_tagged_field = (struct {
            fn write(w: *const Writer, tag: u8, payload: anytype) !void {
                switch (@TypeOf(payload)) {
                    []const u8, []u8 => {
                        // Every tagged field data can be at most 1023 bytes long.
                        std.debug.assert(payload.len < 1024);

                        try w.writeOne(@truncate(tag));

                        try ser.tryStretchWriter(
                            w,
                            (try ser.encodeIntBeBase32(calculateBase32Len(payload.len))).constSlice(),
                            2,
                        );

                        try writeSliceBase32(payload, w);
                    },
                    else => {
                        const len = payload.base32Len();

                        // Every tagged field data can be at most 1023 bytes long.
                        std.debug.assert(len < 1024);

                        try w.writeOne(@truncate(tag));

                        try ser.tryStretchWriter(
                            w,
                            (try ser.encodeIntBeBase32(len)).constSlice(),
                            2,
                        );

                        try payload.writeBase32(w);
                    },
                }
            }
        }).write;

        switch (self.*) {
            .payment_hash => |hash| {
                try write_tagged_field(writer, constants.TAG_PAYMENT_HASH, hash);
            },
            .description => |ds| {
                try write_tagged_field(writer, constants.TAG_DESCRIPTION, ds);
            },
            .payee_pub_key => |ppk| {
                try write_tagged_field(writer, constants.TAG_PAYEE_PUB_KEY, ppk);
            },
            .description_hash => |hash| {
                try write_tagged_field(writer, constants.TAG_DESCRIPTION_HASH, hash);
            },
            .expiry_time => |et| {
                try write_tagged_field(writer, constants.TAG_EXPIRY_TIME, et);
            },
            .min_final_cltv_expiry_delta => |cltv| {
                try write_tagged_field(writer, constants.TAG_MIN_FINAL_CLTV_EXPIRY_DELTA, cltv);
            },
            .fallback => |fb| {
                try write_tagged_field(writer, constants.TAG_FALLBACK, fb);
            },
            .payment_secret => |ps| {
                try write_tagged_field(writer, constants.TAG_PAYMENT_SECRET, ps);
            },
            .payment_metadata => |pm| {
                try write_tagged_field(writer, constants.TAG_PAYMENT_METADATA, pm.items);
            },
            // TODO implement other
            // features: Features,

            else => {},
        }
    }

    fn fromBase32(allocator: std.mem.Allocator, field: []const u5) !TaggedField {
        if (field.len < 3) return errors.Bolt11ParseError.UnexpectedEndOfTaggedFields;

        const tag = field[0];
        const field_data = field[3..];

        return switch (@as(u8, tag)) {
            constants.TAG_PAYMENT_HASH => .{
                .payment_hash = try Sha256Hash.fromBase32(allocator, field_data),
            },
            constants.TAG_DESCRIPTION => v: {
                const bytes = try bech32.arrayListFromBase32(allocator, field_data);
                errdefer bytes.deinit();

                if (bytes.items.len > 639) return error.DescriptionDecodeError;

                break :v TaggedField{
                    .description = .{
                        .inner = bytes,
                    },
                };
            },
            constants.TAG_PAYEE_PUB_KEY => .{
                .payee_pub_key = try PayeePubKey.fromBase32(allocator, field_data),
            },
            constants.TAG_DESCRIPTION_HASH => .{
                .description_hash = try Sha256Hash.fromBase32(allocator, field_data),
            },
            constants.TAG_EXPIRY_TIME => .{
                .expiry_time = try Uint64.fromBase32(field_data),
            },
            constants.TAG_MIN_FINAL_CLTV_EXPIRY_DELTA => .{
                .min_final_cltv_expiry_delta = try Uint64.fromBase32(field_data),
            },
            constants.TAG_FALLBACK => .{
                .fallback = try Fallback.fromBase32(allocator, field_data),
            },
            constants.TAG_PAYMENT_SECRET => .{
                .payment_secret = try PaymentSecret.fromBase32(allocator, field_data),
            },
            constants.TAG_PAYMENT_METADATA => .{
                .payment_metadata = try bech32.arrayListFromBase32(allocator, field_data),
            },
            constants.TAG_FEATURES => .{
                .features = try Features.fromBase32(allocator, field_data),
            },
            else => return error.Skip,
        };
    }
};

const Sha256 = std.crypto.hash.sha2.Sha256;

// TODO when bitcoin-primitives got impl of witness_version, move to it
pub const WitnessVersion = enum(u8) {
    /// Initial version of witness program. Used for P2WPKH and P2WPK outputs
    v0 = 0,
    /// Version of witness program used for Taproot P2TR outputs.
    v1 = 1,
    /// Future (unsupported) version of witness program.
    v2 = 2,
    /// Future (unsupported) version of witness program.
    v3 = 3,
    /// Future (unsupported) version of witness program.
    v4 = 4,
    /// Future (unsupported) version of witness program.
    v5 = 5,
    /// Future (unsupported) version of witness program.
    v6 = 6,
    /// Future (unsupported) version of witness program.
    v7 = 7,
    /// Future (unsupported) version of witness program.
    v8 = 8,
    /// Future (unsupported) version of witness program.
    v9 = 9,
    /// Future (unsupported) version of witness program.
    v10 = 10,
    /// Future (unsupported) version of witness program.
    v11 = 11,
    /// Future (unsupported) version of witness program.
    v12 = 12,
    /// Future (unsupported) version of witness program.
    v13 = 13,
    /// Future (unsupported) version of witness program.
    v14 = 14,
    /// Future (unsupported) version of witness program.
    v15 = 15,
    /// Future (unsupported) version of witness program.
    v16 = 16,
};

/// Fallback address in case no LN payment is possible
pub const Fallback = union(enum) {
    // SegWitProgram
    program: struct {
        version: WitnessVersion,
        program: []const u8,
    },
    // ripemd160 hash
    pub_key_hash: [20]u8,
    // ripemd160 hash
    script_hash: [20]u8,

    pub fn deinit(self: *const Fallback, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline .program => |p| gpa.free(p.program),
            else => {},
        }
    }

    fn fromBase32(allocator: std.mem.Allocator, field_data: []const u5) !Fallback {
        if (field_data.len == 0) return errors.Bolt11ParseError.UnexpectedEndOfTaggedFields;

        const version: u8 = field_data[0];

        var data_bytes = try bech32.arrayListFromBase32(allocator, field_data[1..]);
        defer data_bytes.deinit();

        switch (version) {
            0...16 => {
                if (data_bytes.items.len < 2 or data_bytes.items.len > 40) {
                    return errors.Bolt11ParseError.InvalidSegWitProgramLength;
                }

                const witness_version = try std.meta.intToEnum(WitnessVersion, version);

                return .{
                    .program = .{ .version = witness_version, .program = try data_bytes.toOwnedSlice() },
                };
            },
            17 => {
                //hash160
                return .{
                    .pub_key_hash = data_bytes.items[0..20].*,
                };
            },
            18 => {
                //hash160
                return .{
                    .script_hash = data_bytes.items[0..20].*,
                };
            },
            else => return errors.Bolt11ParseError.Skip,
        }
    }

    fn writeBase32(self: *const Fallback, writer: *const Writer) !void {
        switch (self.*) {
            .program => |p| {
                try writer.writeOne(@intCast(@intFromEnum(p.version)));
                try writeSliceBase32(p.program, writer);
            },
            .pub_key_hash => |pkh| {
                try writer.writeOne(17);
                try writeSliceBase32(&pkh, writer);
            },
            .script_hash => |sh| {
                try writer.writeOne(18);
                try writeSliceBase32(&sh, writer);
            },
        }
    }

    fn base32Len(self: *const Fallback) usize {
        return switch (self.*) {
            .program => |p| calculateBase32Len(p.program.len) + 1,
            inline .pub_key_hash, .script_hash => 33,
        };
    }
};

test "decode" {
    // test_raw_signed_invoice_deserialization from rust lightning invoice
    const str = "lnbc1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq8rkx3yf5tcsyz3d73gafnh3cax9rn449d9p5uxz9ezhhypd0elx87sjle52x86fux2ypatgddc6k63n7erqz25le42c4u4ecky03ylcqca784w";

    var v = try SignedRawBolt11Invoice.fromStr(std.testing.allocator, str);
    defer v.deinit();

    try std.testing.expectEqual(v.raw_invoice.hrp, RawHrp{ .currency = .bitcoin, .raw_amount = null, .si_prefix = null });

    // checking data
    try std.testing.expectEqual(v.raw_invoice.data.timestamp, 1496314658);

    var buf: [100]u8 = undefined;

    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buf, "0001020304050607080900010203040506070809000102030405060708090102"), &v.raw_invoice.getKnownTag(.payment_hash).?.inner);

    try std.testing.expectEqualSlices(u8, "Please consider supporting this project", v.raw_invoice.getKnownTag(.description).?.inner.items);

    // TODO: add other tags

    // end checking data

    try std.testing.expectEqual(.{ 0xc3, 0xd4, 0xe8, 0x3f, 0x64, 0x6f, 0xa7, 0x9a, 0x39, 0x3d, 0x75, 0x27, 0x7b, 0x1d, 0x85, 0x8d, 0xb1, 0xd1, 0xf7, 0xab, 0x71, 0x37, 0xdc, 0xb7, 0x83, 0x5d, 0xb2, 0xec, 0xd5, 0x18, 0xe1, 0xc9 }, v.hash);

    try std.testing.expectEqual(Bolt11InvoiceSignature{
        .value = try secp256k1.ecdsa.RecoverableSignature.fromCompact(
            &.{ 0x38, 0xec, 0x68, 0x91, 0x34, 0x5e, 0x20, 0x41, 0x45, 0xbe, 0x8a, 0x3a, 0x99, 0xde, 0x38, 0xe9, 0x8a, 0x39, 0xd6, 0xa5, 0x69, 0x43, 0x4e, 0x18, 0x45, 0xc8, 0xaf, 0x72, 0x05, 0xaf, 0xcf, 0xcc, 0x7f, 0x42, 0x5f, 0xcd, 0x14, 0x63, 0xe9, 0x3c, 0x32, 0x88, 0x1e, 0xad, 0x0d, 0x6e, 0x35, 0x6d, 0x46, 0x7e, 0xc8, 0xc0, 0x25, 0x53, 0xf9, 0xaa, 0xb1, 0x5e, 0x57, 0x38, 0xb1, 0x1f, 0x12, 0x7f },
            try secp256k1.ecdsa.RecoveryId.fromI32(0),
        ),
    }, v.signature);
}

// SERIALIZING TESTS, TODO move to separate file
test "test currency code" {
    try std.testing.expectEqualSlices(u8, "bc", Currency.toStr(.bitcoin));
    try std.testing.expectEqualSlices(u8, "tb", Currency.toStr(.bitcoin_testnet));
    try std.testing.expectEqualSlices(u8, "bcrt", Currency.toStr(.regtest));
    try std.testing.expectEqualSlices(u8, "sb", Currency.toStr(.simnet));
    try std.testing.expectEqualSlices(u8, "tbs", Currency.toStr(.signet));
}

test "test raw hrp" {
    const hrp = RawHrp{
        .currency = .bitcoin,
        .raw_amount = 100,
        .si_prefix = .micro,
    };

    const hrp_bytes = try hrp.toStr(std.testing.allocator);
    defer std.testing.allocator.free(hrp_bytes);

    try std.testing.expectEqualSlices(u8, "lnbc100u", hrp_bytes);
}

test "full serialize" {
    var hasher = Sha256.init(.{});

    hasher.update("blalblablablab");

    // test_raw_signed_invoice_deserialization from rust lightning invoice
    const str = "lnbc1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq8rkx3yf5tcsyz3d73gafnh3cax9rn449d9p5uxz9ezhhypd0elx87sjle52x86fux2ypatgddc6k63n7erqz25le42c4u4ecky03ylcqca784w";

    var v = try SignedRawBolt11Invoice.fromStr(std.testing.allocator, str);
    defer v.deinit();

    try v.raw_invoice.data.tagged_fields.append(.{ .known = .{ .payee_pub_key = .{ .inner = .{ .pk = .{ .data = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 } } } } } });

    try v.raw_invoice.data.tagged_fields.append(.{ .known = .{ .description_hash = .{
        .inner = hasher.finalResult(),
    } } });
    try v.raw_invoice.data.tagged_fields.append(.{ .known = .{ .expiry_time = .{ .inner = 123131231 } } });
    try v.raw_invoice.data.tagged_fields.append(.{ .known = .{ .min_final_cltv_expiry_delta = .{ .inner = 123131231 } } });
    try v.raw_invoice.data.tagged_fields.append(.{ .known = .{ .fallback = .{ .pub_key_hash = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 } } } });

    // payload metadata
    {
        var pm = std.ArrayList(u8).init(std.testing.allocator);
        errdefer pm.deinit();

        try pm.appendSlice("dfdfakoadsoaskfoaksdofkaoskha");

        try v.raw_invoice.data.tagged_fields.append(.{ .known = .{ .payment_metadata = pm } });
    }

    try v.raw_invoice.data.tagged_fields.append(.{ .known = .{ .fallback = .{ .pub_key_hash = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 } } } });

    const vv = try v.toStrAlloc(std.testing.allocator);
    defer std.testing.allocator.free(vv);

    // decode and expect equal
    {
        var vvv = try SignedRawBolt11Invoice.fromStr(std.testing.allocator, vv);
        defer vvv.deinit();

        const double_encoded = try vvv.toStrAlloc(std.testing.allocator);
        defer std.testing.allocator.free(double_encoded);

        try std.testing.expectEqualSlices(u8, vv, double_encoded);
    }
}

test "ln invoice" {
    const str =
        \\lnbc550n1pn04xe4sp53aqjsrd2wg58e7ve4erj8kklssaqg929uzzsdc6tzxg04jcvpa3qpp59sd92rxj89he4uzqg2d4xjcr3lvwa2pfhq3e2xxcwny6wkm024fqdpqf38xy6t5wvszs3z9f48jq5692fty253fxqrpcgcqpjrzjqdm9ng9v36em3598yqg5alyxr5afgquzmnapgqm5dd8c76ew3qgt5rpgrgqq3hcqqqqqqqlgqqqqqqqqvs9qxpqysgqjumakl745mg5djjxvtjz5n3upkz4gtsedd0vyf3a359crdcwvm7rlzkvpe87tnhphjjfp8mly79j0wz4hrrst68mfaz96lhj385q2dgpr42g8l
    ;

    var inv = try Bolt11Invoice.fromStr(std.testing.allocator, str);
    defer inv.deinit();
}

test {
    _ = @import("builder.zig");
}

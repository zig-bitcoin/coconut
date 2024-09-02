const std = @import("std");

const Case = enum {
    upper,
    lower,
    none,
};

/// Check if the HRP is valid. Returns the case of the HRP, if any.
///
/// # Errors
/// * **MixedCase**: If the HRP contains both uppercase and lowercase characters.
/// * **InvalidChar**: If the HRP contains any non-ASCII characters (outside 33..=126).
/// * **InvalidLength**: If the HRP is outside 1..83 characters long.
fn checkHrp(hrp: []const u8) Error!Case {
    if (hrp.len == 0 or hrp.len > 83) return Error.InvalidLength;

    var has_lower: bool = false;
    var has_upper: bool = false;

    for (hrp) |b| {
        // Valid subset of ASCII
        if (!(b >= 33 and b <= 126)) return Error.InvalidChar;

        if (b >= 'a' and b <= 'z') has_lower = true else if (b >= 'A' and b <= 'Z') has_upper = true;

        if (has_lower and has_upper) return Error.MixedCase;
    }
    if (has_upper) return .upper;
    if (has_lower) return .lower;

    return .none;
}

fn verifyChecksum(allocator: std.mem.Allocator, hrp: []const u8, data: []const u5) Error!?Variant {
    var exp = try hrpExpand(allocator, hrp);
    defer exp.deinit();

    try exp.appendSlice(data);
    return Variant.fromRemainder(polymod(exp.items));
}

fn hrpExpand(allocator: std.mem.Allocator, hrp: []const u8) Error!std.ArrayList(u5) {
    var v = std.ArrayList(u5).init(allocator);
    errdefer v.deinit();

    for (hrp) |b| {
        try v.append(@truncate(b >> 5));
    }

    try v.append(0);

    for (hrp) |b| {
        try v.append(@truncate(b & 0x1f));
    }

    return v;
}

/// Generator coefficients
const GEN: [5]u32 = .{
    0x3b6a_57b2,
    0x2650_8e6d,
    0x1ea1_19fa,
    0x3d42_33dd,
    0x2a14_62b3,
};

fn polymod(values: []const u5) u32 {
    var chk: u32 = 1;
    var b: u8 = undefined;
    for (values) |v| {
        b = @truncate(chk >> 25);
        chk = (chk & 0x01ff_ffff) << 5 ^ @as(u32, v);

        for (GEN, 0..) |item, i| {
            if (std.math.shr(u8, b, i) & 1 == 1) {
                chk ^= item;
            }
        }
    }

    return chk;
}

/// Human-readable part and data part separator
const SEP: u8 = '1';

/// Encoding character set. Maps data value -> char
const CHARSET: [32]u8 = .{
    'q', 'p', 'z', 'r', 'y', '9', 'x', '8', //  +0
    'g', 'f', '2', 't', 'v', 'd', 'w', '0', //  +8
    's', '3', 'j', 'n', '5', '4', 'k', 'h', // +16
    'c', 'e', '6', 'm', 'u', 'a', '7', 'l', // +24
};

/// Reverse character set. Maps ASCII byte -> CHARSET index on [0,31]
const CHARSET_REV: [128]i8 = .{
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    15, -1, 10, 17, 21, 20, 26, 30, 7,  5,  -1, -1, -1, -1, -1, -1, -1, 29, -1, 24, 13, 25, 9,  8,
    23, -1, 18, 22, 31, 27, 19, -1, 1,  0,  3,  16, 11, 28, 12, 14, 6,  4,  2,  -1, -1, -1, -1, -1,
    -1, 29, -1, 24, 13, 25, 9,  8,  23, -1, 18, 22, 31, 27, 19, -1, 1,  0,  3,  16, 11, 28, 12, 14,
    6,  4,  2,  -1, -1, -1, -1, -1,
};

/// Error types for Bech32 encoding / decoding
pub const Error = std.mem.Allocator.Error || error{
    /// String does not contain the separator character
    MissingSeparator,
    /// The checksum does not match the rest of the data
    InvalidChecksum,
    /// The data or human-readable part is too long or too short
    InvalidLength,
    /// Some part of the string contains an invalid character
    InvalidChar,
    /// Some part of the data has an invalid value
    InvalidData,
    /// The bit conversion failed due to a padding issue
    InvalidPadding,
    /// The whole string must be of one case
    MixedCase,
};

const BECH32_CONST: u32 = 1;
const BECH32M_CONST: u32 = 0x2bc8_30a3;

/// Used for encode/decode operations for the two variants of Bech32
pub const Variant = enum {
    /// The original Bech32 described in [BIP-0173](https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki)
    bech32,
    /// The improved Bech32m variant described in [BIP-0350](https://github.com/bitcoin/bips/blob/master/bip-0350.mediawiki)
    bech32m,

    // Produce the variant based on the remainder of the polymod operation
    fn fromRemainder(c: u32) ?Variant {
        return switch (c) {
            BECH32_CONST => .bech32,
            BECH32M_CONST => .bech32m,
            else => null,
        };
    }

    fn constant(self: Variant) u32 {
        return switch (self) {
            .bech32 => BECH32_CONST,
            .bech32m => BECH32M_CONST,
        };
    }
};

/// Decode a bech32 string into the raw HRP and the `u5` data.
fn splitAndDecode(allocator: std.mem.Allocator, s: []const u8) Error!struct { std.ArrayList(u8), std.ArrayList(u5) } {
    // Split at separator and check for two pieces

    const raw_hrp, const raw_data = if (std.mem.indexOfScalar(u8, s, SEP)) |sep| .{
        s[0..sep], s[sep + 1 ..],
    } else return Error.MissingSeparator;

    var case = try checkHrp(raw_hrp);
    var buf = try std.ArrayList(u8).initCapacity(allocator, 100);
    errdefer buf.deinit();

    const hrp_lower = switch (case) {
        .upper => std.ascii.lowerString(buf.items, raw_hrp),
        // already lowercase
        .lower, .none => v: {
            try buf.appendSlice(raw_hrp);
            break :v buf.items;
        },
    };

    buf.items.len = hrp_lower.len;

    var data = std.ArrayList(u5).init(allocator);
    errdefer data.deinit();

    // Check data payload
    for (raw_data) |c| {
        // Only check if c is in the ASCII range, all invalid ASCII
        // characters have the value -1 in CHARSET_REV (which covers
        // the whole ASCII range) and will be filtered out later.
        if (!std.ascii.isAscii(c)) return error.InvalidChar;

        if (std.ascii.isLower(c)) {
            switch (case) {
                .upper => return Error.MixedCase,
                .none => case = .lower,
                .lower => {},
            }
        } else if (std.ascii.isUpper(c)) {
            switch (case) {
                .lower => return Error.MixedCase,
                .none => case = .upper,
                .upper => {},
            }
        }

        // c should be <128 since it is in the ASCII range, CHARSET_REV.len() == 128
        const num_value = CHARSET_REV[c];

        if (!(0 >= num_value or num_value <= 31)) return Error.InvalidChar;

        try data.append(@intCast(num_value));
    }

    return .{ buf, data };
}

const CHECKSUM_LENGTH: usize = 6;

/// Decode a bech32 string into the raw HRP and the data bytes.
///
/// Returns the HRP in lowercase, the data with the checksum removed, and the encoding.
pub fn decode(allocator: std.mem.Allocator, s: []const u8) Error!struct { std.ArrayList(u8), std.ArrayList(u5), Variant } {
    const hrp_lower, var data = try splitAndDecode(allocator, s);
    errdefer data.deinit();
    errdefer hrp_lower.deinit();

    if (data.items.len < CHECKSUM_LENGTH)
        return Error.InvalidLength;

    if (try verifyChecksum(allocator, hrp_lower.items, data.items)) |v| {
        // Remove checksum from data payload
        data.items.len = data.items.len - CHECKSUM_LENGTH;

        return .{ hrp_lower, data, v };
    }
    return Error.InvalidChecksum;
}

/// Encode a bech32 payload to an [WriteAny].
///
/// # Errors
/// * If [checkHrp] returns an error for the given HRP.
/// # Deviations from standard
/// * No length limits are enforced for the data part
pub fn encodeToFmt(
    allocator: std.mem.Allocator,
    fmt: std.io.AnyWriter,
    hrp: []const u8,
    data: []const u5,
    variant: Variant,
) !void {
    var hrp_lower = try std.ArrayList(u8).initCapacity(allocator, hrp.len);
    defer hrp_lower.deinit();

    hrp_lower.appendSliceAssumeCapacity(hrp);

    _ = if (try checkHrp(hrp) == .upper) std.ascii.lowerString(hrp_lower.items, hrp);

    var writer = try Bech32Writer.init(hrp_lower.items, variant, fmt);

    try writer.write(data);
    try writer.finalize();
}

/// Allocationless Bech32 writer that accumulates the checksum data internally and writes them out
/// in the end.
pub const Bech32Writer = struct {
    formatter: std.io.AnyWriter,
    chk: u32,
    variant: Variant,

    /// Creates a new writer that can write a bech32 string without allocating itself.
    ///
    /// This is a rather low-level API and doesn't check the HRP or data length for standard
    /// compliance.
    pub fn init(hrp: []const u8, variant: Variant, fmt: std.io.AnyWriter) !Bech32Writer {
        var writer = Bech32Writer{
            .formatter = fmt,
            .chk = 1,
            .variant = variant,
        };

        _ = try writer.formatter.write(hrp);
        try writer.formatter.writeByte(SEP);

        // expand HRP
        for (hrp) |b| {
            writer.polymodStep(@truncate(b >> 5));
        }

        writer.polymodStep(0);
        for (hrp) |b| {
            writer.polymodStep(@truncate(b & 0x1f));
        }

        return writer;
    }

    fn polymodStep(self: *@This(), v: u5) void {
        const b: u8 = @truncate(self.chk >> 25);

        self.chk = (self.chk & 0x01ff_ffff) << 5 ^ v;

        for (0.., GEN) |i, item| {
            if (std.math.shr(u8, b, i) & 1 == 1) {
                self.chk ^= item;
            }
        }
    }

    pub fn finalize(self: *@This()) !void {
        try self.writeChecksum();
    }

    fn writeChecksum(self: *@This()) !void {
        // Pad with 6 zeros
        for (0..CHECKSUM_LENGTH) |_| {
            self.polymodStep(0);
        }

        const plm: u32 = self.chk ^ self.variant.constant();

        for (0..CHECKSUM_LENGTH) |p| {
            const v: u8 = @intCast(std.math.shr(u32, plm, (5 * (5 - p))) & 0x1f);

            try self.formatter.writeByte(CHARSET[v]);
        }
    }

    /// Write a `u5` slice
    fn write(self: *@This(), data: []const u5) !void {
        for (data) |b| {
            try self.writeU5(b);
        }
    }

    /// Writes a single 5 bit value of the data part
    fn writeU5(self: *@This(), data: u5) !void {
        self.polymodStep(data);

        try self.formatter.writeByte(CHARSET[data]);
    }
};

// Encode a bech32 payload to string.
//
// # Errors
// * If [check_hrp] returns an error for the given HRP.
// # Deviations from standard
// * No length limits are enforced for the data part
pub fn encode(allocator: std.mem.Allocator, hrp: []const u8, data: []const u5, variant: Variant) !std.ArrayList(u8) {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try encodeToFmt(allocator, buf.writer().any(), hrp, data, variant);

    return buf;
}

pub fn toBase32(allocator: std.mem.Allocator, d: []const u8) !std.ArrayList(u5) {
    var self = std.ArrayList(u5).init(allocator);
    errdefer self.deinit();

    // Amount of bits left over from last round, stored in buffer.
    var buffer_bits: u32 = 0;
    // Holds all unwritten bits left over from last round. The bits are stored beginning from
    // the most significant bit. E.g. if buffer_bits=3, then the byte with bits a, b and c will
    // look as follows: [a, b, c, 0, 0, 0, 0, 0]
    var buffer: u8 = 0;

    for (d) |b| {
        // Write first u5 if we have to write two u5s this round. That only happens if the
        // buffer holds too many bits, so we don't have to combine buffer bits with new bits
        // from this rounds byte.
        if (buffer_bits >= 5) {
            try self.append(@truncate(std.math.shr(u8, buffer & 0b1111_1000, 3)));
            buffer <<= 5;
            buffer_bits -= 5;
        }

        // Combine all bits from buffer with enough bits from this rounds byte so that they fill
        // a u5. Save reamining bits from byte to buffer.
        const from_buffer = buffer >> 3;
        const from_byte = std.math.shr(u8, b, 3 + buffer_bits); // buffer_bits <= 4

        try self.append(@truncate(from_buffer | from_byte));
        buffer = std.math.shl(u8, b, 5 - buffer_bits);
        buffer_bits += 3;
    }

    // There can be at most two u5s left in the buffer after processing all bytes, write them.
    if (buffer_bits >= 5) {
        try self.append(@truncate((buffer & 0b1111_1000) >> 3));
        buffer <<= 5;
        buffer_bits -= 5;
    }

    if (buffer_bits != 0) {
        try self.append(@truncate(buffer >> 3));
    }

    return self;
}

/// Encode a bech32 payload without a checksum to an [std.io.AnyWriter].
///
/// # Errors
/// * If [checkHrp] returns an error for the given HRP.
/// # Deviations from standard
/// * No length limits are enforced for the data part
pub fn encodeWithoutChecksumToFmt(
    allocator: std.mem.Allocator,
    fmt: std.io.AnyWriter,
    hrp: []const u8,
    data: []const u5,
) !void {
    var hrp_lower = try std.ArrayList(u8).initCapacity(allocator, hrp.len);
    defer hrp_lower.deinit();

    hrp_lower.appendSliceAssumeCapacity(hrp);

    _ = if (try checkHrp(hrp) == .upper) std.ascii.lowerString(hrp_lower.items, hrp);

    _ = try fmt.write(hrp);

    _ = try fmt.writeByte(SEP);

    for (data) |b| {
        try fmt.writeByte(CHARSET[b]);
    }
}

/// Encode a bech32 payload to string without the checksum.
///
/// # Errors
/// * If [checkHrp] returns an error for the given HRP.
/// # Deviations from standard
/// * No length limits are enforced for the data part
pub fn encodeWithoutChecksum(allocator: std.mem.Allocator, hrp: []const u8, data: []const u5) !std.ArrayList(u8) {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try encodeWithoutChecksumToFmt(allocator, buf.writer().any(), hrp, data);

    return buf;
}

/// Decode a bech32 string into the raw HRP and the data bytes, assuming no checksum.
///
/// Returns the HRP in lowercase and the data.
pub fn decodeWithoutChecksum(allocator: std.mem.Allocator, s: []const u8) Error!struct { std.ArrayList(u8), std.ArrayList(u5) } {
    return splitAndDecode(allocator, s);
}

/// Convert base32 to base256, removes null-padding if present, returns
/// `Err(Error::InvalidPadding)` if padding bits are unequal `0`
pub fn arrayListFromBase32(allocator: std.mem.Allocator, b: []const u5) !std.ArrayList(u8) {
    return convertBits(u5, allocator, b, 5, 8, false);
}

/// Convert between bit sizes
///
/// # Errors
/// * `Error::InvalidData` if any element of `data` is out of range
/// * `Error::InvalidPadding` if `pad == false` and the padding bits are not `0`
///
/// # Panics
/// Function will panic if attempting to convert `from` or `to` a bit size that
/// is 0 or larger than 8 bits.
///
/// # Examples
///
/// ```zig
/// const base5 = try convertBits(u8, allocator, &.{0xff}, 8, 5, true);
/// std.testing.expectEqualSlices(u8, base5.items, &.{0x1f, 0x1c});
/// ```
pub fn convertBits(comptime T: type, allocator: std.mem.Allocator, data: []const T, from: u32, to: u32, pad: bool) !std.ArrayList(u8) {
    if (from > 8 or to > 8 or from == 0 or to == 0) {
        @panic("convert_bits `from` and `to` parameters 0 or greater than 8");
    }

    var acc: u32 = 0;
    var bits: u32 = 0;
    var ret = std.ArrayList(u8).init(allocator);
    errdefer ret.deinit();

    const maxv: u32 = std.math.shl(u32, 1, to) - 1;
    for (data) |value| {
        const v: u32 = @intCast(value);
        if (std.math.shr(u32, v, from) != 0) {
            // Input value exceeds `from` bit size
            return error.InvalidData;
        }
        acc = std.math.shl(u32, acc, from) | v;
        bits += from;

        while (bits >= to) {
            bits -= to;
            try ret.append(@truncate(std.math.shr(u32, acc, bits) & maxv));
        }
    }

    if (pad) {
        if (bits > 0) {
            try ret.append(@truncate(std.math.shl(u32, acc, to - bits) & maxv));
        }
    } else if (bits >= from or (std.math.shl(u32, acc, to - bits) & maxv) != 0) {
        return error.InvalidPadding;
    }

    return ret;
}

test "encode" {
    try std.testing.expectError(
        error.InvalidLength,
        encode(std.testing.allocator, "", &.{ 1, 2, 3, 4 }, .bech32),
    );
}

test "roundtrip_without_checksum" {
    const hrp = "lnbc";
    const data = try toBase32(std.testing.allocator, "Hello World!");
    defer data.deinit();

    const encoded = try encodeWithoutChecksum(std.testing.allocator, hrp, data.items);
    defer encoded.deinit();

    const decoded_hrp, const decoded_data =
        try decodeWithoutChecksum(std.testing.allocator, encoded.items);
    defer decoded_hrp.deinit();
    defer decoded_data.deinit();

    try std.testing.expectEqualSlices(u8, hrp, decoded_hrp.items);

    try std.testing.expectEqualSlices(u5, data.items, decoded_data.items);
}

test "test_hrp_case_decode" {
    const hrp, const data, const variant = try decode(std.testing.allocator, "hrp1qqqq40atq3");
    defer hrp.deinit();
    defer data.deinit();

    var expected_data = try toBase32(std.testing.allocator, &.{ 0x00, 0x00 });
    defer expected_data.deinit();

    try std.testing.expectEqual(.bech32, variant);
    try std.testing.expectEqualSlices(u8, "hrp", hrp.items);
    try std.testing.expectEqualSlices(u5, expected_data.items, data.items);
}

test "test_hrp_case" {
    var data = try toBase32(std.testing.allocator, &.{ 0x00, 0x00 });
    defer data.deinit();

    // Tests for issue with HRP case checking being ignored for encoding
    const encoded = try encode(std.testing.allocator, "HRP", data.items, .bech32);
    defer encoded.deinit();

    try std.testing.expectEqualSlices(u8, "hrp1qqqq40atq3", encoded.items);
}

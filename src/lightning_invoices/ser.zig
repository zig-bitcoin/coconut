const std = @import("std");

/// Converts a stream of bytes written to it to base32. On finalization the according padding will
/// be applied. That means the results of writing two data blocks with one or two `BytesToBase32`
/// converters will differ.
pub const BytesToBase32 = struct {
    const Self = @This();

    /// Target for writing the resulting `u5`s resulting from the written bytes
    writer: *Writer,
    /// Holds all unwritten bits left over from last round. The bits are stored beginning from
    /// the most significant bit. E.g. if buffer_bits=3, then the byte with bits a, b and c will
    /// look as follows: [a, b, c, 0, 0, 0, 0, 0]
    buffer: u8 = 0,
    /// Amount of bits left over from last round, stored in buffer.
    buffer_bits: u8 = 0,

    pub fn init(writer: *Writer) Self {
        return .{
            .writer = writer,
        };
    }

    /// Add more bytes to the current conversion unit
    pub fn append(self: *Self, bytes: []const u8) !void {
        for (bytes) |b| {
            try self.appendU8(b);
        }
    }

    pub fn appendU8(self: *Self, byte: u8) !void {
        // Write first u5 if we have to write two u5s this round. That only happens if the
        // buffer holds too many bits, so we don't have to combine buffer bits with new bits
        // from this rounds byte.
        if (self.buffer_bits >= 5) {
            try self.writer.writeOne(@truncate(std.math.shr(
                u8,
                self.buffer & 0b11111000,
                3,
            )));
            self.buffer <<= 5;
            self.buffer_bits -= 5;
        }

        // Combine all bits from buffer with enough bits from this rounds byte so that they fill
        // a u5. Save remaining bits from byte to buffer.
        const from_buffer = self.buffer >> 3;
        const from_byte = std.math.shr(u8, byte, 3 + self.buffer_bits); // buffer_bits <= 4

        try self.writer.writeOne(@truncate(from_buffer | from_byte));

        self.buffer = std.math.shl(u8, byte, 5 - self.buffer_bits);
        self.buffer_bits += 3;
    }

    pub fn finalize(self: *Self) !void {
        // There can be at most two u5s left in the buffer after processing all bytes, write them.
        if (self.buffer_bits >= 5) {
            try self.writer.writeOne(@truncate((self.buffer & 0b11111000) >> 3));
            self.buffer <<= 5;
            self.buffer_bits -= 5;
        }

        if (self.buffer_bits != 0) {
            try self.writer.writeOne(@truncate(self.buffer >> 3));
        }
    }
};

pub const Writer = struct {
    inner: *std.ArrayList(u5),

    pub fn init(inner_writer: *std.ArrayList(u5)) Writer {
        return .{
            .inner = inner_writer,
        };
    }

    pub fn write(self: *const Writer, data: []const u5) !void {
        try self.inner.appendSlice(data);
    }

    pub fn writeOne(self: *const Writer, data: u5) !void {
        try self.inner.append(data);
    }
};

pub fn encodeIntBeBase32(int: u64) !std.BoundedArray(u5, 20) {
    const base: u64 = 32;

    var out_vec = try std.BoundedArray(u5, 20).init(0);

    var rem_int = int;
    while (rem_int != 0) {
        out_vec.appendAssumeCapacity(@truncate(rem_int % base));
        rem_int /= base;
    }

    // reverse array
    for (0..out_vec.len / 2) |i| {
        std.mem.swap(u5, &out_vec.buffer[i], &out_vec.buffer[out_vec.len - i - 1]);
    }

    return out_vec;
}

pub fn encodedIntBeBase32Size(int: u64) usize {
    var pos: usize = 12;

    while (pos >= 0) : (pos -= 1) {
        if (int & std.math.shl(u64, 0x1f, 5 * pos) != 0) {
            return pos + 1;
        }
    }

    return 0;
}

/// Calculates the base32 encoded size of a byte slice
fn bytesSizeToBase32Size(byte_size: usize) usize {
    const bits = byte_size * 8;

    return if (bits % 5 == 0)
        // without padding bits
        bits / 5
    else
        // with padding bits
        bits / 5 + 1;
}

/// Appends the default value of `T` to the front of the `in_vec` till it reaches the length
/// `target_length`. If `in_vec` already is too lang `None` is returned.
/// caller own result and must free
pub fn tryStretch(gpa: std.mem.Allocator, in_vec: []const u5, target_len: usize) ?std.ArrayList(u5) {
    var out_vec = std.ArrayList(u5).init(gpa);
    errdefer out_vec.deinit();

    if (in_vec.len > target_len) {
        return null;
    } else if (in_vec.len == target_len) {
        return try out_vec.appendSlice(in_vec);
    } else {
        try out_vec.ensureTotalCapacity(target_len);

        out_vec.appendNTimesAssumeCapacity(0, target_len - in_vec.len);
        out_vec.appendSliceAssumeCapacity(in_vec);

        return out_vec;
    }
}

pub fn tryStretchWriter(writer: *const Writer, in_vec: []const u5, comptime target_len: usize) !void {
    if (in_vec.len > target_len) {
        return error.InputLengthMoreTarget;
    } else if (in_vec.len == target_len) {
        try writer.write(in_vec);
    } else {
        var buf: [target_len]u5 = undefined;

        @memset(buf[0..(target_len - in_vec.len)], 0);
        @memcpy(buf[target_len - in_vec.len ..], in_vec);

        try writer.write(&buf);
    }
}

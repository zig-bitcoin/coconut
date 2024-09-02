const std = @import("std");
const SALT_PREFIX = "mnemonic";

const Hmac = std.crypto.auth.hmac.sha2.HmacSha512;
const Sha512 = std.crypto.hash.sha2.Sha512;

/// Calculate the binary size of the mnemonic.
fn mnemonicByteLen(mnemonic: []const []const u8) usize {
    var len: usize = 0;
    for (0.., mnemonic) |i, word| {
        if (i > 0) {
            len += 1;
        }

        len += word.len;
    }
    return len;
}

/// Wrote the mnemonic in binary form into the hash engine.
fn mnemonicWriteInto(mnemonic: []const []const u8, engine: *Sha512) void {
    for (0.., mnemonic) |i, word| {
        if (i > 0) {
            engine.update(" ");
        }
        engine.update(word);
    }
}

/// Create an HMAC engine from the passphrase.
/// We need a special method because we can't allocate a new byte
/// vector for the entire serialized mnemonic.
fn createHmacEngine(mnemonic: []const []const u8) Hmac {
    // Inner code is borrowed from the bitcoin_hashes::hmac::HmacEngine::new method.
    var ipad = [_]u8{0x36} ** 128;
    var opad = [_]u8{0x5c} ** 128;

    var iengine = Sha512.init(.{});

    if (mnemonicByteLen(mnemonic) > Sha512.block_length) {
        const hash = v: {
            var engine = Sha512.init(.{});
            mnemonicWriteInto(mnemonic, &engine);
            var final: [Sha512.digest_length]u8 = undefined;
            engine.final(&final);
            break :v final;
        };

        for (ipad[0..64], hash) |*b_i, b_h| {
            b_i.* = b_i.* ^ b_h;
        }

        for (opad[0..64], hash) |*b_o, b_h| {
            b_o.* = b_o.* ^ b_h;
        }
    } else {
        // First modify the first elements from the prefix.
        var cursor: usize = 0;
        for (0.., mnemonic) |i, word| {
            if (i > 0) {
                ipad[cursor] ^= ' ';
                opad[cursor] ^= ' ';
                cursor += 1;
            }

            const min_len = @min(ipad.len - cursor, word.len);
            for (ipad[cursor .. cursor + min_len], word[0..min_len]) |*b_i, b_h| {
                b_i.* = b_i.* ^ b_h;
            }

            for (opad[cursor .. cursor + min_len], word[0..min_len]) |*b_o, b_h| {
                b_o.* = b_o.* ^ b_h;
            }

            cursor += word.len;
            // assert!(cursor <= sha512::HashEngine::BLOCK_SIZE, "mnemonic_byte_len is broken");
        }
    }

    iengine.update(ipad[0..Sha512.block_length]);

    return Hmac{
        .o_key_pad = opad[0..Sha512.block_length].*,
        .hash = iengine,
    };
}

inline fn xor(res: []u8, salt: []const u8) void {
    // length mismatch in xor
    std.debug.assert(salt.len >= res.len);
    const min_len = @min(res.len, salt.len);
    for (res[0..min_len], salt[0..min_len]) |*a, b| {
        a.* = a.* ^ b;
    }
}

/// PBKDF2-HMAC-SHA512 implementation using bitcoin_hashes.
pub fn pbkdf2(mnemonic: []const []const u8, unprefixed_salt: []const u8, c: usize, res: []u8) void {
    const prf = createHmacEngine(mnemonic);
    @memset(res, 0);

    // var pprf = prf;

    // var prf_buf: [Hmac.mac_length]u8 = undefined;
    // pprf.final(&prf_buf);

    // std.log.warn("pprf :{any}", .{prf_buf});

    var i: usize = 0;

    while (i < res.len) : ({
        i += Sha512.digest_length;
    }) {
        const chunk_too = @min(res.len, i + Sha512.digest_length);
        const chunk: []u8 = res[i..chunk_too];
        var salt = v: {
            var prfc = prf;
            prfc.update(SALT_PREFIX);
            prfc.update(unprefixed_salt);

            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, @truncate(i + 1), .big);

            prfc.update(&buf);

            var salt: [Hmac.mac_length]u8 = undefined;

            prfc.final(&salt);

            xor(chunk, &salt);
            break :v salt;
        };

        for (1..c) |_| {
            var prfc = prf;

            prfc.update(&salt);

            prfc.final(&salt);
            xor(chunk, &salt);
        }
    }
}

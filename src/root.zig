//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

const Secp256k1 = std.crypto.ecc.Secp256k1;

pub fn step1_alice(secret_msg: []const u8, blinding_factor: Secp256k1) void {}

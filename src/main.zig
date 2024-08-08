const std = @import("std");

const bdhke = @import("bdhke.zig");

pub fn main() !void {
    try bdhke.testBDHKE();
}

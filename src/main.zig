const std = @import("std");

const bdhke = @import("bdhke.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try bdhke.testBDHKE(allocator);
}

const std = @import("std");

const bdhke = @import("bdhke.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Running Coconut...\n", .{});

    try bdhke.testBDHKE();

    try bw.flush(); // Don't forget to flush!
}

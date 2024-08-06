const std = @import("std");

const root = @import("root.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Running Coconut...\n", .{});

    //root.step1_alice();

    try bw.flush(); // Don't forget to flush!
}

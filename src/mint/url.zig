const std = @import("std");

pub fn Url(comptime max_size: usize) type {
    return struct {
        inner: std.BoundedArray(u8, max_size),

        /// New mint url
        pub fn new(s: []const u8) @This() {
            var inner = try std.BoundedArray(u8, max_size).init(0);
            inner.appendSlice(s) catch @panic("overflow");

            return .{
                .inner = inner,
            };
        }
    };
}

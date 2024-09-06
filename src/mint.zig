const std = @import("std");
const httpz = @import("httpz");

pub fn main() void {
    var server = try httpz.ServerApp(*App).init(allocator, .{ .port = 5882 }, &app);
    var router = server.router(.{});
}

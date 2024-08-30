const std = @import("std");
const zul = @import("zul");

pub const Secret = struct {
    inner: []const u8,

    pub fn clone(self: Secret, allocator: std.mem.Allocator) !Secret {
        const data = try allocator.alloc(u8, self.inner.len);

        @memcpy(data, self.inner);
        return .{
            .inner = data,
        };
    }

    pub fn deinit(self: Secret, allocator: std.mem.Allocator) void {
        allocator.free(self.inner);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        return .{ .inner = try std.json.innerParse([]const u8, allocator, source, options) };
    }

    /// Create secret value
    /// Generate a new random secret as the recommended 32 byte hex
    pub fn generate(allocator: std.mem.Allocator) !Secret {
        var random_bytes: [32]u8 = undefined;

        var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));

        // Generate random bytes
        rng.fill(&random_bytes);

        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        try std.fmt.format(result.writer(), "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)});

        // The secret string is hex encoded
        return .{
            .inner = try result.toOwnedSlice(),
        };
    }

    pub fn toBytes(self: Secret) []const u8 {
        return self.inner;
    }
};

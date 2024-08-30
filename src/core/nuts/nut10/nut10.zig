//! NUT-10: Spending conditions
//!
//! <https://github.com/cashubtc/nuts/blob/main/10.md>

const std = @import("std");
const secret_lib = @import("../../secret.zig");
const helper = @import("../../../helper/helper.zig");

///  NUT10 Secret Kind
pub const Kind = enum {
    /// NUT-11 P2PK
    p2pk,
    /// NUT-14 HTLC
    htlc,

    pub fn jsonStringify(self: Kind, out: anytype) !void {
        try out.write(switch (self) {
            .p2pk => "P2PK",
            .htlc => "HTLC",
        });
    }

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !Kind {
        const name = switch (try source.next()) {
            inline .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };

        if (std.mem.eql(u8, name, "P2PK")) return .p2pk;
        if (std.mem.eql(u8, name, "HTLC")) return .htlc;

        return error.UnexpectedToken;
    }
};

/// Secert Date
pub const SecretData = struct {
    /// Unique random string
    nonce: []const u8,
    /// Expresses the spending condition specific to each kind
    data: []const u8,
    /// Additional data committed to and can be used for feature extensions
    tags: ?[]const []const []const u8,

    pub fn eql(self: SecretData, other: SecretData) bool {
        if (!std.mem.eql(u8, self.nonce, other.nonce)) return false;
        if (!std.mem.eql(u8, self.data, other.data)) return false;

        if ((self.tags != null and other.tags == null) or (self.tags == null and other.tags != null)) return false;

        if (self.tags) |stags| {
            if (other.tags) |tags| {
                if (stags.len != tags.len) return false;

                for (0..stags.len) |x| {
                    if (tags[x].len != stags[x].len) return false;

                    for (0..tags[x].len) |i| {
                        if (!std.mem.eql(u8, tags[x][i], stags[x][i])) return false;
                    }
                }
            }
        }

        return true;
    }
};

/// NUT10 Secret
pub const Secret = struct {
    ///  Kind of the spending condition
    kind: Kind,
    /// Secret Data
    secret_data: SecretData,

    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Secret) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }

    /// Create new [`Secret`] using allocator arena
    pub fn init(alloc: std.mem.Allocator, kind: Kind, _data: []const u8, tags: ?std.ArrayList(std.ArrayList(std.ArrayList(u8)))) !Secret {
        var arenaAllocator = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arenaAllocator);

        arenaAllocator.* = std.heap.ArenaAllocator.init(alloc);

        errdefer arenaAllocator.deinit();
        const allocator = arenaAllocator.allocator();

        const sec = try secret_lib.Secret.generate(allocator);

        const data = try allocator.alloc(u8, _data.len);
        @memcpy(data, _data);

        const converted_tags = if (tags) |t| try helper.clone3dArrayToSlice(u8, allocator, t) else null;

        const secret_data = SecretData{
            .nonce = sec.toBytes(),
            .data = data,
            .tags = converted_tags,
        };

        return .{
            .kind = kind,
            .arena = arenaAllocator,
            .secret_data = secret_data,
        };
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginArray();
        try out.write(self.kind);
        try out.write(self.secret_data);
        try out.endArray();
    }

    pub fn fromSecret(sec: secret_lib.Secret, allocator: std.mem.Allocator) !std.json.Parsed(Secret) {
        return try std.json.parseFromSlice(Secret, allocator, sec.inner, .{});
    }

    pub fn toSecret(self: Secret, allocator: std.mem.Allocator) !secret_lib.Secret {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        try std.json.stringify(&self, .{}, output.writer());

        return secret_lib.Secret{
            .inner = try output.toOwnedSlice(),
        };
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Secret {
        if (try source.next() != .array_begin) return error.UnexpectedToken;

        var res: Secret = undefined; // no defaults

        res.kind = try std.json.innerParse(Kind, allocator, source, options);
        res.secret_data = try std.json.innerParse(SecretData, allocator, source, options);

        // array_end
        if (try source.next() != .array_end) return error.UnexpectedToken;

        return res;
    }
};

test "test_secret_serialize" {
    const secret = Secret{
        .kind = .p2pk,
        .secret_data = .{
            .nonce = "5d11913ee0f92fefdc82a6764fd2457a",
            .data = "026562efcfadc8e86d44da6a8adf80633d974302e62c850774db1fb36ff4cc7198",
            .tags = &.{&.{ "key", "value1", "value2" }},
        },
        .arena = undefined,
    };

    const secret_str =
        \\["P2PK",{"nonce":"5d11913ee0f92fefdc82a6764fd2457a","data":"026562efcfadc8e86d44da6a8adf80633d974302e62c850774db1fb36ff4cc7198","tags":[["key","value1","value2"]]}]
    ;

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try std.json.stringify(secret, .{}, output.writer());

    try std.testing.expectEqualSlices(u8, secret_str, output.items);
}

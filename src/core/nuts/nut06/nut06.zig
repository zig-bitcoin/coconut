//! NUT-06: Mint Information
//!
//! <https://github.com/cashubtc/nuts/blob/main/06.md>
const std = @import("std");
const bitcoin_primitives = @import("bitcoin-primitives");
const secp256k1 = bitcoin_primitives.secp256k1;
const nut05 = @import("../nut05/nut05.zig");
const nut15 = @import("../nut15/nut15.zig");
const nut04 = @import("../nut04/nut04.zig");
const helper = @import("../../../helper/helper.zig");

const PublicKey = secp256k1.PublicKey;
const MppMethodSettings = @import("../nut15/nut15.zig").MppMethodSettings;

/// Mint Version
pub const MintVersion = struct {
    /// Mint Software name
    name: []const u8,
    /// Mint Version
    version: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const value = try std.json.innerParse([]const u8, allocator, source, options);

        var parts = std.mem.splitScalar(u8, value, '/');

        return .{
            .name = parts.next().?,
            .version = parts.next().?,
        };
    }

    pub fn jsonStringify(self: MintVersion, out: anytype) !void {
        try out.print("\"{s}/{s}\"", .{ self.name, self.version });
    }
};

/// Supported nuts and settings
pub const Nuts = struct {
    /// NUT04 Settings
    nut04: nut04.Settings = .{},
    /// NUT05 Settings
    nut05: nut05.Settings = .{},
    /// NUT07 Settings
    nut07: SupportedSettings = .{},
    /// NUT08 Settings
    nut08: SupportedSettings = .{},
    /// NUT09 Settings
    nut09: SupportedSettings = .{},
    /// NUT10 Settings
    nut10: SupportedSettings = .{},
    /// NUT11 Settings
    nut11: SupportedSettings = .{},
    /// NUT12 Settings
    nut12: SupportedSettings = .{},
    /// NUT14 Settings
    nut14: SupportedSettings = .{},
    /// NUT15 Settings
    nut15: nut15.Settings = .{},

    pub fn deinit(self: Nuts, gpa: std.mem.Allocator) void {
        gpa.free(self.nut04.methods);
        gpa.free(self.nut05.methods);
        gpa.free(self.nut15.methods);
    }

    pub usingnamespace helper.RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "nut04", "4",
                },
                .{
                    "nut05", "5",
                },

                .{
                    "nut07", "7",
                },
                .{
                    "nut08", "8",
                },
                .{
                    "nut09", "9",
                },
                .{
                    "nut10", "10",
                },
                .{
                    "nut11", "11",
                },
                .{
                    "nut12", "12",
                },
                .{
                    "nut14", "14",
                },
                .{
                    "nut15", "15",
                },
            },
        ),
    );
};

/// Mint Info [NIP-06]
pub const MintInfo = struct {
    /// name of the mint and should be recognizable
    name: ?[]const u8 = null,
    /// hex pubkey of the mint
    pubkey: ?PublicKey = null,
    /// implementation name and the version running
    version: ?MintVersion = null,
    /// short description of the mint
    description: ?[]const u8 = null,
    /// long description
    description_long: ?[]const u8 = null,
    /// Contact info
    contact: ?[]const ContactInfo = null,
    /// shows which NUTs the mint supports
    nuts: Nuts = .{},
    /// Mint's icon URL
    mint_icon_url: ?[]const u8 = null,
    /// message of the day that the wallet must display to the user
    motd: ?[]const u8 = null,
};

/// Check state Settings
pub const SupportedSettings = struct {
    supported: bool = false,
};

/// Contact Info
pub const ContactInfo = struct {
    /// Contact Method i.e. nostr
    method: []const u8,
    /// Contact info i.e. npub...
    info: []const u8,
};

test "test_des_mint_into" {
    const mint_info_str =
        \\    {
        \\    "name": "Cashu mint",
        \\    "pubkey": "0296d0aa13b6a31cf0cd974249f28c7b7176d7274712c95a41c7d8066d3f29d679",
        \\    "version": "Nutshell/0.15.3",
        \\    "contact": [
        \\        {"method": "", "info": ""},
        \\        {"method": "", "info": ""}
        \\    ],
        \\    "nuts": {
        \\        "4": {
        \\            "methods": [
        \\                {"method": "bolt11", "unit": "sat"},
        \\                {"method": "bolt11", "unit": "usd"}
        \\            ],
        \\            "disabled": false
        \\        },
        \\        "5": {
        \\            "methods": [
        \\                {"method": "bolt11", "unit": "sat"},
        \\                {"method": "bolt11", "unit": "usd"}
        \\            ],
        \\            "disabled": false
        \\        },
        \\        "7": {"supported": true},
        \\        "8": {"supported": true},
        \\        "9": {"supported": true},
        \\        "10": {"supported": true},
        \\        "11": {"supported": true}
        \\    }
        \\}
    ;
    const mint_info = try std.json.parseFromSlice(MintInfo, std.testing.allocator, mint_info_str, .{
        .ignore_unknown_fields = true,
    });
    defer mint_info.deinit();
}
test "test_ser_mint_into" {
    const mint_info_str =
        \\{
        \\"name": "Bob's Cashu mint",
        \\"pubkey": "0283bf290884eed3a7ca2663fc0260de2e2064d6b355ea13f98dec004b7a7ead99",
        \\"version": "Nutshell/0.15.0",
        \\"description": "The short mint description",
        \\"description_long": "A description that can be a long piece of text.",
        \\"contact": [
        \\  {
        \\      "method": "nostr",
        \\      "info": "xxxxx"
        \\  },
        \\  {
        \\      "method": "email",
        \\      "info": "contact@me.com"
        \\  }
        \\] ,
        \\"motd": "Message to display to users.",
        \\"mint_icon_url": "https://this-is-a-mint-icon-url.com/icon.png",
        \\"nuts": {
        \\  "4": {
        \\    "methods": [
        \\      {
        \\      "method": "bolt11",
        \\      "unit": "sat",
        \\      "min_amount": 0,
        \\      "max_amount": 10000
        \\      }
        \\    ],
        \\    "disabled": false
        \\  },
        \\  "5": {
        \\    "methods": [
        \\      {
        \\      "method": "bolt11",
        \\      "unit": "sat",
        \\      "min_amount": 0,
        \\      "max_amount": 10000
        \\      }
        \\    ],
        \\    "disabled": false
        \\  },
        \\  "7": {"supported": true},
        \\  "8": {"supported": true},
        \\  "9": {"supported": true},
        \\  "10": {"supported": true},
        \\  "12": {"supported": true}
        \\}
        \\}
    ;
    const mint_info = try std.json.parseFromSlice(MintInfo, std.testing.allocator, mint_info_str, .{});
    defer mint_info.deinit();

    var result_json = std.ArrayList(u8).init(std.testing.allocator);
    defer result_json.deinit();

    try std.json.stringify(&mint_info.value, .{}, result_json.writer());

    var mint_info_2 = try std.json.parseFromSlice(MintInfo, std.testing.allocator, result_json.items, .{});
    defer mint_info_2.deinit();

    try std.testing.expectEqualDeep(mint_info.value, mint_info_2.value);
}

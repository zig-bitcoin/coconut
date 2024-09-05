//! NUT-09: Restore signatures
//!
//! <https://github.com/cashubtc/nuts/blob/main/09.md>
const std = @import("std");
const BlindedMessage = @import("../nut00/nut00.zig").BlindedMessage;
const BlindSignature = @import("../nut00/nut00.zig").BlindSignature;
const helper = @import("../../../helper/helper.zig");

/// Restore Request [NUT-09]
pub const RestoreRequest = struct {
    /// Outputs
    outputs: []const BlindedMessage,
};

/// Restore Response [NUT-09]
pub const RestoreResponse = struct {
    /// Outputs
    outputs: []const BlindedMessage,
    /// Signatures
    signatures: []const BlindSignature,

    pub usingnamespace helper.RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "signatures", "promises",
                },
            },
        ),
    );
};

test "restore_response" {
    const rs =
        \\{"outputs":[{"B_":"0204bbffa045f28ec836117a29ea0a00d77f1d692e38cf94f72a5145bfda6d8f41","amount":0,"id":"00ffd48b8f5ecf80", "witness":null},{"B_":"025f0615ccba96f810582a6885ffdb04bd57c96dbc590f5aa560447b31258988d7","amount":0,"id":"00ffd48b8f5ecf80"}],"promises":[{"C_":"02e9701b804dc05a5294b5a580b428237a27c7ee1690a0177868016799b1761c81","amount":8,"dleq":null,"id":"00ffd48b8f5ecf80"},{"C_":"031246ee046519b15648f1b8d8ffcb8e537409c84724e148c8d6800b2e62deb795","amount":2,"dleq":null,"id":"00ffd48b8f5ecf80"}]}
    ;

    const res = try std.json.parseFromSlice(RestoreResponse, std.testing.allocator, rs, .{});
    defer res.deinit();

    try std.testing.expectEqual(res.value.signatures.len, 2);
    try std.testing.expectEqual(res.value.outputs.len, 2);

    // std.log.warn("res: {any}", .{res.value});
}

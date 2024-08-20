const std = @import("std");
pub usingnamespace @import("core/lib.zig");
pub usingnamespace @import("mint/lib.zig");
pub const bech32 = @import("bech32/bech32.zig");

test {
    std.testing.log_level = .debug;
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(bech32);
}

const std = @import("std");
pub const nuts = @import("core/nuts/lib.zig");
pub const core = @import("core/lib.zig");

pub const dhke = @import("core/dhke.zig");
// pub usingnamespace @import("core/lib.zig");
// TODO return after fix mint
// pub usingnamespace @import("mint/lib.zig");
// pub const bech32 = @import("bech32/bech32.zig");

test {
    std.testing.log_level = .warn;
    std.testing.refAllDeclsRecursive(@This());
    // std.testing.refAllDeclsRecursive(bech32);
}

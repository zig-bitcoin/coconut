const std = @import("std");
pub const core = @import("core/lib.zig");

test {
    std.testing.log_level = .warn;
    std.testing.refAllDeclsRecursive(@This());
}

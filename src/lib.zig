pub usingnamespace @import("core/lib.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}

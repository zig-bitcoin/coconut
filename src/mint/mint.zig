const std = @import("std");

const core = @import("../core/lib.zig");
const MintConfig = @import("config.zig").MintConfig;

pub const Mint = struct {
    keyset: core.keyset.MintKeyset,
    config: MintConfig,

    // init - initialized Mint using config
    pub fn init(allocator: std.mem.Allocator, config: MintConfig) !Mint {
        var keyset = try core.keyset.MintKeyset.init(
            allocator,
            config.privatekey,
            config.derivation_path orelse &.{},
        );
        errdefer keyset.deinit();

        return .{
            .keyset = keyset,
            .config = config,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.keyset.deinit();
    }
};

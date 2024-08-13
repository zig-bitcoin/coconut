const std = @import("std");

const core = @import("../core/lib.zig");
const pg = @import("pg");

const MintConfig = @import("config.zig").MintConfig;

pub const Mint = struct {
    keyset: core.keyset.MintKeyset,
    config: MintConfig,
    db: *pg.Pool,

    // init - initialized Mint using config
    pub fn init(allocator: std.mem.Allocator, config: MintConfig) !Mint {
        var keyset = try core.keyset.MintKeyset.init(
            allocator,
            config.privatekey,
            config.derivation_path orelse &.{},
        );
        errdefer keyset.deinit();

        var db = try pg.Pool.initUri(allocator, try std.Uri.parse(config.database.db_url), config.database.max_connections, 1000 * 10 * 60);
        errdefer db.deinit();

        return .{
            .keyset = keyset,
            .config = config,
            .db = db,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.keyset.deinit();
    }
};

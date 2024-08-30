const std = @import("std");

pub const LightningFeeConfig = struct {
    fee_percent: f64 = 1.0,
    fee_reserve_min: u64 = 4000,
};

pub const MintConfig = struct {
    privatekey: []const u8,
    derivation_path: ?[]const u8 = null,
    server: ServerConfig = .{},
    lightning_fee: LightningFeeConfig,

    database: DatabaseConfig = .{
        // TODO: i think we need to split it to another entity in main
        .db_url = "some-db-configuration",
    },

    pub fn readConfigWithDefaults(_: std.mem.Allocator) !MintConfig {
        // TODO read from cli
        // so we here need to read configuration
        return .{
            .privatekey = "my_private_key",
            .lightning_fee = .{},
        };
    }
};

pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 3338,
    serve_wallet_path: ?[]const u8 = null,
    api_prefix: ?[]const u8 = null,
};

pub const DatabaseConfig = struct {
    db_url: []const u8,

    max_connections: u32 = 5,
};

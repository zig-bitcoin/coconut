const std = @import("std");

pub const MintConfig = struct {
    privatekey: []const u8,
    derivation_path: ?[]const u8 = null,
    // pub info: MintInfoConfig,
    // pub lightning_fee: LightningFeeConfig,
    server: ServerConfig = .{},
    // pub btconchain_backend: Option<BtcOnchainConfig>,
    // pub lightning_backend: Option<LightningType>,
    // pub tracing: Option<TracingConfig>,
    // pub database: DatabaseConfig,

    pub fn readConfigWithDefaults(_: std.mem.Allocator) !MintConfig {
        // so we here need to read configuration
        return .{
            .privatekey = "my_private_key",
        };
    }
};

pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 3338,
    serve_wallet_path: ?[]const u8 = null,
    api_prefix: ?[]const u8 = null,
};

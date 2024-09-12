const std = @import("std");
const core = @import("../core/lib.zig");
const bitcoin_primitives = @import("bitcoin-primitives");
const zig_toml = @import("zig-toml");

const PublicKey = bitcoin_primitives.secp256k1.PublicKey;
const Amount = core.amount.Amount;
const CurrencyUnit = core.nuts.CurrencyUnit;

pub const Settings = struct {
    info: Info,
    mint_info: MintInfo,
    ln: Ln,
    cln: ?Cln,
    strike: ?Strike,
    fake_wallet: ?FakeWallet,
    database: Database,

    pub fn initFromToml(gpa: std.mem.Allocator, config_file_name: []const u8) !zig_toml.Parsed(Settings) {
        var parser = zig_toml.Parser(Settings).init(gpa);
        defer parser.deinit();

        const result = try parser.parseFile(config_file_name);

        return result;
    }
};

pub const DatabaseEngine = enum {
    sqlite,
    redb,
    in_memory,
};

pub const Database = struct {
    engine: DatabaseEngine = .in_memory,
};

pub const Info = struct {
    url: []const u8,
    listen_host: []const u8,
    listen_port: u16,
    mnemonic: []const u8,
    seconds_quote_is_valid_for: ?u64,
    input_fee_ppk: ?u64,
};

pub const MintInfo = struct {
    /// name of the mint and should be recognizable
    name: []const u8,
    /// hex pubkey of the mint
    pubkey: ?PublicKey, // nut01
    /// short description of the mint
    description: []const u8,
    /// long description
    description_long: ?[]const u8,
    /// url to the mint icon
    mint_icon_url: ?[]const u8,
    /// message of the day that the wallet must display to the user
    motd: ?[]const u8,
    /// Nostr publickey
    contact_nostr_public_key: ?[]const u8,
    /// Contact email
    contact_email: ?[]const u8,
};

pub const LnBackend = enum {
    // default
    cln,
    strike,
    fake_wallet,
    //  Greenlight,
    //  Ldk,
};

pub const Ln = struct {
    ln_backend: LnBackend = .cln,
    invoice_description: ?[]const u8,
    fee_percent: f32,
    reserve_fee_min: Amount,
};

pub const Strike = struct {
    api_key: []const u8,
    supported_units: ?[]const CurrencyUnit,
};

pub const Cln = struct {
    rpc_path: []const u8,
};

pub const FakeWallet = struct {
    supported_units: []const CurrencyUnit = &.{.sat},
};

const std = @import("std");
const cli = @import("zig-cli");
const bdhke = @import("bdhke.zig");

// Configuration settings for the CLI
const Args = struct {
    mint: bool = false,
    mnemonic: bool = false,
};

var cfg: Args = .{};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = try cli.AppRunner.init(allocator);
    defer r.deinit();

    // Define the CLI app
    const app = cli.App{
        .version = "0.1.0",
        .author = "Coconut Contributors",
        .command = .{
            .name = "coconut",
            .target = .{
                .subcommands = &.{
                    .{
                        .name = "info",
                        .description = .{
                            .one_line = "Display information about the Coconut wallet",
                        },
                        .options = &.{
                            .{
                                .long_name = "mint",
                                .short_alias = 'm',
                                .help = "Fetch mint information",
                                .value_ref = r.mkRef(&cfg.mint),
                            },
                            .{
                                .long_name = "mnemonic",
                                .short_alias = 'n',
                                .help = "Show your mnemonic",
                                .value_ref = r.mkRef(&cfg.mnemonic),
                            },
                        },
                        .target = .{ .action = .{ .exec = execute } },
                    },
                },
            },
        },
    };

    return r.run(&app);
}

fn execute() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try runInfo(allocator, cfg);
}

fn runInfo(allocator: std.mem.Allocator, _cfg: Args) !void {
    const dhke = try bdhke.Dhke.init(allocator);
    defer dhke.deinit();

    const stdout = std.io.getStdOut().writer();

    try stdout.print("Version: 0.1.0\n", .{});
    try stdout.print("Wallet: coconut\n", .{});

    const cashu_dir = try getCashuDir();
    try stdout.print("Cashu dir: {s}\n", .{cashu_dir});

    try stdout.print("Mints:\n", .{});
    try printMintsInfo(allocator, stdout, _cfg.mint);

    if (_cfg.mnemonic) {
        try printMnemonic(stdout);
    }

    try printNostrInfo(stdout);
}

fn getCashuDir() ![]const u8 {
    return std.fs.getAppDataDir(std.heap.page_allocator, "coconut") catch |err| {
        std.debug.print("Error getting Cashu directory: {}\n", .{err});
        return error.CashuDirNotFound;
    };
}

fn printMintsInfo(allocator: std.mem.Allocator, writer: anytype, fetch_mint_info: bool) !void {
    // Placeholder
    const mints = [_][]const u8{"https://example.com:3338"};

    for (mints) |mint| {
        try writer.print("    - URL: {s}\n", .{mint});
        if (fetch_mint_info) {
            try fetchAndPrintMintInfo(allocator, writer, mint);
        }
        try printKeysets(allocator, writer, mint);
    }
}

fn fetchAndPrintMintInfo(allocator: std.mem.Allocator, writer: anytype, mint: []const u8) !void {
    // Placeholder
    _ = allocator;
    _ = mint;
    try writer.print("        - Mint name: Example Mint\n", .{});
    try writer.print("        - Description: An example mint\n", .{});
}

fn printKeysets(allocator: std.mem.Allocator, writer: anytype, mint: []const u8) !void {
    // Placeholder
    _ = allocator;
    _ = mint;
    try writer.print("        - Keysets:\n", .{});
    try writer.print("            - ID: example_id  unit: sat  active: True   fee (ppk): 0\n", .{});
}

fn printMnemonic(writer: anytype) !void {
    // Placeholder
    try writer.print("Mnemonic:\n - example word1 word2 word3 ...\n", .{});
}

fn printNostrInfo(writer: anytype) !void {
    // Placeholder
    try writer.print("Nostr:\n", .{});
    try writer.print("    - Public key: npub1example...\n", .{});
    try writer.print("    - Relays: wss://example1.com, wss://example2.com\n", .{});
}

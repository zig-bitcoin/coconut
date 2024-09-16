//! NUT-07: Spendable Check
//!
//! <https://github.com/cashubtc/nuts/blob/main/07.md>
const std = @import("std");
const helper = @import("../../../helper/helper.zig");
const bitcoin_primitives = @import("bitcoin-primitives");
const secp256k1 = bitcoin_primitives.secp256k1;

/// State of Proof
pub const State = enum {
    /// Spent
    spent,
    /// Unspent
    unspent,
    /// Pending
    ///
    /// Currently being used in a transaction i.e. melt in progress
    pending,
    /// Proof is reserved
    ///
    /// i.e. used to create a token
    reserved,

    pub fn jsonStringify(self: State, out: anytype) !void {
        try out.write(self.toString());
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !State {
        const state = try std.json.innerParse([]const u8, allocator, source, .{});

        return State.fromString(state) catch {
            std.log.debug("wrong state value: {s}", .{state});
            return error.UnexpectedError;
        };
    }

    pub fn toString(self: State) []const u8 {
        return switch (self) {
            .spent => "SPENT",
            .unspent => "UNSPENT",
            .pending => "PENDING",
            .reserved => "RESERVED",
        };
    }

    pub fn fromString(s: []const u8) !State {
        const kv = std.StaticStringMap(State).initComptime(
            &.{
                .{ "SPENT", State.spent },
                .{ "UNSPENT", State.unspent },
                .{ "RESERVED", State.reserved },
                .{ "PENDING", State.pending },
            },
        );

        return kv.get(s) orelse return error.UnknownState;
    }
};

/// Check spendabale request [NUT-07]
pub const CheckStateRequest = struct {
    /// Y's of the proofs to check
    ys: []const secp256k1.PublicKey,

    pub usingnamespace helper.RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "ys", "Ys",
                },
            },
        ),
    );
};

/// Proof state [NUT-07]
pub const ProofState = struct {
    /// Y of proof
    y: secp256k1.PublicKey,
    /// State of proof
    state: State,
    /// Witness data if it is supplied
    witness: ?[]const u8,

    pub usingnamespace helper.RenameJsonField(
        @This(),
        std.StaticStringMap([]const u8).initComptime(
            &.{
                .{
                    "y", "Y",
                },
            },
        ),
    );

    pub fn deinit(self: ProofState, allocator: std.mem.Allocator) void {
        if (self.witness) |witness| allocator.free(witness);
    }
};

/// Check Spendable Response [NUT-07]
pub const CheckStateResponse = struct {
    /// Proof states
    states: []const ProofState,
};

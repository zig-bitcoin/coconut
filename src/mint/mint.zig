const std = @import("std");

const core = @import("../core/lib.zig");
const database = @import("database/database.zig");
const Lightning = @import("lightning/lib.zig").Lightning;
const model = @import("model.zig");

const MintConfig = @import("config.zig").MintConfig;

pub const Mint = struct {
    const Self = @This();

    keyset: core.keyset.MintKeyset,
    config: MintConfig,
    db: database.Database,
    dhke: core.Dhke,
    allocator: std.mem.Allocator,
    lightning: Lightning,

    // init - initialized Mint using config
    pub fn init(allocator: std.mem.Allocator, config: MintConfig, lightning: Lightning) !Mint {
        var keyset = try core.keyset.MintKeyset.init(
            allocator,
            config.privatekey,
            config.derivation_path orelse &.{},
        );
        errdefer keyset.deinit();

        const db = try database.InMemory.init(allocator);
        errdefer db.deinit();

        return .{
            .keyset = keyset,
            .config = config,
            .db = db,
            .allocator = allocator,
            .dhke = try core.Dhke.init(allocator),
            .lightning = lightning,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.keyset.deinit();
        self.db.deinit();
        self.dhke.deinit();
    }

    pub fn checkedUsedProofs(self: *const Self, tx: database.Tx, proofs: []const core.proof.Proof) !void {
        const used_proofs = try self.db.getUsedProofs(tx, self.allocator);
        defer self.allocator.free(used_proofs);

        for (used_proofs) |used_proof| {
            for (proofs) |proof| if (std.meta.eql(used_proof, proof)) return error.ProofAlreadyUsed;
        }
    }

    fn hasDuplicatePubkeys(allocator: std.mem.Allocator, outputs: []const core.BlindedMessage) !bool {
        var uniq = std.AutoHashMap([64]u8, void).init(allocator);
        defer uniq.deinit();

        for (outputs) |x| {
            const res = try uniq.getOrPut(x.b_.pk.data);
            if (res.found_existing) return true;
        }

        return false;
    }
    /// caller should deinit with allocator result
    pub fn createBlindedSignatures(
        self: *const Self,
        allocator: std.mem.Allocator,
        blinded_messages: []const core.BlindedMessage,
        keyset: core.keyset.MintKeyset,
    ) ![]core.BlindedSignature {
        var res = try std.ArrayList(core.BlindedSignature).initCapacity(allocator, blinded_messages.len);
        errdefer res.deinit();

        for (blinded_messages) |blinded_msg| {
            const priv_key = keyset.private_keys.get(blinded_msg.amount) orelse return error.PrivateKeyNotFound;

            const blinded_sig = try self.dhke.step2Bob(blinded_msg.b_, priv_key);

            res.appendAssumeCapacity(.{
                .amount = blinded_msg.amount,
                .c_ = blinded_sig,
                .id = keyset.keyset_id,
            });
        }
        return try res.toOwnedSlice();
    }

    pub fn swap(
        self: *const Self,
        allocator: std.mem.Allocator,
        proofs: []const core.proof.Proof,
        blinded_messages: []const core.BlindedMessage,
        keyset: core.keyset.MintKeyset,
    ) ![]const core.BlindedSignature {
        var tx = try self.db.beginTx(allocator);
        errdefer tx.rollback() catch |err| std.log.debug("rollback err {any}", .{err});

        try self.checkedUsedProofs(tx, proofs);

        if (try Self.hasDuplicatePubkeys(self.allocator, blinded_messages)) return error.SwapHasDuplicatePromises;

        const sum_proofs = core.proof.Proof.totalAmount(proofs);

        const promises = try self.createBlindedSignatures(allocator, blinded_messages, keyset);
        errdefer allocator.free(promises);

        const amount_promises = core.BlindedSignature.totalAmount(promises);

        if (sum_proofs != amount_promises) {
            std.log.debug("Swap amount mismatch: {d} != {d}", .{
                sum_proofs, amount_promises,
            });
            return error.SwapAmountMismatch;
        }

        try self.db.addUsedProofs(tx, proofs);
        try tx.commit();

        return promises;
    }

    pub fn createInvoice(
        self: *const Self,
        allocator: std.mem.Allocator,
        key: []const u8,
        amount: u64,
    ) !model.CreateInvoiceResult {
        var tx = try self.db.beginTx(allocator);

        const inv = try self.lightning.createInvoice(allocator, amount);
        errdefer inv.deinit(allocator);

        try self.db.addPendingInvoice(allocator, tx, key, .{
            .amount = amount,
            .payment_request = inv.payment_request,
        });

        try tx.commit();

        return inv;
    }

    pub fn mintBolt11Tokens(self: *const Self, allocator: std.mem.Allocator, tx: database.Tx, key: []const u8, outputs: []const core.BlindedMessage, keyset: core.keyset.MintKeyset) ![]const core.BlindedSignature {
        const invoice = try self.db.getPendingInvoice(allocator, tx, key);
        defer invoice.deinit(allocator);

        // const is_paid = try self.lightning.isInvoicePaid(allocator, invoice.payment_request);

        try self.db.deletePendingInvoice(allocator, tx, key);

        return try self.createBlindedSignatures(allocator, outputs, keyset);
    }
};

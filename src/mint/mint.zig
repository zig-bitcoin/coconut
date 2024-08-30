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

    pub fn feeReserve(self: *const Self, amount_msat: u64) !u64 {
        const fee_percent = self.config.lightning_fee.fee_percent / 100.0;
        const fee_reserve: u64 = @intFromFloat(@as(f64, @floatFromInt(amount_msat)) * fee_percent);

        return @max(fee_reserve, self.config.lightning_fee.fee_reserve_min);
    }

    // melting using bolt11 method, returned payment hash and change, should be manually deallocated
    pub fn meltBolt11(
        self: *const Mint,
        tx: database.Tx,
        allocator: std.mem.Allocator,
        payment_request: []const u8,
        fee_reserve: u64,
        proofs: []const core.proof.Proof,
        blinded_messages: ?[]const core.BlindedMessage,
        keyset: core.keyset.MintKeyset,
    ) struct { bool, []const u8, std.ArrayList(core.BlindedSignature) } {
        _ = keyset; // autofix
        const invoice = try self.lightning.decodeInvoice(allocator, payment_request);

        const proofs_amount = core.proof.Proof.totalAmount(proofs);

        // TODO verify proofs

        try self.checkedUsedProofs(tx, proofs);

        // TODO check for fees
        const amount_msat = invoice
            .amountMilliSatoshis() orelse return error.@"Invoice amount is missing";

        if (amount_msat < (proofs_amount / 1_000)) {
            return error.@"Invoice amount is too low";
        }

        // TODO check invoice
        const result = try self.lightning.payInvoice(allocator, payment_request);
        errdefer result.deinit(allocator);

        try self.db.addUsedProofs(tx, proofs);

        var signatures = std.ArrayList(core.BlindedSignature).init(allocator);
        errdefer signatures.deinit();

        if (blinded_messages) |blinded_msgs| v: {
            if (fee_reserve) {
                const return_fees = try core.splitAmount(allocator, fee_reserve - result.total_fees);
                defer return_fees.deinit();
            }
            // if (fee_reserve > 0) {
            //     let return_fees = Amount(fee_reserve - result.total_fees).split();

            //     if (return_fees.len()) > blinded_messages.len() {
            //         // FIXME better handle case when there are more fees than blinded messages
            //         vec![]
            //     } else {
            //         let out: Vec<_> = blinded_messages[0..return_fees.len()]
            //             .iter()
            //             .zip(return_fees.into_iter())
            //             .map(|(message, fee)| BlindedMessage {
            //                 amount: fee,
            //                 ..message.clone()
            //             })
            //             .collect();

            //         self.create_blinded_signatures(&out, keyset)?
            //     }
            // } else {
            //     vec![]
            // }
        } else v: {}

        // let change = match blinded_messages {
        //     Some(blinded_messages) => {
        //         if fee_reserve > 0 {
        //             let return_fees = Amount(fee_reserve - result.total_fees).split();

        //             if (return_fees.len()) > blinded_messages.len() {
        //                 // FIXME better handle case when there are more fees than blinded messages
        //                 vec![]
        //             } else {
        //                 let out: Vec<_> = blinded_messages[0..return_fees.len()]
        //                     .iter()
        //                     .zip(return_fees.into_iter())
        //                     .map(|(message, fee)| BlindedMessage {
        //                         amount: fee,
        //                         ..message.clone()
        //                     })
        //                     .collect();

        //                 self.create_blinded_signatures(&out, keyset)?
        //             }
        //         } else {
        //             vec![]
        //         }
        //     }
        //     None => {
        //         vec![]
        //     }
        // };

        // Ok((true, result.payment_hash, change))
    }


    pub fn proccessMintRequest(self: *const Mint, tx: database.Tx,)
};

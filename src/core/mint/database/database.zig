const std = @import("std");
const core = @import("../../core/lib.zig");
const model = @import("../model.zig");
const zul = @import("zul");

// TODO remove deinit from Database and Tx(?)
pub const Tx = struct {
    // These two fields are the same as before
    ptr: *anyopaque,
    commitFn: *const fn (ptr: *anyopaque) anyerror!void,
    rollbackFn: *const fn (ptr: *anyopaque) anyerror!void,
    deinitFn: *const fn (ptr: *anyopaque) void,

    // This is new
    fn init(ptr: anytype) Tx {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const gen = struct {
            pub fn commit(pointer: *anyopaque) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.commit(self);
            }

            pub fn rollback(pointer: *anyopaque) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.rollback(self);
            }

            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.deinit(self);
            }
        };

        return .{
            .ptr = ptr,
            .commitFn = gen.commit,
            .rollbackFn = gen.rollback,
            .deinitFn = gen.deinit,
        };
    }

    // This is the same as before
    pub fn commit(self: *Tx) !void {
        return self.commitFn(self.ptr);
    }

    pub fn rollback(self: *Tx) !void {
        return self.rollbackFn(self.ptr);
    }

    pub fn deinit(self: *Tx) void {
        return self.deinitFn(self.ptr);
    }
};

pub const Database = struct {
    // These two fields are the same as before
    ptr: *anyopaque,
    beginTxFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!Tx,

    deinitFn: *const fn (ptr: *anyopaque) void,
    addUsedProofsFn: *const fn (ptr: *anyopaque, tx: Tx, proofs: []const core.proof.Proof) anyerror!void,
    getUsedProofsFn: *const fn (ptr: *anyopaque, tx: Tx, allocator: std.mem.Allocator) anyerror![]core.proof.Proof,

    addPendingInvoiceFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, tx: Tx, key: []const u8, invoice: model.Invoice) anyerror!void,
    getPendingInvoiceFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, tx: Tx, key: []const u8) anyerror!model.Invoice,
    deletePendingInvoiceFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, tx: Tx, key: []const u8) anyerror!void,

    getBolt11MintQuoteFn: *const fn (ptr: *anyopaque, _: std.mem.Allocator, _: Tx, id: zul.UUID) anyerror!core.primitives.Bolt11MintQuote,

    updateBolt11MintQuoteFn: *const fn (ptr: *anyopaque, _: std.mem.Allocator, _: Tx, quote: core.primitives.Bolt11MintQuote) anyerror!void,

    addBolt11MintQuoteFn: *const fn (ptr: *anyopaque, _: std.mem.Allocator, _: Tx, _: core.primitives.Bolt11MintQuote) anyerror!void,

    getBolt11MeltQuoteFn: *const fn (ptr: *anyopaque, _: std.mem.Allocator, _: Tx, id: zul.UUID) anyerror!core.primitives.Bolt11MeltQuote,

    updateBolt11MeltQuoteFn: *const fn (ptr: *anyopaque, _: std.mem.Allocator, _: Tx, quote: core.primitives.Bolt11MeltQuote) anyerror!void,

    addBolt11MeltQuoteFn: *const fn (ptr: *anyopaque, _: std.mem.Allocator, _: Tx, _: core.primitives.Bolt11MeltQuote) anyerror!void,

    // This is new
    fn init(ptr: anytype) Database {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const gen = struct {
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.deinit(self);
            }

            pub fn beginTx(pointer: *anyopaque, allocator: std.mem.Allocator) anyerror!Tx {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.beginTx(self, allocator);
            }

            pub fn addUsedProofs(pointer: *anyopaque, tx: Tx, proofs: []const core.proof.Proof) !void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.addUsedProofs(self, tx, proofs);
            }

            pub fn getUsedProofs(pointer: *anyopaque, tx: Tx, allocator: std.mem.Allocator) ![]core.proof.Proof {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.getUsedProofs(self, tx, allocator);
            }

            pub fn addPendingInvoice(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, key: []const u8, invoice: model.Invoice) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.addPendingInvoice(self, allocator, tx, key, invoice);
            }

            pub fn getPendingInvoice(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, key: []const u8) anyerror!model.Invoice {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.getPendingInvoice(self, allocator, tx, key);
            }

            pub fn deletePendingInvoice(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, key: []const u8) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.deletePendingInvoice(self, allocator, tx, key);
            }

            pub fn updateBolt11MintQuote(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MintQuote) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.updateBolt11MintQuote(self, allocator, tx, quote);
            }

            pub fn getBolt11MintQuote(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, id: zul.UUID) !core.primitives.Bolt11MintQuote {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.getBolt11MintQuote(self, allocator, tx, id);
            }

            pub fn addBolt11MintQuote(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MintQuote) !void {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.addBolt11MintQuote(self, allocator, tx, quote);
            }

            pub fn updateBolt11MeltQuote(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MeltQuote) anyerror!void {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.updateBolt11MeltQuote(self, allocator, tx, quote);
            }

            pub fn getBolt11MeltQuote(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, id: zul.UUID) !core.primitives.Bolt11MeltQuote {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.getBolt11MeltQuote(self, allocator, tx, id);
            }

            pub fn addBolt11MeltQuote(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MeltQuote) !void {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.addBolt11MeltQuote(self, allocator, tx, quote);
            }
        };

        return .{
            .ptr = @ptrCast(ptr),
            .beginTxFn = gen.beginTx,
            .deinitFn = gen.deinit,
            .addUsedProofsFn = gen.addUsedProofs,
            .getUsedProofsFn = gen.getUsedProofs,
            .addPendingInvoiceFn = gen.addPendingInvoice,
            .getPendingInvoiceFn = gen.getPendingInvoice,
            .deletePendingInvoiceFn = gen.deletePendingInvoice,
            .updateBolt11MintQuoteFn = gen.updateBolt11MintQuote,
            .getBolt11MintQuoteFn = gen.getBolt11MintQuote,
            .addBolt11MintQuoteFn = gen.addBolt11MintQuote,

            .updateBolt11MeltQuoteFn = gen.updateBolt11MeltQuote,
            .getBolt11MeltQuoteFn = gen.getBolt11MeltQuote,
            .addBolt11MeltQuoteFn = gen.addBolt11MeltQuote,
        };
    }

    // This is the same as before
    pub fn beginTx(self: Database, allocator: std.mem.Allocator) !Tx {
        return self.beginTxFn(self.ptr, allocator);
    }

    pub fn addUsedProofs(self: Database, tx: Tx, proofs: []const core.proof.Proof) !void {
        return self.addUsedProofsFn(self.ptr, tx, proofs);
    }

    pub fn getUsedProofs(self: Database, tx: Tx, allocator: std.mem.Allocator) ![]core.proof.Proof {
        return self.getUsedProofsFn(self.ptr, tx, allocator);
    }

    pub fn addPendingInvoice(self: Database, allocator: std.mem.Allocator, tx: Tx, key: []const u8, invoice: model.Invoice) !void {
        return self.addPendingInvoiceFn(self.ptr, allocator, tx, key, invoice);
    }

    pub fn getPendingInvoice(self: Database, allocator: std.mem.Allocator, tx: Tx, key: []const u8) !model.Invoice {
        return self.getPendingInvoiceFn(self.ptr, allocator, tx, key);
    }

    pub fn deletePendingInvoice(self: Database, allocator: std.mem.Allocator, tx: Tx, key: []const u8) !void {
        return self.deletePendingInvoiceFn(self.ptr, allocator, tx, key);
    }

    pub fn getBolt11MintQuote(self: Database, allocator: std.mem.Allocator, tx: Tx, id: zul.UUID) !core.primitives.Bolt11MintQuote {
        return self.getBolt11MintQuoteFn(self.ptr, allocator, tx, id);
    }

    pub fn updateBolt11MintQuote(self: Database, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MintQuote) !void {
        return self.updateBolt11MintQuoteFn(self.ptr, allocator, tx, quote);
    }

    pub fn addBolt11MintQuote(self: Database, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MintQuote) !void {
        return self.addBolt11MintQuoteFn(self.ptr, allocator, tx, quote);
    }

    pub fn getBolt11MeltQuote(self: Database, allocator: std.mem.Allocator, tx: Tx, id: zul.UUID) !core.primitives.Bolt11MeltQuote {
        return self.getBolt11MeltQuoteFn(self.ptr, allocator, tx, id);
    }

    pub fn updateBolt11MeltQuote(self: Database, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MeltQuote) !void {
        return self.updateBolt11MeltQuoteFn(self.ptr, allocator, tx, quote);
    }

    pub fn addBolt11MeltQuote(self: Database, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MeltQuote) !void {
        return self.addBolt11MeltQuoteFn(self.ptr, allocator, tx, quote);
    }

    pub fn deinit(self: Database) void {
        return self.deinitFn(self.ptr);
    }
};

pub const InMemory = struct {
    const Self = @This();

    const BaseTx = struct {
        allocator: std.mem.Allocator,
        // TODO make it better

        pub fn init(allocator: std.mem.Allocator) !*BaseTx {
            // allocator.
            var self = try allocator.create(@This());
            self.allocator = allocator;
            return self;
        }

        pub fn commit(self: *@This()) !void {
            _ = self;
        }

        pub fn rollback(self: *@This()) !void {
            _ = self;
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.destroy(self);
        }
    };

    const Bolt11MintQuotes = struct {
        const Bolt11MintQuote = struct {
            id: zul.UUID,
            payment_request: []const u8,
            expiry: u64,
            paid: bool,

            pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
                allocator.free(self.payment_request);
            }
        };

        quotes: std.ArrayList(Bolt11MintQuote),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) !Bolt11MintQuotes {
            return .{
                .quotes = std.ArrayList(Bolt11MintQuote).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: @This()) void {
            for (self.quotes.items) |q| q.deinit();
        }

        fn update(self: *@This(), quote: core.primitives.Bolt11MintQuote) !void {
            if (self.getPtr(quote.quote_id)) |q| {
                const q_old = q.*;
                const q_cloned = try quote.clone(self.allocator);

                q.* = Bolt11MintQuote{
                    .id = q_cloned.quote_id,
                    .payment_request = q_cloned.payment_request,
                    .expiry = q_cloned.expiry,
                    .paid = q_cloned.paid,
                };
                q_old.deinit(self.allocator);
            } else return error.QuoteNotFound;
        }

        fn add(self: *@This(), quote: core.primitives.Bolt11MintQuote) !void {
            if (self.get(quote.quote_id) != null) return error.QuoteAlreadyExist;

            const payment_request = try self.allocator.alloc(u8, quote.payment_request.len);
            errdefer self.allocator.free(payment_request);

            try self.quotes.append(.{
                .id = quote.quote_id,
                .payment_request = payment_request,
                .expiry = quote.expiry,
                .paid = quote.paid,
            });
        }

        fn get(self: *@This(), id: zul.UUID) ?Bolt11MintQuote {
            for (self.quotes.items) |i| if (id.eql(i.id)) return i;

            return null;
        }

        fn getPtr(self: *@This(), id: zul.UUID) ?*Bolt11MintQuote {
            for (self.quotes.items) |*i| if (id.eql(i.id)) return i;

            return null;
        }

        fn delete(self: *@This(), id: zul.UUID) !void {
            for (0.., self.quotes.items) |idx, i| {
                if (i.eql(id)) {
                    self.quotes.orderedRemove(idx);
                    return;
                }
            }
        }
    };

    const Bolt11MeltQuotes = struct {
        quotes: std.ArrayList(core.primitives.Bolt11MeltQuote),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) !Bolt11MeltQuotes {
            return .{
                .quotes = std.ArrayList(core.primitives.Bolt11MeltQuote).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: @This()) void {
            for (self.quotes.items) |q| q.deinit();
        }

        fn update(self: *@This(), quote: core.primitives.Bolt11MeltQuote) !void {
            if (self.getPtr(quote.quote_id)) |q| {
                const q_old = q.*;
                q.* = try quote.clone(self.allocator);
                q_old.deinit(self.allocator);
            } else return error.QuoteNotFound;
        }

        fn add(self: *@This(), quote: core.primitives.Bolt11MeltQuote) !void {
            if (self.get(quote.quote_id) != null) return error.QuoteAlreadyExist;

            const new = try quote.clone(self.allocator);
            errdefer new.deinit(self.allocator);

            try self.quotes.append(new);
        }

        fn get(self: *@This(), id: zul.UUID) ?core.primitives.Bolt11MeltQuote {
            for (self.quotes.items) |i| if (id.eql(i.quote_id)) return i;

            return null;
        }

        fn getPtr(self: *@This(), id: zul.UUID) ?*core.primitives.Bolt11MeltQuote {
            for (self.quotes.items) |*i| if (id.eql(i.quote_id)) return i;

            return null;
        }

        fn delete(self: *@This(), id: zul.UUID) !void {
            for (0.., self.quotes.items) |idx, i| {
                if (i.quote_id.eql(id)) {
                    self.quotes.orderedRemove(idx);
                    return;
                }
            }
        }
    };

    const PendingInvoices = struct {
        const PendingInvoice = struct {
            key: []const u8,
            amount: u64,
            payment_request: []const u8,

            fn deinit(self: PendingInvoice, allocator: std.mem.Allocator) void {
                allocator.free(self.key);
                allocator.free(self.payment_request);
            }
        };

        invoices: std.ArrayList(PendingInvoice),
        allocator: std.mem.Allocator,

        fn deinit(self: PendingInvoices) void {
            for (self.invoices.items) |i| i.deinit();
        }

        fn init(allocator: std.mem.Allocator) !PendingInvoices {
            return .{
                .invoices = std.ArrayList(PendingInvoice).init(allocator),
                .allocator = allocator,
            };
        }

        fn add(self: *@This(), invoice: PendingInvoice) !void {
            if (self.get(invoice.key) != null) return error.InvoiceDuplicate;

            const key = try self.allocator.alloc(u8, invoice.key.len);
            errdefer self.allocator.free(key);

            const payment_request = try self.allocator.alloc(u8, invoice.payment_request.len);
            errdefer self.allocator.free(payment_request);

            try self.invoices.append(.{ .key = key, .payment_request = payment_request, .amount = invoice.amount });
        }

        fn get(self: *@This(), key: []const u8) ?PendingInvoice {
            for (self.invoices.items) |i| if (std.mem.eql(u8, i.key, key)) return i;
            return null;
        }

        fn delete(self: *@This(), key: []const u8) !void {
            for (0.., self.invoices.items) |idx, i| {
                if (std.mem.eql(u8, i.key, key)) {
                    _ = self.invoices.orderedRemove(idx);
                    return;
                }
            }
        }
    };

    allocator: std.mem.Allocator,
    proofs: std.ArrayList(core.proof.Proof),
    pending_invoices: PendingInvoices,
    mint_quotes: Bolt11MintQuotes,
    melt_quotes: Bolt11MeltQuotes,

    pub fn init(allocator: std.mem.Allocator) !Database {
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.proofs = std.ArrayList(core.proof.Proof).init(allocator);

        self.pending_invoices = try PendingInvoices.init(allocator);
        errdefer self.pending_invoices.deinit();

        self.mint_quotes = try Bolt11MintQuotes.init(allocator);
        errdefer self.mint_quotes.deinit();

        self.melt_quotes = try Bolt11MeltQuotes.init(allocator);
        errdefer self.melt_quotes.deinit();

        return Database.init(self);
    }

    pub fn deinit(self: *Self) void {
        self.proofs.deinit();
        self.allocator.destroy(self);
    }

    pub fn beginTx(self: *Self, allocator: std.mem.Allocator) !Tx {
        _ = self; // autofix
        return Tx.init(try BaseTx.init(allocator));
    }

    pub fn addUsedProofs(self: *Self, tx: Tx, proofs: []const core.proof.Proof) !void {
        _ = tx; // autofix

        try self.proofs.appendSlice(proofs);
    }

    pub fn getUsedProofs(self: *Self, tx: Tx, allocator: std.mem.Allocator) ![]core.proof.Proof {
        _ = tx; // autofix
        const res = try allocator.alloc(core.proof.Proof, self.proofs.items.len);
        errdefer allocator.free(res);

        @memcpy(res, self.proofs.items);

        return res;
    }

    pub fn addPendingInvoice(self: *Self, _: std.mem.Allocator, _: Tx, key: []const u8, invoice: model.Invoice) anyerror!void {
        try self.pending_invoices.add(.{ .key = key, .amount = invoice.amount, .payment_request = invoice.payment_request });
    }

    pub fn getPendingInvoice(self: *Self, allocator: std.mem.Allocator, _: Tx, key: []const u8) !model.Invoice {
        const invoice = self.pending_invoices.get(key) orelse return error.PendingInvoiceNotFound;

        const inv = model.Invoice{ .amount = invoice.amount, .payment_request = invoice.payment_request };

        return inv.clone(allocator);
    }

    pub fn deletePendingInvoice(self: *Self, _: std.mem.Allocator, _: Tx, key: []const u8) anyerror!void {
        return try self.pending_invoices.delete(key);
    }

    pub fn getBolt11MintQuote(self: *Self, allocator: std.mem.Allocator, _: Tx, id: zul.UUID) !core.primitives.Bolt11MintQuote {
        const q = self.mint_quotes.get(id) orelse return error.NotFound;

        const qq = core.primitives.Bolt11MintQuote{
            .quote_id = q.id,
            .payment_request = q.payment_request,
            .expiry = q.expiry,
            .paid = q.paid,
        };

        return qq.clone(allocator);
    }

    pub fn addBolt11MintQuote(self: *Self, _: std.mem.Allocator, _: Tx, quote: core.primitives.Bolt11MintQuote) !void {
        return self.mint_quotes.add(quote);
    }

    pub fn updateBolt11MintQuote(self: *Self, _: std.mem.Allocator, _: Tx, quote: core.primitives.Bolt11MintQuote) !void {
        return self.mint_quotes.update(quote);
    }

    pub fn getBolt11MeltQuote(self: *Self, allocator: std.mem.Allocator, _: Tx, id: zul.UUID) !core.primitives.Bolt11MeltQuote {
        const q = self.melt_quotes.get(id) orelse return error.NotFound;

        return q.clone(allocator);
    }

    pub fn addBolt11MeltQuote(self: *Self, _: std.mem.Allocator, _: Tx, quote: core.primitives.Bolt11MeltQuote) !void {
        return self.melt_quotes.add(quote);
    }

    pub fn updateBolt11MeltQuote(self: *Self, _: std.mem.Allocator, _: Tx, quote: core.primitives.Bolt11MeltQuote) !void {
        return self.melt_quotes.update(quote);
    }
};

test "dfd" {
    var db = try InMemory.init(std.testing.allocator);
    defer db.deinit();

    var tx = try db.beginTx(std.testing.allocator);
    defer tx.deinit();

    const pr: core.proof.Proof = undefined;

    try db.addUsedProofs(tx, &.{pr});

    const proofs = try db.getUsedProofs(tx, std.testing.allocator);
    defer std.testing.allocator.free(proofs);

    try std.testing.expectEqual(1, proofs.len);
    try std.testing.expectEqual(pr, proofs[0]);
}

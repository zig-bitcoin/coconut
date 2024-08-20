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

    getBolt11MintQuoteFn: *const fn (ptr: *anyopaque, _: std.mem.Allocator, _: Tx, id: zul.UUID) anyerror!core.primitives.Bolt11MintQuote,

    addBolt11MintQuoteFn: *const fn (ptr: *anyopaque, _: std.mem.Allocator, _: Tx, _: core.primitives.Bolt11MintQuote) anyerror!void,

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

            pub fn getBolt11MintQuote(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, id: zul.UUID) !core.primitives.Bolt11MintQuote {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.getBolt11MintQuote(self, allocator, tx, id);
            }

            pub fn addBolt11MintQuote(pointer: *anyopaque, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MintQuote) !void {
                const self: T = @ptrCast(@alignCast(pointer));

                return ptr_info.Pointer.child.addBolt11MintQuote(self, allocator, tx, quote);
            }
        };

        return .{
            .ptr = @ptrCast(ptr),
            .beginTxFn = gen.beginTx,
            .deinitFn = gen.deinit,
            .addUsedProofsFn = gen.addUsedProofs,
            .getUsedProofsFn = gen.getUsedProofs,
            .addPendingInvoiceFn = gen.addPendingInvoice,
            .getBolt11MintQuoteFn = gen.getBolt11MintQuote,
            .addBolt11MintQuoteFn = gen.addBolt11MintQuote,
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

    pub fn addPendingInvoice(self: Database, allocator: std.mem.Allocator, tx: Tx, key: []const u8, invoice: model.Invoice) anyerror!void {
        return self.addPendingInvoiceFn(self.ptr, allocator, tx, key, invoice);
    }

    pub fn getBolt11MintQuote(self: Database, allocator: std.mem.Allocator, tx: Tx, id: zul.UUID) !core.primitives.Bolt11MintQuote {
        return self.getBolt11MintQuoteFn(self.ptr, allocator, tx, id);
    }

    pub fn addBolt11MintQuote(self: Database, allocator: std.mem.Allocator, tx: Tx, quote: core.primitives.Bolt11MintQuote) !void {
        return self.addBolt11MintQuoteFn(self.ptr, allocator, tx, quote);
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

        fn delete(self: *@This(), id: zul.UUID) !void {
            for (0.., self.quotes.items) |idx, i| {
                if (i.eql(id)) {
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
                    self.invoices.orderedRemove(idx);
                    return;
                }
            }
        }
    };

    allocator: std.mem.Allocator,
    proofs: std.ArrayList(core.proof.Proof),
    pending_invoices: PendingInvoices,
    quotes: Bolt11MintQuotes,

    pub fn init(allocator: std.mem.Allocator) !Database {
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.proofs = std.ArrayList(core.proof.Proof).init(allocator);

        self.pending_invoices = try PendingInvoices.init(allocator);
        errdefer self.pending_invoices.deinit();

        self.quotes = try Bolt11MintQuotes.init(allocator);
        errdefer self.quotes.deinit();

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

    pub fn getBolt11MintQuote(self: *Self, allocator: std.mem.Allocator, _: Tx, id: zul.UUID) !core.primitives.Bolt11MintQuote {
        const q = self.quotes.get(id) orelse return error.NotFound;

        const qq = core.primitives.Bolt11MintQuote{
            .quote_id = q.id,
            .payment_request = q.payment_request,
            .expiry = q.expiry,
            .paid = q.paid,
        };

        return qq.clone(allocator);
    }

    pub fn addBolt11MintQuote(self: *Self, _: std.mem.Allocator, _: Tx, quote: core.primitives.Bolt11MintQuote) !void {
        return self.quotes.add(quote);
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

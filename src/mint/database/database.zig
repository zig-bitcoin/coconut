const std = @import("std");
const core = @import("../../core/lib.zig");

const Tx = struct {
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

const Database = struct {
    // These two fields are the same as before
    ptr: *anyopaque,
    beginTxFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!Tx,

    deinitFn: *const fn (ptr: *anyopaque) void,
    addUsedProofsFn: *const fn (ptr: *anyopaque, tx: Tx, proofs: []const core.proof.Proof) anyerror!void,
    getUsedProofsFn: *const fn (ptr: *anyopaque, tx: Tx, allocator: std.mem.Allocator) anyerror![]core.proof.Proof,

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
        };

        return .{
            .ptr = @ptrCast(ptr),
            .beginTxFn = gen.beginTx,
            .deinitFn = gen.deinit,
            .addUsedProofsFn = gen.addUsedProofs,
            .getUsedProofsFn = gen.getUsedProofs,
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

    pub fn deinit(self: Database) void {
        return self.deinitFn(self.ptr);
    }
};

const InMemory = struct {
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

    allocator: std.mem.Allocator,
    proofs: std.ArrayList(core.proof.Proof),

    pub fn init(allocator: std.mem.Allocator) !Database {
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.proofs = std.ArrayList(core.proof.Proof).init(allocator);

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

const std = @import("std");
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const Allocator = std.mem.Allocator;

pub fn Channel(comptime T: type) type {
    return struct {
        allocator: Allocator,
        mutex: Mutex = .{},
        txCond: Condition = .{}, // Optimized for many threads, rather than using broadcast to wake all threads, which could potentially waste resources.
        rxCond: Condition = .{}, // Optimized for many threads, rather than using broadcast to wake all threads, which could potentially waste resources.
        queue: std.DoublyLinkedList(T) = .{},
        cap: usize,

        pub const Chan = @This();

        pub const Tx = struct {
            chan: *Chan,

            pub fn send(self: *const Tx, element: T) !void {
                try self.chan.put(element);
            }
        };

        pub const Rx = struct {
            chan: *Chan,

            pub fn recv(self: *const Rx) T {
                return self.chan.take();
            }
        };

        pub fn init(allocator: Allocator, cap: usize) !*Chan {
            const chan = try allocator.create(Chan);

            chan.* = .{ .allocator = allocator, .cap = cap + 1 };

            return chan;
        }

        pub fn deinit(self: *Chan) void {
            self.mutex.lock();
            const allocator = self.allocator;
            defer {
                self.mutex.unlock();
                self.* = undefined; // Set Channel instance to undefined to catch any use-after-free in debug mode.
                allocator.destroy(self);
            }

            while (self.queue.popFirst()) |node| {
                self.allocator.destroy(node);
            }
        }

        pub fn getTx(self: *Chan) Tx {
            return .{ .chan = self };
        }

        pub fn getRx(self: *Chan) Rx {
            return .{ .chan = self };
        }

        pub fn put(self: *Chan, data: T) !void {
            self.mutex.lock();
            defer {
                self.mutex.unlock();
                self.rxCond.signal();
            }

            while (self.queue.len >= self.cap) self.txCond.wait(&self.mutex);

            const node = try self.allocator.create(std.DoublyLinkedList(T).Node);
            node.data = data;

            self.queue.append(node);
        }

        pub fn take(self: *Chan) T {
            self.mutex.lock();
            defer {
                self.mutex.unlock();
                self.txCond.signal();
            }

            while (true) {
                const node = self.queue.popFirst() orelse {
                    self.rxCond.wait(&self.mutex);
                    continue;
                };
                defer self.allocator.destroy(node);

                return node.data;
            }
        }
    };
}

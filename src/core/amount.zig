const std = @import("std");

pub const Amount = u64;

pub fn split(self: Amount, allocator: std.mem.Allocator) !std.ArrayList(Amount) {
    const sats: u64 = self;
    var result = std.ArrayList(Amount).init(allocator);
    errdefer result.deinit();

    var i: u64 = 64;
    while (i > 0) {
        i -= 1;

        const part = std.math.shl(u64, 1, i);

        if ((sats & part) == part) {
            try result.append(part);
        }
    }

    return result;
}

pub fn sum(t: []const Amount) Amount {
    var a: Amount = 0;
    for (t) |e| a += e;
    return a;
}

/// Split into parts that are powers of two by target
pub fn splitTargeted(self: Amount, allocator: std.mem.Allocator, target: SplitTarget) !std.ArrayList(Amount) {
    const parts = switch (target) {
        .none => try split(self, allocator),
        .value => |amount| v: {
            if (self <= amount) {
                return split(self, allocator);
            }

            var parts_total: Amount = 0;
            var parts = std.ArrayList(Amount).init(allocator);
            errdefer parts.deinit();

            // The powers of two that are need to create target value
            const parts_of_value = try split(amount, allocator);
            defer parts_of_value.deinit();

            while (parts_total < self) {
                for (parts_of_value.items) |part| {
                    if ((part + parts_total) <= self) {
                        try parts.append(part);
                    } else {
                        const amount_left = self - parts_total;
                        const amount_left_splitted = try split(amount_left, allocator);
                        defer amount_left_splitted.deinit();

                        try parts.appendSlice(amount_left_splitted.items);
                    }

                    parts_total = sum(parts.items);

                    if (parts_total == self) {
                        break;
                    }
                }
            }

            break :v parts;
        },
        .values => |values| v: {
            const values_total: Amount = sum(values);

            switch (std.math.order(self, values_total)) {
                .eq => {
                    var result = try std.ArrayList(Amount).initCapacity(allocator, values.len);
                    errdefer result.deinit();

                    result.appendSliceAssumeCapacity(values);
                    break :v result;
                },
                .lt => return error.SplitValuesGreater,
                .gt => {
                    const extra = self - values_total;
                    var extra_amount = try split(extra, allocator);
                    defer extra_amount.deinit();

                    var result = try std.ArrayList(Amount).initCapacity(allocator, values.len + extra_amount.items.len);
                    errdefer result.deinit();

                    result.appendSliceAssumeCapacity(values);
                    result.appendSliceAssumeCapacity(extra_amount.items);

                    break :v result;
                },
            }
        },
    };

    std.sort.block(Amount, parts.items, {}, (struct {
        pub fn compare(_: void, lhs: Amount, rhs: Amount) bool {
            return lhs < rhs;
        }
    }).compare);

    return parts;
}

/// Kinds of targeting that are supported
pub const SplitTarget = union(enum) {
    /// Default target; least amount of proofs
    none,
    /// Target amount for wallet to have most proofs that add up to value
    value: Amount,
    /// Specific amounts to split into **MUST** equal amount being split
    values: []const Amount,
};

test "test_split_amount" {
    {
        var splitted = try split(@as(Amount, 1), std.testing.allocator);

        defer splitted.deinit();
        try std.testing.expectEqualSlices(Amount, &.{1}, splitted.items);
    }
    {
        var splitted = try split(@as(Amount, 2), std.testing.allocator);

        defer splitted.deinit();
        try std.testing.expectEqualSlices(Amount, &.{2}, splitted.items);
    }
    {
        var splitted = try split(3, std.testing.allocator);

        defer splitted.deinit();
        try std.testing.expectEqualSlices(Amount, &.{ 2, 1 }, splitted.items);
    }
    {
        var splitted = try split(11, std.testing.allocator);

        defer splitted.deinit();
        try std.testing.expectEqualSlices(Amount, &.{ 8, 2, 1 }, splitted.items);
    }
    {
        var splitted = try split(255, std.testing.allocator);

        defer splitted.deinit();
        try std.testing.expectEqualSlices(Amount, &.{ 128, 64, 32, 16, 8, 4, 2, 1 }, splitted.items);
    }
}

test "test_split_target_amount" {
    {
        const splitted =
            try splitTargeted(65, std.testing.allocator, .{ .value = 32 });
        defer splitted.deinit();

        try std.testing.expectEqualSlices(Amount, &.{ 1, 32, 32 }, splitted.items);
    }
    {
        const splitted =
            try splitTargeted(150, std.testing.allocator, .{ .value = 50 });
        defer splitted.deinit();

        try std.testing.expectEqualSlices(Amount, &.{ 2, 2, 2, 16, 16, 16, 32, 32, 32 }, splitted.items);
    }

    {
        const splitted =
            try splitTargeted(63, std.testing.allocator, .{ .value = 32 });
        defer splitted.deinit();

        try std.testing.expectEqualSlices(Amount, &.{ 1, 2, 4, 8, 16, 32 }, splitted.items);
    }
}

test "test_split_values" {
    {
        const target: []const Amount = &.{ 2, 4, 4 };

        const values = try splitTargeted(10, std.testing.allocator, .{ .values = target });
        defer values.deinit();

        try std.testing.expectEqualSlices(Amount, target, values.items);
    }
    {
        const target: []const Amount = &.{ 2, 4, 4 };

        const values = try splitTargeted(10, std.testing.allocator, .{ .values = &.{ 2, 4 } });
        defer values.deinit();

        try std.testing.expectEqualSlices(Amount, target, values.items);
    }

    try std.testing.expectError(error.SplitValuesGreater, splitTargeted(10, std.testing.allocator, .{ .values = &.{ 2, 10 } }));
}

const std = @import("std");

// TODO add atomic ref count?
pub fn RWMutex(comptime T: type) type {
    return struct {
        value: T,
        lock: std.Thread.RwLock,
    };
}

pub inline fn copySlice(allocator: std.mem.Allocator, slice: []const u8) ![]u8 {
    const allocated = try allocator.alloc(u8, slice.len);

    @memcpy(allocated, slice);
    return allocated;
}

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            var parsed = Parsed(T){
                .arena = try allocator.create(std.heap.ArenaAllocator),
                .value = undefined,
            };
            errdefer allocator.destroy(parsed.arena);

            parsed.arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer parsed.arena.deinit();

            return parsed;
        }

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

pub fn clone2dArrayToSlice(comptime T: type, allocator: std.mem.Allocator, array: std.ArrayList(std.ArrayList(T))) ![]const []const T {
    var result = try allocator.alloc([]const T, array.items.len);
    errdefer {
        for (result) |r| allocator.free(r);
        allocator.free(result);
    }

    for (0.., array.items) |idx, arr| {
        const slice = try allocator.alloc(T, arr.items.len);

        @memcpy(slice, arr.items);
        result[idx] = slice;
    }

    return result;
}

pub fn clone3dArrayToSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    arr: std.ArrayList(std.ArrayList(std.ArrayList(T))),
) ![]const []const []const T {
    var result = try allocator.alloc([]const []const T, arr.items.len);
    errdefer {
        for (result) |rr| {
            for (rr) |rrr| allocator.free(rrr);
            allocator.free(rr);
        }

        allocator.free(result);
    }

    for (0.., arr.items) |idx, ar| {
        result[idx] = try clone2dArrayToSlice(T, allocator, ar);
    }

    return result;
}

pub fn clone3dSliceToArrayList(comptime T: type, allocator: std.mem.Allocator, slice: []const []const []const T) !std.ArrayList(std.ArrayList(std.ArrayList(T))) {
    var result = try std.ArrayList(std.ArrayList(std.ArrayList(T))).initCapacity(allocator, slice.len);
    errdefer {
        for (result.items) |r| {
            for (r.items) |rr| rr.deinit();
            r.deinit();
        }

        result.deinit();
    }

    for (slice) |item| {
        result.appendAssumeCapacity(try clone2dSliceToArrayList(T, allocator, item));
    }

    return result;
}

pub fn clone2dSliceToArrayList(comptime T: type, allocator: std.mem.Allocator, slice: []const []const T) !std.ArrayList(std.ArrayList(T)) {
    var result = try std.ArrayList(std.ArrayList(T)).initCapacity(allocator, slice.len);
    errdefer {
        for (result.items) |r| r.deinit();
    }

    for (slice) |item| {
        var sl = try std.ArrayList(T).initCapacity(allocator, item.len);

        sl.appendSliceAssumeCapacity(item);

        result.appendAssumeCapacity(sl);
    }

    return result;
}

pub fn JsonArrayList(comptime T: type) type {
    return struct {
        const Self = @This();

        value: std.ArrayList(T),

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            if (try source.next() != .array_begin) return error.UnexpectedToken;

            var result = std.ArrayList(T).init(allocator);
            errdefer result.deinit();

            while (try source.peekNextTokenType() != .array_end) {
                const val = try std.json.innerParse(T, allocator, source, options);

                try result.append(val);
            }

            // array_end
            _ = try source.next();

            return .{ .value = result };
        }
    };
}

pub fn fieldType(comptime T: type, comptime name: []const u8) ?type {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, name))
            return field.type;
    }

    return null;
}

// TODO add check for hash map
pub fn RenameJsonField(comptime T: type, comptime field_from_to: std.StaticStringMap([]const u8)) type {
    const field = comptime @typeInfo(T).@"struct";
    const full_map = comptime blk: {
        var result: [field.fields.len]struct { []const u8, []const u8 } = undefined;

        for (0.., field.fields) |x, f| {
            var found: bool = false;

            for (0..field_from_to.kvs.len) |i| {
                if (std.mem.eql(u8, f.name, field_from_to.kvs.keys[i])) {
                    found = true;
                    result[x] = .{ f.name, field_from_to.kvs.values[i] };
                    break;
                }
            }

            if (!found) {
                result[x] = .{ f.name, f.name };
            }
        }

        break :blk result;
    };
    const ffto = std.StaticStringMap([]const u8).initComptime(full_map);

    return struct {
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !T {
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            var res: T = undefined;

            var fields_seen = [_]bool{false} ** full_map.len;

            while (true) {
                // taking token name from source
                const name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                const field_name = switch (name_token.?) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => { // No more fields.
                        break;
                    },
                    else => {
                        std.log.debug("unexpected token: {any}", .{name_token});
                        return error.UnexpectedToken;
                    },
                };

                var f = false;

                inline for (0.., full_map) |i, p| {
                    if (std.mem.eql(u8, p[1], field_name)) {
                        @field(&res, p[0]) = try std.json.innerParse(fieldType(T, p[0]).?, allocator, source, options);
                        f = true;
                        fields_seen[i] = true;
                        break;
                    }
                }

                if (!f) {
                    // not found field in struct
                    if (options.ignore_unknown_fields) {
                        std.log.debug("field is not exist in Type {s}, field name = {s} ", .{
                            @typeName(T),
                            field_name,
                        });
                        return error.MissingField;
                    }

                    // we need to read value
                    _ = try source.next();
                }
            }

            for (0.., fields_seen) |i, seen| {
                if (!seen) {
                    inline for (field.fields) |f| {
                        if (std.mem.eql(u8, f.name, full_map[i][0])) {
                            if (f.default_value) |default_ptr| {
                                const default = @as(*align(1) const f.type, @ptrCast(default_ptr)).*;
                                @field(&res, f.name) = default;
                            } else {
                                return error.MissingField;
                            }
                        }
                    }
                }
            }

            return res;
        }

        pub fn jsonStringify(self: anytype, out: anytype) !void {
            try out.beginObject();

            switch (@typeInfo(@TypeOf(self))) {
                .pointer => |p| {
                    switch (@typeInfo(p.child)) {
                        .@"struct" => |S| {
                            inline for (S.fields) |Field| {
                                // don't include void fields
                                if (Field.type == void) continue;

                                var emit_field = true;

                                // don't include optional fields that are null when emit_null_optional_fields is set to false
                                if (@typeInfo(Field.type) == .optional) {
                                    if (out.options.emit_null_optional_fields == false) {
                                        if (@field(self, Field.name) == null) {
                                            emit_field = false;
                                        }
                                    }
                                }

                                if (emit_field) {
                                    try out.objectField(ffto.get(Field.name) orelse return error.OutOfMemory);
                                }
                                try out.write(@field(self, Field.name));
                            }

                            try out.endObject();
                            return;
                        },
                        else => {
                            @compileError("expect type Struct, got: " ++ @typeName(p.child));
                        },
                    }
                },
                else => {
                    @compileError("expect type Struct, got: " ++ @typeName(@TypeOf(self)));
                },
            }

            try out.endObject();
        }
    };
}

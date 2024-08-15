const std = @import("std");

pub fn JsonArrayList(comptime T: type) type {
    return struct {
        const Self = @This();

        value: std.ArrayList(T),

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            errdefer std.log.err("ssssaaaa", .{});
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
    const field = comptime @typeInfo(T).Struct;
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

            while (true) {
                // taking token name from source
                const name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                const field_name = switch (name_token.?) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => { // No more fields.
                        break;
                    },
                    else => {
                        return error.UnexpectedToken;
                    },
                };

                var f = false;

                inline for (full_map) |p| {
                    if (std.mem.eql(u8, p[1], field_name)) {
                        @field(&res, p[0]) = try std.json.innerParse(fieldType(T, p[0]).?, allocator, source, options);
                        f = true;
                        break;
                    }
                }

                if (!f) {
                    std.log.err("field not found {s}", .{field_name});
                    return error.MissingField;
                }
            }

            return res;
        }

        pub fn jsonStringify(self: anytype, out: anytype) !void {
            try out.beginObject();

            switch (@typeInfo(@TypeOf(self))) {
                .Pointer => |p| {
                    switch (@typeInfo(p.child)) {
                        .Struct => |s| {
                            inline for (s.fields) |f| {
                                const rename_to = comptime ffto.get(f.name).?;
                                try out.objectField(rename_to);
                                try out.write(@field(self, f.name));
                            }
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

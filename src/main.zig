const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const PrimitiveType = union(enum) {
    bool,
    integer: Integer,
    float: Float,
    string: String,
    // any,

    pub const Integer = struct {
        min: i64,
        max: i64,
    };

    pub const Float = struct {
        min: f64,
        max: f64,
    };

    pub const String = struct {
        min_len: usize,
        max_len: usize,
    };
};

const RefType = union(enum) {
    array: Array,
    object: Object,
    optional: Optional,
    // union,

    pub const Index = usize;

    pub const Array = struct {
        min_len: usize,
        max_len: usize,
        child_type: ?Type,
    };

    pub const Object = struct {
        fields: []Field,

        pub const Field = struct {
            name: []const u8,
            type: Type,
        };
    };

    pub const Optional = struct {
        child_type: ?Type,
    };
};

const Type = union(enum) {
    primitive: PrimitiveType,
    ref: RefType.Index,
};

const Parsed = struct {
    arena: *ArenaAllocator,
    types: []RefType,
    root: Type,

    pub fn deinit(this: Parsed) void {
        const gpa = this.arena.child_allocator;

        gpa.free(this.types);
        this.arena.deinit();
        gpa.destroy(this.arena);
    }

    pub fn render(this: *Parsed, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try this.renderType(writer, this.root, 0);
    }

    fn renderType(this: *Parsed, writer: *std.Io.Writer, @"type": Type, indent_level: usize) std.Io.Writer.Error!void {
        switch (@"type") {
            .primitive => |primitive| {
                switch (primitive) {
                    .bool => try writer.writeAll("bool"),
                    .integer => try writer.writeAll("i64"),
                    .float => try writer.writeAll("f64"),
                    .string => try writer.writeAll("[]const u8"),
                }
            },
            .ref => |ref| {
                switch (this.types[ref]) {
                    .array => |array| {
                        if (array.child_type) |child_type| {
                            try writer.writeAll("[]");
                            try this.renderType(writer, child_type, indent_level);
                        } else {
                            try writer.writeAll("[]ERROR");
                        }
                    },
                    .optional => |optional| {
                        if (optional.child_type) |child_type| {
                            try writer.writeAll("?");
                            try this.renderType(writer, child_type, indent_level);
                        } else {
                            try writer.writeAll("?ERROR");
                        }
                    },
                    .object => |object| {
                        try writer.writeAll("struct {\n");
                        for (object.fields) |field| {
                            try writer.splatByteAll(' ', (indent_level + 1) * 4);
                            if (needsEscaping(field.name)) {
                                try writer.print("@\"{s}\": ", .{field.name});
                            } else {
                                try writer.print("{s}: ", .{field.name});
                            }
                            try this.renderType(writer, field.type, indent_level + 1);
                            try writer.writeAll(",\n");
                        }
                        try writer.splatByteAll(' ', indent_level * 4);
                        try writer.writeAll("}");
                    },
                }
            },
        }
    }

    fn needsEscaping(name: []const u8) bool {
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return true;
        for (name[1..]) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '_') return true;
        }
        if (std.zig.Token.keywords.has(name)) return true;
        return false;
    }
};

const Parser = struct {
    gpa: Allocator,
    arena: *ArenaAllocator,
    types: std.ArrayListUnmanaged(RefType),

    const Error = Allocator.Error || error{RootNodeCanNotBeNull};

    pub fn parse(gpa: Allocator, json: std.json.Value) Error!Parsed {
        const arena = try gpa.create(ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        var resolver: Parser = .{
            .gpa = gpa,
            .arena = arena,
            .types = .empty,
        };
        defer resolver.types.deinit(gpa);

        const root = try resolver.parseType(json);

        return .{
            .types = try resolver.types.toOwnedSlice(gpa),
            .arena = arena,
            .root = root,
        };
    }

    fn parseType(this: *Parser, json: std.json.Value) Error!Type {
        return switch (json) {
            .null => .{
                .ref = try this.addRefType(.{
                    .optional = .{ .child_type = null },
                }),
            },
            .bool => .{
                .primitive = .bool,
            },
            .integer => |value| .{
                .primitive = .{
                    .integer = .{
                        .min = value,
                        .max = value,
                    },
                },
            },
            .float => |value| .{
                .primitive = .{
                    .float = .{
                        .min = value,
                        .max = value,
                    },
                },
            },
            .number_string => |string| .{
                .primitive = .{
                    .string = .{
                        .min_len = string.len,
                        .max_len = string.len,
                    },
                },
            },
            .string => |string| .{
                .primitive = .{
                    .string = .{
                        .min_len = string.len,
                        .max_len = string.len,
                    },
                },
            },
            .array => |array| blk: {
                var optional_child_type: ?Type = null;

                for (array.items) |value| {
                    const other_child_type = try this.parseType(value);
                    if (optional_child_type) |child_type| {
                        optional_child_type = try this.mergeTypes(child_type, other_child_type);
                    } else {
                        optional_child_type = other_child_type;
                    }
                }

                break :blk .{
                    .ref = try this.addRefType(.{
                        .array = .{
                            .min_len = array.items.len,
                            .max_len = array.items.len,
                            .child_type = optional_child_type,
                        },
                    }),
                };
            },
            .object => |object| blk: {
                var it = object.iterator();
                var object_type: RefType.Object = .{
                    .fields = try this.arena.allocator().alloc(RefType.Object.Field, object.count()),
                };

                while (it.next()) |entry| {
                    object_type.fields[it.index - 1] = .{
                        .name = entry.key_ptr.*,
                        .type = try this.parseType(entry.value_ptr.*),
                    };
                }

                break :blk .{ .ref = try this.addRefType(.{
                    .object = object_type,
                }) };
            },
        };
    }

    fn addRefType(this: *Parser, ref_type: RefType) Allocator.Error!RefType.Index {
        const index = this.types.items.len;
        try this.types.append(this.gpa, ref_type);
        return index;
    }

    fn mergeOptionalTypes(this: *Parser, optional_type_a: ?Type, optional_type_b: ?Type) Error!?Type {
        if (optional_type_a) |type_a| {
            if (optional_type_b) |type_b| {
                return try this.mergeTypes(type_a, type_b);
            }
            return optional_type_a;
        }
        return optional_type_b;
    }

    fn mergeTypes(this: *Parser, type_a: Type, type_b: Type) Error!Type {
        if (std.meta.activeTag(type_a) == std.meta.activeTag(type_b)) {
            const @"type": Type = switch (type_a) {
                .primitive => blk: {
                    const primitive_a = type_a.primitive;
                    const primitive_b = type_b.primitive;

                    if (std.meta.activeTag(primitive_a) == std.meta.activeTag(primitive_b)) {
                        break :blk switch (primitive_a) {
                            .bool => .{
                                .primitive = .bool,
                            },
                            .integer => .{
                                .primitive = .{
                                    .integer = .{
                                        .min = @min(primitive_a.integer.min, primitive_b.integer.min),
                                        .max = @max(primitive_a.integer.max, primitive_b.integer.max),
                                    },
                                },
                            },
                            .float => .{
                                .primitive = .{
                                    .float = .{
                                        .min = @min(primitive_a.float.min, primitive_b.float.min),
                                        .max = @max(primitive_a.float.max, primitive_b.float.max),
                                    },
                                },
                            },
                            .string => .{
                                .primitive = .{
                                    .string = .{
                                        .min_len = @min(primitive_a.string.min_len, primitive_b.string.min_len),
                                        .max_len = @max(primitive_a.string.max_len, primitive_b.string.max_len),
                                    },
                                },
                            },
                        };
                    }
                    @panic("TODO");
                },
                .ref => blk: {
                    const ref_a = this.types.items[type_a.ref];
                    const ref_b = this.types.items[type_b.ref];

                    if (std.meta.activeTag(ref_a) == std.meta.activeTag(ref_b)) {
                        break :blk .{
                            .ref = try this.addRefType(switch (ref_a) {
                                .array => .{
                                    .array = .{
                                        .min_len = @min(ref_a.array.min_len, ref_b.array.min_len),
                                        .max_len = @max(ref_a.array.max_len, ref_b.array.max_len),
                                        .child_type = try this.mergeOptionalTypes(ref_a.array.child_type, ref_b.array.child_type),
                                    },
                                },
                                .object => blk1: {
                                    const fields_a = ref_a.object.fields;
                                    const fields_b = ref_b.object.fields;

                                    // TODO Alloc once
                                    const field_a_to_b = try this.gpa.alloc(?usize, fields_a.len);
                                    defer this.gpa.free(field_a_to_b);
                                    @memset(field_a_to_b, null);

                                    const field_b_to_a = try this.gpa.alloc(?usize, fields_b.len);
                                    defer this.gpa.free(field_b_to_a);
                                    @memset(field_b_to_a, null);

                                    var count_mutual_fields: usize = 0;

                                    for (fields_a, 0..) |field_a, i_a| {
                                        for (fields_b, 0..) |field_b, i_b| {
                                            if (std.mem.eql(u8, field_a.name, field_b.name)) {
                                                count_mutual_fields += 1;
                                                field_a_to_b[i_a] = i_b;
                                                field_b_to_a[i_b] = i_a;
                                            }
                                        }
                                    }
                                    var fields = try this.arena.allocator().alloc(RefType.Object.Field, fields_a.len + fields_b.len - count_mutual_fields);
                                    var i: usize = 0;
                                    for (fields_a, 0..) |field_a, i_a| {
                                        if (field_a_to_b[i_a]) |b_i_s| {
                                            fields[i].name = field_a.name;
                                            fields[i].type = try this.mergeTypes(field_a.type, fields_b[b_i_s].type);
                                            i += 1;
                                            var b_i = b_i_s + 1;
                                            while (b_i < fields_b.len and field_b_to_a[b_i] == null) : (b_i += 1) {
                                                fields[i].name = fields_b[b_i].name;
                                                fields[i].type = .{
                                                    .ref = try this.addRefType(.{
                                                        .optional = .{
                                                            .child_type = fields_b[b_i].type,
                                                        },
                                                    }),
                                                };
                                                i += 1;
                                            }
                                        } else {
                                            fields[i].name = field_a.name;
                                            fields[i].type = .{
                                                .ref = try this.addRefType(.{
                                                    .optional = .{
                                                        .child_type = field_a.type,
                                                    },
                                                }),
                                            };
                                            i += 1;
                                        }
                                    }
                                    var b_i: usize = 0;
                                    while (b_i < fields_b.len and field_b_to_a[b_i] == null) : (b_i += 1) {
                                        fields[i].name = fields_b[b_i].name;
                                        fields[i].type = .{
                                            .ref = try this.addRefType(.{
                                                .optional = .{
                                                    .child_type = fields_b[b_i].type,
                                                },
                                            }),
                                        };
                                        i += 1;
                                    }
                                    std.debug.assert(i == fields.len);

                                    break :blk1 .{
                                        .object = .{
                                            .fields = fields,
                                        },
                                    };
                                },
                                .optional => .{
                                    .optional = .{
                                        .child_type = try this.mergeOptionalTypes(ref_a.optional.child_type, ref_b.optional.child_type),
                                    },
                                },
                            }),
                        };
                    }
                    @panic("TODO");
                },
            };

            return @"type";
        }
        @panic("TODO");
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var buffer: [1024]u8 = undefined;

    var reader = std.fs.File.stdin().reader(&buffer);

    var json_reader = std.json.Reader.init(gpa, &reader.interface);
    defer json_reader.deinit();

    const json = try std.json.parseFromTokenSource(std.json.Value, gpa, &json_reader, .{});
    defer json.deinit();

    var resolved = try Parser.parse(gpa, json.value);
    defer resolved.deinit();

    var writer = std.fs.File.stdout().writer(&buffer);

    try resolved.render(&writer.interface);
    try writer.interface.flush();
}

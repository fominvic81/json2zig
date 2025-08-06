const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Type = union(enum) {
    unknown,
    any,
    bool,
    integer: Integer,
    float: Float,
    string: String,
    array: Array,
    object: Object,
    optional: Optional,

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

    pub const Array = struct {
        min_len: usize,
        max_len: usize,
        child_type: *Type,
    };

    pub const Object = struct {
        fields: []Field,

        pub const Field = struct {
            name: []const u8,
            type: *Type,
        };
    };

    pub const Optional = struct {
        child_type: *Type,
    };
};

pub const Parsed = struct {
    arena: *ArenaAllocator,
    root: Type,

    pub fn deinit(this: Parsed) void {
        const gpa = this.arena.child_allocator;
        this.arena.deinit();
        gpa.destroy(this.arena);
    }
};

pub const Parser = struct {
    gpa: Allocator,
    arena: *ArenaAllocator,

    pub const Error = Allocator.Error || error{RootNodeCanNotBeNull};

    pub fn parse(gpa: Allocator, json: std.json.Value) Error!Parsed {
        const arena = try gpa.create(ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        var resolver: Parser = .{
            .gpa = gpa,
            .arena = arena,
        };

        const root = try resolver.parseType(json);

        return .{
            .arena = arena,
            .root = root,
        };
    }

    fn parseType(this: *Parser, json: std.json.Value) Error!Type {
        return switch (json) {
            .null => .{ .optional = .{ .child_type = try this.allocType(.unknown) } },
            .bool => .bool,
            .integer => |value| .{ .integer = .{
                .min = value,
                .max = value,
            } },
            .float => |value| .{ .float = .{
                .min = value,
                .max = value,
            } },
            .number_string => |string| .{ .string = .{
                .min_len = string.len,
                .max_len = string.len,
            } },
            .string => |string| .{ .string = .{
                .min_len = string.len,
                .max_len = string.len,
            } },
            .array => |array| blk: {
                var child_type: Type = .unknown;

                for (array.items) |value| {
                    const other_child_type = try this.parseType(value);
                    child_type = try this.mergeTypes(child_type, other_child_type);
                }

                break :blk .{ .array = .{
                    .min_len = array.items.len,
                    .max_len = array.items.len,
                    .child_type = try this.allocType(child_type),
                } };
            },
            .object => |object| blk: {
                var it = object.iterator();
                var object_type: Type.Object = .{
                    .fields = try this.arena.allocator().alloc(Type.Object.Field, object.count()),
                };

                while (it.next()) |entry| {
                    object_type.fields[it.index - 1] = .{
                        .name = entry.key_ptr.*,
                        .type = try this.allocType(try this.parseType(entry.value_ptr.*)),
                    };
                }

                break :blk .{ .object = object_type };
            },
        };
    }

    fn mergeTypes(this: *Parser, type_a: Type, type_b: Type) Error!Type {
        if (std.meta.activeTag(type_a) == std.meta.activeTag(type_b)) {
            return switch (type_a) {
                .unknown => .unknown,
                .any => .any,
                .bool => .bool,
                .integer => .{ .integer = .{
                    .min = @min(type_a.integer.min, type_b.integer.min),
                    .max = @max(type_a.integer.max, type_b.integer.max),
                } },
                .float => .{ .float = .{
                    .min = @min(type_a.float.min, type_b.float.min),
                    .max = @max(type_a.float.max, type_b.float.max),
                } },
                .string => .{ .string = .{
                    .min_len = @min(type_a.string.min_len, type_b.string.min_len),
                    .max_len = @max(type_a.string.max_len, type_b.string.max_len),
                } },
                .array => .{ .array = .{
                    .min_len = @min(type_a.array.min_len, type_b.array.min_len),
                    .max_len = @max(type_a.array.max_len, type_b.array.max_len),
                    .child_type = try this.allocType(try this.mergeTypes(type_a.array.child_type.*, type_b.array.child_type.*)),
                } },
                .object => blk1: {
                    const fields_a = type_a.object.fields;
                    const fields_b = type_b.object.fields;

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
                    var fields = try this.arena.allocator().alloc(Type.Object.Field, fields_a.len + fields_b.len - count_mutual_fields);
                    var i: usize = 0;
                    for (fields_a, 0..) |field_a, i_a| {
                        if (field_a_to_b[i_a]) |b_i_s| {
                            fields[i].name = field_a.name;
                            fields[i].type = try this.allocType(try this.mergeTypes(field_a.type.*, fields_b[b_i_s].type.*));
                            i += 1;
                            var b_i = b_i_s + 1;
                            while (b_i < fields_b.len and field_b_to_a[b_i] == null) : (b_i += 1) {
                                fields[i].name = fields_b[b_i].name;
                                fields[i].type = if (fields_b[b_i].type.* == .optional) fields_b[b_i].type else try this.allocType(.{ .optional = .{ .child_type = fields_b[b_i].type } });
                                i += 1;
                            }
                        } else {
                            fields[i].name = field_a.name;
                            fields[i].type = if (field_a.type.* == .optional) field_a.type else try this.allocType(.{ .optional = .{ .child_type = field_a.type } });
                            i += 1;
                        }
                    }
                    var b_i: usize = 0;
                    while (b_i < fields_b.len and field_b_to_a[b_i] == null) : (b_i += 1) {
                        fields[i].name = fields_b[b_i].name;
                        fields[i].type = if (fields_b[b_i].type.* == .optional) fields_b[b_i].type else try this.allocType(.{ .optional = .{ .child_type = fields_b[b_i].type } });
                        i += 1;
                    }
                    std.debug.assert(i == fields.len);

                    break :blk1 .{ .object = .{
                        .fields = fields,
                    } };
                },
                .optional => .{ .optional = .{
                    .child_type = try this.allocType(try this.mergeTypes(type_a.optional.child_type.*, type_b.optional.child_type.*)),
                } },
            };
        }
        if (type_a == .unknown) return type_b;
        if (type_b == .unknown) return type_a;
        if (type_a == .any) return .any;
        if (type_b == .any) return .any;
        if (type_a == .optional) {
            return .{ .optional = .{
                .child_type = try this.allocType(try this.mergeTypes(type_a.optional.child_type.*, type_b)),
            } };
        }
        if (type_b == .optional) {
            return .{ .optional = .{
                .child_type = try this.allocType(try this.mergeTypes(type_a, type_b.optional.child_type.*)),
            } };
        }
        if (type_a == .integer and type_b == .float) {
            return .{ .float = .{
                .min = @min(@as(f64, @floatFromInt(type_a.integer.min)), type_b.float.min),
                .max = @max(@as(f64, @floatFromInt(type_a.integer.max)), type_b.float.max),
            } };
        }
        if (type_a == .float and type_b == .integer) {
            return .{ .float = .{
                .min = @min(type_a.float.min, @as(f64, @floatFromInt(type_b.integer.min))),
                .max = @max(type_a.float.max, @as(f64, @floatFromInt(type_b.integer.max))),
            } };
        }

        return .any;
    }

    fn allocType(this: *Parser, @"type": Type) Allocator.Error!*Type {
        const type_ptr = try this.arena.allocator().create(Type);
        type_ptr.* = @"type";
        return type_ptr;
    }
};

pub const Renderer = struct {
    parsed: Parsed,
    writer: *std.Io.Writer,
    options: Options,

    const Options = struct {
        string: []const u8 = "[]const u8",
        integer: []const u8 = "i64",
        float: []const u8 = "f64",
        bool: []const u8 = "bool",
        any: []const u8 = "std.json.Value",
        unknown: []const u8 = "UNKNOWN",
    };

    pub fn render(parsed: Parsed, writer: *std.Io.Writer, options: Options) std.Io.Writer.Error!void {
        const renderer: Renderer = .{
            .parsed = parsed,
            .writer = writer,
            .options = options,
        };

        try renderer.renderType(writer, parsed.root, 0);
    }

    pub fn renderAlloc(gpa: Allocator, parsed: Parsed, options: Options) Allocator.Error![]const u8 {
        var output: std.ArrayList(u8) = .init(gpa);
        defer output.deinit();

        var writer = output.writer().adaptToNewApi();
        render(parsed, &writer.new_interface, options) catch return writer.err.?;

        return try output.toOwnedSlice();
    }

    fn renderType(this: *const Renderer, writer: *std.Io.Writer, @"type": Type, indent_level: usize) std.Io.Writer.Error!void {
        switch (@"type") {
            .unknown => try writer.writeAll(this.options.unknown),
            .any => try writer.writeAll(this.options.any),
            .bool => try writer.writeAll(this.options.bool),
            .integer => try writer.writeAll(this.options.integer),
            .float => try writer.writeAll(this.options.float),
            .string => try writer.writeAll(this.options.string),
            .array => |array| {
                try writer.writeAll("[]");
                try this.renderType(writer, array.child_type.*, indent_level);
            },
            .optional => |optional| {
                try writer.writeAll("?");
                try this.renderType(writer, optional.child_type.*, indent_level);
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
                    try this.renderType(writer, field.type.*, indent_level + 1);
                    try writer.writeAll(",\n");
                }
                try writer.splatByteAll(' ', indent_level * 4);
                try writer.writeAll("}");
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

test "Basic types" {
    const json =
        \\{
        \\    "int": 1,
        \\    "float": 1.0,
        \\    "bool": true,
        \\    "array": [1, 2, 3, 4.5, null]
        \\}
    ;
    const expected =
        \\struct {
        \\    int: i64,
        \\    float: f64,
        \\    bool: bool,
        \\    array: []?f64,
        \\}
    ;
    var parsed_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed_json.deinit();

    var parsed = try Parser.parse(std.testing.allocator, parsed_json.value);
    defer parsed.deinit();

    const output = try Renderer.renderAlloc(std.testing.allocator, parsed, .{});
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(expected, output);
}

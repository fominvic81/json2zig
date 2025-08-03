const std = @import("std");
const Allocator = std.mem.Allocator;

const Type = union(enum) {
    bool,
    integer: Integer,
    float: Float,
    string: String,
    array: Array,
    // object: Object,
    optional: Optional,
    // any,
    // union,

    const Index = usize;

    const Optional = struct {
        child_type: ?Index,
    };

    const Integer = struct {
        min: i64,
        max: i64,
    };

    const Float = struct {
        min: f64,
        max: f64,
    };

    const String = struct {
        min_len: usize,
        max_len: usize,
    };

    const Array = struct {
        min_len: usize,
        max_len: usize,
        child_type: ?Index,
    };

    const Object = struct {
        fields: []Field,

        const Field = struct {
            name: []const u8,
            type: Index,
        };
    };
};

const Resolver = struct {
    gpa: Allocator,
    types: std.ArrayListUnmanaged(Type),

    const Error = Allocator.Error || error{RootNodeCanNotBeNull};

    pub fn resolve(gpa: Allocator, json: std.json.Value) Error!void {
        var resolver: Resolver = .{
            .gpa = gpa,
            .types = .empty,
        };
        const @"type" = try resolver.resolveType(json);
        _ = @"type";
    }

    fn resolveType(this: *Resolver, json: std.json.Value) Error!Type.Index {
        return switch (json) {
            // TODO: do not create type for primitives
            .null => try this.makeType(.{
                .optional = .{ .child_type = null },
            }),
            .bool => try this.makeType(.bool),
            .integer => |value| try this.makeType(.{
                .integer = .{
                    .min = value,
                    .max = value,
                },
            }),
            .float => |value| try this.makeType(.{
                .float = .{
                    .min = value,
                    .max = value,
                },
            }),
            .number_string => |string| try this.makeType(.{
                .string = .{
                    .min_len = string.len,
                    .max_len = string.len,
                },
            }),
            .string => |string| try this.makeType(.{
                .string = .{
                    .min_len = string.len,
                    .max_len = string.len,
                },
            }),
            .array => |array| blk: {
                var optional_child_type: ?Type.Index = null;

                for (array.items) |value| {
                    const other_child_type = try this.resolveType(value);
                    if (optional_child_type) |child_type| {
                        optional_child_type = try this.unionTypes(child_type, other_child_type);
                    } else {
                        optional_child_type = other_child_type;
                    }
                }

                break :blk try this.makeType(.{
                    .array = .{
                        .min_len = array.items.len,
                        .max_len = array.items.len,
                        .child_type = optional_child_type,
                    },
                });
            },
            .object => @panic("TODO"),
        };
    }

    fn makeType(this: *Resolver, @"type": Type) Allocator.Error!Type.Index {
        const index = this.types.items.len;
        try this.types.append(this.gpa, @"type");
        return index;
    }

    fn unionOptionalTypes(this: *Resolver, optional_type_index_a: ?Type.Index, optional_type_index_b: ?Type.Index) Error!?Type.Index {
        if (optional_type_index_a) |type_index_a| {
            if (optional_type_index_b) |type_index_b| {
                return try this.unionTypes(type_index_a, type_index_b);
            }
            return optional_type_index_a;
        }
        return optional_type_index_b;
    }

    fn unionTypes(this: *Resolver, type_index_a: Type.Index, type_index_b: Type.Index) Error!Type.Index {
        const type_a = this.types.items[type_index_a];
        const type_b = this.types.items[type_index_b];

        if (std.meta.activeTag(type_a) == std.meta.activeTag(type_b)) {
            const @"type": Type = switch (type_a) {
                .bool => .bool,
                .integer => .{
                    .integer = .{
                        .min = @min(type_a.integer.min, type_b.integer.min),
                        .max = @max(type_a.integer.max, type_b.integer.max),
                    },
                },
                .float => .{
                    .float = .{
                        .min = @min(type_a.float.min, type_b.float.min),
                        .max = @max(type_a.float.max, type_b.float.max),
                    },
                },
                .string => .{
                    .string = .{
                        .min_len = @min(type_a.string.min_len, type_b.string.min_len),
                        .max_len = @max(type_a.string.max_len, type_b.string.max_len),
                    },
                },
                .array => blk: {
                    break :blk .{
                        .array = .{
                            .min_len = @min(type_a.array.min_len, type_b.array.min_len),
                            .max_len = @max(type_a.array.max_len, type_b.array.max_len),
                            .child_type = try this.unionOptionalTypes(type_a.array.child_type, type_b.array.child_type),
                        },
                    };
                },
                // .object => {},
                .optional => .{
                    .optional = .{
                        .child_type = try this.unionOptionalTypes(type_a.optional.child_type, type_b.optional.child_type),
                    },
                },
            };

            return try this.makeType(@"type");
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

    try Resolver.resolve(gpa, json.value);

    // switch (json.value) {
    //     null => Error.RootNodeCanNotBeNull,
    //     bool: bool,
    //     integer: i64,
    //     float: f64,
    //     number_string: []const u8,
    //     string: []const u8,
    //     array: Array,
    //     object: ObjectMap,
    // }
}

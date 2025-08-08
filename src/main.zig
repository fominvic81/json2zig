const std = @import("std");
const j2z = @import("json2zig");
const Parser = j2z.Parser;
const Renderer = j2z.Renderer;

const Command = struct {
    field: ?[]const u8 = null,
    names: []const []const u8,
    description: []const u8,
};

const commands: []const Command = &.{ .{
    .field = "string",
    .names = &.{ "--string", "-s" },
    .description = "Type to use for strings",
}, .{
    .field = "integer",
    .names = &.{ "--int", "-i" },
    .description = "Type to use for integers",
}, .{
    .field = "float",
    .names = &.{ "--float", "-f" },
    .description = "Type to use for floats",
}, .{
    .field = "bool",
    .names = &.{ "--bool", "-b" },
    .description = "Type to use for bools",
}, .{
    .field = "any",
    .names = &.{ "--any", "-a" },
    .description = "Type to use for fields of multiple types",
}, .{
    .field = "unknown",
    .names = &.{ "--unknown", "-u" },
    .description = "Type to use for fields of unknown type",
}, .{
    .names = &.{ "--help", "-h" },
    .description = "Print this help and exit",
} };

const help_msg = blk: {
    var msg: []const u8 =
        \\Usage: json2zig [options]
        \\
        \\Options:
        \\
    ;
    for (commands) |command| {
        msg = msg ++ "  ";
        for (command.names, 0..) |name, i| {
            if (i > 0) msg = msg ++ ", ";
            msg = msg ++ name;
        }
        msg = msg ++ "\n    " ++ command.description ++ "\n\n";
    }
    break :blk msg;
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var options: Renderer.Options = .{};
    var argument_already_set: [commands.len]bool = @splat(false);

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    _ = args.skip();
    while (args.next()) |arg| {
        var it = std.mem.splitScalar(u8, arg, '=');
        const first = it.first();
        var short_argument_value: ?[]const u8 = null;

        const argument = if (first.len > 1 and first[0] == '-' and first[1] != '-') blk: {
            if (first.len > 2) short_argument_value = first[2..];
            break :blk first[0..2];
        } else first;

        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) {
            std.debug.print(help_msg, .{});
            return;
        }

        inline for (commands, 0..) |command, i| {
            const matches = for (command.names) |name| {
                if (std.mem.eql(u8, argument, name)) break true;
            } else false;
            if (matches) {
                if (argument_already_set[i]) {
                    std.debug.print("Error: duplicate argument '{s}'", .{argument});
                    return;
                }
                argument_already_set[i] = true;
                const value = short_argument_value orelse it.next() orelse args.next() orelse {
                    std.debug.print("Error: expected value for argument '{s}'\n", .{argument});
                    return;
                };
                if (command.field) |field| {
                    @field(options, field) = value;
                } else unreachable;

                break;
            }
        } else {
            std.debug.print("Error: unrecognized argument '{s}'\n", .{argument});
            return;
        }
    }

    const input = try std.fs.File.stdin().readToEndAlloc(gpa, 0xffffffff);
    defer gpa.free(input);

    const json = try std.json.parseFromSlice(std.json.Value, gpa, input, .{});
    defer json.deinit();

    var parsed = try Parser.parse(gpa, json.value);
    defer parsed.deinit();

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try Renderer.render(parsed, &writer.interface, options);
    try writer.interface.flush();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const j2z = @import("json2zig");
const Parser = j2z.Parser;
const Renderer = j2z.Renderer;

const Option = struct {
    field: ?[]const u8 = null,
    names: []const []const u8,
    description: []const u8,
};

const cli_options: []const Option = &.{ .{
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
    for (cli_options) |option| {
        msg = msg ++ "  ";
        for (option.names, 0..) |name, i| {
            if (i > 0) msg = msg ++ ", ";
            msg = msg ++ name;
        }
        msg = msg ++ "\n    " ++ option.description ++ "\n\n";
    }
    break :blk msg;
};

pub fn run(gpa: Allocator, args: anytype, input_reader: *std.Io.Reader, output_writer: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error || std.Io.Reader.Error)!void {
    var options: Renderer.Options = .{};
    var argument_already_set: [cli_options.len]bool = @splat(false);

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

        inline for (cli_options, 0..) |option, i| {
            const matches = for (option.names) |name| {
                if (std.mem.eql(u8, argument, name)) break true;
            } else false;
            if (matches) {
                if (argument_already_set[i]) {
                    std.debug.print("Error: duplicate argument '{s}'\n", .{argument});
                    return;
                }
                argument_already_set[i] = true;
                const value = short_argument_value orelse it.next() orelse args.next() orelse {
                    std.debug.print("Error: expected value for argument '{s}'\n", .{argument});
                    return;
                };
                if (option.field) |field| {
                    @field(options, field) = value;
                } else unreachable;

                break;
            }
        } else {
            std.debug.print("Error: unrecognized argument '{s}'\n", .{argument});
            return;
        }
    }

    const input = input_reader.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.StreamTooLong => unreachable,
        else => |err2| return err2,
    };
    defer gpa.free(input);

    var diagnostics = std.json.Diagnostics{};
    var source = std.json.Scanner.initCompleteInput(gpa, input);
    defer source.deinit();
    source.enableDiagnostics(&diagnostics);

    const json = std.json.parseFromTokenSource(std.json.Value, gpa, &source, .{}) catch |err| {
        std.debug.print("Error: failed to parse json '{} at line {}, column {}'\n", .{ err, diagnostics.getLine(), diagnostics.getColumn() });
        return;
    };
    defer json.deinit();

    var parsed = try Parser.parse(gpa, json.value);
    defer parsed.deinit();

    try Renderer.render(parsed, output_writer, options);
}

pub fn main() void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = std.process.argsWithAllocator(gpa) catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Error: out of memory. Go buy more RAM!\n", .{});
            return;
        },
    };
    _ = args.skip();
    defer args.deinit();

    var input_buffer: [1024]u8 = undefined;
    var reader = std.fs.File.stdin().reader(&input_buffer);

    var output_buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&output_buffer);
    defer writer.interface.flush() catch |err| {
        std.debug.print("Error: failed to write to stdout '{}'\n", .{err});
    };

    run(gpa, &args, &reader.interface, &writer.interface) catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Error: out of memory. Go buy more RAM!\n", .{});
            return;
        },
        error.ReadFailed => {
            std.debug.print("Error: failed to read from stdin '{}'\n", .{reader.err.?});
            return;
        },
        error.EndOfStream => {
            std.debug.print("Error: unexpected end of stream\n", .{});
            return;
        },
        error.WriteFailed => {
            std.debug.print("Error: failed to write to stdout '{}'\n", .{writer.err.?});
            return;
        },
    };
}

const TestArgIterator = struct {
    args: []const []const u8,
    pos: usize,

    fn init(data: []const []const u8) TestArgIterator {
        return .{ .args = data, .pos = 0 };
    }

    fn next(self: *TestArgIterator) ?[]const u8 {
        if (self.pos == self.args.len) {
            return null;
        } else {
            const arg = self.args[self.pos];
            self.pos += 1;
            return arg;
        }
    }
};

test "Custom type arguments" {
    const args = &.{
        // zig fmt: off
        "-s[]u8",
        "--int", "u69",
        "-f=f32",
        "-b", "mabool",
        "-aany",
        "--unknown=UnKnOwN",
        // zig fmt: on
    };
    const input =
        \\[
        \\    {
        \\        "string": "something",
        \\        "int": 123,
        \\        "float": 123.45,
        \\        "bool": true,
        \\        "any": "string",
        \\        "unknown": null
        \\    },
        \\    {
        \\        "string": "something",
        \\        "int": 123,
        \\        "float": 123.45,
        \\        "bool": true,
        \\        "any": 123,
        \\        "unknown": null
        \\    }
        \\]
        ;
    const expected_output =
        \\[]struct {
        \\    string: []u8,
        \\    int: u69,
        \\    float: f32,
        \\    bool: mabool,
        \\    any: any,
        \\    unknown: ?UnKnOwN,
        \\}
        ;

    var input_reader = std.io.Reader.fixed(input);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var args_it = TestArgIterator.init(args);
    try run(std.testing.allocator, &args_it, &input_reader, &output.writer);

    try std.testing.expectEqualStrings(expected_output, output.written());
}

const std = @import("std");
const j2z = @import("json2zig");
const Parser = j2z.Parser;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(gpa, 0xffffffff);
    defer gpa.free(input);

    const json = try std.json.parseFromSlice(std.json.Value, gpa, input, .{});
    defer json.deinit();

    var parsed = try Parser.parse(gpa, json.value);
    defer parsed.deinit();

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try parsed.render(&writer.interface);
    try writer.interface.flush();
}

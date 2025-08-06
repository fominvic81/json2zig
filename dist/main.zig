const std = @import("std");
const Allocator = std.mem.Allocator;
const j2z = @import("json2zig");

const allocator = std.heap.wasm_allocator;

fn allocData(data: []const u8) Allocator.Error!u32 {
    const allocation = alloc(data.len);
    @memcpy(@as([*]u8, @ptrFromInt(allocation)), data);
    return allocation;
}

export fn alloc(n: u32) u32 {
    const ptr = (allocator.alignedAlloc(u8, .@"8", n + @sizeOf(u32)) catch return 0).ptr;
    @as(*u32, @ptrCast(ptr)).* = n;
    return @intFromPtr(ptr) + @sizeOf(u32);
}

export fn sizeOf(ptr: u32) u32 {
    return @as(*u32, @ptrFromInt(ptr - @sizeOf(u32))).*;
}

export fn free(ptr: u32) void {
    if (ptr == 0) return;
    allocator.free(@as([*]u8, @ptrFromInt(ptr - @sizeOf(u32)))[0 .. sizeOf(ptr) + @sizeOf(u32)]);
}

export fn parse(ptr: u32) u32 {
    const input = @as([*]u8, @ptrFromInt(ptr))[0..sizeOf(ptr)];

    var json = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return 0;
    defer json.deinit();

    var parsed = j2z.Parser.parse(allocator, json.value) catch return 0;
    defer parsed.deinit();

    const output = j2z.Renderer.renderAlloc(allocator, parsed, .{}) catch return 0;
    return allocData(output) catch return 0;
}

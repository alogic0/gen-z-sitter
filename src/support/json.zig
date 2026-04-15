const std = @import("std");

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try std.json.Stringify.value(value, .{
        .whitespace = .indent_2,
    }, &out.writer);

    return out.toOwnedSlice();
}

test "stringifyAlloc renders stable JSON" {
    const allocator = std.testing.allocator;
    const json = try stringifyAlloc(allocator, .{
        .name = "zig-tree-sit",
        .version = "0.0.0",
    });
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
}

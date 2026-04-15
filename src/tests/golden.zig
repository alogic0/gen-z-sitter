const std = @import("std");

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "expectContains succeeds for present substring" {
    try expectContains("zig-tree-sit", "tree");
}

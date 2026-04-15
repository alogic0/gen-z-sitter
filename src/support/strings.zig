const std = @import("std");

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn hasPrefix(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

test "hasPrefix returns true for matching prefix" {
    try std.testing.expect(hasPrefix("grammar.json", "grammar"));
}

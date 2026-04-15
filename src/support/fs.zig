const std = @import("std");

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

pub fn writeFile(path: []const u8, contents: []const u8) !void {
    return std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = contents,
    });
}

pub fn ensureDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

test "ensureDir creates nested directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("a/b");
    try tmp.dir.access("a/b", .{});
}

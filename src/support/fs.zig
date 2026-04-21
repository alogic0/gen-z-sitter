const std = @import("std");
const runtime_io = @import("runtime_io.zig");

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(max_bytes));
}

pub fn writeFile(path: []const u8, contents: []const u8) !void {
    return std.Io.Dir.cwd().writeFile(runtime_io.get(), .{
        .sub_path = path,
        .data = contents,
    });
}

pub fn ensureDir(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), path);
}

test "ensureDir creates nested directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("a/b");
    try tmp.dir.access("a/b", .{});
}

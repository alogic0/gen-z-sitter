const std = @import("std");
pub fn main() !void {
    inline for (std.meta.declarations(std.heap)) |decl| {
        std.debug.print("{s}\n", .{decl.name});
    }
}

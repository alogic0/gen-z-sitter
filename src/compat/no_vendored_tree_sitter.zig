const std = @import("std");
const process_support = @import("../support/process.zig");

const allowed_c_or_h_files = [_][]const u8{
    "compat_targets/bracket_lang/scanner.c",
};

fn isAllowedCOrHeader(path: []const u8) bool {
    for (&allowed_c_or_h_files) |allowed| {
        if (std.mem.eql(u8, path, allowed)) return true;
    }
    return false;
}

fn isCOrHeader(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h");
}

test "tracked source does not vendor tree-sitter implementation C or header files" {
    const allocator = std.testing.allocator;

    var result = try process_support.runCapture(allocator, &.{ "git", "ls-files" });
    defer result.deinit(allocator);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.GitLsFilesTerminated,
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        if (!isCOrHeader(path)) continue;
        if (isAllowedCOrHeader(path)) continue;
        std.debug.print("unexpected tracked C/header file: {s}\n", .{path});
        return error.UnexpectedVendoredImplementationFile;
    }
}

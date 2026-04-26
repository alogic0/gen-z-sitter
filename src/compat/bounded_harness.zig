const std = @import("std");
const process_support = @import("../support/process.zig");

test "bounded C JSON parser compatibility proof stays under the heavy-suite budget" {
    var result = try process_support.runCapture(std.testing.allocator, &.{
        "zig",
        "build",
        "run-compat-target",
        "-Dcompat-target=tree_sitter_c_json",
    });
    defer result.deinit(std.testing.allocator);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("run-compat-target stderr:\n{s}\nstdout:\n{s}\n", .{ result.stderr, result.stdout });
                try std.testing.expectEqual(@as(u8, 0), code);
            }
        },
        else => return error.UnexpectedCompatRunnerTermination,
    }

    const output = if (result.stdout.len != 0) result.stdout else result.stderr;
    try std.testing.expect(std.mem.indexOf(u8, output, "target=tree_sitter_c_json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "classification=passed_within_current_boundary") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "step compile_smoke status=passed") != null);
}

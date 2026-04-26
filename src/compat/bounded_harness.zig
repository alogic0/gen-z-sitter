const std = @import("std");
const process_support = @import("../support/process.zig");

test "bounded C JSON parser compatibility proof stays under the heavy-suite budget" {
    const output = try runCompatTargetOutput("tree_sitter_c_json");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "target=tree_sitter_c_json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "classification=passed_within_current_boundary") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "step compile_smoke status=passed") != null);
}

test "bounded Haskell scanner compatibility proof stays under the heavy-suite budget" {
    const output = try runCompatTargetOutput("tree_sitter_haskell_json");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "target=tree_sitter_haskell_json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "classification=passed_within_current_boundary") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "step scanner_boundary_check status=passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "step compile_smoke status=not_run") != null);
}

test "bounded Bash scanner compatibility proof stays under the heavy-suite budget" {
    const output = try runCompatTargetOutput("tree_sitter_bash_json");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "target=tree_sitter_bash_json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "classification=passed_within_current_boundary") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "step scanner_boundary_check status=passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "step compile_smoke status=not_run") != null);
}

fn runCompatTargetOutput(target_id: []const u8) ![]const u8 {
    const target_arg = try std.fmt.allocPrint(std.testing.allocator, "-Dcompat-target={s}", .{target_id});
    defer std.testing.allocator.free(target_arg);

    var result = try process_support.runCapture(std.testing.allocator, &.{
        "zig",
        "build",
        "run-compat-target",
        target_arg,
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
    return try std.testing.allocator.dupe(u8, output);
}

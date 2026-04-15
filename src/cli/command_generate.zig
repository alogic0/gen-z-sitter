const std = @import("std");
const args = @import("args.zig");
const diag = @import("../support/diag.zig");

pub fn runGenerate(allocator: std.mem.Allocator, opts: args.GenerateOptions) !void {
    _ = allocator;

    if (opts.grammar_path.len == 0) {
        return error.InvalidArguments;
    }

    try diag.printStdout(diag.Diagnostic{
        .kind = .info,
        .message = "generate command accepted; pipeline scaffold is active",
        .note = opts.grammar_path,
    });

    return error.NotImplemented;
}

test "runGenerate rejects empty grammar path" {
    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, .{
        .grammar_path = "",
    }));
}

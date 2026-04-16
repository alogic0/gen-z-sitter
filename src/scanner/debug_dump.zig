const std = @import("std");
const scanner_serialize = @import("serialize.zig");

pub const DebugDumpError = std.mem.Allocator.Error || std.fs.File.WriteError;

pub fn dumpSerializedExternalScannerAlloc(
    allocator: std.mem.Allocator,
    serialized: scanner_serialize.SerializedExternalScannerBoundary,
) DebugDumpError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try writeSerializedExternalScanner(out.writer(), serialized);
    return try out.toOwnedSlice();
}

pub fn writeSerializedExternalScanner(
    writer: anytype,
    serialized: scanner_serialize.SerializedExternalScannerBoundary,
) !void {
    try writer.print("blocked {}\n", .{serialized.blocked});
    try writer.print("tokens {d}\n", .{serialized.tokens.len});
    for (serialized.tokens, 0..) |token, index| {
        try writer.print("token {d} index {d} {s} {s}\n", .{ index, token.index, token.name, @tagName(token.kind) });
    }
    try writer.print("uses {d}\n", .{serialized.uses.len});
    for (serialized.uses, 0..) |use, index| {
        try writer.print(
            "use {d} external {d} variable {s} production {d} step {d} field {?s}\n",
            .{ index, use.external_index, use.variable_name, use.production_index, use.step_index, use.field_name },
        );
    }
    try writer.print("unsupported_features {d}\n", .{serialized.unsupported_features.len});
    for (serialized.unsupported_features, 0..) |feature, index| {
        switch (feature) {
            .missing_external_tokens => try writer.print("feature {d} missing_external_tokens\n", .{index}),
            .multiple_external_tokens => |count| try writer.print("feature {d} multiple_external_tokens {d}\n", .{ index, count }),
            .extra_symbols => |count| try writer.print("feature {d} extra_symbols {d}\n", .{ index, count }),
            .non_leading_external_step => |location| try writer.print(
                "feature {d} non_leading_external_step {s} production {d} step {d}\n",
                .{ index, location.variable_name, location.production_index, location.step_index },
            ),
        }
    }
}

test "dumpSerializedExternalScannerAlloc formats serialized external scanner boundary deterministically" {
    const serialized = scanner_serialize.SerializedExternalScannerBoundary{
        .tokens = &.{.{
            .index = 0,
            .name = "indent",
            .kind = .named,
        }},
        .uses = &.{.{
            .external_index = 0,
            .variable_name = "_with_indent",
            .production_index = 0,
            .step_index = 0,
            .field_name = "lead",
        }},
        .unsupported_features = &.{.{
            .extra_symbols = 1,
        }},
        .blocked = true,
    };

    const dump = try dumpSerializedExternalScannerAlloc(std.testing.allocator, serialized);
    defer std.testing.allocator.free(dump);

    try std.testing.expectEqualStrings(
        \\blocked true
        \\tokens 1
        \\token 0 index 0 indent named
        \\uses 1
        \\use 0 external 0 variable _with_indent production 0 step 0 field lead
        \\unsupported_features 1
        \\feature 0 extra_symbols 1
        \\
    , dump);
}

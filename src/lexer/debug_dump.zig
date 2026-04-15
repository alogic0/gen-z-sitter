const std = @import("std");
const lexical_serialize = @import("serialize.zig");

pub const DebugDumpError = std.mem.Allocator.Error || std.fs.File.WriteError;

pub fn dumpSerializedLexicalGrammarAlloc(
    allocator: std.mem.Allocator,
    serialized: lexical_serialize.SerializedLexicalGrammar,
) DebugDumpError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try writeSerializedLexicalGrammar(out.writer(), serialized);
    return try out.toOwnedSlice();
}

pub fn writeSerializedLexicalGrammar(
    writer: anytype,
    serialized: lexical_serialize.SerializedLexicalGrammar,
) !void {
    try writer.print("blocked {}\n", .{serialized.blocked});
    try writer.print("variables {d}\n", .{serialized.variables.len});
    for (serialized.variables, 0..) |variable, index| {
        try writer.print("variable {d}\n", .{index});
        try writer.print("  name {s}\n", .{variable.name});
        try writer.print("  kind {s}\n", .{@tagName(variable.kind)});
        switch (variable.form) {
            .string => |value| try writer.print("  form string {s}\n", .{value}),
            .pattern => |pattern| {
                try writer.print("  form pattern {s}\n", .{pattern.value});
                try writer.print("  flags {?s}\n", .{pattern.flags});
            },
        }
        try writer.print("  tokenized {}\n", .{variable.tokenized});
        try writer.print("  immediate {}\n", .{variable.immediate});
        try writer.print("  implicit_precedence {d}\n", .{variable.implicit_precedence});
        try writer.print("  start_state {d}\n", .{variable.start_state});
    }
    try writer.print("unsupported_separators {d}\n", .{serialized.unsupported_separators.len});
    for (serialized.unsupported_separators, 0..) |separator, index| {
        try writer.print("separator {d} rule {d}\n", .{ index, separator.rule });
    }
    try writer.print("unsupported_externals {d}\n", .{serialized.unsupported_externals.len});
    for (serialized.unsupported_externals, 0..) |external, index| {
        try writer.print("external {d} {s} {s}\n", .{ index, external.name, @tagName(external.kind) });
    }
}

test "dumpSerializedLexicalGrammarAlloc formats serialized lexical grammar deterministically" {
    const serialized = lexical_serialize.SerializedLexicalGrammar{
        .variables = &.{
            .{
                .name = "identifier",
                .kind = .named,
                .form = .{ .pattern = .{ .value = "[a-z]+", .flags = "i" } },
                .tokenized = true,
                .immediate = false,
                .implicit_precedence = 2,
                .start_state = 7,
            },
        },
        .unsupported_separators = &.{.{ .rule = 4 }},
        .unsupported_externals = &.{.{ .name = "indent", .kind = .named }},
        .blocked = true,
    };

    const dump = try dumpSerializedLexicalGrammarAlloc(std.testing.allocator, serialized);
    defer std.testing.allocator.free(dump);

    try std.testing.expectEqualStrings(
        \\blocked true
        \\variables 1
        \\variable 0
        \\  name identifier
        \\  kind named
        \\  form pattern [a-z]+
        \\  flags i
        \\  tokenized true
        \\  immediate false
        \\  implicit_precedence 2
        \\  start_state 7
        \\unsupported_separators 1
        \\separator 0 rule 4
        \\unsupported_externals 1
        \\external 0 indent named
        \\
    , dump);
}

const std = @import("std");
const lexical_serialize = @import("serialize.zig");

pub const LexicalCheckError = error{
    MissingLexicalVariables,
    BlockedWithoutReason,
    ReadyWithUnsupportedFeatures,
    EmptyStringLexicalForm,
    EmptyPatternLexicalForm,
};

pub fn validateSerializedLexicalBoundary(
    serialized: lexical_serialize.SerializedLexicalGrammar,
) LexicalCheckError!void {
    if (serialized.variables.len == 0) return error.MissingLexicalVariables;

    if (serialized.blocked) {
        if (serialized.unsupported_separators.len == 0 and serialized.unsupported_externals.len == 0) {
            return error.BlockedWithoutReason;
        }
    } else {
        if (serialized.unsupported_separators.len != 0 or serialized.unsupported_externals.len != 0) {
            return error.ReadyWithUnsupportedFeatures;
        }
    }

    for (serialized.variables) |variable| {
        switch (variable.form) {
            .string => |value| if (value.len == 0) return error.EmptyStringLexicalForm,
            .pattern => |pattern| if (pattern.value.len == 0) return error.EmptyPatternLexicalForm,
        }
    }
}

test "validateSerializedLexicalBoundary accepts a ready lexical surface" {
    try validateSerializedLexicalBoundary(.{
        .variables = &.{
            .{
                .name = "identifier",
                .kind = .named,
                .form = .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
                .tokenized = true,
                .immediate = false,
                .implicit_precedence = 0,
                .start_state = 0,
            },
        },
        .unsupported_separators = &.{},
        .unsupported_externals = &.{},
        .blocked = false,
    });
}

test "validateSerializedLexicalBoundary rejects blocked surfaces without explicit blockers" {
    try std.testing.expectError(
        error.BlockedWithoutReason,
        validateSerializedLexicalBoundary(.{
            .variables = &.{
                .{
                    .name = "identifier",
                    .kind = .named,
                    .form = .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
                    .tokenized = true,
                    .immediate = false,
                    .implicit_precedence = 0,
                    .start_state = 0,
                },
            },
            .unsupported_separators = &.{},
            .unsupported_externals = &.{},
            .blocked = true,
        }),
    );
}

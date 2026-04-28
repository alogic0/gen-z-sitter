const std = @import("std");
const rules = @import("rules.zig");

pub const LexicalVariable = struct {
    name: []const u8,
    kind: VariableKind,
    rule: rules.RuleId,
    implicit_precedence: i32 = 0,
    start_state: u32 = 0,
    source_kind: SourceKind = .string,
};

pub const VariableKind = enum {
    named,
    anonymous,
    hidden,
    auxiliary,
};

pub const SourceKind = enum {
    string,
    pattern,
    composite,
    token,
};

pub const LexicalGrammar = struct {
    variables: []const LexicalVariable,
    separators: []const rules.RuleId,
};

test "lexical grammar can be instantiated minimally" {
    const grammar = LexicalGrammar{
        .variables = &.{},
        .separators = &.{},
    };

    try std.testing.expectEqual(@as(usize, 0), grammar.variables.len);
    try std.testing.expectEqual(@as(usize, 0), grammar.separators.len);
}

test "lexical variable retains precedence and start state fields" {
    const variable = LexicalVariable{
        .name = "identifier",
        .kind = .named,
        .rule = 4,
        .implicit_precedence = 2,
        .start_state = 7,
    };

    try std.testing.expectEqualStrings("identifier", variable.name);
    try std.testing.expectEqual(@as(i32, 2), variable.implicit_precedence);
    try std.testing.expectEqual(@as(u32, 7), variable.start_state);
}

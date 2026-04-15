const std = @import("std");
const rules = @import("rules.zig");

pub const SyntaxVariable = struct {
    name: []const u8,
    kind: VariableKind,
    productions: []const Production,
};

pub const ExternalToken = struct {
    name: []const u8,
    kind: VariableKind,
};

pub const VariableKind = enum {
    named,
    hidden,
    anonymous,
    auxiliary,
};

pub const Production = struct {
    steps: []ProductionStep,
    dynamic_precedence: i32 = 0,
};

pub const SymbolRef = union(enum) {
    non_terminal: u32,
    terminal: u32,
    external: u32,
};

pub const ProductionStep = struct {
    symbol: SymbolRef,
    alias: ?rules.Alias = null,
    field_name: ?[]const u8 = null,
    precedence: rules.PrecedenceValue = .none,
    associativity: rules.Assoc = .none,
    reserved_context_name: ?[]const u8 = null,
};

pub const SyntaxGrammar = struct {
    variables: []const SyntaxVariable,
    external_tokens: []const ExternalToken,
    extra_symbols: []const SymbolRef,
    expected_conflicts: []const []const SymbolRef,
    precedence_orderings: []const []const PrecedenceEntry,
    variables_to_inline: []const SymbolRef,
    supertype_symbols: []const SymbolRef,
    word_token: ?SymbolRef,
};

pub const PrecedenceEntry = union(enum) {
    name: []const u8,
    symbol: SymbolRef,
};

test "syntax grammar can be instantiated minimally" {
    const grammar = SyntaxGrammar{
        .variables = &.{},
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    try std.testing.expectEqual(@as(usize, 0), grammar.variables.len);
    try std.testing.expectEqual(@as(usize, 0), grammar.external_tokens.len);
    try std.testing.expect(grammar.word_token == null);
}

test "production step preserves metadata fields" {
    const step = ProductionStep{
        .symbol = .{ .non_terminal = 1 },
        .field_name = "lhs",
        .precedence = .{ .name = "sum" },
        .associativity = .left,
    };

    try std.testing.expectEqual(@as(u32, 1), step.symbol.non_terminal);
    try std.testing.expectEqualStrings("lhs", step.field_name.?);
    try std.testing.expectEqual(rules.Assoc.left, step.associativity);
}

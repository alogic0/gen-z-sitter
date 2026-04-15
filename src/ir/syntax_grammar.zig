const std = @import("std");
const symbols = @import("symbols.zig");
const rules = @import("rules.zig");

pub const SyntaxVariable = struct {
    name: []const u8,
    kind: VariableKind,
    productions: []const Production,
};

pub const VariableKind = enum {
    named,
    hidden,
    anonymous,
    auxiliary,
};

pub const Production = struct {
    steps: []const ProductionStep,
    dynamic_precedence: i32 = 0,
};

pub const ProductionStep = struct {
    symbol: symbols.SymbolId,
    alias: ?rules.Alias = null,
    field_name: ?[]const u8 = null,
    precedence: rules.PrecedenceValue = .none,
    associativity: rules.Assoc = .none,
    reserved_context_name: ?[]const u8 = null,
};

pub const SyntaxGrammar = struct {
    variables: []const SyntaxVariable,
    extra_symbols: []const symbols.SymbolId,
    expected_conflicts: []const []const symbols.SymbolId,
    precedence_orderings: []const []const PrecedenceEntry,
    variables_to_inline: []const symbols.SymbolId,
    supertype_symbols: []const symbols.SymbolId,
    word_token: ?symbols.SymbolId,
};

pub const PrecedenceEntry = union(enum) {
    name: []const u8,
    symbol: symbols.SymbolId,
};

test "syntax grammar can be instantiated minimally" {
    const grammar = SyntaxGrammar{
        .variables = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    try std.testing.expectEqual(@as(usize, 0), grammar.variables.len);
    try std.testing.expect(grammar.word_token == null);
}

test "production step preserves metadata fields" {
    const step = ProductionStep{
        .symbol = symbols.SymbolId.nonTerminal(1),
        .field_name = "lhs",
        .precedence = .{ .name = "sum" },
        .associativity = .left,
    };

    try std.testing.expectEqual(@as(u32, 1), step.symbol.index);
    try std.testing.expectEqualStrings("lhs", step.field_name.?);
    try std.testing.expectEqual(rules.Assoc.left, step.associativity);
}

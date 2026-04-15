const std = @import("std");
const symbols = @import("symbols.zig");
const rules = @import("rules.zig");

pub const VariableKind = enum {
    named,
    hidden,
    anonymous,
    auxiliary,
};

pub const Variable = struct {
    name: []const u8,
    symbol: symbols.SymbolId,
    kind: VariableKind,
    rule: rules.RuleId,
};

pub const ExternalToken = struct {
    name: []const u8,
    symbol: symbols.SymbolId,
    kind: VariableKind,
    rule: rules.RuleId,
};

pub const ConflictSet = []const symbols.SymbolId;

pub const PrecedenceEntry = union(enum) {
    name: []const u8,
    symbol: symbols.SymbolId,
};

pub const PrecedenceOrdering = []const PrecedenceEntry;

pub const ReservedWordSet = struct {
    context_name: []const u8,
    members: []const rules.RuleId,
};

pub const PreparedGrammar = struct {
    grammar_name: []const u8,
    variables: []const Variable,
    external_tokens: []const ExternalToken,
    rules: []const rules.Rule,
    symbols: []const symbols.SymbolInfo,
    extra_rules: []const rules.RuleId,
    expected_conflicts: []const ConflictSet,
    precedence_orderings: []const PrecedenceOrdering,
    variables_to_inline: []const symbols.SymbolId,
    supertype_symbols: []const symbols.SymbolId,
    word_token: ?symbols.SymbolId,
    reserved_word_sets: []const ReservedWordSet,
};

test "prepared grammar can be instantiated minimally" {
    const grammar = PreparedGrammar{
        .grammar_name = "basic",
        .variables = &.{},
        .external_tokens = &.{},
        .rules = &.{},
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    try std.testing.expectEqualStrings("basic", grammar.grammar_name);
}

const std = @import("std");
const syntax_ir = @import("../../ir/syntax_grammar.zig");

pub const FlattenGrammarError = error{
    EmptyString,
    RecursiveInline,
    OutOfMemory,
};

pub fn flattenGrammar(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
) FlattenGrammarError!syntax_ir.SyntaxGrammar {
    const variables = try flattenVariables(allocator, grammar.variables);
    try validateEmptyStrings(variables);
    try validateInlineVariables(grammar.variables_to_inline, variables);

    return .{
        .variables = variables,
        .external_tokens = try allocator.dupe(syntax_ir.ExternalToken, grammar.external_tokens),
        .extra_symbols = try allocator.dupe(syntax_ir.SymbolRef, grammar.extra_symbols),
        .expected_conflicts = try cloneConflictSets(allocator, grammar.expected_conflicts),
        .precedence_orderings = try clonePrecedenceOrderings(allocator, grammar.precedence_orderings),
        .variables_to_inline = try allocator.dupe(syntax_ir.SymbolRef, grammar.variables_to_inline),
        .supertype_symbols = try allocator.dupe(syntax_ir.SymbolRef, grammar.supertype_symbols),
        .word_token = grammar.word_token,
    };
}

fn flattenVariables(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
) FlattenGrammarError![]const syntax_ir.SyntaxVariable {
    var result = std.array_list.Managed(syntax_ir.SyntaxVariable).init(allocator);
    defer result.deinit();

    for (variables) |variable| {
        try result.append(.{
            .name = variable.name,
            .kind = variable.kind,
            .productions = try dedupeProductions(allocator, variable.productions),
        });
    }

    return try result.toOwnedSlice();
}

fn dedupeProductions(
    allocator: std.mem.Allocator,
    productions: []const syntax_ir.Production,
) FlattenGrammarError![]const syntax_ir.Production {
    var result = std.array_list.Managed(syntax_ir.Production).init(allocator);
    defer result.deinit();

    for (productions) |production| {
        if (containsProduction(result.items, production)) continue;
        try result.append(try cloneProduction(allocator, production));
    }

    return try result.toOwnedSlice();
}

fn containsProduction(
    productions: []const syntax_ir.Production,
    candidate: syntax_ir.Production,
) bool {
    for (productions) |production| {
        if (productionEql(production, candidate)) return true;
    }
    return false;
}

fn productionEql(a: syntax_ir.Production, b: syntax_ir.Production) bool {
    if (a.dynamic_precedence != b.dynamic_precedence) return false;
    if (a.steps.len != b.steps.len) return false;

    for (a.steps, b.steps) |left, right| {
        if (!stepEql(left, right)) return false;
    }

    return true;
}

fn stepEql(a: syntax_ir.ProductionStep, b: syntax_ir.ProductionStep) bool {
    return symbolRefEql(a.symbol, b.symbol) and
        aliasEql(a.alias, b.alias) and
        std.meta.eql(a.field_name, b.field_name) and
        std.meta.eql(a.precedence, b.precedence) and
        a.associativity == b.associativity and
        std.meta.eql(a.reserved_context_name, b.reserved_context_name);
}

fn symbolRefEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
        .non_terminal => |index| switch (b) {
            .non_terminal => |other| index == other,
            else => false,
        },
        .terminal => |index| switch (b) {
            .terminal => |other| index == other,
            else => false,
        },
        .external => |index| switch (b) {
            .external => |other| index == other,
            else => false,
        },
    };
}

fn aliasEql(a: ?@import("../../ir/rules.zig").Alias, b: ?@import("../../ir/rules.zig").Alias) bool {
    return std.meta.eql(a, b);
}

fn cloneProduction(
    allocator: std.mem.Allocator,
    production: syntax_ir.Production,
) FlattenGrammarError!syntax_ir.Production {
    return .{
        .steps = try allocator.dupe(syntax_ir.ProductionStep, production.steps),
        .dynamic_precedence = production.dynamic_precedence,
    };
}

fn cloneConflictSets(
    allocator: std.mem.Allocator,
    conflicts: []const []const syntax_ir.SymbolRef,
) FlattenGrammarError![]const []const syntax_ir.SymbolRef {
    var result = std.array_list.Managed([]const syntax_ir.SymbolRef).init(allocator);
    defer result.deinit();

    for (conflicts) |conflict| {
        try result.append(try allocator.dupe(syntax_ir.SymbolRef, conflict));
    }

    return try result.toOwnedSlice();
}

fn clonePrecedenceOrderings(
    allocator: std.mem.Allocator,
    orderings: []const []const syntax_ir.PrecedenceEntry,
) FlattenGrammarError![]const []const syntax_ir.PrecedenceEntry {
    var result = std.array_list.Managed([]const syntax_ir.PrecedenceEntry).init(allocator);
    defer result.deinit();

    for (orderings) |ordering| {
        try result.append(try allocator.dupe(syntax_ir.PrecedenceEntry, ordering));
    }

    return try result.toOwnedSlice();
}

fn validateEmptyStrings(variables: []const syntax_ir.SyntaxVariable) FlattenGrammarError!void {
    for (variables, 0..) |variable, index| {
        for (variable.productions) |production| {
            if (production.steps.len == 0 and index != 0 and variable.kind != .auxiliary) {
                return error.EmptyString;
            }
        }
    }
}

fn validateInlineVariables(
    symbols_to_inline: []const syntax_ir.SymbolRef,
    variables: []const syntax_ir.SyntaxVariable,
) FlattenGrammarError!void {
    for (symbols_to_inline) |symbol| {
        const index = switch (symbol) {
            .non_terminal => |i| i,
            else => continue,
        };

        const variable = variables[index];
        if (variableReferencesSelf(index, variable)) {
            return error.RecursiveInline;
        }
    }
}

fn variableReferencesSelf(index: u32, variable: syntax_ir.SyntaxVariable) bool {
    for (variable.productions) |production| {
        for (production.steps) |step| {
            switch (step.symbol) {
                .non_terminal => |other| if (other == index) return true,
                else => {},
            }
        }
    }
    return false;
}

test "flattenGrammar deduplicates duplicate productions while preserving metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_steps_a = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .field_name = "lhs",
            .precedence = .{ .integer = 1 },
            .associativity = .left,
        },
    };
    var source_steps_b = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .field_name = "lhs",
            .precedence = .{ .integer = 1 },
            .associativity = .left,
        },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = source_steps_a[0..] },
                    .{ .steps = source_steps_b[0..] },
                },
            },
            .{
                .name = "expr",
                .kind = .named,
                .productions = &.{
                    .{ .steps = expr_steps[0..] },
                },
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const flattened = try flattenGrammar(arena.allocator(), grammar);
    try std.testing.expectEqual(@as(usize, 1), flattened.variables[0].productions.len);
    try std.testing.expectEqualStrings("lhs", flattened.variables[0].productions[0].steps[0].field_name.?);
    try std.testing.expectEqual(@as(i64, 1), flattened.variables[0].productions[0].steps[0].precedence.integer);
}

test "flattenGrammar rejects empty strings outside the start rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var start_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = start_steps[0..] },
                },
            },
            .{
                .name = "expr",
                .kind = .named,
                .productions = &.{
                    .{ .steps = &.{} },
                },
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    try std.testing.expectError(error.EmptyString, flattenGrammar(arena.allocator(), grammar));
}

test "flattenGrammar allows empty string on the start rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = &.{} },
                },
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const flattened = try flattenGrammar(arena.allocator(), grammar);
    try std.testing.expectEqual(@as(usize, 1), flattened.variables.len);
    try std.testing.expectEqual(@as(usize, 0), flattened.variables[0].productions[0].steps.len);
}

test "flattenGrammar allows empty string on auxiliary repeat variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var start_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var repeat_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = start_steps[0..] },
                },
            },
            .{
                .name = "source_file_repeat1",
                .kind = .auxiliary,
                .productions = &.{
                    .{ .steps = &.{} },
                    .{ .steps = repeat_steps[0..] },
                },
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const flattened = try flattenGrammar(arena.allocator(), grammar);
    try std.testing.expectEqual(@as(usize, 2), flattened.variables.len);
    try std.testing.expectEqual(@as(usize, 2), flattened.variables[1].productions.len);
}

test "flattenGrammar rejects recursive inline variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recursive_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = recursive_steps[0..] },
                },
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{.{ .non_terminal = 0 }},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    try std.testing.expectError(error.RecursiveInline, flattenGrammar(arena.allocator(), grammar));
}

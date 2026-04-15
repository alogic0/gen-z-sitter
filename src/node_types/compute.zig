const std = @import("std");
const alias_ir = @import("../ir/aliases.zig");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const rules = @import("../ir/rules.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const ComputeNodeTypesError = error{
    InvalidSupertype,
    OutOfMemory,
};

pub const NodeType = struct {
    kind: []const u8,
    named: bool,
    root: bool = false,
    extra: bool = false,
    subtypes: []const NodeTypeRef = &.{},
};

pub const NodeTypeRef = struct {
    kind: []const u8,
    named: bool,
};

pub fn computeNodeTypes(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) ComputeNodeTypesError![]const NodeType {
    var nodes = std.array_list.Managed(NodeType).init(allocator);
    defer nodes.deinit();

    for (syntax.variables, 0..) |variable, index| {
        if (!isVisibleSyntaxVariable(variable)) continue;

        const symbol: syntax_ir.SymbolRef = .{ .non_terminal = @intCast(index) };
        const subtype_refs = if (containsSymbolRef(syntax.supertype_symbols, symbol))
            try computeSupertypeRefs(allocator, syntax, lexical, defaults, symbol)
        else
            &.{};

        try nodes.append(.{
            .kind = effectiveNameForSymbol(symbol, syntax, lexical, defaults),
            .named = isNamedSyntaxVariable(variable, defaults.findForSymbol(symbol)),
            .root = index == 0,
            .extra = containsSymbolRef(syntax.extra_symbols, symbol),
            .subtypes = subtype_refs,
        });
    }

    for (lexical.variables, 0..) |variable, index| {
        const symbol: syntax_ir.SymbolRef = .{ .terminal = @intCast(index) };
        if (!isVisibleLexicalVariable(variable, defaults.findForSymbol(symbol))) continue;

        try nodes.append(.{
            .kind = effectiveNameForSymbol(symbol, syntax, lexical, defaults),
            .named = isNamedLexicalVariable(variable, defaults.findForSymbol(symbol)),
            .extra = containsSymbolRef(syntax.extra_symbols, symbol),
        });
    }

    std.mem.sort(NodeType, nodes.items, {}, lessThanNodeType);
    return try nodes.toOwnedSlice();
}

fn computeSupertypeRefs(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
    supertype_symbol: syntax_ir.SymbolRef,
) ComputeNodeTypesError![]const NodeTypeRef {
    var refs = std.array_list.Managed(NodeTypeRef).init(allocator);
    defer refs.deinit();

    const supertype_index = switch (supertype_symbol) {
        .non_terminal => |index| index,
        else => return error.InvalidSupertype,
    };

    const variable = syntax.variables[supertype_index];
    for (variable.productions) |production| {
        if (production.steps.len != 1) return error.InvalidSupertype;
        const step = production.steps[0];
        if (containsSymbolRef(syntax.supertype_symbols, step.symbol)) return error.InvalidSupertype;
        if (!isVisibleChild(step.symbol, syntax, lexical, defaults)) return error.InvalidSupertype;

        const candidate = NodeTypeRef{
            .kind = effectiveNameForSymbol(step.symbol, syntax, lexical, defaults),
            .named = isNamedSymbol(step.symbol, syntax, lexical, defaults),
        };
        if (!containsNodeTypeRef(refs.items, candidate)) {
            try refs.append(candidate);
        }
    }

    std.mem.sort(NodeTypeRef, refs.items, {}, lessThanNodeTypeRef);
    return try refs.toOwnedSlice();
}

fn isVisibleChild(
    symbol: syntax_ir.SymbolRef,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) bool {
    return switch (symbol) {
        .non_terminal => |index| isVisibleSyntaxVariable(syntax.variables[index]),
        .terminal => |index| isVisibleLexicalVariable(lexical.variables[index], defaults.findForSymbol(symbol)),
        .external => true,
    };
}

fn effectiveNameForSymbol(
    symbol: syntax_ir.SymbolRef,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) []const u8 {
    if (defaults.findForSymbol(symbol)) |alias| return alias.value;

    return switch (symbol) {
        .non_terminal => |index| syntax.variables[index].name,
        .terminal => |index| lexical.variables[index].name,
        .external => "external",
    };
}

fn isNamedSymbol(
    symbol: syntax_ir.SymbolRef,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) bool {
    const alias = defaults.findForSymbol(symbol);
    return switch (symbol) {
        .non_terminal => |index| isNamedSyntaxVariable(syntax.variables[index], alias),
        .terminal => |index| isNamedLexicalVariable(lexical.variables[index], alias),
        .external => alias != null and alias.?.named,
    };
}

fn isVisibleSyntaxVariable(variable: syntax_ir.SyntaxVariable) bool {
    return switch (variable.kind) {
        .hidden, .auxiliary => false,
        .named, .anonymous => true,
    };
}

fn isNamedSyntaxVariable(variable: syntax_ir.SyntaxVariable, alias: ?rules.Alias) bool {
    if (alias) |a| return a.named;
    return switch (variable.kind) {
        .named => true,
        .anonymous, .hidden, .auxiliary => false,
    };
}

fn isVisibleLexicalVariable(variable: lexical_ir.LexicalVariable, alias: ?rules.Alias) bool {
    if (alias != null) return true;
    return switch (variable.kind) {
        .hidden, .auxiliary => false,
        .named, .anonymous => true,
    };
}

fn isNamedLexicalVariable(variable: lexical_ir.LexicalVariable, alias: ?rules.Alias) bool {
    if (alias) |a| return a.named;
    return switch (variable.kind) {
        .named => true,
        .anonymous, .hidden, .auxiliary => false,
    };
}

fn containsSymbolRef(haystack: []const syntax_ir.SymbolRef, needle: syntax_ir.SymbolRef) bool {
    for (haystack) |entry| {
        if (symbolRefEql(entry, needle)) return true;
    }
    return false;
}

fn containsNodeTypeRef(haystack: []const NodeTypeRef, needle: NodeTypeRef) bool {
    for (haystack) |entry| {
        if (std.mem.eql(u8, entry.kind, needle.kind) and entry.named == needle.named) return true;
    }
    return false;
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

fn lessThanNodeType(_: void, a: NodeType, b: NodeType) bool {
    const kind_order = std.mem.order(u8, a.kind, b.kind);
    if (kind_order != .eq) return kind_order == .lt;
    return @intFromBool(a.named) < @intFromBool(b.named);
}

fn lessThanNodeTypeRef(_: void, a: NodeTypeRef, b: NodeTypeRef) bool {
    const kind_order = std.mem.order(u8, a.kind, b.kind);
    if (kind_order != .eq) return kind_order == .lt;
    return @intFromBool(a.named) < @intFromBool(b.named);
}

test "computeNodeTypes includes visible syntax and lexical nodes with default aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 0 } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = root_steps[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
            .{ .name = "_hidden", .kind = .hidden, .productions = &.{.{ .steps = &.{} }} },
        },
        .extra_symbols = &.{.{ .terminal = 0 }},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "comma", .kind = .anonymous, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };
    const defaults = alias_ir.AliasMap{
        .entries = &.{.{
            .target = .{ .symbol = .{ .terminal = 0 } },
            .alias = .{ .value = ",", .named = false },
        }},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, defaults);
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expectEqualStrings(",", nodes[0].kind);
    try std.testing.expect(!nodes[0].named);
    try std.testing.expect(nodes[0].extra);
    try std.testing.expectEqualStrings("expr", nodes[1].kind);
    try std.testing.expect(nodes[1].named);
    try std.testing.expectEqualStrings("identifier", nodes[2].kind);
    try std.testing.expectEqualStrings("source_file", nodes[3].kind);
    try std.testing.expect(nodes[3].root);
}

test "computeNodeTypes computes visible supertype subtypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var super_prod_a = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var super_prod_b = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 3 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = root_steps[0..] }} },
            .{ .name = "expression", .kind = .named, .productions = &.{.{ .steps = super_prod_a[0..] }, .{ .steps = super_prod_b[0..] }} },
            .{ .name = "binary_expression", .kind = .named, .productions = &.{.{ .steps = &.{} }} },
            .{ .name = "identifier", .kind = .named, .productions = &.{.{ .steps = &.{} }} },
        },
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{.{ .non_terminal = 1 }},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{},
        .separators = &.{},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, .{ .entries = &.{} });
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expectEqualStrings("expression", nodes[1].kind);
    try std.testing.expectEqual(@as(usize, 2), nodes[1].subtypes.len);
    try std.testing.expectEqualStrings("binary_expression", nodes[1].subtypes[0].kind);
    try std.testing.expectEqualStrings("identifier", nodes[1].subtypes[1].kind);
}

const std = @import("std");
const alias_ir = @import("../../ir/aliases.zig");
const lexical_ir = @import("../../ir/lexical_grammar.zig");
const rules = @import("../../ir/rules.zig");
const syntax_ir = @import("../../ir/syntax_grammar.zig");

pub const ExtractDefaultAliasesError = error{
    OutOfMemory,
};

pub const DefaultAliasResult = struct {
    syntax: syntax_ir.SyntaxGrammar,
    defaults: alias_ir.AliasMap,
};

const AliasCount = struct {
    alias: rules.Alias,
    count: usize,
};

const SymbolStatus = struct {
    aliases: std.array_list.Managed(AliasCount),
    appears_unaliased: bool = false,

    fn init(allocator: std.mem.Allocator) SymbolStatus {
        return .{
            .aliases = std.array_list.Managed(AliasCount).init(allocator),
        };
    }
};

pub fn extractDefaultAliases(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
) ExtractDefaultAliasesError!DefaultAliasResult {
    const syntax_copy = try cloneSyntaxGrammar(allocator, syntax);

    const terminal_statuses = try initStatusList(allocator, lexical.variables.len);
    const non_terminal_statuses = try initStatusList(allocator, syntax_copy.variables.len);
    const external_statuses = try initStatusList(allocator, countExternalSymbols(syntax_copy));

    try collectStatuses(syntax_copy, terminal_statuses, non_terminal_statuses, external_statuses);
    markExtraSymbolsUnaliased(syntax_copy.extra_symbols, terminal_statuses, non_terminal_statuses, external_statuses);

    const defaults = try buildDefaultAliasMap(
        allocator,
        terminal_statuses,
        non_terminal_statuses,
        external_statuses,
    );

    try clearDefaultAliasUses(
        allocator,
        syntax_copy.variables,
        defaults,
        terminal_statuses,
        non_terminal_statuses,
        external_statuses,
    );

    return .{
        .syntax = syntax_copy,
        .defaults = defaults,
    };
}

fn cloneSyntaxGrammar(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
) ExtractDefaultAliasesError!syntax_ir.SyntaxGrammar {
    var variables = std.array_list.Managed(syntax_ir.SyntaxVariable).init(allocator);
    defer variables.deinit();

    for (syntax.variables) |variable| {
        var productions = std.array_list.Managed(syntax_ir.Production).init(allocator);
        defer productions.deinit();

        for (variable.productions) |production| {
            try productions.append(.{
                .steps = try allocator.dupe(syntax_ir.ProductionStep, production.steps),
                .dynamic_precedence = production.dynamic_precedence,
            });
        }

        try variables.append(.{
            .name = variable.name,
            .kind = variable.kind,
            .productions = try productions.toOwnedSlice(),
        });
    }

    return .{
        .variables = try variables.toOwnedSlice(),
        .external_tokens = try allocator.dupe(syntax_ir.ExternalToken, syntax.external_tokens),
        .extra_symbols = try allocator.dupe(syntax_ir.SymbolRef, syntax.extra_symbols),
        .expected_conflicts = try cloneConflictSets(allocator, syntax.expected_conflicts),
        .precedence_orderings = try clonePrecedenceOrderings(allocator, syntax.precedence_orderings),
        .variables_to_inline = try allocator.dupe(syntax_ir.SymbolRef, syntax.variables_to_inline),
        .supertype_symbols = try allocator.dupe(syntax_ir.SymbolRef, syntax.supertype_symbols),
        .word_token = syntax.word_token,
    };
}

fn cloneConflictSets(
    allocator: std.mem.Allocator,
    conflicts: []const []const syntax_ir.SymbolRef,
) ExtractDefaultAliasesError![]const []const syntax_ir.SymbolRef {
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
) ExtractDefaultAliasesError![]const []const syntax_ir.PrecedenceEntry {
    var result = std.array_list.Managed([]const syntax_ir.PrecedenceEntry).init(allocator);
    defer result.deinit();

    for (orderings) |ordering| {
        try result.append(try allocator.dupe(syntax_ir.PrecedenceEntry, ordering));
    }

    return try result.toOwnedSlice();
}

fn initStatusList(
    allocator: std.mem.Allocator,
    len: usize,
) ExtractDefaultAliasesError![]SymbolStatus {
    const statuses = try allocator.alloc(SymbolStatus, len);
    for (statuses) |*status| {
        status.* = SymbolStatus.init(allocator);
    }
    return statuses;
}

fn countExternalSymbols(grammar: syntax_ir.SyntaxGrammar) usize {
    var max_index: ?u32 = null;

    for (grammar.variables) |variable| {
        for (variable.productions) |production| {
            for (production.steps) |step| {
                switch (step.symbol) {
                    .external => |index| {
                        if (max_index == null or index > max_index.?) max_index = index;
                    },
                    else => {},
                }
            }
        }
    }

    for (grammar.extra_symbols) |symbol| {
        switch (symbol) {
            .external => |index| {
                if (max_index == null or index > max_index.?) max_index = index;
            },
            else => {},
        }
    }

    return if (max_index) |index| index + 1 else 0;
}

fn collectStatuses(
    grammar: syntax_ir.SyntaxGrammar,
    terminal_statuses: []SymbolStatus,
    non_terminal_statuses: []SymbolStatus,
    external_statuses: []SymbolStatus,
) ExtractDefaultAliasesError!void {
    for (grammar.variables) |variable| {
        for (variable.productions) |production| {
            for (production.steps) |step| {
                if (containsInlineSymbol(grammar.variables_to_inline, step.symbol)) continue;

                const status = statusForSymbol(step.symbol, terminal_statuses, non_terminal_statuses, external_statuses);
                if (step.alias) |alias| {
                    try incrementAliasCount(status, alias);
                } else {
                    status.appears_unaliased = true;
                }
            }
        }
    }
}

fn markExtraSymbolsUnaliased(
    extra_symbols: []const syntax_ir.SymbolRef,
    terminal_statuses: []SymbolStatus,
    non_terminal_statuses: []SymbolStatus,
    external_statuses: []SymbolStatus,
) void {
    for (extra_symbols) |symbol| {
        const status = statusForSymbol(symbol, terminal_statuses, non_terminal_statuses, external_statuses);
        status.appears_unaliased = true;
    }
}

fn incrementAliasCount(status: *SymbolStatus, alias: rules.Alias) ExtractDefaultAliasesError!void {
    for (status.aliases.items) |*entry| {
        if (std.meta.eql(entry.alias, alias)) {
            entry.count += 1;
            return;
        }
    }

    try status.aliases.append(.{
        .alias = alias,
        .count = 1,
    });
}

fn buildDefaultAliasMap(
    allocator: std.mem.Allocator,
    terminal_statuses: []SymbolStatus,
    non_terminal_statuses: []SymbolStatus,
    external_statuses: []SymbolStatus,
) ExtractDefaultAliasesError!alias_ir.AliasMap {
    var entries = std.array_list.Managed(alias_ir.AliasEntry).init(allocator);
    defer entries.deinit();

    for (terminal_statuses, 0..) |*status, index| {
        if (try chooseDefaultAlias(status)) |alias| {
            try entries.append(.{
                .target = .{ .symbol = .{ .terminal = @intCast(index) } },
                .alias = alias,
            });
        }
    }

    for (non_terminal_statuses, 0..) |*status, index| {
        if (try chooseDefaultAlias(status)) |alias| {
            try entries.append(.{
                .target = .{ .symbol = .{ .non_terminal = @intCast(index) } },
                .alias = alias,
            });
        }
    }

    for (external_statuses, 0..) |*status, index| {
        if (try chooseDefaultAlias(status)) |alias| {
            try entries.append(.{
                .target = .{ .symbol = .{ .external = @intCast(index) } },
                .alias = alias,
            });
        }
    }

    return .{
        .entries = try entries.toOwnedSlice(),
    };
}

fn chooseDefaultAlias(status: *SymbolStatus) ExtractDefaultAliasesError!?rules.Alias {
    if (status.appears_unaliased or status.aliases.items.len == 0) {
        status.aliases.clearRetainingCapacity();
        return null;
    }

    var best_index: usize = 0;
    for (status.aliases.items[1..], 1..) |entry, i| {
        if (entry.count > status.aliases.items[best_index].count) {
            best_index = i;
        }
    }

    const best = status.aliases.items[best_index];
    status.aliases.clearRetainingCapacity();
    try status.aliases.append(best);
    return best.alias;
}

fn clearDefaultAliasUses(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    defaults: alias_ir.AliasMap,
    terminal_statuses: []SymbolStatus,
    non_terminal_statuses: []SymbolStatus,
    external_statuses: []SymbolStatus,
) ExtractDefaultAliasesError!void {
    _ = terminal_statuses;
    _ = non_terminal_statuses;
    _ = external_statuses;

    for (variables) |*variable| {
        var positions = std.array_list.Managed(struct { production_index: usize, step_index: usize }).init(allocator);
        defer positions.deinit();

        for (variable.productions, 0..) |production, production_index| {
            for (production.steps, 0..) |step, step_index| {
                if (step.alias == null) continue;
                const default_alias = defaultAliasForSymbol(defaults, step.symbol) orelse continue;
                if (!std.meta.eql(step.alias.?, default_alias)) continue;

                var must_keep = false;
                for (variable.productions, 0..) |other_production, other_index| {
                    if (other_index == production_index) continue;
                    if (other_production.steps.len <= step_index) continue;
                    const other_step = other_production.steps[step_index];
                    if (other_step.alias == null) continue;
                    if (!std.meta.eql(other_step.alias.?, step.alias.?)) continue;

                    const other_default = defaultAliasForSymbol(defaults, other_step.symbol);
                    if (other_default == null or !std.meta.eql(other_default.?, step.alias.?)) {
                        must_keep = true;
                        break;
                    }
                }

                if (!must_keep) {
                    try positions.append(.{
                        .production_index = production_index,
                        .step_index = step_index,
                    });
                }
            }
        }

        for (positions.items) |position| {
            @constCast(variable.productions[position.production_index].steps)[position.step_index].alias = null;
        }
    }
}

fn containsInlineSymbol(symbols: []const syntax_ir.SymbolRef, candidate: syntax_ir.SymbolRef) bool {
    for (symbols) |symbol| {
        if (symbolRefEql(symbol, candidate)) return true;
    }
    return false;
}

fn statusForSymbol(
    symbol: syntax_ir.SymbolRef,
    terminal_statuses: []SymbolStatus,
    non_terminal_statuses: []SymbolStatus,
    external_statuses: []SymbolStatus,
) *SymbolStatus {
    return switch (symbol) {
        .terminal => |index| &terminal_statuses[index],
        .non_terminal => |index| &non_terminal_statuses[index],
        .external => |index| &external_statuses[index],
    };
}

fn defaultAliasForSymbol(defaults: alias_ir.AliasMap, symbol: syntax_ir.SymbolRef) ?rules.Alias {
    return switch (symbol) {
        .terminal => |index| defaults.findForSymbol(.{ .terminal = index }),
        .non_terminal => |index| defaults.findForSymbol(.{ .non_terminal = index }),
        .external => |index| defaults.findForSymbol(.{ .external = index }),
    };
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

test "extractDefaultAliases promotes always-aliased symbols and clears redundant aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var prod1_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 }, .alias = .{ .value = "atom", .named = true } },
        .{ .symbol = .{ .terminal = 1 }, .alias = .{ .value = "plus", .named = false } },
    };
    var prod2_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 }, .alias = .{ .value = "atom", .named = true } },
        .{ .symbol = .{ .terminal = 1 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = prod1_steps[0..] },
                    .{ .steps = prod2_steps[0..] },
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
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "t0", .kind = .named, .rule = 0 },
            .{ .name = "t1", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };

    const result = try extractDefaultAliases(arena.allocator(), syntax, lexical);
    const default_alias = result.defaults.findForSymbol(.{ .terminal = 0 }).?;
    try std.testing.expectEqualStrings("atom", default_alias.value);
    try std.testing.expect(result.defaults.findForSymbol(.{ .terminal = 1 }) == null);
    try std.testing.expect(result.syntax.variables[0].productions[0].steps[0].alias == null);
    try std.testing.expect(result.syntax.variables[0].productions[1].steps[0].alias == null);
    try std.testing.expectEqualStrings("plus", result.syntax.variables[0].productions[0].steps[1].alias.?.value);
}

test "extractDefaultAliases does not promote aliases for inlined variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 0 }, .alias = .{ .value = "expr", .named = true } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = steps[0..] },
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
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{},
        .separators = &.{},
    };

    const result = try extractDefaultAliases(arena.allocator(), syntax, lexical);
    try std.testing.expect(result.defaults.findForSymbol(.{ .non_terminal = 0 }) == null);
    try std.testing.expectEqualStrings("expr", result.syntax.variables[0].productions[0].steps[0].alias.?.value);
}

test "extractDefaultAliases promotes always-aliased external tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var prod1_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .external = 0 }, .alias = .{ .value = "template_chunk", .named = true } },
    };
    var prod2_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .external = 0 }, .alias = .{ .value = "template_chunk", .named = true } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = prod1_steps[0..] },
                    .{ .steps = prod2_steps[0..] },
                },
            },
        },
        .external_tokens = &.{
            .{ .name = "template_chars", .kind = .named },
        },
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{},
        .separators = &.{},
    };

    const result = try extractDefaultAliases(arena.allocator(), syntax, lexical);
    const default_alias = result.defaults.findForSymbol(.{ .external = 0 }).?;
    try std.testing.expectEqualStrings("template_chunk", default_alias.value);
    try std.testing.expect(default_alias.named);
    try std.testing.expect(result.syntax.variables[0].productions[0].steps[0].alias == null);
    try std.testing.expect(result.syntax.variables[0].productions[1].steps[0].alias == null);
}

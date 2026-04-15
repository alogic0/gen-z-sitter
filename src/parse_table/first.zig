const std = @import("std");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const FirstError = std.mem.Allocator.Error;

pub const SymbolSet = struct {
    terminals: []bool,
    externals: []bool,
    includes_epsilon: bool = false,

    pub fn containsTerminal(self: SymbolSet, index: u32) bool {
        return self.terminals[index];
    }

    pub fn containsExternal(self: SymbolSet, index: u32) bool {
        return self.externals[index];
    }

    pub fn isEmpty(self: SymbolSet) bool {
        if (self.includes_epsilon) return false;
        for (self.terminals) |present| {
            if (present) return false;
        }
        for (self.externals) |present| {
            if (present) return false;
        }
        return true;
    }

    pub fn eql(a: SymbolSet, b: SymbolSet) bool {
        return a.includes_epsilon == b.includes_epsilon and
            std.mem.eql(bool, a.terminals, b.terminals) and
            std.mem.eql(bool, a.externals, b.externals);
    }
};

pub const FirstSets = struct {
    terminals_len: usize,
    externals_len: usize,
    per_variable: []SymbolSet,

    pub fn firstOfVariable(self: FirstSets, index: u32) SymbolSet {
        return self.per_variable[index];
    }

    pub fn firstOfSequence(
        self: FirstSets,
        allocator: std.mem.Allocator,
        steps: []const syntax_ir.ProductionStep,
    ) FirstError!SymbolSet {
        return computeSequenceFirst(allocator, self.terminals_len, self.externals_len, self.per_variable, steps);
    }
};

pub fn computeFirstSets(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
) FirstError!FirstSets {
    const counts = countSymbols(grammar);
    const per_variable = try allocator.alloc(SymbolSet, grammar.variables.len);

    for (per_variable) |*entry| {
        entry.* = .{
            .terminals = try allocator.alloc(bool, counts.terminals),
            .externals = try allocator.alloc(bool, counts.externals),
            .includes_epsilon = false,
        };
        @memset(entry.terminals, false);
        @memset(entry.externals, false);
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (grammar.variables, 0..) |variable, variable_index| {
            var variable_set = per_variable[variable_index];
            for (variable.productions) |production| {
                if (try mergeProductionIntoSet(
                    allocator,
                    counts.terminals,
                    counts.externals,
                    per_variable,
                    production.steps,
                    &variable_set,
                )) {
                    changed = true;
                }
            }
            per_variable[variable_index] = variable_set;
        }
    }

    return .{
        .terminals_len = counts.terminals,
        .externals_len = counts.externals,
        .per_variable = per_variable,
    };
}

fn computeSequenceFirst(
    allocator: std.mem.Allocator,
    terminals_len: usize,
    externals_len: usize,
    per_variable: []const SymbolSet,
    steps: []const syntax_ir.ProductionStep,
) FirstError!SymbolSet {
    var result = SymbolSet{
        .terminals = try allocator.alloc(bool, terminals_len),
        .externals = try allocator.alloc(bool, externals_len),
        .includes_epsilon = false,
    };
    @memset(result.terminals, false);
    @memset(result.externals, false);

    if (steps.len == 0) {
        result.includes_epsilon = true;
        return result;
    }

    var all_nullable = true;
    for (steps) |step| {
        switch (step.symbol) {
            .terminal => |index| {
                result.terminals[index] = true;
                all_nullable = false;
                break;
            },
            .external => |index| {
                result.externals[index] = true;
                all_nullable = false;
                break;
            },
            .non_terminal => |index| {
                const first = per_variable[index];
                _ = changedMergeWithoutEpsilon(&result, first);
                if (!first.includes_epsilon) {
                    all_nullable = false;
                    break;
                }
            },
        }
    }

    if (all_nullable) result.includes_epsilon = true;
    return result;
}

fn mergeProductionIntoSet(
    allocator: std.mem.Allocator,
    terminals_len: usize,
    externals_len: usize,
    per_variable: []const SymbolSet,
    steps: []const syntax_ir.ProductionStep,
    target: *SymbolSet,
) FirstError!bool {
    const production_first = try computeSequenceFirst(allocator, terminals_len, externals_len, per_variable, steps);
    return mergeSymbolSets(target, production_first);
}

fn mergeSymbolSets(target: *SymbolSet, incoming: SymbolSet) bool {
    var changed = false;

    if (incoming.includes_epsilon and !target.includes_epsilon) {
        target.includes_epsilon = true;
        changed = true;
    }

    for (incoming.terminals, 0..) |present, index| {
        if (present and !target.terminals[index]) {
            target.terminals[index] = true;
            changed = true;
        }
    }

    for (incoming.externals, 0..) |present, index| {
        if (present and !target.externals[index]) {
            target.externals[index] = true;
            changed = true;
        }
    }

    return changed;
}

fn changedMergeWithoutEpsilon(target: *SymbolSet, incoming: SymbolSet) bool {
    var changed = false;

    for (incoming.terminals, 0..) |present, index| {
        if (present and !target.terminals[index]) {
            target.terminals[index] = true;
            changed = true;
        }
    }

    for (incoming.externals, 0..) |present, index| {
        if (present and !target.externals[index]) {
            target.externals[index] = true;
            changed = true;
        }
    }

    return changed;
}

fn countSymbols(grammar: syntax_ir.SyntaxGrammar) struct { terminals: usize, externals: usize } {
    var max_terminal: usize = 0;
    var max_external: usize = 0;

    for (grammar.variables) |variable| {
        for (variable.productions) |production| {
            for (production.steps) |step| {
                switch (step.symbol) {
                    .terminal => |index| max_terminal = @max(max_terminal, index + 1),
                    .external => |index| max_external = @max(max_external, index + 1),
                    .non_terminal => {},
                }
            }
        }
    }

    for (grammar.extra_symbols) |symbol| {
        switch (symbol) {
            .terminal => |index| max_terminal = @max(max_terminal, index + 1),
            .external => |index| max_external = @max(max_external, index + 1),
            .non_terminal => {},
        }
    }

    if (grammar.word_token) |symbol| {
        switch (symbol) {
            .terminal => |index| max_terminal = @max(max_terminal, index + 1),
            .external => |index| max_external = @max(max_external, index + 1),
            .non_terminal => {},
        }
    }

    return .{
        .terminals = max_terminal,
        .externals = max_external,
    };
}

test "computeFirstSets handles terminals and nullable prefixes deterministically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var empty_steps = [_]syntax_ir.ProductionStep{};
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = source_steps[0..] },
                },
            },
            .{
                .name = "expr",
                .kind = .named,
                .productions = &.{
                    .{ .steps = empty_steps[0..] },
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

    const first_sets = try computeFirstSets(arena.allocator(), grammar);
    const source_first = first_sets.firstOfVariable(0);
    const expr_first = first_sets.firstOfVariable(1);

    try std.testing.expect(source_first.containsTerminal(0));
    try std.testing.expect(source_first.includes_epsilon);
    try std.testing.expect(expr_first.containsTerminal(0));
    try std.testing.expect(expr_first.includes_epsilon);
}

test "firstOfSequence carries terminals across nullable non-terminals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var empty_steps = [_]syntax_ir.ProductionStep{};
    var token_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = source_steps[0..] },
                },
            },
            .{
                .name = "nullable",
                .kind = .named,
                .productions = &.{
                    .{ .steps = empty_steps[0..] },
                },
            },
            .{
                .name = "token_holder",
                .kind = .named,
                .productions = &.{
                    .{ .steps = token_steps[0..] },
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

    const first_sets = try computeFirstSets(arena.allocator(), grammar);
    const sequence = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 0 } },
    };
    const sequence_first = try first_sets.firstOfSequence(arena.allocator(), sequence[0..]);

    try std.testing.expect(sequence_first.containsTerminal(0));
    try std.testing.expect(!sequence_first.includes_epsilon);
}

test "computeFirstSets includes externals in first sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .external = 1 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{ .steps = source_steps[0..] },
                },
            },
        },
        .external_tokens = &.{
            .{ .name = "indent", .kind = .named },
            .{ .name = "dedent", .kind = .named },
        },
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const first_sets = try computeFirstSets(arena.allocator(), grammar);
    const source_first = first_sets.firstOfVariable(0);

    try std.testing.expect(source_first.containsExternal(1));
    try std.testing.expect(!source_first.includes_epsilon);
}

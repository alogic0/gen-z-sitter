const std = @import("std");
const actions = @import("actions.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const first = @import("first.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const conflicts = @import("conflicts.zig");
const resolution = @import("resolution.zig");
const rules = @import("../ir/rules.zig");

pub const BuildError = error{
    UnsupportedFeature,
    OutOfMemory,
};

pub const ProductionInfo = struct {
    lhs: u32,
    steps: []const syntax_ir.ProductionStep,
    augmented: bool = false,
    dynamic_precedence: i32 = 0,
};

pub const BuildResult = struct {
    productions: []const ProductionInfo,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    states: []const state.ParseState,
    actions: actions.ActionTable,
    resolved_actions: resolution.ResolvedActionTable,
};

pub fn buildStates(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
) BuildError!BuildResult {
    try validateSupportedSubset(grammar);

    const first_sets = try first.computeFirstSets(allocator, grammar);
    const productions = try collectProductions(allocator, grammar);
    const constructed = try constructStates(allocator, productions, first_sets);
    const grouped_actions = try actions.groupActionTable(allocator, constructed.actions);
    const resolved_actions = try resolution.resolveActionTableWithPrecedence(
        allocator,
        productions,
        grammar.precedence_orderings,
        grouped_actions,
    );
    return .{
        .productions = productions,
        .precedence_orderings = grammar.precedence_orderings,
        .states = constructed.states,
        .actions = constructed.actions,
        .resolved_actions = resolved_actions,
    };
}

const ConstructedStates = struct {
    states: []const state.ParseState,
    actions: actions.ActionTable,
};

fn validateSupportedSubset(grammar: syntax_ir.SyntaxGrammar) BuildError!void {
    _ = grammar;
}

fn collectProductions(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
) BuildError![]const ProductionInfo {
    var productions = std.array_list.Managed(ProductionInfo).init(allocator);
    defer productions.deinit();

    const augmented_steps = try allocator.alloc(syntax_ir.ProductionStep, 1);
    augmented_steps[0] = .{ .symbol = .{ .non_terminal = 0 } };
    try productions.append(.{
        .lhs = std.math.maxInt(u32),
        .steps = augmented_steps,
        .augmented = true,
    });

    for (grammar.variables, 0..) |variable, variable_index| {
        for (variable.productions) |production| {
            try productions.append(.{
                .lhs = @intCast(variable_index),
                .steps = production.steps,
                .dynamic_precedence = production.dynamic_precedence,
            });
        }
    }

    return try productions.toOwnedSlice();
}

fn constructStates(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
) BuildError!ConstructedStates {
    var states = std.array_list.Managed(state.ParseState).init(allocator);
    defer states.deinit();
    var action_states = std.array_list.Managed(actions.StateActions).init(allocator);
    defer action_states.deinit();

    const start_items = try closure(allocator, productions, first_sets, &[_]item.ParseItem{item.ParseItem.init(0, 0)});
    try states.append(.{
        .id = 0,
        .items = start_items,
        .transitions = &.{},
        .conflicts = &.{},
    });

    var next_state_index: usize = 0;
    while (next_state_index < states.items.len) : (next_state_index += 1) {
        const transitions = try collectTransitionsForState(allocator, productions, first_sets, &states, states.items[next_state_index].items);
        const mutable_states = states.items;
        mutable_states[next_state_index].transitions = transitions;

        const state_actions = try actions.buildActionsForState(allocator, productions, mutable_states[next_state_index]);
        const detected_conflicts = try conflicts.detectConflictsFromActions(
            allocator,
            mutable_states[next_state_index],
            state_actions,
        );
        mutable_states[next_state_index].conflicts = detected_conflicts;
        try action_states.append(.{
            .state_id = mutable_states[next_state_index].id,
            .entries = state_actions,
        });
    }

    state.sortStates(states.items);
    return .{
        .states = try states.toOwnedSlice(),
        .actions = .{
            .states = try action_states.toOwnedSlice(),
        },
    };
}

fn collectTransitionsForState(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    states: *std.array_list.Managed(state.ParseState),
    state_items: []const item.ParseItem,
) BuildError![]const state.Transition {
    var transitions = std.array_list.Managed(state.Transition).init(allocator);
    defer transitions.deinit();

    for (state_items) |parse_item| {
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) continue;
        const symbol = production.steps[parse_item.step_index].symbol;
        if (containsTransition(transitions.items, symbol)) continue;

        const advanced_items = try gotoItems(allocator, productions, first_sets, state_items, symbol);
        if (findState(states.items, advanced_items)) |existing| {
            try transitions.append(.{ .symbol = symbol, .state = existing.id });
            continue;
        }

        const new_id: state.StateId = @intCast(states.items.len);
        try states.append(.{
            .id = new_id,
            .items = advanced_items,
            .transitions = &.{},
            .conflicts = &.{},
        });
        try transitions.append(.{ .symbol = symbol, .state = new_id });
    }

    state.sortTransitions(transitions.items);
    return try transitions.toOwnedSlice();
}

test "buildStates records LR(0)-style conflicts for an ambiguous expression grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var recursive_expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 1 } },
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var literal_expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{
                .name = "expr",
                .kind = .named,
                .productions = &.{
                    .{ .steps = recursive_expr_steps[0..] },
                    .{ .steps = literal_expr_steps[0..] },
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

    const result = try buildStates(arena.allocator(), grammar);

    var saw_shift_reduce = false;
    var saw_reduce_reduce = false;
    for (result.states) |parse_state| {
        for (parse_state.conflicts) |conflict| {
            switch (conflict.kind) {
                .shift_reduce => saw_shift_reduce = true,
                .reduce_reduce => saw_reduce_reduce = true,
            }
        }
    }

    try std.testing.expect(saw_shift_reduce);
    try std.testing.expect(!saw_reduce_reduce);
    try std.testing.expect(result.actions.entriesForState(0).len > 0);
}

fn closure(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    seed_items: []const item.ParseItem,
) BuildError![]const item.ParseItem {
    var items = std.array_list.Managed(item.ParseItem).init(allocator);
    defer items.deinit();
    try items.appendSlice(seed_items);
    state.sortItems(items.items);

    var changed = true;
    while (changed) {
        changed = false;
        var cursor: usize = 0;
        while (cursor < items.items.len) : (cursor += 1) {
            const parse_item = items.items[cursor];
            const production = productions[parse_item.production_id];
            if (parse_item.step_index >= production.steps.len) continue;
            switch (production.steps[parse_item.step_index].symbol) {
                .non_terminal => |non_terminal| {
                    const suffix = production.steps[parse_item.step_index + 1 ..];
                    const suffix_first = try first_sets.firstOfSequence(allocator, suffix);
                    for (productions, 0..) |candidate, production_index| {
                        if (candidate.augmented) continue;
                        if (candidate.lhs != non_terminal) continue;
                        if (try appendPropagatedItems(
                            allocator,
                            &items,
                            @intCast(production_index),
                            suffix_first,
                            parse_item.lookahead,
                        )) {
                            changed = true;
                        }
                    }
                },
                else => {},
            }
        }
        state.sortItems(items.items);
    }

    return try items.toOwnedSlice();
}

fn gotoItems(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    state_items: []const item.ParseItem,
    symbol: syntax_ir.SymbolRef,
) BuildError![]const item.ParseItem {
    var advanced = std.array_list.Managed(item.ParseItem).init(allocator);
    defer advanced.deinit();

    for (state_items) |parse_item| {
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) continue;
        if (!symbolRefEql(production.steps[parse_item.step_index].symbol, symbol)) continue;
        try advanced.append(.{
            .production_id = parse_item.production_id,
            .step_index = parse_item.step_index + 1,
            .lookahead = parse_item.lookahead,
        });
    }

    return try closure(allocator, productions, first_sets, advanced.items);
}

fn appendPropagatedItems(
    allocator: std.mem.Allocator,
    items: *std.array_list.Managed(item.ParseItem),
    production_id: item.ProductionId,
    propagated_first: first.SymbolSet,
    inherited_lookahead: ?syntax_ir.SymbolRef,
) BuildError!bool {
    _ = allocator;
    var changed = false;

    for (propagated_first.terminals, 0..) |present, index| {
        if (!present) continue;
        const new_item = item.ParseItem.withLookahead(production_id, 0, .{ .terminal = @intCast(index) });
        if (!containsItem(items.items, new_item)) {
            try items.append(new_item);
            changed = true;
        }
    }

    for (propagated_first.externals, 0..) |present, index| {
        if (!present) continue;
        const new_item = item.ParseItem.withLookahead(production_id, 0, .{ .external = @intCast(index) });
        if (!containsItem(items.items, new_item)) {
            try items.append(new_item);
            changed = true;
        }
    }

    if (propagated_first.includes_epsilon) {
        const new_item = if (inherited_lookahead) |lookahead|
            item.ParseItem.withLookahead(production_id, 0, lookahead)
        else
            item.ParseItem.init(production_id, 0);
        if (!containsItem(items.items, new_item)) {
            try items.append(new_item);
            changed = true;
        }
    }

    return changed;
}

fn containsItem(items: []const item.ParseItem, candidate: item.ParseItem) bool {
    for (items) |entry| {
        if (item.ParseItem.eql(entry, candidate)) return true;
    }
    return false;
}

fn containsTransition(transitions: []const state.Transition, symbol: syntax_ir.SymbolRef) bool {
    for (transitions) |entry| {
        if (symbolRefEql(entry.symbol, symbol)) return true;
    }
    return false;
}

fn findState(states: []const state.ParseState, candidate_items: []const item.ParseItem) ?state.ParseState {
    for (states) |parse_state| {
        if (itemsEql(parse_state.items, candidate_items)) return parse_state;
    }
    return null;
}

fn itemsEql(left: []const item.ParseItem, right: []const item.ParseItem) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!item.ParseItem.eql(a, b)) return false;
    }
    return true;
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

test "buildStates constructs deterministic LR(0)-style states for a tiny grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try buildStates(arena.allocator(), grammar);
    try std.testing.expectEqual(@as(usize, 3), result.productions.len);
    try std.testing.expectEqual(@as(usize, 4), result.states.len);
    try std.testing.expectEqual(@as(state.StateId, 0), result.states[0].id);
    try std.testing.expectEqual(@as(usize, 3), result.states[0].items.len);
    try std.testing.expectEqual(@as(usize, 3), result.states[0].transitions.len);
}

test "buildStates propagates terminal lookaheads through nullable suffix closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 1 } },
    };
    var start_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "start", .kind = .named, .productions = &.{.{ .steps = start_steps[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try buildStates(arena.allocator(), grammar);

    var saw_start_with_terminal_lookahead = false;
    var saw_expr_with_terminal_lookahead = false;
    for (result.states[0].items) |parse_item| {
        if (parse_item.production_id == 2 and hasTerminalLookahead(parse_item, 1)) {
            saw_start_with_terminal_lookahead = true;
        }
        if (parse_item.production_id == 3 and hasTerminalLookahead(parse_item, 1)) {
            saw_expr_with_terminal_lookahead = true;
        }
    }

    try std.testing.expect(saw_start_with_terminal_lookahead);
    try std.testing.expect(saw_expr_with_terminal_lookahead);
}

fn hasTerminalLookahead(parse_item: item.ParseItem, terminal_index: u32) bool {
    if (parse_item.lookahead) |lookahead| {
        return switch (lookahead) {
            .terminal => |index| index == terminal_index,
            else => false,
        };
    }
    return false;
}

test "buildStates allows inert step metadata in the current supported subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .terminal = 0 },
            .alias = .{ .value = "token", .named = true },
            .field_name = "lhs",
            .precedence = .{ .integer = 1 },
            .associativity = .left,
            .reserved_context_name = "global",
        },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try buildStates(arena.allocator(), grammar);

    try std.testing.expectEqual(@as(usize, 3), result.states.len);
    try std.testing.expectEqual(@as(state.StateId, 2), result.states[0].transitions[1].state);
}

test "buildStates accepts dynamic precedence metadata in the current supported subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{.{ .steps = source_steps[0..], .dynamic_precedence = 1 }},
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

    const result = try buildStates(arena.allocator(), grammar);
    try std.testing.expect(result.states.len > 0);
}

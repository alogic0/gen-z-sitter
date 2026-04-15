const std = @import("std");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const rules = @import("../ir/rules.zig");

pub const BuildError = error{
    UnsupportedFeature,
    OutOfMemory,
};

pub const ProductionInfo = struct {
    lhs: u32,
    steps: []const syntax_ir.ProductionStep,
    augmented: bool = false,
};

pub const BuildResult = struct {
    productions: []const ProductionInfo,
    states: []const state.ParseState,
};

pub fn buildStates(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
) BuildError!BuildResult {
    try validateSupportedSubset(grammar);

    const productions = try collectProductions(allocator, grammar);
    const states = try constructStates(allocator, productions);
    return .{
        .productions = productions,
        .states = states,
    };
}

fn validateSupportedSubset(grammar: syntax_ir.SyntaxGrammar) BuildError!void {
    for (grammar.variables) |variable| {
        for (variable.productions) |production| {
            if (production.dynamic_precedence != 0) return error.UnsupportedFeature;
            for (production.steps) |step| {
                if (step.alias != null) return error.UnsupportedFeature;
                if (step.field_name != null) return error.UnsupportedFeature;
                if (step.precedence != .none) return error.UnsupportedFeature;
                if (step.associativity != .none) return error.UnsupportedFeature;
                if (step.reserved_context_name != null) return error.UnsupportedFeature;
            }
        }
    }
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
            });
        }
    }

    return try productions.toOwnedSlice();
}

fn constructStates(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
) BuildError![]const state.ParseState {
    var states = std.array_list.Managed(state.ParseState).init(allocator);
    defer states.deinit();

    const start_items = try closure(allocator, productions, &[_]item.ParseItem{item.ParseItem.init(0, 0)});
    try states.append(.{
        .id = 0,
        .items = start_items,
        .transitions = &.{},
    });

    var next_state_index: usize = 0;
    while (next_state_index < states.items.len) : (next_state_index += 1) {
        const transitions = try collectTransitionsForState(allocator, productions, &states, states.items[next_state_index].items);
        const mutable_states = states.items;
        mutable_states[next_state_index].transitions = transitions;
    }

    state.sortStates(states.items);
    return try states.toOwnedSlice();
}

fn collectTransitionsForState(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
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

        const advanced_items = try gotoItems(allocator, productions, state_items, symbol);
        if (findState(states.items, advanced_items)) |existing| {
            try transitions.append(.{ .symbol = symbol, .state = existing.id });
            continue;
        }

        const new_id: state.StateId = @intCast(states.items.len);
        try states.append(.{
            .id = new_id,
            .items = advanced_items,
            .transitions = &.{},
        });
        try transitions.append(.{ .symbol = symbol, .state = new_id });
    }

    state.sortTransitions(transitions.items);
    return try transitions.toOwnedSlice();
}

fn closure(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
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
                    for (productions, 0..) |candidate, production_index| {
                        if (candidate.augmented) continue;
                        if (candidate.lhs != non_terminal) continue;
                        const new_item = item.ParseItem.init(@intCast(production_index), 0);
                        if (!containsItem(items.items, new_item)) {
                            try items.append(new_item);
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

    return try closure(allocator, productions, advanced.items);
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

test "buildStates rejects metadata-heavy syntax not in the current supported subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 }, .field_name = "lhs" },
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

    try std.testing.expectError(error.UnsupportedFeature, buildStates(arena.allocator(), grammar));
}

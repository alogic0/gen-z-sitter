const std = @import("std");
const actions = @import("actions.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const item = @import("item.zig");
const state = @import("state.zig");

pub fn detectConflicts(
    allocator: std.mem.Allocator,
    productions: anytype,
    state_items: []const item.ParseItem,
    transitions: []const state.Transition,
) std.mem.Allocator.Error![]const state.Conflict {
    var completed_items = std.array_list.Managed(item.ParseItem).init(allocator);
    defer completed_items.deinit();

    for (state_items) |parse_item| {
        const production = productions[parse_item.production_id];
        if (parse_item.step_index == production.steps.len) {
            try completed_items.append(parse_item);
        }
    }

    if (completed_items.items.len == 0) return &.{};

    var conflicts = std.array_list.Managed(state.Conflict).init(allocator);
    defer conflicts.deinit();

    if (try collectReduceReduceItems(allocator, completed_items.items, null)) |reduce_reduce_items| {
        try conflicts.append(.{
            .kind = .reduce_reduce,
            .items = reduce_reduce_items,
        });
    }

    for (transitions) |transition| {
        switch (transition.symbol) {
            .terminal, .external => {},
            .non_terminal => continue,
        }

        var conflict_items = std.array_list.Managed(item.ParseItem).init(allocator);
        defer conflict_items.deinit();
        try appendApplicableCompletedItems(&conflict_items, completed_items.items, transition.symbol);

        for (state_items) |parse_item| {
            const production = productions[parse_item.production_id];
            if (parse_item.step_index >= production.steps.len) continue;
            if (!symbolRefEql(production.steps[parse_item.step_index].symbol, transition.symbol)) continue;
            try appendUniqueCoreItem(&conflict_items, parse_item);
        }

        if (conflict_items.items.len < 2) continue;
        const shift_reduce_items = try allocator.dupe(item.ParseItem, conflict_items.items);
        try conflicts.append(.{
            .kind = .shift_reduce,
            .symbol = transition.symbol,
            .items = shift_reduce_items,
        });
    }

    return try conflicts.toOwnedSlice();
}

pub fn detectConflictsFromActions(
    allocator: std.mem.Allocator,
    parse_state: state.ParseState,
    state_actions: []const actions.ActionEntry,
) std.mem.Allocator.Error![]const state.Conflict {
    var conflicts = std.array_list.Managed(state.Conflict).init(allocator);
    defer conflicts.deinit();

    var cursor: usize = 0;
    while (cursor < state_actions.len) {
        const symbol = state_actions[cursor].symbol;
        var next = cursor + 1;
        while (next < state_actions.len and symbolRefEql(state_actions[next].symbol, symbol)) : (next += 1) {}

        const grouped = state_actions[cursor..next];
        if (grouped.len >= 2) {
            const kind = classifyConflict(grouped);
            if (kind) |conflict_kind| {
                const conflict_items = try collectConflictItemsForSymbol(allocator, parse_state.items, symbol);
                try conflicts.append(.{
                    .kind = conflict_kind,
                    .symbol = symbol,
                    .items = conflict_items,
                });
            }
        }

        cursor = next;
    }

    return try conflicts.toOwnedSlice();
}

fn collectReduceReduceItems(
    allocator: std.mem.Allocator,
    completed_items: []const item.ParseItem,
    lookahead: ?syntax_ir.SymbolRef,
) std.mem.Allocator.Error!?[]const item.ParseItem {
    var grouped = std.array_list.Managed(item.ParseItem).init(allocator);
    defer grouped.deinit();

    for (completed_items) |parse_item| {
        if (!itemAppliesToLookahead(parse_item, lookahead)) continue;
        try appendUniqueCoreItem(&grouped, parse_item);
    }

    if (grouped.items.len < 2) return null;
    return try allocator.dupe(item.ParseItem, grouped.items);
}

fn appendApplicableCompletedItems(
    result: *std.array_list.Managed(item.ParseItem),
    completed_items: []const item.ParseItem,
    lookahead: syntax_ir.SymbolRef,
) std.mem.Allocator.Error!void {
    for (completed_items) |parse_item| {
        if (!itemAppliesToLookahead(parse_item, lookahead)) continue;
        try appendUniqueCoreItem(result, parse_item);
    }
}

fn appendUniqueCoreItem(
    result: *std.array_list.Managed(item.ParseItem),
    candidate: item.ParseItem,
) std.mem.Allocator.Error!void {
    for (result.items) |existing| {
        if (existing.production_id == candidate.production_id and existing.step_index == candidate.step_index) {
            return;
        }
    }
    try result.append(candidate);
}

fn itemAppliesToLookahead(parse_item: item.ParseItem, lookahead: ?syntax_ir.SymbolRef) bool {
    if (parse_item.lookahead) |item_lookahead| {
        if (lookahead) |candidate| {
            return symbolRefEql(item_lookahead, candidate);
        }
        return false;
    }
    return true;
}

fn collectConflictItemsForSymbol(
    allocator: std.mem.Allocator,
    state_items: []const item.ParseItem,
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error![]const item.ParseItem {
    var grouped = std.array_list.Managed(item.ParseItem).init(allocator);
    defer grouped.deinit();

    for (state_items) |parse_item| {
        if (!itemAppliesToLookahead(parse_item, symbol)) continue;
        try appendUniqueCoreItem(&grouped, parse_item);
    }

    return try allocator.dupe(item.ParseItem, grouped.items);
}

fn classifyConflict(grouped: []const actions.ActionEntry) ?state.ConflictKind {
    var saw_shift = false;
    var reduce_like_count: usize = 0;

    for (grouped) |entry| {
        switch (entry.action) {
            .shift => saw_shift = true,
            .reduce, .accept => reduce_like_count += 1,
        }
    }

    if (saw_shift and reduce_like_count > 0) return .shift_reduce;
    if (reduce_like_count >= 2) return .reduce_reduce;
    return null;
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

test "detectConflicts reports shift/reduce and reduce/reduce conflicts deterministically" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
    };

    const productions = [_]ProductionInfo{
        .{
            .lhs = 0,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 0 } },
            },
        },
        .{
            .lhs = 0,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 1 } },
            },
        },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 0 } },
            },
        },
    };
    const state_items = [_]item.ParseItem{
        item.ParseItem.init(0, 1),
        item.ParseItem.init(1, 1),
        item.ParseItem.init(2, 0),
    };
    const transitions = [_]state.Transition{
        .{ .symbol = .{ .terminal = 0 }, .state = 1 },
    };

    const conflicts = try detectConflicts(allocator, productions[0..], state_items[0..], transitions[0..]);
    defer {
        for (conflicts) |conflict| allocator.free(conflict.items);
        allocator.free(conflicts);
    }

    try std.testing.expectEqual(@as(usize, 2), conflicts.len);
    try std.testing.expectEqual(state.ConflictKind.reduce_reduce, conflicts[0].kind);
    try std.testing.expectEqual(@as(usize, 2), conflicts[0].items.len);
    try std.testing.expectEqual(state.ConflictKind.shift_reduce, conflicts[1].kind);
    try std.testing.expectEqual(@as(u32, 0), conflicts[1].symbol.?.terminal);
    try std.testing.expectEqual(@as(usize, 3), conflicts[1].items.len);
}

test "detectConflicts does not report duplicate reductions for the same production core" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
    };

    const productions = [_]ProductionInfo{
        .{
            .lhs = 0,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 0 } },
            },
        },
    };
    const state_items = [_]item.ParseItem{
        item.ParseItem.init(0, 1),
        item.ParseItem.withLookahead(0, 1, .{ .terminal = 0 }),
    };

    const conflicts = try detectConflicts(allocator, productions[0..], state_items[0..], &.{});
    defer allocator.free(conflicts);

    try std.testing.expectEqual(@as(usize, 0), conflicts.len);
}

test "detectConflictsFromActions derives shift-reduce conflicts from competing actions" {
    const allocator = std.testing.allocator;

    const parse_state = state.ParseState{
        .id = 2,
        .items = &[_]item.ParseItem{
            item.ParseItem.init(1, 1),
            item.ParseItem.withLookahead(2, 1, .{ .terminal = 0 }),
        },
        .transitions = &.{},
    };
    const state_actions = [_]actions.ActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 2 } },
    };

    const conflicts = try detectConflictsFromActions(allocator, parse_state, state_actions[0..]);
    defer {
        for (conflicts) |conflict| allocator.free(conflict.items);
        allocator.free(conflicts);
    }

    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqual(state.ConflictKind.shift_reduce, conflicts[0].kind);
    try std.testing.expectEqual(@as(u32, 0), conflicts[0].symbol.?.terminal);
    try std.testing.expectEqual(@as(usize, 2), conflicts[0].items.len);
}

test "detectConflictsFromActions derives reduce-reduce conflicts from competing reduces" {
    const allocator = std.testing.allocator;

    const parse_state = state.ParseState{
        .id = 5,
        .items = &[_]item.ParseItem{
            item.ParseItem.withLookahead(2, 1, .{ .terminal = 1 }),
            item.ParseItem.withLookahead(3, 1, .{ .terminal = 1 }),
        },
        .transitions = &.{},
    };
    const state_actions = [_]actions.ActionEntry{
        .{ .symbol = .{ .terminal = 1 }, .action = .{ .reduce = 2 } },
        .{ .symbol = .{ .terminal = 1 }, .action = .{ .reduce = 3 } },
    };

    const conflicts = try detectConflictsFromActions(allocator, parse_state, state_actions[0..]);
    defer {
        for (conflicts) |conflict| allocator.free(conflict.items);
        allocator.free(conflicts);
    }

    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqual(state.ConflictKind.reduce_reduce, conflicts[0].kind);
    try std.testing.expectEqual(@as(u32, 1), conflicts[0].symbol.?.terminal);
    try std.testing.expectEqual(@as(usize, 2), conflicts[0].items.len);
}

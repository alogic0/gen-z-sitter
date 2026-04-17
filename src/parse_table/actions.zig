const std = @import("std");
const item = @import("item.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

fn testLog(name: []const u8) void {
    std.debug.print("[parse_table/actions] {s}\n", .{name});
}

pub const ActionKind = enum {
    shift,
    reduce,
    accept,
};

pub const ParseAction = union(ActionKind) {
    shift: state.StateId,
    reduce: item.ProductionId,
    accept: void,

    pub fn lessThan(_: void, a: ParseAction, b: ParseAction) bool {
        const a_tag = @intFromEnum(a);
        const b_tag = @intFromEnum(b);
        if (a_tag != b_tag) return a_tag < b_tag;

        return switch (a) {
            .shift => |left| switch (b) {
                .shift => |right| left < right,
                else => false,
            },
            .reduce => |left| switch (b) {
                .reduce => |right| left < right,
                else => false,
            },
            .accept => false,
        };
    }
};

pub const ActionEntry = struct {
    symbol: syntax_ir.SymbolRef,
    action: ParseAction,
};

pub const StateActions = struct {
    state_id: state.StateId,
    entries: []const ActionEntry,
};

pub const ActionTable = struct {
    states: []const StateActions,

    pub fn entriesForState(self: ActionTable, state_id: state.StateId) []const ActionEntry {
        for (self.states) |state_actions| {
            if (state_actions.state_id == state_id) return state_actions.entries;
        }
        return &.{};
    }
};

pub const ActionGroup = struct {
    symbol: syntax_ir.SymbolRef,
    entries: []const ActionEntry,
};

pub const GroupedStateActions = struct {
    state_id: state.StateId,
    groups: []const ActionGroup,
};

pub const GroupedActionTable = struct {
    states: []const GroupedStateActions,

    pub fn groupsForState(self: GroupedActionTable, state_id: state.StateId) []const ActionGroup {
        for (self.states) |state_actions| {
            if (state_actions.state_id == state_id) return state_actions.groups;
        }
        return &.{};
    }
};

pub fn buildActionsForState(
    allocator: std.mem.Allocator,
    productions: anytype,
    parse_state: state.ParseState,
) std.mem.Allocator.Error![]const ActionEntry {
    var entries = std.array_list.Managed(ActionEntry).init(allocator);
    defer entries.deinit();

    for (parse_state.transitions) |transition| {
        switch (transition.symbol) {
            .terminal, .external => {
                try appendUniqueAction(&entries, .{
                    .symbol = transition.symbol,
                    .action = .{ .shift = transition.state },
                });
            },
            .non_terminal => {},
        }
    }

    for (parse_state.items) |entry| {
        const parse_item = entry.item;
        const production = productions[parse_item.production_id];
        if (parse_item.step_index != production.steps.len) continue;

        const action: ParseAction = if (production.augmented)
            .{ .accept = {} }
        else
            .{ .reduce = parse_item.production_id };

        for (entry.lookaheads.terminals, 0..) |present, index| {
            if (!present) continue;
            try appendUniqueAction(&entries, .{
                .symbol = .{ .terminal = @intCast(index) },
                .action = action,
            });
        }
        for (entry.lookaheads.externals, 0..) |present, index| {
            if (!present) continue;
            try appendUniqueAction(&entries, .{
                .symbol = .{ .external = @intCast(index) },
                .action = action,
            });
        }
    }

    sortActionEntries(entries.items);
    return try entries.toOwnedSlice();
}

pub fn buildActionTable(
    allocator: std.mem.Allocator,
    productions: anytype,
    parse_states: []const state.ParseState,
) std.mem.Allocator.Error!ActionTable {
    const state_entries = try allocator.alloc(StateActions, parse_states.len);
    for (parse_states, 0..) |parse_state, index| {
        state_entries[index] = .{
            .state_id = parse_state.id,
            .entries = try buildActionsForState(allocator, productions, parse_state),
        };
    }
    return .{ .states = state_entries };
}

pub fn groupActionsForState(
    allocator: std.mem.Allocator,
    state_id: state.StateId,
    entries: []const ActionEntry,
) std.mem.Allocator.Error!GroupedStateActions {
    var groups = std.array_list.Managed(ActionGroup).init(allocator);
    defer groups.deinit();

    var cursor: usize = 0;
    while (cursor < entries.len) {
        const symbol = entries[cursor].symbol;
        var next = cursor + 1;
        while (next < entries.len and symbolRefEql(entries[next].symbol, symbol)) : (next += 1) {}

        try groups.append(.{
            .symbol = symbol,
            .entries = try allocator.dupe(ActionEntry, entries[cursor..next]),
        });
        cursor = next;
    }

    return .{
        .state_id = state_id,
        .groups = try groups.toOwnedSlice(),
    };
}

pub fn groupActionTable(
    allocator: std.mem.Allocator,
    action_table: ActionTable,
) std.mem.Allocator.Error!GroupedActionTable {
    const states = try allocator.alloc(GroupedStateActions, action_table.states.len);
    for (action_table.states, 0..) |state_actions, index| {
        states[index] = try groupActionsForState(allocator, state_actions.state_id, state_actions.entries);
    }
    return .{ .states = states };
}

pub fn sortActionEntries(entries: []ActionEntry) void {
    std.mem.sort(ActionEntry, entries, {}, lessThanActionEntry);
}

fn appendUniqueAction(
    entries: *std.array_list.Managed(ActionEntry),
    candidate: ActionEntry,
) std.mem.Allocator.Error!void {
    for (entries.items) |entry| {
        if (actionEntryEql(entry, candidate)) return;
    }
    try entries.append(candidate);
}

fn lessThanActionEntry(_: void, a: ActionEntry, b: ActionEntry) bool {
    if (!symbolRefEql(a.symbol, b.symbol)) return symbolLessThan(a.symbol, b.symbol);
    return ParseAction.lessThan({}, a.action, b.action);
}

fn actionEntryEql(a: ActionEntry, b: ActionEntry) bool {
    return symbolRefEql(a.symbol, b.symbol) and parseActionEql(a.action, b.action);
}

fn parseActionEql(a: ParseAction, b: ParseAction) bool {
    return switch (a) {
        .shift => |left| switch (b) {
            .shift => |right| left == right,
            else => false,
        },
        .reduce => |left| switch (b) {
            .reduce => |right| left == right,
            else => false,
        },
        .accept => switch (b) {
            .accept => true,
            else => false,
        },
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

fn symbolLessThan(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
        .non_terminal => |index| switch (b) {
            .non_terminal => |other| index < other,
            else => true,
        },
        .terminal => |index| switch (b) {
            .non_terminal => false,
            .terminal => |other| index < other,
            .external => true,
        },
        .external => |index| switch (b) {
            .external => |other| index < other,
            else => false,
        },
    };
}

test "action helpers sort deterministically" {
    testLog("action helpers sort deterministically");
    var entries = [_]ActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 2 } },
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
        .{ .symbol = .{ .external = 1 }, .action = .{ .accept = {} } },
    };

    sortActionEntries(entries[0..]);
    try std.testing.expectEqual(@as(u32, 0), entries[0].symbol.terminal);
    try std.testing.expect(switch (entries[0].action) { .shift => true, else => false });
    try std.testing.expect(switch (entries[1].action) { .reduce => true, else => false });
    try std.testing.expect(switch (entries[2].action) { .accept => true, else => false });
}

test "buildActionsForState derives shift reduce and accept actions" {
    testLog("buildActionsForState derives shift reduce and accept actions");
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
    };

    const productions = [_]ProductionInfo{
        .{
            .lhs = std.math.maxInt(u32),
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .non_terminal = 0 } },
            },
            .augmented = true,
        },
        .{
            .lhs = 0,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 0 } },
            },
        },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 3, item.ParseItem.init(0, 1), .{ .external = 2 }),
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 3, item.ParseItem.init(1, 1), .{ .terminal = 0 }),
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 3, item.ParseItem.init(1, 0), .{ .terminal = 0 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const parse_state = state.ParseState{
        .id = 3,
        .items = parse_items[0..],
        .transitions = &[_]state.Transition{
            .{ .symbol = .{ .terminal = 0 }, .state = 7 },
            .{ .symbol = .{ .non_terminal = 0 }, .state = 8 },
        },
    };

    const entries = try buildActionsForState(allocator, productions[0..], parse_state);
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqual(@as(u32, 0), entries[0].symbol.terminal);
    try std.testing.expect(switch (entries[0].action) { .shift => |id| id == 7, else => false });
    try std.testing.expect(switch (entries[1].action) { .reduce => |id| id == 1, else => false });
    try std.testing.expectEqual(@as(u32, 2), entries[2].symbol.external);
    try std.testing.expect(switch (entries[2].action) { .accept => true, else => false });
}

test "buildActionTable keeps per-state actions addressable by state id" {
    testLog("buildActionTable keeps per-state actions addressable by state id");
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
    };

    const productions = [_]ProductionInfo{
        .{
            .lhs = std.math.maxInt(u32),
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .non_terminal = 0 } },
            },
            .augmented = true,
        },
        .{
            .lhs = 0,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 0 } },
            },
        },
    };

    var state_two_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 2, item.ParseItem.init(1, 1), .{ .terminal = 0 }),
    };
    defer for (state_two_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    var state_seven_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 2, item.ParseItem.init(0, 1), .{ .external = 1 }),
    };
    defer for (state_seven_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const parse_states = [_]state.ParseState{
        .{
            .id = 2,
            .items = state_two_items[0..],
            .transitions = &[_]state.Transition{},
        },
        .{
            .id = 7,
            .items = state_seven_items[0..],
            .transitions = &[_]state.Transition{},
        },
    };

    const table = try buildActionTable(allocator, productions[0..], parse_states[0..]);
    defer {
        for (table.states) |state_actions| allocator.free(state_actions.entries);
        allocator.free(table.states);
    }

    try std.testing.expectEqual(@as(usize, 2), table.states.len);
    try std.testing.expectEqual(@as(usize, 1), table.entriesForState(2).len);
    try std.testing.expectEqual(@as(u32, 0), table.entriesForState(2)[0].symbol.terminal);
    try std.testing.expect(switch (table.entriesForState(2)[0].action) { .reduce => |id| id == 1, else => false });
    try std.testing.expectEqual(@as(usize, 1), table.entriesForState(7).len);
    try std.testing.expect(switch (table.entriesForState(7)[0].action) { .accept => true, else => false });
}

test "groupActionsForState groups sorted actions by symbol deterministically" {
    const allocator = std.testing.allocator;

    const entries = [_]ActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 3 } },
        .{ .symbol = .{ .external = 1 }, .action = .{ .accept = {} } },
    };

    const grouped = try groupActionsForState(allocator, 4, entries[0..]);
    defer {
        for (grouped.groups) |group| allocator.free(group.entries);
        allocator.free(grouped.groups);
    }

    try std.testing.expectEqual(@as(state.StateId, 4), grouped.state_id);
    try std.testing.expectEqual(@as(usize, 2), grouped.groups.len);
    try std.testing.expectEqual(@as(u32, 0), grouped.groups[0].symbol.terminal);
    try std.testing.expectEqual(@as(usize, 2), grouped.groups[0].entries.len);
    try std.testing.expect(switch (grouped.groups[0].entries[0].action) { .shift => true, else => false });
    try std.testing.expect(switch (grouped.groups[0].entries[1].action) { .reduce => true, else => false });
    try std.testing.expectEqual(@as(u32, 1), grouped.groups[1].symbol.external);
}

test "groupActionTable keeps grouped states addressable by state id" {
    const allocator = std.testing.allocator;

    const table = ActionTable{
        .states = &[_]StateActions{
            .{
                .state_id = 2,
                .entries = &[_]ActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 3 } },
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 4 } },
                },
            },
            .{
                .state_id = 7,
                .entries = &[_]ActionEntry{
                    .{ .symbol = .{ .external = 1 }, .action = .{ .accept = {} } },
                },
            },
        },
    };

    const grouped_table = try groupActionTable(allocator, table);
    defer {
        for (grouped_table.states) |grouped_state| {
            for (grouped_state.groups) |group| allocator.free(group.entries);
            allocator.free(grouped_state.groups);
        }
        allocator.free(grouped_table.states);
    }

    try std.testing.expectEqual(@as(usize, 2), grouped_table.states.len);
    try std.testing.expectEqual(@as(usize, 1), grouped_table.groupsForState(2).len);
    try std.testing.expectEqual(@as(u32, 0), grouped_table.groupsForState(2)[0].symbol.terminal);
    try std.testing.expectEqual(@as(usize, 2), grouped_table.groupsForState(2)[0].entries.len);
    try std.testing.expectEqual(@as(usize, 1), grouped_table.groupsForState(7).len);
    try std.testing.expectEqual(@as(u32, 1), grouped_table.groupsForState(7)[0].symbol.external);
}

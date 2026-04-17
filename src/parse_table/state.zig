const std = @import("std");
const item = @import("item.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const StateId = u32;

pub const Transition = struct {
    symbol: syntax_ir.SymbolRef,
    state: StateId,
};

pub const ConflictKind = enum {
    shift_reduce,
    reduce_reduce,
};

pub const Conflict = struct {
    kind: ConflictKind,
    symbol: ?syntax_ir.SymbolRef = null,
    items: []const item.ParseItem,
};

pub const ParseState = struct {
    id: StateId,
    items: []const item.ParseItemSetEntry,
    transitions: []const Transition,
    conflicts: []const Conflict = &.{},

    pub fn lessThan(_: void, a: ParseState, b: ParseState) bool {
        return a.id < b.id;
    }
};

pub fn sortItems(items: []item.ParseItemSetEntry) void {
    std.mem.sort(item.ParseItemSetEntry, items, {}, item.ParseItemSetEntry.lessThan);
}

pub fn sortTransitions(transitions: []Transition) void {
    std.mem.sort(Transition, transitions, {}, lessThanTransition);
}

pub fn sortStates(states: []ParseState) void {
    std.mem.sort(ParseState, states, {}, ParseState.lessThan);
}

fn lessThanTransition(_: void, a: Transition, b: Transition) bool {
    if (!std.meta.eql(a.symbol, b.symbol)) return symbolLessThan(a.symbol, b.symbol);
    return a.state < b.state;
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

test "state helpers sort items and transitions deterministically" {
    var items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(std.testing.allocator, 1, 6, item.ParseItem.init(1, 1), .{ .external = 5 }),
        try item.ParseItemSetEntry.initEmpty(std.testing.allocator, 1, 6, item.ParseItem.init(0, 2)),
        try item.ParseItemSetEntry.initEmpty(std.testing.allocator, 1, 6, item.ParseItem.init(0, 1)),
    };
    defer for (items) |entry| item.freeSymbolSet(std.testing.allocator, entry.lookaheads);
    sortItems(items[0..]);
    try std.testing.expectEqual(@as(item.ProductionId, 0), items[0].item.production_id);
    try std.testing.expectEqual(@as(u16, 1), items[0].item.step_index);
    try std.testing.expectEqual(@as(u16, 2), items[1].item.step_index);

    var transitions = [_]Transition{
        .{ .symbol = .{ .external = 7 }, .state = 3 },
        .{ .symbol = .{ .non_terminal = 2 }, .state = 9 },
        .{ .symbol = .{ .non_terminal = 2 }, .state = 1 },
    };
    sortTransitions(transitions[0..]);
    try std.testing.expectEqual(@as(u32, 2), transitions[0].symbol.non_terminal);
    try std.testing.expectEqual(@as(StateId, 1), transitions[0].state);
    try std.testing.expectEqual(@as(u32, 7), transitions[2].symbol.external);
}

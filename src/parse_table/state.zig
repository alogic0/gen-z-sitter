const std = @import("std");
const item = @import("item.zig");
const symbols = @import("../ir/symbols.zig");

pub const StateId = u32;

pub const Transition = struct {
    symbol: symbols.SymbolId,
    state: StateId,
};

pub const ConflictKind = enum {
    shift_reduce,
    reduce_reduce,
};

pub const Conflict = struct {
    kind: ConflictKind,
    symbol: ?symbols.SymbolId = null,
    items: []const item.ParseItem,
};

pub const ParseState = struct {
    id: StateId,
    items: []const item.ParseItem,
    transitions: []const Transition,
    conflicts: []const Conflict = &.{},

    pub fn lessThan(_: void, a: ParseState, b: ParseState) bool {
        return a.id < b.id;
    }
};

pub fn sortItems(items: []item.ParseItem) void {
    std.mem.sort(item.ParseItem, items, {}, item.ParseItem.lessThan);
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

fn symbolLessThan(a: symbols.SymbolId, b: symbols.SymbolId) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return a.index < b.index;
}

test "state helpers sort items and transitions deterministically" {
    var items = [_]item.ParseItem{
        item.ParseItem.withLookahead(1, 1, symbols.SymbolId.external(5)),
        item.ParseItem.init(0, 2),
        item.ParseItem.init(0, 1),
    };
    sortItems(items[0..]);
    try std.testing.expectEqual(@as(item.ProductionId, 0), items[0].production_id);
    try std.testing.expectEqual(@as(u16, 1), items[0].step_index);
    try std.testing.expectEqual(@as(u16, 2), items[1].step_index);

    var transitions = [_]Transition{
        .{ .symbol = symbols.SymbolId.external(7), .state = 3 },
        .{ .symbol = symbols.SymbolId.nonTerminal(2), .state = 9 },
        .{ .symbol = symbols.SymbolId.nonTerminal(2), .state = 1 },
    };
    sortTransitions(transitions[0..]);
    try std.testing.expectEqual(symbols.SymbolKind.non_terminal, transitions[0].symbol.kind);
    try std.testing.expectEqual(@as(StateId, 1), transitions[0].state);
    try std.testing.expectEqual(symbols.SymbolKind.external, transitions[2].symbol.kind);
}

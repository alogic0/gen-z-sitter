const std = @import("std");
const actions = @import("actions.zig");
const build = @import("build.zig");
const resolution = @import("resolution.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const SerializeError = std.mem.Allocator.Error || error{
    UnresolvedDecisions,
};

pub const SerializeMode = enum {
    strict,
    diagnostic,
};

pub const SerializedActionEntry = struct {
    symbol: syntax_ir.SymbolRef,
    action: actions.ParseAction,
};

pub const SerializedGotoEntry = struct {
    symbol: syntax_ir.SymbolRef,
    state: state.StateId,
};

pub const SerializedUnresolvedEntry = struct {
    symbol: syntax_ir.SymbolRef,
    reason: resolution.UnresolvedReason,
    candidate_actions: []const actions.ParseAction,
};

pub const SerializedState = struct {
    id: state.StateId,
    actions: []const SerializedActionEntry,
    gotos: []const SerializedGotoEntry,
    unresolved: []const SerializedUnresolvedEntry,
};

pub const SerializedAliasEntry = struct {
    production_id: u32,
    step_index: u32,
    name: []const u8,
    named: bool,
};

pub const SerializedProductionInfo = struct {
    lhs: u32,
    child_count: u8,
    dynamic_precedence: i16,
};

pub const SerializedParseActionKind = enum {
    shift,
    reduce,
    accept,
    recover,
};

pub const SerializedParseAction = struct {
    kind: SerializedParseActionKind,
    state: state.StateId = 0,
    extra: bool = false,
    repetition: bool = false,
    child_count: u8 = 0,
    symbol: syntax_ir.SymbolRef = .{ .terminal = 0 },
    dynamic_precedence: i16 = 0,
    production_id: u16 = 0,
};

pub const SerializedParseActionListEntry = struct {
    index: u16,
    reusable: bool,
    actions: []const SerializedParseAction,
};

pub const SerializedSmallParseValueKind = enum {
    state,
    action,
};

pub const SerializedSmallParseGroup = struct {
    kind: SerializedSmallParseValueKind,
    value: u16,
    symbols: []const syntax_ir.SymbolRef,
};

pub const SerializedSmallParseRow = struct {
    offset: u32,
    groups: []const SerializedSmallParseGroup,
};

pub const SerializedSmallParseTable = struct {
    rows: []const SerializedSmallParseRow = &.{},
    map: []const u32 = &.{},
};

pub const SerializedTable = struct {
    states: []const SerializedState,
    blocked: bool,
    large_state_count: usize = 0,
    productions: []const SerializedProductionInfo = &.{},
    parse_action_list: []const SerializedParseActionListEntry = &.{},
    small_parse_table: SerializedSmallParseTable = .{},
    alias_sequences: []const SerializedAliasEntry = &.{},
    word_token: ?syntax_ir.SymbolRef = null,

    pub fn isSerializationReady(self: SerializedTable) bool {
        return !self.blocked;
    }
};

pub fn serializeBuildResult(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    mode: SerializeMode,
) SerializeError!SerializedTable {
    std.debug.print("[parse_table/serialize] serializeBuildResult enter mode={s} states={d}\n", .{ @tagName(mode), result.states.len });
    if (mode == .strict and result.hasBlockingUnresolvedDecisions()) {
        return error.UnresolvedDecisions;
    }

    std.debug.print("[parse_table/serialize] stage decision_snapshot\n", .{});
    const snapshot = try result.decisionSnapshotAlloc(allocator);
    defer {
        allocator.free(snapshot.chosen);
        allocator.free(snapshot.unresolved);
    }
    std.debug.print("[parse_table/serialize] stage allocate_serialized_states len={d}\n", .{result.states.len});
    const serialized_states = try allocator.alloc(SerializedState, result.states.len);

    for (result.states, 0..) |parse_state, index| {
        if (index < 5 or (index + 1) % 500 == 0) {
            std.debug.print("[parse_table/serialize] state {d}/{d} id={d}\n", .{ index + 1, result.states.len, parse_state.id });
        }
        serialized_states[index] = .{
            .id = parse_state.id,
            .actions = try collectActionsForState(allocator, snapshot.chosen, parse_state.id),
            .gotos = try collectGotosForState(allocator, parse_state),
            .unresolved = if (mode == .diagnostic)
                try collectUnresolvedForState(allocator, snapshot.unresolved, parse_state.id)
            else
                &.{},
        };
    }

    var alias_list = std.ArrayListUnmanaged(SerializedAliasEntry).empty;
    const productions = try allocator.alloc(SerializedProductionInfo, result.productions.len);
    for (result.productions, 0..) |production, production_id| {
        productions[production_id] = .{
            .lhs = production.lhs,
            .child_count = @intCast(@min(production.steps.len, std.math.maxInt(u8))),
            .dynamic_precedence = @intCast(std.math.clamp(production.dynamic_precedence, std.math.minInt(i16), std.math.maxInt(i16))),
        };
        for (production.steps, 0..) |step, step_index| {
            if (step.alias) |alias| {
                try alias_list.append(allocator, .{
                    .production_id = @intCast(production_id),
                    .step_index = @intCast(step_index),
                    .name = alias.value,
                    .named = alias.named,
                });
            }
        }
    }

    const blocked = result.hasBlockingUnresolvedDecisions();
    const large_state_count = try computeLargeStateCountAlloc(allocator, serialized_states, productions);
    const parse_action_list = try buildParseActionListAlloc(allocator, serialized_states, productions);
    std.debug.print("[parse_table/serialize] serializeBuildResult done blocked={}\n", .{blocked});
    return .{
        .states = serialized_states,
        .blocked = blocked,
        .large_state_count = large_state_count,
        .productions = productions,
        .parse_action_list = parse_action_list,
        .small_parse_table = try buildSmallParseTableAlloc(allocator, serialized_states, large_state_count, parse_action_list, productions),
        .alias_sequences = try alias_list.toOwnedSlice(allocator),
    };
}

pub fn buildParseActionListAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error![]const SerializedParseActionListEntry {
    var entries = std.array_list.Managed(SerializedParseActionListEntry).init(allocator);
    defer entries.deinit();

    try entries.append(.{
        .index = 0,
        .reusable = false,
        .actions = &.{},
    });

    for (states) |serialized_state| {
        for (serialized_state.actions) |entry| {
            const runtime_action = runtimeActionFromParseAction(entry.action, productions);
            if (parseActionListIndexForRuntimeAction(entries.items, runtime_action) != null) continue;

            const action_slice = try allocator.alloc(SerializedParseAction, 1);
            action_slice[0] = runtime_action;
            try entries.append(.{
                .index = @intCast(entries.items.len * 2 - 1),
                .reusable = true,
                .actions = action_slice,
            });
        }
    }

    return try entries.toOwnedSlice();
}

pub fn deinitParseActionList(
    allocator: std.mem.Allocator,
    entries: []const SerializedParseActionListEntry,
) void {
    for (entries) |entry| {
        if (entry.actions.len > 0) allocator.free(entry.actions);
    }
    allocator.free(entries);
}

pub fn buildSmallParseTableAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    large_state_count: usize,
    parse_action_list: []const SerializedParseActionListEntry,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error!SerializedSmallParseTable {
    if (large_state_count >= states.len) return .{};

    var unique_rows = std.array_list.Managed(SerializedSmallParseRow).init(allocator);
    defer unique_rows.deinit();

    const map = try allocator.alloc(u32, states.len - large_state_count);
    var next_offset: u32 = 0;

    for (states[large_state_count..], 0..) |serialized_state, small_index| {
        const groups = try buildSmallParseGroupsAlloc(allocator, serialized_state, parse_action_list, productions);
        if (findSmallParseRow(unique_rows.items, groups)) |existing_index| {
            map[small_index] = unique_rows.items[existing_index].offset;
            deinitSmallParseGroups(allocator, groups);
            continue;
        }

        map[small_index] = next_offset;
        try unique_rows.append(.{
            .offset = next_offset,
            .groups = groups,
        });
        next_offset += packedSmallParseRowLength(groups);
    }

    return .{
        .rows = try unique_rows.toOwnedSlice(),
        .map = map,
    };
}

pub fn deinitSmallParseTable(allocator: std.mem.Allocator, table: SerializedSmallParseTable) void {
    for (table.rows) |row| {
        deinitSmallParseGroups(allocator, row.groups);
    }
    allocator.free(table.rows);
    allocator.free(table.map);
}

pub fn computeLargeStateCountAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error!usize {
    var symbols = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
    defer symbols.deinit();

    for (states) |serialized_state| {
        for (serialized_state.actions) |entry| {
            try appendUniqueSymbolRef(&symbols, entry.symbol);
            switch (entry.action) {
                .reduce => |production_id| {
                    if (production_id < productions.len) {
                        try appendUniqueSymbolRef(&symbols, .{ .non_terminal = productions[production_id].lhs });
                    }
                },
                .shift, .accept => {},
            }
        }
        for (serialized_state.gotos) |entry| {
            try appendUniqueSymbolRef(&symbols, entry.symbol);
        }
    }

    const threshold = @min(@as(usize, 64), symbols.items.len / 2);
    var count: usize = 0;
    for (states, 0..) |serialized_state, index| {
        if (index <= 1 or serialized_state.actions.len + serialized_state.gotos.len > threshold) {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

fn buildSmallParseGroupsAlloc(
    allocator: std.mem.Allocator,
    serialized_state: SerializedState,
    parse_action_list: []const SerializedParseActionListEntry,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error![]const SerializedSmallParseGroup {
    var groups = std.array_list.Managed(SerializedSmallParseGroup).init(allocator);
    defer groups.deinit();

    for (serialized_state.gotos) |entry| {
        try appendSmallParseSymbol(allocator, &groups, .state, @intCast(entry.state), entry.symbol);
    }
    for (serialized_state.actions) |entry| {
        const action_index = parseActionListIndexForParseAction(parse_action_list, entry.action, productions) orelse 0;
        try appendSmallParseSymbol(allocator, &groups, .action, action_index, entry.symbol);
    }

    for (groups.items) |*group| {
        std.mem.sort(syntax_ir.SymbolRef, @constCast(group.symbols), {}, symbolRefLessThan);
    }
    std.mem.sort(SerializedSmallParseGroup, groups.items, {}, smallParseGroupLessThan);

    return try groups.toOwnedSlice();
}

fn appendSmallParseSymbol(
    allocator: std.mem.Allocator,
    groups: *std.array_list.Managed(SerializedSmallParseGroup),
    kind: SerializedSmallParseValueKind,
    value: u16,
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error!void {
    for (groups.items) |*group| {
        if (group.kind == kind and group.value == value) {
            group.symbols = try appendSymbolToOwnedSlice(allocator, group.symbols, symbol);
            return;
        }
    }

    const symbols = try allocator.alloc(syntax_ir.SymbolRef, 1);
    symbols[0] = symbol;
    try groups.append(.{
        .kind = kind,
        .value = value,
        .symbols = symbols,
    });
}

fn appendSymbolToOwnedSlice(
    allocator: std.mem.Allocator,
    symbols: []const syntax_ir.SymbolRef,
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error![]const syntax_ir.SymbolRef {
    const updated = try allocator.alloc(syntax_ir.SymbolRef, symbols.len + 1);
    @memcpy(updated[0..symbols.len], symbols);
    updated[symbols.len] = symbol;
    allocator.free(symbols);
    return updated;
}

fn findSmallParseRow(rows: []const SerializedSmallParseRow, groups: []const SerializedSmallParseGroup) ?usize {
    for (rows, 0..) |row, index| {
        if (smallParseGroupsEql(row.groups, groups)) return index;
    }
    return null;
}

fn smallParseGroupsEql(left: []const SerializedSmallParseGroup, right: []const SerializedSmallParseGroup) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_group, right_group| {
        if (left_group.kind != right_group.kind or left_group.value != right_group.value) return false;
        if (left_group.symbols.len != right_group.symbols.len) return false;
        for (left_group.symbols, right_group.symbols) |left_symbol, right_symbol| {
            if (!symbolRefEql(left_symbol, right_symbol)) return false;
        }
    }
    return true;
}

fn packedSmallParseRowLength(groups: []const SerializedSmallParseGroup) u32 {
    var len: u32 = 1;
    for (groups) |group| {
        len += 2 + @as(u32, @intCast(group.symbols.len));
    }
    return len;
}

fn deinitSmallParseGroups(allocator: std.mem.Allocator, groups: []const SerializedSmallParseGroup) void {
    for (groups) |group| {
        allocator.free(group.symbols);
    }
    allocator.free(groups);
}

fn smallParseGroupLessThan(_: void, left: SerializedSmallParseGroup, right: SerializedSmallParseGroup) bool {
    if (left.symbols.len != right.symbols.len) return left.symbols.len < right.symbols.len;
    if (left.kind != right.kind) return @intFromEnum(left.kind) < @intFromEnum(right.kind);
    if (left.value != right.value) return left.value < right.value;
    if (left.symbols.len == 0 or right.symbols.len == 0) return left.symbols.len < right.symbols.len;
    return symbolRefLessThan({}, left.symbols[0], right.symbols[0]);
}

pub fn parseActionListIndexForParseAction(
    entries: []const SerializedParseActionListEntry,
    action: actions.ParseAction,
    productions: []const SerializedProductionInfo,
) ?u16 {
    return parseActionListIndexForRuntimeAction(entries, runtimeActionFromParseAction(action, productions));
}

pub fn runtimeActionFromParseAction(
    action: actions.ParseAction,
    productions: []const SerializedProductionInfo,
) SerializedParseAction {
    return switch (action) {
        .shift => |state_id| .{
            .kind = .shift,
            .state = state_id,
        },
        .reduce => |production_id| blk: {
            const production = if (production_id < productions.len)
                productions[production_id]
            else
                SerializedProductionInfo{ .lhs = 0, .child_count = 0, .dynamic_precedence = 0 };
            break :blk .{
                .kind = .reduce,
                .child_count = production.child_count,
                .symbol = .{ .non_terminal = production.lhs },
                .dynamic_precedence = production.dynamic_precedence,
                .production_id = @intCast(@min(production_id, std.math.maxInt(u16))),
            };
        },
        .accept => .{
            .kind = .accept,
        },
    };
}

fn parseActionListIndexForRuntimeAction(
    entries: []const SerializedParseActionListEntry,
    action: SerializedParseAction,
) ?u16 {
    for (entries) |entry| {
        if (entry.actions.len != 1) continue;
        if (serializedParseActionEql(entry.actions[0], action)) return entry.index;
    }
    return null;
}

fn serializedParseActionEql(left: SerializedParseAction, right: SerializedParseAction) bool {
    if (left.kind != right.kind) return false;
    return switch (left.kind) {
        .shift => left.state == right.state and
            left.extra == right.extra and
            left.repetition == right.repetition,
        .reduce => left.child_count == right.child_count and
            symbolRefEql(left.symbol, right.symbol) and
            left.dynamic_precedence == right.dynamic_precedence and
            left.production_id == right.production_id,
        .accept, .recover => true,
    };
}

fn appendUniqueSymbolRef(
    symbols: *std.array_list.Managed(syntax_ir.SymbolRef),
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error!void {
    for (symbols.items) |existing| {
        if (symbolRefEql(existing, symbol)) return;
    }
    try symbols.append(symbol);
}

fn symbolRefLessThan(_: void, left: syntax_ir.SymbolRef, right: syntax_ir.SymbolRef) bool {
    return symbolSortKey(left) < symbolSortKey(right);
}

fn symbolSortKey(symbol: syntax_ir.SymbolRef) u64 {
    return switch (symbol) {
        .non_terminal => |index| (@as(u64, 0) << 32) | index,
        .terminal => |index| (@as(u64, 1) << 32) | index,
        .external => |index| (@as(u64, 2) << 32) | index,
    };
}

fn collectActionsForState(
    allocator: std.mem.Allocator,
    chosen: []const resolution.ChosenDecisionRef,
    state_id: state.StateId,
) std.mem.Allocator.Error![]const SerializedActionEntry {
    var count: usize = 0;
    for (chosen) |entry| {
        if (entry.state_id == state_id) count += 1;
    }

    const entries = try allocator.alloc(SerializedActionEntry, count);
    var index: usize = 0;
    for (chosen) |entry| {
        if (entry.state_id != state_id) continue;
        entries[index] = .{
            .symbol = entry.symbol,
            .action = entry.action,
        };
        index += 1;
    }
    return entries;
}

fn collectGotosForState(
    allocator: std.mem.Allocator,
    parse_state: state.ParseState,
) std.mem.Allocator.Error![]const SerializedGotoEntry {
    var count: usize = 0;
    for (parse_state.transitions) |transition| {
        switch (transition.symbol) {
            .non_terminal => count += 1,
            .terminal, .external => {},
        }
    }

    const entries = try allocator.alloc(SerializedGotoEntry, count);
    var index: usize = 0;
    for (parse_state.transitions) |transition| {
        switch (transition.symbol) {
            .non_terminal => {
                entries[index] = .{
                    .symbol = transition.symbol,
                    .state = transition.state,
                };
                index += 1;
            },
            .terminal, .external => {},
        }
    }
    return entries;
}

fn collectUnresolvedForState(
    allocator: std.mem.Allocator,
    unresolved: []const resolution.UnresolvedDecisionRef,
    state_id: state.StateId,
) std.mem.Allocator.Error![]const SerializedUnresolvedEntry {
    var count: usize = 0;
    for (unresolved) |entry| {
        if (entry.state_id == state_id) count += 1;
    }

    const entries = try allocator.alloc(SerializedUnresolvedEntry, count);
    var index: usize = 0;
    for (unresolved) |entry| {
        if (entry.state_id != state_id) continue;
        entries[index] = .{
            .symbol = entry.symbol,
            .reason = entry.reason,
            .candidate_actions = entry.candidate_actions,
        };
        index += 1;
    }
    return entries;
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

test "serializeBuildResult rejects blocked snapshots in strict mode" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 2,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 9 },
            },
            .conflicts = &.{},
        },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{
                            .{ .shift = 4 },
                            .{ .reduce = 2 },
                        },
                        .decision = .{ .unresolved = .shift_reduce },
                    },
                },
            },
        },
    };

    const result = build.BuildResult{
        .productions = &.{},
        .precedence_orderings = &.{},
        .states = parse_states[0..],
        .lex_state_count = 1,
        .actions = .{ .states = &.{} },
        .resolved_actions = resolved_actions,
    };

    try std.testing.expectError(
        error.UnresolvedDecisions,
        serializeBuildResult(allocator, result, .strict),
    );
}

test "serializeBuildResult keeps blocked snapshots in diagnostic mode" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 2,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 9 },
            },
            .conflicts = &.{},
        },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{
                            .{ .shift = 4 },
                            .{ .reduce = 2 },
                        },
                        .decision = .{ .unresolved = .shift_reduce },
                    },
                },
            },
        },
    };

    const result = build.BuildResult{
        .productions = &.{},
        .precedence_orderings = &.{},
        .states = parse_states[0..],
        .lex_state_count = 1,
        .actions = .{ .states = &.{} },
        .resolved_actions = resolved_actions,
    };

    const serialized = try serializeBuildResult(allocator, result, .diagnostic);
    defer allocator.free(serialized.states);
    defer deinitSmallParseTable(allocator, serialized.small_parse_table);
    defer deinitParseActionList(allocator, serialized.parse_action_list);
    defer allocator.free(serialized.states[0].unresolved);
    defer allocator.free(serialized.states[0].gotos);
    defer allocator.free(serialized.states[0].actions);

    try std.testing.expect(!serialized.isSerializationReady());
    try std.testing.expectEqual(@as(usize, 1), serialized.states.len);
    try std.testing.expectEqual(@as(usize, 0), serialized.states[0].actions.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.states[0].gotos.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.states[0].unresolved.len);
    try std.testing.expectEqual(resolution.UnresolvedReason.shift_reduce, serialized.states[0].unresolved[0].reason);
}

test "buildParseActionListAlloc deduplicates runtime actions" {
    const allocator = std.testing.allocator;
    const productions = [_]SerializedProductionInfo{
        .{ .lhs = 2, .child_count = 3, .dynamic_precedence = 4 },
    };
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 7 } },
                .{ .symbol = .{ .terminal = 2 }, .action = .{ .reduce = 0 } },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
    };

    const list = try buildParseActionListAlloc(allocator, states[0..], productions[0..]);
    defer deinitParseActionList(allocator, list);

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(u16, 0), list[0].index);
    try std.testing.expectEqual(@as(u16, 1), list[1].index);
    try std.testing.expectEqual(@as(u16, 3), list[2].index);
    try std.testing.expectEqual(@as(u16, 1), parseActionListIndexForParseAction(list, .{ .shift = 7 }, productions[0..]).?);
    try std.testing.expectEqual(@as(u16, 3), parseActionListIndexForParseAction(list, .{ .reduce = 0 }, productions[0..]).?);
    try std.testing.expectEqual(SerializedParseActionKind.reduce, list[2].actions[0].kind);
    try std.testing.expectEqual(@as(u8, 3), list[2].actions[0].child_count);
    try std.testing.expectEqual(@as(i16, 4), list[2].actions[0].dynamic_precedence);
    try std.testing.expectEqual(@as(u32, 2), list[2].actions[0].symbol.non_terminal);
}

test "computeLargeStateCountAlloc follows tree-sitter threshold prefix rule" {
    const allocator = std.testing.allocator;
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 1,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 2,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 3,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
    };

    try std.testing.expectEqual(
        @as(usize, 2),
        try computeLargeStateCountAlloc(allocator, states[0..], &.{}),
    );
}

test "buildSmallParseTableAlloc groups values and deduplicates rows" {
    const allocator = std.testing.allocator;
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 1,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 2,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 9 } },
                .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 9 } },
            },
            .gotos = &[_]SerializedGotoEntry{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 4 },
            },
            .unresolved = &.{},
        },
        .{
            .id = 3,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 9 } },
                .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 9 } },
            },
            .gotos = &[_]SerializedGotoEntry{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 4 },
            },
            .unresolved = &.{},
        },
    };
    const actions_list = try buildParseActionListAlloc(allocator, states[0..], &.{});
    defer deinitParseActionList(allocator, actions_list);

    const table = try buildSmallParseTableAlloc(allocator, states[0..], 2, actions_list, &.{});
    defer deinitSmallParseTable(allocator, table);

    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqual(@as(usize, 2), table.map.len);
    try std.testing.expectEqual(@as(u32, 0), table.map[0]);
    try std.testing.expectEqual(@as(u32, 0), table.map[1]);
    try std.testing.expectEqual(@as(usize, 2), table.rows[0].groups.len);
    try std.testing.expectEqual(SerializedSmallParseValueKind.state, table.rows[0].groups[0].kind);
    try std.testing.expectEqual(@as(u16, 4), table.rows[0].groups[0].value);
    try std.testing.expectEqual(@as(usize, 1), table.rows[0].groups[0].symbols.len);
    try std.testing.expectEqual(SerializedSmallParseValueKind.action, table.rows[0].groups[1].kind);
    try std.testing.expectEqual(@as(usize, 2), table.rows[0].groups[1].symbols.len);
}

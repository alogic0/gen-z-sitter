const std = @import("std");
const lexer_serialize = @import("../lexer/serialize.zig");
const parse_actions = @import("../parse_table/actions.zig");
const parse_state = @import("../parse_table/state.zig");
const serialize = @import("../parse_table/serialize.zig");
const syntax_grammar = @import("../ir/syntax_grammar.zig");

pub const Options = struct {
    compact_duplicate_states: bool = true,
    glr_loop: bool = false,
};

pub fn prepareSerializedTableAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
    options: Options,
) serialize.ParseActionListError!serialize.SerializedTable {
    if (!options.compact_duplicate_states) return serialized;
    return try compactSerializedTableAlloc(allocator, serialized);
}

pub fn compactSerializedTableAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) serialize.ParseActionListError!serialize.SerializedTable {
    for (serialized.states, 0..) |serialized_state, index| {
        std.debug.assert(serialized_state.id == index);
    }

    const state_owners = try collectStateOwners(allocator, serialized.states, serialized.lex_modes);
    defer allocator.free(state_owners);
    const owner_new_ids = try allocator.alloc(parse_state.StateId, serialized.states.len);
    defer allocator.free(owner_new_ids);
    var unique_count: usize = 0;

    for (serialized.states, 0..) |_, index| {
        owner_new_ids[index] = std.math.maxInt(parse_state.StateId);
        if (state_owners[index] == index) {
            owner_new_ids[index] = @intCast(unique_count);
            unique_count += 1;
        }
    }

    const compacted_states = try allocator.alloc(serialize.SerializedState, unique_count);
    var compacted_index: usize = 0;
    for (serialized.states, 0..) |serialized_state, index| {
        if (state_owners[index] != index) continue;
        compacted_states[compacted_index] = .{
            .id = @intCast(compacted_index),
            .core_id = serialized_state.core_id,
            .lex_state_id = serialized_state.lex_state_id,
            .actions = try remapActionEntries(allocator, serialized.states, serialized_state.actions, state_owners, owner_new_ids),
            .gotos = try remapGotoEntries(allocator, serialized.states, serialized_state.gotos, state_owners, owner_new_ids),
            .unresolved = try remapUnresolvedEntries(allocator, serialized.states, serialized_state.unresolved, state_owners, owner_new_ids),
        };
        compacted_index += 1;
    }

    const large_state_count = try serialize.computeLargeStateCountAlloc(allocator, compacted_states, serialized.productions);
    const parse_action_list = try serialize.buildRuntimeParseActionListAlloc(allocator, compacted_states, serialized.productions);
    const lex_modes = try lexer_serialize.buildLexModesAlloc(allocator, compacted_states);
    compactLexModeExternalStates(@constCast(lex_modes), serialized.lex_modes, serialized.states, state_owners);
    const primary_state_ids = try serialize.buildPrimaryStateIdsAlloc(allocator, compacted_states);

    return .{
        .states = compacted_states,
        .blocked = serialized.blocked,
        .grammar_name = serialized.grammar_name,
        .grammar_version = serialized.grammar_version,
        .symbols = serialized.symbols,
        .large_state_count = large_state_count,
        .production_id_count = serialized.production_id_count,
        .productions = serialized.productions,
        .parse_action_list = parse_action_list,
        .small_parse_table = try serialize.buildSmallParseTableAlloc(allocator, compacted_states, large_state_count, parse_action_list, serialized.productions),
        .alias_sequences = serialized.alias_sequences,
        .non_terminal_aliases = serialized.non_terminal_aliases,
        .field_map = serialized.field_map,
        .supertype_map = serialized.supertype_map,
        .lex_modes = lex_modes,
        .lex_state_terminal_sets = serialized.lex_state_terminal_sets,
        .lex_tables = serialized.lex_tables,
        .keyword_lex_table = serialized.keyword_lex_table,
        .primary_state_ids = primary_state_ids,
        .word_token = serialized.word_token,
        .reserved_words = serialized.reserved_words,
        .external_scanner = serialized.external_scanner,
    };
}

fn compactLexModeExternalStates(
    compacted_lex_modes: []lexer_serialize.SerializedLexMode,
    original_lex_modes: []const lexer_serialize.SerializedLexMode,
    original_states: []const serialize.SerializedState,
    state_owners: []const usize,
) void {
    var compacted_index: usize = 0;
    for (original_states, 0..) |_, index| {
        if (state_owners[index] != index) continue;
        if (index < original_lex_modes.len and compacted_index < compacted_lex_modes.len) {
            compacted_lex_modes[compacted_index].lex_state = original_lex_modes[index].lex_state;
            compacted_lex_modes[compacted_index].external_lex_state = original_lex_modes[index].external_lex_state;
            compacted_lex_modes[compacted_index].reserved_word_set_id = original_lex_modes[index].reserved_word_set_id;
        }
        compacted_index += 1;
    }
}

fn collectStateOwners(
    allocator: std.mem.Allocator,
    states: []const serialize.SerializedState,
    lex_modes: []const lexer_serialize.SerializedLexMode,
) std.mem.Allocator.Error![]usize {
    const owners = try allocator.alloc(usize, states.len);
    for (states, 0..) |state_value, index| {
        owners[index] = index;
        for (states[0..index], 0..) |previous_state, previous_index| {
            if (serializedStatesEql(
                state_value,
                previous_state,
                lexModeForState(states, lex_modes, index),
                lexModeForState(states, lex_modes, previous_index),
            )) {
                owners[index] = previous_index;
                break;
            }
        }
    }
    return owners;
}

fn lexModeForState(
    states: []const serialize.SerializedState,
    lex_modes: []const lexer_serialize.SerializedLexMode,
    index: usize,
) lexer_serialize.SerializedLexMode {
    if (index < lex_modes.len) return lex_modes[index];
    return .{ .lex_state = @intCast(states[index].lex_state_id) };
}

fn serializedStatesEql(
    left: serialize.SerializedState,
    right: serialize.SerializedState,
    left_lex_mode: lexer_serialize.SerializedLexMode,
    right_lex_mode: lexer_serialize.SerializedLexMode,
) bool {
    return std.meta.eql(left_lex_mode, right_lex_mode) and
        actionEntrySlicesEql(left.actions, right.actions) and
        gotoEntrySlicesEql(left.gotos, right.gotos) and
        unresolvedEntrySlicesEql(left.unresolved, right.unresolved);
}

fn remapActionEntries(
    allocator: std.mem.Allocator,
    states: []const serialize.SerializedState,
    entries: []const serialize.SerializedActionEntry,
    state_owners: []const usize,
    owner_new_ids: []const parse_state.StateId,
) std.mem.Allocator.Error![]const serialize.SerializedActionEntry {
    const remapped = try allocator.alloc(serialize.SerializedActionEntry, entries.len);
    for (entries, 0..) |entry, index| {
        const candidate_actions = try allocator.alloc(parse_actions.ParseAction, entry.candidate_actions.len);
        for (entry.candidate_actions, 0..) |candidate_action, candidate_index| {
            candidate_actions[candidate_index] = remapParseAction(states, candidate_action, state_owners, owner_new_ids);
        }
        remapped[index] = .{
            .symbol = entry.symbol,
            .action = remapParseAction(states, entry.action, state_owners, owner_new_ids),
            .candidate_actions = candidate_actions,
            .extra = entry.extra,
            .repetition = entry.repetition,
        };
    }
    return remapped;
}

fn remapGotoEntries(
    allocator: std.mem.Allocator,
    states: []const serialize.SerializedState,
    entries: []const serialize.SerializedGotoEntry,
    state_owners: []const usize,
    owner_new_ids: []const parse_state.StateId,
) std.mem.Allocator.Error![]const serialize.SerializedGotoEntry {
    const remapped = try allocator.alloc(serialize.SerializedGotoEntry, entries.len);
    for (entries, 0..) |entry, index| {
        remapped[index] = .{
            .symbol = entry.symbol,
            .state = remapStateId(states, entry.state, state_owners, owner_new_ids),
        };
    }
    return remapped;
}

fn remapUnresolvedEntries(
    allocator: std.mem.Allocator,
    states: []const serialize.SerializedState,
    entries: []const serialize.SerializedUnresolvedEntry,
    state_owners: []const usize,
    owner_new_ids: []const parse_state.StateId,
) std.mem.Allocator.Error![]const serialize.SerializedUnresolvedEntry {
    const remapped = try allocator.alloc(serialize.SerializedUnresolvedEntry, entries.len);
    for (entries, 0..) |entry, index| {
        const candidate_actions = try allocator.alloc(parse_actions.ParseAction, entry.candidate_actions.len);
        for (entry.candidate_actions, 0..) |candidate_action, candidate_index| {
            candidate_actions[candidate_index] = remapParseAction(states, candidate_action, state_owners, owner_new_ids);
        }
        remapped[index] = .{
            .symbol = entry.symbol,
            .reason = entry.reason,
            .candidate_actions = candidate_actions,
        };
    }
    return remapped;
}

fn remapParseAction(
    states: []const serialize.SerializedState,
    action: parse_actions.ParseAction,
    state_owners: []const usize,
    owner_new_ids: []const parse_state.StateId,
) parse_actions.ParseAction {
    return switch (action) {
        .shift => |state_id| .{ .shift = remapStateId(states, state_id, state_owners, owner_new_ids) },
        .reduce => |production_id| .{ .reduce = production_id },
        .accept => .{ .accept = {} },
    };
}

fn remapStateId(
    states: []const serialize.SerializedState,
    state_id: parse_state.StateId,
    state_owners: []const usize,
    owner_new_ids: []const parse_state.StateId,
) parse_state.StateId {
    if (findStateIndexById(states, state_id)) |state_index| {
        const owner = state_owners[state_index];
        return owner_new_ids[owner];
    }
    return state_id;
}

fn findStateIndexById(states: []const serialize.SerializedState, state_id: parse_state.StateId) ?usize {
    for (states, 0..) |state_value, index| {
        if (state_value.id == state_id) return index;
    }
    return null;
}

fn actionEntrySlicesEql(left: []const serialize.SerializedActionEntry, right: []const serialize.SerializedActionEntry) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (!symbolRefEql(left_entry.symbol, right_entry.symbol)) return false;
        if (!parseActionEql(left_entry.action, right_entry.action)) return false;
        if (!parseActionSliceEql(left_entry.candidate_actions, right_entry.candidate_actions)) return false;
        if (left_entry.extra != right_entry.extra) return false;
        if (left_entry.repetition != right_entry.repetition) return false;
    }
    return true;
}

fn gotoEntrySlicesEql(left: []const serialize.SerializedGotoEntry, right: []const serialize.SerializedGotoEntry) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (!symbolRefEql(left_entry.symbol, right_entry.symbol)) return false;
        if (left_entry.state != right_entry.state) return false;
    }
    return true;
}

fn unresolvedEntrySlicesEql(left: []const serialize.SerializedUnresolvedEntry, right: []const serialize.SerializedUnresolvedEntry) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (!symbolRefEql(left_entry.symbol, right_entry.symbol)) return false;
        if (left_entry.reason != right_entry.reason) return false;
        if (!parseActionSliceEql(left_entry.candidate_actions, right_entry.candidate_actions)) return false;
    }
    return true;
}

fn parseActionSliceEql(left: []const parse_actions.ParseAction, right: []const parse_actions.ParseAction) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (!parseActionEql(left_entry, right_entry)) return false;
    }
    return true;
}

fn parseActionEql(left: parse_actions.ParseAction, right: parse_actions.ParseAction) bool {
    return switch (left) {
        .shift => |left_value| switch (right) {
            .shift => |right_value| left_value == right_value,
            else => false,
        },
        .reduce => |left_value| switch (right) {
            .reduce => |right_value| left_value == right_value,
            else => false,
        },
        .accept => switch (right) {
            .accept => true,
            else => false,
        },
    };
}

fn symbolRefEql(a: syntax_grammar.SymbolRef, b: syntax_grammar.SymbolRef) bool {
    return switch (a) {
        .end => switch (b) {
            .end => true,
            else => false,
        },
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

test "compactSerializedTableAlloc keeps states with different external lex states distinct" {
    const allocator = std.testing.allocator;

    const compacted = try compactSerializedTableAlloc(allocator, .{
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
            .{ .id = 1, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
        .blocked = false,
        .lex_modes = &[_]lexer_serialize.SerializedLexMode{
            .{ .lex_state = 0, .external_lex_state = 0 },
            .{ .lex_state = 0, .external_lex_state = 1 },
        },
    });
    defer allocator.free(compacted.states);
    defer allocator.free(compacted.parse_action_list);
    defer serialize.deinitSmallParseTable(allocator, compacted.small_parse_table);
    defer allocator.free(compacted.lex_modes);
    defer allocator.free(compacted.primary_state_ids);

    try std.testing.expectEqual(@as(usize, 2), compacted.states.len);
    try std.testing.expectEqual(@as(u16, 0), compacted.lex_modes[0].external_lex_state);
    try std.testing.expectEqual(@as(u16, 1), compacted.lex_modes[1].external_lex_state);
}

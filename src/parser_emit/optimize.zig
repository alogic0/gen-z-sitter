const std = @import("std");
const parse_actions = @import("../parse_table/actions.zig");
const parse_state = @import("../parse_table/state.zig");
const serialize = @import("../parse_table/serialize.zig");
const syntax_grammar = @import("../ir/syntax_grammar.zig");
const resolution = @import("../parse_table/resolution.zig");

pub fn compactSerializedTableAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) std.mem.Allocator.Error!serialize.SerializedTable {
    for (serialized.states, 0..) |serialized_state, index| {
        std.debug.assert(serialized_state.id == index);
    }

    const state_owners = try collectStateOwners(allocator, serialized.states);
    const owner_new_ids = try allocator.alloc(parse_state.StateId, serialized.states.len);
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
            .actions = try remapActionEntries(allocator, serialized.states, serialized_state.actions, state_owners, owner_new_ids),
            .gotos = try remapGotoEntries(allocator, serialized.states, serialized_state.gotos, state_owners, owner_new_ids),
            .unresolved = try remapUnresolvedEntries(allocator, serialized.states, serialized_state.unresolved, state_owners, owner_new_ids),
        };
        compacted_index += 1;
    }

    return .{
        .states = compacted_states,
        .blocked = serialized.blocked,
    };
}

fn collectStateOwners(
    allocator: std.mem.Allocator,
    states: []const serialize.SerializedState,
) std.mem.Allocator.Error![]usize {
    const owners = try allocator.alloc(usize, states.len);
    for (states, 0..) |state_value, index| {
        owners[index] = index;
        for (states[0..index], 0..) |previous_state, previous_index| {
            if (serializedStatesEql(state_value, previous_state)) {
                owners[index] = previous_index;
                break;
            }
        }
    }
    return owners;
}

fn serializedStatesEql(left: serialize.SerializedState, right: serialize.SerializedState) bool {
    return actionEntrySlicesEql(left.actions, right.actions) and
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
        remapped[index] = .{
            .symbol = entry.symbol,
            .action = remapParseAction(states, entry.action, state_owners, owner_new_ids),
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

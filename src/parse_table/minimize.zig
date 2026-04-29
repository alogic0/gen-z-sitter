const std = @import("std");
const item = @import("item.zig");
const resolution = @import("resolution.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const MinimizeResult = struct {
    states: []state.ParseState,
    resolved_actions: resolution.ResolvedActionTable,
    merged_count: usize,

    pub fn deinit(self: MinimizeResult, allocator: std.mem.Allocator) void {
        for (self.states) |parse_state| allocator.free(parse_state.transitions);
        allocator.free(self.states);
        for (self.resolved_actions.states) |resolved_state| {
            for (resolved_state.groups) |group| {
                if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
            }
            if (resolved_state.groups.len != 0) allocator.free(resolved_state.groups);
        }
        allocator.free(self.resolved_actions.states);
    }
};

pub const TerminalConflictMap = struct {
    terminal_count: usize,
    conflicts: []const bool,
    keyword_tokens: []const bool = &.{},

    pub fn conflictsWith(self: TerminalConflictMap, left: usize, right: usize) bool {
        if (left >= self.terminal_count or right >= self.terminal_count) return true;
        return self.conflicts[left * self.terminal_count + right];
    }

    pub fn isKeyword(self: TerminalConflictMap, token: usize) bool {
        return token < self.keyword_tokens.len and self.keyword_tokens[token];
    }
};

pub fn minimizeAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
) std.mem.Allocator.Error!MinimizeResult {
    const n = states_in.len;
    if (n == 0) {
        return .{
            .states = try allocator.alloc(state.ParseState, 0),
            .resolved_actions = .{ .states = try allocator.alloc(resolution.ResolvedStateActions, 0) },
            .merged_count = 0,
        };
    }

    var max_id: state.StateId = 0;
    var max_core_id: u32 = 0;
    for (states_in) |s| if (s.id > max_id) {
        max_id = s.id;
    };
    for (states_in) |s| if (s.core_id > max_core_id) {
        max_core_id = s.core_id;
    };

    const id_to_idx = try allocator.alloc(usize, max_id + 1);
    defer allocator.free(id_to_idx);
    @memset(id_to_idx, std.math.maxInt(usize));
    for (states_in, 0..) |s, idx| id_to_idx[s.id] = idx;

    var groups = std.array_list.Managed([]usize).init(allocator);
    defer {
        for (groups.items) |group| allocator.free(group);
        groups.deinit();
    }
    const grouped_by_core = try allocator.alloc(std.array_list.Managed(usize), max_core_id + 1);
    defer {
        for (grouped_by_core) |*group| group.deinit();
        allocator.free(grouped_by_core);
    }
    for (grouped_by_core) |*group| group.* = std.array_list.Managed(usize).init(allocator);
    for (states_in, 0..) |s, idx| {
        try grouped_by_core[s.core_id].append(idx);
    }
    for (grouped_by_core) |group| {
        if (group.items.len == 0) continue;
        try groups.append(try allocator.dupe(usize, group.items));
    }

    const group_of = try allocator.alloc(u32, max_id + 1);
    defer allocator.free(group_of);
    refreshGroupIds(states_in, groups.items, group_of);

    _ = try splitConflictGroups(
        allocator,
        states_in,
        resolved_in,
        terminal_conflicts,
        word_token,
        &groups,
        group_of,
    );
    refreshGroupIds(states_in, groups.items, group_of);
    while (try splitSuccessorGroups(
        allocator,
        states_in,
        resolved_in,
        &groups,
        group_of,
    )) {
        refreshGroupIds(states_in, groups.items, group_of);
    }

    if (groups.items.len > 1) {
        for (groups.items, 0..) |group, index| {
            for (group) |state_index| {
                if (states_in[state_index].id == 0 and index != 0) {
                    std.mem.swap([]usize, &groups.items[0], &groups.items[index]);
                    break;
                }
            } else continue;
            break;
        }
        refreshGroupIds(states_in, groups.items, group_of);
    }

    const id_remap = try allocator.alloc(state.StateId, max_id + 1);
    defer allocator.free(id_remap);
    @memset(id_remap, std.math.maxInt(state.StateId));
    for (groups.items, 0..) |group, new_id| {
        for (group) |state_index| {
            id_remap[states_in[state_index].id] = @intCast(new_id);
        }
    }

    const out_states = try allocator.alloc(state.ParseState, groups.items.len);
    for (groups.items, 0..) |group, new_id| {
        const base = states_in[group[0]];
        var transitions = std.array_list.Managed(state.Transition).init(allocator);
        for (group) |state_index| {
            for (states_in[state_index].transitions) |transition| {
                try appendMergedTransition(&transitions, .{
                    .symbol = transition.symbol,
                    .state = id_remap[transition.state],
                    .extra = transition.extra,
                });
            }
        }

        out_states[new_id] = .{
            .id = @intCast(new_id),
            .core_id = base.core_id,
            .lex_state_id = base.lex_state_id,
            .reserved_word_set_id = base.reserved_word_set_id,
            .items = base.items,
            .transitions = try transitions.toOwnedSlice(),
            .conflicts = base.conflicts,
            .auxiliary_symbols = base.auxiliary_symbols,
        };
    }

    const out_resolved = try allocator.alloc(resolution.ResolvedStateActions, groups.items.len);
    for (groups.items, 0..) |group, new_id| {
        var action_groups = std.array_list.Managed(resolution.ResolvedActionGroup).init(allocator);
        for (group) |state_index| {
            const old_state_id = states_in[state_index].id;
            for (resolved_in.groupsForState(old_state_id)) |action_group| {
                if (findResolvedGroup(action_groups.items, action_group.symbol) != null) continue;
                try action_groups.append(try remapResolvedActionGroup(allocator, action_group, id_remap));
            }
        }

        out_resolved[new_id] = .{
            .state_id = @intCast(new_id),
            .groups = try action_groups.toOwnedSlice(),
        };
    }

    return .{
        .states = out_states,
        .resolved_actions = .{ .states = out_resolved },
        .merged_count = n - groups.items.len,
    };
}

fn refreshGroupIds(
    states_in: []const state.ParseState,
    groups: []const []const usize,
    group_of: []u32,
) void {
    @memset(group_of, std.math.maxInt(u32));
    for (groups, 0..) |group, group_index| {
        for (group) |state_index| {
            group_of[states_in[state_index].id] = @intCast(group_index);
        }
    }
}

fn splitConflictGroups(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved: resolution.ResolvedActionTable,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
    groups: *std.array_list.Managed([]usize),
    group_of: []const u32,
) std.mem.Allocator.Error!bool {
    var new_groups = std.array_list.Managed([]usize).init(allocator);
    errdefer {
        for (new_groups.items) |group| allocator.free(group);
        new_groups.deinit();
    }

    var changed = false;
    for (groups.items) |group| {
        if (group.len <= 1) {
            try new_groups.append(try allocator.dupe(usize, group));
            continue;
        }

        var partitions = std.array_list.Managed(std.array_list.Managed(usize)).init(allocator);
        defer {
            for (partitions.items) |*partition| partition.deinit();
            partitions.deinit();
        }

        for (group) |state_index| {
            var placed = false;
            for (partitions.items) |*partition| {
                var conflicts = false;
                for (partition.items) |other_index| {
                    if (statesConflict(
                        states_in[state_index],
                        states_in[other_index],
                        resolved,
                        terminal_conflicts,
                        word_token,
                        group_of,
                    )) {
                        conflicts = true;
                        break;
                    }
                }
                if (!conflicts) {
                    try partition.append(state_index);
                    placed = true;
                    break;
                }
            }
            if (!placed) {
                var partition = std.array_list.Managed(usize).init(allocator);
                try partition.append(state_index);
                try partitions.append(partition);
            }
        }

        if (partitions.items.len > 1) changed = true;
        for (partitions.items) |partition| {
            try new_groups.append(try allocator.dupe(usize, partition.items));
        }
    }

    for (groups.items) |group| allocator.free(group);
    groups.clearRetainingCapacity();
    try groups.appendSlice(new_groups.items);
    new_groups.clearRetainingCapacity();
    new_groups.deinit();
    return changed;
}

fn splitSuccessorGroups(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved: resolution.ResolvedActionTable,
    groups: *std.array_list.Managed([]usize),
    group_of: []const u32,
) std.mem.Allocator.Error!bool {
    var new_groups = std.array_list.Managed([]usize).init(allocator);
    errdefer {
        for (new_groups.items) |group| allocator.free(group);
        new_groups.deinit();
    }

    var changed = false;
    for (groups.items) |group| {
        if (group.len <= 1) {
            try new_groups.append(try allocator.dupe(usize, group));
            continue;
        }

        var partitions = std.array_list.Managed(std.array_list.Managed(usize)).init(allocator);
        defer {
            for (partitions.items) |*partition| partition.deinit();
            partitions.deinit();
        }

        for (group) |state_index| {
            var placed = false;
            for (partitions.items) |*partition| {
                var differs = false;
                for (partition.items) |other_index| {
                    if (successorsDiffer(
                        states_in[state_index],
                        states_in[other_index],
                        resolved,
                        group_of,
                    )) {
                        differs = true;
                        break;
                    }
                }
                if (!differs) {
                    try partition.append(state_index);
                    placed = true;
                    break;
                }
            }
            if (!placed) {
                var partition = std.array_list.Managed(usize).init(allocator);
                try partition.append(state_index);
                try partitions.append(partition);
            }
        }

        if (partitions.items.len > 1) changed = true;
        for (partitions.items) |partition| {
            try new_groups.append(try allocator.dupe(usize, partition.items));
        }
    }

    for (groups.items) |group| allocator.free(group);
    groups.clearRetainingCapacity();
    try groups.appendSlice(new_groups.items);
    new_groups.clearRetainingCapacity();
    new_groups.deinit();
    return changed;
}

fn statesConflict(
    left: state.ParseState,
    right: state.ParseState,
    resolved: resolution.ResolvedActionTable,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
    group_of: []const u32,
) bool {
    const left_groups = resolved.groupsForState(left.id);
    const right_groups = resolved.groupsForState(right.id);
    for (left_groups) |left_group| {
        if (left_group.symbol == .non_terminal) continue;
        if (findResolvedGroup(right_groups, left_group.symbol)) |right_group| {
            if (entriesConflict(left_group, right_group, group_of)) return true;
        } else if (tokenConflicts(left_group.symbol, right, right_groups, terminal_conflicts, word_token)) {
            return true;
        }
    }
    for (right_groups) |right_group| {
        if (right_group.symbol == .non_terminal) continue;
        if (findResolvedGroup(left_groups, right_group.symbol) != null) continue;
        if (tokenConflicts(right_group.symbol, left, left_groups, terminal_conflicts, word_token)) return true;
    }
    return false;
}

fn tokenConflicts(
    new_token: syntax_ir.SymbolRef,
    other_state: state.ParseState,
    other_groups: []const resolution.ResolvedActionGroup,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
) bool {
    _ = other_state;
    switch (new_token) {
        .end => return false,
        .external => return true,
        .non_terminal => return false,
        .terminal => |left| {
            const conflict_map = terminal_conflicts orelse return false;
            for (other_groups) |group| {
                switch (group.symbol) {
                    .terminal => |right| {
                        const left_is_word = symbolRefEql(.{ .terminal = left }, word_token orelse .end);
                        const right_is_word = symbolRefEql(.{ .terminal = right }, word_token orelse .end);
                        if ((left_is_word and conflict_map.isKeyword(right)) or
                            (right_is_word and conflict_map.isKeyword(left)))
                        {
                            continue;
                        }
                        if (conflict_map.conflictsWith(left, right)) return true;
                    },
                    .external => return true,
                    else => {},
                }
            }
            return false;
        },
    }
}

fn entriesConflict(
    left: resolution.ResolvedActionGroup,
    right: resolution.ResolvedActionGroup,
    group_of: []const u32,
) bool {
    if (!actionListsEquivalent(left.candidate_actions, right.candidate_actions, group_of)) return true;
    return !decisionsEquivalent(left.decision, right.decision, group_of);
}

fn successorsDiffer(
    left: state.ParseState,
    right: state.ParseState,
    resolved: resolution.ResolvedActionTable,
    group_of: []const u32,
) bool {
    const left_groups = resolved.groupsForState(left.id);
    const right_groups = resolved.groupsForState(right.id);
    for (left_groups) |left_group| {
        const left_target = chosenShiftTarget(left_group) orelse continue;
        const right_group = findResolvedGroup(right_groups, left_group.symbol) orelse continue;
        const right_target = chosenShiftTarget(right_group) orelse continue;
        if (groupOfState(group_of, left_target) != groupOfState(group_of, right_target)) return true;
    }

    for (left.transitions) |left_transition| {
        if (left_transition.symbol != .non_terminal) continue;
        const right_transition = findTransition(right.transitions, left_transition.symbol) orelse continue;
        if (left_transition.extra != right_transition.extra) return true;
        if (groupOfState(group_of, left_transition.state) != groupOfState(group_of, right_transition.state)) return true;
    }
    return false;
}

fn decisionsEquivalent(
    left: resolution.ResolvedDecision,
    right: resolution.ResolvedDecision,
    group_of: []const u32,
) bool {
    return switch (left) {
        .chosen => |left_action| switch (right) {
            .chosen => |right_action| actionsEquivalent(left_action, right_action, group_of),
            .unresolved => false,
        },
        .unresolved => |left_reason| switch (right) {
            .chosen => false,
            .unresolved => |right_reason| left_reason == right_reason,
        },
    };
}

fn actionsEquivalent(
    left: @import("actions.zig").ParseAction,
    right: @import("actions.zig").ParseAction,
    group_of: []const u32,
) bool {
    return switch (left) {
        .shift => |left_state| switch (right) {
            .shift => |right_state| groupOfState(group_of, left_state) == groupOfState(group_of, right_state),
            else => false,
        },
        .reduce => |left_production| switch (right) {
            .reduce => |right_production| left_production == right_production,
            else => false,
        },
        .accept => switch (right) {
            .accept => true,
            else => false,
        },
    };
}

fn actionListsEquivalent(
    left: []const @import("actions.zig").ParseAction,
    right: []const @import("actions.zig").ParseAction,
    group_of: []const u32,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_action, right_action| {
        if (!actionsEquivalent(left_action, right_action, group_of)) return false;
    }
    return true;
}

fn groupOfState(group_of: []const u32, state_id: state.StateId) u32 {
    if (state_id >= group_of.len) return std.math.maxInt(u32);
    return group_of[state_id];
}

fn chosenShiftTarget(group: resolution.ResolvedActionGroup) ?state.StateId {
    return switch (group.decision) {
        .chosen => |action| switch (action) {
            .shift => |target| target,
            else => null,
        },
        .unresolved => null,
    };
}

fn findResolvedGroup(
    groups: []const resolution.ResolvedActionGroup,
    symbol: syntax_ir.SymbolRef,
) ?resolution.ResolvedActionGroup {
    for (groups) |group| {
        if (symbolRefEql(group.symbol, symbol)) return group;
    }
    return null;
}

fn findTransition(
    transitions: []const state.Transition,
    symbol: syntax_ir.SymbolRef,
) ?state.Transition {
    for (transitions) |transition| {
        if (symbolRefEql(transition.symbol, symbol)) return transition;
    }
    return null;
}

fn appendMergedTransition(
    transitions: *std.array_list.Managed(state.Transition),
    new_transition: state.Transition,
) !void {
    for (transitions.items) |existing| {
        if (symbolRefEql(existing.symbol, new_transition.symbol) and existing.extra == new_transition.extra) return;
    }
    try transitions.append(new_transition);
}

fn remapResolvedActionGroup(
    allocator: std.mem.Allocator,
    group: resolution.ResolvedActionGroup,
    id_remap: []const state.StateId,
) !resolution.ResolvedActionGroup {
    return .{
        .symbol = group.symbol,
        .candidate_actions = try remapActionsAlloc(allocator, group.candidate_actions, id_remap),
        .decision = switch (group.decision) {
            .chosen => |action| .{ .chosen = remapAction(action, id_remap) },
            .unresolved => group.decision,
        },
    };
}

fn remapActionsAlloc(
    allocator: std.mem.Allocator,
    source: []const @import("actions.zig").ParseAction,
    id_remap: []const state.StateId,
) ![]const @import("actions.zig").ParseAction {
    if (source.len == 0) return &.{};
    const result = try allocator.alloc(@import("actions.zig").ParseAction, source.len);
    for (source, 0..) |action, index| {
        result[index] = remapAction(action, id_remap);
    }
    return result;
}

fn remapAction(
    action: @import("actions.zig").ParseAction,
    id_remap: []const state.StateId,
) @import("actions.zig").ParseAction {
    return switch (action) {
        .shift => |target| .{ .shift = if (target < id_remap.len) id_remap[target] else target },
        else => action,
    };
}

fn symbolRefEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
        .end => b == .end,
        .terminal => |left| switch (b) {
            .terminal => |right| left == right,
            else => false,
        },
        .external => |left| switch (b) {
            .external => |right| left == right,
            else => false,
        },
        .non_terminal => |left| switch (b) {
            .non_terminal => |right| left == right,
            else => false,
        },
    };
}

fn buildSig(
    alloc: std.mem.Allocator,
    s: state.ParseState,
    resolved: resolution.ResolvedActionTable,
    class_of: []const u32,
    id_to_idx: []const usize,
) std.mem.Allocator.Error![]const u8 {
    const Entry = struct {
        sym_tag: u8,
        sym_idx: u32,
        kind: u8,
        value: u32,
    };

    var entries = std.array_list.Managed(Entry).init(alloc);
    try entries.append(.{
        .sym_tag = 253,
        .sym_idx = s.lex_state_id,
        .kind = 255,
        .value = s.lex_state_id,
    });
    try entries.append(.{
        .sym_tag = 255,
        .sym_idx = s.reserved_word_set_id,
        .kind = 255,
        .value = s.reserved_word_set_id,
    });

    for (resolved.groupsForState(s.id)) |group| {
        const sym_tag: u8 = switch (group.symbol) {
            .end => 0,
            .terminal => 1,
            .external => 2,
            .non_terminal => continue,
        };
        const sym_idx: u32 = switch (group.symbol) {
            .end => 0,
            .terminal => |idx| idx,
            .external => |idx| idx,
            .non_terminal => |idx| idx,
        };
        const kind: u8 = switch (group.decision) {
            .chosen => |action| switch (action) {
                .shift => 0,
                .reduce => 1,
                .accept => 2,
            },
            .unresolved => 3,
        };
        const value: u32 = switch (group.decision) {
            .chosen => |action| switch (action) {
                .shift => |target| class_of[id_to_idx[target]],
                .reduce => |prod| prod,
                .accept => 0,
            },
            .unresolved => |reason| @intFromEnum(reason),
        };
        try entries.append(.{ .sym_tag = sym_tag, .sym_idx = sym_idx, .kind = kind, .value = value });
    }

    for (s.transitions) |t| {
        switch (t.symbol) {
            .non_terminal => |idx| {
                try entries.append(.{
                    .sym_tag = 0,
                    .sym_idx = idx,
                    .kind = if (t.extra) 5 else 4,
                    .value = class_of[id_to_idx[t.state]],
                });
            },
            .terminal => |idx| if (t.extra) {
                try entries.append(.{
                    .sym_tag = 1,
                    .sym_idx = idx,
                    .kind = 5,
                    .value = class_of[id_to_idx[t.state]],
                });
            },
            .external => |idx| if (t.extra) {
                try entries.append(.{
                    .sym_tag = 2,
                    .sym_idx = idx,
                    .kind = 5,
                    .value = class_of[id_to_idx[t.state]],
                });
            },
            else => {},
        }
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.sym_tag != b.sym_tag) return a.sym_tag < b.sym_tag;
            if (a.sym_idx != b.sym_idx) return a.sym_idx < b.sym_idx;
            if (a.kind != b.kind) return a.kind < b.kind;
            return a.value < b.value;
        }
    }.lt);

    const bytes = try alloc.alloc(u8, entries.items.len * 10);
    var pos: usize = 0;
    for (entries.items) |e| {
        bytes[pos] = e.sym_tag;
        pos += 1;
        std.mem.writeInt(u32, bytes[pos..][0..4], e.sym_idx, .little);
        pos += 4;
        bytes[pos] = e.kind;
        pos += 1;
        std.mem.writeInt(u32, bytes[pos..][0..4], e.value, .little);
        pos += 4;
    }
    return bytes;
}

test "minimizeAlloc returns empty result for empty input" {
    const result = try minimizeAlloc(
        std.testing.allocator,
        &.{},
        .{ .states = &.{} },
        null,
        null,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc merges two identical states" {
    // States: 0 has two non-terminal gotos (to 1 and 2); 3 is an accept state.
    // States 1 and 2 both shift terminal:0 to state 3 and reduce terminal:1 to prod:1.
    // After minimization, states 1 and 2 should merge into state 1 (lower id).
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 0,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 1 },
                .{ .symbol = .{ .non_terminal = 1 }, .state = 2 },
                .{ .symbol = .{ .terminal = 0 }, .state = 3 },
            },
        },
        .{
            .id = 1,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .terminal = 0 }, .state = 3 },
            },
        },
        .{
            .id = 2,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .terminal = 0 }, .state = 3 },
            },
        },
        .{
            .id = 3,
            .items = &.{},
            .transitions = &.{},
        },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .shift = 3 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .shift = 3 } },
                    },
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 1 } },
                    },
                },
            },
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .shift = 3 } },
                    },
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 1 } },
                    },
                },
            },
            .{
                .state_id = 3,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .accept = {} } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 2), result.merged_count);

    // State 0's non-terminal goto to former state 2 should now point to canonical state 1
    var found_state_0 = false;
    for (result.states) |s| {
        if (s.id != 0) continue;
        found_state_0 = true;
        try std.testing.expectEqual(@as(usize, 3), s.transitions.len);
        for (s.transitions) |t| {
            switch (t.symbol) {
                .non_terminal => |idx| {
                    _ = idx;
                    try std.testing.expect(t.state < result.states.len);
                },
                .end => {},
                .terminal => {},
                .external => {},
            }
        }
    }
    try std.testing.expect(found_state_0);

    // State 2 should not be present in the output
    for (result.states) |s| {
        try std.testing.expect(s.id != 2);
    }
}

test "minimizeAlloc keeps distinct states separate" {
    const allocator = std.testing.allocator;

    // Two states with different actions should not be merged
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 1 } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc keeps states with different item cores separate" {
    const allocator = std.testing.allocator;

    var left_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, item.ParseItem.init(0, 1)),
    };
    defer for (left_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    var right_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, item.ParseItem.init(1, 1)),
    };
    defer for (right_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = left_items[0..], .transitions = &.{} },
        .{ .id = 1, .core_id = 1, .items = right_items[0..], .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc merges states before lex mode assignment" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .lex_state_id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .lex_state_id = 2, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
    try std.testing.expectEqual(@as(state.LexStateId, 1), result.states[0].lex_state_id);
}

test "minimizeAlloc merges compatible reserved-word states" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 0,
            .reserved_word_set_id = 1,
            .items = &.{},
            .transitions = &.{},
        },
        .{
            .id = 1,
            .reserved_word_set_id = 2,
            .items = &.{},
            .transitions = &.{},
        },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
    try std.testing.expectEqual(@as(u16, 1), result.states[0].reserved_word_set_id);
}

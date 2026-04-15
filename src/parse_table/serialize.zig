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

pub const SerializedTable = struct {
    states: []const SerializedState,
    blocked: bool,

    pub fn isSerializationReady(self: SerializedTable) bool {
        return !self.blocked;
    }
};

pub fn serializeBuildResult(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    mode: SerializeMode,
) SerializeError!SerializedTable {
    if (mode == .strict and result.hasUnresolvedDecisions()) {
        return error.UnresolvedDecisions;
    }

    const snapshot = try result.decisionSnapshotAlloc(allocator);
    defer {
        allocator.free(snapshot.chosen);
        allocator.free(snapshot.unresolved);
    }
    const serialized_states = try allocator.alloc(SerializedState, result.states.len);

    for (result.states, 0..) |parse_state, index| {
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

    return .{
        .states = serialized_states,
        .blocked = snapshot.unresolved.len > 0,
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
        .actions = .{ .states = &.{} },
        .resolved_actions = resolved_actions,
    };

    const serialized = try serializeBuildResult(allocator, result, .diagnostic);
    defer allocator.free(serialized.states);
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

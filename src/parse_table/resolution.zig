const std = @import("std");
const actions = @import("actions.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

fn testLog(name: []const u8) void {
    std.debug.print("[parse_table/resolution] {s}\n", .{name});
}

pub const UnresolvedReason = enum {
    multiple_candidates,
    shift_reduce,
    reduce_reduce_deferred,
    unsupported_action_mix,
};

pub const ResolvedDecision = union(enum) {
    chosen: actions.ParseAction,
    unresolved: UnresolvedReason,
};

pub const UnresolvedDecisionRef = struct {
    state_id: state.StateId,
    symbol: syntax_ir.SymbolRef,
    reason: UnresolvedReason,
    candidate_actions: []const actions.ParseAction,
};

pub const ChosenDecisionRef = struct {
    state_id: state.StateId,
    symbol: syntax_ir.SymbolRef,
    action: actions.ParseAction,
    candidate_actions: []const actions.ParseAction,
};

pub const DecisionSnapshot = struct {
    chosen: []const ChosenDecisionRef,
    unresolved: []const UnresolvedDecisionRef,

    pub fn isSerializationReady(self: DecisionSnapshot) bool {
        return self.unresolved.len == 0;
    }
};

pub const ResolvedActionGroup = struct {
    symbol: @import("../ir/syntax_grammar.zig").SymbolRef,
    candidate_actions: []const actions.ParseAction,
    decision: ResolvedDecision,

    pub fn chosenAction(self: ResolvedActionGroup) ?actions.ParseAction {
        return switch (self.decision) {
            .chosen => |action| action,
            .unresolved => null,
        };
    }

    pub fn unresolvedReason(self: ResolvedActionGroup) ?UnresolvedReason {
        return switch (self.decision) {
            .chosen => null,
            .unresolved => |reason| reason,
        };
    }
};

pub const ResolvedStateActions = struct {
    state_id: state.StateId,
    groups: []const ResolvedActionGroup,

    pub fn groupForSymbol(
        self: ResolvedStateActions,
        symbol: syntax_ir.SymbolRef,
    ) ?ResolvedActionGroup {
        for (self.groups) |group| {
            if (symbolRefEql(group.symbol, symbol)) return group;
        }
        return null;
    }

    pub fn hasUnresolvedDecisions(self: ResolvedStateActions) bool {
        for (self.groups) |group| {
            switch (group.decision) {
                .chosen => {},
                .unresolved => return true,
            }
        }
        return false;
    }
};

pub const ResolvedActionTable = struct {
    states: []const ResolvedStateActions,

    pub fn groupsForState(self: ResolvedActionTable, state_id: state.StateId) []const ResolvedActionGroup {
        for (self.states) |resolved| {
            if (resolved.state_id == state_id) return resolved.groups;
        }
        return &.{};
    }

    pub fn decisionFor(
        self: ResolvedActionTable,
        state_id: state.StateId,
        symbol: syntax_ir.SymbolRef,
    ) ?ResolvedDecision {
        for (self.states) |resolved| {
            if (resolved.state_id != state_id) continue;
            if (resolved.groupForSymbol(symbol)) |group| return group.decision;
            return null;
        }
        return null;
    }

    pub fn candidateActionsFor(
        self: ResolvedActionTable,
        state_id: state.StateId,
        symbol: syntax_ir.SymbolRef,
    ) []const actions.ParseAction {
        for (self.states) |resolved| {
            if (resolved.state_id != state_id) continue;
            if (resolved.groupForSymbol(symbol)) |group| return group.candidate_actions;
            return &.{};
        }
        return &.{};
    }

    pub fn hasUnresolvedDecisions(self: ResolvedActionTable) bool {
        for (self.states) |resolved| {
            if (resolved.hasUnresolvedDecisions()) return true;
        }
        return false;
    }

    pub fn isSerializationReady(self: ResolvedActionTable) bool {
        return !self.hasUnresolvedDecisions();
    }

    pub fn countUnresolvedDecisions(self: ResolvedActionTable) usize {
        var count: usize = 0;
        for (self.states) |resolved| {
            for (resolved.groups) |group| {
                switch (group.decision) {
                    .chosen => {},
                    .unresolved => count += 1,
                }
            }
        }
        return count;
    }

    pub fn unresolvedDecisionsAlloc(
        self: ResolvedActionTable,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const UnresolvedDecisionRef {
        const refs = try allocator.alloc(UnresolvedDecisionRef, self.countUnresolvedDecisions());
        var index: usize = 0;
        for (self.states) |resolved| {
            for (resolved.groups) |group| {
                switch (group.decision) {
                    .chosen => {},
                    .unresolved => |reason| {
                        refs[index] = .{
                            .state_id = resolved.state_id,
                            .symbol = group.symbol,
                            .reason = reason,
                            .candidate_actions = group.candidate_actions,
                        };
                        index += 1;
                    },
                }
            }
        }
        return refs;
    }

    pub fn countChosenDecisions(self: ResolvedActionTable) usize {
        var count: usize = 0;
        for (self.states) |resolved| {
            for (resolved.groups) |group| {
                switch (group.decision) {
                    .chosen => count += 1,
                    .unresolved => {},
                }
            }
        }
        return count;
    }

    pub fn chosenDecisionsAlloc(
        self: ResolvedActionTable,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const ChosenDecisionRef {
        const refs = try allocator.alloc(ChosenDecisionRef, self.countChosenDecisions());
        var index: usize = 0;
        for (self.states) |resolved| {
            for (resolved.groups) |group| {
                switch (group.decision) {
                    .chosen => |action| {
                        refs[index] = .{
                            .state_id = resolved.state_id,
                            .symbol = group.symbol,
                            .action = action,
                            .candidate_actions = group.candidate_actions,
                        };
                        index += 1;
                    },
                    .unresolved => {},
                }
            }
        }
        return refs;
    }

    pub fn snapshotAlloc(
        self: ResolvedActionTable,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!DecisionSnapshot {
        return .{
            .chosen = try self.chosenDecisionsAlloc(allocator),
            .unresolved = try self.unresolvedDecisionsAlloc(allocator),
        };
    }
};

const ProductionResolutionMetadata = struct {
    max_integer_precedence: ?i32 = null,
    named_precedence: ?[]const u8 = null,
    associativity: ?@import("../ir/rules.zig").Assoc = null,
    dynamic_precedence: i32 = 0,
};

pub fn resolveActionTableSkeleton(
    allocator: std.mem.Allocator,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    return try resolveActionTable(allocator, &.{}, grouped_table);
}

pub fn resolveActionTable(
    allocator: std.mem.Allocator,
    productions: anytype,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    return try resolveActionTableWithContext(allocator, productions, &.{}, &.{}, grouped_table);
}

pub fn resolveActionTableWithPrecedence(
    allocator: std.mem.Allocator,
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    return try resolveActionTableWithContext(allocator, productions, precedence_orderings, &.{}, grouped_table);
}

pub fn resolveActionTableWithContext(
    allocator: std.mem.Allocator,
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    parse_states: []const state.ParseState,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    const states = try allocator.alloc(ResolvedStateActions, grouped_table.states.len);
    for (grouped_table.states, 0..) |grouped_state, state_index| {
        const groups = try allocator.alloc(ResolvedActionGroup, grouped_state.groups.len);
        const parse_state = findState(parse_states, grouped_state.state_id);
        for (grouped_state.groups, 0..) |group, group_index| {
            const decision = chooseResolvedAction(productions, precedence_orderings, parse_state, group.entries);
            groups[group_index] = .{
                .symbol = group.symbol,
                .candidate_actions = try dupActions(allocator, group.entries),
                .decision = if (decision.chosen) |chosen|
                    .{ .chosen = chosen }
                else
                    .{ .unresolved = decision.reason orelse .unsupported_action_mix },
            };
        }
        states[state_index] = .{
            .state_id = grouped_state.state_id,
            .groups = groups,
        };
    }
    return .{ .states = states };
}

fn dupActions(
    allocator: std.mem.Allocator,
    entries: []const actions.ActionEntry,
) std.mem.Allocator.Error![]const actions.ParseAction {
    const duplicated = try allocator.alloc(actions.ParseAction, entries.len);
    for (entries, 0..) |entry, index| {
        duplicated[index] = entry.action;
    }
    return duplicated;
}

const ResolutionDecision = struct {
    chosen: ?actions.ParseAction = null,
    reason: ?UnresolvedReason = null,
};

fn chooseResolvedAction(
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    parse_state: ?state.ParseState,
    candidates: []const actions.ActionEntry,
) ResolutionDecision {
    if (candidates.len == 1) return .{ .chosen = candidates[0].action };

    if (candidates.len == 2) {
        const first = candidates[0].action;
        const second = candidates[1].action;

        if (isShift(first) and isReduce(second)) {
            return .{
                .chosen = resolveShiftReduce(productions, precedence_orderings, parse_state, candidates[0].symbol, first, second),
                .reason = .shift_reduce,
            };
        }
        if (isReduce(first) and isShift(second)) {
            return .{
                .chosen = resolveShiftReduce(productions, precedence_orderings, parse_state, candidates[0].symbol, second, first),
                .reason = .shift_reduce,
            };
        }
        if (isReduce(first) and isReduce(second)) {
            return .{
                .chosen = null,
                .reason = .reduce_reduce_deferred,
            };
        }
    }

    return .{
        .chosen = null,
        .reason = if (candidates.len > 1) .multiple_candidates else .unsupported_action_mix,
    };
}

fn resolveShiftReduce(
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    parse_state: ?state.ParseState,
    shift_symbol: syntax_ir.SymbolRef,
    shift_action: actions.ParseAction,
    reduce_action: actions.ParseAction,
) ?actions.ParseAction {
    const production_id = switch (reduce_action) {
        .reduce => |id| id,
        else => return null,
    };

    if (production_id >= productions.len) return null;
    const production = productions[production_id];
    const metadata = extractResolutionMetadata(production);
    const shift_metadata = if (parse_state) |resolved_state|
        extractShiftResolutionMetadata(productions, resolved_state, shift_symbol)
    else
        null;

    if (metadata.dynamic_precedence > 0) return reduce_action;
    if (metadata.dynamic_precedence < 0) return shift_action;

    if (shift_metadata) |shift| {
        if (metadata.max_integer_precedence) |reduce_value| {
            if (shift.max_integer_precedence) |shift_value| {
                if (reduce_value > shift_value) return reduce_action;
                if (reduce_value < shift_value) return shift_action;
            }
        }

        if (metadata.named_precedence) |reduce_name| {
            if (shift.named_precedence) |shift_name| {
                if (comparePrecedenceEntries(
                    precedence_orderings,
                    .{ .name = reduce_name },
                    .{ .name = shift_name },
                )) |reduce_wins| {
                    return if (reduce_wins) reduce_action else shift_action;
                }
            }
        }
    }

    if (metadata.named_precedence) |name| {
        if (comparePrecedenceEntries(
            precedence_orderings,
            .{ .name = name },
            .{ .symbol = shift_symbol },
        )) |reduce_wins| {
            return if (reduce_wins) reduce_action else shift_action;
        }
    }

    if (metadata.max_integer_precedence) |value| {
        if (value > 0) return reduce_action;
        if (value < 0) return shift_action;
        if (value == 0) {
            if (metadata.associativity) |assoc| switch (assoc) {
                .left => return reduce_action,
                .right => return shift_action,
                .none => {},
            };
        }
    }

    if (productionIsRepeatAuxiliary(production)) return shift_action;

    return null;
}

fn productionIsRepeatAuxiliary(production: anytype) bool {
    if (!@hasField(@TypeOf(production), "lhs_is_repeat_auxiliary")) return false;
    return production.lhs_is_repeat_auxiliary;
}

fn extractResolutionMetadata(production: anytype) ProductionResolutionMetadata {
    var metadata = ProductionResolutionMetadata{
        .dynamic_precedence = production.dynamic_precedence,
    };
    for (production.steps) |step| {
        switch (step.precedence) {
            .integer => |value| {
                if (metadata.max_integer_precedence == null or value > metadata.max_integer_precedence.?) {
                    metadata.max_integer_precedence = value;
                }
            },
            .name => |value| {
                if (metadata.named_precedence == null) metadata.named_precedence = value;
            },
            else => {},
        }
        if (step.associativity != .none and metadata.associativity == null) {
            metadata.associativity = step.associativity;
        }
    }
    return metadata;
}

fn comparePrecedenceEntries(
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    left: syntax_ir.PrecedenceEntry,
    right: syntax_ir.PrecedenceEntry,
) ?bool {
    for (precedence_orderings) |ordering| {
        var left_index: ?usize = null;
        var right_index: ?usize = null;

        for (ordering, 0..) |entry, index| {
            if (precedenceEntryEql(entry, left)) left_index = index;
            if (precedenceEntryEql(entry, right)) right_index = index;
        }

        if (left_index != null and right_index != null) {
            return right_index.? < left_index.?;
        }
    }

    return null;
}

fn extractShiftResolutionMetadata(
    productions: anytype,
    parse_state: state.ParseState,
    shift_symbol: syntax_ir.SymbolRef,
) ?ProductionResolutionMetadata {
    var metadata = ProductionResolutionMetadata{};
    var saw_match = false;

    for (parse_state.items) |entry| {
        const parse_item = entry.item;
        if (parse_item.production_id >= productions.len) continue;
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) continue;
        const step = production.steps[parse_item.step_index];
        if (!symbolRefEql(step.symbol, shift_symbol)) continue;

        saw_match = true;
        metadata = mergeResolutionMetadata(metadata, extractResolutionMetadata(production));
    }

    return if (saw_match) metadata else null;
}

fn mergeResolutionMetadata(
    existing: ProductionResolutionMetadata,
    candidate: ProductionResolutionMetadata,
) ProductionResolutionMetadata {
    var merged = existing;

    if (candidate.max_integer_precedence) |value| {
        if (merged.max_integer_precedence == null or value > merged.max_integer_precedence.?) {
            merged.max_integer_precedence = value;
        }
    }

    if (merged.named_precedence == null) merged.named_precedence = candidate.named_precedence;
    if (merged.associativity == null) merged.associativity = candidate.associativity;
    merged.dynamic_precedence += candidate.dynamic_precedence;

    return merged;
}

fn findState(states: []const state.ParseState, state_id: state.StateId) ?state.ParseState {
    for (states) |parse_state| {
        if (parse_state.id == state_id) return parse_state;
    }
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

fn precedenceEntryEql(a: syntax_ir.PrecedenceEntry, b: syntax_ir.PrecedenceEntry) bool {
    return switch (a) {
        .name => |left| switch (b) {
            .name => |right| std.mem.eql(u8, left, right),
            else => false,
        },
        .symbol => |left| switch (b) {
            .symbol => |right| symbolRefEql(left, right),
            else => false,
        },
    };
}

fn isShift(action: actions.ParseAction) bool {
    return switch (action) {
        .shift => true,
        else => false,
    };
}

fn isReduce(action: actions.ParseAction) bool {
    return switch (action) {
        .reduce => true,
        else => false,
    };
}

fn expectChosenAction(group: ResolvedActionGroup, expected: actions.ParseAction) !void {
    try std.testing.expect(switch (group.decision) {
        .chosen => |actual| std.meta.eql(actual, expected),
        .unresolved => false,
    });
}

fn expectUnresolvedGroup(
    group: ResolvedActionGroup,
    expected_reason: UnresolvedReason,
    expected_count: usize,
) !void {
    try std.testing.expect(switch (group.decision) {
        .chosen => false,
        .unresolved => |reason| reason == expected_reason,
    });
    try std.testing.expectEqual(expected_count, group.candidate_actions.len);
}

test "resolveActionTableSkeleton marks singleton groups as chosen" {
    const allocator = std.testing.allocator;

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 1,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 3 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableSkeleton(allocator, grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(@as(usize, 1), resolved.groupsForState(1).len);
    try expectChosenAction(resolved.groupsForState(1)[0], .{ .shift = 3 });
    try std.testing.expect(switch (resolved.decisionFor(1, .{ .terminal = 0 }).?) {
        .chosen => |action| std.meta.eql(action, actions.ParseAction{ .shift = 3 }),
        .unresolved => false,
    });
}

test "resolveActionTableSkeleton leaves multi-candidate groups unresolved" {
    const allocator = std.testing.allocator;

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 2 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableSkeleton(allocator, grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(2)[0], .shift_reduce, 2);
    try std.testing.expectEqual(@as(usize, 2), resolved.groupsForState(2)[0].candidate_actions.len);
    try std.testing.expect(switch (resolved.groupsForState(2)[0].candidate_actions[0]) {
        .shift => |id| id == 4,
        else => false,
    });
    try std.testing.expect(switch (resolved.groupsForState(2)[0].candidate_actions[1]) {
        .reduce => |id| id == 2,
        else => false,
    });
    try std.testing.expectEqual(@as(usize, 2), resolved.candidateActionsFor(2, .{ .terminal = 0 }).len);
    try std.testing.expect(resolved.hasUnresolvedDecisions());
    try std.testing.expect(!resolved.isSerializationReady());
}

test "resolveActionTableSkeleton is serialization-ready when every group is chosen" {
    const allocator = std.testing.allocator;

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 1,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 3 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableSkeleton(allocator, grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expect(!resolved.hasUnresolvedDecisions());
    try std.testing.expect(resolved.isSerializationReady());
    const chosen = try resolved.chosenDecisionsAlloc(allocator);
    defer allocator.free(chosen);
    try std.testing.expectEqual(@as(usize, 1), chosen.len);
    try std.testing.expectEqual(@as(state.StateId, 1), chosen[0].state_id);
    try std.testing.expect(switch (chosen[0].symbol) {
        .terminal => |id| id == 0,
        else => false,
    });
    try std.testing.expect(switch (chosen[0].action) {
        .shift => |id| id == 3,
        else => false,
    });
}

test "resolveActionTableSkeleton exposes structured unresolved decision refs" {
    const allocator = std.testing.allocator;

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 2 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableSkeleton(allocator, grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    const refs = try resolved.unresolvedDecisionsAlloc(allocator);
    defer allocator.free(refs);

    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqual(@as(state.StateId, 2), refs[0].state_id);
    try std.testing.expectEqual(UnresolvedReason.shift_reduce, refs[0].reason);
    try std.testing.expect(switch (refs[0].symbol) {
        .terminal => |id| id == 0,
        else => false,
    });
    try std.testing.expectEqual(@as(usize, 2), refs[0].candidate_actions.len);
}

test "resolveActionTableSkeleton exposes a serializer-facing decision snapshot" {
    const allocator = std.testing.allocator;

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 2 } },
                        },
                    },
                    .{
                        .symbol = .{ .terminal = 1 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 5 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableSkeleton(allocator, grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    const snapshot = try resolved.snapshotAlloc(allocator);
    defer {
        allocator.free(snapshot.chosen);
        allocator.free(snapshot.unresolved);
    }

    try std.testing.expect(!snapshot.isSerializationReady());
    try std.testing.expectEqual(@as(usize, 1), snapshot.chosen.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.unresolved.len);
    try std.testing.expect(switch (snapshot.chosen[0].action) {
        .shift => |id| id == 5,
        else => false,
    });
    try std.testing.expectEqual(UnresolvedReason.shift_reduce, snapshot.unresolved[0].reason);
}

test "resolveActionTable keeps reduce/reduce pairs unresolved" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = &[_]syntax_ir.ProductionStep{.{ .symbol = .{ .non_terminal = 1 } }} },
        .{ .lhs = 2, .steps = &[_]syntax_ir.ProductionStep{.{ .symbol = .{ .non_terminal = 2 } }} },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 4,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 2 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(4)[0], .reduce_reduce_deferred, 2);
}

test "resolveActionTable chooses reduce for a positive integer precedence shift/reduce pair" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{
                    .symbol = .{ .non_terminal = 1 },
                    .precedence = .{ .integer = 1 },
                },
            },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .reduce = 1 });
}

test "resolveActionTable chooses reduce for named precedence ordered above the conflicted symbol" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{
                    .symbol = .{ .non_terminal = 1 },
                    .precedence = .{ .name = "sum" },
                },
            },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{
        &[_]syntax_ir.PrecedenceEntry{
            .{ .symbol = .{ .terminal = 0 } },
            .{ .name = "sum" },
        },
    };

    const resolved = try resolveActionTableWithPrecedence(allocator, productions[0..], precedence_orderings[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .reduce = 1 });
}

test "resolveActionTable chooses shift for named precedence ordered below the conflicted symbol" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{
                    .symbol = .{ .non_terminal = 1 },
                    .precedence = .{ .name = "sum" },
                },
            },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{
        &[_]syntax_ir.PrecedenceEntry{
            .{ .name = "sum" },
            .{ .symbol = .{ .terminal = 0 } },
        },
    };

    const resolved = try resolveActionTableWithPrecedence(allocator, productions[0..], precedence_orderings[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .shift = 4 });
}

test "resolveActionTable chooses shift for a negative integer precedence shift/reduce pair" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{
                    .symbol = .{ .non_terminal = 1 },
                    .precedence = .{ .integer = -1 },
                },
            },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .shift = 4 });
}

test "resolveActionTable chooses reduce for equal-precedence left associativity" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{
                    .symbol = .{ .non_terminal = 1 },
                    .precedence = .{ .integer = 0 },
                    .associativity = .left,
                },
            },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .reduce = 1 });
}

test "resolveActionTable chooses shift for equal-precedence right associativity" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{
                    .symbol = .{ .non_terminal = 1 },
                    .precedence = .{ .integer = 0 },
                    .associativity = .right,
                },
            },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .shift = 4 });
}

test "resolveActionTable keeps equal-precedence non-associative conflicts unresolved" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{
                    .symbol = .{ .non_terminal = 1 },
                    .precedence = .{ .integer = 0 },
                    .associativity = .none,
                },
            },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(3)[0], .shift_reduce, 2);
}

test "extractResolutionMetadata captures integer precedence and associativity" {
    const steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 0 },
            .precedence = .{ .integer = 1 },
            .associativity = .left,
        },
        .{
            .symbol = .{ .terminal = 1 },
            .precedence = .{ .integer = 2 },
        },
    };

    const production = struct {
        steps: []const syntax_ir.ProductionStep,
        dynamic_precedence: i32,
    }{
        .steps = steps[0..],
        .dynamic_precedence = 7,
    };

    const metadata = extractResolutionMetadata(production);
    try std.testing.expectEqual(@as(i32, 2), metadata.max_integer_precedence.?);
    try std.testing.expectEqual(@import("../ir/rules.zig").Assoc.left, metadata.associativity.?);
    try std.testing.expectEqual(@as(i32, 7), metadata.dynamic_precedence);
}

test "resolveActionTable chooses reduce for positive dynamic precedence shift/reduce pair" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .non_terminal = 1 } },
            },
            .dynamic_precedence = 5,
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .reduce = 1 });
}

test "resolveActionTable chooses shift for negative dynamic precedence shift/reduce pair" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .non_terminal = 1 } },
            },
            .dynamic_precedence = -5,
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .shift = 4 });
}

test "resolveActionTable lets positive dynamic precedence outrank named precedence" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{
            .lhs = 1,
            .steps = &[_]syntax_ir.ProductionStep{
                .{
                    .symbol = .{ .non_terminal = 1 },
                    .precedence = .{ .name = "sum" },
                },
            },
            .dynamic_precedence = 1,
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 3,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{
        &[_]syntax_ir.PrecedenceEntry{
            .{ .name = "sum" },
            .{ .symbol = .{ .terminal = 0 } },
        },
    };

    const resolved = try resolveActionTableWithPrecedence(allocator, productions[0..], precedence_orderings[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .reduce = 1 });
}

test "resolveActionTable uses shift-side integer precedence from the current state when available" {
    testLog("resolveActionTable uses shift-side integer precedence from the current state when available");
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .precedence = .{ .integer = 1 },
        },
    };
    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{
            .symbol = .{ .terminal = 0 },
            .precedence = .{ .integer = 2 },
        },
        .{ .symbol = .{ .non_terminal = 1 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = reduce_steps[0..] },
        .{ .lhs = 1, .steps = shift_steps[0..] },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 2, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{
            .id = 6,
            .items = parse_items[0..],
            .transitions = &.{},
            .conflicts = &.{},
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 6,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(6)[0], .{ .shift = 7 });
}

test "resolveActionTable uses shift-side named precedence from the current state when available" {
    testLog("resolveActionTable uses shift-side named precedence from the current state when available");
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .precedence = .{ .name = "sum" },
        },
    };
    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{
            .symbol = .{ .terminal = 0 },
            .precedence = .{ .name = "product" },
        },
        .{ .symbol = .{ .non_terminal = 1 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = reduce_steps[0..] },
        .{ .lhs = 1, .steps = shift_steps[0..] },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 2, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{
            .id = 6,
            .items = parse_items[0..],
            .transitions = &.{},
            .conflicts = &.{},
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 6,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{
        &[_]syntax_ir.PrecedenceEntry{
            .{ .name = "sum" },
            .{ .name = "product" },
        },
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        precedence_orderings[0..],
        parse_states[0..],
        grouped,
    );
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(6)[0], .{ .shift = 7 });
}

test "resolveActionTable uses production-level shift precedence from the current state when the conflicted step itself has none" {
    testLog("resolveActionTable uses production-level shift precedence from the current state when the conflicted step itself has none");
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .precedence = .{ .integer = 1 },
        },
    };
    const shift_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .precedence = .{ .integer = 2 },
        },
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .non_terminal = 1 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = reduce_steps[0..] },
        .{ .lhs = 1, .steps = shift_steps[0..] },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 2, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{
            .id = 6,
            .items = parse_items[0..],
            .transitions = &.{},
            .conflicts = &.{},
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 6,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(6)[0], .{ .shift = 7 });
}

test "resolveActionTable prefers shift over reducing repeat auxiliaries" {
    testLog("resolveActionTable prefers shift over reducing repeat auxiliaries");
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        lhs_is_repeat_auxiliary: bool = false,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = reduce_steps[0..], .lhs_is_repeat_auxiliary = true },
        .{ .lhs = 2, .steps = shift_steps[0..] },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 2, .step_index = 0 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{
            .id = 6,
            .items = parse_items[0..],
            .transitions = &.{},
            .conflicts = &.{},
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 6,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                            .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(6)[0], .{ .shift = 7 });
}

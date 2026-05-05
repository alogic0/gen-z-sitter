const std = @import("std");
const actions = @import("actions.zig");
const first_sets_mod = @import("first.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const conflict_resolution = @import("conflict_resolution.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const UnresolvedReason = enum {
    multiple_candidates,
    auxiliary_repeat,
    shift_reduce,
    shift_reduce_expected,
    reduce_reduce_deferred,
    reduce_reduce_expected,
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
    shift_is_repetition: bool = false,

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

    pub fn hasBlockingUnresolvedDecisions(self: ResolvedActionTable) bool {
        for (self.states) |resolved| {
            for (resolved.groups) |group| {
                switch (group.decision) {
                    .chosen => {},
                    .unresolved => |reason| {
                        if (reason != .auxiliary_repeat and
                            reason != .reduce_reduce_expected and
                            reason != .shift_reduce_expected) return true;
                    },
                }
            }
        }
        return false;
    }

    pub fn isSerializationReady(self: ResolvedActionTable) bool {
        return !self.hasBlockingUnresolvedDecisions();
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

    pub fn expectedConflictCandidatesAlloc(
        self: ResolvedActionTable,
        allocator: std.mem.Allocator,
        productions: anytype,
        parse_states: []const state.ParseState,
    ) std.mem.Allocator.Error![]const conflict_resolution.ConflictCandidate {
        var result = std.array_list.Managed(conflict_resolution.ConflictCandidate).init(allocator);
        defer result.deinit();
        errdefer for (result.items) |candidate| allocator.free(candidate.members);

        for (self.states) |resolved| {
            for (resolved.groups) |group| {
                switch (group.decision) {
                    .chosen => {},
                    .unresolved => |reason| switch (reason) {
                        .reduce_reduce_deferred, .reduce_reduce_expected => {
                            const candidate = if (findState(parse_states, resolved.state_id)) |parse_state|
                                try reduceConflictCandidateAlloc(
                                    allocator,
                                    resolved.state_id,
                                    group.symbol,
                                    productions,
                                    parse_state,
                                    group.candidate_actions,
                                )
                            else
                                try conflict_resolution.reduceConflictCandidateAlloc(
                                    allocator,
                                    resolved.state_id,
                                    group.symbol,
                                    productions,
                                    group.candidate_actions,
                                );
                            if (candidate) |value| try result.append(value);
                        },
                        .shift_reduce, .shift_reduce_expected => {
                            const parse_state = findState(parse_states, resolved.state_id) orelse continue;
                            const candidate = try shiftReduceConflictCandidateAlloc(
                                allocator,
                                resolved.state_id,
                                group.symbol,
                                productions,
                                parse_state,
                                null,
                                group.candidate_actions,
                            );
                            if (candidate) |value| try result.append(value);
                        },
                        .auxiliary_repeat, .multiple_candidates, .unsupported_action_mix => {},
                    },
                }
            }
        }

        return try result.toOwnedSlice();
    }

    pub fn unusedExpectedConflictIndexesAlloc(
        self: ResolvedActionTable,
        allocator: std.mem.Allocator,
        expected_conflicts: []const []const syntax_ir.SymbolRef,
        productions: anytype,
        parse_states: []const state.ParseState,
    ) std.mem.Allocator.Error![]const usize {
        const candidates = try self.expectedConflictCandidatesAlloc(allocator, productions, parse_states);
        defer conflict_resolution.freeConflictCandidates(allocator, candidates);

        const policy = conflict_resolution.ExpectedConflictPolicy{
            .expected_conflicts = expected_conflicts,
        };
        return try policy.unusedExpectedIndexesAlloc(allocator, candidates);
    }
};

const ProductionResolutionMetadata = struct {
    max_integer_precedence: ?i32 = null,
    named_precedence: ?[]const u8 = null,
    associativity: ?@import("../ir/rules.zig").Assoc = null,
    dynamic_precedence: i32 = 0,
};

const ShiftResolutionMetadata = struct {
    resolution: ProductionResolutionMetadata = .{},
    has_repeat_auxiliary_candidate: bool = false,
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
    return try resolveActionTableWithContext(allocator, productions, &.{}, &.{}, &.{}, grouped_table);
}

pub fn resolveActionTableWithPrecedence(
    allocator: std.mem.Allocator,
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    return try resolveActionTableWithContext(allocator, productions, precedence_orderings, &.{}, &.{}, grouped_table);
}

pub fn resolveActionTableWithContext(
    allocator: std.mem.Allocator,
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    expected_conflicts: []const []const syntax_ir.SymbolRef,
    parse_states: []const state.ParseState,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    return try resolveActionTableWithOptionalFirstSets(
        allocator,
        productions,
        precedence_orderings,
        expected_conflicts,
        parse_states,
        null,
        grouped_table,
    );
}

pub fn resolveActionTableWithFirstSetsContext(
    allocator: std.mem.Allocator,
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    expected_conflicts: []const []const syntax_ir.SymbolRef,
    parse_states: []const state.ParseState,
    first_sets: first_sets_mod.FirstSets,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    return try resolveActionTableWithOptionalFirstSets(
        allocator,
        productions,
        precedence_orderings,
        expected_conflicts,
        parse_states,
        first_sets,
        grouped_table,
    );
}

fn resolveActionTableWithOptionalFirstSets(
    allocator: std.mem.Allocator,
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    expected_conflicts: []const []const syntax_ir.SymbolRef,
    parse_states: []const state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    const states = try allocator.alloc(ResolvedStateActions, grouped_table.states.len);
    for (grouped_table.states, 0..) |grouped_state, state_index| {
        const groups = try allocator.alloc(ResolvedActionGroup, grouped_state.groups.len);
        const parse_state = findState(parse_states, grouped_state.state_id);
        for (grouped_state.groups, 0..) |group, group_index| {
            var candidate_actions = try actionGroupActionsAlloc(allocator, group);
            if (try filterLowerPrecedenceReductionsAlloc(
                allocator,
                productions,
                precedence_orderings,
                candidate_actions,
            )) |filtered| {
                allocator.free(candidate_actions);
                candidate_actions = filtered;
            }
            if (!hasSameAuxiliaryRepeatConflictForGroup(
                productions,
                parse_state,
                first_sets,
                group.symbol,
                candidate_actions,
            )) {
                if (try filterShiftReduceByPrecedenceAlloc(
                    allocator,
                    productions,
                    precedence_orderings,
                    parse_state,
                    first_sets,
                    group.symbol,
                    candidate_actions,
                )) |filtered| {
                    allocator.free(candidate_actions);
                    candidate_actions = filtered;
                }
            }
            const decision = chooseResolvedAction(
                productions,
                precedence_orderings,
                expected_conflicts,
                parse_state,
                first_sets,
                group.symbol,
                candidate_actions,
            );
            const resolved_decision: ResolvedDecision = if (decision.chosen) |chosen|
                .{ .chosen = chosen }
            else
                .{ .unresolved = decision.reason orelse .unsupported_action_mix };
            groups[group_index] = .{
                .symbol = group.symbol,
                .candidate_actions = candidate_actions,
                .decision = resolved_decision,
                .shift_is_repetition = resolvedShiftIsRepetition(
                    productions,
                    parse_state,
                    first_sets,
                    group.symbol,
                    resolved_decision,
                ),
            };
        }
        states[state_index] = .{
            .state_id = grouped_state.state_id,
            .groups = groups,
        };
    }
    return .{ .states = states };
}

fn resolvedShiftIsRepetition(
    productions: anytype,
    parse_state: ?state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    symbol: syntax_ir.SymbolRef,
    decision: ResolvedDecision,
) bool {
    switch (decision) {
        .chosen => |action| switch (action) {
            .shift => {},
            else => return false,
        },
        .unresolved => |reason| if (reason == .auxiliary_repeat) return true else return false,
    }
    const resolved_state = parse_state orelse return false;
    return hasSameAuxiliaryRepeatConflictWithFirstSets(productions, resolved_state, first_sets, symbol);
}

fn hasSameAuxiliaryRepeatConflictForGroup(
    productions: anytype,
    parse_state: ?state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    symbol: syntax_ir.SymbolRef,
    candidate_actions: []const actions.ParseAction,
) bool {
    const resolved_state = parse_state orelse return false;
    var saw_shift = false;
    var saw_reduce = false;
    for (candidate_actions) |candidate| {
        switch (candidate) {
            .shift => saw_shift = true,
            .reduce => |reduced| {
                const production_id = reduced.production_id;
                saw_reduce = true;
                if (production_id >= productions.len) return false;
                const production = productions[production_id];
                if (!productionIsAuxiliary(production)) return false;
            },
            else => return false,
        }
    }
    return saw_shift and saw_reduce and
        hasSameAuxiliaryRepeatConflictWithFirstSets(productions, resolved_state, first_sets, symbol);
}

fn actionGroupActionsAlloc(
    allocator: std.mem.Allocator,
    group: actions.ActionGroup,
) std.mem.Allocator.Error![]const actions.ParseAction {
    if (group.actions.len != 0) return try allocator.dupe(actions.ParseAction, group.actions);
    return try actionsFromEntriesAlloc(allocator, group.entries);
}

fn filterLowerPrecedenceReductionsAlloc(
    allocator: std.mem.Allocator,
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    candidate_actions: []const actions.ParseAction,
) std.mem.Allocator.Error!?[]const actions.ParseAction {
    if (candidate_actions.len <= 1) return null;

    var kept_reductions_buffer: [256]actions.ParseAction = undefined;
    var kept_reduction_count: usize = 0;
    var original_reduction_count: usize = 0;

    for (candidate_actions) |candidate| {
        if (!isReduce(candidate)) continue;
        original_reduction_count += 1;

        if (kept_reduction_count == 0) {
            kept_reductions_buffer[0] = candidate;
            kept_reduction_count = 1;
            continue;
        }

        switch (compareReduceActionPrecedence(
            productions,
            precedence_orderings,
            candidate,
            kept_reductions_buffer[0],
        ) orelse .equal) {
            .greater => {
                kept_reductions_buffer[0] = candidate;
                kept_reduction_count = 1;
            },
            .less => {},
            .equal => {
                if (kept_reduction_count == kept_reductions_buffer.len) return null;
                kept_reductions_buffer[kept_reduction_count] = candidate;
                kept_reduction_count += 1;
            },
        }
    }

    if (kept_reduction_count == 0 or kept_reduction_count == original_reduction_count) return null;

    const filtered_len = candidate_actions.len - (original_reduction_count - kept_reduction_count);
    var filtered = try allocator.alloc(actions.ParseAction, filtered_len);
    var index: usize = 0;
    for (candidate_actions) |candidate| {
        if (isReduce(candidate) and !containsParseAction(kept_reductions_buffer[0..kept_reduction_count], candidate)) continue;
        filtered[index] = candidate;
        index += 1;
    }
    std.debug.assert(index == filtered.len);
    return filtered;
}

fn actionsFromEntriesAlloc(
    allocator: std.mem.Allocator,
    entries: []const actions.ActionEntry,
) std.mem.Allocator.Error![]const actions.ParseAction {
    const duplicated = try allocator.alloc(actions.ParseAction, entries.len);
    for (entries, 0..) |entry, index| {
        duplicated[index] = entry.action;
    }
    return duplicated;
}

fn filterShiftReduceByPrecedenceAlloc(
    allocator: std.mem.Allocator,
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    parse_state: ?state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    symbol: syntax_ir.SymbolRef,
    candidate_actions: []const actions.ParseAction,
) std.mem.Allocator.Error!?[]const actions.ParseAction {
    var shift_action: ?actions.ParseAction = null;
    var reduce_count: usize = 0;

    for (candidate_actions) |candidate| {
        switch (candidate) {
            .shift => {
                if (shift_action != null) return null;
                shift_action = candidate;
            },
            .reduce => reduce_count += 1,
            else => return null,
        }
    }

    const shift = shift_action orelse return null;
    if (reduce_count == 0) return null;

    var shift_wins = false;
    var reduce_wins = false;
    for (candidate_actions) |candidate| {
        switch (candidate) {
            .reduce => {
                const chosen = resolveShiftReduce(
                    productions,
                    precedence_orderings,
                    parse_state,
                    first_sets,
                    symbol,
                    shift,
                    candidate,
                ) orelse return null;
                if (std.meta.eql(chosen, shift)) {
                    shift_wins = true;
                } else if (std.meta.eql(chosen, candidate)) {
                    reduce_wins = true;
                } else {
                    return null;
                }
            },
            else => {},
        }
    }

    if (shift_wins and reduce_wins) return null;

    if (shift_wins) {
        const filtered = try allocator.alloc(actions.ParseAction, 1);
        filtered[0] = shift;
        return filtered;
    }

    const filtered = try allocator.alloc(actions.ParseAction, reduce_count);
    var index: usize = 0;
    for (candidate_actions) |candidate| {
        switch (candidate) {
            .reduce => {
                filtered[index] = candidate;
                index += 1;
            },
            else => {},
        }
    }
    std.debug.assert(index == filtered.len);
    return filtered;
}

const ResolutionDecision = struct {
    chosen: ?actions.ParseAction = null,
    reason: ?UnresolvedReason = null,
};

fn chooseResolvedAction(
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    expected_conflicts: []const []const syntax_ir.SymbolRef,
    parse_state: ?state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    symbol: syntax_ir.SymbolRef,
    candidates: []const actions.ParseAction,
) ResolutionDecision {
    if (candidates.len == 1) return .{ .chosen = candidates[0] };

    if (candidates.len == 2) {
        const first = candidates[0];
        const second = candidates[1];

        if (isShift(first) and isReduce(second)) {
            if (hasSameAuxiliaryRepeatConflictForGroup(productions, parse_state, first_sets, symbol, candidates)) {
                return .{ .chosen = null, .reason = .auxiliary_repeat };
            }
            const chosen = resolveShiftReduce(productions, precedence_orderings, parse_state, first_sets, symbol, first, second);
            return .{
                .chosen = chosen,
                .reason = if (chosen == null and shiftReduceIsExpected(
                    productions,
                    expected_conflicts,
                    parse_state,
                    first_sets,
                    symbol,
                    candidates,
                )) .shift_reduce_expected else .shift_reduce,
            };
        }
        if (isReduce(first) and isShift(second)) {
            if (hasSameAuxiliaryRepeatConflictForGroup(productions, parse_state, first_sets, symbol, candidates)) {
                return .{ .chosen = null, .reason = .auxiliary_repeat };
            }
            const chosen = resolveShiftReduce(productions, precedence_orderings, parse_state, first_sets, symbol, second, first);
            return .{
                .chosen = chosen,
                .reason = if (chosen == null and shiftReduceIsExpected(
                    productions,
                    expected_conflicts,
                    parse_state,
                    first_sets,
                    symbol,
                    candidates,
                )) .shift_reduce_expected else .shift_reduce,
            };
        }
        if (isReduce(first) and isReduce(second)) {
            if (resolveReduceReduceByPrecedence(productions, precedence_orderings, first, second)) |chosen| {
                return .{ .chosen = chosen };
            }
            const reason: UnresolvedReason = if (reduceReduceIsExpected(
                productions,
                expected_conflicts,
                parse_state,
                symbol,
                candidates,
            ))
                .reduce_reduce_expected
            else
                .reduce_reduce_deferred;
            return .{ .chosen = null, .reason = reason };
        }
    }

    if (candidates.len > 2) {
        var has_shift = false;
        var has_reduce = false;
        var has_other = false;
        for (candidates) |candidate| {
            if (isShift(candidate)) {
                has_shift = true;
            } else if (isReduce(candidate)) {
                has_reduce = true;
            } else {
                has_other = true;
            }
        }

        if (!has_other and has_reduce and has_shift) {
            if (hasSameAuxiliaryRepeatConflictForGroup(productions, parse_state, first_sets, symbol, candidates)) {
                return .{ .chosen = null, .reason = .auxiliary_repeat };
            }
            return .{
                .chosen = null,
                .reason = if (shiftReduceIsExpected(
                    productions,
                    expected_conflicts,
                    parse_state,
                    first_sets,
                    symbol,
                    candidates,
                )) .shift_reduce_expected else .multiple_candidates,
            };
        }
        if (!has_other and has_reduce) {
            return .{
                .chosen = null,
                .reason = if (reduceReduceIsExpected(
                    productions,
                    expected_conflicts,
                    parse_state,
                    symbol,
                    candidates,
                )) .reduce_reduce_expected else .reduce_reduce_deferred,
            };
        }
    }

    return .{
        .chosen = null,
        .reason = if (candidates.len > 1) .multiple_candidates else .unsupported_action_mix,
    };
}

fn reduceReduceIsExpected(
    productions: anytype,
    expected_conflicts: []const []const syntax_ir.SymbolRef,
    parse_state: ?state.ParseState,
    symbol: syntax_ir.SymbolRef,
    candidates: []const actions.ParseAction,
) bool {
    if (parse_state) |resolved_state| {
        var members_buffer: [256]syntax_ir.SymbolRef = undefined;
        const candidate = reduceConflictCandidate(
            &members_buffer,
            resolved_state.id,
            symbol,
            productions,
            resolved_state,
            candidates,
        ) orelse return false;
        const policy = conflict_resolution.ExpectedConflictPolicy{ .expected_conflicts = expected_conflicts };
        return policy.isExpected(candidate);
    } else {
        return conflict_resolution.reduceConflictIsExpected(
            expected_conflicts,
            0,
            symbol,
            productions,
            candidates,
        );
    }
}

fn reduceConflictCandidateAlloc(
    allocator: std.mem.Allocator,
    state_id: state.StateId,
    lookahead: syntax_ir.SymbolRef,
    productions: anytype,
    parse_state: state.ParseState,
    candidate_actions: []const actions.ParseAction,
) std.mem.Allocator.Error!?conflict_resolution.ConflictCandidate {
    const members = try allocator.alloc(syntax_ir.SymbolRef, candidate_actions.len + parse_state.items.len * 2);
    errdefer allocator.free(members);

    const candidate = reduceConflictCandidate(
        members,
        state_id,
        lookahead,
        productions,
        parse_state,
        candidate_actions,
    ) orelse {
        allocator.free(members);
        return null;
    };

    const owned_members = try allocator.dupe(syntax_ir.SymbolRef, candidate.members);
    allocator.free(members);
    return .{
        .state_id = candidate.state_id,
        .lookahead = candidate.lookahead,
        .members = owned_members,
    };
}

fn reduceConflictCandidate(
    members_buffer: []syntax_ir.SymbolRef,
    state_id: state.StateId,
    lookahead: syntax_ir.SymbolRef,
    productions: anytype,
    parse_state: state.ParseState,
    candidate_actions: []const actions.ParseAction,
) ?conflict_resolution.ConflictCandidate {
    if (recordedConflictCandidate(
        members_buffer,
        state_id,
        lookahead,
        productions,
        parse_state,
        .reduce_reduce,
    )) |candidate| return candidate;

    if (candidate_actions.len == 0) return null;

    var member_count: usize = 0;
    for (candidate_actions) |action| {
        const production_id = switch (action) {
            .reduce => |reduced| reduced.production_id,
            else => return null,
        };
        if (production_id >= productions.len) return null;
        member_count = appendConflictMemberUpstreamStyle(
            members_buffer,
            member_count,
            .{ .non_terminal = productions[production_id].lhs },
            productions,
            parse_state,
        ) orelse return null;
    }

    if (member_count == 0) return null;
    return .{
        .state_id = state_id,
        .lookahead = lookahead,
        .members = members_buffer[0..member_count],
    };
}

fn shiftReduceIsExpected(
    productions: anytype,
    expected_conflicts: []const []const syntax_ir.SymbolRef,
    parse_state: ?state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    symbol: syntax_ir.SymbolRef,
    candidates: []const actions.ParseAction,
) bool {
    const resolved_state = parse_state orelse return false;
    var members_buffer: [256]syntax_ir.SymbolRef = undefined;
    const candidate = shiftReduceConflictCandidate(
        &members_buffer,
        resolved_state.id,
        symbol,
        productions,
        resolved_state,
        first_sets,
        candidates,
    ) orelse return false;
    const policy = conflict_resolution.ExpectedConflictPolicy{ .expected_conflicts = expected_conflicts };
    return policy.isExpected(candidate);
}

fn shiftReduceConflictCandidateAlloc(
    allocator: std.mem.Allocator,
    state_id: state.StateId,
    lookahead: syntax_ir.SymbolRef,
    productions: anytype,
    parse_state: state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    candidate_actions: []const actions.ParseAction,
) std.mem.Allocator.Error!?conflict_resolution.ConflictCandidate {
    const members = try allocator.alloc(syntax_ir.SymbolRef, candidate_actions.len + parse_state.items.len * 2);
    errdefer allocator.free(members);

    const candidate = shiftReduceConflictCandidate(
        members,
        state_id,
        lookahead,
        productions,
        parse_state,
        first_sets,
        candidate_actions,
    ) orelse {
        allocator.free(members);
        return null;
    };

    const owned_members = try allocator.dupe(syntax_ir.SymbolRef, candidate.members);
    allocator.free(members);
    return .{
        .state_id = candidate.state_id,
        .lookahead = candidate.lookahead,
        .members = owned_members,
    };
}

fn shiftReduceConflictCandidate(
    members_buffer: []syntax_ir.SymbolRef,
    state_id: state.StateId,
    lookahead: syntax_ir.SymbolRef,
    productions: anytype,
    parse_state: state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    candidate_actions: []const actions.ParseAction,
) ?conflict_resolution.ConflictCandidate {
    if (recordedConflictCandidate(
        members_buffer,
        state_id,
        lookahead,
        productions,
        parse_state,
        .shift_reduce,
    )) |candidate| return candidate;

    if (candidate_actions.len == 0) return null;

    var saw_shift = false;
    var saw_reduce = false;
    var member_count: usize = 0;
    for (candidate_actions) |action| {
        switch (action) {
            .shift => saw_shift = true,
            .reduce => |reduced| {
                const production_id = reduced.production_id;
                saw_reduce = true;
                if (production_id >= productions.len) return null;
                member_count = appendConflictMemberUpstreamStyle(
                    members_buffer,
                    member_count,
                    .{ .non_terminal = productions[production_id].lhs },
                    productions,
                    parse_state,
                ) orelse return null;
            },
            else => return null,
        }
    }
    if (!saw_shift or !saw_reduce) return null;

    for (parse_state.items) |entry| {
        if (entry.item.production_id >= productions.len) continue;
        const production = productions[entry.item.production_id];
        if (entry.item.step_index < production.steps.len) {
            if (!saw_shift) continue;
            if (entry.item.step_index == 0) continue;
            const step = production.steps[entry.item.step_index];
            if (!symbolCanStartLookahead(first_sets, step.symbol, lookahead)) continue;
        } else {
            if (!item.containsLookahead(entry.lookaheads, lookahead)) continue;
            if (!candidateActionsContainReduce(candidate_actions, entry.item.production_id)) continue;
        }
        member_count = appendConflictMemberUpstreamStyle(
            members_buffer,
            member_count,
            conflictMemberForItem(entry.item, productions) orelse return null,
            productions,
            parse_state,
        ) orelse return null;
    }

    if (member_count == 0) return null;
    return .{
        .state_id = state_id,
        .lookahead = lookahead,
        .members = members_buffer[0..member_count],
    };
}

fn recordedConflictCandidate(
    members_buffer: []syntax_ir.SymbolRef,
    state_id: state.StateId,
    lookahead: syntax_ir.SymbolRef,
    productions: anytype,
    parse_state: state.ParseState,
    kind: state.ConflictKind,
) ?conflict_resolution.ConflictCandidate {
    for (parse_state.conflicts) |conflict| {
        if (conflict.kind != kind) continue;
        const conflict_symbol = conflict.symbol orelse continue;
        if (!symbolRefEql(conflict_symbol, lookahead)) continue;

        var member_count: usize = 0;
        for (conflict.items) |parse_item| {
            if (parse_item.production_id >= productions.len) return null;
            member_count = appendConflictMemberUpstreamStyle(
                members_buffer,
                member_count,
                conflictMemberForItem(parse_item, productions) orelse return null,
                productions,
                parse_state,
            ) orelse return null;
        }
        if (member_count == 0) return null;
        return .{
            .state_id = state_id,
            .lookahead = lookahead,
            .members = members_buffer[0..member_count],
        };
    }
    return null;
}

fn conflictMemberForItem(
    parse_item: item.ParseItem,
    productions: anytype,
) ?syntax_ir.SymbolRef {
    if (parse_item.variable_index != item.unset_variable_index) {
        return .{ .non_terminal = parse_item.variable_index };
    }
    if (parse_item.production_id >= productions.len) return null;
    return .{ .non_terminal = productions[parse_item.production_id].lhs };
}

fn candidateActionsContainReduce(candidate_actions: []const actions.ParseAction, production_id: item.ProductionId) bool {
    for (candidate_actions) |candidate| {
        switch (candidate) {
            .reduce => |reduced| if (reduced.production_id == production_id) return true,
            else => {},
        }
    }
    return false;
}

fn appendConflictMemberUpstreamStyle(
    members: []syntax_ir.SymbolRef,
    member_count: usize,
    symbol: syntax_ir.SymbolRef,
    productions: anytype,
    parse_state: state.ParseState,
) ?usize {
    const non_terminal = switch (symbol) {
        .non_terminal => |index| index,
        else => return appendUniqueConflictMember(members, member_count, symbol),
    };
    if (!symbolIsAuxiliaryLhs(productions, non_terminal)) {
        return appendUniqueConflictMember(members, member_count, symbol);
    }

    if (auxiliaryParentsForSymbol(parse_state, symbol)) |parents| {
        var next_count = member_count;
        for (parents) |parent| {
            next_count = appendUniqueConflictMember(members, next_count, parent) orelse return null;
        }
        return next_count;
    }

    return appendUniqueConflictMember(members, member_count, symbol);
}

fn auxiliaryParentsForSymbol(
    parse_state: state.ParseState,
    symbol: syntax_ir.SymbolRef,
) ?[]const syntax_ir.SymbolRef {
    var index = parse_state.auxiliary_symbols.len;
    while (index > 0) {
        index -= 1;
        const info = parse_state.auxiliary_symbols[index];
        if (symbolRefEql(info.auxiliary_symbol, symbol)) return info.parent_symbols;
    }
    return null;
}

fn symbolIsAuxiliaryLhs(productions: anytype, non_terminal: u32) bool {
    for (productions) |production| {
        if (production.lhs == non_terminal and productionIsAuxiliary(production)) return true;
    }
    return false;
}

fn appendUniqueConflictMember(
    members: []syntax_ir.SymbolRef,
    member_count: usize,
    symbol: syntax_ir.SymbolRef,
) ?usize {
    for (members[0..member_count]) |existing| {
        if (symbolRefEql(existing, symbol)) return member_count;
    }
    if (member_count >= members.len) return null;
    members[member_count] = symbol;
    return member_count + 1;
}

const PrecedenceComparison = enum {
    less,
    equal,
    greater,
};

fn compareReduceActionPrecedence(
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    first: actions.ParseAction,
    second: actions.ParseAction,
) ?PrecedenceComparison {
    const first_id = switch (first) {
        .reduce => |reduced| reduced.production_id,
        else => return null,
    };
    const second_id = switch (second) {
        .reduce => |reduced| reduced.production_id,
        else => return null,
    };
    if (first_id >= productions.len or second_id >= productions.len) return null;
    return compareReducePrecedence(productions[first_id], productions[second_id], precedence_orderings);
}

fn resolveReduceReduceByPrecedence(
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    first: actions.ParseAction,
    second: actions.ParseAction,
) ?actions.ParseAction {
    const first_id = switch (first) {
        .reduce => |reduced| reduced.production_id,
        else => return null,
    };
    const second_id = switch (second) {
        .reduce => |reduced| reduced.production_id,
        else => return null,
    };
    if (first_id >= productions.len or second_id >= productions.len) return null;

    return switch (compareReducePrecedence(
        productions[first_id],
        productions[second_id],
        precedence_orderings,
    )) {
        .greater => first,
        .less => second,
        .equal => null,
    };
}

fn compareReducePrecedence(
    left: anytype,
    right: @TypeOf(left),
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
) PrecedenceComparison {
    const left_metadata = extractResolutionMetadata(left);
    const right_metadata = extractResolutionMetadata(right);

    const left_integer = left_metadata.max_integer_precedence orelse 0;
    const right_integer = right_metadata.max_integer_precedence orelse 0;
    if (left_integer != 0 or right_integer != 0) {
        if (left_integer > right_integer) return .greater;
        if (left_integer < right_integer) return .less;
        return .equal;
    }

    for (precedence_orderings) |ordering| {
        var saw_left = false;
        var saw_right = false;
        for (ordering) |entry| {
            if (precedenceEntryMatchesProduction(entry, left_metadata, left.lhs)) {
                if (saw_right) return .less;
                saw_left = true;
            } else if (precedenceEntryMatchesProduction(entry, right_metadata, right.lhs)) {
                if (saw_left) return .greater;
                saw_right = true;
            }
        }
    }

    return .equal;
}

fn compareProductionPrecedence(
    left_metadata: ProductionResolutionMetadata,
    left_lhs: u32,
    right_metadata: ProductionResolutionMetadata,
    right_lhs: u32,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
) PrecedenceComparison {
    const left_integer = left_metadata.max_integer_precedence orelse 0;
    const right_integer = right_metadata.max_integer_precedence orelse 0;
    if (left_integer != 0 or right_integer != 0) {
        if (left_integer > right_integer) return .greater;
        if (left_integer < right_integer) return .less;
        return .equal;
    }

    for (precedence_orderings) |ordering| {
        var saw_left = false;
        var saw_right = false;
        for (ordering) |entry| {
            if (precedenceEntryMatchesProduction(entry, left_metadata, left_lhs)) {
                if (saw_right) return .less;
                saw_left = true;
            } else if (precedenceEntryMatchesProduction(entry, right_metadata, right_lhs)) {
                if (saw_left) return .greater;
                saw_right = true;
            }
        }
    }

    return .equal;
}

fn precedenceEntryMatchesProduction(
    entry: syntax_ir.PrecedenceEntry,
    metadata: ProductionResolutionMetadata,
    lhs: u32,
) bool {
    return switch (entry) {
        .name => |name| if (metadata.named_precedence) |candidate|
            std.mem.eql(u8, name, candidate)
        else
            false,
        .symbol => |symbol| switch (symbol) {
            .non_terminal => |index| index == lhs,
            else => false,
        },
    };
}

fn resolveShiftReduce(
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    parse_state: ?state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    shift_symbol: syntax_ir.SymbolRef,
    shift_action: actions.ParseAction,
    reduce_action: actions.ParseAction,
) ?actions.ParseAction {
    const production_id = switch (reduce_action) {
        .reduce => |reduced| reduced.production_id,
        else => return null,
    };

    if (production_id >= productions.len) return null;
    const production = productions[production_id];
    const metadata = extractResolutionMetadata(production);
    const shift_metadata = if (parse_state) |resolved_state|
        extractShiftResolutionMetadata(productions, resolved_state, first_sets, shift_symbol)
    else
        null;

    if (shift_metadata) |shift| {
        if (metadata.max_integer_precedence) |reduce_value| {
            if (shift.resolution.max_integer_precedence) |shift_value| {
                if (reduce_value > shift_value) return reduce_action;
                if (reduce_value < shift_value) return shift_action;
                if (resolveEqualPrecedenceByAssociativity(metadata, reduce_action, shift_action)) |action| return action;
            }
        }

        if (metadata.named_precedence) |reduce_name| {
            if (shift.resolution.named_precedence) |shift_name| {
                if (std.mem.eql(u8, reduce_name, shift_name)) {
                    return resolveEqualPrecedenceByAssociativity(metadata, reduce_action, shift_action);
                }
                if (comparePrecedenceEntries(
                    precedence_orderings,
                    .{ .name = reduce_name },
                    .{ .name = shift_name },
                )) |reduce_wins| {
                    return if (reduce_wins) reduce_action else shift_action;
                }
            }
        }

        if (shift.resolution.named_precedence) |shift_name| {
            if (comparePrecedenceEntries(
                precedence_orderings,
                .{ .name = shift_name },
                .{ .symbol = .{ .non_terminal = production.lhs } },
            )) |shift_wins| {
                return if (shift_wins) shift_action else reduce_action;
            }
        }
    }

    if (parse_state) |resolved_state| {
        if (compareShiftItemPrecedence(
            productions,
            precedence_orderings,
            resolved_state,
            first_sets,
            shift_symbol,
            production,
        )) |comparison| {
            switch (comparison) {
                .greater => return shift_action,
                .less => return reduce_action,
                .equal => if (resolveEqualPrecedenceByAssociativity(metadata, reduce_action, shift_action)) |action| return action,
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

    if (metadata.associativity) |assoc| switch (assoc) {
        .left => return reduce_action,
        .right => return shift_action,
        .none => {},
    };

    return null;
}

fn compareShiftItemPrecedence(
    productions: anytype,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    parse_state: state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    shift_symbol: syntax_ir.SymbolRef,
    reduce_production: @TypeOf(productions[0]),
) ?PrecedenceComparison {
    const reduce_metadata = extractResolutionMetadata(reduce_production);
    var saw_shift_precedence = false;
    var shift_is_less = false;
    var shift_is_more = false;

    for (parse_state.items) |entry| {
        const parse_item = entry.item;
        if (parse_item.production_id >= productions.len) continue;
        const shift_production = productions[parse_item.production_id];
        if (parse_item.step_index >= shift_production.steps.len) continue;
        if (parse_item.step_index == 0) continue;
        const step = shift_production.steps[parse_item.step_index];
        if (!symbolCanStartLookahead(first_sets, step.symbol, shift_symbol)) continue;

        const shift_metadata = extractShiftItemResolutionMetadata(shift_production, parse_item.step_index);
        saw_shift_precedence = true;
        switch (compareProductionPrecedence(
            shift_metadata,
            shift_production.lhs,
            reduce_metadata,
            reduce_production.lhs,
            precedence_orderings,
        )) {
            .greater => shift_is_more = true,
            .less => shift_is_less = true,
            .equal => {},
        }
    }

    if (shift_is_more and !shift_is_less) return .greater;
    if (shift_is_less and !shift_is_more) return .less;
    if (saw_shift_precedence and !shift_is_more and !shift_is_less) return .equal;
    return null;
}

pub fn hasSameAuxiliaryRepeatConflict(
    productions: anytype,
    parse_state: state.ParseState,
    shift_symbol: syntax_ir.SymbolRef,
) bool {
    return hasSameAuxiliaryRepeatConflictWithFirstSets(productions, parse_state, null, shift_symbol);
}

pub fn hasSameAuxiliaryRepeatConflictWithFirstSets(
    productions: anytype,
    parse_state: state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    shift_symbol: syntax_ir.SymbolRef,
) bool {
    var common_lhs: ?u32 = null;
    var saw_shift_item = false;
    var saw_reduce_item = false;

    for (parse_state.items) |entry| {
        if (entry.item.production_id >= productions.len) continue;
        const production = productions[entry.item.production_id];
        if (productionIsAugmented(production)) continue;

        const participates_as_shift =
            entry.item.step_index < production.steps.len and
            entry.item.step_index > 0 and
            symbolCanStartLookahead(first_sets, production.steps[entry.item.step_index].symbol, shift_symbol);
        const participates_as_reduce =
            entry.item.step_index == production.steps.len and
            item.containsLookahead(entry.lookaheads, shift_symbol);

        if (!participates_as_shift and !participates_as_reduce) continue;
        if (!productionIsAuxiliary(production)) return false;
        if (common_lhs) |lhs| {
            if (lhs != production.lhs) return false;
        } else {
            common_lhs = production.lhs;
        }
        saw_shift_item = saw_shift_item or participates_as_shift;
        saw_reduce_item = saw_reduce_item or participates_as_reduce;
    }

    return common_lhs != null and saw_shift_item and saw_reduce_item;
}

fn symbolCanStartLookahead(
    first_sets: ?first_sets_mod.FirstSets,
    symbol: syntax_ir.SymbolRef,
    lookahead: syntax_ir.SymbolRef,
) bool {
    if (symbolRefEql(symbol, lookahead)) return true;

    const sets = first_sets orelse return false;
    return switch (symbol) {
        .non_terminal => |index| if (index < sets.per_variable.len)
            symbolSetContainsRef(sets.per_variable[index], lookahead)
        else
            false,
        else => false,
    };
}

fn symbolSetContainsRef(symbol_set: first_sets_mod.SymbolSet, symbol: syntax_ir.SymbolRef) bool {
    return switch (symbol) {
        .terminal => |index| index < symbol_set.terminals.len() and symbol_set.terminals.get(index),
        .external => |index| index < symbol_set.externals.len() and symbol_set.externals.get(index),
        .end => symbol_set.includes_end,
        .non_terminal => false,
    };
}

fn productionIsRepeatAuxiliary(production: anytype) bool {
    if (!@hasField(@TypeOf(production), "lhs_is_repeat_auxiliary")) return false;
    return production.lhs_is_repeat_auxiliary;
}

fn productionIsAuxiliary(production: anytype) bool {
    if (!@hasField(@TypeOf(production), "lhs_kind")) return false;
    return production.lhs_kind == .auxiliary;
}

fn productionIsAugmented(production: anytype) bool {
    if (!@hasField(@TypeOf(production), "augmented")) return false;
    return production.augmented;
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
            if (left_index.? == right_index.?) return null;
            return left_index.? < right_index.?;
        }
    }

    return null;
}

fn resolveEqualPrecedenceByAssociativity(
    metadata: ProductionResolutionMetadata,
    reduce_action: actions.ParseAction,
    shift_action: actions.ParseAction,
) ?actions.ParseAction {
    if (metadata.associativity) |assoc| switch (assoc) {
        .left => return reduce_action,
        .right => return shift_action,
        .none => {},
    };
    return null;
}

fn extractShiftResolutionMetadata(
    productions: anytype,
    parse_state: state.ParseState,
    first_sets: ?first_sets_mod.FirstSets,
    shift_symbol: syntax_ir.SymbolRef,
) ?ShiftResolutionMetadata {
    var metadata = ShiftResolutionMetadata{};
    var saw_match = false;

    for (parse_state.items) |entry| {
        const parse_item = entry.item;
        if (parse_item.production_id >= productions.len) continue;
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) continue;
        if (parse_item.step_index == 0) continue;
        const step = production.steps[parse_item.step_index];
        if (!symbolCanStartLookahead(first_sets, step.symbol, shift_symbol)) continue;

        saw_match = true;
        metadata.resolution = mergeResolutionMetadata(
            metadata.resolution,
            extractShiftItemResolutionMetadata(production, parse_item.step_index),
        );
        if (productionIsRepeatAuxiliary(production)) {
            metadata.has_repeat_auxiliary_candidate = true;
        }
    }

    return if (saw_match) metadata else null;
}

fn extractShiftItemResolutionMetadata(production: anytype, step_index: u16) ProductionResolutionMetadata {
    var metadata = ProductionResolutionMetadata{};
    if (step_index == 0 or step_index > production.steps.len) return metadata;

    const step = production.steps[step_index - 1];
    switch (step.precedence) {
        .integer => |value| metadata.max_integer_precedence = value,
        .name => |value| metadata.named_precedence = value,
        .none => {},
    }
    if (step.associativity != .none) metadata.associativity = step.associativity;
    return metadata;
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

fn containsParseAction(haystack: []const actions.ParseAction, needle: actions.ParseAction) bool {
    for (haystack) |candidate| {
        if (std.meta.eql(candidate, needle)) return true;
    }
    return false;
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
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
        .reduce => |reduced| reduced.production_id == 2,
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
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

test "ResolvedActionTable exposes reduce conflict candidates" {
    const allocator = std.testing.allocator;
    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep = &.{},
    };
    const productions = [_]ProductionInfo{
        .{ .lhs = 0 },
        .{ .lhs = 1 },
        .{ .lhs = 2 },
    };
    const reduce_actions = [_]actions.ParseAction{
        actions.reduce(1),
        actions.reduce(2),
    };
    const shift_reduce_actions = [_]actions.ParseAction{
        .{ .shift = 3 },
        actions.reduce(2),
    };
    const resolved = ResolvedActionTable{
        .states = &[_]ResolvedStateActions{.{
            .state_id = 4,
            .groups = &[_]ResolvedActionGroup{
                .{
                    .symbol = .{ .terminal = 0 },
                    .candidate_actions = &reduce_actions,
                    .decision = .{ .unresolved = .reduce_reduce_deferred },
                },
                .{
                    .symbol = .{ .terminal = 1 },
                    .candidate_actions = &shift_reduce_actions,
                    .decision = .{ .unresolved = .shift_reduce },
                },
            },
        }},
    };

    const candidates = try resolved.expectedConflictCandidatesAlloc(allocator, productions[0..], &.{});
    defer conflict_resolution.freeConflictCandidates(allocator, candidates);

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqual(@as(state.StateId, 4), candidates[0].state_id);
    try std.testing.expectEqual(@as(usize, 2), candidates[0].members.len);
    try std.testing.expectEqual(@as(u32, 1), candidates[0].members[0].non_terminal);
    try std.testing.expectEqual(@as(u32, 2), candidates[0].members[1].non_terminal);
}

test "ResolvedActionTable reports unused expected conflict indexes" {
    const allocator = std.testing.allocator;
    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep = &.{},
    };
    const productions = [_]ProductionInfo{
        .{ .lhs = 0 },
        .{ .lhs = 1 },
        .{ .lhs = 2 },
    };
    const used_expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 2 },
        .{ .non_terminal = 1 },
    };
    const unused_expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 1 },
        .{ .non_terminal = 9 },
    };
    const reduce_actions = [_]actions.ParseAction{
        actions.reduce(1),
        actions.reduce(2),
    };
    const resolved = ResolvedActionTable{
        .states = &[_]ResolvedStateActions{.{
            .state_id = 4,
            .groups = &[_]ResolvedActionGroup{.{
                .symbol = .{ .terminal = 0 },
                .candidate_actions = &reduce_actions,
                .decision = .{ .unresolved = .reduce_reduce_expected },
            }},
        }},
    };

    const unused = try resolved.unusedExpectedConflictIndexesAlloc(
        allocator,
        &.{ &used_expected, &unused_expected },
        productions[0..],
        &.{},
    );
    defer allocator.free(unused);

    try std.testing.expectEqual(@as(usize, 1), unused.len);
    try std.testing.expectEqual(@as(usize, 1), unused[0]);
}

test "resolveActionTable marks declared shift reduce conflicts expected" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = &[_]syntax_ir.ProductionStep{.{ .symbol = .{ .terminal = 0 } }} },
        .{ .lhs = 1, .steps = &.{} },
    };
    const expected = [_]syntax_ir.SymbolRef{.{ .non_terminal = 1 }};

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, item.ParseItem.init(1, 0)),
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, item.ParseItem.init(2, 0), .{ .terminal = 0 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const parse_states = [_]state.ParseState{.{
        .id = 3,
        .items = &parse_items,
        .transitions = &.{},
    }};
    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{.{
            .state_id = 3,
            .groups = &[_]actions.ActionGroup{.{
                .symbol = .{ .terminal = 0 },
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 4 } },
                    .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
                },
            }},
        }},
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        &.{},
        &.{&expected},
        &parse_states,
        grouped,
    );
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(3)[0], .shift_reduce_expected, 2);
    try std.testing.expect(!resolved.hasBlockingUnresolvedDecisions());

    const unused = try resolved.unusedExpectedConflictIndexesAlloc(
        allocator,
        &.{&expected},
        productions[0..],
        &parse_states,
    );
    defer allocator.free(unused);
    try std.testing.expectEqual(@as(usize, 0), unused.len);
}

test "resolveActionTable derives shift reduce expected members from conflict items" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 7 } },
        .{ .symbol = .{ .terminal = 2 } },
    };
    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 7 } },
    };
    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 83, .steps = shift_steps[0..] },
        .{ .lhs = 48, .steps = reduce_steps[0..] },
    };
    const expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 48 },
        .{ .non_terminal = 83 },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 3, 0, item.ParseItem.init(1, 1)),
        try item.ParseItemSetEntry.withLookahead(allocator, 3, 0, item.ParseItem.init(2, 1), .{ .terminal = 2 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const conflict_items = [_]item.ParseItem{
        item.ParseItem.init(2, 1),
        item.ParseItem.init(1, 1),
    };
    const conflicts = [_]state.Conflict{.{
        .kind = .shift_reduce,
        .symbol = .{ .terminal = 2 },
        .items = conflict_items[0..],
    }};
    const parse_states = [_]state.ParseState{.{
        .id = 3,
        .items = &parse_items,
        .transitions = &.{},
        .conflicts = conflicts[0..],
    }};
    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{.{
            .state_id = 3,
            .groups = &[_]actions.ActionGroup{.{
                .symbol = .{ .terminal = 2 },
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 2 }, .action = .{ .shift = 4 } },
                    .{ .symbol = .{ .terminal = 2 }, .action = actions.reduce(2) },
                },
            }},
        }},
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        &.{},
        &.{&expected},
        &parse_states,
        grouped,
    );
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(3)[0], .shift_reduce_expected, 2);
    try std.testing.expect(!resolved.hasBlockingUnresolvedDecisions());
}

test "resolveActionTable uses item variable identity for inlined conflict members" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 7 } },
        .{ .symbol = .{ .terminal = 2 } },
    };
    const inlined_reduce_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 7 } },
    };
    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 83, .steps = shift_steps[0..] },
        .{ .lhs = 48, .steps = inlined_reduce_steps[0..] },
    };
    const expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 83 },
        .{ .non_terminal = 99 },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 3, 0, .{
            .variable_index = 83,
            .production_id = 1,
            .step_index = 1,
        }),
        try item.ParseItemSetEntry.withLookahead(allocator, 3, 0, .{
            .variable_index = 99,
            .production_id = 2,
            .step_index = 1,
        }, .{ .terminal = 2 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const conflict_items = [_]item.ParseItem{
        .{ .variable_index = 99, .production_id = 2, .step_index = 1 },
        .{ .variable_index = 83, .production_id = 1, .step_index = 1 },
    };
    const conflicts = [_]state.Conflict{.{
        .kind = .shift_reduce,
        .symbol = .{ .terminal = 2 },
        .items = conflict_items[0..],
    }};
    const parse_states = [_]state.ParseState{.{
        .id = 3,
        .items = &parse_items,
        .transitions = &.{},
        .conflicts = conflicts[0..],
    }};
    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{.{
            .state_id = 3,
            .groups = &[_]actions.ActionGroup{.{
                .symbol = .{ .terminal = 2 },
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 2 }, .action = .{ .shift = 4 } },
                    .{ .symbol = .{ .terminal = 2 }, .action = actions.reduce(2) },
                },
            }},
        }},
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        &.{},
        &.{&expected},
        &parse_states,
        grouped,
    );
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(3)[0], .shift_reduce_expected, 2);
    try std.testing.expect(!resolved.hasBlockingUnresolvedDecisions());
}

test "resolveActionTable marks multi-reduce shift conflicts expected" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 7 } },
        .{ .symbol = .{ .non_terminal = 9 } },
    };
    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 7 } },
    };
    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 83, .steps = shift_steps[0..] },
        .{ .lhs = 48, .steps = reduce_steps[0..] },
        .{ .lhs = 117, .steps = reduce_steps[0..] },
    };
    const expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 83 },
        .{ .non_terminal = 48 },
        .{ .non_terminal = 117 },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 8, 0, item.ParseItem.init(1, 1)),
        try item.ParseItemSetEntry.withLookahead(allocator, 8, 0, item.ParseItem.init(2, 1), .{ .terminal = 2 }),
        try item.ParseItemSetEntry.withLookahead(allocator, 8, 0, item.ParseItem.init(3, 1), .{ .terminal = 2 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const conflict_items = [_]item.ParseItem{
        item.ParseItem.init(2, 1),
        item.ParseItem.init(3, 1),
        item.ParseItem.init(1, 1),
    };
    const conflicts = [_]state.Conflict{.{
        .kind = .shift_reduce,
        .symbol = .{ .terminal = 2 },
        .items = conflict_items[0..],
    }};
    const parse_states = [_]state.ParseState{.{
        .id = 3,
        .items = &parse_items,
        .transitions = &.{},
        .conflicts = conflicts[0..],
    }};
    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{.{
            .state_id = 3,
            .groups = &[_]actions.ActionGroup{.{
                .symbol = .{ .terminal = 2 },
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 2 }, .action = .{ .shift = 4 } },
                    .{ .symbol = .{ .terminal = 2 }, .action = actions.reduce(2) },
                    .{ .symbol = .{ .terminal = 2 }, .action = actions.reduce(3) },
                },
            }},
        }},
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        &.{},
        &.{&expected},
        &parse_states,
        grouped,
    );
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(3)[0], .shift_reduce_expected, 3);
    try std.testing.expect(!resolved.hasBlockingUnresolvedDecisions());
}

test "resolveActionTable drops lower-precedence reductions before shift reduce resolution" {
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
                .{ .symbol = .{ .terminal = 1 }, .precedence = .{ .name = "low" } },
            },
        },
        .{
            .lhs = 2,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 2 }, .precedence = .{ .name = "high" } },
            },
        },
    };
    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{
        &[_]syntax_ir.PrecedenceEntry{
            .{ .name = "high" },
            .{ .name = "low" },
            .{ .symbol = .{ .terminal = 0 } },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{.{
            .state_id = 4,
            .groups = &[_]actions.ActionGroup{.{
                .symbol = .{ .terminal = 0 },
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 5 } },
                    .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                    .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
                },
            }},
        }},
    };

    const resolved = try resolveActionTableWithPrecedence(allocator, productions[0..], precedence_orderings[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    const group = resolved.groupsForState(4)[0];
    try std.testing.expectEqual(@as(usize, 1), group.candidate_actions.len);
    try expectChosenAction(group, actions.reduce(2));
}

test "resolveActionTable does not use positive dynamic precedence to remove shift from multiple reductions" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = &.{}, .dynamic_precedence = 3 },
        .{ .lhs = 2, .steps = &.{}, .dynamic_precedence = 3 },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{.{
            .state_id = 4,
            .groups = &[_]actions.ActionGroup{.{
                .symbol = .{ .terminal = 0 },
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 5 } },
                    .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                    .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
                },
            }},
        }},
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    const group = resolved.groupsForState(4)[0];
    try expectUnresolvedGroup(group, .multiple_candidates, 3);
    try std.testing.expectEqual(actions.ParseAction{ .shift = 5 }, group.candidate_actions[0]);
    try std.testing.expectEqual(actions.reduce(1), group.candidate_actions[1]);
    try std.testing.expectEqual(actions.reduce(2), group.candidate_actions[2]);
}

test "resolveActionTable does not use negative dynamic precedence to remove reductions" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = &.{}, .dynamic_precedence = -1 },
        .{ .lhs = 2, .steps = &.{}, .dynamic_precedence = -1 },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{.{
            .state_id = 4,
            .groups = &[_]actions.ActionGroup{.{
                .symbol = .{ .terminal = 0 },
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 5 } },
                    .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                    .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
                },
            }},
        }},
    };

    const resolved = try resolveActionTable(allocator, productions[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    const group = resolved.groupsForState(4)[0];
    try expectUnresolvedGroup(group, .multiple_candidates, 3);
    try std.testing.expectEqual(actions.ParseAction{ .shift = 5 }, group.candidate_actions[0]);
    try std.testing.expectEqual(actions.reduce(1), group.candidate_actions[1]);
    try std.testing.expectEqual(actions.reduce(2), group.candidate_actions[2]);
}

test "resolveActionTable expands auxiliary conflict members to parent symbols" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        lhs_kind: syntax_ir.VariableKind = .named,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const parent_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 20 } },
        .{ .symbol = .{ .terminal = 1 } },
    };
    const auxiliary_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 10, .steps = parent_steps[0..] },
        .{ .lhs = 20, .lhs_kind = .auxiliary, .steps = auxiliary_steps[0..] },
    };
    const expected = [_]syntax_ir.SymbolRef{.{ .non_terminal = 10 }};
    const auxiliary_parents = [_]syntax_ir.SymbolRef{.{ .non_terminal = 10 }};
    const auxiliary_symbols = [_]state.AuxiliarySymbolInfo{.{
        .auxiliary_symbol = .{ .non_terminal = 20 },
        .parent_symbols = auxiliary_parents[0..],
    }};

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 2, 0, item.ParseItem.init(1, 0)),
        try item.ParseItemSetEntry.withLookahead(allocator, 2, 0, item.ParseItem.init(2, 1), .{ .terminal = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const parse_states = [_]state.ParseState{.{
        .id = 3,
        .items = &parse_items,
        .transitions = &.{},
        .auxiliary_symbols = auxiliary_symbols[0..],
    }};
    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{.{
            .state_id = 3,
            .groups = &[_]actions.ActionGroup{.{
                .symbol = .{ .terminal = 1 },
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 4 } },
                    .{ .symbol = .{ .terminal = 1 }, .action = actions.reduce(2) },
                },
            }},
        }},
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        &.{},
        &.{&expected},
        &parse_states,
        grouped,
    );
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(3)[0], .shift_reduce_expected, 2);
    try std.testing.expect(!resolved.hasBlockingUnresolvedDecisions());
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
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

test "resolveActionTable chooses higher integer precedence reduce/reduce action" {
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
                .{ .symbol = .{ .terminal = 1 }, .precedence = .{ .integer = 1 } },
            },
        },
        .{
            .lhs = 2,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 2 }, .precedence = .{ .integer = 3 } },
            },
        },
    };

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 4,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
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

    try expectChosenAction(resolved.groupsForState(4)[0], actions.reduce(2));
    try std.testing.expectEqual(@as(usize, 1), resolved.groupsForState(4)[0].candidate_actions.len);
}

test "resolveActionTable chooses ordered named precedence reduce/reduce action" {
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
                .{ .symbol = .{ .terminal = 1 }, .precedence = .{ .name = "low" } },
            },
        },
        .{
            .lhs = 2,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 2 }, .precedence = .{ .name = "high" } },
            },
        },
    };
    const ordering = [_]syntax_ir.PrecedenceEntry{
        .{ .name = "high" },
        .{ .name = "low" },
    };
    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{ordering[0..]};

    const grouped = actions.GroupedActionTable{
        .states = &[_]actions.GroupedStateActions{
            .{
                .state_id = 4,
                .groups = &[_]actions.ActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .entries = &[_]actions.ActionEntry{
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(2) },
                        },
                    },
                },
            },
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

    try expectChosenAction(resolved.groupsForState(4)[0], actions.reduce(2));
    try std.testing.expectEqual(@as(usize, 1), resolved.groupsForState(4)[0].candidate_actions.len);
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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

    try expectChosenAction(resolved.groupsForState(3)[0], actions.reduce(1));
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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

    try expectChosenAction(resolved.groupsForState(3)[0], .{ .shift = 4 });
}

test "resolveActionTable compares shift parent symbols in precedence orderings" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = &.{} },
        .{
            .lhs = 2,
            .steps = &[_]syntax_ir.ProductionStep{
                .{ .symbol = .{ .terminal = 1 } },
                .{ .symbol = .{ .terminal = 0 } },
            },
        },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 2, 0, item.ParseItem.init(2, 1)),
        try item.ParseItemSetEntry.withLookahead(allocator, 2, 0, item.ParseItem.init(1, 0), .{ .terminal = 0 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const parse_states = [_]state.ParseState{
        .{
            .id = 3,
            .items = parse_items[0..],
            .transitions = &.{},
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{
        &[_]syntax_ir.PrecedenceEntry{
            .{ .symbol = .{ .non_terminal = 2 } },
            .{ .symbol = .{ .non_terminal = 1 } },
        },
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        precedence_orderings[0..],
        &.{},
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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

    try expectChosenAction(resolved.groupsForState(3)[0], actions.reduce(1));
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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

test "resolveActionTable uses associativity for unordered shift and reduce precedence" {
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
            .precedence = .{ .name = "assign" },
            .associativity = .right,
        },
    };
    const shift_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .precedence = .{ .name = "member" },
        },
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = reduce_steps[0..] },
        .{ .lhs = 2, .steps = shift_steps[0..] },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{
        &[_]syntax_ir.PrecedenceEntry{
            .{ .name = "member" },
            .{ .name = "call" },
        },
        &[_]syntax_ir.PrecedenceEntry{
            .{ .name = "assign" },
            .{ .symbol = .{ .non_terminal = 1 } },
        },
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        precedence_orderings[0..],
        &.{},
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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

test "resolveActionTable does not use positive dynamic precedence for shift/reduce resolution" {
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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

test "resolveActionTable does not use negative dynamic precedence for shift/reduce resolution" {
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
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

    try expectChosenAction(resolved.groupsForState(3)[0], actions.reduce(1));
}

test "resolveActionTable uses shift-side integer precedence from the current state when available" {
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
        .{
            .symbol = .{ .terminal = 0 },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
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
        .{
            .symbol = .{ .non_terminal = 1 },
            .precedence = .{ .name = "product" },
        },
        .{
            .symbol = .{ .terminal = 0 },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const precedence_orderings = [_][]const syntax_ir.PrecedenceEntry{
        &[_]syntax_ir.PrecedenceEntry{
            .{ .name = "product" },
            .{ .name = "sum" },
        },
    };

    const resolved = try resolveActionTableWithContext(
        allocator,
        productions[0..],
        precedence_orderings[0..],
        &.{},
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectChosenAction(resolved.groupsForState(6)[0], .{ .shift = 7 });
}

test "resolveActionTable leaves repeat auxiliary marker conflicts to normal resolution" {
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(6)[0], .shift_reduce, 2);
}

test "resolveActionTable preserves repeat auxiliary reductions before shift filtering" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        lhs_kind: syntax_ir.VariableKind = .named,
        steps: []const syntax_ir.ProductionStep,
        lhs_is_repeat_auxiliary: bool = false,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const repeat_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .lhs_kind = .auxiliary, .steps = repeat_steps[0..], .lhs_is_repeat_auxiliary = true },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 2 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 6, .items = parse_items[0..], .transitions = &.{}, .conflicts = &.{} },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    const group = resolved.groupsForState(6)[0];
    try expectUnresolvedGroup(group, .auxiliary_repeat, 2);
    try std.testing.expect(group.shift_is_repetition);
}

test "resolveActionTable keeps same auxiliary repeat conflicts with repetition metadata" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        lhs_kind: syntax_ir.VariableKind = .named,
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
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .lhs_kind = .auxiliary, .steps = reduce_steps[0..] },
        .{ .lhs = 1, .lhs_kind = .auxiliary, .steps = shift_steps[0..] },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 2, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 6, .items = parse_items[0..], .transitions = &.{}, .conflicts = &.{} },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    const group = resolved.groupsForState(6)[0];
    try expectUnresolvedGroup(group, .auxiliary_repeat, 2);
    try std.testing.expect(group.shift_is_repetition);
    try std.testing.expect(!resolved.hasBlockingUnresolvedDecisions());
}

test "hasSameAuxiliaryRepeatConflictWithFirstSets matches upstream FIRST-set rule" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        lhs_kind: syntax_ir.VariableKind = .named,
        steps: []const syntax_ir.ProductionStep,
        lhs_is_repeat_auxiliary: bool = false,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    const child_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .lhs_kind = .auxiliary, .steps = reduce_steps[0..] },
        .{ .lhs = 1, .lhs_kind = .auxiliary, .steps = shift_steps[0..] },
        .{ .lhs = 2, .lhs_kind = .named, .steps = child_steps[0..] },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 2, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 2, 0, .{ .production_id = 2, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 6, .items = parse_items[0..], .transitions = &.{}, .conflicts = &.{} },
    };

    const empty_terms = [_]bool{ false, false };
    const child_terms = [_]bool{ true, false };
    var per_variable = [_]first_sets_mod.SymbolSet{
        .{
            .terminals = try first_sets_mod.SymbolBits.initFromSlice(allocator, empty_terms[0..]),
            .externals = try first_sets_mod.SymbolBits.initEmpty(allocator, 0),
        },
        .{
            .terminals = try first_sets_mod.SymbolBits.initFromSlice(allocator, empty_terms[0..]),
            .externals = try first_sets_mod.SymbolBits.initEmpty(allocator, 0),
        },
        .{
            .terminals = try first_sets_mod.SymbolBits.initFromSlice(allocator, child_terms[0..]),
            .externals = try first_sets_mod.SymbolBits.initEmpty(allocator, 0),
        },
    };
    defer for (per_variable) |set| {
        var terminals = set.terminals;
        var externals = set.externals;
        terminals.deinit(allocator);
        externals.deinit(allocator);
    };
    const first_sets = first_sets_mod.FirstSets{
        .terminals_len = 2,
        .externals_len = 0,
        .per_variable = per_variable[0..],
    };

    try std.testing.expect(hasSameAuxiliaryRepeatConflictWithFirstSets(
        productions[0..],
        parse_states[0],
        first_sets,
        .{ .terminal = 0 },
    ));
}

test "resolveActionTable leaves mixed auxiliary repeat conflicts unresolved" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        lhs_kind: syntax_ir.VariableKind = .named,
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
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .lhs_kind = .auxiliary, .steps = reduce_steps[0..] },
        .{ .lhs = 2, .lhs_kind = .auxiliary, .steps = shift_steps[0..] },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 2, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 6, .items = parse_items[0..], .transitions = &.{}, .conflicts = &.{} },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(6)[0], .shift_reduce, 2);
}

test "resolveActionTable leaves common non-auxiliary repeat-shaped conflicts unresolved" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        lhs_kind: syntax_ir.VariableKind = .named,
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
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .lhs_kind = .named, .steps = reduce_steps[0..] },
        .{ .lhs = 1, .lhs_kind = .named, .steps = shift_steps[0..] },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 2, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 6, .items = parse_items[0..], .transitions = &.{}, .conflicts = &.{} },
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(6)[0], .shift_reduce, 2);
}

test "resolveActionTable leaves repeat auxiliary continuation conflicts to normal resolution" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        lhs_is_repeat_auxiliary: bool = false,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const wrapper_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    const repeat_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = wrapper_steps[0..] },
        .{ .lhs = 2, .steps = repeat_steps[0..], .lhs_is_repeat_auxiliary = true },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 2, .step_index = 1 }, .{ .terminal = 0 }),
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(6)[0], .shift_reduce, 2);
}

test "resolveActionTable leaves repeat auxiliary continuation with wrapper reductions unresolved" {
    const allocator = std.testing.allocator;

    const ProductionInfo = struct {
        lhs: u32,
        steps: []const syntax_ir.ProductionStep,
        lhs_is_repeat_auxiliary: bool = false,
        augmented: bool = false,
        dynamic_precedence: i32 = 0,
    };

    const wrapper_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .non_terminal = 3 } },
    };
    const wrapper_seq_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    const repeat_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .terminal = 0 } },
    };

    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = wrapper_seq_steps[0..] },
        .{ .lhs = 2, .steps = wrapper_steps[0..] },
        .{ .lhs = 3, .steps = repeat_steps[0..], .lhs_is_repeat_auxiliary = true },
    };

    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 2, .step_index = 2 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 3, .step_index = 1 }, .{ .terminal = 0 }),
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
                            .{ .symbol = .{ .terminal = 0 }, .action = actions.reduce(1) },
                        },
                    },
                },
            },
        },
    };

    const resolved = try resolveActionTableWithContext(allocator, productions[0..], &.{}, &.{}, parse_states[0..], grouped);
    defer {
        for (resolved.states) |resolved_state| {
            for (resolved_state.groups) |group| allocator.free(group.candidate_actions);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try expectUnresolvedGroup(resolved.groupsForState(6)[0], .shift_reduce, 2);
}

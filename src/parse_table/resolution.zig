const std = @import("std");
const actions = @import("actions.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const ResolutionKind = enum {
    chosen,
    unresolved,
};

pub const UnresolvedReason = enum {
    multiple_candidates,
    shift_reduce,
    reduce_reduce_deferred,
    unsupported_action_mix,
};

pub const ResolvedActionGroup = struct {
    symbol: @import("../ir/syntax_grammar.zig").SymbolRef,
    kind: ResolutionKind,
    candidates: []const actions.ActionEntry,
    chosen: ?actions.ParseAction = null,
    reason: ?UnresolvedReason = null,
};

pub const ResolvedStateActions = struct {
    state_id: state.StateId,
    groups: []const ResolvedActionGroup,
};

pub const ResolvedActionTable = struct {
    states: []const ResolvedStateActions,

    pub fn groupsForState(self: ResolvedActionTable, state_id: state.StateId) []const ResolvedActionGroup {
        for (self.states) |resolved| {
            if (resolved.state_id == state_id) return resolved.groups;
        }
        return &.{};
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
                .kind = if (decision.chosen != null) .chosen else .unresolved,
                .candidates = try allocator.dupe(actions.ActionEntry, group.entries),
                .chosen = decision.chosen,
                .reason = decision.reason,
            };
        }
        states[state_index] = .{
            .state_id = grouped_state.state_id,
            .groups = groups,
        };
    }
    return .{ .states = states };
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

    return null;
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

    for (parse_state.items) |parse_item| {
        if (parse_item.production_id >= productions.len) continue;
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) continue;
        const step = production.steps[parse_item.step_index];
        if (!symbolRefEql(step.symbol, shift_symbol)) continue;

        saw_match = true;

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

    return if (saw_match) metadata else null;
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(@as(usize, 1), resolved.groupsForState(1).len);
    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(1)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(1)[0].chosen.?) { .shift => |id| id == 3, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.unresolved, resolved.groupsForState(2)[0].kind);
    try std.testing.expect(resolved.groupsForState(2)[0].chosen == null);
    try std.testing.expectEqual(UnresolvedReason.shift_reduce, resolved.groupsForState(2)[0].reason.?);
    try std.testing.expectEqual(@as(usize, 2), resolved.groupsForState(2)[0].candidates.len);
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.unresolved, resolved.groupsForState(4)[0].kind);
    try std.testing.expectEqual(@as(?actions.ParseAction, null), resolved.groupsForState(4)[0].chosen);
    try std.testing.expectEqual(UnresolvedReason.reduce_reduce_deferred, resolved.groupsForState(4)[0].reason.?);
    try std.testing.expectEqual(@as(usize, 2), resolved.groupsForState(4)[0].candidates.len);
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .reduce => |id| id == 1, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .reduce => |id| id == 1, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .shift => |id| id == 4, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .shift => |id| id == 4, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .reduce => |id| id == 1, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .shift => |id| id == 4, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.unresolved, resolved.groupsForState(3)[0].kind);
    try std.testing.expectEqual(@as(?actions.ParseAction, null), resolved.groupsForState(3)[0].chosen);
    try std.testing.expectEqual(UnresolvedReason.shift_reduce, resolved.groupsForState(3)[0].reason.?);
    try std.testing.expectEqual(@as(usize, 2), resolved.groupsForState(3)[0].candidates.len);
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .reduce => |id| id == 1, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .shift => |id| id == 4, else => false });
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(3)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(3)[0].chosen.?) { .reduce => |id| id == 1, else => false });
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

    const parse_items = [_]item.ParseItem{
        .{
            .production_id = 1,
            .step_index = 1,
            .lookahead = .{ .terminal = 0 },
        },
        .{
            .production_id = 2,
            .step_index = 1,
            .lookahead = null,
        },
    };
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
            for (resolved_state.groups) |group| allocator.free(group.candidates);
            allocator.free(resolved_state.groups);
        }
        allocator.free(resolved.states);
    }

    try std.testing.expectEqual(ResolutionKind.chosen, resolved.groupsForState(6)[0].kind);
    try std.testing.expect(switch (resolved.groupsForState(6)[0].chosen.?) { .shift => |id| id == 7, else => false });
}

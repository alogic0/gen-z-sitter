const std = @import("std");
const actions = @import("actions.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const ResolutionKind = enum {
    chosen,
    unresolved,
};

pub const ResolvedActionGroup = struct {
    symbol: @import("../ir/syntax_grammar.zig").SymbolRef,
    kind: ResolutionKind,
    candidates: []const actions.ActionEntry,
    chosen: ?actions.ParseAction = null,
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
    const states = try allocator.alloc(ResolvedStateActions, grouped_table.states.len);
    for (grouped_table.states, 0..) |grouped_state, state_index| {
        const groups = try allocator.alloc(ResolvedActionGroup, grouped_state.groups.len);
        for (grouped_state.groups, 0..) |group, group_index| {
            const chosen = chooseResolvedAction(productions, group.entries);
            groups[group_index] = .{
                .symbol = group.symbol,
                .kind = if (chosen != null) .chosen else .unresolved,
                .candidates = try allocator.dupe(actions.ActionEntry, group.entries),
                .chosen = chosen,
            };
        }
        states[state_index] = .{
            .state_id = grouped_state.state_id,
            .groups = groups,
        };
    }
    return .{ .states = states };
}

fn chooseResolvedAction(
    productions: anytype,
    candidates: []const actions.ActionEntry,
) ?actions.ParseAction {
    if (candidates.len == 1) return candidates[0].action;

    if (candidates.len == 2) {
        const first = candidates[0].action;
        const second = candidates[1].action;

        if (isShift(first) and isReduce(second)) {
            return resolveShiftReduce(productions, first, second);
        }
        if (isReduce(first) and isShift(second)) {
            return resolveShiftReduce(productions, second, first);
        }
    }

    return null;
}

fn resolveShiftReduce(
    productions: anytype,
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

    if (metadata.dynamic_precedence > 0) return reduce_action;

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
            else => {},
        }
        if (step.associativity != .none and metadata.associativity == null) {
            metadata.associativity = step.associativity;
        }
    }
    return metadata;
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

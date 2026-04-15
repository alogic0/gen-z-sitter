const std = @import("std");
const actions = @import("actions.zig");
const state = @import("state.zig");

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

pub fn resolveActionTableSkeleton(
    allocator: std.mem.Allocator,
    grouped_table: actions.GroupedActionTable,
) std.mem.Allocator.Error!ResolvedActionTable {
    const states = try allocator.alloc(ResolvedStateActions, grouped_table.states.len);
    for (grouped_table.states, 0..) |grouped_state, state_index| {
        const groups = try allocator.alloc(ResolvedActionGroup, grouped_state.groups.len);
        for (grouped_state.groups, 0..) |group, group_index| {
            groups[group_index] = .{
                .symbol = group.symbol,
                .kind = if (group.entries.len == 1) .chosen else .unresolved,
                .candidates = try allocator.dupe(actions.ActionEntry, group.entries),
                .chosen = if (group.entries.len == 1) group.entries[0].action else null,
            };
        }
        states[state_index] = .{
            .state_id = grouped_state.state_id,
            .groups = groups,
        };
    }
    return .{ .states = states };
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

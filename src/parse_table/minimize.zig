const std = @import("std");
const resolution = @import("resolution.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const MinimizeResult = struct {
    states: []state.ParseState,
    resolved_actions: resolution.ResolvedActionTable,
    merged_count: usize,
};

pub fn minimizeAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
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
    for (states_in) |s| if (s.id > max_id) {
        max_id = s.id;
    };

    const id_to_idx = try allocator.alloc(usize, max_id + 1);
    defer allocator.free(id_to_idx);
    @memset(id_to_idx, std.math.maxInt(usize));
    for (states_in, 0..) |s, idx| id_to_idx[s.id] = idx;

    const class_of = try allocator.alloc(u32, n);
    defer allocator.free(class_of);
    @memset(class_of, 0);

    var changed = true;
    while (changed) {
        changed = false;

        var iter_arena = std.heap.ArenaAllocator.init(allocator);
        defer iter_arena.deinit();
        const ia = iter_arena.allocator();

        const sigs = try ia.alloc([]const u8, n);
        for (states_in, 0..) |s, idx| {
            sigs[idx] = try buildSig(ia, s, resolved_in, class_of, id_to_idx);
        }

        const sorted_idxs = try ia.alloc(usize, n);
        for (sorted_idxs, 0..) |*v, i| v.* = i;

        const SortCtx = struct {
            class_of: []const u32,
            sigs: []const []const u8,

            fn lt(ctx: @This(), a: usize, b: usize) bool {
                if (ctx.class_of[a] != ctx.class_of[b]) return ctx.class_of[a] < ctx.class_of[b];
                return std.mem.lessThan(u8, ctx.sigs[a], ctx.sigs[b]);
            }
        };
        std.mem.sort(usize, sorted_idxs, SortCtx{ .class_of = class_of, .sigs = sigs }, SortCtx.lt);

        const new_class_of = try ia.alloc(u32, n);
        var new_class: u32 = 0;
        for (sorted_idxs, 0..) |idx, sort_pos| {
            if (sort_pos > 0) {
                const prev_idx = sorted_idxs[sort_pos - 1];
                const class_changed = class_of[idx] != class_of[prev_idx];
                const sig_changed = !std.mem.eql(u8, sigs[idx], sigs[prev_idx]);
                if (class_changed or sig_changed) new_class += 1;
            }
            new_class_of[idx] = new_class;
        }

        if (!std.mem.eql(u32, class_of, new_class_of)) {
            changed = true;
            @memcpy(class_of, new_class_of);
        }
    }

    var class_count: u32 = 0;
    for (class_of) |c| if (c >= class_count) {
        class_count = c + 1;
    };

    const canonical_ids = try allocator.alloc(state.StateId, class_count);
    defer allocator.free(canonical_ids);
    @memset(canonical_ids, std.math.maxInt(state.StateId));
    for (states_in, 0..) |s, idx| {
        const cls = class_of[idx];
        if (s.id < canonical_ids[cls]) canonical_ids[cls] = s.id;
    }

    const id_remap = try allocator.alloc(state.StateId, max_id + 1);
    defer allocator.free(id_remap);
    @memset(id_remap, std.math.maxInt(state.StateId));
    for (states_in, 0..) |s, idx| {
        id_remap[s.id] = canonical_ids[class_of[idx]];
    }

    var canonical_count: usize = 0;
    for (states_in) |s| {
        if (id_remap[s.id] == s.id) canonical_count += 1;
    }

    const out_states = try allocator.alloc(state.ParseState, canonical_count);
    var out_idx: usize = 0;
    for (states_in) |s| {
        if (id_remap[s.id] != s.id) continue;

        const new_transitions = try allocator.alloc(state.Transition, s.transitions.len);
        for (s.transitions, 0..) |t, ti| {
            new_transitions[ti] = .{
                .symbol = t.symbol,
                .state = id_remap[t.state],
            };
        }

        out_states[out_idx] = .{
            .id = s.id,
            .core_id = s.core_id,
            .lex_state_id = s.lex_state_id,
            .items = s.items,
            .transitions = new_transitions,
            .conflicts = s.conflicts,
        };
        out_idx += 1;
    }

    const out_resolved = try allocator.alloc(resolution.ResolvedStateActions, canonical_count);
    var out_res_idx: usize = 0;
    for (states_in) |s| {
        if (id_remap[s.id] != s.id) continue;

        var found_rs: ?resolution.ResolvedStateActions = null;
        for (resolved_in.states) |rs| {
            if (rs.state_id == s.id) {
                found_rs = rs;
                break;
            }
        }

        const rs = found_rs orelse {
            out_resolved[out_res_idx] = .{ .state_id = s.id, .groups = &.{} };
            out_res_idx += 1;
            continue;
        };

        var needs_remap = false;
        for (rs.groups) |group| {
            switch (group.decision) {
                .chosen => |action| switch (action) {
                    .shift => |target| if (target <= max_id and id_remap[target] != target) {
                        needs_remap = true;
                        break;
                    },
                    else => {},
                },
                .unresolved => {},
            }
        }

        const new_groups = if (needs_remap) blk: {
            const groups = try allocator.alloc(resolution.ResolvedActionGroup, rs.groups.len);
            for (rs.groups, 0..) |group, gi| {
                groups[gi] = .{
                    .symbol = group.symbol,
                    .candidate_actions = group.candidate_actions,
                    .decision = switch (group.decision) {
                        .chosen => |action| .{
                            .chosen = switch (action) {
                                .shift => |target| .{
                                    .shift = if (target <= max_id) id_remap[target] else target,
                                },
                                else => action,
                            },
                        },
                        .unresolved => group.decision,
                    },
                };
            }
            break :blk groups;
        } else rs.groups;

        out_resolved[out_res_idx] = .{
            .state_id = rs.state_id,
            .groups = new_groups,
        };
        out_res_idx += 1;
    }

    return .{
        .states = out_states,
        .resolved_actions = .{ .states = out_resolved[0..out_res_idx] },
        .merged_count = n - canonical_count,
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

    for (resolved.groupsForState(s.id)) |group| {
        const sym_tag: u8 = switch (group.symbol) {
            .terminal => 1,
            .external => 2,
            .non_terminal => continue,
        };
        const sym_idx: u32 = switch (group.symbol) {
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
                    .kind = 4,
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
    );
    defer std.testing.allocator.free(result.states);
    defer std.testing.allocator.free(result.resolved_actions.states);

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

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions);
    defer {
        for (result.states) |s| allocator.free(s.transitions);
        allocator.free(result.states);
        allocator.free(result.resolved_actions.states);
    }

    try std.testing.expectEqual(@as(usize, 3), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);

    // State 0's non-terminal goto to former state 2 should now point to canonical state 1
    var found_state_0 = false;
    for (result.states) |s| {
        if (s.id != 0) continue;
        found_state_0 = true;
        try std.testing.expectEqual(@as(usize, 3), s.transitions.len);
        for (s.transitions) |t| {
            switch (t.symbol) {
                .non_terminal => |idx| {
                    // Both non-terminal gotos should point to state 1 (canonical)
                    _ = idx;
                    try std.testing.expectEqual(@as(state.StateId, 1), t.state);
                },
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

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions);
    defer {
        for (result.states) |s| allocator.free(s.transitions);
        allocator.free(result.states);
        allocator.free(result.resolved_actions.states);
    }

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

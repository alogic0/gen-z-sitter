const std = @import("std");
const actions = @import("actions.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const ConflictCandidate = struct {
    state_id: state.StateId,
    lookahead: syntax_ir.SymbolRef,
    members: []const syntax_ir.SymbolRef,
};

pub const ConflictMatch = struct {
    candidate_index: usize,
    expected_index: usize,
};

pub const ExpectedConflictPolicy = struct {
    expected_conflicts: []const []const syntax_ir.SymbolRef,

    pub fn findExpectedConflict(
        self: ExpectedConflictPolicy,
        candidate: ConflictCandidate,
    ) ?usize {
        for (self.expected_conflicts, 0..) |expected, index| {
            if (conflictSetsMatch(expected, candidate.members)) return index;
        }
        return null;
    }

    pub fn isExpected(self: ExpectedConflictPolicy, candidate: ConflictCandidate) bool {
        return self.findExpectedConflict(candidate) != null;
    }

    pub fn matchesAlloc(
        self: ExpectedConflictPolicy,
        allocator: std.mem.Allocator,
        candidates: []const ConflictCandidate,
    ) std.mem.Allocator.Error![]const ConflictMatch {
        var result = std.array_list.Managed(ConflictMatch).init(allocator);
        defer result.deinit();

        for (candidates, 0..) |candidate, candidate_index| {
            if (self.findExpectedConflict(candidate)) |expected_index| {
                try result.append(.{
                    .candidate_index = candidate_index,
                    .expected_index = expected_index,
                });
            }
        }

        return try result.toOwnedSlice();
    }

    pub fn unusedExpectedIndexesAlloc(
        self: ExpectedConflictPolicy,
        allocator: std.mem.Allocator,
        candidates: []const ConflictCandidate,
    ) std.mem.Allocator.Error![]const usize {
        var used = try allocator.alloc(bool, self.expected_conflicts.len);
        defer allocator.free(used);
        @memset(used, false);

        for (candidates) |candidate| {
            if (self.findExpectedConflict(candidate)) |expected_index| {
                used[expected_index] = true;
            }
        }

        var result = std.array_list.Managed(usize).init(allocator);
        defer result.deinit();
        for (used, 0..) |is_used, index| {
            if (!is_used) try result.append(index);
        }
        return try result.toOwnedSlice();
    }
};

pub fn conflictSetsMatch(
    expected: []const syntax_ir.SymbolRef,
    candidate: []const syntax_ir.SymbolRef,
) bool {
    if (expected.len != candidate.len) return false;
    for (expected) |symbol| {
        if (!containsSymbol(candidate, symbol)) return false;
    }
    for (candidate) |symbol| {
        if (!containsSymbol(expected, symbol)) return false;
    }
    return true;
}

pub fn reduceConflictCandidate(
    members_buffer: []syntax_ir.SymbolRef,
    state_id: state.StateId,
    lookahead: syntax_ir.SymbolRef,
    productions: anytype,
    candidate_actions: []const actions.ParseAction,
) ?ConflictCandidate {
    if (candidate_actions.len == 0) return null;
    if (candidate_actions.len > members_buffer.len) return null;

    var member_count: usize = 0;
    for (candidate_actions) |action| {
        const production_id = switch (action) {
            .reduce => |id| id,
            else => return null,
        };
        if (production_id >= productions.len) return null;
        members_buffer[member_count] = .{ .non_terminal = productions[production_id].lhs };
        member_count += 1;
    }

    return .{
        .state_id = state_id,
        .lookahead = lookahead,
        .members = members_buffer[0..member_count],
    };
}

pub fn reduceConflictIsExpected(
    expected_conflicts: []const []const syntax_ir.SymbolRef,
    state_id: state.StateId,
    lookahead: syntax_ir.SymbolRef,
    productions: anytype,
    candidate_actions: []const actions.ParseAction,
) bool {
    var members_buffer: [32]syntax_ir.SymbolRef = undefined;
    const candidate = reduceConflictCandidate(
        &members_buffer,
        state_id,
        lookahead,
        productions,
        candidate_actions,
    ) orelse return false;
    const policy = ExpectedConflictPolicy{ .expected_conflicts = expected_conflicts };
    return policy.isExpected(candidate);
}

fn containsSymbol(values: []const syntax_ir.SymbolRef, needle: syntax_ir.SymbolRef) bool {
    for (values) |value| {
        if (symbolRefEql(value, needle)) return true;
    }
    return false;
}

fn symbolRefEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
        .end => switch (b) {
            .end => true,
            else => false,
        },
        .non_terminal => |left| switch (b) {
            .non_terminal => |right| left == right,
            else => false,
        },
        .terminal => |left| switch (b) {
            .terminal => |right| left == right,
            else => false,
        },
        .external => |left| switch (b) {
            .external => |right| left == right,
            else => false,
        },
    };
}

test "conflictSetsMatch ignores member order" {
    const expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 1 },
        .{ .non_terminal = 2 },
    };
    const candidate = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 2 },
        .{ .non_terminal = 1 },
    };

    try std.testing.expect(conflictSetsMatch(&expected, &candidate));
}

test "ExpectedConflictPolicy rejects undeclared conflict candidates" {
    const expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 1 },
        .{ .non_terminal = 2 },
    };
    const candidate_members = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 1 },
        .{ .non_terminal = 3 },
    };
    const policy = ExpectedConflictPolicy{
        .expected_conflicts = &.{&expected},
    };
    const candidate = ConflictCandidate{
        .state_id = 7,
        .lookahead = .{ .terminal = 0 },
        .members = &candidate_members,
    };

    try std.testing.expect(!policy.isExpected(candidate));
    try std.testing.expectEqual(@as(?usize, null), policy.findExpectedConflict(candidate));
}

test "ExpectedConflictPolicy collects unused expected conflicts" {
    const used_expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 1 },
        .{ .non_terminal = 2 },
    };
    const unused_expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 3 },
        .{ .non_terminal = 4 },
    };
    const candidate_members = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 2 },
        .{ .non_terminal = 1 },
    };
    const candidates = [_]ConflictCandidate{.{
        .state_id = 7,
        .lookahead = .{ .terminal = 0 },
        .members = &candidate_members,
    }};
    const policy = ExpectedConflictPolicy{
        .expected_conflicts = &.{ &used_expected, &unused_expected },
    };

    const matches = try policy.matchesAlloc(std.testing.allocator, &candidates);
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].candidate_index);
    try std.testing.expectEqual(@as(usize, 0), matches[0].expected_index);

    const unused = try policy.unusedExpectedIndexesAlloc(std.testing.allocator, &candidates);
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqual(@as(usize, 1), unused.len);
    try std.testing.expectEqual(@as(usize, 1), unused[0]);
}

test "reduceConflictIsExpected derives members from reduce actions" {
    const Production = struct {
        lhs: u32,
    };
    const productions = [_]Production{
        .{ .lhs = 0 },
        .{ .lhs = 1 },
        .{ .lhs = 2 },
    };
    const expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 2 },
        .{ .non_terminal = 1 },
    };
    const candidate_actions = [_]actions.ParseAction{
        .{ .reduce = 1 },
        .{ .reduce = 2 },
    };

    try std.testing.expect(reduceConflictIsExpected(
        &.{&expected},
        7,
        .{ .terminal = 0 },
        productions[0..],
        &candidate_actions,
    ));
}

test "reduceConflictIsExpected rejects mixed action groups" {
    const Production = struct {
        lhs: u32,
    };
    const productions = [_]Production{
        .{ .lhs = 0 },
        .{ .lhs = 1 },
    };
    const expected = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 1 },
        .{ .non_terminal = 2 },
    };
    const candidate_actions = [_]actions.ParseAction{
        .{ .reduce = 1 },
        .{ .shift = 3 },
    };

    try std.testing.expect(!reduceConflictIsExpected(
        &.{&expected},
        7,
        .{ .terminal = 0 },
        productions[0..],
        &candidate_actions,
    ));
}

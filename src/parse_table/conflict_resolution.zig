const std = @import("std");
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

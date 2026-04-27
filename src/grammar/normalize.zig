const std = @import("std");
const ir = @import("../ir/grammar_ir.zig");
const ir_rules = @import("../ir/rules.zig");
const ir_symbols = @import("../ir/symbols.zig");

pub fn normalizeSymbolList(
    allocator: std.mem.Allocator,
    input: []const ir_symbols.SymbolId,
) ![]const ir_symbols.SymbolId {
    const result = try allocator.alloc(ir_symbols.SymbolId, input.len);
    std.mem.copyForwards(ir_symbols.SymbolId, result, input);
    std.mem.sort(ir_symbols.SymbolId, result, {}, lessThanSymbol);
    return dedupeSortedSymbols(allocator, result);
}

pub fn normalizeConflictSets(
    allocator: std.mem.Allocator,
    input: []const ir.ConflictSet,
) ![]const ir.ConflictSet {
    var normalized = std.array_list.Managed(ir.ConflictSet).init(allocator);
    defer normalized.deinit();

    for (input) |conflict_set| {
        const members = try normalizeSymbolList(allocator, conflict_set);
        if (members.len == 0) {
            allocator.free(members);
            continue;
        }
        if (containsConflictSet(normalized.items, members)) {
            allocator.free(members);
            continue;
        }
        try normalized.append(members);
    }

    std.mem.sort(ir.ConflictSet, normalized.items, {}, lessThanConflictSet);
    return try normalized.toOwnedSlice();
}

pub fn normalizeReservedWordSets(
    allocator: std.mem.Allocator,
    input: []const ir.ReservedWordSet,
) ![]const ir.ReservedWordSet {
    var result = try allocator.alloc(ir.ReservedWordSet, input.len);
    for (input, 0..) |set, i| {
        result[i] = .{
            .context_name = set.context_name,
            .members = try normalizeRuleList(allocator, set.members),
        };
    }
    std.mem.sort(ir.ReservedWordSet, result, {}, lessThanReservedWordSet);
    return dedupeReservedWordSets(allocator, result);
}

pub fn normalizePrecedenceOrderings(
    allocator: std.mem.Allocator,
    input: []const ir.PrecedenceOrdering,
) ![]const ir.PrecedenceOrdering {
    var result = std.array_list.Managed(ir.PrecedenceOrdering).init(allocator);
    defer result.deinit();

    for (input) |ordering| {
        const normalized_ordering = try normalizePrecedenceOrdering(allocator, ordering);
        if (normalized_ordering.len == 0) {
            allocator.free(normalized_ordering);
            continue;
        }
        if (containsPrecedenceOrdering(result.items, normalized_ordering)) {
            allocator.free(normalized_ordering);
            continue;
        }
        try result.append(normalized_ordering);
    }

    return try result.toOwnedSlice();
}

pub fn normalizeRuleList(
    allocator: std.mem.Allocator,
    input: []const ir_rules.RuleId,
) ![]const ir_rules.RuleId {
    const result = try allocator.alloc(ir_rules.RuleId, input.len);
    std.mem.copyForwards(ir_rules.RuleId, result, input);
    std.mem.sort(ir_rules.RuleId, result, {}, std.sort.asc(ir_rules.RuleId));
    return dedupeSortedRules(allocator, result);
}

fn dedupeSortedSymbols(
    allocator: std.mem.Allocator,
    sorted: []ir_symbols.SymbolId,
) ![]const ir_symbols.SymbolId {
    if (sorted.len == 0) return sorted;

    var write_index: usize = 1;
    var previous = sorted[0];
    for (sorted[1..]) |current| {
        if (!symbolEql(previous, current)) {
            sorted[write_index] = current;
            write_index += 1;
            previous = current;
        }
    }
    return try allocator.realloc(sorted, write_index);
}

fn dedupeSortedRules(
    allocator: std.mem.Allocator,
    sorted: []ir_rules.RuleId,
) ![]const ir_rules.RuleId {
    if (sorted.len == 0) return sorted;

    var write_index: usize = 1;
    var previous = sorted[0];
    for (sorted[1..]) |current| {
        if (previous != current) {
            sorted[write_index] = current;
            write_index += 1;
            previous = current;
        }
    }
    return try allocator.realloc(sorted, write_index);
}

fn dedupeReservedWordSets(
    allocator: std.mem.Allocator,
    sorted: []ir.ReservedWordSet,
) ![]const ir.ReservedWordSet {
    if (sorted.len == 0) return sorted;

    var write_index: usize = 1;
    var previous = sorted[0];
    for (sorted[1..]) |current| {
        if (!reservedWordSetEql(previous, current)) {
            sorted[write_index] = current;
            write_index += 1;
            previous = current;
        }
    }
    return try allocator.realloc(sorted, write_index);
}

fn containsConflictSet(existing: []const ir.ConflictSet, candidate: []const ir_symbols.SymbolId) bool {
    for (existing) |conflict_set| {
        if (conflictSetEql(conflict_set, candidate)) return true;
    }
    return false;
}

fn containsPrecedenceOrdering(existing: []const ir.PrecedenceOrdering, candidate: ir.PrecedenceOrdering) bool {
    for (existing) |ordering| {
        if (precedenceOrderingEql(ordering, candidate)) return true;
    }
    return false;
}

fn lessThanSymbol(_: void, lhs: ir_symbols.SymbolId, rhs: ir_symbols.SymbolId) bool {
    if (@intFromEnum(lhs.kind) != @intFromEnum(rhs.kind)) {
        return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    }
    return lhs.index < rhs.index;
}

fn lessThanConflictSet(_: void, lhs: ir.ConflictSet, rhs: ir.ConflictSet) bool {
    const min_len = @min(lhs.len, rhs.len);
    for (lhs[0..min_len], rhs[0..min_len]) |lhs_symbol, rhs_symbol| {
        if (symbolEql(lhs_symbol, rhs_symbol)) continue;
        return lessThanSymbol({}, lhs_symbol, rhs_symbol);
    }
    return lhs.len < rhs.len;
}

fn lessThanReservedWordSet(_: void, lhs: ir.ReservedWordSet, rhs: ir.ReservedWordSet) bool {
    const name_order = std.mem.order(u8, lhs.context_name, rhs.context_name);
    if (name_order != .eq) {
        return name_order == .lt;
    }

    const min_len = @min(lhs.members.len, rhs.members.len);
    for (lhs.members[0..min_len], rhs.members[0..min_len]) |lhs_member, rhs_member| {
        if (lhs_member != rhs_member) return lhs_member < rhs_member;
    }
    return lhs.members.len < rhs.members.len;
}

fn symbolEql(lhs: ir_symbols.SymbolId, rhs: ir_symbols.SymbolId) bool {
    return lhs.kind == rhs.kind and lhs.index == rhs.index;
}

fn conflictSetEql(lhs: ir.ConflictSet, rhs: []const ir_symbols.SymbolId) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_symbol, rhs_symbol| {
        if (!symbolEql(lhs_symbol, rhs_symbol)) return false;
    }
    return true;
}

fn reservedWordSetEql(lhs: ir.ReservedWordSet, rhs: ir.ReservedWordSet) bool {
    return std.mem.eql(u8, lhs.context_name, rhs.context_name) and std.mem.eql(ir_rules.RuleId, lhs.members, rhs.members);
}

fn normalizePrecedenceOrdering(
    allocator: std.mem.Allocator,
    ordering: ir.PrecedenceOrdering,
) !ir.PrecedenceOrdering {
    var result = std.array_list.Managed(ir.PrecedenceEntry).init(allocator);
    defer result.deinit();

    for (ordering) |entry| {
        if (containsPrecedenceEntry(result.items, entry)) continue;
        try result.append(entry);
    }

    return try result.toOwnedSlice();
}

fn containsPrecedenceEntry(existing: []const ir.PrecedenceEntry, candidate: ir.PrecedenceEntry) bool {
    for (existing) |entry| {
        if (precedenceEntryEql(entry, candidate)) return true;
    }
    return false;
}

fn precedenceOrderingEql(lhs: ir.PrecedenceOrdering, rhs: ir.PrecedenceOrdering) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_entry, rhs_entry| {
        if (!precedenceEntryEql(lhs_entry, rhs_entry)) return false;
    }
    return true;
}

fn precedenceEntryEql(lhs: ir.PrecedenceEntry, rhs: ir.PrecedenceEntry) bool {
    return switch (lhs) {
        .name => |lhs_name| switch (rhs) {
            .name => |rhs_name| std.mem.eql(u8, lhs_name, rhs_name),
            else => false,
        },
        .symbol => |lhs_symbol| switch (rhs) {
            .symbol => |rhs_symbol| lhs_symbol.kind == rhs_symbol.kind and lhs_symbol.index == rhs_symbol.index,
            else => false,
        },
    };
}

test "normalizeSymbolList sorts and deduplicates symbols" {
    const input = [_]ir_symbols.SymbolId{
        ir_symbols.SymbolId.external(0),
        ir_symbols.SymbolId.nonTerminal(2),
        ir_symbols.SymbolId.nonTerminal(1),
        ir_symbols.SymbolId.nonTerminal(2),
    };
    const normalized = try normalizeSymbolList(std.testing.allocator, &input);
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqual(@as(usize, 3), normalized.len);
    try std.testing.expectEqual(ir_symbols.SymbolKind.non_terminal, normalized[0].kind);
    try std.testing.expectEqual(@as(u32, 1), normalized[0].index);
    try std.testing.expectEqual(ir_symbols.SymbolKind.non_terminal, normalized[1].kind);
    try std.testing.expectEqual(@as(u32, 2), normalized[1].index);
    try std.testing.expectEqual(ir_symbols.SymbolKind.external, normalized[2].kind);
    try std.testing.expectEqual(@as(u32, 0), normalized[2].index);
}

test "normalizeConflictSets deduplicates conflict members and duplicate sets" {
    const conflict_a = [_]ir_symbols.SymbolId{
        ir_symbols.SymbolId.nonTerminal(2),
        ir_symbols.SymbolId.nonTerminal(1),
        ir_symbols.SymbolId.nonTerminal(1),
    };
    const conflict_b = [_]ir_symbols.SymbolId{
        ir_symbols.SymbolId.nonTerminal(1),
        ir_symbols.SymbolId.nonTerminal(2),
    };
    const normalized = try normalizeConflictSets(std.testing.allocator, &.{ &conflict_a, &conflict_b });
    defer std.testing.allocator.free(normalized);
    defer std.testing.allocator.free(normalized[0]);

    try std.testing.expectEqual(@as(usize, 1), normalized.len);
    try std.testing.expectEqual(@as(usize, 2), normalized[0].len);
    try std.testing.expectEqual(@as(u32, 1), normalized[0][0].index);
    try std.testing.expectEqual(@as(u32, 2), normalized[0][1].index);
}

test "normalizeConflictSets preserves singleton conflict sets" {
    const conflict = [_]ir_symbols.SymbolId{
        ir_symbols.SymbolId.nonTerminal(1),
    };
    const normalized = try normalizeConflictSets(std.testing.allocator, &.{&conflict});
    defer std.testing.allocator.free(normalized);
    defer std.testing.allocator.free(normalized[0]);

    try std.testing.expectEqual(@as(usize, 1), normalized.len);
    try std.testing.expectEqual(@as(usize, 1), normalized[0].len);
    try std.testing.expectEqual(@as(u32, 1), normalized[0][0].index);
}

test "normalizePrecedenceOrderings deduplicates entries and duplicate lists" {
    const ordering_a = [_]ir.PrecedenceEntry{
        .{ .name = "a" },
        .{ .name = "b" },
        .{ .name = "a" },
    };
    const ordering_b = [_]ir.PrecedenceEntry{
        .{ .name = "a" },
        .{ .name = "b" },
    };
    const normalized = try normalizePrecedenceOrderings(std.testing.allocator, &.{ &ordering_a, &ordering_b });
    defer std.testing.allocator.free(normalized);
    defer std.testing.allocator.free(normalized[0]);

    try std.testing.expectEqual(@as(usize, 1), normalized.len);
    try std.testing.expectEqual(@as(usize, 2), normalized[0].len);
    try std.testing.expectEqualStrings("a", normalized[0][0].name);
    try std.testing.expectEqualStrings("b", normalized[0][1].name);
}

const std = @import("std");
const first = @import("first.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const ProductionId = u32;

pub const ParseItem = struct {
    production_id: ProductionId,
    step_index: u16,

    pub fn init(production_id: ProductionId, step_index: u16) ParseItem {
        return .{
            .production_id = production_id,
            .step_index = step_index,
        };
    }

    pub fn eql(a: ParseItem, b: ParseItem) bool {
        return a.production_id == b.production_id and a.step_index == b.step_index;
    }

    pub fn lessThan(_: void, a: ParseItem, b: ParseItem) bool {
        if (a.production_id != b.production_id) return a.production_id < b.production_id;
        return a.step_index < b.step_index;
    }

    pub fn format(self: ParseItem, writer: anytype) !void {
        try writer.print("#{d}@{d}", .{ self.production_id, self.step_index });
    }
};

pub const ParseItemSetEntry = struct {
    item: ParseItem,
    lookaheads: first.SymbolSet,

    pub fn initEmpty(
        allocator: std.mem.Allocator,
        terminals_len: usize,
        externals_len: usize,
        parse_item: ParseItem,
    ) !ParseItemSetEntry {
        return .{
            .item = parse_item,
            .lookaheads = try initEmptyLookaheadSet(allocator, terminals_len, externals_len),
        };
    }

    pub fn withLookahead(
        allocator: std.mem.Allocator,
        terminals_len: usize,
        externals_len: usize,
        parse_item: ParseItem,
        lookahead: syntax_ir.SymbolRef,
    ) !ParseItemSetEntry {
        var entry = try initEmpty(allocator, terminals_len, externals_len, parse_item);
        addLookahead(&entry.lookaheads, lookahead);
        return entry;
    }

    pub fn withOptionalLookahead(
        allocator: std.mem.Allocator,
        terminals_len: usize,
        externals_len: usize,
        parse_item: ParseItem,
        lookahead: ?syntax_ir.SymbolRef,
    ) !ParseItemSetEntry {
        return if (lookahead) |symbol|
            withLookahead(allocator, terminals_len, externals_len, parse_item, symbol)
        else
            initEmpty(allocator, terminals_len, externals_len, parse_item);
    }

    pub fn eql(a: ParseItemSetEntry, b: ParseItemSetEntry) bool {
        return ParseItem.eql(a.item, b.item) and first.SymbolSet.eql(a.lookaheads, b.lookaheads);
    }

    pub fn lessThan(_: void, a: ParseItemSetEntry, b: ParseItemSetEntry) bool {
        if (!ParseItem.eql(a.item, b.item)) return ParseItem.lessThan({}, a.item, b.item);
        return symbolSetLessThan(a.lookaheads, b.lookaheads);
    }

    pub fn appliesToLookahead(self: ParseItemSetEntry, lookahead: ?syntax_ir.SymbolRef) bool {
        if (lookahead) |symbol| return containsLookahead(self.lookaheads, symbol);
        return self.lookaheads.includes_epsilon or isSymbolSetEmpty(self.lookaheads);
    }

    pub fn format(self: ParseItemSetEntry, writer: anytype) !void {
        try writer.print("{f}", .{self.item});
        if (isSymbolSetEmpty(self.lookaheads) and !self.lookaheads.includes_epsilon) return;
        try writer.writeAll(" [");
        var first_written = false;
        for (self.lookaheads.terminals, 0..) |present, index| {
            if (!present) continue;
            if (first_written) try writer.writeAll(", ");
            try writer.print("terminal:{d}", .{index});
            first_written = true;
        }
        for (self.lookaheads.externals, 0..) |present, index| {
            if (!present) continue;
            if (first_written) try writer.writeAll(", ");
            try writer.print("external:{d}", .{index});
            first_written = true;
        }
        if (self.lookaheads.includes_epsilon) {
            if (first_written) try writer.writeAll(", ");
            try writer.writeAll("epsilon");
        }
        try writer.writeByte(']');
    }
};

pub const ParseItemSet = struct {
    entries: []const ParseItemSetEntry,
};

pub const ParseItemSetCore = struct {
    items: []const ParseItem,
};

pub fn initEmptyLookaheadSet(
    allocator: std.mem.Allocator,
    terminals_len: usize,
    externals_len: usize,
) !first.SymbolSet {
    const terminals = try allocator.alloc(bool, terminals_len);
    errdefer allocator.free(terminals);
    const externals = try allocator.alloc(bool, externals_len);
    @memset(terminals, false);
    @memset(externals, false);
    return .{
        .terminals = terminals,
        .externals = externals,
        .includes_epsilon = false,
    };
}

pub fn cloneSymbolSet(allocator: std.mem.Allocator, source: first.SymbolSet) !first.SymbolSet {
    return .{
        .terminals = try allocator.dupe(bool, source.terminals),
        .externals = try allocator.dupe(bool, source.externals),
        .includes_epsilon = source.includes_epsilon,
    };
}

pub fn freeSymbolSet(allocator: std.mem.Allocator, symbol_set: first.SymbolSet) void {
    allocator.free(symbol_set.terminals);
    allocator.free(symbol_set.externals);
}

pub fn addLookahead(target: *first.SymbolSet, lookahead: syntax_ir.SymbolRef) void {
    switch (lookahead) {
        .terminal => |index| target.terminals[index] = true,
        .external => |index| target.externals[index] = true,
        .non_terminal => {},
    }
}

pub fn containsLookahead(symbol_set: first.SymbolSet, lookahead: syntax_ir.SymbolRef) bool {
    return switch (lookahead) {
        .terminal => |index| symbol_set.terminals[index],
        .external => |index| symbol_set.externals[index],
        .non_terminal => false,
    };
}

pub fn isSymbolSetEmpty(symbol_set: first.SymbolSet) bool {
    return symbol_set.isEmpty();
}

fn symbolSetLessThan(a: first.SymbolSet, b: first.SymbolSet) bool {
    if (a.includes_epsilon != b.includes_epsilon) return !a.includes_epsilon and b.includes_epsilon;
    for (a.terminals, b.terminals) |left, right| {
        if (left != right) return !left and right;
    }
    for (a.externals, b.externals) |left, right| {
        if (left != right) return !left and right;
    }
    return false;
}

test "parse items compare deterministically" {
    const a = ParseItem.init(1, 0);
    const b = ParseItem.init(1, 1);
    try std.testing.expect(ParseItem.lessThan({}, a, b));
    try std.testing.expect(ParseItem.eql(b, ParseItem.init(1, 1)));
}

test "parse item set entry format includes lookaheads when present" {
    const entry = try ParseItemSetEntry.withLookahead(
        std.testing.allocator,
        4,
        10,
        ParseItem.init(2, 3),
        .{ .external = 9 },
    );
    defer freeSymbolSet(std.testing.allocator, entry.lookaheads);

    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{entry});
    try std.testing.expectEqualStrings("#2@3 [external:9]", text);
}

test "parse item set entry applies to matching lookahead" {
    const entry = try ParseItemSetEntry.withLookahead(
        std.testing.allocator,
        2,
        2,
        ParseItem.init(1, 1),
        .{ .terminal = 1 },
    );
    defer freeSymbolSet(std.testing.allocator, entry.lookaheads);

    try std.testing.expect(entry.appliesToLookahead(.{ .terminal = 1 }));
    try std.testing.expect(!entry.appliesToLookahead(.{ .terminal = 0 }));
}

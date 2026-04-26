const std = @import("std");
const first = @import("first.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const ProductionId = u32;

pub const SymbolSetProfile = struct {
    init_empty_count: usize = 0,
    clone_count: usize = 0,
    free_count: usize = 0,
    bool_alloc_bytes: usize = 0,
    bool_free_bytes: usize = 0,
};

threadlocal var symbol_set_profile_enabled: bool = false;
threadlocal var symbol_set_profile: SymbolSetProfile = .{};

pub fn setSymbolSetProfileEnabled(enabled: bool) void {
    symbol_set_profile_enabled = enabled;
}

pub fn resetSymbolSetProfile() void {
    symbol_set_profile = .{};
}

pub fn symbolSetProfile() SymbolSetProfile {
    return symbol_set_profile;
}

fn recordSymbolSetAlloc(kind: enum { init_empty, clone }, terminals_len: usize, externals_len: usize) void {
    if (!symbol_set_profile_enabled) return;
    switch (kind) {
        .init_empty => symbol_set_profile.init_empty_count += 1,
        .clone => symbol_set_profile.clone_count += 1,
    }
    symbol_set_profile.bool_alloc_bytes += packedSymbolBitsBytes(terminals_len) + packedSymbolBitsBytes(externals_len);
}

fn recordSymbolSetFree(terminals_len: usize, externals_len: usize) void {
    if (!symbol_set_profile_enabled) return;
    symbol_set_profile.free_count += 1;
    symbol_set_profile.bool_free_bytes += packedSymbolBitsBytes(terminals_len) + packedSymbolBitsBytes(externals_len);
}

fn packedSymbolBitsBytes(bit_count: usize) usize {
    const bits_per_mask = @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
    const mask_count = (bit_count + bits_per_mask - 1) / bits_per_mask;
    return mask_count * @sizeOf(std.DynamicBitSetUnmanaged.MaskInt);
}

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
    following_reserved_word_set_id: u16 = 0,

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
        return ParseItem.eql(a.item, b.item) and
            first.SymbolSet.eql(a.lookaheads, b.lookaheads) and
            a.following_reserved_word_set_id == b.following_reserved_word_set_id;
    }

    pub fn lessThan(_: void, a: ParseItemSetEntry, b: ParseItemSetEntry) bool {
        if (!ParseItem.eql(a.item, b.item)) return ParseItem.lessThan({}, a.item, b.item);
        if (a.following_reserved_word_set_id != b.following_reserved_word_set_id) {
            return a.following_reserved_word_set_id < b.following_reserved_word_set_id;
        }
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
        var terminal_iter = self.lookaheads.terminals.bits.iterator(.{});
        while (terminal_iter.next()) |index| {
            if (first_written) try writer.writeAll(", ");
            try writer.print("terminal:{d}", .{index});
            first_written = true;
        }
        var external_iter = self.lookaheads.externals.bits.iterator(.{});
        while (external_iter.next()) |index| {
            if (first_written) try writer.writeAll(", ");
            try writer.print("external:{d}", .{index});
            first_written = true;
        }
        if (self.lookaheads.includes_end) {
            if (first_written) try writer.writeAll(", ");
            try writer.writeAll("end");
            first_written = true;
        }
        if (self.lookaheads.includes_epsilon) {
            if (first_written) try writer.writeAll(", ");
            try writer.writeAll("epsilon");
        }
        try writer.writeByte(']');
        if (self.following_reserved_word_set_id != 0) {
            try writer.print(" reserved:{d}", .{self.following_reserved_word_set_id});
        }
    }
};

pub const ParseItemSet = struct {
    entries: []const ParseItemSetEntry,

    pub fn lessThan(_: void, a: ParseItemSet, b: ParseItemSet) bool {
        return entriesLessThan(a.entries, b.entries);
    }
};

pub const ParseItemSetCore = struct {
    items: []const ParseItem,

    pub fn fromEntriesAlloc(
        allocator: std.mem.Allocator,
        entries: []const ParseItemSetEntry,
    ) !ParseItemSetCore {
        const items = try allocator.alloc(ParseItem, entries.len);
        for (entries, 0..) |entry, index| {
            items[index] = entry.item;
        }
        std.mem.sort(ParseItem, items, {}, ParseItem.lessThan);
        return .{ .items = items };
    }

    pub fn eql(a: ParseItemSetCore, b: ParseItemSetCore) bool {
        if (a.items.len != b.items.len) return false;
        for (a.items, b.items) |left, right| {
            if (!ParseItem.eql(left, right)) return false;
        }
        return true;
    }

    pub fn lessThan(_: void, a: ParseItemSetCore, b: ParseItemSetCore) bool {
        return itemsLessThan(a.items, b.items);
    }
};

pub fn initEmptyLookaheadSet(
    allocator: std.mem.Allocator,
    terminals_len: usize,
    externals_len: usize,
) !first.SymbolSet {
    const terminals = try first.SymbolBits.initEmpty(allocator, terminals_len);
    errdefer {
        var mutable = terminals;
        mutable.deinit(allocator);
    }
    const externals = try first.SymbolBits.initEmpty(allocator, externals_len);
    recordSymbolSetAlloc(.init_empty, terminals_len, externals_len);
    return .{
        .terminals = terminals,
        .externals = externals,
        .includes_end = false,
        .includes_epsilon = false,
    };
}

pub fn cloneSymbolSet(allocator: std.mem.Allocator, source: first.SymbolSet) !first.SymbolSet {
    const cloned = first.SymbolSet{
        .terminals = try source.terminals.clone(allocator),
        .externals = try source.externals.clone(allocator),
        .includes_end = source.includes_end,
        .includes_epsilon = source.includes_epsilon,
    };
    recordSymbolSetAlloc(.clone, source.terminals.len(), source.externals.len());
    return cloned;
}

pub fn freeSymbolSet(allocator: std.mem.Allocator, symbol_set: first.SymbolSet) void {
    recordSymbolSetFree(symbol_set.terminals.len(), symbol_set.externals.len());
    var terminals = symbol_set.terminals;
    var externals = symbol_set.externals;
    terminals.deinit(allocator);
    externals.deinit(allocator);
}

pub fn addLookahead(target: *first.SymbolSet, lookahead: syntax_ir.SymbolRef) void {
    switch (lookahead) {
        .end => target.includes_end = true,
        .terminal => |index| target.terminals.set(index),
        .external => |index| target.externals.set(index),
        .non_terminal => {},
    }
}

pub fn containsLookahead(symbol_set: first.SymbolSet, lookahead: syntax_ir.SymbolRef) bool {
    return switch (lookahead) {
        .end => symbol_set.includes_end,
        .terminal => |index| symbol_set.terminals.get(index),
        .external => |index| symbol_set.externals.get(index),
        .non_terminal => false,
    };
}

pub fn mergeSymbolSetLookaheads(target: *first.SymbolSet, incoming: first.SymbolSet) bool {
    var changed = false;
    if (incoming.includes_end and !target.includes_end) {
        target.includes_end = true;
        changed = true;
    }
    changed = first.SymbolBits.merge(&target.terminals, incoming.terminals) or changed;
    changed = first.SymbolBits.merge(&target.externals, incoming.externals) or changed;
    if (incoming.includes_epsilon and !target.includes_epsilon) {
        target.includes_epsilon = true;
        changed = true;
    }
    return changed;
}

pub fn isSymbolSetEmpty(symbol_set: first.SymbolSet) bool {
    return symbol_set.isEmpty();
}

fn symbolSetLessThan(a: first.SymbolSet, b: first.SymbolSet) bool {
    if (a.includes_end != b.includes_end) return !a.includes_end and b.includes_end;
    if (a.includes_epsilon != b.includes_epsilon) return !a.includes_epsilon and b.includes_epsilon;
    var index: usize = 0;
    while (index < a.terminals.len() and index < b.terminals.len()) : (index += 1) {
        const left = a.terminals.get(index);
        const right = b.terminals.get(index);
        if (left != right) return !left and right;
    }
    index = 0;
    while (index < a.externals.len() and index < b.externals.len()) : (index += 1) {
        const left = a.externals.get(index);
        const right = b.externals.get(index);
        if (left != right) return !left and right;
    }
    return false;
}

fn entriesLessThan(left: []const ParseItemSetEntry, right: []const ParseItemSetEntry) bool {
    const shared_len = @min(left.len, right.len);
    for (0..shared_len) |index| {
        if (ParseItemSetEntry.lessThan({}, left[index], right[index])) return true;
        if (ParseItemSetEntry.lessThan({}, right[index], left[index])) return false;
    }
    return left.len < right.len;
}

fn itemsLessThan(left: []const ParseItem, right: []const ParseItem) bool {
    const shared_len = @min(left.len, right.len);
    for (0..shared_len) |index| {
        if (ParseItem.lessThan({}, left[index], right[index])) return true;
        if (ParseItem.lessThan({}, right[index], left[index])) return false;
    }
    return left.len < right.len;
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

test "parse item set core extracts sorted item identity from entries" {
    var entries = [_]ParseItemSetEntry{
        try ParseItemSetEntry.withLookahead(std.testing.allocator, 2, 0, ParseItem.init(2, 0), .{ .terminal = 1 }),
        try ParseItemSetEntry.initEmpty(std.testing.allocator, 2, 0, ParseItem.init(1, 3)),
    };
    defer for (entries) |entry| freeSymbolSet(std.testing.allocator, entry.lookaheads);

    const core = try ParseItemSetCore.fromEntriesAlloc(std.testing.allocator, entries[0..]);
    defer std.testing.allocator.free(core.items);

    try std.testing.expectEqual(@as(usize, 2), core.items.len);
    try std.testing.expect(ParseItem.eql(ParseItem.init(1, 3), core.items[0]));
    try std.testing.expect(ParseItem.eql(ParseItem.init(2, 0), core.items[1]));
}

test "mergeSymbolSetLookaheads unions terminals externals and epsilon" {
    var target = try initEmptyLookaheadSet(std.testing.allocator, 2, 2);
    defer freeSymbolSet(std.testing.allocator, target);
    addLookahead(&target, .{ .terminal = 0 });

    var incoming = try initEmptyLookaheadSet(std.testing.allocator, 2, 2);
    defer freeSymbolSet(std.testing.allocator, incoming);
    addLookahead(&incoming, .{ .external = 1 });
    incoming.includes_epsilon = true;

    try std.testing.expect(mergeSymbolSetLookaheads(&target, incoming));
    try std.testing.expect(target.terminals.get(0));
    try std.testing.expect(target.externals.get(1));
    try std.testing.expect(target.includes_epsilon);
}

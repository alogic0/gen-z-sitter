const std = @import("std");
const lexical_serialize = @import("serialize.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const EmitError = std.Io.Writer.Error || std.mem.Allocator.Error;
const advance_map_threshold = 8;
const large_character_range_threshold = 8;

pub const SymbolResolver = struct {
    context: *const anyopaque,
    resolve: *const fn (context: *const anyopaque, symbol: syntax_ir.SymbolRef) ?u16,

    fn symbolId(self: SymbolResolver, symbol: syntax_ir.SymbolRef) ?u16 {
        return self.resolve(self.context, symbol);
    }
};

pub fn emitLexFunction(
    writer: anytype,
    fn_name: []const u8,
    lex_table: lexical_serialize.SerializedLexTable,
) EmitError!void {
    try emitLexFunctionWithResolver(writer, fn_name, lex_table, null);
}

pub fn emitLexFunctionWithResolver(
    writer: anytype,
    fn_name: []const u8,
    lex_table: lexical_serialize.SerializedLexTable,
    resolver: ?SymbolResolver,
) EmitError!void {
    const large_sets = LargeCharacterSets{ .lex_table = lex_table };
    try emitLexFunctionWithLargeSets(writer, fn_name, lex_table, resolver, large_sets);
}

pub fn emitLexFunctionWithResolverAlloc(
    allocator: std.mem.Allocator,
    writer: anytype,
    fn_name: []const u8,
    lex_table: lexical_serialize.SerializedLexTable,
    resolver: ?SymbolResolver,
) EmitError!void {
    const large_sets = try LargeCharacterSetIndex.initAlloc(allocator, lex_table);
    defer large_sets.deinit(allocator);
    try emitLexFunctionWithLargeSets(writer, fn_name, lex_table, resolver, large_sets);
}

fn emitLexFunctionWithLargeSets(
    writer: anytype,
    fn_name: []const u8,
    lex_table: lexical_serialize.SerializedLexTable,
    resolver: ?SymbolResolver,
    large_sets: anytype,
) EmitError!void {
    try large_sets.emitDeclarations(writer, fn_name);

    try writer.print("static bool {s}(TSLexer *lexer, TSStateId state) {{\n", .{fn_name});
    try writer.writeAll("  START_LEXER();\n");
    try writer.writeAll("  eof = lexer->eof(lexer);\n");
    try writer.writeAll("  switch (state) {\n");
    for (lex_table.states, 0..) |state_value, state_id| {
        try writer.print("    case {d}:\n", .{state_id});
        if (state_value.accept_symbol) |symbol| {
            const symbol_id = runtimeSymbolId(symbol, resolver);
            try writer.print("      ACCEPT_TOKEN({d});\n", .{symbol_id});
        }
        if (state_value.eof_target) |target| {
            try writer.print("      if (eof) ADVANCE({d});\n", .{target});
        }
        const advance_map_end = leadingAdvanceMapTransitionEnd(state_value.transitions);
        if (advance_map_end != 0) {
            try emitAdvanceMap(writer, state_value.transitions[0..advance_map_end]);
        }
        for (state_value.transitions[advance_map_end..]) |transition| {
            if (transition.ranges.len == 0) continue;
            try writer.writeAll("      if (");
            if (large_sets.find(transition.ranges)) |set_id| {
                try writeLargeSetCondition(writer, fn_name, set_id, transition.ranges);
            } else {
                try writeTransitionCondition(writer, transition.ranges);
            }
            try writer.writeAll(") ");
            if (transition.skip) {
                try writer.print("SKIP({d});\n", .{transition.next_state_id});
            } else {
                try writer.print("ADVANCE({d});\n", .{transition.next_state_id});
            }
        }
        try writer.writeAll("      END_STATE();\n");
    }
    try writer.writeAll("    default:\n");
    try writer.writeAll("      return false;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n\n");
}

const LargeCharacterSetEntry = struct {
    ranges: []const lexical_serialize.SerializedCharacterRange,
};

const LargeCharacterSetIndex = struct {
    entries: []const LargeCharacterSetEntry,

    fn initAlloc(
        allocator: std.mem.Allocator,
        lex_table: lexical_serialize.SerializedLexTable,
    ) std.mem.Allocator.Error!LargeCharacterSetIndex {
        var entries = std.array_list.Managed(LargeCharacterSetEntry).init(allocator);
        errdefer entries.deinit();

        for (lex_table.states) |state_value| {
            const advance_map_end = leadingAdvanceMapTransitionEnd(state_value.transitions);
            for (state_value.transitions[advance_map_end..]) |transition| {
                if (!isLargeCharacterSet(transition.ranges)) continue;
                if (findInEntries(entries.items, transition.ranges) != null) continue;
                try entries.append(.{ .ranges = transition.ranges });
            }
        }

        return .{ .entries = try entries.toOwnedSlice() };
    }

    fn deinit(self: LargeCharacterSetIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    fn emitDeclarations(
        self: LargeCharacterSetIndex,
        writer: anytype,
        fn_name: []const u8,
    ) EmitError!void {
        for (self.entries, 0..) |entry, set_id| {
            try writer.print("static const TSCharacterRange {s}_character_set_{d}[] = {{\n", .{ fn_name, set_id });
            for (entry.ranges) |range| {
                try writer.print("  {{ {d}, {d} }},\n", .{ range.start, range.end_inclusive });
            }
            try writer.writeAll("};\n\n");
        }
    }

    fn find(self: LargeCharacterSetIndex, ranges: []const lexical_serialize.SerializedCharacterRange) ?usize {
        return findInEntries(self.entries, ranges);
    }
};

fn findInEntries(
    entries: []const LargeCharacterSetEntry,
    ranges: []const lexical_serialize.SerializedCharacterRange,
) ?usize {
    for (entries, 0..) |entry, index| {
        if (rangeSetsEqual(entry.ranges, ranges)) return index;
    }
    return null;
}

const LargeCharacterSets = struct {
    lex_table: lexical_serialize.SerializedLexTable,

    fn emitDeclarations(
        self: *const LargeCharacterSets,
        writer: anytype,
        fn_name: []const u8,
    ) EmitError!void {
        var next_id: usize = 0;
        for (self.lex_table.states) |state_value| {
            const advance_map_end = leadingAdvanceMapTransitionEnd(state_value.transitions);
            for (state_value.transitions[advance_map_end..]) |transition| {
                if (!isLargeCharacterSet(transition.ranges)) continue;
                const set_id = self.find(transition.ranges) orelse continue;
                if (set_id != next_id) continue;

                try writer.print("static const TSCharacterRange {s}_character_set_{d}[] = {{\n", .{ fn_name, set_id });
                for (transition.ranges) |range| {
                    try writer.print("  {{ {d}, {d} }},\n", .{ range.start, range.end_inclusive });
                }
                try writer.writeAll("};\n\n");
                next_id += 1;
            }
        }
    }

    fn find(self: *const LargeCharacterSets, ranges: []const lexical_serialize.SerializedCharacterRange) ?usize {
        var next_id: usize = 0;
        for (self.lex_table.states, 0..) |state_value, state_index| {
            const advance_map_end = leadingAdvanceMapTransitionEnd(state_value.transitions);
            for (state_value.transitions[advance_map_end..], advance_map_end..) |transition, transition_index| {
                if (!isLargeCharacterSet(transition.ranges)) continue;
                if (self.hasPrevious(transition.ranges, state_index, transition_index)) continue;
                if (rangeSetsEqual(transition.ranges, ranges)) return next_id;
                next_id += 1;
            }
        }
        return null;
    }

    fn hasPrevious(
        self: *const LargeCharacterSets,
        ranges: []const lexical_serialize.SerializedCharacterRange,
        current_state_index: usize,
        current_transition_index: usize,
    ) bool {
        for (self.lex_table.states[0..current_state_index]) |state_value| {
            const advance_map_end = leadingAdvanceMapTransitionEnd(state_value.transitions);
            for (state_value.transitions[advance_map_end..]) |transition| {
                if (isLargeCharacterSet(transition.ranges) and rangeSetsEqual(transition.ranges, ranges)) return true;
            }
        }

        const current_state = self.lex_table.states[current_state_index];
        const advance_map_end = leadingAdvanceMapTransitionEnd(current_state.transitions);
        for (current_state.transitions[advance_map_end..current_transition_index]) |transition| {
            if (isLargeCharacterSet(transition.ranges) and rangeSetsEqual(transition.ranges, ranges)) return true;
        }
        return false;
    }
};

pub fn isLargeCharacterSet(ranges: []const lexical_serialize.SerializedCharacterRange) bool {
    return ranges.len >= large_character_range_threshold;
}

fn rangeSetsEqual(
    lhs: []const lexical_serialize.SerializedCharacterRange,
    rhs: []const lexical_serialize.SerializedCharacterRange,
) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left.start != right.start) return false;
        if (left.end_inclusive != right.end_inclusive) return false;
    }
    return true;
}

fn writeLargeSetCondition(
    writer: anytype,
    fn_name: []const u8,
    set_id: usize,
    ranges: []const lexical_serialize.SerializedCharacterRange,
) EmitError!void {
    if (rangesIncludeNull(ranges)) try writer.writeAll("(!eof && ");
    try writer.print("set_contains({s}_character_set_{d}, {d}, lookahead)", .{ fn_name, set_id, ranges.len });
    if (rangesIncludeNull(ranges)) try writer.writeByte(')');
}

fn rangesIncludeNull(ranges: []const lexical_serialize.SerializedCharacterRange) bool {
    for (ranges) |range| {
        if (range.start == 0) return true;
    }
    return false;
}

fn leadingAdvanceMapTransitionEnd(transitions: []const lexical_serialize.SerializedLexTransition) usize {
    var transition_count: usize = 0;
    var range_count: usize = 0;
    for (transitions) |transition| {
        if (transition.skip) break;
        if (!isAdvanceMapTransition(transition)) break;
        transition_count += 1;
        range_count += transition.ranges.len;
    }
    return if (range_count >= advance_map_threshold) transition_count else 0;
}

fn isAdvanceMapTransition(transition: lexical_serialize.SerializedLexTransition) bool {
    if (transition.ranges.len == 0) return false;
    for (transition.ranges) |range| {
        if (range.end_inclusive > std.math.maxInt(u16)) return false;
        if (range.end_inclusive > range.start + 1) return false;
    }
    return true;
}

fn emitAdvanceMap(
    writer: anytype,
    transitions: []const lexical_serialize.SerializedLexTransition,
) EmitError!void {
    try writer.writeAll("      ADVANCE_MAP(\n");
    for (transitions) |transition| {
        for (transition.ranges) |range| {
            try writer.print("        {d}, {d},\n", .{ range.start, transition.next_state_id });
            if (range.end_inclusive > range.start) {
                try writer.print("        {d}, {d},\n", .{ range.end_inclusive, transition.next_state_id });
            }
        }
    }
    try writer.writeAll("      );\n");
}

fn runtimeSymbolId(symbol: syntax_ir.SymbolRef, resolver: ?SymbolResolver) u16 {
    if (resolver) |value| {
        if (value.symbolId(symbol)) |symbol_id| return symbol_id;
    }
    return switch (symbol) {
        .end => 0,
        .terminal => |index| @intCast(index),
        .external => |index| @intCast(index),
        .non_terminal => |index| @intCast(index),
    };
}

fn writeTransitionCondition(
    writer: anytype,
    ranges: []const lexical_serialize.SerializedCharacterRange,
) EmitError!void {
    for (ranges, 0..) |range, index| {
        if (index > 0) try writer.writeAll(" || ");
        try writeRangeCondition(writer, range);
    }
}

fn writeRangeCondition(
    writer: anytype,
    range: lexical_serialize.SerializedCharacterRange,
) EmitError!void {
    if (range.start == range.end_inclusive) {
        try writeCodepointCondition(writer, range.start);
        return;
    }
    if (range.end_inclusive == range.start + 1) {
        try writer.writeByte('(');
        try writeCodepointCondition(writer, range.start);
        try writer.writeAll(" || ");
        try writeCodepointCondition(writer, range.end_inclusive);
        try writer.writeByte(')');
        return;
    }

    const needs_eof_guard = range.start == 0;
    if (needs_eof_guard) try writer.writeAll("(!eof && ");
    try writer.print("({d} <= lookahead && lookahead <= {d})", .{ range.start, range.end_inclusive });
    if (needs_eof_guard) try writer.writeByte(')');
}

fn writeCodepointCondition(writer: anytype, codepoint: u32) EmitError!void {
    if (codepoint == 0) {
        try writer.writeAll("(!eof && lookahead == 0)");
    } else {
        try writer.print("lookahead == {d}", .{codepoint});
    }
}

test "emitLexFunction emits switch states, accepts, advances, and skips" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    const table = lexical_serialize.SerializedLexTable{
        .start_state_id = 0,
        .states = &[_]lexical_serialize.SerializedLexState{
            .{
                .transitions = &[_]lexical_serialize.SerializedLexTransition{
                    .{
                        .ranges = &[_]lexical_serialize.SerializedCharacterRange{
                            .{ .start = 'a', .end_inclusive = 'a' },
                        },
                        .next_state_id = 1,
                        .skip = false,
                    },
                },
            },
            .{
                .accept_symbol = .{ .terminal = 7 },
                .transitions = &[_]lexical_serialize.SerializedLexTransition{
                    .{
                        .ranges = &[_]lexical_serialize.SerializedCharacterRange{
                            .{ .start = ' ', .end_inclusive = ' ' },
                        },
                        .next_state_id = 1,
                        .skip = true,
                    },
                },
            },
        },
    };

    try emitLexFunction(&buffer.writer, "ts_lex", table);
    const emitted = buffer.writer.buffered();

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_lex(TSLexer *lexer, TSStateId state) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  START_LEXER();\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "    case 0:\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      if (lookahead == 97) ADVANCE(1);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      ACCEPT_TOKEN(7);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      if (lookahead == 32) SKIP(1);\n"));
}

test "emitLexFunction renders EOF guards and adjacent range readability form" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    const table = lexical_serialize.SerializedLexTable{
        .start_state_id = 0,
        .states = &[_]lexical_serialize.SerializedLexState{
            .{
                .eof_target = 1,
                .transitions = &[_]lexical_serialize.SerializedLexTransition{
                    .{
                        .ranges = &[_]lexical_serialize.SerializedCharacterRange{
                            .{ .start = 0, .end_inclusive = 3 },
                            .{ .start = 'x', .end_inclusive = 'y' },
                        },
                        .next_state_id = 1,
                        .skip = false,
                    },
                },
            },
            .{ .accept_symbol = .{ .terminal = 2 }, .transitions = &.{} },
        },
    };

    try emitLexFunction(&buffer.writer, "ts_lex", table);
    const emitted = buffer.writer.buffered();

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      if (eof) ADVANCE(1);\n"));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        emitted,
        1,
        "      if ((!eof && (0 <= lookahead && lookahead <= 3)) || (lookahead == 120 || lookahead == 121)) ADVANCE(1);\n",
    ));
}

test "emitLexFunction uses ADVANCE_MAP for leading simple transitions" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    const transitions = [_]lexical_serialize.SerializedLexTransition{
        .{
            .ranges = &[_]lexical_serialize.SerializedCharacterRange{
                .{ .start = 'a', .end_inclusive = 'a' },
                .{ .start = 'b', .end_inclusive = 'b' },
            },
            .next_state_id = 1,
            .skip = false,
        },
        .{
            .ranges = &[_]lexical_serialize.SerializedCharacterRange{
                .{ .start = 'c', .end_inclusive = 'd' },
                .{ .start = 'e', .end_inclusive = 'f' },
            },
            .next_state_id = 2,
            .skip = false,
        },
        .{
            .ranges = &[_]lexical_serialize.SerializedCharacterRange{
                .{ .start = 'g', .end_inclusive = 'g' },
                .{ .start = 'h', .end_inclusive = 'h' },
            },
            .next_state_id = 3,
            .skip = false,
        },
        .{
            .ranges = &[_]lexical_serialize.SerializedCharacterRange{
                .{ .start = 'i', .end_inclusive = 'i' },
                .{ .start = 'j', .end_inclusive = 'j' },
            },
            .next_state_id = 4,
            .skip = false,
        },
        .{
            .ranges = &[_]lexical_serialize.SerializedCharacterRange{
                .{ .start = '0', .end_inclusive = '9' },
            },
            .next_state_id = 5,
            .skip = false,
        },
    };
    const table = lexical_serialize.SerializedLexTable{
        .start_state_id = 0,
        .states = &[_]lexical_serialize.SerializedLexState{
            .{ .transitions = transitions[0..] },
            .{ .transitions = &.{} },
            .{ .transitions = &.{} },
            .{ .transitions = &.{} },
            .{ .transitions = &.{} },
            .{ .transitions = &.{} },
        },
    };

    try emitLexFunction(&buffer.writer, "ts_lex", table);
    const emitted = buffer.writer.buffered();

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      ADVANCE_MAP(\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "        97, 1,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "        100, 2,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "        106, 4,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      if ((48 <= lookahead && lookahead <= 57)) ADVANCE(5);\n"));
}

test "emitLexFunction uses TSCharacterRange tables for large character sets" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    const ranges = [_]lexical_serialize.SerializedCharacterRange{
        .{ .start = 0, .end_inclusive = 1 },
        .{ .start = 10, .end_inclusive = 12 },
        .{ .start = 20, .end_inclusive = 24 },
        .{ .start = 30, .end_inclusive = 31 },
        .{ .start = 40, .end_inclusive = 42 },
        .{ .start = 50, .end_inclusive = 53 },
        .{ .start = 60, .end_inclusive = 61 },
        .{ .start = 70, .end_inclusive = 75 },
    };
    const table = lexical_serialize.SerializedLexTable{
        .start_state_id = 0,
        .states = &[_]lexical_serialize.SerializedLexState{
            .{
                .transitions = &[_]lexical_serialize.SerializedLexTransition{
                    .{
                        .ranges = ranges[0..],
                        .next_state_id = 1,
                        .skip = false,
                    },
                },
            },
            .{ .accept_symbol = .{ .terminal = 2 }, .transitions = &.{} },
        },
    };

    try emitLexFunction(&buffer.writer, "ts_lex", table);
    const emitted = buffer.writer.buffered();

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSCharacterRange ts_lex_character_set_0[] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  { 70, 75 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        emitted,
        1,
        "      if ((!eof && set_contains(ts_lex_character_set_0, 8, lookahead))) ADVANCE(1);\n",
    ));
}

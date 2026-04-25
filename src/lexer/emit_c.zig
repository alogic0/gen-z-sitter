const std = @import("std");
const lexical_serialize = @import("serialize.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const EmitError = std.Io.Writer.Error;

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
        for (state_value.transitions) |transition| {
            if (transition.ranges.len == 0) continue;
            try writer.writeAll("      if (");
            try writeTransitionCondition(writer, transition.ranges);
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

fn runtimeSymbolId(symbol: syntax_ir.SymbolRef, resolver: ?SymbolResolver) u16 {
    if (resolver) |value| {
        if (value.symbolId(symbol)) |symbol_id| return symbol_id;
    }
    return switch (symbol) {
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

const std = @import("std");
const compile_smoke = @import("compat/compile_smoke.zig");
const parser_compat = @import("parser_emit/compat.zig");
const lexer_emit_c = @import("lexer/emit_c.zig");
const lexer_serialize = @import("lexer/serialize.zig");

test {
    _ = @import("cli/args.zig");
    _ = @import("grammar/raw_grammar.zig");
    _ = @import("grammar/json_loader.zig");
    _ = @import("grammar/js_loader.zig");
    _ = @import("grammar/validate.zig");
    _ = @import("grammar/loader.zig");
    _ = @import("grammar/parse_grammar.zig");
    _ = @import("grammar/debug_dump.zig");
    _ = @import("grammar/normalize.zig");
    _ = @import("grammar/prepare/extract_tokens.zig");
    _ = @import("grammar/prepare/expand_repeats.zig");
    _ = @import("grammar/prepare/flatten_grammar.zig");
    _ = @import("grammar/prepare/extract_default_aliases.zig");
    _ = @import("ir/symbols.zig");
    _ = @import("ir/rules.zig");
    _ = @import("ir/grammar_ir.zig");
    _ = @import("ir/syntax_grammar.zig");
    _ = @import("ir/lexical_grammar.zig");
    _ = @import("ir/aliases.zig");
    _ = @import("lexer/checks.zig");
    _ = @import("lexer/debug_dump.zig");
    _ = @import("lexer/emit_c.zig");
    _ = @import("lexer/model.zig");
    _ = @import("lexer/serialize.zig");
    _ = @import("lexer/table.zig");
    _ = @import("scanner/debug_dump.zig");
    _ = @import("scanner/checks.zig");
    _ = @import("scanner/serialize.zig");
    _ = @import("node_types/compute.zig");
    _ = @import("node_types/render_json.zig");
    _ = @import("parse_table/item.zig");
    _ = @import("parse_table/first.zig");
    _ = @import("parse_table/actions.zig");
    _ = @import("parse_table/state.zig");
    _ = @import("parse_table/conflicts.zig");
    _ = @import("parse_table/conflict_resolution.zig");
    _ = @import("parse_table/debug_dump.zig");
    _ = @import("parse_table/build.zig");
    _ = @import("parse_table/minimize.zig");
    _ = @import("parse_table/resolution.zig");
    _ = @import("parse_table/serialize.zig");
    _ = @import("parser_emit/common.zig");
    _ = @import("parser_emit/compat.zig");
    _ = @import("parser_emit/compat_checks.zig");
    _ = @import("parser_emit/parser_tables.zig");
    _ = @import("parser_emit/parser_c.zig");
    _ = @import("compat/no_vendored_tree_sitter.zig");
    _ = @import("compat/release_boundary.zig");
    _ = @import("compat/minimize_probe.zig");
    _ = @import("compat/node_types_diff.zig");
    _ = @import("compat/upstream_summary.zig");
    _ = @import("cli/command_compare_upstream.zig");
    _ = @import("support/diag.zig");
    _ = @import("support/fs.zig");
    _ = @import("support/json.zig");
    _ = @import("support/process.zig");
    _ = @import("support/strings.zig");
    _ = @import("tests/fixtures.zig");
    _ = @import("tests/golden.zig");
}

test "generated contract and large character-set lexer compile as C11 with warnings" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try parser_compat.writeContractPrelude(&buffer.writer, parser_compat.currentRuntimeCompatibility());
    try parser_compat.writeContractTypesAndConstants(&buffer.writer, parser_compat.currentRuntimeCompatibility());

    const ranges = [_]lexer_serialize.SerializedCharacterRange{
        .{ .start = 0, .end_inclusive = 1 },
        .{ .start = 10, .end_inclusive = 12 },
        .{ .start = 20, .end_inclusive = 24 },
        .{ .start = 30, .end_inclusive = 31 },
        .{ .start = 40, .end_inclusive = 42 },
        .{ .start = 50, .end_inclusive = 53 },
        .{ .start = 60, .end_inclusive = 61 },
        .{ .start = 70, .end_inclusive = 75 },
    };
    const lex_table = lexer_serialize.SerializedLexTable{
        .start_state_id = 0,
        .states = &[_]lexer_serialize.SerializedLexState{
            .{
                .transitions = &[_]lexer_serialize.SerializedLexTransition{
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

    try lexer_emit_c.emitLexFunction(&buffer.writer, "ts_lex", lex_table);
    try buffer.writer.writeAll("bool (*gen_z_sitter_use_ts_lex)(TSLexer *, TSStateId) = ts_lex;\n");

    var result = try compile_smoke.compileParserC(std.testing.allocator, buffer.writer.buffered());
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .success);
}

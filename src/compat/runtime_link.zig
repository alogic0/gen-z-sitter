const std = @import("std");
const build_parse_table = @import("../parse_table/build.zig");
const ir_rules = @import("../ir/rules.zig");
const lexical_grammar = @import("../ir/lexical_grammar.zig");
const lexer_serialize = @import("../lexer/serialize.zig");
const parse_actions = @import("../parse_table/actions.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const parse_table_resolution = @import("../parse_table/resolution.zig");
const serialize = @import("../parse_table/serialize.zig");
const process_support = @import("../support/process.zig");
const runtime_io = @import("../support/runtime_io.zig");
const syntax_grammar = @import("../ir/syntax_grammar.zig");

pub const RuntimeLinkError = anyerror;

const tree_sitter_runtime_dir = "../tree-sitter/lib/src";
const tree_sitter_include_dir = "../tree-sitter/lib/include";
const bracket_lang_grammar_path = "compat_targets/bracket_lang/grammar.json";
const bracket_lang_scanner_path = "compat_targets/bracket_lang/scanner.c";
const bash_scanner_path = "../tree-sitter-grammars/tree-sitter-bash/src/scanner.c";
const bash_scanner_include_dir = "../tree-sitter-grammars/tree-sitter-bash/src";
const bash_bare_dollar_external_id = 15;
const javascript_scanner_path = "../tree-sitter-grammars/tree-sitter-javascript/src/scanner.c";
const javascript_scanner_include_dir = "../tree-sitter-grammars/tree-sitter-javascript/src";
const javascript_ternary_qmark_external_id = 2;
const javascript_jsx_text_external_id = 7;
const typescript_scanner_path = "../tree-sitter-grammars/tree-sitter-typescript/typescript/src/scanner.c";
const typescript_scanner_include_dir = "../tree-sitter-grammars/tree-sitter-typescript/typescript/src";
const typescript_ternary_qmark_external_id = 2;
const typescript_jsx_text_external_id = 7;
const python_scanner_path = "../tree-sitter-grammars/tree-sitter-python/src/scanner.c";
const python_scanner_include_dir = "../tree-sitter-grammars/tree-sitter-python/src";
const python_newline_external_id = 0;
const rust_scanner_path = "../tree-sitter-grammars/tree-sitter-rust/src/scanner.c";
const rust_scanner_include_dir = "../tree-sitter-grammars/tree-sitter-rust/src";
const rust_float_literal_external_id = 5;
const haskell_scanner_path = "../tree-sitter-grammars/tree-sitter-haskell/src/scanner.c";
const haskell_scanner_include_dir = "../tree-sitter-grammars/tree-sitter-haskell/src";
const haskell_start_external_id = 2;
const haskell_varsym_external_id = 46;
const haskell_update_external_id = 48;

pub fn linkAndRunNoExternalTinyParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTinyParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "x",
        .expected_metadata = .{ 3, 1, 4 },
    });
}

pub fn linkAndRunNoExternalTinyGlrParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTinyGlrParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "x",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
    });
}

pub fn linkAndRunNoExternalTinyGlrResultParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitAliasedFieldGlrParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "xy",
        .direct_generated_parse = true,
        .direct_generated_result = true,
        .expected_consumed_bytes = 2,
    });
}

pub fn linkAndRunGeneratedStatusAccessors(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTinyGlrParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "x",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
        .extra_driver_declarations =
        \\const char *ts_generated_result_api_status(void);
        \\const char *ts_generated_tree_api_status(void);
        \\bool ts_generated_tree_api_is_tree_sitter_compatible(void);
        \\const char *ts_generated_error_recovery_status(void);
        \\const char *ts_generated_support_boundary_status(void);
        \\const char *ts_generated_corpus_status(void);
        \\const char *ts_generated_external_scanner_status(void);
        \\
        ,
        .after_parser_delete_check =
        \\  const char *result_status = ts_generated_result_api_status();
        \\  const char *tree_status = ts_generated_tree_api_status();
        \\  bool tree_api_compatible = ts_generated_tree_api_is_tree_sitter_compatible();
        \\  const char *recovery_status = ts_generated_error_recovery_status();
        \\  const char *support_status = ts_generated_support_boundary_status();
        \\  const char *corpus_status = ts_generated_corpus_status();
        \\  const char *scanner_status = ts_generated_external_scanner_status();
        \\  if (!result_status || !strstr(result_status, "temporary generated result API")) return 70;
        \\  if (!tree_status || !strstr(tree_status, "temporary project tree API")) return 71;
        \\  if (tree_api_compatible) return 72;
        \\  if (!recovery_status || !strstr(recovery_status, "bounded generated GLR recovery")) return 73;
        \\  if (!support_status || !strstr(support_status, "local generator evidence only")) return 74;
        \\  if (!corpus_status || !strstr(corpus_status, "corpus comparison is not embedded")) return 75;
        \\  if (!scanner_status || !strstr(scanner_status, "scanner-free generated parser")) return 76;
        \\
        ,
    });
}

pub fn linkAndRunUnresolvedShiftReduceGlrParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitUnresolvedShiftReduceGlrParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "x",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
    });
}

pub fn linkAndRecoverMalformedTinyGlrParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTinyGlrParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "xx",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
    });
}

pub fn linkAndRunKeywordReservedParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitKeywordReservedParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "if",
    });
}

pub fn linkAndRunExternalScannerParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitExternalScannerParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = externalScannerSource(),
        .input = "e",
    });
}

pub fn linkAndRunExternalScannerGlrParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitExternalScannerGlrParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = externalScannerSource(),
        .input = "e",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
    });
}

pub fn linkAndRunMultiTokenExternalScannerParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitMultiTokenExternalScannerParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = multiTokenScannerSource(),
        .input = "()",
        .expected_root_type = "source_file",
        .expected_child_types = &.{ "OPEN", "CLOSE" },
    });
}

pub fn linkAndRunMultiTokenExternalScannerGlrParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitMultiTokenExternalScannerGlrParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = multiTokenScannerSource(),
        .input = "()",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 2,
    });
}

pub fn linkAndRunStatefulExternalScannerParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitStatefulExternalScannerParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = statefulScannerSource(),
        .input = "(())",
        .expected_root_type = "source_file",
        .expected_tree_string = "(source_file (item (item)))",
        .extra_driver_declarations =
        \\extern unsigned tree_sitter_stateful_external_grammar_created_count(void);
        \\extern unsigned tree_sitter_stateful_external_grammar_destroyed_count(void);
        \\extern unsigned tree_sitter_stateful_external_grammar_max_depth(void);
        \\
        ,
        .after_parser_delete_check =
        \\  if (tree_sitter_stateful_external_grammar_created_count() != 1) return 30;
        \\  if (tree_sitter_stateful_external_grammar_destroyed_count() != 1) return 31;
        \\  if (tree_sitter_stateful_external_grammar_max_depth() != 2) return 32;
        \\
        ,
    });
}

pub fn linkAndRunForkedStatefulExternalScannerGlrParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitForkedStatefulExternalScannerGlrParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = forkedStatefulScannerSource(),
        .input = "(x)",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 3,
        .extra_driver_declarations =
        \\extern unsigned tree_sitter_forked_stateful_external_grammar_close_a_count(void);
        \\extern unsigned tree_sitter_forked_stateful_external_grammar_close_b_count(void);
        \\extern unsigned tree_sitter_forked_stateful_external_grammar_deserialize_with_branch_count(void);
        \\
        ,
        .after_parser_delete_check =
        \\  if (tree_sitter_forked_stateful_external_grammar_close_a_count() != 1) {
        \\    fprintf(stderr, "close_a=%u\n", tree_sitter_forked_stateful_external_grammar_close_a_count());
        \\    return 60;
        \\  }
        \\  if (tree_sitter_forked_stateful_external_grammar_close_b_count() != 1) {
        \\    fprintf(stderr, "close_b=%u\n", tree_sitter_forked_stateful_external_grammar_close_b_count());
        \\    return 61;
        \\  }
        \\  if (tree_sitter_forked_stateful_external_grammar_deserialize_with_branch_count() < 2) {
        \\    fprintf(stderr, "branch_deserialize=%u\n", tree_sitter_forked_stateful_external_grammar_deserialize_with_branch_count());
        \\    return 62;
        \\  }
        \\
        ,
    });
}

pub fn linkAndRunBracketLangParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitBracketLangParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        bracket_lang_scanner_path,
        arena.allocator(),
        .limited(64 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .input = "(())",
        .expected_root_type = "source",
        .expected_tree_string = "(source (item (open_bracket) (item (open_bracket) (close_bracket)) (close_bracket)))",
    });
}

pub fn linkAndRunTreeSitterJsonParserAcceptedSample(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTreeSitterJsonParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "{\"answer\":42,\"items\":[\"x\"]}",
        .expected_root_type = "document",
        .expected_has_error = false,
    });
}

pub fn linkAndRunTreeSitterJsonParserInvalidSample(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTreeSitterJsonParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "x",
        .expected_has_error = true,
    });
}

pub fn linkAndRunTreeSitterZiggyParserAcceptedSample(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitRuntimeParserCFromGrammarPath(
        arena.allocator(),
        "compat_targets/tree_sitter_ziggy/grammar.json",
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "null",
        .expected_root_type = "document",
        .expected_has_error = false,
    });
}

pub fn linkAndRunTreeSitterZiggyParserInvalidSample(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitRuntimeParserCFromGrammarPath(
        arena.allocator(),
        "compat_targets/tree_sitter_ziggy/grammar.json",
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "@",
        .expected_root_type = "document",
        .expected_has_error = true,
    });
}

pub fn linkAndRunTreeSitterZiggySchemaParserAcceptedSample(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitRuntimeParserCFromGrammarPath(
        arena.allocator(),
        "compat_targets/tree_sitter_ziggy_schema/grammar.json",
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "root = bytes",
        .expected_root_type = "schema",
        .expected_has_error = false,
    });
}

pub fn profileTreeSitterZigRuntimeLinkCandidate(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const serialize_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    var serialized = try parse_table_pipeline.serializeRuntimeTableFromGrammarPathWithBuildOptionsProfile(
        arena.allocator(),
        "compat_targets/tree_sitter_zig/grammar.json",
        .diagnostic,
        .{ .closure_lookahead_mode = .none, .coarse_follow_lookaheads = true },
        "tree_sitter_zig_json",
    );
    std.debug.print(
        "[zig-runtime-link-profile] serialize_ms={d:.2} states={d} blocked={}\n",
        .{ elapsedMs(serialize_timer), serialized.states.len, serialized.blocked },
    );
    dumpZigRuntimeLinkContext(serialized, 149);
    dumpZigRuntimeLinkContext(serialized, 150);
    serialized = try offsetRuntimeStartStateAlloc(arena.allocator(), serialized);
    dumpZigRuntimeLinkContext(serialized, 150);
    dumpZigRuntimeLinkContext(serialized, 151);

    const emit_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const parser_c = try parser_c_emit.emitParserCAllocWithOptions(arena.allocator(), serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    std.debug.print(
        "[zig-runtime-link-profile] emit_parser_c_ms={d:.2} bytes={d}\n",
        .{ elapsedMs(emit_timer), parser_c.len },
    );

    try linkAndRunGeneratedParserWithProfile(allocator, .{
        .parser_c = parser_c,
        .input = "const answer = 42;",
        .expected_has_error = false,
    }, "tree_sitter_zig_json");
}

pub fn linkAndRunTreeSitterZigParserAcceptedSample(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTreeSitterZigParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "const answer = 42;",
        .expected_root_type = "source_file",
        .expected_has_error = false,
    });
}

pub fn linkAndRunTreeSitterZigParserInvalidSample(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTreeSitterZigParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "const answer = ;",
        .expected_has_error = true,
    });
}

fn dumpZigRuntimeLinkContext(serialized: serialize.SerializedTable, state_id: u32) void {
    if (state_id >= serialized.states.len) return;
    const state_value = serialized.states[state_id];
    std.debug.print(
        "[zig-runtime-link-profile] state={d} lex_state={d} actions={d} gotos={d} unresolved={d}\n",
        .{ state_id, state_value.lex_state_id, state_value.actions.len, state_value.gotos.len, state_value.unresolved.len },
    );
    for (state_value.actions[0..@min(state_value.actions.len, 12)]) |entry| {
        std.debug.print(
            "[zig-runtime-link-profile] state={d} action symbol={s} kind={s}\n",
            .{ state_id, symbolName(serialized, entry.symbol), parseActionName(entry.action) },
        );
    }
    if (state_value.actions.len > 12) {
        std.debug.print(
            "[zig-runtime-link-profile] state={d} action_more={d}\n",
            .{ state_id, state_value.actions.len - 12 },
        );
    }
    if (state_value.lex_state_id >= serialized.lex_state_terminal_sets.len) return;
    const terminal_set = serialized.lex_state_terminal_sets[state_value.lex_state_id];
    var printed: usize = 0;
    for (terminal_set, 0..) |present, terminal_id| {
        if (!present) continue;
        if (printed >= 12) break;
        std.debug.print(
            "[zig-runtime-link-profile] state={d} lex_terminal={s}\n",
            .{ state_id, symbolName(serialized, .{ .terminal = @intCast(terminal_id) }) },
        );
        printed += 1;
    }
    var total: usize = 0;
    for (terminal_set) |present| {
        if (present) total += 1;
    }
    if (total > printed) {
        std.debug.print(
            "[zig-runtime-link-profile] state={d} lex_terminal_more={d}\n",
            .{ state_id, total - printed },
        );
    }
}

fn parseActionName(action: parse_actions.ParseAction) []const u8 {
    return switch (action) {
        .shift => "shift",
        .reduce => "reduce",
        .accept => "accept",
    };
}

fn symbolName(serialized: serialize.SerializedTable, symbol: syntax_grammar.SymbolRef) []const u8 {
    for (serialized.symbols) |info| {
        if (symbolRefEql(info.ref, symbol)) return info.name;
    }
    return switch (symbol) {
        .end => "end",
        .terminal => "<terminal>",
        .non_terminal => "<non_terminal>",
        .external => "<external>",
    };
}

fn symbolRefEql(left: syntax_grammar.SymbolRef, right: syntax_grammar.SymbolRef) bool {
    return switch (left) {
        .end => right == .end,
        .terminal => |left_index| right == .terminal and right.terminal == left_index,
        .non_terminal => |left_index| right == .non_terminal and right.non_terminal == left_index,
        .external => |left_index| right == .external and right.external == left_index,
    };
}

pub fn linkAndRunBashParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(bash_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitBashBareDollarParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        bash_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{bash_scanner_include_dir},
        .input = "$\n",
        .expected_root_type = "program",
    });
}

pub fn linkAndRunBashGeneratedGlrParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(bash_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitBashBareDollarGlrParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        bash_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{bash_scanner_include_dir},
        .input = "$",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
    });
}

pub fn linkAndRunJavascriptTernaryParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(javascript_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitJavascriptTernaryParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        javascript_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{javascript_scanner_include_dir},
        .input = "?",
        .expected_root_type = "program",
    });
}

pub fn linkAndRunJavascriptJsxTextParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(javascript_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitJavascriptJsxTextParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        javascript_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{javascript_scanner_include_dir},
        .input = "hello",
        .expected_root_type = "program",
    });
}

pub fn linkAndRunJavascriptTernaryGeneratedGlrParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(javascript_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitJavascriptTernaryGlrParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        javascript_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{javascript_scanner_include_dir},
        .input = "?",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
    });
}

pub fn linkAndRunTypescriptTernaryParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(typescript_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTypescriptTernaryParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        typescript_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{typescript_scanner_include_dir},
        .input = "?",
        .expected_root_type = "program",
    });
}

pub fn linkAndRunTypescriptJsxTextParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(typescript_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTypescriptJsxTextParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        typescript_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{typescript_scanner_include_dir},
        .input = "hello",
        .expected_root_type = "program",
    });
}

pub fn linkAndRunPythonNewlineParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(python_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitPythonNewlineParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        python_scanner_path,
        arena.allocator(),
        .limited(1024 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{python_scanner_include_dir},
        .input = "\n",
        .expected_root_type = "module",
    });
}

pub fn linkAndRunPythonNewlineGeneratedGlrParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(python_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitPythonNewlineGlrParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        python_scanner_path,
        arena.allocator(),
        .limited(1024 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{python_scanner_include_dir},
        .input = "\n",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
    });
}

pub fn linkAndRunPythonStringParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(python_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitPythonStringParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        python_scanner_path,
        arena.allocator(),
        .limited(1024 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{python_scanner_include_dir},
        .input = "\"hi\"",
        .expected_root_type = "module",
    });
}

pub fn linkAndRunRustFloatLiteralParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(rust_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitRustFloatLiteralParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        rust_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{rust_scanner_include_dir},
        .input = "1.0",
        .expected_root_type = "source_file",
    });
}

pub fn linkAndRunRustRawStringParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(rust_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitRustRawStringParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        rust_scanner_path,
        arena.allocator(),
        .limited(512 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{rust_scanner_include_dir},
        .input = "r#\"hi\"#",
        .expected_root_type = "source_file",
    });
}

pub fn linkAndRunHaskellParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(haskell_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitHaskellVarsymParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        haskell_scanner_path,
        arena.allocator(),
        .limited(1024 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{haskell_scanner_include_dir},
        .extra_compile_flags = &.{"-Wno-implicit-function-declaration"},
        .input = "+",
        .expected_root_type = "module",
    });
}

pub fn linkAndRunHaskellGeneratedGlrParserWithRealExternalScanner(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();
    try ensureFileAvailableOrSkip(haskell_scanner_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitHaskellVarsymGlrParserC(arena.allocator());
    const scanner_c = try std.Io.Dir.cwd().readFileAlloc(
        runtime_io.get(),
        haskell_scanner_path,
        arena.allocator(),
        .limited(1024 * 1024),
    );
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .scanner_c = scanner_c,
        .scanner_include_dirs = &.{haskell_scanner_include_dir},
        .extra_compile_flags = &.{"-Wno-implicit-function-declaration"},
        .input = "+",
        .direct_generated_parse = true,
        .expected_consumed_bytes = 1,
    });
}

fn emitTinyParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitTinyParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitTinyGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitTinyParserCWithOptions(allocator, .{
        .offset_start_state = false,
        .glr_loop = true,
    });
}

fn emitUnresolvedShiftReduceGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
        .{ .ref = .{ .terminal = 1 }, .name = "x", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 2 },
    };
    const productions = [_]serialize.SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 0, .dynamic_precedence = 0 },
    };
    const unresolved_candidates = [_]parse_actions.ParseAction{
        .{ .shift = 1 },
        .{ .reduce = 0 },
    };
    const unresolved_entries = [_]serialize.SerializedUnresolvedEntry{
        .{
            .symbol = .{ .terminal = 1 },
            .reason = parse_table_resolution.UnresolvedReason.shift_reduce,
            .candidate_actions = unresolved_candidates[0..],
        },
    };
    const start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 2 },
    };
    const accept_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    };
    const states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = start_gotos[0..], .unresolved = unresolved_entries[0..] },
        .{ .id = 1, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
    };
    const x_ranges = [_]lexer_serialize.SerializedCharacterRange{.{ .start = 'x', .end_inclusive = 'x' }};
    const x_transitions = [_]lexer_serialize.SerializedLexTransition{
        .{ .ranges = x_ranges[0..], .next_state_id = 1, .skip = false },
    };
    const lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = x_transitions[0..] },
        .{ .accept_symbol = .{ .terminal = 1 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = lex_states[0..] },
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
    };
    const primary_state_ids = [_]u32{ 0, 1, 2 };
    const parse_action_list = try serialize.buildParseActionListAlloc(allocator, states[0..], productions[0..]);
    const serialized = serialize.SerializedTable{
        .blocked = true,
        .grammar_name = "unresolved_shift_reduce",
        .symbols = symbols[0..],
        .large_state_count = states.len,
        .productions = productions[0..],
        .parse_action_list = parse_action_list,
        .lex_modes = lex_modes[0..],
        .lex_tables = lex_tables[0..],
        .primary_state_ids = primary_state_ids[0..],
        .states = states[0..],
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
}

fn emitAliasedFieldGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
        .{ .ref = .{ .terminal = 1 }, .name = "x", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        .{ .ref = .{ .terminal = 2 }, .name = "y", .named = false, .visible = true, .supertype = false, .public_symbol = 2 },
        .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 3 },
    };
    const productions = [_]serialize.SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 2, .dynamic_precedence = 0 },
    };
    const start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 2 } },
    };
    const after_x_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 2 }, .action = .{ .shift = 3 } },
    };
    const reduce_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    };
    const accept_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    };
    const start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 4 },
    };
    const states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = after_x_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const x_ranges = [_]lexer_serialize.SerializedCharacterRange{.{ .start = 'x', .end_inclusive = 'x' }};
    const y_ranges = [_]lexer_serialize.SerializedCharacterRange{.{ .start = 'y', .end_inclusive = 'y' }};
    const start_transitions = [_]lexer_serialize.SerializedLexTransition{
        .{ .ranges = x_ranges[0..], .next_state_id = 1, .skip = false },
        .{ .ranges = y_ranges[0..], .next_state_id = 2, .skip = false },
    };
    const lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = start_transitions[0..] },
        .{ .accept_symbol = .{ .terminal = 1 }, .transitions = &.{} },
        .{ .accept_symbol = .{ .terminal = 2 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = lex_states[0..] },
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
    };
    const primary_state_ids = [_]u32{ 0, 1, 2, 3, 4 };
    const alias_sequences = [_]serialize.SerializedAliasEntry{
        .{ .production_id = 0, .step_index = 1, .original_symbol = .{ .terminal = 2 }, .name = "renamed_y", .named = true },
    };
    const field_names = [_]serialize.SerializedFieldName{
        .{ .id = 1, .name = "left" },
    };
    const field_entries = [_]serialize.SerializedFieldMapEntry{
        .{ .field_id = 1, .child_index = 0, .inherited = false },
    };
    const field_slices = [_]serialize.SerializedFieldMapSlice{
        .{ .index = 0, .length = 1 },
    };
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "aliased_field_result",
        .symbols = symbols[0..],
        .large_state_count = states.len,
        .productions = productions[0..],
        .alias_sequences = alias_sequences[0..],
        .field_map = .{
            .names = field_names[0..],
            .entries = field_entries[0..],
            .slices = field_slices[0..],
        },
        .lex_modes = lex_modes[0..],
        .lex_tables = lex_tables[0..],
        .primary_state_ids = primary_state_ids[0..],
        .states = states[0..],
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
}

const TinyParserOptions = struct {
    offset_start_state: bool,
    glr_loop: bool,
};

fn emitTinyParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const rules = [_]ir_rules.Rule{
        .{ .string = "x" },
    };
    var source_steps = [_]syntax_grammar.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const syntax = syntax_grammar.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_grammar.LexicalGrammar{
        .variables = &.{
            .{ .name = "x", .kind = .anonymous, .rule = 0 },
        },
        .separators = &.{},
    };

    const built = try build_parse_table.buildStates(allocator, syntax);
    var serialized = try serialize.serializeBuildResult(allocator, built, .strict);
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{ .ref = .{ .terminal = 0 }, .name = "x", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 2 },
    };
    serialized.grammar_name = "generated";
    serialized.grammar_version = .{ 3, 1, 4 };
    serialized.symbols = symbols[0..];
    const eof_valids = try eofValidLexStatesAlloc(allocator, serialized);
    serialized.lex_tables = try lexer_serialize.buildSerializedLexTablesWithEofAlloc(
        allocator,
        rules[0..],
        lexical,
        serialized.lex_state_terminal_sets,
        eof_valids,
    );
    if (options.offset_start_state) {
        serialized = try offsetRuntimeStartStateAlloc(allocator, serialized);
    }

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn eofValidLexStatesAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) RuntimeLinkError![]const bool {
    const values = try allocator.alloc(bool, serialized.lex_state_terminal_sets.len);
    @memset(values, false);
    for (serialized.states) |state_value| {
        if (state_value.lex_state_id >= values.len) continue;
        for (state_value.actions) |entry| {
            if (entry.symbol == .end) {
                values[state_value.lex_state_id] = true;
                break;
            }
        }
    }
    return values;
}

fn offsetRuntimeStartStateAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) RuntimeLinkError!serialize.SerializedTable {
    const states = try allocator.alloc(serialize.SerializedState, serialized.states.len + 1);
    states[0] = .{
        .id = 0,
        .lex_state_id = 0,
        .actions = &.{},
        .gotos = &.{},
        .unresolved = &.{},
    };
    for (serialized.states, 0..) |source_state, index| {
        const actions = try allocator.alloc(serialize.SerializedActionEntry, source_state.actions.len);
        for (source_state.actions, 0..) |entry, action_index| {
            actions[action_index] = entry;
            if (entry.action == .shift) {
                actions[action_index].action = .{ .shift = entry.action.shift + 1 };
            }
        }
        const gotos = try allocator.alloc(serialize.SerializedGotoEntry, source_state.gotos.len);
        for (source_state.gotos, 0..) |entry, goto_index| {
            gotos[goto_index] = entry;
            gotos[goto_index].state = entry.state + 1;
        }
        states[index + 1] = source_state;
        states[index + 1].id = source_state.id + 1;
        states[index + 1].actions = actions;
        states[index + 1].gotos = gotos;
    }

    const lex_modes = try allocator.alloc(lexer_serialize.SerializedLexMode, serialized.lex_modes.len + 1);
    lex_modes[0] = .{ .lex_state = 0 };
    for (serialized.lex_modes, 0..) |mode, index| {
        lex_modes[index + 1] = mode;
    }

    const primary_state_ids = try allocator.alloc(u32, states.len);
    primary_state_ids[0] = 0;
    for (serialized.primary_state_ids, 0..) |state_id, index| {
        primary_state_ids[index + 1] = state_id + 1;
    }

    var result = serialized;
    result.states = states;
    result.lex_modes = lex_modes;
    result.primary_state_ids = primary_state_ids;
    result.large_state_count = try serialize.computeLargeStateCountAlloc(allocator, states, serialized.productions);
    result.parse_action_list = try serialize.buildParseActionListAlloc(allocator, states, serialized.productions);
    result.small_parse_table = try serialize.buildSmallParseTableAlloc(
        allocator,
        states,
        result.large_state_count,
        result.parse_action_list,
        serialized.productions,
    );
    return result;
}

fn emitKeywordReservedParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
        .{ .ref = .{ .terminal = 1 }, .name = "if", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        .{ .ref = .{ .terminal = 2 }, .name = "identifier", .named = true, .visible = true, .supertype = false, .public_symbol = 2 },
        .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 3 },
    };
    const productions = [_]serialize.SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    };
    const start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 2 } },
    };
    const start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    };
    const reduce_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    };
    const accept_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    };
    const states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const i_ranges = [_]lexer_serialize.SerializedCharacterRange{.{ .start = 'i', .end_inclusive = 'i' }};
    const f_ranges = [_]lexer_serialize.SerializedCharacterRange{.{ .start = 'f', .end_inclusive = 'f' }};
    const main_state0_transitions = [_]lexer_serialize.SerializedLexTransition{
        .{ .ranges = i_ranges[0..], .next_state_id = 1, .skip = false },
    };
    const main_state1_transitions = [_]lexer_serialize.SerializedLexTransition{
        .{ .ranges = f_ranges[0..], .next_state_id = 2, .skip = false },
    };
    const main_lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = main_state0_transitions[0..] },
        .{ .transitions = main_state1_transitions[0..] },
        .{ .accept_symbol = .{ .terminal = 2 }, .transitions = &.{} },
    };
    const keyword_state0_transitions = [_]lexer_serialize.SerializedLexTransition{
        .{ .ranges = i_ranges[0..], .next_state_id = 1, .skip = false },
    };
    const keyword_state1_transitions = [_]lexer_serialize.SerializedLexTransition{
        .{ .ranges = f_ranges[0..], .next_state_id = 2, .skip = false },
    };
    const keyword_lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .transitions = keyword_state0_transitions[0..] },
        .{ .transitions = keyword_state1_transitions[0..] },
        .{ .accept_symbol = .{ .terminal = 1 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = main_lex_states[0..] },
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0, .reserved_word_set_id = 1 },
        .{ .lex_state = 0, .reserved_word_set_id = 1 },
        .{ .lex_state = 0, .reserved_word_set_id = 1 },
        .{ .lex_state = 0, .reserved_word_set_id = 1 },
    };
    const primary_state_ids = [_]u32{ 0, 1, 2, 3 };
    const reserved_set = [_]syntax_grammar.SymbolRef{
        .{ .terminal = 1 },
    };
    const reserved_sets = [_][]const syntax_grammar.SymbolRef{
        &.{},
        reserved_set[0..],
    };
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "generated",
        .symbols = symbols[0..],
        .large_state_count = states.len,
        .productions = productions[0..],
        .lex_modes = lex_modes[0..],
        .lex_tables = lex_tables[0..],
        .keyword_lex_table = .{ .start_state_id = 0, .states = keyword_lex_states[0..] },
        .word_token = .{ .terminal = 2 },
        .reserved_words = .{ .sets = reserved_sets[0..], .max_size = 1 },
        .primary_state_ids = primary_state_ids[0..],
        .states = states[0..],
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
    });
}

fn emitExternalScannerParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitExternalScannerParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitExternalScannerGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitExternalScannerParserCWithOptions(allocator, .{
        .offset_start_state = false,
        .glr_loop = true,
    });
}

fn emitExternalScannerParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
        .{ .ref = .{ .external = 0 }, .name = "external_token", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 2 },
    };
    const productions = [_]serialize.SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    };
    const start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 2 } },
    };
    const start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    };
    const reduce_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    };
    const accept_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    };
    const runtime_states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const glr_start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 1 } },
    };
    const glr_start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 2 },
    };
    const glr_states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = glr_start_actions[0..], .gotos = glr_start_gotos[0..], .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const states = if (options.offset_start_state) runtime_states[0..] else glr_states[0..];
    const lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = lex_states[0..] },
    };
    const runtime_lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 1 },
    };
    const glr_lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 1 },
    };
    const lex_modes = if (options.offset_start_state) runtime_lex_modes[0..] else glr_lex_modes[0..];
    const runtime_primary_state_ids = [_]u32{ 0, 1, 2, 3 };
    const glr_primary_state_ids = [_]u32{ 0, 1, 2 };
    const primary_state_ids = if (options.offset_start_state) runtime_primary_state_ids[0..] else glr_primary_state_ids[0..];
    const external_symbols = [_]syntax_grammar.SymbolRef{
        .{ .external = 0 },
    };
    const external_state_0 = [_]bool{false};
    const external_state_1 = [_]bool{true};
    const external_states = [_][]const bool{
        external_state_0[0..],
        external_state_1[0..],
    };
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "external_grammar",
        .symbols = symbols[0..],
        .large_state_count = states.len,
        .productions = productions[0..],
        .lex_modes = lex_modes,
        .lex_tables = lex_tables[0..],
        .external_scanner = .{
            .symbols = external_symbols[0..],
            .states = external_states[0..],
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitBashBareDollarParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitBashBareDollarParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitBashBareDollarGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitBashBareDollarParserCWithOptions(allocator, .{
        .offset_start_state = false,
        .glr_loop = true,
    });
}

fn emitJavascriptTernaryParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitJavascriptTernaryParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitJavascriptJsxTextParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitJavascriptSingleExternalParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    }, javascript_jsx_text_external_id);
}

fn emitJavascriptTernaryGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitJavascriptTernaryParserCWithOptions(allocator, .{
        .offset_start_state = false,
        .glr_loop = true,
    });
}

fn emitTypescriptTernaryParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitTypescriptTernaryParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitTypescriptJsxTextParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitTypescriptSingleExternalParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    }, typescript_jsx_text_external_id);
}

fn emitPythonNewlineParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitPythonNewlineParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitPythonNewlineGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitPythonNewlineParserCWithOptions(allocator, .{
        .offset_start_state = false,
        .glr_loop = true,
    });
}

fn emitPythonStringParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitPythonStringParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitRustFloatLiteralParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitRustFloatLiteralParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitRustRawStringParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitRustRawStringParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitJavascriptTernaryParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    return try emitJavascriptSingleExternalParserCWithOptions(allocator, options, javascript_ternary_qmark_external_id);
}

fn emitJavascriptSingleExternalParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
    active_external_id: usize,
) RuntimeLinkError![]const u8 {
    const external_names = [_][]const u8{
        "_automatic_semicolon",
        "_template_chars",
        "_ternary_qmark",
        "html_comment",
        "||",
        "escape_sequence",
        "regex_pattern",
        "jsx_text",
    };

    var symbols = try allocator.alloc(serialize.SerializedSymbolInfo, external_names.len + 2);
    symbols[0] = .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 };
    for (external_names, 0..) |name, index| {
        symbols[index + 1] = .{
            .ref = .{ .external = @intCast(index) },
            .name = name,
            .named = index == active_external_id,
            .visible = index == active_external_id,
            .supertype = false,
            .public_symbol = @intCast(index + 1),
        };
    }
    symbols[symbols.len - 1] = .{
        .ref = .{ .non_terminal = 0 },
        .name = "program",
        .named = true,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.len - 1),
    };

    const productions = try allocator.dupe(serialize.SerializedProductionInfo, &.{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    });
    const start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = @intCast(active_external_id) }, .action = .{ .shift = 2 } },
    });
    const start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    });
    const reduce_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    });
    const accept_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    });
    const runtime_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const glr_start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = @intCast(active_external_id) }, .action = .{ .shift = 1 } },
    });
    const glr_start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 2 },
    });
    const glr_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = glr_start_actions, .gotos = glr_start_gotos, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const states = if (options.offset_start_state) runtime_states else glr_states;
    const lex_states = try allocator.dupe(lexer_serialize.SerializedLexState, &.{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    });
    const lex_tables = try allocator.dupe(lexer_serialize.SerializedLexTable, &.{
        .{ .start_state_id = 0, .states = lex_states },
    });
    const runtime_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const glr_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const lex_modes = if (options.offset_start_state) runtime_lex_modes else glr_lex_modes;
    const runtime_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3 });
    const glr_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2 });
    const primary_state_ids = if (options.offset_start_state) runtime_primary_state_ids else glr_primary_state_ids;

    const external_symbols = try allocator.alloc(syntax_grammar.SymbolRef, external_names.len);
    for (external_symbols, 0..) |*symbol, index| {
        symbol.* = .{ .external = @intCast(index) };
    }
    const external_state_0 = try allocator.alloc(bool, external_names.len);
    const external_state_1 = try allocator.alloc(bool, external_names.len);
    @memset(external_state_0, false);
    @memset(external_state_1, false);
    external_state_1[active_external_id] = true;
    const external_states = try allocator.dupe([]const bool, &.{
        external_state_0,
        external_state_1,
    });

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "javascript",
        .symbols = symbols,
        .large_state_count = states.len,
        .productions = productions,
        .lex_modes = lex_modes,
        .lex_tables = lex_tables,
        .external_scanner = .{
            .symbols = external_symbols,
            .states = external_states,
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitTypescriptTernaryParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    return try emitTypescriptSingleExternalParserCWithOptions(allocator, options, typescript_ternary_qmark_external_id);
}

fn emitTypescriptSingleExternalParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
    active_external_id: usize,
) RuntimeLinkError![]const u8 {
    const external_names = [_][]const u8{
        "_automatic_semicolon",
        "_template_chars",
        "_ternary_qmark",
        "html_comment",
        "||",
        "escape_sequence",
        "regex_pattern",
        "jsx_text",
        "_function_signature_automatic_semicolon",
        "__error_recovery",
    };

    var symbols = try allocator.alloc(serialize.SerializedSymbolInfo, external_names.len + 2);
    symbols[0] = .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 };
    for (external_names, 0..) |name, index| {
        symbols[index + 1] = .{
            .ref = .{ .external = @intCast(index) },
            .name = name,
            .named = index == active_external_id,
            .visible = index == active_external_id,
            .supertype = false,
            .public_symbol = @intCast(index + 1),
        };
    }
    symbols[symbols.len - 1] = .{
        .ref = .{ .non_terminal = 0 },
        .name = "program",
        .named = true,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.len - 1),
    };

    const productions = try allocator.dupe(serialize.SerializedProductionInfo, &.{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    });
    const start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = @intCast(active_external_id) }, .action = .{ .shift = 2 } },
    });
    const start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    });
    const reduce_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    });
    const accept_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    });
    const runtime_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const states = runtime_states;
    const lex_states = try allocator.dupe(lexer_serialize.SerializedLexState, &.{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    });
    const lex_tables = try allocator.dupe(lexer_serialize.SerializedLexTable, &.{
        .{ .start_state_id = 0, .states = lex_states },
    });
    const runtime_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const lex_modes = runtime_lex_modes;
    const runtime_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3 });
    const primary_state_ids = runtime_primary_state_ids;

    const external_symbols = try allocator.alloc(syntax_grammar.SymbolRef, external_names.len);
    for (external_symbols, 0..) |*symbol, index| {
        symbol.* = .{ .external = @intCast(index) };
    }
    const external_state_0 = try allocator.alloc(bool, external_names.len);
    const external_state_1 = try allocator.alloc(bool, external_names.len);
    @memset(external_state_0, false);
    @memset(external_state_1, false);
    external_state_1[active_external_id] = true;
    const external_states = try allocator.dupe([]const bool, &.{
        external_state_0,
        external_state_1,
    });

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "typescript",
        .symbols = symbols,
        .large_state_count = states.len,
        .productions = productions,
        .lex_modes = lex_modes,
        .lex_tables = lex_tables,
        .external_scanner = .{
            .symbols = external_symbols,
            .states = external_states,
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitPythonNewlineParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const external_names = [_][]const u8{
        "_newline",
        "_indent",
        "_dedent",
        "string_start",
        "_string_content",
        "escape_interpolation",
        "string_end",
        "comment",
        "]",
        ")",
        "}",
        "except",
    };

    var symbols = try allocator.alloc(serialize.SerializedSymbolInfo, external_names.len + 2);
    symbols[0] = .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 };
    for (external_names, 0..) |name, index| {
        symbols[index + 1] = .{
            .ref = .{ .external = @intCast(index) },
            .name = name,
            .named = false,
            .visible = false,
            .supertype = false,
            .public_symbol = @intCast(index + 1),
        };
    }
    symbols[symbols.len - 1] = .{
        .ref = .{ .non_terminal = 0 },
        .name = "module",
        .named = true,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.len - 1),
    };

    const productions = try allocator.dupe(serialize.SerializedProductionInfo, &.{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    });
    const start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = python_newline_external_id }, .action = .{ .shift = 2 } },
    });
    const start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    });
    const reduce_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    });
    const accept_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    });
    const runtime_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const glr_start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = python_newline_external_id }, .action = .{ .shift = 1 } },
    });
    const glr_start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 2 },
    });
    const glr_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = glr_start_actions, .gotos = glr_start_gotos, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const states = if (options.offset_start_state) runtime_states else glr_states;
    const lex_states = try allocator.dupe(lexer_serialize.SerializedLexState, &.{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    });
    const lex_tables = try allocator.dupe(lexer_serialize.SerializedLexTable, &.{
        .{ .start_state_id = 0, .states = lex_states },
    });
    const runtime_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const glr_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const lex_modes = if (options.offset_start_state) runtime_lex_modes else glr_lex_modes;
    const runtime_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3 });
    const glr_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2 });
    const primary_state_ids = if (options.offset_start_state) runtime_primary_state_ids else glr_primary_state_ids;

    const external_symbols = try allocator.alloc(syntax_grammar.SymbolRef, external_names.len);
    for (external_symbols, 0..) |*symbol, index| {
        symbol.* = .{ .external = @intCast(index) };
    }
    const external_state_0 = try allocator.alloc(bool, external_names.len);
    const external_state_1 = try allocator.alloc(bool, external_names.len);
    @memset(external_state_0, false);
    @memset(external_state_1, false);
    external_state_1[python_newline_external_id] = true;
    const external_states = try allocator.dupe([]const bool, &.{
        external_state_0,
        external_state_1,
    });

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "python",
        .symbols = symbols,
        .large_state_count = states.len,
        .productions = productions,
        .lex_modes = lex_modes,
        .lex_tables = lex_tables,
        .external_scanner = .{
            .symbols = external_symbols,
            .states = external_states,
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitPythonStringParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const python_string_start_external_id = 3;
    const python_string_content_external_id = 4;
    const python_string_end_external_id = 6;
    const external_names = [_][]const u8{
        "_newline",
        "_indent",
        "_dedent",
        "string_start",
        "_string_content",
        "escape_interpolation",
        "string_end",
        "comment",
        "]",
        ")",
        "}",
        "except",
    };

    var symbols = try allocator.alloc(serialize.SerializedSymbolInfo, external_names.len + 2);
    symbols[0] = .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 };
    for (external_names, 0..) |name, index| {
        symbols[index + 1] = .{
            .ref = .{ .external = @intCast(index) },
            .name = name,
            .named = index == python_string_content_external_id,
            .visible = index == python_string_content_external_id,
            .supertype = false,
            .public_symbol = @intCast(index + 1),
        };
    }
    symbols[symbols.len - 1] = .{
        .ref = .{ .non_terminal = 0 },
        .name = "module",
        .named = true,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.len - 1),
    };

    const productions = try allocator.dupe(serialize.SerializedProductionInfo, &.{
        .{ .lhs = 0, .child_count = 3, .dynamic_precedence = 0 },
    });
    const start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = python_string_start_external_id }, .action = .{ .shift = 2 } },
    });
    const content_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = python_string_content_external_id }, .action = .{ .shift = 3 } },
    });
    const end_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = python_string_end_external_id }, .action = .{ .shift = 4 } },
    });
    const reduce_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    });
    const accept_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    });
    const start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 5 },
    });
    const states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = content_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = end_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 5, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });

    const lex_states = try allocator.dupe(lexer_serialize.SerializedLexState, &.{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    });
    const lex_tables = try allocator.dupe(lexer_serialize.SerializedLexTable, &.{
        .{ .start_state_id = 0, .states = lex_states },
    });
    const lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 2 },
        .{ .lex_state = 0, .external_lex_state = 3 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 5 });

    const external_symbols = try allocator.alloc(syntax_grammar.SymbolRef, external_names.len);
    for (external_symbols, 0..) |*symbol, index| {
        symbol.* = .{ .external = @intCast(index) };
    }
    const external_state_0 = try allocator.alloc(bool, external_names.len);
    const external_state_1 = try allocator.alloc(bool, external_names.len);
    const external_state_2 = try allocator.alloc(bool, external_names.len);
    const external_state_3 = try allocator.alloc(bool, external_names.len);
    @memset(external_state_0, false);
    @memset(external_state_1, false);
    @memset(external_state_2, false);
    @memset(external_state_3, false);
    external_state_1[python_string_start_external_id] = true;
    external_state_2[python_string_content_external_id] = true;
    external_state_3[python_string_content_external_id] = true;
    external_state_3[python_string_end_external_id] = true;
    const external_states = try allocator.dupe([]const bool, &.{
        external_state_0,
        external_state_1,
        external_state_2,
        external_state_3,
    });

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "python",
        .symbols = symbols,
        .large_state_count = states.len,
        .productions = productions,
        .lex_modes = lex_modes,
        .lex_tables = lex_tables,
        .external_scanner = .{
            .symbols = external_symbols,
            .states = external_states,
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitRustFloatLiteralParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const external_names = [_][]const u8{
        "string_content",
        "string_close",
        "_raw_string_literal_start",
        "raw_string_literal_content",
        "_raw_string_literal_end",
        "float_literal",
        "_outer_block_doc_comment_marker",
        "_inner_block_doc_comment_marker",
        "_block_comment_content",
        "_line_doc_content",
        "_error_sentinel",
    };

    var symbols = try allocator.alloc(serialize.SerializedSymbolInfo, external_names.len + 2);
    symbols[0] = .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 };
    for (external_names, 0..) |name, index| {
        symbols[index + 1] = .{
            .ref = .{ .external = @intCast(index) },
            .name = name,
            .named = index == rust_float_literal_external_id,
            .visible = index == rust_float_literal_external_id,
            .supertype = false,
            .public_symbol = @intCast(index + 1),
        };
    }
    symbols[symbols.len - 1] = .{
        .ref = .{ .non_terminal = 0 },
        .name = "source_file",
        .named = true,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.len - 1),
    };

    const productions = try allocator.dupe(serialize.SerializedProductionInfo, &.{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    });
    const start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = rust_float_literal_external_id }, .action = .{ .shift = 2 } },
    });
    const start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    });
    const reduce_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    });
    const accept_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    });
    const runtime_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const states = runtime_states;
    const lex_states = try allocator.dupe(lexer_serialize.SerializedLexState, &.{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    });
    const lex_tables = try allocator.dupe(lexer_serialize.SerializedLexTable, &.{
        .{ .start_state_id = 0, .states = lex_states },
    });
    const runtime_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const lex_modes = runtime_lex_modes;
    const runtime_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3 });
    const primary_state_ids = runtime_primary_state_ids;

    const external_symbols = try allocator.alloc(syntax_grammar.SymbolRef, external_names.len);
    for (external_symbols, 0..) |*symbol, index| {
        symbol.* = .{ .external = @intCast(index) };
    }
    const external_state_0 = try allocator.alloc(bool, external_names.len);
    const external_state_1 = try allocator.alloc(bool, external_names.len);
    @memset(external_state_0, false);
    @memset(external_state_1, false);
    external_state_1[rust_float_literal_external_id] = true;
    const external_states = try allocator.dupe([]const bool, &.{
        external_state_0,
        external_state_1,
    });

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "rust",
        .symbols = symbols,
        .large_state_count = states.len,
        .productions = productions,
        .lex_modes = lex_modes,
        .lex_tables = lex_tables,
        .external_scanner = .{
            .symbols = external_symbols,
            .states = external_states,
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitRustRawStringParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const raw_string_start_external_id = 2;
    const raw_string_content_external_id = 3;
    const raw_string_end_external_id = 4;
    const external_names = [_][]const u8{
        "string_content",
        "string_close",
        "_raw_string_literal_start",
        "raw_string_literal_content",
        "_raw_string_literal_end",
        "float_literal",
        "_outer_block_doc_comment_marker",
        "_inner_block_doc_comment_marker",
        "_block_comment_content",
        "_line_doc_content",
        "_error_sentinel",
    };

    var symbols = try allocator.alloc(serialize.SerializedSymbolInfo, external_names.len + 2);
    symbols[0] = .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 };
    for (external_names, 0..) |name, index| {
        symbols[index + 1] = .{
            .ref = .{ .external = @intCast(index) },
            .name = name,
            .named = index == raw_string_content_external_id,
            .visible = index == raw_string_content_external_id,
            .supertype = false,
            .public_symbol = @intCast(index + 1),
        };
    }
    symbols[symbols.len - 1] = .{
        .ref = .{ .non_terminal = 0 },
        .name = "source_file",
        .named = true,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.len - 1),
    };

    const productions = try allocator.dupe(serialize.SerializedProductionInfo, &.{
        .{ .lhs = 0, .child_count = 3, .dynamic_precedence = 0 },
    });
    const start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = raw_string_start_external_id }, .action = .{ .shift = 2 } },
    });
    const content_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = raw_string_content_external_id }, .action = .{ .shift = 3 } },
    });
    const end_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = raw_string_end_external_id }, .action = .{ .shift = 4 } },
    });
    const reduce_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    });
    const accept_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    });
    const start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 5 },
    });
    const states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = content_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = end_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 5, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const lex_states = try allocator.dupe(lexer_serialize.SerializedLexState, &.{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    });
    const lex_tables = try allocator.dupe(lexer_serialize.SerializedLexTable, &.{
        .{ .start_state_id = 0, .states = lex_states },
    });
    const lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 2 },
        .{ .lex_state = 0, .external_lex_state = 3 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 5 });

    const external_symbols = try allocator.alloc(syntax_grammar.SymbolRef, external_names.len);
    for (external_symbols, 0..) |*symbol, index| {
        symbol.* = .{ .external = @intCast(index) };
    }
    const external_state_0 = try allocator.alloc(bool, external_names.len);
    const external_state_1 = try allocator.alloc(bool, external_names.len);
    const external_state_2 = try allocator.alloc(bool, external_names.len);
    const external_state_3 = try allocator.alloc(bool, external_names.len);
    @memset(external_state_0, false);
    @memset(external_state_1, false);
    @memset(external_state_2, false);
    @memset(external_state_3, false);
    external_state_1[raw_string_start_external_id] = true;
    external_state_2[raw_string_content_external_id] = true;
    external_state_3[raw_string_end_external_id] = true;
    const external_states = try allocator.dupe([]const bool, &.{
        external_state_0,
        external_state_1,
        external_state_2,
        external_state_3,
    });

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "rust",
        .symbols = symbols,
        .large_state_count = states.len,
        .productions = productions,
        .lex_modes = lex_modes,
        .lex_tables = lex_tables,
        .external_scanner = .{
            .symbols = external_symbols,
            .states = external_states,
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitBashBareDollarParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const external_names = [_][]const u8{
        "heredoc_start",
        "simple_heredoc_body",
        "heredoc_body_beginning",
        "heredoc_content",
        "heredoc_end",
        "file_descriptor",
        "empty_value",
        "concat",
        "variable_name",
        "test_operator",
        "regex",
        "regex_no_slash",
        "regex_no_space",
        "expansion_word",
        "extglob_pattern",
        "bare_dollar",
        "brace_start",
        "immediate_double_hash",
        "external_expansion_sym_hash",
        "external_expansion_sym_bang",
        "external_expansion_sym_equal",
        "closing_brace",
        "closing_bracket",
        "heredoc_arrow",
        "heredoc_arrow_dash",
        "newline",
        "opening_paren",
        "esac",
        "error_recovery",
    };

    var symbols = try allocator.alloc(serialize.SerializedSymbolInfo, external_names.len + 2);
    symbols[0] = .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 };
    for (external_names, 0..) |name, index| {
        symbols[index + 1] = .{
            .ref = .{ .external = @intCast(index) },
            .name = name,
            .named = index != haskell_update_external_id and index != haskell_start_external_id,
            .visible = index != haskell_update_external_id and index != haskell_start_external_id,
            .supertype = false,
            .public_symbol = @intCast(index + 1),
        };
    }
    symbols[symbols.len - 1] = .{
        .ref = .{ .non_terminal = 0 },
        .name = "program",
        .named = true,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.len - 1),
    };

    const productions = try allocator.dupe(serialize.SerializedProductionInfo, &.{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    });
    const start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = bash_bare_dollar_external_id }, .action = .{ .shift = 2 } },
    });
    const start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    });
    const reduce_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    });
    const accept_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    });
    const runtime_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const glr_start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = bash_bare_dollar_external_id }, .action = .{ .shift = 1 } },
    });
    const glr_start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 2 },
    });
    const glr_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = glr_start_actions, .gotos = glr_start_gotos, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const states = if (options.offset_start_state) runtime_states else glr_states;
    const lex_states = try allocator.dupe(lexer_serialize.SerializedLexState, &.{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    });
    const lex_tables = try allocator.dupe(lexer_serialize.SerializedLexTable, &.{
        .{ .start_state_id = 0, .states = lex_states },
    });
    const runtime_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const glr_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const lex_modes = if (options.offset_start_state) runtime_lex_modes else glr_lex_modes;
    const runtime_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3 });
    const glr_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2 });
    const primary_state_ids = if (options.offset_start_state) runtime_primary_state_ids else glr_primary_state_ids;

    const external_symbols = try allocator.alloc(syntax_grammar.SymbolRef, external_names.len);
    for (external_symbols, 0..) |*symbol, index| {
        symbol.* = .{ .external = @intCast(index) };
    }
    const external_state_0 = try allocator.alloc(bool, external_names.len);
    const external_state_1 = try allocator.alloc(bool, external_names.len);
    @memset(external_state_0, false);
    @memset(external_state_1, false);
    external_state_1[bash_bare_dollar_external_id] = true;
    const external_states = try allocator.dupe([]const bool, &.{
        external_state_0,
        external_state_1,
    });

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "bash",
        .symbols = symbols,
        .large_state_count = states.len,
        .productions = productions,
        .lex_modes = lex_modes,
        .lex_tables = lex_tables,
        .external_scanner = .{
            .symbols = external_symbols,
            .states = external_states,
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitHaskellVarsymParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitHaskellVarsymParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitHaskellVarsymGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitHaskellVarsymParserCWithOptions(allocator, .{
        .offset_start_state = false,
        .glr_loop = true,
    });
}

fn emitHaskellVarsymParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const external_names = [_][]const u8{
        "fail",
        "semicolon",
        "start",
        "start_do",
        "start_case",
        "start_if",
        "start_let",
        "start_quote",
        "start_explicit",
        "end",
        "end_explicit",
        "start_brace",
        "end_brace",
        "start_texp",
        "end_texp",
        "where",
        "in",
        "arrow",
        "bar",
        "deriving",
        "comment",
        "haddock",
        "cpp",
        "pragma",
        "qq_start",
        "qq_body",
        "splice",
        "qual_dot",
        "tight_dot",
        "prefix_dot",
        "dotdot",
        "tight_at",
        "prefix_at",
        "tight_bang",
        "prefix_bang",
        "tight_tilde",
        "prefix_tilde",
        "prefix_percent",
        "qualified_op",
        "left_section_op",
        "no_section_op",
        "minus",
        "context",
        "infix",
        "data_infix",
        "type_instance",
        "varsym",
        "consym",
        "update",
    };

    var symbols = try allocator.alloc(serialize.SerializedSymbolInfo, external_names.len + 2);
    symbols[0] = .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 };
    for (external_names, 0..) |name, index| {
        symbols[index + 1] = .{
            .ref = .{ .external = @intCast(index) },
            .name = name,
            .named = true,
            .visible = true,
            .supertype = false,
            .public_symbol = @intCast(index + 1),
        };
    }
    symbols[symbols.len - 1] = .{
        .ref = .{ .non_terminal = 0 },
        .name = "module",
        .named = true,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.len - 1),
    };

    const productions = try allocator.dupe(serialize.SerializedProductionInfo, &.{
        .{ .lhs = 0, .child_count = 3, .dynamic_precedence = 0 },
    });
    const start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = haskell_update_external_id }, .action = .{ .shift = 2 } },
    });
    const after_update_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = haskell_start_external_id }, .action = .{ .shift = 3 } },
    });
    const after_start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = haskell_varsym_external_id }, .action = .{ .shift = 4 } },
    });
    const start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 6 },
    });
    const reduce_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    });
    const accept_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    });
    const runtime_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = after_update_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = after_start_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 5, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 6, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const glr_start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = haskell_update_external_id }, .action = .{ .shift = 1 } },
    });
    const glr_after_update_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = haskell_start_external_id }, .action = .{ .shift = 2 } },
    });
    const glr_after_start_actions = try allocator.dupe(serialize.SerializedActionEntry, &.{
        .{ .symbol = .{ .external = haskell_varsym_external_id }, .action = .{ .shift = 3 } },
    });
    const glr_start_gotos = try allocator.dupe(serialize.SerializedGotoEntry, &.{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 4 },
    });
    const glr_states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = glr_start_actions, .gotos = glr_start_gotos, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = glr_after_update_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = glr_after_start_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
    });
    const states = if (options.offset_start_state) runtime_states else glr_states;
    const lex_states = try allocator.dupe(lexer_serialize.SerializedLexState, &.{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    });
    const lex_tables = try allocator.dupe(lexer_serialize.SerializedLexTable, &.{
        .{ .start_state_id = 0, .states = lex_states },
    });
    const runtime_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 2 },
        .{ .lex_state = 0, .external_lex_state = 3 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const glr_lex_modes = try allocator.dupe(lexer_serialize.SerializedLexMode, &.{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 2 },
        .{ .lex_state = 0, .external_lex_state = 3 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const lex_modes = if (options.offset_start_state) runtime_lex_modes else glr_lex_modes;
    const runtime_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 5, 6 });
    const glr_primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4 });
    const primary_state_ids = if (options.offset_start_state) runtime_primary_state_ids else glr_primary_state_ids;

    const external_symbols = try allocator.alloc(syntax_grammar.SymbolRef, external_names.len);
    for (external_symbols, 0..) |*symbol, index| {
        symbol.* = .{ .external = @intCast(index) };
    }
    const external_state_0 = try allocator.alloc(bool, external_names.len);
    const external_state_1 = try allocator.alloc(bool, external_names.len);
    const external_state_2 = try allocator.alloc(bool, external_names.len);
    const external_state_3 = try allocator.alloc(bool, external_names.len);
    @memset(external_state_0, false);
    @memset(external_state_1, false);
    @memset(external_state_2, false);
    @memset(external_state_3, false);
    external_state_1[haskell_update_external_id] = true;
    external_state_2[haskell_start_external_id] = true;
    external_state_3[haskell_varsym_external_id] = true;
    const external_states = try allocator.dupe([]const bool, &.{
        external_state_0,
        external_state_1,
        external_state_2,
        external_state_3,
    });

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "haskell",
        .symbols = symbols,
        .large_state_count = states.len,
        .productions = productions,
        .lex_modes = lex_modes,
        .lex_tables = lex_tables,
        .external_scanner = .{
            .symbols = external_symbols,
            .states = external_states,
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitMultiTokenExternalScannerParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitMultiTokenExternalScannerParserCWithOptions(allocator, .{
        .offset_start_state = true,
        .glr_loop = false,
    });
}

fn emitMultiTokenExternalScannerGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitMultiTokenExternalScannerParserCWithOptions(allocator, .{
        .offset_start_state = false,
        .glr_loop = true,
    });
}

fn emitMultiTokenExternalScannerParserCWithOptions(
    allocator: std.mem.Allocator,
    options: TinyParserOptions,
) RuntimeLinkError![]const u8 {
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
        .{ .ref = .{ .external = 0 }, .name = "OPEN", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        .{ .ref = .{ .external = 1 }, .name = "CLOSE", .named = false, .visible = true, .supertype = false, .public_symbol = 2 },
        .{ .ref = .{ .external = 2 }, .name = "ERROR_SENTINEL", .named = false, .visible = false, .supertype = false, .public_symbol = 3 },
        .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 4 },
    };
    const productions = [_]serialize.SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 2, .dynamic_precedence = 0 },
    };
    const start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 2 } },
    };
    const start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 4 },
    };
    const close_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 1 }, .action = .{ .shift = 3 } },
    };
    const reduce_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    };
    const accept_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    };
    const runtime_states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = close_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const glr_start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 1 } },
    };
    const glr_close_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 1 }, .action = .{ .shift = 2 } },
    };
    const glr_start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 4 },
    };
    const glr_states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = glr_start_actions[0..], .gotos = glr_start_gotos[0..], .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = glr_close_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const states = if (options.offset_start_state) runtime_states[0..] else glr_states[0..];
    const lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = lex_states[0..] },
    };
    const runtime_lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 2 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    };
    const glr_lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 2 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    };
    const lex_modes = if (options.offset_start_state) runtime_lex_modes[0..] else glr_lex_modes[0..];
    const runtime_primary_state_ids = [_]u32{ 0, 1, 2, 3, 4 };
    const glr_primary_state_ids = [_]u32{ 0, 1, 2, 3, 4 };
    const primary_state_ids = if (options.offset_start_state) runtime_primary_state_ids[0..] else glr_primary_state_ids[0..];
    const external_symbols = [_]syntax_grammar.SymbolRef{
        .{ .external = 0 },
        .{ .external = 1 },
        .{ .external = 2 },
    };
    const external_state_0 = [_]bool{ false, false, false };
    const external_state_1 = [_]bool{ true, false, false };
    const external_state_2 = [_]bool{ false, true, false };
    const external_states = [_][]const bool{
        external_state_0[0..],
        external_state_1[0..],
        external_state_2[0..],
    };
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "multi_external_grammar",
        .symbols = symbols[0..],
        .large_state_count = states.len,
        .productions = productions[0..],
        .lex_modes = lex_modes,
        .lex_tables = lex_tables[0..],
        .external_scanner = .{
            .symbols = external_symbols[0..],
            .states = external_states[0..],
        },
        .primary_state_ids = primary_state_ids,
        .states = states,
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = options.glr_loop,
    });
}

fn emitStatefulExternalScannerParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
        .{ .ref = .{ .external = 0 }, .name = "OPEN", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        .{ .ref = .{ .external = 1 }, .name = "CLOSE", .named = false, .visible = true, .supertype = false, .public_symbol = 2 },
        .{ .ref = .{ .external = 2 }, .name = "ERROR_SENTINEL", .named = false, .visible = false, .supertype = false, .public_symbol = 3 },
        .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 4 },
        .{ .ref = .{ .non_terminal = 1 }, .name = "item", .named = true, .visible = true, .supertype = false, .public_symbol = 5 },
    };
    const productions = [_]serialize.SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
        .{ .lhs = 1, .child_count = 3, .dynamic_precedence = 0 },
        .{ .lhs = 1, .child_count = 2, .dynamic_precedence = 0 },
    };
    const start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 2 } },
    };
    const start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 8 },
        .{ .symbol = .{ .non_terminal = 1 }, .state = 7 },
    };
    const nested_start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 2 } },
        .{ .symbol = .{ .external = 1 }, .action = .{ .shift = 3 } },
    };
    const nested_start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 1 }, .state = 4 },
    };
    const short_item_reduce_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 2 } },
        .{ .symbol = .{ .external = 1 }, .action = .{ .reduce = 2 } },
    };
    const after_nested_item_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 1 }, .action = .{ .shift = 5 } },
    };
    const nested_item_reduce_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
        .{ .symbol = .{ .external = 1 }, .action = .{ .reduce = 1 } },
    };
    const source_reduce_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    };
    const accept_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    };
    const states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = nested_start_actions[0..], .gotos = nested_start_gotos[0..], .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = short_item_reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = after_nested_item_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 5, .lex_state_id = 0, .actions = nested_item_reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 6, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 7, .lex_state_id = 0, .actions = source_reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 8, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = lex_states[0..] },
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 2 },
        .{ .lex_state = 0, .external_lex_state = 3 },
        .{ .lex_state = 0, .external_lex_state = 3 },
        .{ .lex_state = 0, .external_lex_state = 3 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    };
    const primary_state_ids = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const external_symbols = [_]syntax_grammar.SymbolRef{
        .{ .external = 0 },
        .{ .external = 1 },
        .{ .external = 2 },
    };
    const external_state_0 = [_]bool{ false, false, false };
    const external_state_1 = [_]bool{ true, false, false };
    const external_state_2 = [_]bool{ true, true, false };
    const external_state_3 = [_]bool{ false, true, false };
    const external_states = [_][]const bool{
        external_state_0[0..],
        external_state_1[0..],
        external_state_2[0..],
        external_state_3[0..],
    };
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "stateful_external_grammar",
        .symbols = symbols[0..],
        .large_state_count = states.len,
        .productions = productions[0..],
        .lex_modes = lex_modes[0..],
        .lex_tables = lex_tables[0..],
        .external_scanner = .{
            .symbols = external_symbols[0..],
            .states = external_states[0..],
        },
        .primary_state_ids = primary_state_ids[0..],
        .states = states[0..],
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
    });
}

fn emitBracketLangParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    var serialized = try parse_table_pipeline.serializeRuntimeTableFromGrammarPath(
        allocator,
        bracket_lang_grammar_path,
        .strict,
    );
    serialized = try offsetRuntimeStartStateAlloc(allocator, serialized);
    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
    });
}

fn emitForkedStatefulExternalScannerGlrParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{ .ref = .{ .terminal = 0 }, .name = "end", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
        .{ .ref = .{ .external = 0 }, .name = "OPEN", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        .{ .ref = .{ .external = 1 }, .name = "BRANCH", .named = false, .visible = true, .supertype = false, .public_symbol = 2 },
        .{ .ref = .{ .external = 2 }, .name = "CLOSE_A", .named = false, .visible = true, .supertype = false, .public_symbol = 3 },
        .{ .ref = .{ .external = 3 }, .name = "CLOSE_B", .named = false, .visible = true, .supertype = false, .public_symbol = 4 },
        .{ .ref = .{ .external = 4 }, .name = "ERROR_SENTINEL", .named = false, .visible = false, .supertype = false, .public_symbol = 5 },
        .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 6 },
    };
    const productions = [_]serialize.SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 3, .dynamic_precedence = 0 },
        .{ .lhs = 0, .child_count = 3, .dynamic_precedence = 0 },
    };
    const start_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 1 } },
    };
    const start_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 6 },
    };
    const branch_candidates = [_]parse_actions.ParseAction{
        .{ .shift = 2 },
        .{ .shift = 3 },
    };
    const branch_unresolved = [_]serialize.SerializedUnresolvedEntry{
        .{
            .symbol = .{ .external = 1 },
            .reason = .shift_reduce_expected,
            .candidate_actions = branch_candidates[0..],
        },
    };
    const close_a_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 2 }, .action = .{ .shift = 4 } },
    };
    const close_b_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .external = 3 }, .action = .{ .shift = 5 } },
    };
    const reduce_a_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    };
    const reduce_b_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 1 } },
    };
    const accept_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    };
    const states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = branch_unresolved[0..] },
        .{ .id = 2, .lex_state_id = 0, .actions = close_a_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = close_b_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = reduce_a_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 5, .lex_state_id = 0, .actions = reduce_b_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 6, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = lex_states[0..] },
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 2 },
        .{ .lex_state = 0, .external_lex_state = 3 },
        .{ .lex_state = 0, .external_lex_state = 4 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    };
    const primary_state_ids = [_]u32{ 0, 1, 2, 3, 4, 5, 6 };
    const external_symbols = [_]syntax_grammar.SymbolRef{
        .{ .external = 0 },
        .{ .external = 1 },
        .{ .external = 2 },
        .{ .external = 3 },
        .{ .external = 4 },
    };
    const external_state_0 = [_]bool{ false, false, false, false, false };
    const external_state_1 = [_]bool{ true, false, false, false, false };
    const external_state_2 = [_]bool{ false, true, false, false, false };
    const external_state_3 = [_]bool{ false, false, true, false, false };
    const external_state_4 = [_]bool{ false, false, false, true, false };
    const external_states = [_][]const bool{
        external_state_0[0..],
        external_state_1[0..],
        external_state_2[0..],
        external_state_3[0..],
        external_state_4[0..],
    };
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "forked_stateful_external_grammar",
        .symbols = symbols[0..],
        .large_state_count = states.len,
        .productions = productions[0..],
        .lex_modes = lex_modes[0..],
        .lex_tables = lex_tables[0..],
        .external_scanner = .{
            .symbols = external_symbols[0..],
            .states = external_states[0..],
        },
        .primary_state_ids = primary_state_ids[0..],
        .states = states[0..],
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
}

fn emitTreeSitterJsonParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    return try emitRuntimeParserCFromGrammarPath(
        allocator,
        "compat_targets/tree_sitter_json/grammar.json",
    );
}

fn emitTreeSitterZigParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    var serialized = try parse_table_pipeline.serializeRuntimeTableFromGrammarPathWithBuildOptions(
        allocator,
        "compat_targets/tree_sitter_zig/grammar.json",
        .diagnostic,
        .{ .closure_lookahead_mode = .none, .coarse_follow_lookaheads = true },
    );
    serialized = try offsetRuntimeStartStateAlloc(allocator, serialized);
    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
}

fn emitRuntimeParserCFromGrammarPath(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
) RuntimeLinkError![]const u8 {
    var serialized = try parse_table_pipeline.serializeRuntimeTableFromGrammarPath(
        allocator,
        grammar_path,
        .strict,
    );
    serialized = try offsetRuntimeStartStateAlloc(allocator, serialized);
    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
    });
}

const GeneratedParserRun = struct {
    parser_c: []const u8,
    input: []const u8,
    scanner_c: ?[]const u8 = null,
    scanner_include_dirs: []const []const u8 = &.{},
    extra_compile_flags: []const []const u8 = &.{},
    language_function_name: []const u8 = "tree_sitter_generated",
    expected_metadata: ?[3]u8 = null,
    expected_root_type: ?[]const u8 = null,
    expected_child_types: []const []const u8 = &.{},
    expected_tree_string: ?[]const u8 = null,
    expected_has_error: ?bool = null,
    direct_generated_parse: bool = false,
    direct_generated_result: bool = false,
    expected_direct_parse_success: bool = true,
    expected_consumed_bytes: ?u32 = null,
    extra_driver_declarations: []const u8 = "",
    after_parser_delete_check: []const u8 = "",
};

fn linkAndRunGeneratedParser(
    allocator: std.mem.Allocator,
    generated: GeneratedParserRun,
) RuntimeLinkError!void {
    return try linkAndRunGeneratedParserMaybeProfile(allocator, generated, null);
}

fn linkAndRunGeneratedParserWithProfile(
    allocator: std.mem.Allocator,
    generated: GeneratedParserRun,
    label: []const u8,
) RuntimeLinkError!void {
    return try linkAndRunGeneratedParserMaybeProfile(allocator, generated, label);
}

fn linkAndRunGeneratedParserMaybeProfile(
    allocator: std.mem.Allocator,
    generated: GeneratedParserRun,
    profile_label: ?[]const u8,
) RuntimeLinkError!void {
    const timestamp = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const tmp_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/runtime-link-{d}",
        .{timestamp.nanoseconds},
    );
    defer allocator.free(tmp_path);
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), tmp_path);
    defer std.Io.Dir.cwd().deleteTree(runtime_io.get(), tmp_path) catch {};

    var tmp_dir = try std.Io.Dir.cwd().openDir(runtime_io.get(), tmp_path, .{});
    defer tmp_dir.close(runtime_io.get());

    try tmp_dir.writeFile(runtime_io.get(), .{
        .sub_path = "parser.c",
        .data = generated.parser_c,
    });
    if (generated.scanner_c) |scanner_c| {
        try tmp_dir.writeFile(runtime_io.get(), .{
            .sub_path = "scanner.c",
            .data = scanner_c,
        });
    }
    const driver_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const driver_source = try driverSourceAlloc(allocator, generated);
    defer allocator.free(driver_source);
    try tmp_dir.writeFile(runtime_io.get(), .{
        .sub_path = "driver.c",
        .data = driver_source,
    });
    if (profile_label) |label| {
        std.debug.print("[zig-runtime-link-profile] {s} driver_source_ms={d:.2} bytes={d}\n", .{
            label,
            elapsedMs(driver_timer),
            driver_source.len,
        });
    }

    const parser_path = try tmp_dir.realPathFileAlloc(runtime_io.get(), "parser.c", allocator);
    defer allocator.free(parser_path);
    const driver_path = try tmp_dir.realPathFileAlloc(runtime_io.get(), "driver.c", allocator);
    defer allocator.free(driver_path);
    const scanner_path = if (generated.scanner_c != null)
        try tmp_dir.realPathFileAlloc(runtime_io.get(), "scanner.c", allocator)
    else
        null;
    defer if (scanner_path) |path| allocator.free(path);
    const dir_path = try tmp_dir.realPathFileAlloc(runtime_io.get(), ".", allocator);
    defer allocator.free(dir_path);
    const exe_path = try std.fs.path.join(allocator, &.{ dir_path, "driver" });
    defer allocator.free(exe_path);

    var compile_args = std.array_list.Managed([]const u8).init(allocator);
    defer compile_args.deinit();
    try compile_args.appendSlice(&.{
        "zig", "cc",                    "-std=c11", "-D_GNU_SOURCE",
        "-I",  tree_sitter_include_dir,
    });
    for (generated.scanner_include_dirs) |include_dir| {
        try compile_args.appendSlice(&.{ "-I", include_dir });
    }
    try compile_args.appendSlice(&.{
        "-I",
        tree_sitter_runtime_dir,
        driver_path,
        parser_path,
    });
    try compile_args.appendSlice(generated.extra_compile_flags);
    if (scanner_path) |path| try compile_args.append(path);
    try compile_args.appendSlice(&.{ "../tree-sitter/lib/src/lib.c", "-o", exe_path });

    if (profile_label) |label| {
        std.debug.print("[zig-runtime-link-profile] {s} compile_start\n", .{label});
    }
    const compile_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    var compile_result = try process_support.runCapture(allocator, compile_args.items);
    defer compile_result.deinit(allocator);
    if (profile_label) |label| {
        std.debug.print("[zig-runtime-link-profile] {s} compile_ms={d:.2}\n", .{ label, elapsedMs(compile_timer) });
    }

    switch (compile_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("runtime link compile failed:\n{s}\n", .{compile_result.stderr});
            return error.RuntimeLinkCompileFailed;
        },
        else => return error.RuntimeLinkCompileTerminated,
    }

    if (profile_label) |label| {
        std.debug.print("[zig-runtime-link-profile] {s} run_start\n", .{label});
    }
    const run_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    var run_result = try process_support.runCapture(allocator, &.{exe_path});
    defer run_result.deinit(allocator);
    if (profile_label) |label| {
        std.debug.print("[zig-runtime-link-profile] {s} run_ms={d:.2}\n", .{ label, elapsedMs(run_timer) });
    }

    switch (run_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("runtime link driver failed code={d}\nstdout:\n{s}\nstderr:\n{s}\n", .{
                code,
                run_result.stdout,
                run_result.stderr,
            });
            return error.RuntimeLinkDriverFailed;
        },
        else => {
            std.debug.print("runtime link driver terminated: {any}\nstdout:\n{s}\nstderr:\n{s}\n", .{
                run_result.term,
                run_result.stdout,
                run_result.stderr,
            });
            return error.RuntimeLinkDriverTerminated;
        },
    }
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const duration = start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake));
    return @as(f64, @floatFromInt(duration.nanoseconds)) / @as(f64, std.time.ns_per_ms);
}

fn externalScannerSource() []const u8 {
    return
    \\#include <stdbool.h>
    \\#include "parser.h"
    \\
    \\enum TokenType {
    \\  EXTERNAL_TOKEN = 0,
    \\};
    \\
    \\void *tree_sitter_external_grammar_external_scanner_create(void) { return 0; }
    \\void tree_sitter_external_grammar_external_scanner_destroy(void *payload) { (void)payload; }
    \\unsigned tree_sitter_external_grammar_external_scanner_serialize(void *payload, char *buffer) {
    \\  (void)payload;
    \\  (void)buffer;
    \\  return 0;
    \\}
    \\void tree_sitter_external_grammar_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
    \\  (void)payload;
    \\  (void)buffer;
    \\  (void)length;
    \\}
    \\bool tree_sitter_external_grammar_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    \\  (void)payload;
    \\  if (valid_symbols[EXTERNAL_TOKEN] && lexer->lookahead == 'e') {
    \\    lexer->result_symbol = EXTERNAL_TOKEN;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\
    ;
}

fn multiTokenScannerSource() []const u8 {
    return
    \\#include <stdbool.h>
    \\#include "parser.h"
    \\
    \\enum TokenType {
    \\  OPEN = 0,
    \\  CLOSE = 1,
    \\  ERROR_SENTINEL = 2,
    \\};
    \\
    \\void *tree_sitter_multi_external_grammar_external_scanner_create(void) { return 0; }
    \\void tree_sitter_multi_external_grammar_external_scanner_destroy(void *payload) { (void)payload; }
    \\unsigned tree_sitter_multi_external_grammar_external_scanner_serialize(void *payload, char *buffer) {
    \\  (void)payload;
    \\  (void)buffer;
    \\  return 0;
    \\}
    \\void tree_sitter_multi_external_grammar_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
    \\  (void)payload;
    \\  (void)buffer;
    \\  (void)length;
    \\}
    \\bool tree_sitter_multi_external_grammar_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    \\  (void)payload;
    \\  if (valid_symbols[ERROR_SENTINEL]) return false;
    \\  if (valid_symbols[OPEN] && lexer->lookahead == '(') {
    \\    lexer->result_symbol = OPEN;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    return true;
    \\  }
    \\  if (valid_symbols[CLOSE] && lexer->lookahead == ')') {
    \\    lexer->result_symbol = CLOSE;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\
    ;
}

fn statefulScannerSource() []const u8 {
    return
    \\#include <stdbool.h>
    \\#include <stdint.h>
    \\#include <stdlib.h>
    \\#include "parser.h"
    \\
    \\enum TokenType {
    \\  OPEN = 0,
    \\  CLOSE = 1,
    \\  ERROR_SENTINEL = 2,
    \\};
    \\
    \\typedef struct {
    \\  uint8_t depth;
    \\} ScannerState;
    \\
    \\static unsigned created_count;
    \\static unsigned destroyed_count;
    \\static unsigned max_depth;
    \\
    \\unsigned tree_sitter_stateful_external_grammar_created_count(void) { return created_count; }
    \\unsigned tree_sitter_stateful_external_grammar_destroyed_count(void) { return destroyed_count; }
    \\unsigned tree_sitter_stateful_external_grammar_max_depth(void) { return max_depth; }
    \\
    \\void *tree_sitter_stateful_external_grammar_external_scanner_create(void) {
    \\  ScannerState *state = (ScannerState *)calloc(1, sizeof(ScannerState));
    \\  if (state) created_count++;
    \\  return state;
    \\}
    \\
    \\void tree_sitter_stateful_external_grammar_external_scanner_destroy(void *payload) {
    \\  destroyed_count++;
    \\  free(payload);
    \\}
    \\
    \\unsigned tree_sitter_stateful_external_grammar_external_scanner_serialize(void *payload, char *buffer) {
    \\  ScannerState *state = (ScannerState *)payload;
    \\  buffer[0] = state ? (char)state->depth : 0;
    \\  return 1;
    \\}
    \\
    \\void tree_sitter_stateful_external_grammar_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
    \\  ScannerState *state = (ScannerState *)payload;
    \\  if (!state) return;
    \\  state->depth = length >= 1 ? (uint8_t)buffer[0] : 0;
    \\}
    \\
    \\bool tree_sitter_stateful_external_grammar_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    \\  ScannerState *state = (ScannerState *)payload;
    \\  if (!state || valid_symbols[ERROR_SENTINEL]) return false;
    \\  if (valid_symbols[OPEN] && lexer->lookahead == '(') {
    \\    lexer->result_symbol = OPEN;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    state->depth++;
    \\    if (state->depth > max_depth) max_depth = state->depth;
    \\    return true;
    \\  }
    \\  if (valid_symbols[CLOSE] && lexer->lookahead == ')') {
    \\    lexer->result_symbol = CLOSE;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    if (state->depth > 0) state->depth--;
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\
    ;
}

fn forkedStatefulScannerSource() []const u8 {
    return
    \\#include <stdbool.h>
    \\#include <stdint.h>
    \\#include <stdlib.h>
    \\#include "parser.h"
    \\
    \\enum TokenType {
    \\  OPEN = 0,
    \\  BRANCH = 1,
    \\  CLOSE_A = 2,
    \\  CLOSE_B = 3,
    \\  ERROR_SENTINEL = 4,
    \\};
    \\
    \\typedef struct {
    \\  uint8_t phase;
    \\} ScannerState;
    \\
    \\static unsigned close_a_count;
    \\static unsigned close_b_count;
    \\static unsigned deserialize_with_branch_count;
    \\
    \\unsigned tree_sitter_forked_stateful_external_grammar_close_a_count(void) { return close_a_count; }
    \\unsigned tree_sitter_forked_stateful_external_grammar_close_b_count(void) { return close_b_count; }
    \\unsigned tree_sitter_forked_stateful_external_grammar_deserialize_with_branch_count(void) { return deserialize_with_branch_count; }
    \\
    \\void *tree_sitter_forked_stateful_external_grammar_external_scanner_create(void) {
    \\  return calloc(1, sizeof(ScannerState));
    \\}
    \\
    \\void tree_sitter_forked_stateful_external_grammar_external_scanner_destroy(void *payload) {
    \\  free(payload);
    \\}
    \\
    \\unsigned tree_sitter_forked_stateful_external_grammar_external_scanner_serialize(void *payload, char *buffer) {
    \\  ScannerState *state = (ScannerState *)payload;
    \\  buffer[0] = state ? (char)state->phase : 0;
    \\  return 1;
    \\}
    \\
    \\void tree_sitter_forked_stateful_external_grammar_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
    \\  ScannerState *state = (ScannerState *)payload;
    \\  if (!state) return;
    \\  state->phase = length >= 1 ? (uint8_t)buffer[0] : 0;
    \\  if (state->phase == 2) deserialize_with_branch_count++;
    \\}
    \\
    \\bool tree_sitter_forked_stateful_external_grammar_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    \\  ScannerState *state = (ScannerState *)payload;
    \\  if (!state || valid_symbols[ERROR_SENTINEL]) return false;
    \\  if (valid_symbols[OPEN] && lexer->lookahead == '(') {
    \\    lexer->result_symbol = OPEN;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    state->phase = 1;
    \\    return true;
    \\  }
    \\  if (valid_symbols[BRANCH] && lexer->lookahead == 'x' && state->phase == 1) {
    \\    lexer->result_symbol = BRANCH;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    state->phase = 2;
    \\    return true;
    \\  }
    \\  if (valid_symbols[CLOSE_A] && lexer->lookahead == ')' && state->phase == 2) {
    \\    lexer->result_symbol = CLOSE_A;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    state->phase = 3;
    \\    close_a_count++;
    \\    return true;
    \\  }
    \\  if (valid_symbols[CLOSE_B] && lexer->lookahead == ')' && state->phase == 2) {
    \\    lexer->result_symbol = CLOSE_B;
    \\    lexer->advance(lexer, false);
    \\    lexer->mark_end(lexer);
    \\    state->phase = 4;
    \\    close_b_count++;
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\
    ;
}

fn driverSourceAlloc(
    allocator: std.mem.Allocator,
    generated: GeneratedParserRun,
) RuntimeLinkError![]const u8 {
    if (generated.direct_generated_parse) {
        return directGeneratedParseDriverSourceAlloc(allocator, generated);
    }

    const input_literal = try cStringLiteralAlloc(allocator, generated.input);
    defer allocator.free(input_literal);

    const metadata_check = if (generated.expected_metadata) |metadata|
        try std.fmt.allocPrint(allocator,
            \\  const TSLanguageMetadata *metadata = ts_language_metadata(language);
            \\  if (!metadata) return 14;
            \\  if (metadata->major_version != {d}) return 15;
            \\  if (metadata->minor_version != {d}) return 16;
            \\  if (metadata->patch_version != {d}) return 17;
            \\
        , .{ metadata[0], metadata[1], metadata[2] })
    else
        "";
    defer if (generated.expected_metadata != null) allocator.free(metadata_check);

    const tree_check = try treeAssertionSourceAlloc(
        allocator,
        generated.expected_root_type,
        generated.expected_child_types,
        generated.expected_tree_string,
    );
    defer allocator.free(tree_check);
    const error_check = try treeErrorAssertionSourceAlloc(allocator, generated.expected_has_error);
    defer allocator.free(error_check);

    return try std.fmt.allocPrint(allocator,
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <signal.h>
        \\#include <stdlib.h>
        \\#include <string.h>
        \\#include <tree_sitter/api.h>
        \\#include <unistd.h>
        \\
        \\const TSLanguage *{s}(void);
        \\{s}
        \\
        \\static void log_parser(void *payload, TSLogType log_type, const char *buffer) {{
        \\  uint32_t *count = (uint32_t *)payload;
        \\  if (*count >= 200) return;
        \\  fprintf(stderr, "%s: %s\n", log_type == TSLogTypeLex ? "lex" : "parse", buffer);
        \\  *count += 1;
        \\}}
        \\
        \\int main(void) {{
        \\  alarm(2);
        \\  const char *input = {s};
        \\  const TSLanguage *language = {s}();
        \\{s}
        \\  TSParser *parser = ts_parser_new();
        \\  if (!parser) return 10;
        \\  if (!ts_parser_set_language(parser, language)) return 11;
        \\  uint32_t log_count = 0;
        \\  ts_parser_set_logger(parser, (TSLogger){{ .payload = &log_count, .log = log_parser }});
        \\  TSTree *tree = ts_parser_parse_string(parser, 0, input, (uint32_t)strlen(input));
        \\  if (!tree) return 12;
        \\  TSNode root = ts_tree_root_node(tree);
        \\  bool is_error = ts_node_is_error(root);
        \\  bool has_error = ts_node_has_error(root);
        \\  const char *type = ts_node_type(root);
        \\  printf("%s\n", type ? type : "<null>");
        \\{s}
        \\{s}
        \\  ts_tree_delete(tree);
        \\  ts_parser_delete(parser);
        \\{s}
        \\  return is_error && {s} ? 13 : 0;
        \\}}
        \\
    , .{
        generated.language_function_name,
        generated.extra_driver_declarations,
        input_literal,
        generated.language_function_name,
        metadata_check,
        tree_check,
        error_check,
        generated.after_parser_delete_check,
        if (generated.expected_has_error == true) "false" else "true",
    });
}

fn treeAssertionSourceAlloc(
    allocator: std.mem.Allocator,
    expected_root_type: ?[]const u8,
    expected_child_types: []const []const u8,
    expected_tree_string: ?[]const u8,
) RuntimeLinkError![]const u8 {
    if (expected_root_type == null and expected_child_types.len == 0 and expected_tree_string == null) {
        return try allocator.dupe(u8, "");
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    if (expected_root_type) |root_type| {
        try writer.print(
            \\  if (!type || strcmp(type, "{s}") != 0) return 18;
            \\
        , .{root_type});
    }
    if (expected_child_types.len != 0) {
        try writer.print(
            \\  if (ts_node_child_count(root) != {d}) return 19;
            \\
        , .{expected_child_types.len});
        for (expected_child_types, 0..) |child_type, index| {
            try writer.print(
                \\  TSNode child_{d} = ts_node_child(root, {d});
                \\  const char *child_type_{d} = ts_node_type(child_{d});
                \\  if (!child_type_{d} || strcmp(child_type_{d}, "{s}") != 0) return {d};
                \\
            , .{ index, index, index, index, index, index, child_type, 20 + index });
        }
    }
    if (expected_tree_string) |tree_string| {
        try writer.print(
            \\  char *tree_string = ts_node_string(root);
            \\  if (!tree_string) return 28;
            \\  bool tree_matches = strcmp(tree_string, "{s}") == 0;
            \\  free(tree_string);
            \\  if (!tree_matches) return 29;
            \\
        , .{tree_string});
    }

    return try out.toOwnedSlice();
}

fn treeErrorAssertionSourceAlloc(
    allocator: std.mem.Allocator,
    expected_has_error: ?bool,
) RuntimeLinkError![]const u8 {
    const expected = expected_has_error orelse return try allocator.dupe(u8, "");
    if (expected) {
        return try allocator.dupe(u8,
            \\  if (!has_error) return 33;
            \\
        );
    }
    return try allocator.dupe(u8,
        \\  if (is_error || has_error) return 34;
        \\
    );
}

fn directGeneratedParseDriverSourceAlloc(
    allocator: std.mem.Allocator,
    generated: GeneratedParserRun,
) RuntimeLinkError![]const u8 {
    const input_literal = try cStringLiteralAlloc(allocator, generated.input);
    defer allocator.free(input_literal);
    const expected_consumed = generated.expected_consumed_bytes orelse @as(u32, @intCast(generated.input.len));
    const success_check =
        if (generated.expected_direct_parse_success)
            "  if (!parse_ok) return 40;\n"
        else
            "  if (parse_ok) return 40;\n  return 0;\n";
    const parse_call =
        if (generated.direct_generated_result)
            "  TSGeneratedParseResult result = { 0 };\n  bool parse_ok = ts_generated_parse_result(input, (uint32_t)strlen(input), &result);\n  consumed = result.consumed_bytes;\n  if (parse_ok && !result.accepted) return 42;\n  if (parse_ok && result.root_node != 2) return 43;\n  if (parse_ok && result.node_count != 3) return 44;\n  if (parse_ok && result.nodes[result.root_node].start_byte != 0) return 45;\n  if (parse_ok && result.nodes[result.root_node].end_byte != strlen(input)) return 46;\n  if (parse_ok && result.nodes[result.root_node].child_count != 2) return 47;\n  if (parse_ok && result.nodes[result.root_node].children[0] != 0) return 48;\n  if (parse_ok && result.nodes[result.root_node].children[1] != 1) return 49;\n  if (parse_ok && result.nodes[result.root_node].field_map_index != 0) return 50;\n  if (parse_ok && result.nodes[result.root_node].field_map_length != 1) return 51;\n  if (parse_ok && result.nodes[result.root_node].child_aliases[0] != 0) return 52;\n  if (parse_ok && result.nodes[result.root_node].child_aliases[1] == 0) return 53;\n  char generated_tree_string[256];\n  if (parse_ok && !ts_generated_result_tree_string(&result, generated_tree_string, sizeof(generated_tree_string))) return 54;\n  TSParser *parser = ts_parser_new();\n  if (parse_ok && !parser) return 55;\n  if (parse_ok && !ts_parser_set_language(parser, tree_sitter_generated())) return 56;\n  TSTree *tree = parse_ok ? ts_parser_parse_string(parser, 0, input, (uint32_t)strlen(input)) : 0;\n  if (parse_ok && !tree) return 57;\n  TSNode root = parse_ok ? ts_tree_root_node(tree) : (TSNode){0};\n  char *runtime_tree_string = parse_ok ? ts_node_string(root) : 0;\n  if (parse_ok && !runtime_tree_string) return 58;\n  bool tree_strings_match = parse_ok ? strcmp(generated_tree_string, runtime_tree_string) == 0 : true;\n  free(runtime_tree_string);\n  if (tree) ts_tree_delete(tree);\n  if (parser) ts_parser_delete(parser);\n  if (!tree_strings_match) return 59;\n"
        else
            "  bool parse_ok = ts_generated_parse(input, (uint32_t)strlen(input), &consumed);\n";

    return try std.fmt.allocPrint(allocator,
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\#include <signal.h>
        \\#include <stdio.h>
        \\#include <stdlib.h>
        \\#include <string.h>
        \\#include <tree_sitter/api.h>
        \\#include <unistd.h>
        \\
        \\typedef struct {{
        \\  uint16_t symbol;
        \\  uint32_t start_byte;
        \\  uint32_t end_byte;
        \\  uint16_t production_id;
        \\  uint16_t child_count;
        \\  uint16_t first_child;
        \\  uint16_t field_map_index;
        \\  uint16_t field_map_length;
        \\  uint16_t children[16];
        \\  uint16_t child_aliases[16];
        \\}} TSGeneratedNode;
        \\
        \\typedef struct {{
        \\  bool accepted;
        \\  uint32_t consumed_bytes;
        \\  uint16_t root_node;
        \\  uint16_t node_count;
        \\  uint32_t error_count;
        \\  int32_t dynamic_precedence;
        \\  TSGeneratedNode nodes[256];
        \\}} TSGeneratedParseResult;
        \\
        \\const TSLanguage *tree_sitter_generated(void);
        \\bool ts_generated_parse_result(const char *input, uint32_t length, TSGeneratedParseResult *out_result);
        \\bool ts_generated_result_tree_string(const TSGeneratedParseResult *result, char *buffer, uint32_t capacity);
        \\bool ts_generated_parse(const char *input, uint32_t length, uint32_t *out_consumed_bytes);
        \\{s}
        \\
        \\int main(void) {{
        \\  alarm(2);
        \\  const char *input = {s};
        \\  uint32_t consumed = 0;
        \\{s}
        \\{s}
        \\  if (consumed != {d}) {{
        \\    fprintf(stderr, "consumed=%u expected=%u\n", consumed, {d});
        \\    return 41;
        \\  }}
        \\{s}
        \\  return 0;
        \\}}
        \\
    , .{
        generated.extra_driver_declarations,
        input_literal,
        parse_call,
        success_check,
        expected_consumed,
        expected_consumed,
        generated.after_parser_delete_check,
    });
}

fn cStringLiteralAlloc(allocator: std.mem.Allocator, value: []const u8) RuntimeLinkError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            0 => try writer.writeAll("\\0"),
            else => if (byte < 0x20 or byte >= 0x7f) {
                try writer.print("\\{o:0>3}", .{byte});
            } else {
                try writer.writeByte(byte);
            },
        }
    }
    try writer.writeByte('"');
    return try out.toOwnedSlice();
}

fn ensureTreeSitterRuntimeAvailable() RuntimeLinkError!void {
    std.Io.Dir.cwd().access(runtime_io.get(), tree_sitter_runtime_dir ++ "/lib.c", .{}) catch return error.TreeSitterRuntimeMissing;
    std.Io.Dir.cwd().access(runtime_io.get(), tree_sitter_include_dir ++ "/tree_sitter/api.h", .{}) catch return error.TreeSitterRuntimeMissing;
}

fn ensureFileAvailableOrSkip(path: []const u8) RuntimeLinkError!void {
    std.Io.Dir.cwd().access(runtime_io.get(), path, .{}) catch return error.SkipZigTest;
}

test "linkAndRunNoExternalTinyParser links generated parser with tree-sitter runtime" {
    try linkAndRunNoExternalTinyParser(std.testing.allocator);
}

test "linkAndRunNoExternalTinyGlrParser calls generated GLR parse entry directly" {
    try linkAndRunNoExternalTinyGlrParser(std.testing.allocator);
}

test "linkAndRunNoExternalTinyGlrResultParser calls generated GLR result entry directly" {
    try linkAndRunNoExternalTinyGlrResultParser(std.testing.allocator);
}

test "linkAndRunGeneratedStatusAccessors calls generated release status accessors" {
    try linkAndRunGeneratedStatusAccessors(std.testing.allocator);
}

test "linkAndRunUnresolvedShiftReduceGlrParser accepts intended unresolved branch" {
    try linkAndRunUnresolvedShiftReduceGlrParser(std.testing.allocator);
}

test "linkAndRecoverMalformedTinyGlrParser recovers malformed direct GLR input" {
    try linkAndRecoverMalformedTinyGlrParser(std.testing.allocator);
}

test "linkAndRunKeywordReservedParser links generated keyword parser with tree-sitter runtime" {
    try linkAndRunKeywordReservedParser(std.testing.allocator);
}

test "linkAndRunExternalScannerParser links generated external scanner parser with tree-sitter runtime" {
    try linkAndRunExternalScannerParser(std.testing.allocator);
}

test "linkAndRunExternalScannerGlrParser calls generated GLR external scanner path" {
    try linkAndRunExternalScannerGlrParser(std.testing.allocator);
}

test "linkAndRunMultiTokenExternalScannerParser links generated multi-token external scanner parser with tree-sitter runtime" {
    try linkAndRunMultiTokenExternalScannerParser(std.testing.allocator);
}

test "linkAndRunMultiTokenExternalScannerGlrParser uses GLR valid-symbol rows" {
    try linkAndRunMultiTokenExternalScannerGlrParser(std.testing.allocator);
}

test "linkAndRunStatefulExternalScannerParser links generated stateful external scanner parser with tree-sitter runtime" {
    try linkAndRunStatefulExternalScannerParser(std.testing.allocator);
}

test "linkAndRunForkedStatefulExternalScannerGlrParser isolates forked scanner state" {
    try linkAndRunForkedStatefulExternalScannerGlrParser(std.testing.allocator);
}

test "linkAndRunBracketLangParser links generated bracket-lang parser with tree-sitter runtime" {
    try linkAndRunBracketLangParser(std.testing.allocator);
}

test "linkAndRunTreeSitterJsonParserAcceptedSample links real JSON parser on accepted input" {
    try linkAndRunTreeSitterJsonParserAcceptedSample(std.testing.allocator);
}

test "linkAndRunTreeSitterJsonParserInvalidSample links real JSON parser on invalid input" {
    try linkAndRunTreeSitterJsonParserInvalidSample(std.testing.allocator);
}

test "linkAndRunTreeSitterZiggyParserAcceptedSample links real Ziggy parser on accepted input" {
    try linkAndRunTreeSitterZiggyParserAcceptedSample(std.testing.allocator);
}

test "linkAndRunTreeSitterZiggyParserInvalidSample links real Ziggy parser on invalid input" {
    try linkAndRunTreeSitterZiggyParserInvalidSample(std.testing.allocator);
}

test "linkAndRunTreeSitterZiggySchemaParserAcceptedSample links real Ziggy schema parser on accepted input" {
    try linkAndRunTreeSitterZiggySchemaParserAcceptedSample(std.testing.allocator);
}

test "linkAndRunTreeSitterZigParserAcceptedSample links real Zig parser on accepted input" {
    try linkAndRunTreeSitterZigParserAcceptedSample(std.testing.allocator);
}

test "linkAndRunTreeSitterZigParserInvalidSample links real Zig parser on invalid input" {
    try linkAndRunTreeSitterZigParserInvalidSample(std.testing.allocator);
}

test "linkAndRunBashParserWithRealExternalScanner links generated Bash parser with upstream scanner" {
    try linkAndRunBashParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunBashGeneratedGlrParserWithRealExternalScanner calls generated GLR Bash scanner path" {
    try linkAndRunBashGeneratedGlrParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunJavascriptTernaryParserWithRealExternalScanner links generated JavaScript parser with upstream scanner" {
    try linkAndRunJavascriptTernaryParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunJavascriptJsxTextParserWithRealExternalScanner links generated JavaScript JSX text parser with upstream scanner" {
    try linkAndRunJavascriptJsxTextParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunJavascriptTernaryGeneratedGlrParserWithRealExternalScanner calls generated GLR JavaScript scanner path" {
    try linkAndRunJavascriptTernaryGeneratedGlrParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunTypescriptTernaryParserWithRealExternalScanner links generated TypeScript parser with upstream scanner" {
    try linkAndRunTypescriptTernaryParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunTypescriptJsxTextParserWithRealExternalScanner links generated TypeScript JSX text parser with upstream scanner" {
    try linkAndRunTypescriptJsxTextParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunPythonNewlineParserWithRealExternalScanner links generated Python parser with upstream scanner" {
    try linkAndRunPythonNewlineParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunPythonStringParserWithRealExternalScanner links generated Python string parser with upstream scanner" {
    try linkAndRunPythonStringParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunRustFloatLiteralParserWithRealExternalScanner links generated Rust parser with upstream scanner" {
    try linkAndRunRustFloatLiteralParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunRustRawStringParserWithRealExternalScanner links generated Rust raw-string parser with upstream scanner" {
    try linkAndRunRustRawStringParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunHaskellParserWithRealExternalScanner links generated Haskell parser with upstream scanner" {
    try linkAndRunHaskellParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunHaskellGeneratedGlrParserWithRealExternalScanner calls generated GLR Haskell scanner path" {
    try linkAndRunHaskellGeneratedGlrParserWithRealExternalScanner(std.testing.allocator);
}

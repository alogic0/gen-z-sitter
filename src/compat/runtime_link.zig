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
    const states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = lex_states[0..] },
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 1 },
        .{ .lex_state = 0, .external_lex_state = 1 },
    };
    const primary_state_ids = [_]u32{ 0, 1, 2, 3 };
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

fn emitBashBareDollarParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
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
    const states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
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
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3 });

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
    });
}

fn emitHaskellVarsymParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
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
    const states = try allocator.dupe(serialize.SerializedState, &.{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions, .gotos = start_gotos, .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = after_update_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = after_start_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = reduce_actions, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 5, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 6, .lex_state_id = 0, .actions = accept_actions, .gotos = &.{}, .unresolved = &.{} },
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
        .{ .lex_state = 0, .external_lex_state = 0 },
    });
    const primary_state_ids = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 5, 6 });

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
    });
}

fn emitMultiTokenExternalScannerParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
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
    const states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = start_actions[0..], .gotos = start_gotos[0..], .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = close_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = reduce_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 4, .lex_state_id = 0, .actions = accept_actions[0..], .gotos = &.{}, .unresolved = &.{} },
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
        .{ .lex_state = 0, .external_lex_state = 0 },
        .{ .lex_state = 0, .external_lex_state = 0 },
    };
    const primary_state_ids = [_]u32{ 0, 1, 2, 3, 4 };
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
    direct_generated_parse: bool = false,
    expected_consumed_bytes: ?u32 = null,
    extra_driver_declarations: []const u8 = "",
    after_parser_delete_check: []const u8 = "",
};

fn linkAndRunGeneratedParser(
    allocator: std.mem.Allocator,
    generated: GeneratedParserRun,
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
    const driver_source = try driverSourceAlloc(allocator, generated);
    defer allocator.free(driver_source);
    try tmp_dir.writeFile(runtime_io.get(), .{
        .sub_path = "driver.c",
        .data = driver_source,
    });

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

    var compile_result = try process_support.runCapture(allocator, compile_args.items);
    defer compile_result.deinit(allocator);

    switch (compile_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("runtime link compile failed:\n{s}\n", .{compile_result.stderr});
            return error.RuntimeLinkCompileFailed;
        },
        else => return error.RuntimeLinkCompileTerminated,
    }

    var run_result = try process_support.runCapture(allocator, &.{exe_path});
    defer run_result.deinit(allocator);

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
        \\  const char *type = ts_node_type(root);
        \\  printf("%s\n", type ? type : "<null>");
        \\{s}
        \\  ts_tree_delete(tree);
        \\  ts_parser_delete(parser);
        \\{s}
        \\  return is_error ? 13 : 0;
        \\}}
        \\
    , .{
        generated.language_function_name,
        generated.extra_driver_declarations,
        input_literal,
        generated.language_function_name,
        metadata_check,
        tree_check,
        generated.after_parser_delete_check,
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

fn directGeneratedParseDriverSourceAlloc(
    allocator: std.mem.Allocator,
    generated: GeneratedParserRun,
) RuntimeLinkError![]const u8 {
    const input_literal = try cStringLiteralAlloc(allocator, generated.input);
    defer allocator.free(input_literal);
    const expected_consumed = generated.expected_consumed_bytes orelse @as(u32, @intCast(generated.input.len));

    return try std.fmt.allocPrint(allocator,
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\#include <signal.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\#include <unistd.h>
        \\
        \\bool ts_generated_parse(const char *input, uint32_t length, uint32_t *out_consumed_bytes);
        \\
        \\int main(void) {{
        \\  alarm(2);
        \\  const char *input = {s};
        \\  uint32_t consumed = 0;
        \\  if (!ts_generated_parse(input, (uint32_t)strlen(input), &consumed)) return 40;
        \\  if (consumed != {d}) {{
        \\    fprintf(stderr, "consumed=%u expected=%u\n", consumed, {d});
        \\    return 41;
        \\  }}
        \\  return 0;
        \\}}
        \\
    , .{ input_literal, expected_consumed, expected_consumed });
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

test "linkAndRunUnresolvedShiftReduceGlrParser accepts intended unresolved branch" {
    try linkAndRunUnresolvedShiftReduceGlrParser(std.testing.allocator);
}

test "linkAndRunKeywordReservedParser links generated keyword parser with tree-sitter runtime" {
    try linkAndRunKeywordReservedParser(std.testing.allocator);
}

test "linkAndRunExternalScannerParser links generated external scanner parser with tree-sitter runtime" {
    try linkAndRunExternalScannerParser(std.testing.allocator);
}

test "linkAndRunMultiTokenExternalScannerParser links generated multi-token external scanner parser with tree-sitter runtime" {
    try linkAndRunMultiTokenExternalScannerParser(std.testing.allocator);
}

test "linkAndRunStatefulExternalScannerParser links generated stateful external scanner parser with tree-sitter runtime" {
    try linkAndRunStatefulExternalScannerParser(std.testing.allocator);
}

test "linkAndRunBracketLangParser links generated bracket-lang parser with tree-sitter runtime" {
    try linkAndRunBracketLangParser(std.testing.allocator);
}

test "linkAndRunBashParserWithRealExternalScanner links generated Bash parser with upstream scanner" {
    try linkAndRunBashParserWithRealExternalScanner(std.testing.allocator);
}

test "linkAndRunHaskellParserWithRealExternalScanner links generated Haskell parser with upstream scanner" {
    try linkAndRunHaskellParserWithRealExternalScanner(std.testing.allocator);
}

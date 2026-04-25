const std = @import("std");
const lexer_serialize = @import("../lexer/serialize.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const serialize = @import("../parse_table/serialize.zig");
const process_support = @import("../support/process.zig");
const syntax_grammar = @import("../ir/syntax_grammar.zig");

pub const RuntimeLinkError = anyerror;

const tree_sitter_runtime_dir = "../tree-sitter/lib/src";
const tree_sitter_include_dir = "../tree-sitter/lib/include";

pub fn linkAndRunNoExternalTinyParser(allocator: std.mem.Allocator) RuntimeLinkError!void {
    try ensureTreeSitterRuntimeAvailable();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parser_c = try emitTinyParserC(arena.allocator());
    try linkAndRunGeneratedParser(allocator, .{
        .parser_c = parser_c,
        .input = "x",
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

fn emitTinyParserC(allocator: std.mem.Allocator) RuntimeLinkError![]const u8 {
    const symbols = [_]serialize.SerializedSymbolInfo{
        .{
            .ref = .{ .terminal = 0 },
            .name = "end",
            .named = false,
            .visible = false,
            .supertype = false,
            .public_symbol = 0,
        },
        .{
            .ref = .{ .terminal = 1 },
            .name = "x",
            .named = false,
            .visible = true,
            .supertype = false,
            .public_symbol = 1,
        },
        .{
            .ref = .{ .non_terminal = 0 },
            .name = "source_file",
            .named = true,
            .visible = true,
            .supertype = false,
            .public_symbol = 2,
        },
    };
    const productions = [_]serialize.SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    };
    const state0_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 2 } },
    };
    const state0_gotos = [_]serialize.SerializedGotoEntry{
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    };
    const state1_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 0 } },
    };
    const state2_actions = [_]serialize.SerializedActionEntry{
        .{ .symbol = .{ .terminal = 0 }, .action = .{ .accept = {} } },
    };
    const states = [_]serialize.SerializedState{
        .{ .id = 0, .lex_state_id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 1, .lex_state_id = 0, .actions = state0_actions[0..], .gotos = state0_gotos[0..], .unresolved = &.{} },
        .{ .id = 2, .lex_state_id = 0, .actions = state1_actions[0..], .gotos = &.{}, .unresolved = &.{} },
        .{ .id = 3, .lex_state_id = 0, .actions = state2_actions[0..], .gotos = &.{}, .unresolved = &.{} },
    };
    const x_ranges = [_]lexer_serialize.SerializedCharacterRange{
        .{ .start = 'x', .end_inclusive = 'x' },
    };
    const lex_transitions = [_]lexer_serialize.SerializedLexTransition{
        .{ .ranges = x_ranges[0..], .next_state_id = 1, .skip = false },
    };
    const lex_states = [_]lexer_serialize.SerializedLexState{
        .{ .accept_symbol = .{ .terminal = 0 }, .transitions = lex_transitions[0..] },
        .{ .accept_symbol = .{ .terminal = 1 }, .transitions = &.{} },
    };
    const lex_tables = [_]lexer_serialize.SerializedLexTable{
        .{ .start_state_id = 0, .states = lex_states[0..] },
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
    };
    const primary_state_ids = [_]u32{ 0, 1, 2, 3 };
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "generated",
        .symbols = symbols[0..],
        .large_state_count = states.len,
        .productions = productions[0..],
        .lex_modes = lex_modes[0..],
        .lex_tables = lex_tables[0..],
        .primary_state_ids = primary_state_ids[0..],
        .states = states[0..],
    };

    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
    });
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

const GeneratedParserRun = struct {
    parser_c: []const u8,
    input: []const u8,
    scanner_c: ?[]const u8 = null,
};

fn linkAndRunGeneratedParser(
    allocator: std.mem.Allocator,
    generated: GeneratedParserRun,
) RuntimeLinkError!void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "parser.c",
        .data = generated.parser_c,
    });
    if (generated.scanner_c) |scanner_c| {
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "scanner.c",
            .data = scanner_c,
        });
    }
    const driver_source = try driverSourceAlloc(allocator, generated.input);
    defer allocator.free(driver_source);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "driver.c",
        .data = driver_source,
    });

    const parser_path = try tmp.dir.realPathFileAlloc(std.testing.io, "parser.c", allocator);
    defer allocator.free(parser_path);
    const driver_path = try tmp.dir.realPathFileAlloc(std.testing.io, "driver.c", allocator);
    defer allocator.free(driver_path);
    const scanner_path = if (generated.scanner_c != null)
        try tmp.dir.realPathFileAlloc(std.testing.io, "scanner.c", allocator)
    else
        null;
    defer if (scanner_path) |path| allocator.free(path);
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir_path);
    const exe_path = try std.fs.path.join(allocator, &.{ dir_path, "driver" });
    defer allocator.free(exe_path);

    var compile_args = std.array_list.Managed([]const u8).init(allocator);
    defer compile_args.deinit();
    try compile_args.appendSlice(&.{
        "zig",       "cc",                    "-std=c11", "-D_GNU_SOURCE",
        "-I",        tree_sitter_include_dir, "-I",       tree_sitter_runtime_dir,
        driver_path, parser_path,
    });
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

fn driverSourceAlloc(allocator: std.mem.Allocator, input: []const u8) RuntimeLinkError![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <signal.h>
        \\#include <string.h>
        \\#include <tree_sitter/api.h>
        \\#include <unistd.h>
        \\
        \\const TSLanguage *tree_sitter_generated(void);
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
        \\  const char *input = "{s}";
        \\  TSParser *parser = ts_parser_new();
        \\  if (!parser) return 10;
        \\  if (!ts_parser_set_language(parser, tree_sitter_generated())) return 11;
        \\  uint32_t log_count = 0;
        \\  ts_parser_set_logger(parser, (TSLogger){{ .payload = &log_count, .log = log_parser }});
        \\  TSTree *tree = ts_parser_parse_string(parser, 0, input, (uint32_t)strlen(input));
        \\  if (!tree) return 12;
        \\  TSNode root = ts_tree_root_node(tree);
        \\  bool is_error = ts_node_is_error(root);
        \\  const char *type = ts_node_type(root);
        \\  printf("%s\n", type ? type : "<null>");
        \\  ts_tree_delete(tree);
        \\  ts_parser_delete(parser);
        \\  return is_error ? 13 : 0;
        \\}}
        \\
    , .{input});
}

fn ensureTreeSitterRuntimeAvailable() RuntimeLinkError!void {
    std.Io.Dir.cwd().access(std.testing.io, tree_sitter_runtime_dir ++ "/lib.c", .{}) catch return error.TreeSitterRuntimeMissing;
    std.Io.Dir.cwd().access(std.testing.io, tree_sitter_include_dir ++ "/tree_sitter/api.h", .{}) catch return error.TreeSitterRuntimeMissing;
}

test "linkAndRunNoExternalTinyParser links generated parser with tree-sitter runtime" {
    try linkAndRunNoExternalTinyParser(std.testing.allocator);
}

test "linkAndRunKeywordReservedParser links generated keyword parser with tree-sitter runtime" {
    try linkAndRunKeywordReservedParser(std.testing.allocator);
}

test "linkAndRunExternalScannerParser links generated external scanner parser with tree-sitter runtime" {
    try linkAndRunExternalScannerParser(std.testing.allocator);
}

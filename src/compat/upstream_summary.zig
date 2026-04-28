const std = @import("std");
const extract_default_aliases = @import("../grammar/prepare/extract_default_aliases.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const flatten_grammar = @import("../grammar/prepare/flatten_grammar.zig");
const grammar_loader = @import("../grammar/loader.zig");
const grammar_ir = @import("../ir/grammar_ir.zig");
const ir_rules = @import("../ir/rules.zig");
const ir_symbols = @import("../ir/symbols.zig");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const lexer_model = @import("../lexer/model.zig");
const node_type_pipeline = @import("../node_types/pipeline.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const raw_grammar = @import("../grammar/raw_grammar.zig");
const parse_table_build = @import("../parse_table/build.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const parse_table_serialize = @import("../parse_table/serialize.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const parser_compat = @import("../parser_emit/compat.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const LocalSummaryOptions = struct {
    js_runtime: []const u8 = "node",
    report_states_for_rule: ?[]const u8 = null,
    minimize_states: bool = false,
    compact_duplicate_states: bool = true,
};

pub const Summary = struct {
    grammar_name: []const u8,
    language_version: usize,
    blocked: bool,
    rule_count: usize,
    external_count: usize,
    extra_count: usize,
    symbol_count: usize,
    symbol_order_hash: u64,
    token_count: usize,
    field_count: usize,
    field_names_hash: u64,
    node_types_hash: u64,
    alias_count: usize,
    production_id_count: usize,
    serialized_state_count: usize,
    emitted_state_count: usize,
    large_state_count: usize,
    parse_action_list_count: usize,
    small_parse_row_count: usize,
    small_parse_map_count: usize,
    lex_mode_count: usize,
    lex_function_case_count: usize,
    keyword_lex_function_case_count: usize,
    large_character_set_count: usize,
    external_lex_state_count: usize,
};

pub const DiffClassification = enum {
    expected_local_extension,
    known_unsupported_surface,
    suspected_algorithm_gap,
    regression,
};

pub const SummaryDiff = struct {
    field: []const u8,
    local: []const u8,
    upstream: []const u8,
    classification: DiffClassification,
};

pub const PreparedIrSummary = struct {
    stage_order_hash: u64,
    variable_count: usize,
    rule_count: usize,
    symbol_count: usize,
    external_token_count: usize,
    extra_rule_count: usize,
    conflict_count: usize,
    precedence_order_count: usize,
    inline_count: usize,
    supertype_count: usize,
    reserved_word_set_count: usize,
    prepared_variable_hash: u64,
    prepared_symbol_hash: u64,
    prepared_reserved_word_set_hash: u64,
    prepared_conflict_hash: u64,
    prepared_precedence_hash: u64,
    prepared_inline_hash: u64,
    prepared_supertype_hash: u64,
    prepared_word_token_hash: u64,
    extracted_syntax_variable_count: usize,
    extracted_syntax_production_count: usize,
    extracted_syntax_step_count: usize,
    extracted_extra_symbol_hash: u64,
    extracted_expected_conflict_hash: u64,
    extracted_precedence_hash: u64,
    extracted_inline_hash: u64,
    extracted_supertype_hash: u64,
    extracted_word_token_hash: u64,
    extracted_lexical_variable_count: usize,
    extracted_lexical_separator_count: usize,
    extracted_lexical_hash: u64,
    flattened_syntax_variable_count: usize,
    flattened_syntax_production_count: usize,
    flattened_syntax_step_count: usize,
    flattened_syntax_hash: u64,
};

const local_preparation_stage_order = [_][]const u8{
    "load_raw_grammar",
    "parse_raw_grammar_validate_and_intern",
    "extract_tokens_and_expand_repeats",
    "extract_default_aliases",
    "flatten_grammar",
};

pub fn generateLocalSummaryAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) !Summary {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const serialized = try parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena.allocator(),
        prepared,
        .diagnostic,
        .{
            .minimize_states = options.minimize_states,
            .strict_expected_conflicts = false,
        },
    );
    const emission_stats = try parser_c_emit.collectEmissionStatsWithOptions(arena.allocator(), serialized, .{
        .compact_duplicate_states = options.compact_duplicate_states,
    });
    const parser_c = try parser_c_emit.emitParserCAllocWithOptions(arena.allocator(), serialized, .{
        .compact_duplicate_states = options.compact_duplicate_states,
    });
    const node_types_json = try node_type_pipeline.generateNodeTypesJsonFromPrepared(arena.allocator(), prepared);

    var summary = try parseUpstreamParserCSummaryAlloc(allocator, loaded.json.grammar.name, parser_c, node_types_json);
    summary.language_version = parser_compat.language_version;
    summary.blocked = serialized.blocked or emission_stats.blocked;
    summary.rule_count = loaded.json.grammar.ruleCount();
    summary.extra_count = loaded.json.grammar.extras.len;
    summary.serialized_state_count = serialized.states.len;
    summary.emitted_state_count = emission_stats.state_count;
    return summary;
}

pub fn generateLocalPreparedIrSummaryAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) !PreparedIrSummary {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const default_aliases = try extract_default_aliases.extractDefaultAliases(arena.allocator(), extracted.syntax, extracted.lexical);
    const flattened = try flatten_grammar.flattenGrammar(arena.allocator(), default_aliases.syntax);

    return preparedIrSummary(prepared, extracted, flattened);
}

pub fn generateLocalPreparedIrSnapshotJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const default_aliases = try extract_default_aliases.extractDefaultAliases(arena.allocator(), extracted.syntax, extracted.lexical);
    const flattened = try flatten_grammar.flattenGrammar(arena.allocator(), default_aliases.syntax);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writePreparedIrSnapshotJson(&out.writer, prepared, extracted, flattened);
    return try out.toOwnedSlice();
}

pub fn generateLocalRawGrammarSnapshotJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeRawGrammarJson(&out.writer, loaded.json.grammar);
    return try out.toOwnedSlice();
}

pub fn generateLocalNodeTypesJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const json = try node_type_pipeline.generateNodeTypesJsonFromPrepared(arena.allocator(), prepared);
    return try allocator.dupe(u8, json);
}

pub fn generateLocalParserCAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const serialized = try parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena.allocator(),
        prepared,
        .diagnostic,
        .{
            .minimize_states = options.minimize_states,
            .strict_expected_conflicts = false,
        },
    );
    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = options.compact_duplicate_states,
    });
}

pub fn generateLocalParseStateDumpAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const dump = if (options.report_states_for_rule) |rule_name|
        try parse_table_pipeline.generateStateActionDumpForRuleFromPrepared(arena.allocator(), prepared, rule_name)
    else
        try parse_table_pipeline.generateStateDumpFromPrepared(arena.allocator(), prepared);
    return try allocator.dupe(u8, dump);
}

pub fn generateLocalParseStateSummaryJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const result = try parse_table_pipeline.buildStatesFromPrepared(arena.allocator(), prepared);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeParseStateSummaryJson(&out.writer, result);
    return try out.toOwnedSlice();
}

pub fn generateLocalItemSetSnapshotJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const result = try parse_table_pipeline.buildStatesFromPrepared(arena.allocator(), prepared);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeItemSetSnapshotJson(&out.writer, result, prepared, options.report_states_for_rule);
    return try out.toOwnedSlice();
}

pub fn generateLocalConflictSummaryJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const flattened = try flatten_grammar.flattenGrammar(arena.allocator(), extracted.syntax);
    const result = try parse_table_pipeline.buildStatesFromPrepared(arena.allocator(), prepared);
    const unresolved = try result.unresolvedDecisionsAlloc(arena.allocator());
    const chosen = try result.chosenDecisionsAlloc(arena.allocator());
    const expected_report = try parse_table_pipeline.expectedConflictReportFromBuildResultAlloc(arena.allocator(), result);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeConflictSummaryJson(
        &out.writer,
        prepared.expected_conflicts.len,
        expected_report.unused_expected_conflict_indexes,
        chosen,
        unresolved,
        result,
        flattened,
    );
    return try out.toOwnedSlice();
}

pub fn generateLocalTokenConflictSummaryJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const prepared = try parse_grammar.parseRawGrammar(arena_allocator, &loaded.json.grammar);
    const extracted = try extract_tokens.extractTokens(arena_allocator, prepared);
    const expanded = try lexer_model.expandExtractedLexicalGrammar(arena_allocator, prepared.rules, extracted.lexical);
    const following_tokens = try lexer_model.computeFollowingTokensAlloc(
        arena_allocator,
        extracted.syntax,
        expanded.variables.len,
    );
    const conflict_map = try lexer_model.buildTokenConflictMapWithFollowingTokensAlloc(
        arena_allocator,
        expanded,
        following_tokens,
    );

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeTokenConflictSummaryJson(&out.writer, expanded, conflict_map);
    return try out.toOwnedSlice();
}

pub fn generateLocalMinimizationSummaryJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const prepared = try parse_grammar.parseRawGrammar(arena_allocator, &loaded.json.grammar);
    const default_serialized = try parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena_allocator,
        prepared,
        .diagnostic,
        .{
            .minimize_states = false,
            .strict_expected_conflicts = false,
        },
    );
    const minimized_serialized = try parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena_allocator,
        prepared,
        .diagnostic,
        .{
            .minimize_states = true,
            .strict_expected_conflicts = false,
        },
    );

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeMinimizationSummaryJson(&out.writer, default_serialized, minimized_serialized);
    return try out.toOwnedSlice();
}

pub fn generateLocalRegexSurfaceSummaryJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const prepared = try parse_grammar.parseRawGrammar(arena_allocator, &loaded.json.grammar);
    const extracted = try extract_tokens.extractTokens(arena_allocator, prepared);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeRegexSurfaceSummaryJson(&out.writer, arena_allocator, prepared.rules, extracted.lexical);
    return try out.toOwnedSlice();
}

pub fn generateLocalLexTableSummaryJsonAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const prepared = try parse_grammar.parseRawGrammar(arena_allocator, &loaded.json.grammar);
    const serialized = try parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena_allocator,
        prepared,
        .diagnostic,
        .{
            .minimize_states = options.minimize_states,
            .strict_expected_conflicts = false,
        },
    );

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeLexTableSummaryJson(&out.writer, serialized);
    return try out.toOwnedSlice();
}

pub fn parseUpstreamParserCSummaryAlloc(
    allocator: std.mem.Allocator,
    grammar_name: []const u8,
    parser_c: []const u8,
    node_types_json: ?[]const u8,
) !Summary {
    const state_count = defineValue(parser_c, "STATE_COUNT") orelse 0;
    const large_state_count = defineValue(parser_c, "LARGE_STATE_COUNT") orelse 0;
    const symbol_count = defineValue(parser_c, "SYMBOL_COUNT") orelse 0;
    const external_count = defineValue(parser_c, "EXTERNAL_TOKEN_COUNT") orelse 0;

    return .{
        .grammar_name = try allocator.dupe(u8, grammar_name),
        .language_version = defineValue(parser_c, "LANGUAGE_VERSION") orelse 0,
        .blocked = false,
        .rule_count = 0,
        .external_count = external_count,
        .extra_count = 0,
        .symbol_count = symbol_count,
        .symbol_order_hash = initializerBodyHash(parser_c, "static const char * const ts_symbol_names"),
        .token_count = defineValue(parser_c, "TOKEN_COUNT") orelse 0,
        .field_count = defineValue(parser_c, "FIELD_COUNT") orelse 0,
        .field_names_hash = initializerBodyHash(parser_c, "static const char * const ts_field_names"),
        .node_types_hash = if (node_types_json) |json| normalizedJsonHash(json) else 0,
        .alias_count = defineValue(parser_c, "ALIAS_COUNT") orelse 0,
        .production_id_count = defineValue(parser_c, "PRODUCTION_ID_COUNT") orelse 0,
        .serialized_state_count = state_count,
        .emitted_state_count = state_count,
        .large_state_count = large_state_count,
        .parse_action_list_count = countInitializerEntries(parser_c, "static const TSParseActionEntry ts_parse_actions[] = {"),
        .small_parse_row_count = countUniqueSmallParseOffsets(parser_c),
        .small_parse_map_count = if (state_count >= large_state_count) state_count - large_state_count else 0,
        .lex_mode_count = state_count,
        .lex_function_case_count = countLexFunctionCases(parser_c),
        .keyword_lex_function_case_count = countKeywordLexFunctionCases(parser_c),
        .large_character_set_count = std.mem.count(u8, parser_c, "static const TSCharacterRange "),
        .external_lex_state_count = externalScannerStateCount(parser_c),
    };
}

pub fn deinitSummary(allocator: std.mem.Allocator, summary: Summary) void {
    allocator.free(summary.grammar_name);
}

fn defineValue(source: []const u8, name: []const u8) ?usize {
    var pattern_buffer: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buffer, "#define {s} ", .{name}) catch return null;
    const start = std.mem.indexOf(u8, source, pattern) orelse return null;
    var index = start + pattern.len;
    while (index < source.len and source[index] == ' ') index += 1;
    const value_start = index;
    while (index < source.len and std.ascii.isDigit(source[index])) index += 1;
    if (index == value_start) return null;
    return std.fmt.parseUnsigned(usize, source[value_start..index], 10) catch null;
}

fn initializerBodyHash(source: []const u8, header: []const u8) u64 {
    const start = std.mem.indexOf(u8, source, header) orelse return 0;
    const open_brace = std.mem.indexOfScalarPos(u8, source, start + header.len, '{') orelse return 0;
    const body_start = open_brace + 1;
    const end_rel = std.mem.indexOf(u8, source[body_start..], "\n};") orelse return 0;
    const body = std.mem.trim(u8, source[body_start..][0..end_rel], " \n\r\t");
    return std.hash.Wyhash.hash(0, body);
}

fn normalizedJsonHash(source: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var in_string = false;
    var escaped = false;
    for (source) |ch| {
        if (in_string) {
            hasher.update(&.{ch});
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (std.ascii.isWhitespace(ch)) continue;
        hasher.update(&.{ch});
        if (ch == '"') in_string = true;
    }
    return hasher.final();
}

fn countInitializerEntries(source: []const u8, header: []const u8) usize {
    const start = std.mem.indexOf(u8, source, header) orelse return 0;
    const body_start = start + header.len;
    const end_rel = std.mem.indexOf(u8, source[body_start..], "\n};") orelse return 0;
    const body = source[body_start..][0..end_rel];
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, body[offset..], "{")) |rel| {
        count += 1;
        offset += rel + 1;
    }
    return count;
}

fn countUniqueSmallParseOffsets(source: []const u8) usize {
    const header = "static const uint32_t ts_small_parse_table_map[] = {";
    const start = std.mem.indexOf(u8, source, header) orelse return 0;
    const body_start = start + header.len;
    const end_rel = std.mem.indexOf(u8, source[body_start..], "\n};") orelse return 0;
    const body = source[body_start..][0..end_rel];
    var offsets: [4096]usize = undefined;
    var len: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t,");
        if (trimmed.len == 0) continue;
        const value_text = if (std.mem.lastIndexOfScalar(u8, trimmed, '=')) |eq_index|
            std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t,")
        else
            trimmed;
        const value = std.fmt.parseUnsigned(usize, value_text, 10) catch continue;
        var seen = false;
        for (offsets[0..len]) |existing| {
            if (existing == value) {
                seen = true;
                break;
            }
        }
        if (!seen and len < offsets.len) {
            offsets[len] = value;
            len += 1;
        }
    }
    return len;
}

fn externalScannerStateCount(source: []const u8) usize {
    const header = "ts_external_scanner_states[";
    const start = std.mem.indexOf(u8, source, header) orelse return 0;
    const value_start = start + header.len;
    const end = std.mem.indexOfScalarPos(u8, source, value_start, ']') orelse return 0;
    return std.fmt.parseUnsigned(usize, source[value_start..end], 10) catch 0;
}

fn countLexFunctionCases(source: []const u8) usize {
    const start_marker = "static bool ts_lex(TSLexer *lexer, TSStateId state)";
    const keyword_marker = "static bool ts_lex_keywords(TSLexer *lexer, TSStateId state)";
    const modes_marker = "static const TSLexerMode ts_lex_modes";
    return countCasesBetween(source, start_marker, keyword_marker) orelse
        countCasesBetween(source, start_marker, modes_marker) orelse
        0;
}

fn countKeywordLexFunctionCases(source: []const u8) usize {
    return countCasesBetween(
        source,
        "static bool ts_lex_keywords(TSLexer *lexer, TSStateId state)",
        "static const TSLexerMode ts_lex_modes",
    ) orelse 0;
}

fn countCasesBetween(source: []const u8, start_marker: []const u8, end_marker: []const u8) ?usize {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return null;
    const body_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, source, body_start, end_marker) orelse return null;
    return std.mem.count(u8, source[body_start..end], "\n    case ");
}

fn writeRawGrammarJson(writer: anytype, grammar: raw_grammar.RawGrammar) anyerror!void {
    try writer.writeAll("{\n");
    try writer.writeAll("  \"name\": ");
    try writeJsonString(writer, grammar.name);
    try writer.writeAll(",\n");
    try writer.print("  \"version\": [{d}, {d}, {d}],\n", .{ grammar.version[0], grammar.version[1], grammar.version[2] });
    try writer.writeAll("  \"rules\": [");
    if (grammar.rules.len != 0) try writer.writeByte('\n');
    for (grammar.rules, 0..) |entry, index| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, entry.name);
        try writer.writeAll(", \"rule\": ");
        try writeRawRuleJson(writer, entry.rule);
        try writer.writeAll(" }");
        if (index + 1 != grammar.rules.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (grammar.rules.len != 0) try writer.writeAll("  ");
    try writer.writeAll("],\n");
    try writer.writeAll("  \"externals\": ");
    try writeRawRuleArrayJson(writer, grammar.externals);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"extras\": ");
    try writeRawRuleArrayJson(writer, grammar.extras);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"inline\": ");
    try writeStringArrayJson(writer, grammar.inline_rules);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"supertypes\": ");
    try writeStringArrayJson(writer, grammar.supertypes);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"word\": ");
    if (grammar.word) |word| try writeJsonString(writer, word) else try writer.writeAll("null");
    try writer.writeAll(",\n");
    try writer.writeAll("  \"conflicts\": ");
    try writeStringSetsJson(writer, grammar.expected_conflicts);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"precedences\": ");
    try writeRawPrecedencesJson(writer, grammar.precedences);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"reserved\": ");
    try writeRawReservedSetsJson(writer, grammar.reserved);
    try writer.writeByte('\n');
    try writer.writeAll("}\n");
}

fn writeRawRuleArrayJson(writer: anytype, rules: []const *const raw_grammar.RawRule) anyerror!void {
    try writer.writeByte('[');
    for (rules, 0..) |rule, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeRawRuleJson(writer, rule);
    }
    try writer.writeByte(']');
}

fn writeRawRuleJson(writer: anytype, rule: *const raw_grammar.RawRule) anyerror!void {
    try writer.writeAll("{ \"type\": ");
    try writeJsonString(writer, rule.tagName());
    switch (rule.*) {
        .alias => |alias| {
            try writer.writeAll(", \"content\": ");
            try writeRawRuleJson(writer, alias.content);
            try writer.print(", \"named\": {}", .{alias.named});
            try writer.writeAll(", \"value\": ");
            try writeJsonString(writer, alias.value);
        },
        .blank => {},
        .string => |value| {
            try writer.writeAll(", \"value\": ");
            try writeJsonString(writer, value);
        },
        .pattern => |pattern| {
            try writer.writeAll(", \"value\": ");
            try writeJsonString(writer, pattern.value);
            if (pattern.flags) |flags| {
                try writer.writeAll(", \"flags\": ");
                try writeJsonString(writer, flags);
            }
        },
        .symbol => |name| {
            try writer.writeAll(", \"name\": ");
            try writeJsonString(writer, name);
        },
        .choice => |members| {
            try writer.writeAll(", \"members\": ");
            try writeRawRuleArrayJson(writer, members);
        },
        .field => |field| {
            try writer.writeAll(", \"name\": ");
            try writeJsonString(writer, field.name);
            try writer.writeAll(", \"content\": ");
            try writeRawRuleJson(writer, field.content);
        },
        .seq => |members| {
            try writer.writeAll(", \"members\": ");
            try writeRawRuleArrayJson(writer, members);
        },
        .repeat => |inner| {
            try writer.writeAll(", \"content\": ");
            try writeRawRuleJson(writer, inner);
        },
        .repeat1 => |inner| {
            try writer.writeAll(", \"content\": ");
            try writeRawRuleJson(writer, inner);
        },
        .prec_dynamic => |prec| {
            try writer.print(", \"value\": {d}", .{prec.value});
            try writer.writeAll(", \"content\": ");
            try writeRawRuleJson(writer, prec.content);
        },
        .prec_left => |prec| try writeRawPrecJson(writer, prec),
        .prec_right => |prec| try writeRawPrecJson(writer, prec),
        .prec => |prec| try writeRawPrecJson(writer, prec),
        .token => |inner| {
            try writer.writeAll(", \"content\": ");
            try writeRawRuleJson(writer, inner);
        },
        .immediate_token => |inner| {
            try writer.writeAll(", \"content\": ");
            try writeRawRuleJson(writer, inner);
        },
        .reserved => |reserved| {
            try writer.writeAll(", \"context_name\": ");
            try writeJsonString(writer, reserved.context_name);
            try writer.writeAll(", \"content\": ");
            try writeRawRuleJson(writer, reserved.content);
        },
    }
    try writer.writeAll(" }");
}

fn writeRawPrecJson(writer: anytype, prec: raw_grammar.RawPrec) anyerror!void {
    try writer.writeAll(", \"value\": ");
    try writeRawPrecedenceValueJson(writer, prec.value);
    try writer.writeAll(", \"content\": ");
    try writeRawRuleJson(writer, prec.content);
}

fn writeRawPrecedenceValueJson(writer: anytype, value: raw_grammar.RawPrecedenceValue) !void {
    switch (value) {
        .integer => |integer| try writer.print("{d}", .{integer}),
        .name => |name| try writeJsonString(writer, name),
    }
}

fn writeStringArrayJson(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}

fn writeStringSetsJson(writer: anytype, sets: []const []const []const u8) !void {
    try writer.writeByte('[');
    for (sets, 0..) |set, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeStringArrayJson(writer, set);
    }
    try writer.writeByte(']');
}

fn writeRawPrecedencesJson(writer: anytype, precedences: []const raw_grammar.PrecedenceList) !void {
    try writer.writeByte('[');
    for (precedences, 0..) |ordering, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeRawRuleArrayJson(writer, ordering);
    }
    try writer.writeByte(']');
}

fn writeRawReservedSetsJson(writer: anytype, sets: []const raw_grammar.RawReservedSet) !void {
    try writer.writeByte('[');
    for (sets, 0..) |set, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll("{ \"context_name\": ");
        try writeJsonString(writer, set.context_name);
        try writer.writeAll(", \"members\": ");
        try writeRawRuleArrayJson(writer, set.members);
        try writer.writeAll(" }");
    }
    try writer.writeByte(']');
}

fn writeParseStateSummaryJson(
    writer: anytype,
    result: @import("../parse_table/build.zig").BuildResult,
) !void {
    const summary = parseStateSummary(result);
    try writer.writeAll("{\n");
    try writeUsizeField(writer, 2, "state_count", summary.state_count, true);
    try writeUsizeField(writer, 2, "production_count", summary.production_count, true);
    try writeUsizeField(writer, 2, "item_count", summary.item_count, true);
    try writeUsizeField(writer, 2, "transition_count", summary.transition_count, true);
    try writeUsizeField(writer, 2, "conflict_count", summary.conflict_count, true);
    try writeUsizeField(writer, 2, "max_items_per_state", summary.max_items_per_state, true);
    try writeUsizeField(writer, 2, "max_transitions_per_state", summary.max_transitions_per_state, true);
    try writeU64HexField(writer, 2, "core_hash", summary.core_hash, true);
    try writeU64HexField(writer, 2, "lookahead_hash", summary.lookahead_hash, true);
    try writeU64HexField(writer, 2, "transition_hash", summary.transition_hash, true);
    try writeU64HexField(writer, 2, "conflict_hash", summary.conflict_hash, false);
    try writer.writeAll("}\n");
}

const ParseStateSummary = struct {
    state_count: usize,
    production_count: usize,
    item_count: usize,
    transition_count: usize,
    conflict_count: usize,
    max_items_per_state: usize,
    max_transitions_per_state: usize,
    core_hash: u64,
    lookahead_hash: u64,
    transition_hash: u64,
    conflict_hash: u64,
};

const ItemSetComparisonSummary = struct {
    selected_state_count: usize,
    kernel_item_count: usize,
    closure_item_count: usize,
    completed_item_count: usize,
    lookahead_item_count: usize,
    reserved_lookahead_item_count: usize,
    kernel_hash: u64,
    closure_hash: u64,
    completed_item_hash: u64,
    lookahead_hash: u64,
    reserved_lookahead_hash: u64,
    transition_hash: u64,
};

fn parseStateSummary(result: @import("../parse_table/build.zig").BuildResult) ParseStateSummary {
    var core_hasher = std.hash.Wyhash.init(0);
    var lookahead_hasher = std.hash.Wyhash.init(0);
    var transition_hasher = std.hash.Wyhash.init(0);
    var conflict_hasher = std.hash.Wyhash.init(0);
    var item_count: usize = 0;
    var transition_count: usize = 0;
    var conflict_count: usize = 0;
    var max_items: usize = 0;
    var max_transitions: usize = 0;

    for (result.states) |parse_state| {
        hashU32(&core_hasher, parse_state.id);
        hashU32(&lookahead_hasher, parse_state.id);
        hashU32(&transition_hasher, parse_state.id);
        hashU32(&conflict_hasher, parse_state.id);
        item_count += parse_state.items.len;
        transition_count += parse_state.transitions.len;
        conflict_count += parse_state.conflicts.len;
        max_items = @max(max_items, parse_state.items.len);
        max_transitions = @max(max_transitions, parse_state.transitions.len);

        for (parse_state.items) |entry| {
            hashU32(&core_hasher, entry.item.production_id);
            hashU32(&core_hasher, entry.item.step_index);
            hashU32(&lookahead_hasher, entry.item.production_id);
            hashU32(&lookahead_hasher, entry.item.step_index);
            hashSymbolSet(&lookahead_hasher, entry.lookaheads);
            hashU32(&lookahead_hasher, entry.following_reserved_word_set_id);
        }
        for (parse_state.transitions) |transition| {
            hashSymbolRef(&transition_hasher, transition.symbol);
            hashU32(&transition_hasher, transition.state);
            hashBool(&transition_hasher, transition.extra);
        }
        for (parse_state.conflicts) |conflict| {
            hashTag(&conflict_hasher, @tagName(conflict.kind));
            if (conflict.symbol) |symbol| {
                hashBool(&conflict_hasher, true);
                hashSymbolRef(&conflict_hasher, symbol);
            } else {
                hashBool(&conflict_hasher, false);
            }
            for (conflict.items) |conflict_item| {
                hashU32(&conflict_hasher, conflict_item.production_id);
                hashU32(&conflict_hasher, conflict_item.step_index);
            }
        }
    }

    return .{
        .state_count = result.states.len,
        .production_count = result.productions.len,
        .item_count = item_count,
        .transition_count = transition_count,
        .conflict_count = conflict_count,
        .max_items_per_state = max_items,
        .max_transitions_per_state = max_transitions,
        .core_hash = core_hasher.final(),
        .lookahead_hash = lookahead_hasher.final(),
        .transition_hash = transition_hasher.final(),
        .conflict_hash = conflict_hasher.final(),
    };
}

fn writeItemSetSnapshotJson(
    writer: anytype,
    result: @import("../parse_table/build.zig").BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    report_states_for_rule: ?[]const u8,
) !void {
    var selected_count: usize = 0;
    for (result.states) |parse_state| {
        if (stateMatchesRule(result, prepared, parse_state, report_states_for_rule)) {
            selected_count += 1;
        }
    }

    try writer.writeAll("{\n");
    try writeIndent(writer, 2);
    try writer.writeAll("\"selected_rule\": ");
    if (report_states_for_rule) |rule_name| {
        try writeJsonString(writer, rule_name);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writeUsizeField(writer, 2, "state_count", result.states.len, true);
    try writeUsizeField(writer, 2, "selected_state_count", selected_count, true);
    try writeItemSetComparisonJson(writer, result, prepared, report_states_for_rule, 2);
    try writer.writeAll(",\n");
    try writeIndent(writer, 2);
    try writer.writeAll("\"states\": [");
    if (selected_count != 0) try writer.writeByte('\n');

    var emitted: usize = 0;
    for (result.states) |parse_state| {
        if (!stateMatchesRule(result, prepared, parse_state, report_states_for_rule)) continue;
        try writeItemSetStateJson(writer, result, parse_state, 4);
        emitted += 1;
        if (emitted != selected_count) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (selected_count != 0) try writeIndent(writer, 2);
    try writer.writeAll("]\n");
    try writer.writeAll("}\n");
}

fn writeItemSetComparisonJson(
    writer: anytype,
    result: @import("../parse_table/build.zig").BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    report_states_for_rule: ?[]const u8,
    indent: usize,
) !void {
    const summary = itemSetComparisonSummary(result, prepared, report_states_for_rule);
    try writeIndent(writer, indent);
    try writer.writeAll("\"comparison\": {\n");
    try writeUsizeField(writer, indent + 2, "selected_state_count", summary.selected_state_count, true);
    try writeUsizeField(writer, indent + 2, "kernel_item_count", summary.kernel_item_count, true);
    try writeUsizeField(writer, indent + 2, "closure_item_count", summary.closure_item_count, true);
    try writeUsizeField(writer, indent + 2, "completed_item_count", summary.completed_item_count, true);
    try writeUsizeField(writer, indent + 2, "lookahead_item_count", summary.lookahead_item_count, true);
    try writeUsizeField(writer, indent + 2, "reserved_lookahead_item_count", summary.reserved_lookahead_item_count, true);
    try writeU64HexField(writer, indent + 2, "kernel_hash", summary.kernel_hash, true);
    try writeU64HexField(writer, indent + 2, "closure_hash", summary.closure_hash, true);
    try writeU64HexField(writer, indent + 2, "completed_item_hash", summary.completed_item_hash, true);
    try writeU64HexField(writer, indent + 2, "lookahead_hash", summary.lookahead_hash, true);
    try writeU64HexField(writer, indent + 2, "reserved_lookahead_hash", summary.reserved_lookahead_hash, true);
    try writeU64HexField(writer, indent + 2, "transition_hash", summary.transition_hash, true);
    try writeItemSetComparisonKeysJson(writer, summary, indent + 2);
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

fn writeItemSetComparisonKeysJson(writer: anytype, summary: ItemSetComparisonSummary, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("\"comparison_keys\": {\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"note\": ");
    try writeJsonString(writer, "local item-set comparison keys are stable; tree-sitter does not expose an equivalent bounded item-set artifact through the parser.c snapshot");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"keys\": [\n");
    try writeItemSetComparisonKey(writer, indent + 4, "kernel_items", summary.kernel_hash, true);
    try writeItemSetComparisonKey(writer, indent + 4, "closure_items", summary.closure_hash, true);
    try writeItemSetComparisonKey(writer, indent + 4, "completed_items", summary.completed_item_hash, true);
    try writeItemSetComparisonKey(writer, indent + 4, "lookaheads", summary.lookahead_hash, true);
    try writeItemSetComparisonKey(writer, indent + 4, "reserved_lookaheads", summary.reserved_lookahead_hash, true);
    try writeItemSetComparisonKey(writer, indent + 4, "transitions", summary.transition_hash, false);
    try writeIndent(writer, indent + 2);
    try writer.writeAll("]\n");
    try writeIndent(writer, indent);
    try writer.writeAll("}\n");
}

fn writeItemSetComparisonKey(
    writer: anytype,
    indent: usize,
    name: []const u8,
    hash: u64,
    trailing_comma: bool,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{ \"name\": ");
    try writeJsonString(writer, name);
    try writer.writeAll(", \"local_hash\": \"");
    try writer.print("0x{x:0>16}", .{hash});
    try writer.writeByte('"');
    try writer.writeAll(", \"upstream_hash\": null, \"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(" }");
    if (trailing_comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn itemSetComparisonSummary(
    result: @import("../parse_table/build.zig").BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    report_states_for_rule: ?[]const u8,
) ItemSetComparisonSummary {
    var kernel_hasher = std.hash.Wyhash.init(0);
    var closure_hasher = std.hash.Wyhash.init(0);
    var completed_hasher = std.hash.Wyhash.init(0);
    var lookahead_hasher = std.hash.Wyhash.init(0);
    var reserved_lookahead_hasher = std.hash.Wyhash.init(0);
    var transition_hasher = std.hash.Wyhash.init(0);
    var summary: ItemSetComparisonSummary = .{
        .selected_state_count = 0,
        .kernel_item_count = 0,
        .closure_item_count = 0,
        .completed_item_count = 0,
        .lookahead_item_count = 0,
        .reserved_lookahead_item_count = 0,
        .kernel_hash = 0,
        .closure_hash = 0,
        .completed_item_hash = 0,
        .lookahead_hash = 0,
        .reserved_lookahead_hash = 0,
        .transition_hash = 0,
    };

    for (result.states) |parse_state| {
        if (!stateMatchesRule(result, prepared, parse_state, report_states_for_rule)) continue;
        summary.selected_state_count += 1;
        for (parse_state.items) |entry| {
            if (std.mem.eql(u8, itemOrigin(result, entry), "kernel")) {
                summary.kernel_item_count += 1;
                hashItemSetComparisonEntry(&kernel_hasher, result, parse_state.id, entry);
            } else {
                summary.closure_item_count += 1;
                hashItemSetComparisonEntry(&closure_hasher, result, parse_state.id, entry);
            }
            if (!entry.lookaheads.isEmpty()) {
                summary.lookahead_item_count += 1;
                hashItemSetComparisonEntry(&lookahead_hasher, result, parse_state.id, entry);
                hashSymbolSet(&lookahead_hasher, entry.lookaheads);
            }
            if (entry.following_reserved_word_set_id != 0) {
                summary.reserved_lookahead_item_count += 1;
                hashItemSetComparisonEntry(&reserved_lookahead_hasher, result, parse_state.id, entry);
                hashU32(&reserved_lookahead_hasher, entry.following_reserved_word_set_id);
            }
            if (itemAtEnd(result, entry)) {
                summary.completed_item_count += 1;
                hashItemSetComparisonEntry(&completed_hasher, result, parse_state.id, entry);
            }
        }
        for (parse_state.transitions) |transition| {
            hashU32(&transition_hasher, parse_state.id);
            hashSymbolRef(&transition_hasher, transition.symbol);
            hashU32(&transition_hasher, transition.state);
            hashBool(&transition_hasher, transition.extra);
        }
    }

    summary.kernel_hash = kernel_hasher.final();
    summary.closure_hash = closure_hasher.final();
    summary.completed_item_hash = completed_hasher.final();
    summary.lookahead_hash = lookahead_hasher.final();
    summary.reserved_lookahead_hash = reserved_lookahead_hasher.final();
    summary.transition_hash = transition_hasher.final();
    return summary;
}

fn hashItemSetComparisonEntry(
    hasher: *std.hash.Wyhash,
    result: @import("../parse_table/build.zig").BuildResult,
    state_id: u32,
    entry: @import("../parse_table/item.zig").ParseItemSetEntry,
) void {
    hashU32(hasher, state_id);
    hashU32(hasher, entry.item.production_id);
    hashU32(hasher, entry.item.step_index);
    hashU32(hasher, entry.following_reserved_word_set_id);
    if (entry.item.production_id < result.productions.len) {
        const production = result.productions[entry.item.production_id];
        hashBool(hasher, true);
        hashU32(hasher, production.lhs);
        hashUsize(hasher, production.steps.len);
        hashBool(hasher, entry.item.step_index >= production.steps.len);
    } else {
        hashBool(hasher, false);
    }
}

fn itemAtEnd(
    result: @import("../parse_table/build.zig").BuildResult,
    entry: @import("../parse_table/item.zig").ParseItemSetEntry,
) bool {
    if (entry.item.production_id >= result.productions.len) return false;
    return entry.item.step_index >= result.productions[entry.item.production_id].steps.len;
}

fn stateMatchesRule(
    result: @import("../parse_table/build.zig").BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    parse_state: @import("../parse_table/state.zig").ParseState,
    report_states_for_rule: ?[]const u8,
) bool {
    const rule_name = report_states_for_rule orelse return true;
    for (parse_state.items) |entry| {
        if (entry.item.production_id >= result.productions.len) continue;
        const production = result.productions[entry.item.production_id];
        if (production.augmented) continue;
        if (production.lhs >= prepared.variables.len) continue;
        if (std.mem.eql(u8, prepared.variables[production.lhs].name, rule_name)) return true;
    }
    return false;
}

fn writeItemSetStateJson(
    writer: anytype,
    result: @import("../parse_table/build.zig").BuildResult,
    parse_state: @import("../parse_table/state.zig").ParseState,
    indent: usize,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try writeUsizeField(writer, indent + 2, "id", parse_state.id, true);
    try writeUsizeField(writer, indent + 2, "core_id", parse_state.core_id, true);
    try writeUsizeField(writer, indent + 2, "lex_state_id", parse_state.lex_state_id, true);
    try writeUsizeField(writer, indent + 2, "reserved_word_set_id", parse_state.reserved_word_set_id, true);
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"items\": [");
    if (parse_state.items.len != 0) try writer.writeByte('\n');
    for (parse_state.items, 0..) |entry, index| {
        try writeItemSetEntryJson(writer, result, entry, indent + 4);
        if (index + 1 != parse_state.items.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (parse_state.items.len != 0) try writeIndent(writer, indent + 2);
    try writer.writeAll("],\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"transitions\": [");
    if (parse_state.transitions.len != 0) try writer.writeByte('\n');
    for (parse_state.transitions, 0..) |transition, index| {
        try writeIndent(writer, indent + 4);
        try writer.writeAll("{ \"symbol\": ");
        try writeSymbolRef(writer, transition.symbol);
        try writer.print(", \"state\": {d}, \"extra\": ", .{transition.state});
        try writeBoolJson(writer, transition.extra);
        try writer.writeAll(" }");
        if (index + 1 != parse_state.transitions.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (parse_state.transitions.len != 0) try writeIndent(writer, indent + 2);
    try writer.writeAll("]\n");
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

fn writeItemSetEntryJson(
    writer: anytype,
    result: @import("../parse_table/build.zig").BuildResult,
    entry: @import("../parse_table/item.zig").ParseItemSetEntry,
    indent: usize,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{ \"production_id\": ");
    try writer.print("{d}", .{entry.item.production_id});
    try writer.writeAll(", \"step_index\": ");
    try writer.print("{d}", .{entry.item.step_index});
    if (entry.item.production_id < result.productions.len) {
        const production = result.productions[entry.item.production_id];
        try writer.writeAll(", \"production_lhs\": ");
        try writer.print("{d}", .{production.lhs});
        try writer.writeAll(", \"production_step_count\": ");
        try writer.print("{d}", .{production.steps.len});
        try writer.writeAll(", \"at_end\": ");
        try writeBoolJson(writer, entry.item.step_index >= production.steps.len);
    }
    try writer.writeAll(", \"origin\": ");
    try writeJsonString(writer, itemOrigin(result, entry));
    try writer.writeAll(", \"following_reserved_word_set_id\": ");
    try writer.print("{d}", .{entry.following_reserved_word_set_id});
    try writer.writeAll(", \"lookaheads\": ");
    try writeSymbolSetJson(writer, entry.lookaheads);
    try writer.writeAll(" }");
}

fn itemOrigin(
    result: @import("../parse_table/build.zig").BuildResult,
    entry: @import("../parse_table/item.zig").ParseItemSetEntry,
) []const u8 {
    if (entry.item.production_id < result.productions.len and result.productions[entry.item.production_id].augmented) {
        return "kernel";
    }
    return if (entry.item.step_index == 0) "closure" else "kernel";
}

fn writeSymbolSetJson(writer: anytype, set: @import("../parse_table/first.zig").SymbolSet) !void {
    try writer.writeAll("{ \"end\": ");
    try writeBoolJson(writer, set.includes_end);
    try writer.writeAll(", \"epsilon\": ");
    try writeBoolJson(writer, set.includes_epsilon);
    try writer.writeAll(", \"terminals\": ");
    try writeSymbolBitsJson(writer, set.terminals);
    try writer.writeAll(", \"externals\": ");
    try writeSymbolBitsJson(writer, set.externals);
    try writer.writeAll(" }");
}

fn writeSymbolBitsJson(writer: anytype, bits: @import("../parse_table/first.zig").SymbolBits) !void {
    try writer.writeByte('[');
    var first = true;
    for (0..bits.len()) |index| {
        if (!bits.get(index)) continue;
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.print("{d}", .{index});
    }
    try writer.writeByte(']');
}

fn hashSymbolSet(hasher: *std.hash.Wyhash, set: @import("../parse_table/first.zig").SymbolSet) void {
    hashUsize(hasher, set.terminals.len());
    hasher.update(set.terminals.maskBytes());
    hashUsize(hasher, set.externals.len());
    hasher.update(set.externals.maskBytes());
    hashBool(hasher, set.includes_end);
    hashBool(hasher, set.includes_epsilon);
}

fn writeConflictSummaryJson(
    writer: anytype,
    declared_expected_count: usize,
    unused_expected_indexes: []const usize,
    chosen: []const @import("../parse_table/resolution.zig").ChosenDecisionRef,
    unresolved: []const @import("../parse_table/resolution.zig").UnresolvedDecisionRef,
    result: parse_table_build.BuildResult,
    flattened: syntax_ir.SyntaxGrammar,
) !void {
    const chosen_counts = chosenDecisionCounts(chosen, result.productions);
    const counts = conflictReasonCounts(unresolved);
    try writer.writeAll("{\n");
    try writeUsizeField(writer, 2, "declared_expected_conflict_count", declared_expected_count, true);
    try writeUsizeField(writer, 2, "unused_expected_conflict_count", unused_expected_indexes.len, true);
    try writer.writeAll("  \"unused_expected_conflict_indexes\": [");
    for (unused_expected_indexes, 0..) |index_value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{index_value});
    }
    try writer.writeAll("],\n");
    try writeUsizeField(writer, 2, "chosen_count", chosen.len, true);
    try writer.writeAll("  \"chosen_actions\": {\n");
    try writeUsizeField(writer, 4, "shift", chosen_counts.shift, true);
    try writeUsizeField(writer, 4, "reduce", chosen_counts.reduce, true);
    try writeUsizeField(writer, 4, "accept", chosen_counts.accept, true);
    try writeUsizeField(writer, 4, "dynamic_precedence", chosen_counts.dynamic_precedence, true);
    try writeUsizeField(writer, 4, "max_candidate_count", chosen_counts.max_candidate_count, false);
    try writer.writeAll("  },\n");
    try writer.writeAll("  \"chosen_candidate_shapes\": {\n");
    try writeUsizeField(writer, 4, "shift_reduce", chosen_counts.shift_reduce, true);
    try writeUsizeField(writer, 4, "reduce_reduce", chosen_counts.reduce_reduce, true);
    try writeUsizeField(writer, 4, "single_action", chosen_counts.single_action, true);
    try writeUsizeField(writer, 4, "other", chosen_counts.other, false);
    try writer.writeAll("  },\n");
    try writeUsizeField(writer, 2, "unresolved_count", unresolved.len, true);
    try writer.writeAll("  \"unresolved_reasons\": {\n");
    try writeUsizeField(writer, 4, "multiple_candidates", counts.multiple_candidates, true);
    try writeUsizeField(writer, 4, "shift_reduce", counts.shift_reduce, true);
    try writeUsizeField(writer, 4, "shift_reduce_expected", counts.shift_reduce_expected, true);
    try writeUsizeField(writer, 4, "reduce_reduce_deferred", counts.reduce_reduce_deferred, true);
    try writeUsizeField(writer, 4, "reduce_reduce_expected", counts.reduce_reduce_expected, true);
    try writeUsizeField(writer, 4, "unsupported_action_mix", counts.unsupported_action_mix, false);
    try writer.writeAll("  },\n");
    try writer.writeAll("  \"unresolved_samples\": [");
    if (unresolved.len != 0) try writer.writeByte('\n');
    for (unresolved[0..@min(unresolved.len, 16)], 0..) |decision, index| {
        try writer.writeAll("    { \"state_id\": ");
        try writer.print("{d}", .{decision.state_id});
        try writer.writeAll(", \"lookahead\": ");
        try writeSymbolRef(writer, decision.symbol);
        try writer.writeAll(", \"reason\": ");
        try writeJsonString(writer, @tagName(decision.reason));
        try writer.writeAll(", \"candidate_shape\": ");
        try writeJsonString(writer, @tagName(candidateShape(decision.candidate_actions)));
        try writer.writeAll(", \"reduce_parent_rules\": ");
        try writeReduceParentRuleNames(writer, result, flattened, decision.candidate_actions);
        try writer.writeAll(" }");
        if (index + 1 != @min(unresolved.len, 16)) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (unresolved.len != 0) try writer.writeAll("  ");
    try writer.writeAll("]\n");
    try writer.writeAll("}\n");
}

fn writeReduceParentRuleNames(
    writer: anytype,
    result: parse_table_build.BuildResult,
    flattened: syntax_ir.SyntaxGrammar,
    candidate_actions: []const @import("../parse_table/actions.zig").ParseAction,
) !void {
    try writer.writeByte('[');
    var written: usize = 0;
    for (candidate_actions) |action| {
        const production_id = switch (action) {
            .reduce => |id| id,
            else => continue,
        };
        if (production_id >= result.productions.len) continue;
        const lhs = result.productions[production_id].lhs;
        if (lhs >= flattened.variables.len) continue;
        if (written != 0) try writer.writeAll(", ");
        try writeJsonString(writer, flattened.variables[lhs].name);
        written += 1;
    }
    try writer.writeByte(']');
}

const ChosenDecisionCounts = struct {
    shift: usize = 0,
    reduce: usize = 0,
    accept: usize = 0,
    dynamic_precedence: usize = 0,
    max_candidate_count: usize = 0,
    shift_reduce: usize = 0,
    reduce_reduce: usize = 0,
    single_action: usize = 0,
    other: usize = 0,
};

fn chosenDecisionCounts(
    chosen: []const @import("../parse_table/resolution.zig").ChosenDecisionRef,
    productions: []const parse_table_build.ProductionInfo,
) ChosenDecisionCounts {
    var counts = ChosenDecisionCounts{};
    for (chosen) |decision| {
        counts.max_candidate_count = @max(counts.max_candidate_count, decision.candidate_actions.len);
        if (decisionUsesDynamicPrecedence(decision.candidate_actions, productions)) counts.dynamic_precedence += 1;
        switch (candidateShape(decision.candidate_actions)) {
            .shift_reduce => counts.shift_reduce += 1,
            .reduce_reduce => counts.reduce_reduce += 1,
            .single_action => counts.single_action += 1,
            .other => counts.other += 1,
        }
        switch (decision.action) {
            .shift => counts.shift += 1,
            .reduce => counts.reduce += 1,
            .accept => counts.accept += 1,
        }
    }
    return counts;
}

fn decisionUsesDynamicPrecedence(
    candidate_actions: []const @import("../parse_table/actions.zig").ParseAction,
    productions: []const parse_table_build.ProductionInfo,
) bool {
    if (candidate_actions.len <= 1) return false;
    for (candidate_actions) |action| {
        const production_id = switch (action) {
            .reduce => |id| id,
            else => continue,
        };
        if (production_id < productions.len and productions[production_id].dynamic_precedence != 0) return true;
    }
    return false;
}

const CandidateShape = enum {
    shift_reduce,
    reduce_reduce,
    single_action,
    other,
};

fn candidateShape(actions: []const @import("../parse_table/actions.zig").ParseAction) CandidateShape {
    if (actions.len <= 1) return .single_action;

    var shift_count: usize = 0;
    var reduce_count: usize = 0;
    var accept_count: usize = 0;
    for (actions) |action| switch (action) {
        .shift => shift_count += 1,
        .reduce => reduce_count += 1,
        .accept => accept_count += 1,
    };

    if (accept_count == 0 and shift_count == 1 and reduce_count >= 1) return .shift_reduce;
    if (accept_count == 0 and shift_count == 0 and reduce_count >= 2) return .reduce_reduce;
    return .other;
}

const ConflictReasonCounts = struct {
    multiple_candidates: usize = 0,
    shift_reduce: usize = 0,
    shift_reduce_expected: usize = 0,
    reduce_reduce_deferred: usize = 0,
    reduce_reduce_expected: usize = 0,
    unsupported_action_mix: usize = 0,
};

fn conflictReasonCounts(unresolved: []const @import("../parse_table/resolution.zig").UnresolvedDecisionRef) ConflictReasonCounts {
    var counts = ConflictReasonCounts{};
    for (unresolved) |decision| {
        switch (decision.reason) {
            .multiple_candidates => counts.multiple_candidates += 1,
            .shift_reduce => counts.shift_reduce += 1,
            .shift_reduce_expected => counts.shift_reduce_expected += 1,
            .reduce_reduce_deferred => counts.reduce_reduce_deferred += 1,
            .reduce_reduce_expected => counts.reduce_reduce_expected += 1,
            .unsupported_action_mix => counts.unsupported_action_mix += 1,
        }
    }
    return counts;
}

fn writeTokenConflictSummaryJson(
    writer: anytype,
    grammar: lexer_model.ExpandedLexicalGrammar,
    conflict_map: lexer_model.TokenConflictMap,
) !void {
    const counts = tokenConflictCounts(conflict_map);
    try writer.writeAll("{\n");
    try writeUsizeField(writer, 2, "variable_count", grammar.variables.len, true);
    try writeUsizeField(writer, 2, "directional_pair_count", directionalPairCount(grammar.variables.len), true);
    try writeUsizeField(writer, 2, "conflict_pair_count", counts.conflict_pairs, true);
    try writer.writeAll("  \"status_counts\": {\n");
    try writeUsizeField(writer, 4, "matches_prefix", counts.matches_prefix, true);
    try writeUsizeField(writer, 4, "does_match_continuation", counts.does_match_continuation, true);
    try writeUsizeField(writer, 4, "does_match_valid_continuation", counts.does_match_valid_continuation, true);
    try writeUsizeField(writer, 4, "does_match_separators", counts.does_match_separators, true);
    try writeUsizeField(writer, 4, "matches_same_string", counts.matches_same_string, true);
    try writeUsizeField(writer, 4, "matches_different_string", counts.matches_different_string, true);
    try writeUsizeField(writer, 4, "starting_overlap", counts.starting_overlap, false);
    try writer.writeAll("  },\n");

    try writer.writeAll("  \"variables\": [\n");
    for (grammar.variables, 0..) |variable, index| {
        try writeIndent(writer, 4);
        try writer.writeAll("{ \"index\": ");
        try writer.print("{d}", .{index});
        try writer.writeAll(", \"name\": ");
        try writeJsonString(writer, variable.name);
        try writer.writeAll(", \"starting_range_count\": ");
        try writer.print("{d}", .{conflict_map.starting_chars_by_index[index].ranges.items.len});
        try writer.writeAll(", \"following_token_count\": ");
        try writer.print("{d}", .{countTokenIndexSet(conflict_map.following_tokens_by_index[index])});
        try writer.writeAll(", \"following_range_count\": ");
        try writer.print("{d}", .{conflict_map.following_chars_by_index[index].ranges.items.len});
        try writer.writeAll(" }");
        if (index + 1 != grammar.variables.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.writeAll("  ],\n");

    try writer.writeAll("  \"pairs\": [\n");
    var wrote_pair = false;
    for (0..grammar.variables.len) |left| {
        for (0..grammar.variables.len) |right| {
            if (left == right) continue;
            const status = conflict_map.status(left, right);
            if (!tokenConflictStatusIsConcretePair(status)) continue;
            if (wrote_pair) try writer.writeAll(",\n");
            wrote_pair = true;
            try writeTokenConflictPairJson(writer, grammar, left, right, status);
        }
    }
    if (wrote_pair) try writer.writeByte('\n');
    try writer.writeAll("  ],\n");
    try writeTokenConflictComparisonKeysJson(writer, grammar, conflict_map, counts, 2);
    try writer.writeAll("}\n");
}

fn writeTokenConflictComparisonKeysJson(
    writer: anytype,
    grammar: lexer_model.ExpandedLexicalGrammar,
    conflict_map: lexer_model.TokenConflictMap,
    counts: TokenConflictCounts,
    indent: usize,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("\"comparison_keys\": {\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"note\": ");
    try writeJsonString(writer, "local token-conflict comparison keys are stable; tree-sitter does not expose equivalent token-conflict internals through the bounded parser.c snapshot");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"keys\": [\n");
    try writeTokenConflictComparisonKey(writer, indent + 4, "counts", hashTokenConflictCounts(counts), true);
    try writeTokenConflictComparisonKey(writer, indent + 4, "variables", hashTokenConflictVariables(grammar), true);
    try writeTokenConflictComparisonKey(writer, indent + 4, "starting_ranges", hashTokenConflictCharacterSets(conflict_map.starting_chars_by_index), true);
    try writeTokenConflictComparisonKey(writer, indent + 4, "following_tokens", hashTokenConflictFollowingTokens(conflict_map.following_tokens_by_index), true);
    try writeTokenConflictComparisonKey(writer, indent + 4, "following_ranges", hashTokenConflictCharacterSets(conflict_map.following_chars_by_index), true);
    try writeTokenConflictComparisonKey(writer, indent + 4, "status_matrix", hashTokenConflictStatusMatrix(conflict_map), true);
    try writeTokenConflictComparisonKey(writer, indent + 4, "concrete_pairs", hashTokenConflictConcretePairs(grammar, conflict_map), false);
    try writeIndent(writer, indent + 2);
    try writer.writeAll("]\n");
    try writeIndent(writer, indent);
    try writer.writeAll("}\n");
}

fn writeTokenConflictComparisonKey(
    writer: anytype,
    indent: usize,
    name: []const u8,
    hash: u64,
    trailing_comma: bool,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{ \"name\": ");
    try writeJsonString(writer, name);
    try writer.writeAll(", \"local_hash\": \"");
    try writer.print("0x{x:0>16}", .{hash});
    try writer.writeByte('"');
    try writer.writeAll(", \"upstream_hash\": null, \"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(" }");
    if (trailing_comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

const TokenConflictCounts = struct {
    conflict_pairs: usize = 0,
    matches_prefix: usize = 0,
    does_match_continuation: usize = 0,
    does_match_valid_continuation: usize = 0,
    does_match_separators: usize = 0,
    matches_same_string: usize = 0,
    matches_different_string: usize = 0,
    starting_overlap: usize = 0,
};

fn tokenConflictCounts(conflict_map: lexer_model.TokenConflictMap) TokenConflictCounts {
    var counts = TokenConflictCounts{};
    for (0..conflict_map.variable_count) |left| {
        for (0..conflict_map.variable_count) |right| {
            if (left == right) continue;
            const status = conflict_map.status(left, right);
            if (tokenConflictStatusIsConcretePair(status)) counts.conflict_pairs += 1;
            if (status.matches_prefix) counts.matches_prefix += 1;
            if (status.does_match_continuation) counts.does_match_continuation += 1;
            if (status.does_match_valid_continuation) counts.does_match_valid_continuation += 1;
            if (status.does_match_separators) counts.does_match_separators += 1;
            if (status.matches_same_string) counts.matches_same_string += 1;
            if (status.matches_different_string) counts.matches_different_string += 1;
            if (status.starting_overlap) counts.starting_overlap += 1;
        }
    }
    return counts;
}

fn hashTokenConflictCounts(counts: TokenConflictCounts) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashUsize(&hasher, counts.conflict_pairs);
    hashUsize(&hasher, counts.matches_prefix);
    hashUsize(&hasher, counts.does_match_continuation);
    hashUsize(&hasher, counts.does_match_valid_continuation);
    hashUsize(&hasher, counts.does_match_separators);
    hashUsize(&hasher, counts.matches_same_string);
    hashUsize(&hasher, counts.matches_different_string);
    hashUsize(&hasher, counts.starting_overlap);
    return hasher.final();
}

fn hashTokenConflictVariables(grammar: lexer_model.ExpandedLexicalGrammar) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashUsize(&hasher, grammar.variables.len);
    for (grammar.variables) |variable| {
        hashString(&hasher, variable.name);
        hashString(&hasher, lexicalVariableKindName(variable.kind));
        hashI32(&hasher, variable.completion_precedence);
        hashI32(&hasher, variable.implicit_precedence);
        hashU32(&hasher, variable.start_state);
        hashU32(&hasher, variable.source_rule);
    }
    return hasher.final();
}

fn hashTokenConflictCharacterSets(sets: []const lexer_model.CharacterSet) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashUsize(&hasher, sets.len);
    for (sets) |set| {
        hashUsize(&hasher, set.ranges.items.len);
        for (set.ranges.items) |range| {
            hashU32(&hasher, range.start);
            hashU32(&hasher, range.end);
        }
    }
    return hasher.final();
}

fn hashTokenConflictFollowingTokens(sets: []const lexer_model.TokenIndexSet) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashUsize(&hasher, sets.len);
    for (sets) |set| {
        hashUsize(&hasher, set.values.len);
        for (set.values) |present| hashBool(&hasher, present);
    }
    return hasher.final();
}

fn hashTokenConflictStatusMatrix(conflict_map: lexer_model.TokenConflictMap) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashUsize(&hasher, conflict_map.variable_count);
    for (0..conflict_map.variable_count) |left| {
        for (0..conflict_map.variable_count) |right| {
            if (left == right) continue;
            hashTokenConflictStatus(&hasher, conflict_map.status(left, right));
        }
    }
    return hasher.final();
}

fn hashTokenConflictConcretePairs(
    grammar: lexer_model.ExpandedLexicalGrammar,
    conflict_map: lexer_model.TokenConflictMap,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashUsize(&hasher, conflict_map.variable_count);
    for (0..conflict_map.variable_count) |left| {
        for (0..conflict_map.variable_count) |right| {
            if (left == right) continue;
            const status = conflict_map.status(left, right);
            if (!tokenConflictStatusIsConcretePair(status)) continue;
            hashUsize(&hasher, left);
            hashString(&hasher, grammar.variables[left].name);
            hashUsize(&hasher, right);
            hashString(&hasher, grammar.variables[right].name);
            hashTokenConflictStatus(&hasher, status);
        }
    }
    return hasher.final();
}

fn hashTokenConflictStatus(hasher: *std.hash.Wyhash, status: lexer_model.TokenConflictStatus) void {
    hashBool(hasher, status.matches_prefix);
    hashBool(hasher, status.does_match_continuation);
    hashBool(hasher, status.does_match_valid_continuation);
    hashBool(hasher, status.does_match_separators);
    hashBool(hasher, status.matches_same_string);
    hashBool(hasher, status.matches_different_string);
    hashBool(hasher, status.starting_overlap);
}

fn writeTokenConflictPairJson(
    writer: anytype,
    grammar: lexer_model.ExpandedLexicalGrammar,
    left: usize,
    right: usize,
    status: lexer_model.TokenConflictStatus,
) !void {
    try writeIndent(writer, 4);
    try writer.writeAll("{ \"left\": ");
    try writer.print("{d}", .{left});
    try writer.writeAll(", \"left_name\": ");
    try writeJsonString(writer, grammar.variables[left].name);
    try writer.writeAll(", \"right\": ");
    try writer.print("{d}", .{right});
    try writer.writeAll(", \"right_name\": ");
    try writeJsonString(writer, grammar.variables[right].name);
    try writer.writeAll(", \"matches_prefix\": ");
    try writeBoolJson(writer, status.matches_prefix);
    try writer.writeAll(", \"does_match_continuation\": ");
    try writeBoolJson(writer, status.does_match_continuation);
    try writer.writeAll(", \"does_match_valid_continuation\": ");
    try writeBoolJson(writer, status.does_match_valid_continuation);
    try writer.writeAll(", \"does_match_separators\": ");
    try writeBoolJson(writer, status.does_match_separators);
    try writer.writeAll(", \"matches_same_string\": ");
    try writeBoolJson(writer, status.matches_same_string);
    try writer.writeAll(", \"matches_different_string\": ");
    try writeBoolJson(writer, status.matches_different_string);
    try writer.writeAll(", \"starting_overlap\": ");
    try writeBoolJson(writer, status.starting_overlap);
    try writer.writeAll(" }");
}

fn writeBoolJson(writer: anytype, value: bool) !void {
    try writer.writeAll(if (value) "true" else "false");
}

fn tokenConflictStatusIsConcretePair(status: lexer_model.TokenConflictStatus) bool {
    return status.matches_prefix or
        status.does_match_continuation or
        status.does_match_valid_continuation or
        status.does_match_separators or
        status.matches_same_string;
}

fn countTokenIndexSet(set: lexer_model.TokenIndexSet) usize {
    var count: usize = 0;
    for (set.values) |present| {
        if (present) count += 1;
    }
    return count;
}

fn directionalPairCount(variable_count: usize) usize {
    if (variable_count == 0) return 0;
    return variable_count * (variable_count - 1);
}

fn writeMinimizationSummaryJson(
    writer: anytype,
    default_serialized: parse_table_serialize.SerializedTable,
    minimized_serialized: parse_table_serialize.SerializedTable,
) !void {
    try writer.writeAll("{\n");
    try writer.writeAll("  \"default\": {\n");
    try writeSerializedTableCountFields(writer, default_serialized);
    try writer.writeAll("  },\n");
    try writer.writeAll("  \"minimized\": {\n");
    try writeSerializedTableCountFields(writer, minimized_serialized);
    try writer.writeAll("  },\n");
    try writeUsizeField(writer, 2, "merged_state_count", default_serialized.states.len -| minimized_serialized.states.len, true);
    try writeUsizeField(writer, 2, "removed_action_entry_count", countSerializedActionEntries(default_serialized.states) -| countSerializedActionEntries(minimized_serialized.states), true);
    try writeUsizeField(writer, 2, "removed_goto_entry_count", countSerializedGotoEntries(default_serialized.states) -| countSerializedGotoEntries(minimized_serialized.states), true);
    try writer.writeAll("  \"diff\": {\n");
    try writeBoolField(writer, 4, "state_count_changed", default_serialized.states.len != minimized_serialized.states.len, true);
    try writeBoolField(writer, 4, "large_state_count_changed", default_serialized.large_state_count != minimized_serialized.large_state_count, true);
    try writeBoolField(writer, 4, "parse_action_list_changed", default_serialized.parse_action_list.len != minimized_serialized.parse_action_list.len, true);
    try writeBoolField(writer, 4, "small_parse_rows_changed", default_serialized.small_parse_table.rows.len != minimized_serialized.small_parse_table.rows.len, true);
    try writeBoolField(writer, 4, "lex_mode_changed", hashSerializedLexModes(default_serialized.lex_modes) != hashSerializedLexModes(minimized_serialized.lex_modes), true);
    try writeBoolField(writer, 4, "primary_state_id_changed", hashPrimaryStateIds(default_serialized.primary_state_ids) != hashPrimaryStateIds(minimized_serialized.primary_state_ids), true);
    try writeBoolField(writer, 4, "production_metadata_changed", hashSerializedProductions(default_serialized.productions) != hashSerializedProductions(minimized_serialized.productions), false);
    try writer.writeAll("  },\n");
    try writeMinimizationComparisonKeysJson(writer, default_serialized, minimized_serialized, 2);
    try writer.writeAll("}\n");
}

fn writeMinimizationComparisonKeysJson(
    writer: anytype,
    default_serialized: parse_table_serialize.SerializedTable,
    minimized_serialized: parse_table_serialize.SerializedTable,
    indent: usize,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("\"comparison_keys\": {\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"note\": ");
    try writeJsonString(writer, "local minimization comparison keys are stable; tree-sitter does not expose an equivalent bounded minimization artifact through the parser.c snapshot");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"keys\": [\n");
    try writeMinimizationComparisonKey(writer, indent + 4, "table_counts", hashMinimizationPair(hashSerializedTableCounts(default_serialized), hashSerializedTableCounts(minimized_serialized)), true);
    try writeMinimizationComparisonKey(writer, indent + 4, "lex_modes", hashMinimizationPair(hashSerializedLexModes(default_serialized.lex_modes), hashSerializedLexModes(minimized_serialized.lex_modes)), true);
    try writeMinimizationComparisonKey(writer, indent + 4, "primary_state_ids", hashMinimizationPair(hashPrimaryStateIds(default_serialized.primary_state_ids), hashPrimaryStateIds(minimized_serialized.primary_state_ids)), true);
    try writeMinimizationComparisonKey(writer, indent + 4, "production_metadata", hashMinimizationPair(hashSerializedProductions(default_serialized.productions), hashSerializedProductions(minimized_serialized.productions)), false);
    try writeIndent(writer, indent + 2);
    try writer.writeAll("]\n");
    try writeIndent(writer, indent);
    try writer.writeAll("}\n");
}

fn writeMinimizationComparisonKey(
    writer: anytype,
    indent: usize,
    name: []const u8,
    hash: u64,
    trailing_comma: bool,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{ \"name\": ");
    try writeJsonString(writer, name);
    try writer.writeAll(", \"local_hash\": \"");
    try writer.print("0x{x:0>16}", .{hash});
    try writer.writeByte('"');
    try writer.writeAll(", \"upstream_hash\": null, \"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(" }");
    if (trailing_comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn hashMinimizationPair(default_hash: u64, minimized_hash: u64) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashU64(&hasher, default_hash);
    hashU64(&hasher, minimized_hash);
    return hasher.final();
}

fn hashSerializedTableCounts(serialized: parse_table_serialize.SerializedTable) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashUsize(&hasher, serialized.states.len);
    hashUsize(&hasher, serialized.large_state_count);
    hashUsize(&hasher, serialized.small_parse_table.rows.len);
    hashUsize(&hasher, serialized.parse_action_list.len);
    hashUsize(&hasher, countSerializedActionEntries(serialized.states));
    hashUsize(&hasher, countSerializedGotoEntries(serialized.states));
    hashUsize(&hasher, countSerializedUnresolvedEntries(serialized.states));
    return hasher.final();
}

fn writeSerializedTableCountFields(
    writer: anytype,
    serialized: parse_table_serialize.SerializedTable,
) !void {
    try writeUsizeField(writer, 4, "state_count", serialized.states.len, true);
    try writeUsizeField(writer, 4, "large_state_count", serialized.large_state_count, true);
    try writeUsizeField(writer, 4, "small_parse_row_count", serialized.small_parse_table.rows.len, true);
    try writeUsizeField(writer, 4, "parse_action_list_count", serialized.parse_action_list.len, true);
    try writeUsizeField(writer, 4, "action_entry_count", countSerializedActionEntries(serialized.states), true);
    try writeUsizeField(writer, 4, "goto_entry_count", countSerializedGotoEntries(serialized.states), true);
    try writeUsizeField(writer, 4, "unresolved_entry_count", countSerializedUnresolvedEntries(serialized.states), true);
    try writeU64HexField(writer, 4, "lex_mode_hash", hashSerializedLexModes(serialized.lex_modes), true);
    try writeU64HexField(writer, 4, "primary_state_id_hash", hashPrimaryStateIds(serialized.primary_state_ids), true);
    try writeU64HexField(writer, 4, "production_metadata_hash", hashSerializedProductions(serialized.productions), false);
}

fn hashSerializedLexModes(modes: []const @import("../lexer/serialize.zig").SerializedLexMode) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (modes) |mode| {
        hashU32(&hasher, @intCast(mode.lex_state));
        hashU32(&hasher, @intCast(mode.external_lex_state));
        hashU32(&hasher, @intCast(mode.reserved_word_set_id));
    }
    return hasher.final();
}

fn hashPrimaryStateIds(ids: []const @import("../parse_table/state.zig").StateId) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (ids) |id| hashU32(&hasher, id);
    return hasher.final();
}

fn hashSerializedProductions(productions: []const parse_table_serialize.SerializedProductionInfo) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (productions) |production| {
        hashU32(&hasher, production.lhs);
        hashU32(&hasher, @intCast(production.child_count));
        var dynamic_buffer: [@sizeOf(i16)]u8 = undefined;
        std.mem.writeInt(i16, &dynamic_buffer, production.dynamic_precedence, .little);
        hasher.update(&dynamic_buffer);
    }
    return hasher.final();
}

fn countSerializedActionEntries(states: []const parse_table_serialize.SerializedState) usize {
    var count: usize = 0;
    for (states) |serialized_state| count += serialized_state.actions.len;
    return count;
}

fn countSerializedGotoEntries(states: []const parse_table_serialize.SerializedState) usize {
    var count: usize = 0;
    for (states) |serialized_state| count += serialized_state.gotos.len;
    return count;
}

fn countSerializedUnresolvedEntries(states: []const parse_table_serialize.SerializedState) usize {
    var count: usize = 0;
    for (states) |serialized_state| count += serialized_state.unresolved.len;
    return count;
}

const RegexPatternRef = struct {
    rule_id: ir_rules.RuleId,
    value: []const u8,
    flags: ?[]const u8,
};

const RegexSurfaceCounts = struct {
    pattern_variable_count: usize = 0,
    pattern_count: usize = 0,
    flagged_pattern_count: usize = 0,
    class_count: usize = 0,
    negated_class_count: usize = 0,
    class_range_count: usize = 0,
    escape_count: usize = 0,
    shorthand_escape_count: usize = 0,
    hex_escape_count: usize = 0,
    unicode_escape_count: usize = 0,
    control_escape_count: usize = 0,
    unicode_property_count: usize = 0,
    unsupported_unicode_property_count: usize = 0,
    unsupported_flag_count: usize = 0,
    bounded_repeat_count: usize = 0,
    zero_or_more_count: usize = 0,
    one_or_more_count: usize = 0,
    optional_count: usize = 0,
    group_count: usize = 0,
    alternation_count: usize = 0,
    anchor_count: usize = 0,
    dot_count: usize = 0,
    group_prefix_count: usize = 0,
    backreference_count: usize = 0,
    lazy_quantifier_count: usize = 0,
    unsupported_pattern_count: usize = 0,
};

fn writeRegexSurfaceSummaryJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    all_rules: []const ir_rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
) !void {
    var variable_patterns = try allocator.alloc([]const RegexPatternRef, lexical.variables.len);
    var counts = RegexSurfaceCounts{};
    for (lexical.variables, 0..) |variable, index| {
        variable_patterns[index] = try collectPatternRefsForRuleAlloc(allocator, all_rules, variable.rule);
        if (variable_patterns[index].len != 0) counts.pattern_variable_count += 1;
        for (variable_patterns[index]) |pattern| {
            counts.pattern_count += 1;
            if (pattern.flags != null) counts.flagged_pattern_count += 1;
            const features = regexFeatureSummary(pattern.value, pattern.flags);
            if (features.has_class) counts.class_count += 1;
            if (features.has_negated_class) counts.negated_class_count += 1;
            if (features.has_class_range) counts.class_range_count += 1;
            if (features.has_escape) counts.escape_count += 1;
            if (features.has_shorthand_escape) counts.shorthand_escape_count += 1;
            if (features.has_hex_escape) counts.hex_escape_count += 1;
            if (features.has_unicode_escape) counts.unicode_escape_count += 1;
            if (features.has_control_escape) counts.control_escape_count += 1;
            if (features.has_unicode_property) counts.unicode_property_count += 1;
            if (features.has_unsupported_unicode_property) counts.unsupported_unicode_property_count += 1;
            if (features.has_unsupported_flag) counts.unsupported_flag_count += 1;
            if (features.has_bounded_repeat) counts.bounded_repeat_count += 1;
            if (features.has_zero_or_more) counts.zero_or_more_count += 1;
            if (features.has_one_or_more) counts.one_or_more_count += 1;
            if (features.has_optional) counts.optional_count += 1;
            if (features.has_group) counts.group_count += 1;
            if (features.has_alternation) counts.alternation_count += 1;
            if (features.has_anchor) counts.anchor_count += 1;
            if (features.has_dot) counts.dot_count += 1;
            if (features.has_group_prefix) counts.group_prefix_count += 1;
            if (features.has_backreference) counts.backreference_count += 1;
            if (features.has_lazy_quantifier) counts.lazy_quantifier_count += 1;
            if (regexFeaturesUnsupported(features)) counts.unsupported_pattern_count += 1;
        }
    }

    try writer.writeAll("{\n");
    try writeUsizeField(writer, 2, "lexical_variable_count", lexical.variables.len, true);
    try writeUsizeField(writer, 2, "pattern_variable_count", counts.pattern_variable_count, true);
    try writeUsizeField(writer, 2, "pattern_count", counts.pattern_count, true);
    try writer.writeAll("  \"feature_counts\": {\n");
    try writeUsizeField(writer, 4, "flagged", counts.flagged_pattern_count, true);
    try writeUsizeField(writer, 4, "class", counts.class_count, true);
    try writeUsizeField(writer, 4, "negated_class", counts.negated_class_count, true);
    try writeUsizeField(writer, 4, "class_range", counts.class_range_count, true);
    try writeUsizeField(writer, 4, "escape", counts.escape_count, true);
    try writeUsizeField(writer, 4, "shorthand_escape", counts.shorthand_escape_count, true);
    try writeUsizeField(writer, 4, "hex_escape", counts.hex_escape_count, true);
    try writeUsizeField(writer, 4, "unicode_escape", counts.unicode_escape_count, true);
    try writeUsizeField(writer, 4, "control_escape", counts.control_escape_count, true);
    try writeUsizeField(writer, 4, "unicode_property", counts.unicode_property_count, true);
    try writeUsizeField(writer, 4, "unsupported_unicode_property", counts.unsupported_unicode_property_count, true);
    try writeUsizeField(writer, 4, "unsupported_flag", counts.unsupported_flag_count, true);
    try writeUsizeField(writer, 4, "bounded_repeat", counts.bounded_repeat_count, true);
    try writeUsizeField(writer, 4, "zero_or_more", counts.zero_or_more_count, true);
    try writeUsizeField(writer, 4, "one_or_more", counts.one_or_more_count, true);
    try writeUsizeField(writer, 4, "optional", counts.optional_count, true);
    try writeUsizeField(writer, 4, "group", counts.group_count, true);
    try writeUsizeField(writer, 4, "alternation", counts.alternation_count, true);
    try writeUsizeField(writer, 4, "anchor", counts.anchor_count, true);
    try writeUsizeField(writer, 4, "dot", counts.dot_count, true);
    try writeUsizeField(writer, 4, "group_prefix", counts.group_prefix_count, true);
    try writeUsizeField(writer, 4, "backreference", counts.backreference_count, true);
    try writeUsizeField(writer, 4, "lazy_quantifier", counts.lazy_quantifier_count, true);
    try writeUsizeField(writer, 4, "unsupported_pattern", counts.unsupported_pattern_count, false);
    try writer.writeAll("  },\n");
    try writer.writeAll("  \"variables\": [\n");
    var wrote_variable = false;
    for (lexical.variables, 0..) |variable, index| {
        if (variable_patterns[index].len == 0) continue;
        if (wrote_variable) try writer.writeAll(",\n");
        wrote_variable = true;
        try writeRegexVariableSurfaceJson(writer, variable, variable_patterns[index]);
    }
    if (wrote_variable) try writer.writeByte('\n');
    try writer.writeAll("  ]\n");
    try writer.writeAll("}\n");
}

fn writeRegexVariableSurfaceJson(
    writer: anytype,
    variable: lexical_ir.LexicalVariable,
    patterns: []const RegexPatternRef,
) !void {
    try writer.writeAll("    { \"name\": ");
    try writeJsonString(writer, variable.name);
    try writer.writeAll(", \"kind\": ");
    try writeJsonString(writer, lexicalVariableKindName(variable.kind));
    try writer.writeAll(", \"source_kind\": ");
    try writeJsonString(writer, lexicalSourceKindName(variable.source_kind));
    try writer.writeAll(", \"implicit_precedence\": ");
    try writer.print("{d}", .{variable.implicit_precedence});
    try writer.writeAll(", \"start_state\": ");
    try writer.print("{d}", .{variable.start_state});
    try writer.writeAll(", \"pattern_count\": ");
    try writer.print("{d}", .{patterns.len});
    try writer.writeAll(", \"patterns\": [");
    for (patterns, 0..) |pattern, index| {
        if (index != 0) try writer.writeAll(", ");
        const features = regexFeatureSummary(pattern.value, pattern.flags);
        try writer.writeAll("{ \"rule_id\": ");
        try writer.print("{d}", .{pattern.rule_id});
        try writer.writeAll(", \"value\": ");
        try writeJsonString(writer, pattern.value);
        try writer.writeAll(", \"flags\": ");
        if (pattern.flags) |flags|
            try writeJsonString(writer, flags)
        else
            try writer.writeAll("null");
        try writer.writeAll(", \"status\": ");
        try writeJsonString(writer, if (regexFeaturesUnsupported(features)) "unsupported" else "supported_subset");
        try writer.writeAll(", \"unsupported_features\": ");
        try writeRegexUnsupportedFeaturesJson(writer, features);
        try writer.writeAll(", \"features\": ");
        try writeRegexFeaturesJson(writer, features);
        try writer.writeAll(" }");
    }
    try writer.writeAll("] }");
}

fn collectPatternRefsForRuleAlloc(
    allocator: std.mem.Allocator,
    all_rules: []const ir_rules.Rule,
    root_rule: ir_rules.RuleId,
) ![]const RegexPatternRef {
    var refs = std.array_list.Managed(RegexPatternRef).init(allocator);
    const visited = try allocator.alloc(bool, all_rules.len);
    @memset(visited, false);
    try collectPatternRefsForRule(allocator, all_rules, root_rule, visited, &refs);
    return try refs.toOwnedSlice();
}

fn collectPatternRefsForRule(
    allocator: std.mem.Allocator,
    all_rules: []const ir_rules.Rule,
    rule_id: ir_rules.RuleId,
    visited: []bool,
    refs: *std.array_list.Managed(RegexPatternRef),
) !void {
    if (rule_id >= all_rules.len) return;
    if (visited[rule_id]) return;
    visited[rule_id] = true;

    switch (all_rules[rule_id]) {
        .pattern => |pattern| try refs.append(.{
            .rule_id = rule_id,
            .value = pattern.value,
            .flags = pattern.flags,
        }),
        .choice, .seq => |children| {
            for (children) |child| try collectPatternRefsForRule(allocator, all_rules, child, visited, refs);
        },
        .repeat, .repeat1 => |child| try collectPatternRefsForRule(allocator, all_rules, child, visited, refs),
        .metadata => |metadata| try collectPatternRefsForRule(allocator, all_rules, metadata.inner, visited, refs),
        .blank, .symbol, .string => {},
    }
}

const RegexFeatureSummary = struct {
    has_class: bool = false,
    has_negated_class: bool = false,
    has_class_range: bool = false,
    has_escape: bool = false,
    has_shorthand_escape: bool = false,
    has_hex_escape: bool = false,
    has_unicode_escape: bool = false,
    has_control_escape: bool = false,
    has_unicode_property: bool = false,
    has_unsupported_unicode_property: bool = false,
    has_unsupported_flag: bool = false,
    has_bounded_repeat: bool = false,
    has_zero_or_more: bool = false,
    has_one_or_more: bool = false,
    has_optional: bool = false,
    has_group: bool = false,
    has_alternation: bool = false,
    has_anchor: bool = false,
    has_dot: bool = false,
    has_group_prefix: bool = false,
    has_unsupported_group_prefix: bool = false,
    has_backreference: bool = false,
    has_lazy_quantifier: bool = false,
};

fn regexFeatureSummary(value: []const u8, flags: ?[]const u8) RegexFeatureSummary {
    var result = RegexFeatureSummary{
        .has_unsupported_flag = regexFlagsUnsupported(flags),
    };
    var escaped = false;
    var in_class = false;
    var class_content_index: usize = 0;
    for (value, 0..) |ch, index| {
        if (escaped) {
            result.has_escape = true;
            switch (ch) {
                'd', 'D', 's', 'S', 'w', 'W' => result.has_shorthand_escape = true,
                'x' => result.has_hex_escape = true,
                'u' => result.has_unicode_escape = true,
                'c' => result.has_control_escape = true,
                'p', 'P' => {
                    result.has_unicode_property = true;
                    if (regexUnicodePropertyNameAt(value, index + 1)) |property_name| {
                        if (!regexUnicodePropertySupported(property_name)) {
                            result.has_unsupported_unicode_property = true;
                        }
                    } else {
                        result.has_unsupported_unicode_property = true;
                    }
                },
                else => {},
            }
            if (ch >= '1' and ch <= '9') result.has_backreference = true;
            escaped = false;
            if (in_class) class_content_index += 1;
            continue;
        }
        switch (ch) {
            '\\' => escaped = true,
            '[' => {
                result.has_class = true;
                in_class = true;
                class_content_index = 0;
            },
            ']' => in_class = false,
            '{' => result.has_bounded_repeat = true,
            '(' => {
                if (!in_class) result.has_group = true;
                if (!in_class and index + 1 < value.len and value[index + 1] == '?') {
                    result.has_group_prefix = true;
                    if (index + 2 >= value.len or value[index + 2] != ':') {
                        result.has_unsupported_group_prefix = true;
                    }
                }
            },
            '|' => {
                if (!in_class) result.has_alternation = true;
            },
            '^', '$' => {
                if (!in_class) result.has_anchor = true;
            },
            '.' => {
                if (!in_class) result.has_dot = true;
            },
            '*' => {
                if (!in_class) result.has_zero_or_more = true;
            },
            '+' => {
                if (!in_class) result.has_one_or_more = true;
            },
            '?' => {
                if (!in_class) {
                    const quantifier_suffix = index > 0 and switch (value[index - 1]) {
                        '*', '+', '?', '}' => true,
                        else => false,
                    };
                    if (!quantifier_suffix) result.has_optional = true;
                }
            },
            '-' => {
                if (in_class and class_content_index > 0 and index + 1 < value.len and value[index + 1] != ']') {
                    result.has_class_range = true;
                }
            },
            else => {},
        }
        if (in_class and ch == '^' and class_content_index == 0) {
            result.has_negated_class = true;
        }
        if (in_class and ch != '[') class_content_index += 1;
        if (!in_class and ch == '?' and index > 0) {
            const previous = value[index - 1];
            if (previous == '*' or previous == '+' or previous == '?' or previous == '}') {
                result.has_lazy_quantifier = true;
            }
        }
    }
    if (escaped) result.has_escape = true;
    return result;
}

fn regexFeaturesUnsupported(features: RegexFeatureSummary) bool {
    return features.has_anchor or
        features.has_unsupported_group_prefix or
        features.has_backreference or
        features.has_control_escape or
        features.has_unsupported_unicode_property or
        features.has_unsupported_flag;
}

fn regexFlagsUnsupported(flags: ?[]const u8) bool {
    const value = flags orelse return false;
    for (value) |flag| {
        switch (flag) {
            'i', 's' => {},
            else => return true,
        }
    }
    return false;
}

fn regexUnicodePropertyNameAt(value: []const u8, start_index: usize) ?[]const u8 {
    if (start_index >= value.len) return null;
    if (value[start_index] == '{') {
        const property_start = start_index + 1;
        var cursor = property_start;
        while (cursor < value.len and value[cursor] != '}') : (cursor += 1) {}
        if (cursor >= value.len or cursor == property_start) return null;
        return value[property_start..cursor];
    }

    var cursor = start_index;
    while (cursor < value.len and std.ascii.isAlphabetic(value[cursor])) : (cursor += 1) {}
    if (cursor == start_index) return null;
    return value[start_index..cursor];
}

fn regexUnicodePropertySupported(property_name: []const u8) bool {
    const supported = [_][]const u8{
        "Zs",
        "Ll",
        "Lo",
        "Lu",
        "Lt",
        "L",
        "XID_Start",
        "XID_Continue",
        "Mn",
        "N",
    };
    for (supported) |candidate| {
        if (std.mem.eql(u8, property_name, candidate)) return true;
    }
    return false;
}

fn writeRegexUnsupportedFeaturesJson(writer: anytype, features: RegexFeatureSummary) !void {
    try writer.writeByte('[');
    var wrote = false;
    if (features.has_anchor) {
        try writeMaybeComma(writer, &wrote);
        try writeJsonString(writer, "anchor");
    }
    if (features.has_unsupported_group_prefix) {
        try writeMaybeComma(writer, &wrote);
        try writeJsonString(writer, "group_prefix");
    }
    if (features.has_backreference) {
        try writeMaybeComma(writer, &wrote);
        try writeJsonString(writer, "backreference");
    }
    if (features.has_control_escape) {
        try writeMaybeComma(writer, &wrote);
        try writeJsonString(writer, "control_escape");
    }
    if (features.has_unsupported_unicode_property) {
        try writeMaybeComma(writer, &wrote);
        try writeJsonString(writer, "unsupported_unicode_property");
    }
    if (features.has_unsupported_flag) {
        try writeMaybeComma(writer, &wrote);
        try writeJsonString(writer, "unsupported_flag");
    }
    try writer.writeByte(']');
}

fn writeMaybeComma(writer: anytype, wrote: *bool) !void {
    if (wrote.*) try writer.writeAll(", ");
    wrote.* = true;
}

fn writeRegexFeaturesJson(writer: anytype, features: RegexFeatureSummary) !void {
    try writer.writeAll("{ \"class\": ");
    try writeBoolJson(writer, features.has_class);
    try writer.writeAll(", \"negated_class\": ");
    try writeBoolJson(writer, features.has_negated_class);
    try writer.writeAll(", \"class_range\": ");
    try writeBoolJson(writer, features.has_class_range);
    try writer.writeAll(", \"escape\": ");
    try writeBoolJson(writer, features.has_escape);
    try writer.writeAll(", \"shorthand_escape\": ");
    try writeBoolJson(writer, features.has_shorthand_escape);
    try writer.writeAll(", \"hex_escape\": ");
    try writeBoolJson(writer, features.has_hex_escape);
    try writer.writeAll(", \"unicode_escape\": ");
    try writeBoolJson(writer, features.has_unicode_escape);
    try writer.writeAll(", \"control_escape\": ");
    try writeBoolJson(writer, features.has_control_escape);
    try writer.writeAll(", \"unicode_property\": ");
    try writeBoolJson(writer, features.has_unicode_property);
    try writer.writeAll(", \"unsupported_unicode_property\": ");
    try writeBoolJson(writer, features.has_unsupported_unicode_property);
    try writer.writeAll(", \"unsupported_flag\": ");
    try writeBoolJson(writer, features.has_unsupported_flag);
    try writer.writeAll(", \"bounded_repeat\": ");
    try writeBoolJson(writer, features.has_bounded_repeat);
    try writer.writeAll(", \"zero_or_more\": ");
    try writeBoolJson(writer, features.has_zero_or_more);
    try writer.writeAll(", \"one_or_more\": ");
    try writeBoolJson(writer, features.has_one_or_more);
    try writer.writeAll(", \"optional\": ");
    try writeBoolJson(writer, features.has_optional);
    try writer.writeAll(", \"group\": ");
    try writeBoolJson(writer, features.has_group);
    try writer.writeAll(", \"alternation\": ");
    try writeBoolJson(writer, features.has_alternation);
    try writer.writeAll(", \"anchor\": ");
    try writeBoolJson(writer, features.has_anchor);
    try writer.writeAll(", \"dot\": ");
    try writeBoolJson(writer, features.has_dot);
    try writer.writeAll(", \"group_prefix\": ");
    try writeBoolJson(writer, features.has_group_prefix);
    try writer.writeAll(", \"unsupported_group_prefix\": ");
    try writeBoolJson(writer, features.has_unsupported_group_prefix);
    try writer.writeAll(", \"backreference\": ");
    try writeBoolJson(writer, features.has_backreference);
    try writer.writeAll(", \"lazy_quantifier\": ");
    try writeBoolJson(writer, features.has_lazy_quantifier);
    try writer.writeAll(" }");
}

fn lexicalVariableKindName(kind: lexical_ir.VariableKind) []const u8 {
    return switch (kind) {
        .named => "named",
        .hidden => "hidden",
        .anonymous => "anonymous",
        .auxiliary => "auxiliary",
    };
}

fn lexicalSourceKindName(kind: lexical_ir.SourceKind) []const u8 {
    return switch (kind) {
        .string => "string",
        .pattern => "pattern",
        .composite => "composite",
        .token => "token",
    };
}

const LexTableCounts = struct {
    table_count: usize = 0,
    state_count: usize = 0,
    transition_count: usize = 0,
    range_count: usize = 0,
    accept_state_count: usize = 0,
    eof_target_count: usize = 0,
    skip_transition_count: usize = 0,
    large_range_transition_count: usize = 0,
    max_transition_range_count: usize = 0,
    accept_symbol_hash: u64 = 0,
    eof_target_hash: u64 = 0,
    transition_target_hash: u64 = 0,
    skip_transition_hash: u64 = 0,
    large_range_transition_hash: u64 = 0,
    range_hash: u64 = 0,
};

fn writeLexTableSummaryJson(
    writer: anytype,
    serialized: parse_table_serialize.SerializedTable,
) !void {
    const counts = countLexTables(serialized.lex_tables);
    try writer.writeAll("{\n");
    try writeUsizeField(writer, 2, "table_count", counts.table_count, true);
    try writeUsizeField(writer, 2, "state_count", counts.state_count, true);
    try writeUsizeField(writer, 2, "transition_count", counts.transition_count, true);
    try writeUsizeField(writer, 2, "range_count", counts.range_count, true);
    try writeUsizeField(writer, 2, "accept_state_count", counts.accept_state_count, true);
    try writeUsizeField(writer, 2, "eof_target_count", counts.eof_target_count, true);
    try writeUsizeField(writer, 2, "skip_transition_count", counts.skip_transition_count, true);
    try writeUsizeField(writer, 2, "large_range_transition_count", counts.large_range_transition_count, true);
    try writeUsizeField(writer, 2, "max_transition_range_count", counts.max_transition_range_count, true);
    try writeU64HexField(writer, 2, "accept_symbol_hash", counts.accept_symbol_hash, true);
    try writeU64HexField(writer, 2, "eof_target_hash", counts.eof_target_hash, true);
    try writeU64HexField(writer, 2, "transition_target_hash", counts.transition_target_hash, true);
    try writeU64HexField(writer, 2, "skip_transition_hash", counts.skip_transition_hash, true);
    try writeU64HexField(writer, 2, "large_range_transition_hash", counts.large_range_transition_hash, true);
    try writeU64HexField(writer, 2, "range_hash", counts.range_hash, true);
    try writeUsizeField(writer, 2, "keyword_unmapped_reserved_word_count", serialized.keyword_unmapped_reserved_word_count, true);
    try writer.writeAll("  \"keyword_table\": ");
    const keyword_counts = if (serialized.keyword_lex_table) |keyword_table| countLexTable(keyword_table) else null;
    if (serialized.keyword_lex_table) |keyword_table| {
        try writeLexTableCountsObject(writer, keyword_counts.?, keyword_table.states);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\n");
    try writeLexComparisonKeysJson(writer, counts, keyword_counts, 2);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"tables\": [\n");
    for (serialized.lex_tables, 0..) |table, index| {
        const table_counts = countLexTable(table);
        try writeIndent(writer, 4);
        try writer.writeAll("{ \"index\": ");
        try writer.print("{d}", .{index});
        try writer.writeAll(", \"start_state_id\": ");
        try writer.print("{d}", .{table.start_state_id});
        try writer.writeAll(", \"state_count\": ");
        try writer.print("{d}", .{table_counts.state_count});
        try writer.writeAll(", \"transition_count\": ");
        try writer.print("{d}", .{table_counts.transition_count});
        try writer.writeAll(", \"range_count\": ");
        try writer.print("{d}", .{table_counts.range_count});
        try writer.writeAll(", \"accept_state_count\": ");
        try writer.print("{d}", .{table_counts.accept_state_count});
        try writer.writeAll(", \"accepts\": ");
        try writeLexAcceptsJson(writer, table.states);
        try writer.writeAll(", \"eof_target_count\": ");
        try writer.print("{d}", .{table_counts.eof_target_count});
        try writer.writeAll(", \"skip_transition_count\": ");
        try writer.print("{d}", .{table_counts.skip_transition_count});
        try writer.writeAll(", \"large_range_transition_count\": ");
        try writer.print("{d}", .{table_counts.large_range_transition_count});
        try writer.writeAll(", \"max_transition_range_count\": ");
        try writer.print("{d}", .{table_counts.max_transition_range_count});
        try writer.writeAll(", \"accept_symbol_hash\": ");
        try writeJsonHexU64(writer, table_counts.accept_symbol_hash);
        try writer.writeAll(", \"eof_target_hash\": ");
        try writeJsonHexU64(writer, table_counts.eof_target_hash);
        try writer.writeAll(", \"transition_target_hash\": ");
        try writeJsonHexU64(writer, table_counts.transition_target_hash);
        try writer.writeAll(", \"skip_transition_hash\": ");
        try writeJsonHexU64(writer, table_counts.skip_transition_hash);
        try writer.writeAll(", \"large_range_transition_hash\": ");
        try writeJsonHexU64(writer, table_counts.large_range_transition_hash);
        try writer.writeAll(", \"range_hash\": ");
        try writeJsonHexU64(writer, table_counts.range_hash);
        try writer.writeAll(" }");
        if (index + 1 != serialized.lex_tables.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.writeAll("  ]\n");
    try writer.writeAll("}\n");
}

fn writeLexComparisonKeysJson(
    writer: anytype,
    counts: LexTableCounts,
    keyword_counts: ?LexTableCounts,
    indent: usize,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("\"comparison_keys\": {\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"note\": ");
    try writeJsonString(writer, "local lex-table comparison keys are stable; tree-sitter parser.c summaries do not expose equivalent serialized lexer tables through the bounded snapshot");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"keys\": [\n");
    try writeLexComparisonKey(writer, indent + 4, "table_counts", hashLexTableCounts(counts), true);
    try writeLexComparisonKey(writer, indent + 4, "accept_symbols", counts.accept_symbol_hash, true);
    try writeLexComparisonKey(writer, indent + 4, "eof_targets", counts.eof_target_hash, true);
    try writeLexComparisonKey(writer, indent + 4, "transition_targets", counts.transition_target_hash, true);
    try writeLexComparisonKey(writer, indent + 4, "skip_transitions", counts.skip_transition_hash, true);
    try writeLexComparisonKey(writer, indent + 4, "large_range_transitions", counts.large_range_transition_hash, true);
    try writeLexComparisonKey(writer, indent + 4, "ranges", counts.range_hash, true);
    try writeLexComparisonKey(writer, indent + 4, "keyword_table", if (keyword_counts) |value| hashLexTableCounts(value) else 0, false);
    try writeIndent(writer, indent + 2);
    try writer.writeAll("]\n");
    try writeIndent(writer, indent);
    try writer.writeAll("}");
}

fn writeLexComparisonKey(
    writer: anytype,
    indent: usize,
    name: []const u8,
    hash: u64,
    trailing_comma: bool,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{ \"name\": ");
    try writeJsonString(writer, name);
    try writer.writeAll(", \"local_hash\": \"");
    try writer.print("0x{x:0>16}", .{hash});
    try writer.writeByte('"');
    try writer.writeAll(", \"upstream_hash\": null, \"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(" }");
    if (trailing_comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn hashLexTableCounts(counts: LexTableCounts) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashUsize(&hasher, counts.table_count);
    hashUsize(&hasher, counts.state_count);
    hashUsize(&hasher, counts.transition_count);
    hashUsize(&hasher, counts.range_count);
    hashUsize(&hasher, counts.accept_state_count);
    hashUsize(&hasher, counts.eof_target_count);
    hashUsize(&hasher, counts.skip_transition_count);
    hashUsize(&hasher, counts.large_range_transition_count);
    hashUsize(&hasher, counts.max_transition_range_count);
    hashU64(&hasher, counts.accept_symbol_hash);
    hashU64(&hasher, counts.eof_target_hash);
    hashU64(&hasher, counts.transition_target_hash);
    hashU64(&hasher, counts.skip_transition_hash);
    hashU64(&hasher, counts.large_range_transition_hash);
    hashU64(&hasher, counts.range_hash);
    return hasher.final();
}

fn writeLexAcceptsJson(
    writer: anytype,
    states: []const @import("../lexer/serialize.zig").SerializedLexState,
) !void {
    try writer.writeByte('[');
    var first = true;
    for (states, 0..) |state_value, state_index| {
        const symbol = state_value.accept_symbol orelse continue;
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.writeAll("{ \"state\": ");
        try writer.print("{d}", .{state_index});
        try writer.writeAll(", \"symbol\": ");
        try writeSymbolRef(writer, symbol);
        try writer.writeAll(" }");
    }
    try writer.writeByte(']');
}

fn writeLexTableCountsObject(
    writer: anytype,
    counts: LexTableCounts,
    states: []const @import("../lexer/serialize.zig").SerializedLexState,
) !void {
    try writer.writeAll("{ \"state_count\": ");
    try writer.print("{d}", .{counts.state_count});
    try writer.writeAll(", \"transition_count\": ");
    try writer.print("{d}", .{counts.transition_count});
    try writer.writeAll(", \"range_count\": ");
    try writer.print("{d}", .{counts.range_count});
    try writer.writeAll(", \"accept_state_count\": ");
    try writer.print("{d}", .{counts.accept_state_count});
    try writer.writeAll(", \"eof_target_count\": ");
    try writer.print("{d}", .{counts.eof_target_count});
    try writer.writeAll(", \"skip_transition_count\": ");
    try writer.print("{d}", .{counts.skip_transition_count});
    try writer.writeAll(", \"large_range_transition_count\": ");
    try writer.print("{d}", .{counts.large_range_transition_count});
    try writer.writeAll(", \"max_transition_range_count\": ");
    try writer.print("{d}", .{counts.max_transition_range_count});
    try writer.writeAll(", \"accept_symbol_hash\": ");
    try writeJsonHexU64(writer, counts.accept_symbol_hash);
    try writer.writeAll(", \"eof_target_hash\": ");
    try writeJsonHexU64(writer, counts.eof_target_hash);
    try writer.writeAll(", \"transition_target_hash\": ");
    try writeJsonHexU64(writer, counts.transition_target_hash);
    try writer.writeAll(", \"skip_transition_hash\": ");
    try writeJsonHexU64(writer, counts.skip_transition_hash);
    try writer.writeAll(", \"large_range_transition_hash\": ");
    try writeJsonHexU64(writer, counts.large_range_transition_hash);
    try writer.writeAll(", \"range_hash\": ");
    try writeJsonHexU64(writer, counts.range_hash);
    try writer.writeAll(", \"accepts\": ");
    try writeLexAcceptsJson(writer, states);
    try writer.writeAll(" }");
}

fn countLexTables(tables: []const @import("../lexer/serialize.zig").SerializedLexTable) LexTableCounts {
    var result = LexTableCounts{ .table_count = tables.len };
    var accept_hasher = std.hash.Wyhash.init(0);
    var eof_hasher = std.hash.Wyhash.init(0);
    var transition_hasher = std.hash.Wyhash.init(0);
    var skip_hasher = std.hash.Wyhash.init(0);
    var large_range_hasher = std.hash.Wyhash.init(0);
    var range_hasher = std.hash.Wyhash.init(0);
    for (tables) |table| {
        const table_counts = countLexTable(table);
        hashU64(&accept_hasher, table_counts.accept_symbol_hash);
        hashU64(&eof_hasher, table_counts.eof_target_hash);
        hashU64(&transition_hasher, table_counts.transition_target_hash);
        hashU64(&skip_hasher, table_counts.skip_transition_hash);
        hashU64(&large_range_hasher, table_counts.large_range_transition_hash);
        hashU64(&range_hasher, table_counts.range_hash);
        result.state_count += table_counts.state_count;
        result.transition_count += table_counts.transition_count;
        result.range_count += table_counts.range_count;
        result.accept_state_count += table_counts.accept_state_count;
        result.eof_target_count += table_counts.eof_target_count;
        result.skip_transition_count += table_counts.skip_transition_count;
        result.large_range_transition_count += table_counts.large_range_transition_count;
        result.max_transition_range_count = @max(result.max_transition_range_count, table_counts.max_transition_range_count);
    }
    result.accept_symbol_hash = accept_hasher.final();
    result.eof_target_hash = eof_hasher.final();
    result.transition_target_hash = transition_hasher.final();
    result.skip_transition_hash = skip_hasher.final();
    result.large_range_transition_hash = large_range_hasher.final();
    result.range_hash = range_hasher.final();
    return result;
}

fn countLexTable(table: @import("../lexer/serialize.zig").SerializedLexTable) LexTableCounts {
    var result = LexTableCounts{
        .table_count = 1,
        .state_count = table.states.len,
    };
    var accept_hasher = std.hash.Wyhash.init(0);
    var eof_hasher = std.hash.Wyhash.init(0);
    var transition_hasher = std.hash.Wyhash.init(0);
    var skip_hasher = std.hash.Wyhash.init(0);
    var large_range_hasher = std.hash.Wyhash.init(0);
    var range_hasher = std.hash.Wyhash.init(0);
    for (table.states, 0..) |state_value, state_index| {
        hashUsize(&accept_hasher, state_index);
        if (state_value.accept_symbol) |symbol| {
            result.accept_state_count += 1;
            hashBool(&accept_hasher, true);
            hashSymbolRef(&accept_hasher, symbol);
        } else {
            hashBool(&accept_hasher, false);
        }
        hashUsize(&eof_hasher, state_index);
        if (state_value.eof_target) |target| {
            result.eof_target_count += 1;
            hashBool(&eof_hasher, true);
            hashU32(&eof_hasher, target);
        } else {
            hashBool(&eof_hasher, false);
        }
        for (state_value.transitions) |transition| {
            result.transition_count += 1;
            result.range_count += transition.ranges.len;
            result.max_transition_range_count = @max(result.max_transition_range_count, transition.ranges.len);
            if (transition.skip) result.skip_transition_count += 1;
            if (transition.ranges.len > 8) result.large_range_transition_count += 1;
            hashUsize(&transition_hasher, state_index);
            hashU32(&transition_hasher, transition.next_state_id);
            hashBool(&transition_hasher, transition.skip);
            if (transition.skip) {
                hashUsize(&skip_hasher, state_index);
                hashU32(&skip_hasher, transition.next_state_id);
                hashRanges(&skip_hasher, transition.ranges);
            }
            if (transition.ranges.len > 8) {
                hashUsize(&large_range_hasher, state_index);
                hashU32(&large_range_hasher, transition.next_state_id);
                hashBool(&large_range_hasher, transition.skip);
                hashRanges(&large_range_hasher, transition.ranges);
            }
            hashUsize(&range_hasher, state_index);
            hashU32(&range_hasher, transition.next_state_id);
            for (transition.ranges) |range| {
                hashU32(&range_hasher, range.start);
                hashU32(&range_hasher, range.end_inclusive);
            }
        }
    }
    result.accept_symbol_hash = accept_hasher.final();
    result.eof_target_hash = eof_hasher.final();
    result.transition_target_hash = transition_hasher.final();
    result.skip_transition_hash = skip_hasher.final();
    result.large_range_transition_hash = large_range_hasher.final();
    result.range_hash = range_hasher.final();
    return result;
}

fn hashRanges(hasher: *std.hash.Wyhash, ranges: []const @import("../lexer/serialize.zig").SerializedCharacterRange) void {
    hashUsize(hasher, ranges.len);
    for (ranges) |range| {
        hashU32(hasher, range.start);
        hashU32(hasher, range.end_inclusive);
    }
}

fn countProductions(variables: []const syntax_ir.SyntaxVariable) usize {
    var count: usize = 0;
    for (variables) |variable| count += variable.productions.len;
    return count;
}

fn countSteps(variables: []const syntax_ir.SyntaxVariable) usize {
    var count: usize = 0;
    for (variables) |variable| {
        for (variable.productions) |production| count += production.steps.len;
    }
    return count;
}

fn hashPreparedVariables(prepared: grammar_ir.PreparedGrammar) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (prepared.variables) |variable| {
        hashString(&hasher, variable.name);
        hashTag(&hasher, @tagName(variable.kind));
        hashU32(&hasher, variable.symbol.index);
        hashTag(&hasher, @tagName(variable.symbol.kind));
        hashU32(&hasher, variable.rule);
    }
    return hasher.final();
}

fn hashPreparedSymbols(prepared: grammar_ir.PreparedGrammar) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (prepared.symbols) |symbol| {
        hashString(&hasher, symbol.name);
        hashTag(&hasher, @tagName(symbol.id.kind));
        hashU32(&hasher, symbol.id.index);
        hashBool(&hasher, symbol.named);
        hashBool(&hasher, symbol.visible);
        hashBool(&hasher, symbol.supertype);
    }
    return hasher.final();
}

fn hashPreparedReservedWordSets(prepared: grammar_ir.PreparedGrammar) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (prepared.reserved_word_sets) |set| {
        hashString(&hasher, set.context_name);
        for (set.members) |member| hashU32(&hasher, member);
        hashTag(&hasher, "reserved_word_set_end");
    }
    return hasher.final();
}

fn hashPreparedConflictSets(prepared: grammar_ir.PreparedGrammar) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (prepared.expected_conflicts) |set| {
        hashSymbolIdArray(&hasher, set);
        hashTag(&hasher, "prepared_conflict_end");
    }
    return hasher.final();
}

fn hashPreparedPrecedenceOrderings(prepared: grammar_ir.PreparedGrammar) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (prepared.precedence_orderings) |ordering| {
        for (ordering) |entry| hashPreparedPrecedenceEntry(&hasher, entry);
        hashTag(&hasher, "prepared_precedence_ordering_end");
    }
    return hasher.final();
}

fn hashPreparedPrecedenceEntry(hasher: *std.hash.Wyhash, entry: grammar_ir.PrecedenceEntry) void {
    switch (entry) {
        .name => |name| {
            hashTag(hasher, "name");
            hashString(hasher, name);
        },
        .symbol => |symbol| {
            hashTag(hasher, "symbol");
            hashSymbolId(hasher, symbol);
        },
    }
}

fn hashSymbolIdArray(hasher: *std.hash.Wyhash, symbols: []const ir_symbols.SymbolId) void {
    for (symbols) |symbol| hashSymbolId(hasher, symbol);
}

fn hashSymbolId(hasher: *std.hash.Wyhash, symbol: ir_symbols.SymbolId) void {
    hashTag(hasher, @tagName(symbol.kind));
    hashU32(hasher, symbol.index);
}

fn hashOptionalSymbolId(maybe_symbol: ?ir_symbols.SymbolId) u64 {
    var hasher = std.hash.Wyhash.init(0);
    if (maybe_symbol) |symbol| {
        hashBool(&hasher, true);
        hashSymbolId(&hasher, symbol);
    } else {
        hashBool(&hasher, false);
    }
    return hasher.final();
}

fn hashSymbolIds(symbols: []const ir_symbols.SymbolId) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashSymbolIdArray(&hasher, symbols);
    return hasher.final();
}

fn hashLexicalGrammar(grammar: lexical_ir.LexicalGrammar, rules: []const ir_rules.Rule) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (grammar.variables) |variable| {
        hashString(&hasher, variable.name);
        hashTag(&hasher, @tagName(variable.kind));
        hashU32(&hasher, variable.rule);
        hashI32(&hasher, variable.implicit_precedence);
        hashU32(&hasher, variable.start_state);
        hashTag(&hasher, @tagName(variable.source_kind));
        hashBool(&hasher, variable.rule < rules.len and ruleHasImmediateToken(rules, variable.rule));
    }
    for (grammar.separators) |separator| hashU32(&hasher, separator);
    return hasher.final();
}

fn ruleHasImmediateToken(rules: []const ir_rules.Rule, rule_id: ir_rules.RuleId) bool {
    if (rule_id >= rules.len) return false;
    return switch (rules[rule_id]) {
        .metadata => |metadata| metadata.data.immediate_token or ruleHasImmediateToken(rules, metadata.inner),
        .choice, .seq => |members| {
            for (members) |member| {
                if (ruleHasImmediateToken(rules, member)) return true;
            }
            return false;
        },
        .repeat, .repeat1 => |inner| ruleHasImmediateToken(rules, inner),
        else => false,
    };
}

fn hashSymbolRefArray(values: []const syntax_ir.SymbolRef) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (values) |value| hashSymbolRef(&hasher, value);
    return hasher.final();
}

fn hashSymbolRefSets(sets: []const []const syntax_ir.SymbolRef) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (sets) |set| {
        for (set) |symbol| hashSymbolRef(&hasher, symbol);
        hashTag(&hasher, "symbol_ref_set_end");
    }
    return hasher.final();
}

fn hashSyntaxPrecedenceOrderings(orderings: []const []const syntax_ir.PrecedenceEntry) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (orderings) |ordering| {
        for (ordering) |entry| hashSyntaxPrecedenceEntry(&hasher, entry);
        hashTag(&hasher, "syntax_precedence_ordering_end");
    }
    return hasher.final();
}

fn hashSyntaxPrecedenceEntry(hasher: *std.hash.Wyhash, entry: syntax_ir.PrecedenceEntry) void {
    switch (entry) {
        .name => |name| {
            hashTag(hasher, "name");
            hashString(hasher, name);
        },
        .symbol => |symbol| {
            hashTag(hasher, "symbol");
            hashSymbolRef(hasher, symbol);
        },
    }
}

fn hashOptionalSymbolRef(maybe_symbol: ?syntax_ir.SymbolRef) u64 {
    var hasher = std.hash.Wyhash.init(0);
    if (maybe_symbol) |symbol| {
        hashBool(&hasher, true);
        hashSymbolRef(&hasher, symbol);
    } else {
        hashBool(&hasher, false);
    }
    return hasher.final();
}

fn hashSyntaxGrammar(grammar: syntax_ir.SyntaxGrammar) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (grammar.variables) |variable| {
        hashString(&hasher, variable.name);
        hashTag(&hasher, @tagName(variable.kind));
        for (variable.productions) |production| {
            hashI32(&hasher, production.dynamic_precedence);
            for (production.steps) |step| hashProductionStep(&hasher, step);
            hashTag(&hasher, "production_end");
        }
    }
    return hasher.final();
}

fn hashProductionStep(hasher: *std.hash.Wyhash, step: syntax_ir.ProductionStep) void {
    hashSymbolRef(hasher, step.symbol);
    if (step.alias) |alias| {
        hashBool(hasher, true);
        hashString(hasher, alias.value);
        hashBool(hasher, alias.named);
    } else {
        hashBool(hasher, false);
    }
    if (step.field_name) |field_name| {
        hashBool(hasher, true);
        hashString(hasher, field_name);
    } else {
        hashBool(hasher, false);
    }
    hashBool(hasher, step.field_inherited);
    hashPrecedenceValue(hasher, step.precedence);
    hashTag(hasher, @tagName(step.associativity));
    if (step.reserved_context_name) |context_name| {
        hashBool(hasher, true);
        hashString(hasher, context_name);
    } else {
        hashBool(hasher, false);
    }
}

fn hashSymbolRef(hasher: *std.hash.Wyhash, symbol: syntax_ir.SymbolRef) void {
    switch (symbol) {
        .end => hashTag(hasher, "end"),
        .non_terminal => |index| {
            hashTag(hasher, "non_terminal");
            hashU32(hasher, index);
        },
        .terminal => |index| {
            hashTag(hasher, "terminal");
            hashU32(hasher, index);
        },
        .external => |index| {
            hashTag(hasher, "external");
            hashU32(hasher, index);
        },
    }
}

fn hashPrecedenceValue(hasher: *std.hash.Wyhash, value: @import("../ir/rules.zig").PrecedenceValue) void {
    switch (value) {
        .none => hashTag(hasher, "none"),
        .integer => |integer| {
            hashTag(hasher, "integer");
            hashI32(hasher, integer);
        },
        .name => |name| {
            hashTag(hasher, "name");
            hashString(hasher, name);
        },
    }
}

fn hashString(hasher: *std.hash.Wyhash, value: []const u8) void {
    hashUsize(hasher, value.len);
    hasher.update(value);
}

fn hashTag(hasher: *std.hash.Wyhash, value: []const u8) void {
    hashString(hasher, value);
}

fn hashBool(hasher: *std.hash.Wyhash, value: bool) void {
    hasher.update(&.{if (value) @as(u8, 1) else 0});
}

fn hashUsize(hasher: *std.hash.Wyhash, value: usize) void {
    var buffer: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &buffer, value, .little);
    hasher.update(&buffer);
}

fn hashU32(hasher: *std.hash.Wyhash, value: u32) void {
    var buffer: [@sizeOf(u32)]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .little);
    hasher.update(&buffer);
}

fn hashU64(hasher: *std.hash.Wyhash, value: u64) void {
    var buffer: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &buffer, value, .little);
    hasher.update(&buffer);
}

fn hashI32(hasher: *std.hash.Wyhash, value: i32) void {
    var buffer: [@sizeOf(i32)]u8 = undefined;
    std.mem.writeInt(i32, &buffer, value, .little);
    hasher.update(&buffer);
}

pub fn renderSummaryJsonAlloc(allocator: std.mem.Allocator, summary: Summary) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeSummaryJson(&out.writer, summary, 0);
    return try out.toOwnedSlice();
}

pub fn writePreparedIrSummaryJson(writer: anytype, summary: PreparedIrSummary, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try writeU64HexField(writer, indent + 2, "stage_order_hash", summary.stage_order_hash, true);
    try writeUsizeField(writer, indent + 2, "variable_count", summary.variable_count, true);
    try writeUsizeField(writer, indent + 2, "rule_count", summary.rule_count, true);
    try writeUsizeField(writer, indent + 2, "symbol_count", summary.symbol_count, true);
    try writeUsizeField(writer, indent + 2, "external_token_count", summary.external_token_count, true);
    try writeUsizeField(writer, indent + 2, "extra_rule_count", summary.extra_rule_count, true);
    try writeUsizeField(writer, indent + 2, "conflict_count", summary.conflict_count, true);
    try writeUsizeField(writer, indent + 2, "precedence_order_count", summary.precedence_order_count, true);
    try writeUsizeField(writer, indent + 2, "inline_count", summary.inline_count, true);
    try writeUsizeField(writer, indent + 2, "supertype_count", summary.supertype_count, true);
    try writeUsizeField(writer, indent + 2, "reserved_word_set_count", summary.reserved_word_set_count, true);
    try writeU64HexField(writer, indent + 2, "prepared_variable_hash", summary.prepared_variable_hash, true);
    try writeU64HexField(writer, indent + 2, "prepared_symbol_hash", summary.prepared_symbol_hash, true);
    try writeU64HexField(writer, indent + 2, "prepared_reserved_word_set_hash", summary.prepared_reserved_word_set_hash, true);
    try writeU64HexField(writer, indent + 2, "prepared_conflict_hash", summary.prepared_conflict_hash, true);
    try writeU64HexField(writer, indent + 2, "prepared_precedence_hash", summary.prepared_precedence_hash, true);
    try writeU64HexField(writer, indent + 2, "prepared_inline_hash", summary.prepared_inline_hash, true);
    try writeU64HexField(writer, indent + 2, "prepared_supertype_hash", summary.prepared_supertype_hash, true);
    try writeU64HexField(writer, indent + 2, "prepared_word_token_hash", summary.prepared_word_token_hash, true);
    try writeUsizeField(writer, indent + 2, "extracted_syntax_variable_count", summary.extracted_syntax_variable_count, true);
    try writeUsizeField(writer, indent + 2, "extracted_syntax_production_count", summary.extracted_syntax_production_count, true);
    try writeUsizeField(writer, indent + 2, "extracted_syntax_step_count", summary.extracted_syntax_step_count, true);
    try writeU64HexField(writer, indent + 2, "extracted_extra_symbol_hash", summary.extracted_extra_symbol_hash, true);
    try writeU64HexField(writer, indent + 2, "extracted_expected_conflict_hash", summary.extracted_expected_conflict_hash, true);
    try writeU64HexField(writer, indent + 2, "extracted_precedence_hash", summary.extracted_precedence_hash, true);
    try writeU64HexField(writer, indent + 2, "extracted_inline_hash", summary.extracted_inline_hash, true);
    try writeU64HexField(writer, indent + 2, "extracted_supertype_hash", summary.extracted_supertype_hash, true);
    try writeU64HexField(writer, indent + 2, "extracted_word_token_hash", summary.extracted_word_token_hash, true);
    try writeUsizeField(writer, indent + 2, "extracted_lexical_variable_count", summary.extracted_lexical_variable_count, true);
    try writeUsizeField(writer, indent + 2, "extracted_lexical_separator_count", summary.extracted_lexical_separator_count, true);
    try writeU64HexField(writer, indent + 2, "extracted_lexical_hash", summary.extracted_lexical_hash, true);
    try writeUsizeField(writer, indent + 2, "flattened_syntax_variable_count", summary.flattened_syntax_variable_count, true);
    try writeUsizeField(writer, indent + 2, "flattened_syntax_production_count", summary.flattened_syntax_production_count, true);
    try writeUsizeField(writer, indent + 2, "flattened_syntax_step_count", summary.flattened_syntax_step_count, true);
    try writeU64HexField(writer, indent + 2, "flattened_syntax_hash", summary.flattened_syntax_hash, false);
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

pub fn writePreparedIrComparisonKeysJson(writer: anytype, summary: PreparedIrSummary, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"note\": ");
    try writeJsonString(writer, "local prepared/extracted comparison keys are stable; tree-sitter does not expose an equivalent prepared-IR artifact through the bounded generator snapshot");
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"keys\": [\n");
    try writePreparedIrComparisonKey(writer, indent + 4, "stage_order", summary.stage_order_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "prepared_variables", summary.prepared_variable_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "prepared_symbols", summary.prepared_symbol_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "prepared_reserved_word_sets", summary.prepared_reserved_word_set_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "prepared_conflicts", summary.prepared_conflict_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "prepared_precedence", summary.prepared_precedence_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "prepared_inline", summary.prepared_inline_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "prepared_supertypes", summary.prepared_supertype_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "prepared_word_token", summary.prepared_word_token_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "extracted_extra_symbols", summary.extracted_extra_symbol_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "extracted_expected_conflicts", summary.extracted_expected_conflict_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "extracted_precedence", summary.extracted_precedence_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "extracted_inline", summary.extracted_inline_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "extracted_supertypes", summary.extracted_supertype_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "extracted_word_token", summary.extracted_word_token_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "extracted_lexical_variables", summary.extracted_lexical_hash, true);
    try writePreparedIrComparisonKey(writer, indent + 4, "flattened_syntax", summary.flattened_syntax_hash, false);
    try writer.writeByte('\n');
    try writeIndent(writer, indent + 2);
    try writer.writeAll("]\n");
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

fn writePreparedIrComparisonKey(
    writer: anytype,
    indent: usize,
    name: []const u8,
    hash: u64,
    trailing_comma: bool,
) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{ \"name\": ");
    try writeJsonString(writer, name);
    try writer.writeAll(", \"local_hash\": \"");
    try writer.print("0x{x:0>16}", .{hash});
    try writer.writeByte('"');
    try writer.writeAll(", \"upstream_hash\": null, \"status\": ");
    try writeJsonString(writer, "upstream_oracle_missing");
    try writer.writeAll(" }");
    if (trailing_comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn writePreparedIrSnapshotJson(
    writer: anytype,
    prepared: grammar_ir.PreparedGrammar,
    extracted: extract_tokens.ExtractedGrammars,
    flattened: syntax_ir.SyntaxGrammar,
) !void {
    try writer.writeAll("{\n");
    try writer.writeAll("  \"local_stage_order\": [");
    for (local_preparation_stage_order, 0..) |stage, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeJsonString(writer, stage);
    }
    try writer.writeAll("],\n");
    try writer.writeAll("  \"prepared_variables\": [");
    if (prepared.variables.len != 0) try writer.writeByte('\n');
    for (prepared.variables, 0..) |variable, index| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, variable.name);
        try writer.writeAll(", \"kind\": ");
        try writeJsonString(writer, @tagName(variable.kind));
        try writer.print(", \"symbol_kind\": \"{s}\", \"symbol_index\": {d}, \"rule\": {d} }}", .{
            @tagName(variable.symbol.kind),
            variable.symbol.index,
            variable.rule,
        });
        if (index + 1 != prepared.variables.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (prepared.variables.len != 0) try writer.writeAll("  ");
    try writer.writeAll("],\n");

    try writer.writeAll("  \"prepared_symbols\": [");
    if (prepared.symbols.len != 0) try writer.writeByte('\n');
    for (prepared.symbols, 0..) |symbol, index| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, symbol.name);
        try writer.print(
            ", \"kind\": \"{s}\", \"index\": {d}, \"named\": {}, \"visible\": {}, \"supertype\": {} }}",
            .{ @tagName(symbol.id.kind), symbol.id.index, symbol.named, symbol.visible, symbol.supertype },
        );
        if (index + 1 != prepared.symbols.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (prepared.symbols.len != 0) try writer.writeAll("  ");
    try writer.writeAll("],\n");

    try writer.writeAll("  \"prepared_word_token\": ");
    try writeOptionalSymbolId(writer, prepared.word_token);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"prepared_reserved_word_sets\": [");
    if (prepared.reserved_word_sets.len != 0) try writer.writeByte('\n');
    for (prepared.reserved_word_sets, 0..) |reserved_set, index| {
        try writer.writeAll("    { \"context\": ");
        try writeJsonString(writer, reserved_set.context_name);
        try writer.writeAll(", \"members\": ");
        try writeRuleIdArray(writer, reserved_set.members);
        try writer.writeAll(" }");
        if (index + 1 != prepared.reserved_word_sets.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (prepared.reserved_word_sets.len != 0) try writer.writeAll("  ");
    try writer.writeAll("],\n");

    try writer.writeAll("  \"extracted_lexical_variables\": [");
    if (extracted.lexical.variables.len != 0) try writer.writeByte('\n');
    for (extracted.lexical.variables, 0..) |variable, index| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, variable.name);
        try writer.print(
            ", \"kind\": \"{s}\", \"source_kind\": \"{s}\", \"rule\": {d}, \"implicit_precedence\": {d}, \"start_state\": {d}, \"immediate\": {} }}",
            .{
                @tagName(variable.kind),
                @tagName(variable.source_kind),
                variable.rule,
                variable.implicit_precedence,
                variable.start_state,
                variable.rule < prepared.rules.len and ruleHasImmediateToken(prepared.rules, variable.rule),
            },
        );
        if (index + 1 != extracted.lexical.variables.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (extracted.lexical.variables.len != 0) try writer.writeAll("  ");
    try writer.writeAll("],\n");

    try writer.writeAll("  \"extracted_lexical_separators\": ");
    try writeRuleIdArray(writer, extracted.lexical.separators);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"extracted_external_tokens\": [");
    if (extracted.syntax.external_tokens.len != 0) try writer.writeByte('\n');
    for (extracted.syntax.external_tokens, 0..) |token, index| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, token.name);
        try writer.writeAll(", \"kind\": ");
        try writeJsonString(writer, @tagName(token.kind));
        try writer.writeAll(" }");
        if (index + 1 != extracted.syntax.external_tokens.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (extracted.syntax.external_tokens.len != 0) try writer.writeAll("  ");
    try writer.writeAll("],\n");

    try writer.writeAll("  \"extracted_extra_symbols\": ");
    try writeSymbolRefArray(writer, extracted.syntax.extra_symbols);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"extracted_expected_conflicts\": ");
    try writeSymbolRefSets(writer, extracted.syntax.expected_conflicts);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"extracted_precedence_orderings\": ");
    try writePrecedenceOrderings(writer, extracted.syntax.precedence_orderings);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"extracted_variables_to_inline\": ");
    try writeSymbolRefArray(writer, extracted.syntax.variables_to_inline);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"extracted_supertype_symbols\": ");
    try writeSymbolRefArray(writer, extracted.syntax.supertype_symbols);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"extracted_word_token\": ");
    try writeOptionalSymbolRef(writer, extracted.syntax.word_token);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"flattened_syntax_variables\": [");
    if (flattened.variables.len != 0) try writer.writeByte('\n');
    for (flattened.variables, 0..) |variable, index| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, variable.name);
        try writer.print(
            ", \"kind\": \"{s}\", \"production_count\": {d}, \"step_count\": {d} }}",
            .{ @tagName(variable.kind), variable.productions.len, countVariableSteps(variable) },
        );
        if (index + 1 != flattened.variables.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (flattened.variables.len != 0) try writer.writeAll("  ");
    try writer.writeAll("]\n");
    try writer.writeAll("}\n");
}

fn writeRuleIdArray(writer: anytype, values: []const @import("../ir/rules.zig").RuleId) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{value});
    }
    try writer.writeByte(']');
}

fn writeOptionalSymbolId(writer: anytype, maybe_symbol: ?@import("../ir/symbols.zig").SymbolId) !void {
    if (maybe_symbol) |symbol| {
        try writeSymbolId(writer, symbol);
    } else {
        try writer.writeAll("null");
    }
}

fn writeSymbolId(writer: anytype, symbol: @import("../ir/symbols.zig").SymbolId) !void {
    try writer.writeAll("{ \"kind\": ");
    try writeJsonString(writer, @tagName(symbol.kind));
    try writer.print(", \"index\": {d} }}", .{symbol.index});
}

fn writeOptionalSymbolRef(writer: anytype, maybe_symbol: ?syntax_ir.SymbolRef) !void {
    if (maybe_symbol) |symbol| {
        try writeSymbolRef(writer, symbol);
    } else {
        try writer.writeAll("null");
    }
}

fn writeSymbolRefArray(writer: anytype, values: []const syntax_ir.SymbolRef) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeSymbolRef(writer, value);
    }
    try writer.writeByte(']');
}

fn writeSymbolRefSets(writer: anytype, sets: []const []const syntax_ir.SymbolRef) !void {
    try writer.writeByte('[');
    for (sets, 0..) |set, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeSymbolRefArray(writer, set);
    }
    try writer.writeByte(']');
}

fn writePrecedenceOrderings(writer: anytype, orderings: []const []const syntax_ir.PrecedenceEntry) !void {
    try writer.writeByte('[');
    for (orderings, 0..) |ordering, ordering_index| {
        if (ordering_index != 0) try writer.writeAll(", ");
        try writer.writeByte('[');
        for (ordering, 0..) |entry, entry_index| {
            if (entry_index != 0) try writer.writeAll(", ");
            try writePrecedenceEntry(writer, entry);
        }
        try writer.writeByte(']');
    }
    try writer.writeByte(']');
}

fn writePrecedenceEntry(writer: anytype, entry: syntax_ir.PrecedenceEntry) !void {
    try writer.writeAll("{ \"kind\": ");
    switch (entry) {
        .name => |name| {
            try writeJsonString(writer, "name");
            try writer.writeAll(", \"name\": ");
            try writeJsonString(writer, name);
        },
        .symbol => |symbol| {
            try writeJsonString(writer, "symbol");
            try writer.writeAll(", \"symbol\": ");
            try writeSymbolRef(writer, symbol);
        },
    }
    try writer.writeAll(" }");
}

fn writeSymbolRef(writer: anytype, symbol: syntax_ir.SymbolRef) !void {
    try writer.writeAll("{ \"kind\": ");
    switch (symbol) {
        .end => try writeJsonString(writer, "end"),
        .non_terminal => |index| {
            try writeJsonString(writer, "non_terminal");
            try writer.print(", \"index\": {d}", .{index});
        },
        .terminal => |index| {
            try writeJsonString(writer, "terminal");
            try writer.print(", \"index\": {d}", .{index});
        },
        .external => |index| {
            try writeJsonString(writer, "external");
            try writer.print(", \"index\": {d}", .{index});
        },
    }
    try writer.writeAll(" }");
}

fn countVariableSteps(variable: syntax_ir.SyntaxVariable) usize {
    var count: usize = 0;
    for (variable.productions) |production| count += production.steps.len;
    return count;
}

fn preparedIrSummary(
    prepared: grammar_ir.PreparedGrammar,
    extracted: extract_tokens.ExtractedGrammars,
    flattened: syntax_ir.SyntaxGrammar,
) PreparedIrSummary {
    return .{
        .stage_order_hash = hashStageOrder(&local_preparation_stage_order),
        .variable_count = prepared.variables.len,
        .rule_count = prepared.rules.len,
        .symbol_count = prepared.symbols.len,
        .external_token_count = prepared.external_tokens.len,
        .extra_rule_count = prepared.extra_rules.len,
        .conflict_count = prepared.expected_conflicts.len,
        .precedence_order_count = prepared.precedence_orderings.len,
        .inline_count = prepared.variables_to_inline.len,
        .supertype_count = prepared.supertype_symbols.len,
        .reserved_word_set_count = prepared.reserved_word_sets.len,
        .prepared_variable_hash = hashPreparedVariables(prepared),
        .prepared_symbol_hash = hashPreparedSymbols(prepared),
        .prepared_reserved_word_set_hash = hashPreparedReservedWordSets(prepared),
        .prepared_conflict_hash = hashPreparedConflictSets(prepared),
        .prepared_precedence_hash = hashPreparedPrecedenceOrderings(prepared),
        .prepared_inline_hash = hashSymbolIds(prepared.variables_to_inline),
        .prepared_supertype_hash = hashSymbolIds(prepared.supertype_symbols),
        .prepared_word_token_hash = hashOptionalSymbolId(prepared.word_token),
        .extracted_syntax_variable_count = extracted.syntax.variables.len,
        .extracted_syntax_production_count = countProductions(extracted.syntax.variables),
        .extracted_syntax_step_count = countSteps(extracted.syntax.variables),
        .extracted_extra_symbol_hash = hashSymbolRefArray(extracted.syntax.extra_symbols),
        .extracted_expected_conflict_hash = hashSymbolRefSets(extracted.syntax.expected_conflicts),
        .extracted_precedence_hash = hashSyntaxPrecedenceOrderings(extracted.syntax.precedence_orderings),
        .extracted_inline_hash = hashSymbolRefArray(extracted.syntax.variables_to_inline),
        .extracted_supertype_hash = hashSymbolRefArray(extracted.syntax.supertype_symbols),
        .extracted_word_token_hash = hashOptionalSymbolRef(extracted.syntax.word_token),
        .extracted_lexical_variable_count = extracted.lexical.variables.len,
        .extracted_lexical_separator_count = extracted.lexical.separators.len,
        .extracted_lexical_hash = hashLexicalGrammar(extracted.lexical, prepared.rules),
        .flattened_syntax_variable_count = flattened.variables.len,
        .flattened_syntax_production_count = countProductions(flattened.variables),
        .flattened_syntax_step_count = countSteps(flattened.variables),
        .flattened_syntax_hash = hashSyntaxGrammar(flattened),
    };
}

fn hashStageOrder(stages: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (stages) |stage| hashString(&hasher, stage);
    return hasher.final();
}

pub fn writeSummaryJson(writer: anytype, summary: Summary, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try writeFieldPrefix(writer, indent + 2, "grammar_name");
    try writeJsonString(writer, summary.grammar_name);
    try writer.writeAll(",\n");
    try writeUsizeField(writer, indent + 2, "language_version", summary.language_version, true);
    try writeFieldPrefix(writer, indent + 2, "blocked");
    try writer.writeAll(if (summary.blocked) "true" else "false");
    try writer.writeAll(",\n");
    try writeUsizeField(writer, indent + 2, "rule_count", summary.rule_count, true);
    try writeUsizeField(writer, indent + 2, "external_count", summary.external_count, true);
    try writeUsizeField(writer, indent + 2, "extra_count", summary.extra_count, true);
    try writeUsizeField(writer, indent + 2, "symbol_count", summary.symbol_count, true);
    try writeU64HexField(writer, indent + 2, "symbol_order_hash", summary.symbol_order_hash, true);
    try writeUsizeField(writer, indent + 2, "token_count", summary.token_count, true);
    try writeUsizeField(writer, indent + 2, "field_count", summary.field_count, true);
    try writeU64HexField(writer, indent + 2, "field_names_hash", summary.field_names_hash, true);
    try writeU64HexField(writer, indent + 2, "node_types_hash", summary.node_types_hash, true);
    try writeUsizeField(writer, indent + 2, "alias_count", summary.alias_count, true);
    try writeUsizeField(writer, indent + 2, "production_id_count", summary.production_id_count, true);
    try writeUsizeField(writer, indent + 2, "serialized_state_count", summary.serialized_state_count, true);
    try writeUsizeField(writer, indent + 2, "emitted_state_count", summary.emitted_state_count, true);
    try writeUsizeField(writer, indent + 2, "large_state_count", summary.large_state_count, true);
    try writeUsizeField(writer, indent + 2, "parse_action_list_count", summary.parse_action_list_count, true);
    try writeUsizeField(writer, indent + 2, "small_parse_row_count", summary.small_parse_row_count, true);
    try writeUsizeField(writer, indent + 2, "small_parse_map_count", summary.small_parse_map_count, true);
    try writeUsizeField(writer, indent + 2, "lex_mode_count", summary.lex_mode_count, true);
    try writeUsizeField(writer, indent + 2, "lex_function_case_count", summary.lex_function_case_count, true);
    try writeUsizeField(writer, indent + 2, "keyword_lex_function_case_count", summary.keyword_lex_function_case_count, true);
    try writeUsizeField(writer, indent + 2, "large_character_set_count", summary.large_character_set_count, true);
    try writeUsizeField(writer, indent + 2, "external_lex_state_count", summary.external_lex_state_count, false);
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

pub fn compareSummariesAlloc(
    allocator: std.mem.Allocator,
    local: Summary,
    upstream: Summary,
) ![]const SummaryDiff {
    var diffs: std.ArrayList(SummaryDiff) = .empty;
    errdefer deinitDiffs(allocator, diffs.items);

    try compareStringField(allocator, &diffs, "grammar_name", local.grammar_name, upstream.grammar_name, .regression);
    try compareUsizeField(allocator, &diffs, "language_version", local.language_version, upstream.language_version, .known_unsupported_surface);
    try compareBoolField(allocator, &diffs, "blocked", local.blocked, upstream.blocked, .suspected_algorithm_gap);
    if (upstream.rule_count != 0) try compareUsizeField(allocator, &diffs, "rule_count", local.rule_count, upstream.rule_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "external_count", local.external_count, upstream.external_count, .suspected_algorithm_gap);
    if (upstream.extra_count != 0) try compareUsizeField(allocator, &diffs, "extra_count", local.extra_count, upstream.extra_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "symbol_count", local.symbol_count, upstream.symbol_count, .suspected_algorithm_gap);
    try compareU64HexField(allocator, &diffs, "symbol_order_hash", local.symbol_order_hash, upstream.symbol_order_hash, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "token_count", local.token_count, upstream.token_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "field_count", local.field_count, upstream.field_count, .suspected_algorithm_gap);
    try compareU64HexField(allocator, &diffs, "field_names_hash", local.field_names_hash, upstream.field_names_hash, .suspected_algorithm_gap);
    try compareU64HexField(allocator, &diffs, "node_types_hash", local.node_types_hash, upstream.node_types_hash, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "alias_count", local.alias_count, upstream.alias_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "production_id_count", local.production_id_count, upstream.production_id_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "serialized_state_count", local.serialized_state_count, upstream.serialized_state_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "emitted_state_count", local.emitted_state_count, upstream.emitted_state_count, .expected_local_extension);
    try compareUsizeField(allocator, &diffs, "large_state_count", local.large_state_count, upstream.large_state_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "parse_action_list_count", local.parse_action_list_count, upstream.parse_action_list_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "small_parse_row_count", local.small_parse_row_count, upstream.small_parse_row_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "small_parse_map_count", local.small_parse_map_count, upstream.small_parse_map_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "lex_mode_count", local.lex_mode_count, upstream.lex_mode_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "lex_function_case_count", local.lex_function_case_count, upstream.lex_function_case_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "keyword_lex_function_case_count", local.keyword_lex_function_case_count, upstream.keyword_lex_function_case_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "large_character_set_count", local.large_character_set_count, upstream.large_character_set_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "external_lex_state_count", local.external_lex_state_count, upstream.external_lex_state_count, .known_unsupported_surface);

    return try diffs.toOwnedSlice(allocator);
}

pub fn deinitDiffs(allocator: std.mem.Allocator, diffs: []const SummaryDiff) void {
    for (diffs) |diff| {
        allocator.free(diff.field);
        allocator.free(diff.local);
        allocator.free(diff.upstream);
    }
    allocator.free(diffs);
}

pub fn renderDiffsJsonAlloc(allocator: std.mem.Allocator, diffs: []const SummaryDiff) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeDiffsJson(&out.writer, diffs, 0);
    return try out.toOwnedSlice();
}

pub fn writeDiffsJson(writer: anytype, diffs: []const SummaryDiff, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("[");
    if (diffs.len != 0) try writer.writeByte('\n');
    for (diffs, 0..) |diff, index| {
        try writeIndent(writer, indent + 2);
        try writer.writeAll("{ ");
        try writer.writeAll("\"field\": ");
        try writeJsonString(writer, diff.field);
        try writer.writeAll(", \"local\": ");
        try writeJsonString(writer, diff.local);
        try writer.writeAll(", \"upstream\": ");
        try writeJsonString(writer, diff.upstream);
        try writer.writeAll(", \"classification\": ");
        try writeJsonString(writer, @tagName(diff.classification));
        try writer.writeAll(" }");
        if (index + 1 != diffs.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (diffs.len != 0) try writeIndent(writer, indent);
    try writer.writeByte(']');
}

fn compareStringField(
    allocator: std.mem.Allocator,
    diffs: *std.ArrayList(SummaryDiff),
    field: []const u8,
    local: []const u8,
    upstream: []const u8,
    classification: DiffClassification,
) !void {
    if (std.mem.eql(u8, local, upstream)) return;
    try diffs.append(allocator, .{
        .field = try allocator.dupe(u8, field),
        .local = try allocator.dupe(u8, local),
        .upstream = try allocator.dupe(u8, upstream),
        .classification = classification,
    });
}

fn compareBoolField(
    allocator: std.mem.Allocator,
    diffs: *std.ArrayList(SummaryDiff),
    field: []const u8,
    local: bool,
    upstream: bool,
    classification: DiffClassification,
) !void {
    if (local == upstream) return;
    try diffs.append(allocator, .{
        .field = try allocator.dupe(u8, field),
        .local = try allocator.dupe(u8, if (local) "true" else "false"),
        .upstream = try allocator.dupe(u8, if (upstream) "true" else "false"),
        .classification = classification,
    });
}

fn compareUsizeField(
    allocator: std.mem.Allocator,
    diffs: *std.ArrayList(SummaryDiff),
    field: []const u8,
    local: usize,
    upstream: usize,
    classification: DiffClassification,
) !void {
    if (local == upstream) return;
    try diffs.append(allocator, .{
        .field = try allocator.dupe(u8, field),
        .local = try std.fmt.allocPrint(allocator, "{d}", .{local}),
        .upstream = try std.fmt.allocPrint(allocator, "{d}", .{upstream}),
        .classification = classification,
    });
}

fn compareU64HexField(
    allocator: std.mem.Allocator,
    diffs: *std.ArrayList(SummaryDiff),
    field: []const u8,
    local: u64,
    upstream: u64,
    classification: DiffClassification,
) !void {
    if (local == upstream) return;
    try diffs.append(allocator, .{
        .field = try allocator.dupe(u8, field),
        .local = try std.fmt.allocPrint(allocator, "0x{x}", .{local}),
        .upstream = try std.fmt.allocPrint(allocator, "0x{x}", .{upstream}),
        .classification = classification,
    });
}

fn writeUsizeField(writer: anytype, indent: usize, name: []const u8, value: usize, comma: bool) !void {
    try writeFieldPrefix(writer, indent, name);
    try writer.print("{d}", .{value});
    if (comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn writeU64HexField(writer: anytype, indent: usize, name: []const u8, value: u64, comma: bool) !void {
    try writeFieldPrefix(writer, indent, name);
    try writeJsonHexU64(writer, value);
    if (comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn writeBoolField(writer: anytype, indent: usize, name: []const u8, value: bool, comma: bool) !void {
    try writeFieldPrefix(writer, indent, name);
    try writeBoolJson(writer, value);
    if (comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn writeJsonHexU64(writer: anytype, value: u64) !void {
    try writer.print("\"0x{x}\"", .{value});
}

fn writeFieldPrefix(writer: anytype, indent: usize, name: []const u8) !void {
    try writeIndent(writer, indent);
    try writeJsonString(writer, name);
    try writer.writeAll(": ");
}

fn writeIndent(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

test "compareSummariesAlloc classifies changed fields" {
    const local = Summary{
        .grammar_name = "json",
        .language_version = 15,
        .blocked = false,
        .rule_count = 1,
        .external_count = 0,
        .extra_count = 1,
        .symbol_count = 4,
        .symbol_order_hash = 1,
        .token_count = 2,
        .field_count = 0,
        .field_names_hash = 0,
        .node_types_hash = 0,
        .alias_count = 0,
        .production_id_count = 0,
        .serialized_state_count = 5,
        .emitted_state_count = 5,
        .large_state_count = 2,
        .parse_action_list_count = 3,
        .small_parse_row_count = 1,
        .small_parse_map_count = 3,
        .lex_mode_count = 5,
        .lex_function_case_count = 5,
        .keyword_lex_function_case_count = 0,
        .large_character_set_count = 0,
        .external_lex_state_count = 0,
    };
    var upstream = local;
    upstream.serialized_state_count = 6;
    upstream.external_lex_state_count = 1;

    const diffs = try compareSummariesAlloc(std.testing.allocator, local, upstream);
    defer deinitDiffs(std.testing.allocator, diffs);

    try std.testing.expectEqual(@as(usize, 2), diffs.len);
    try std.testing.expectEqualStrings("serialized_state_count", diffs[0].field);
    try std.testing.expectEqual(DiffClassification.suspected_algorithm_gap, diffs[0].classification);
    try std.testing.expectEqualStrings("external_lex_state_count", diffs[1].field);
    try std.testing.expectEqual(DiffClassification.known_unsupported_surface, diffs[1].classification);
}

test "parseUpstreamParserCSummaryAlloc reads generated parser defines" {
    const parser_c =
        \\#define LANGUAGE_VERSION 14
        \\#define STATE_COUNT 8
        \\#define LARGE_STATE_COUNT 2
        \\#define SYMBOL_COUNT 6
        \\#define ALIAS_COUNT 1
        \\#define TOKEN_COUNT 3
        \\#define EXTERNAL_TOKEN_COUNT 0
        \\#define FIELD_COUNT 2
        \\#define PRODUCTION_ID_COUNT 4
        \\static const char * const ts_symbol_names[] = {
        \\  [0] = "end",
        \\};
        \\static const char * const ts_field_names[] = {
        \\  [0] = NULL,
        \\  [1] = "name",
        \\};
        \\static const uint32_t ts_small_parse_table_map[] = {
        \\  [0] = 0,
        \\  [1] = 4,
        \\  [2] = 4,
        \\};
        \\static const TSParseActionEntry ts_parse_actions[] = {
        \\  [0] = {.entry = {.count = 0, .reusable = false}},
        \\  [1] = {.entry = {.count = 1, .reusable = true}}, SHIFT(1),
        \\};
        \\static const TSCharacterRange ts_lex_character_set_0[] = {
        \\  { 1, 2 },
        \\};
        \\static bool ts_lex(TSLexer *lexer, TSStateId state) {
        \\  switch (state) {
        \\    case 0:
        \\      return true;
        \\    case 1:
        \\      return false;
        \\  }
        \\}
        \\static bool ts_lex_keywords(TSLexer *lexer, TSStateId state) {
        \\  switch (state) {
        \\    case 0:
        \\      return false;
        \\  }
        \\}
        \\static const TSLexerMode ts_lex_modes[1] = {
        \\};
    ;
    const summary = try parseUpstreamParserCSummaryAlloc(std.testing.allocator, "demo", parser_c, null);
    defer deinitSummary(std.testing.allocator, summary);

    try std.testing.expectEqual(@as(usize, 14), summary.language_version);
    try std.testing.expectEqual(@as(usize, 8), summary.serialized_state_count);
    try std.testing.expectEqual(@as(usize, 2), summary.large_state_count);
    try std.testing.expectEqual(@as(usize, 6), summary.symbol_count);
    try std.testing.expect(summary.symbol_order_hash != 0);
    try std.testing.expectEqual(@as(usize, 3), summary.token_count);
    try std.testing.expectEqual(@as(usize, 2), summary.field_count);
    try std.testing.expect(summary.field_names_hash != 0);
    try std.testing.expectEqual(@as(usize, 2), summary.small_parse_row_count);
    try std.testing.expectEqual(@as(usize, 2), summary.lex_function_case_count);
    try std.testing.expectEqual(@as(usize, 1), summary.keyword_lex_function_case_count);
    try std.testing.expectEqual(@as(usize, 1), summary.large_character_set_count);
}

test "parseUpstreamParserCSummaryAlloc hashes node-types JSON ignoring whitespace" {
    const parser_c =
        \\#define LANGUAGE_VERSION 15
        \\#define STATE_COUNT 1
        \\#define LARGE_STATE_COUNT 1
        \\#define SYMBOL_COUNT 1
        \\#define ALIAS_COUNT 0
        \\#define TOKEN_COUNT 1
        \\#define EXTERNAL_TOKEN_COUNT 0
        \\#define FIELD_COUNT 0
        \\#define PRODUCTION_ID_COUNT 0
    ;
    const left = try parseUpstreamParserCSummaryAlloc(std.testing.allocator, "demo", parser_c, "[ { \"type\": \"x\" } ]");
    defer deinitSummary(std.testing.allocator, left);
    const right = try parseUpstreamParserCSummaryAlloc(std.testing.allocator, "demo", parser_c, "[{\"type\":\"x\"}]");
    defer deinitSummary(std.testing.allocator, right);

    try std.testing.expect(left.node_types_hash != 0);
    try std.testing.expectEqual(left.node_types_hash, right.node_types_hash);
}

test "generateLocalSummaryAlloc summarizes a tiny grammar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const summary = try generateLocalSummaryAlloc(std.testing.allocator, path, .{});
    defer deinitSummary(std.testing.allocator, summary);

    try std.testing.expectEqualStrings("basic", summary.grammar_name);
    try std.testing.expect(summary.rule_count > 0);
    try std.testing.expect(summary.serialized_state_count > 0);
}

test "generateLocalPreparedIrSummaryAlloc summarizes preparation stages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const summary = try generateLocalPreparedIrSummaryAlloc(std.testing.allocator, path, .{});

    try std.testing.expect(summary.variable_count > 0);
    try std.testing.expect(summary.rule_count > 0);
    try std.testing.expect(summary.stage_order_hash != 0);
    try std.testing.expect(summary.prepared_variable_hash != 0);
    try std.testing.expect(summary.prepared_symbol_hash != 0);
    try std.testing.expect(summary.prepared_reserved_word_set_hash != 0);
    try std.testing.expect(summary.prepared_conflict_hash != 0);
    try std.testing.expect(summary.prepared_inline_hash != 0);
    try std.testing.expect(summary.prepared_supertype_hash != 0);
    try std.testing.expect(summary.prepared_word_token_hash != 0);
    try std.testing.expect(summary.extracted_syntax_variable_count > 0);
    try std.testing.expect(summary.extracted_extra_symbol_hash != 0);
    try std.testing.expect(summary.extracted_expected_conflict_hash != 0);
    try std.testing.expect(summary.extracted_inline_hash != 0);
    try std.testing.expect(summary.extracted_supertype_hash != 0);
    try std.testing.expect(summary.extracted_word_token_hash != 0);
    try std.testing.expect(summary.flattened_syntax_hash != 0);

    var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json.deinit();
    try writePreparedIrSummaryJson(&json.writer, summary, 0);
    const rendered = json.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"prepared_reserved_word_set_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"prepared_conflict_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"extracted_expected_conflict_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"extracted_word_token_hash\"") != null);

    var comparison_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer comparison_json.deinit();
    try writePreparedIrComparisonKeysJson(&comparison_json.writer, summary, 0);
    const comparison_rendered = comparison_json.written();
    try std.testing.expect(std.mem.indexOf(u8, comparison_rendered, "\"status\": \"upstream_oracle_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, comparison_rendered, "\"name\": \"prepared_variables\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, comparison_rendered, "\"name\": \"extracted_lexical_variables\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, comparison_rendered, "\"upstream_hash\": null") != null);
}

test "generateLocalPreparedIrSnapshotJsonAlloc writes diffable sections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalPreparedIrSnapshotJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"prepared_variables\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"local_stage_order\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"prepared_symbols\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"prepared_word_token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"prepared_reserved_word_sets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_lexical_variables\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_expected_conflicts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_variables_to_inline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_word_token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"flattened_syntax_variables\"") != null);
}

test "generateLocalPreparedIrSnapshotJsonAlloc writes immediate lexical metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.nestedMetadataGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalPreparedIrSnapshotJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_lexical_variables\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"immediate\": true") != null);
}

test "generateLocalRawGrammarSnapshotJsonAlloc writes raw grammar structure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalRawGrammarSnapshotJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"basic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rules\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extras\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"precedences\"") != null);
}

test "generateLocalParseStateDumpAlloc writes item-set states" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const dump = try generateLocalParseStateDumpAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "state 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "items:") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "transitions:") != null);
}

test "generateLocalParseStateDumpAlloc supports selected rule snapshots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const dump = try generateLocalParseStateDumpAlloc(std.testing.allocator, path, .{
        .report_states_for_rule = "expr",
    });
    defer std.testing.allocator.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "rule expr") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "actions:") != null);
}

test "generateLocalParseStateSummaryJsonAlloc writes item-set summary hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalParseStateSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"state_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"core_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lookahead_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"transition_hash\"") != null);
}

test "generateLocalItemSetSnapshotJsonAlloc writes selected item-set entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.parseTableTinyGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalItemSetSnapshotJsonAlloc(std.testing.allocator, path, .{
        .report_states_for_rule = "source_file",
    });
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"selected_rule\": \"source_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"comparison\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kernel_item_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"closure_item_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"completed_item_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reserved_lookahead_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"comparison_keys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"kernel_items\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"upstream_hash\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\": \"upstream_oracle_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"production_lhs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"production_step_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"at_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"origin\": \"kernel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"origin\": \"closure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lookaheads\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"following_reserved_word_set_id\"") != null);
}

test "generateLocalItemSetSnapshotJsonAlloc covers parity fixture shapes" {
    const FixtureCase = struct {
        name: []const u8,
        contents: []const u8,
    };
    const cases = [_]FixtureCase{
        .{
            .name = "nullable_suffix",
            .contents =
            \\{
            \\  "name": "nullable_suffix",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "STRING", "value": "a" },
            \\        { "type": "CHOICE", "members": [
            \\          { "type": "BLANK" },
            \\          { "type": "STRING", "value": "b" }
            \\        ] }
            \\      ]
            \\    }
            \\  }
            \\}
            ,
        },
        .{
            .name = "nested_repeats",
            .contents =
            \\{
            \\  "name": "nested_repeats",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "REPEAT",
            \\      "content": {
            \\        "type": "REPEAT1",
            \\        "content": { "type": "STRING", "value": "a" }
            \\      }
            \\    }
            \\  }
            \\}
            ,
        },
        .{
            .name = "dynamic_precedence",
            .contents = fixtures.parseTableDynamicPrecedenceGrammarJson().contents,
        },
        .{
            .name = "token_immediate",
            .contents =
            \\{
            \\  "name": "token_immediate",
            \\  "extras": [
            \\    { "type": "PATTERN", "value": "[ ]+" }
            \\  ],
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "STRING", "value": "a" },
            \\        { "type": "IMMEDIATE_TOKEN", "content": { "type": "STRING", "value": "b" } }
            \\      ]
            \\    }
            \\  }
            \\}
            ,
        },
    };

    inline for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "grammar.json",
            .data = case.contents,
        });

        const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
        defer std.testing.allocator.free(path);

        const json = try generateLocalItemSetSnapshotJsonAlloc(std.testing.allocator, path, .{});
        defer std.testing.allocator.free(json);

        try std.testing.expect(std.mem.indexOf(u8, json, "\"comparison\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"comparison_keys\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"states\"") != null);
    }

    const expected_conflict_json = try generateLocalItemSetSnapshotJsonAlloc(
        std.testing.allocator,
        "compat_targets/parse_table_expected_conflict/grammar.json",
        .{},
    );
    defer std.testing.allocator.free(expected_conflict_json);

    try std.testing.expect(std.mem.indexOf(u8, expected_conflict_json, "\"comparison\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, expected_conflict_json, "\"comparison_keys\"") != null);
}

test "generateLocalConflictSummaryJsonAlloc writes unresolved reason counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalConflictSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"declared_expected_conflict_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unused_expected_conflict_indexes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"chosen_actions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"chosen_candidate_shapes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unresolved_reasons\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unresolved_samples\"") != null);
}

test "generateLocalConflictSummaryJsonAlloc writes resolved precedence decisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.parseTablePrecedenceGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalConflictSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"chosen_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reduce\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shift_reduce\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_candidate_count\": 2") != null);
}

test "generateLocalConflictSummaryJsonAlloc writes associativity decisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.parseTableRightAssociativityGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalConflictSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"chosen_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shift\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shift_reduce\": 1") != null);
}

test "generateLocalConflictSummaryJsonAlloc writes reduce reduce precedence decisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.parseTableReduceReduceGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalConflictSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"chosen_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reduce\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reduce_reduce\"") != null);
}

test "generateLocalConflictSummaryJsonAlloc writes dynamic precedence decisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.parseTableDynamicPrecedenceGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalConflictSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"chosen_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dynamic_precedence\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shift_reduce\": 1") != null);
}

test "generateLocalConflictSummaryJsonAlloc distinguishes expected shift reduce conflicts" {
    const json = try generateLocalConflictSummaryJsonAlloc(
        std.testing.allocator,
        "compat_targets/parse_table_expected_conflict/grammar.json",
        .{},
    );
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"declared_expected_conflict_count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unused_expected_conflict_count\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shift_reduce_expected\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shift_reduce\": 0") != null);
}

test "generateLocalConflictSummaryJsonAlloc records unexpected shift reduce conflicts" {
    const json = try generateLocalConflictSummaryJsonAlloc(
        std.testing.allocator,
        "compat_targets/parse_table_conflict/grammar.json",
        .{},
    );
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"declared_expected_conflict_count\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unresolved_count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shift_reduce\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shift_reduce_expected\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reduce_parent_rules\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"candidate_shape\": \"shift_reduce\"") != null);
}

test "generateLocalTokenConflictSummaryJsonAlloc writes lexical conflict pairs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents =
        \\{
        \\  "name": "token_conflict_summary",
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "CHOICE",
        \\      "members": [
        \\        { "type": "SYMBOL", "name": "keyword" },
        \\        { "type": "SYMBOL", "name": "identifier" }
        \\      ]
        \\    },
        \\    "keyword": { "type": "STRING", "value": "let" },
        \\    "identifier": { "type": "PATTERN", "value": "[a-z]+" }
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalTokenConflictSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"variable_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"conflict_pair_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matches_same_string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pairs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"comparison_keys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"status_matrix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"concrete_pairs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\": \"upstream_oracle_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "identifier") != null);
}

test "generateLocalMinimizationSummaryJsonAlloc writes default and minimized counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalMinimizationSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"minimized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"merged_state_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"removed_action_entry_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lex_mode_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"primary_state_id_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"production_metadata_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"diff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lex_mode_changed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"production_metadata_changed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"comparison_keys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"table_counts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"primary_state_ids\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\": \"upstream_oracle_missing\"") != null);
}

test "generateLocalRegexSurfaceSummaryJsonAlloc writes pattern feature summaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents =
        \\{
        \\  "name": "regex_surface",
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "identifier" },
        \\    "identifier": {
        \\      "type": "PATTERN",
        \\      "value": "(?:\\p{XID_Start}|_)[A-Z\\d\\x41\\u0041_]{0,3}?",
        \\      "flags": "i"
        \\    }
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalRegexSurfaceSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"pattern_count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source_kind\": \"pattern\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"implicit_precedence\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"start_state\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"class_range\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shorthand_escape\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hex_escape\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unicode_escape\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unicode_property\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bounded_repeat\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"group_prefix\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lazy_quantifier\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_pattern\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\": \"supported_subset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_features\": []") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"alternation\": true, \"anchor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"flags\": \"i\"") != null);
}

test "generateLocalRegexSurfaceSummaryJsonAlloc marks unsupported regex constructs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents =
        \\{
        \\  "name": "regex_unsupported_surface",
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "identifier" },
        \\    "identifier": {
        \\      "type": "PATTERN",
        \\      "value": "^(?=a)\\1\\cA$"
        \\    }
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalRegexSurfaceSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_pattern\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"group_prefix\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_group_prefix\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"backreference\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"control_escape\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_features\": [\"anchor\", \"group_prefix\", \"backreference\", \"control_escape\"]") != null);
}

test "generateLocalRegexSurfaceSummaryJsonAlloc marks unsupported unicode properties and flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents =
        \\{
        \\  "name": "regex_unsupported_property_surface",
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "identifier" },
        \\    "identifier": {
        \\      "type": "PATTERN",
        \\      "value": "\\p{Script=Greek}+",
        \\      "flags": "m"
        \\    }
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalRegexSurfaceSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"unicode_property\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_unicode_property\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_flag\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_features\": [\"unsupported_unicode_property\", \"unsupported_flag\"]") != null);
}

test "generateLocalRegexSurfaceSummaryJsonAlloc classifies staged real grammar regex surfaces" {
    const paths = [_][]const u8{
        "compat_targets/tree_sitter_c/grammar.json",
        "compat_targets/tree_sitter_zig/grammar.json",
        "compat_targets/tree_sitter_rust/grammar.json",
        "compat_targets/tree_sitter_javascript/grammar.json",
        "compat_targets/tree_sitter_python/grammar.json",
        "compat_targets/tree_sitter_typescript/grammar.json",
    };

    for (paths) |path| {
        const json = try generateLocalRegexSurfaceSummaryJsonAlloc(std.testing.allocator, path, .{});
        defer std.testing.allocator.free(json);

        try std.testing.expect(std.mem.indexOf(u8, json, "\"pattern_count\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"variables\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"status\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"unsupported_features\"") != null);
    }
}

test "generateLocalLexTableSummaryJsonAlloc writes lexer table counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const json = try generateLocalLexTableSummaryJsonAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"table_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"transition_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_transition_range_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accepts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accept_symbol_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"eof_target_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"transition_target_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"skip_transition_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"large_range_transition_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"range_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"comparison_keys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"skip_transitions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\": \"upstream_oracle_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"keyword_unmapped_reserved_word_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"keyword_table\": null") != null);
}

test "writeLexTableSummaryJson writes keyword table counts" {
    const lexer_serialize = @import("../lexer/serialize.zig");
    const ranges = [_]lexer_serialize.SerializedCharacterRange{.{ .start = 'f', .end_inclusive = 'f' }};
    const transitions = [_]lexer_serialize.SerializedLexTransition{.{
        .ranges = ranges[0..],
        .next_state_id = 0,
        .skip = false,
    }};
    const states = [_]lexer_serialize.SerializedLexState{.{
        .accept_symbol = .{ .terminal = 1 },
        .transitions = transitions[0..],
    }};
    const serialized = parse_table_serialize.SerializedTable{
        .states = &.{},
        .blocked = false,
        .keyword_lex_table = .{
            .start_state_id = 0,
            .states = states[0..],
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeLexTableSummaryJson(&out.writer, serialized);
    const json = out.written();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"keyword_table\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"keyword_unmapped_reserved_word_count\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accepts\": [{ \"state\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accept_symbol_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"eof_target_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"transition_target_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"skip_transition_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"large_range_transition_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"keyword_table\"") != null);
}

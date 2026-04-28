const std = @import("std");
const extract_default_aliases = @import("../grammar/prepare/extract_default_aliases.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const flatten_grammar = @import("../grammar/prepare/flatten_grammar.zig");
const grammar_loader = @import("../grammar/loader.zig");
const grammar_ir = @import("../ir/grammar_ir.zig");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const node_type_pipeline = @import("../node_types/pipeline.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const raw_grammar = @import("../grammar/raw_grammar.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
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
    extracted_syntax_variable_count: usize,
    extracted_syntax_production_count: usize,
    extracted_syntax_step_count: usize,
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

fn hashLexicalGrammar(grammar: lexical_ir.LexicalGrammar) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (grammar.variables) |variable| {
        hashString(&hasher, variable.name);
        hashTag(&hasher, @tagName(variable.kind));
        hashU32(&hasher, variable.rule);
        hashI32(&hasher, variable.implicit_precedence);
        hashU32(&hasher, variable.start_state);
        hashTag(&hasher, @tagName(variable.source_kind));
    }
    for (grammar.separators) |separator| hashU32(&hasher, separator);
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
    try writeUsizeField(writer, indent + 2, "extracted_syntax_variable_count", summary.extracted_syntax_variable_count, true);
    try writeUsizeField(writer, indent + 2, "extracted_syntax_production_count", summary.extracted_syntax_production_count, true);
    try writeUsizeField(writer, indent + 2, "extracted_syntax_step_count", summary.extracted_syntax_step_count, true);
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

    try writer.writeAll("  \"extracted_lexical_variables\": [");
    if (extracted.lexical.variables.len != 0) try writer.writeByte('\n');
    for (extracted.lexical.variables, 0..) |variable, index| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, variable.name);
        try writer.print(
            ", \"kind\": \"{s}\", \"source_kind\": \"{s}\", \"rule\": {d}, \"implicit_precedence\": {d}, \"start_state\": {d} }}",
            .{ @tagName(variable.kind), @tagName(variable.source_kind), variable.rule, variable.implicit_precedence, variable.start_state },
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
        .extracted_syntax_variable_count = extracted.syntax.variables.len,
        .extracted_syntax_production_count = countProductions(extracted.syntax.variables),
        .extracted_syntax_step_count = countSteps(extracted.syntax.variables),
        .extracted_lexical_variable_count = extracted.lexical.variables.len,
        .extracted_lexical_separator_count = extracted.lexical.separators.len,
        .extracted_lexical_hash = hashLexicalGrammar(extracted.lexical),
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
    try writer.print("\"0x{x}\"", .{value});
    if (comma) try writer.writeByte(',');
    try writer.writeByte('\n');
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
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const summary = try generateLocalPreparedIrSummaryAlloc(std.testing.allocator, path, .{});

    try std.testing.expect(summary.variable_count > 0);
    try std.testing.expect(summary.rule_count > 0);
    try std.testing.expect(summary.stage_order_hash != 0);
    try std.testing.expect(summary.prepared_variable_hash != 0);
    try std.testing.expect(summary.extracted_syntax_variable_count > 0);
    try std.testing.expect(summary.flattened_syntax_hash != 0);
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_lexical_variables\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_expected_conflicts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_variables_to_inline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extracted_word_token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"flattened_syntax_variables\"") != null);
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

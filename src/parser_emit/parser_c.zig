const std = @import("std");
const parse_actions = @import("../parse_table/actions.zig");
const serialize = @import("../parse_table/serialize.zig");
const lexer_serialize = @import("../lexer/serialize.zig");
const lexer_emit_c = @import("../lexer/emit_c.zig");
const syntax_grammar = @import("../ir/syntax_grammar.zig");
const common = @import("common.zig");
const compat = @import("compat.zig");
const compile_smoke = @import("../compat/compile_smoke.zig");
const optimize = @import("optimize.zig");

/// Errors produced while rendering parser C into an owned buffer or writer.
pub const EmitError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Row-sharing summary for one emitted parse-table section.
pub const RowSharingStats = struct {
    total_rows: usize,
    empty_rows: usize,
    unique_non_empty_rows: usize,
    shared_non_empty_rows: usize,
    emitted_array_definitions: usize,
};

/// Summary of parser C emission after optional serialized-table optimization.
pub const EmissionStats = struct {
    state_count: usize,
    merged_state_count: usize,
    blocked: bool,
    action_entry_count: usize,
    goto_entry_count: usize,
    unresolved_entry_count: usize,
    action_rows: RowSharingStats,
    goto_rows: RowSharingStats,
    unresolved_rows: RowSharingStats,
};

/// Render parser C into an owned buffer using the default emission options.
pub fn emitParserCAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]const u8 {
    return try emitParserCAllocWithOptions(allocator, serialized, .{});
}

/// Render parser C into an owned buffer using explicit emission options.
pub fn emitParserCAllocWithOptions(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
    options: optimize.Options,
) EmitError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeParserCWithOptions(&out.writer, allocator, serialized, options);
    return try out.toOwnedSlice();
}

/// Collect emission statistics using the default optimization options.
pub fn collectEmissionStats(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) std.mem.Allocator.Error!EmissionStats {
    return try collectEmissionStatsWithOptions(allocator, serialized, .{});
}

/// Collect emission statistics using explicit optimization options.
pub fn collectEmissionStatsWithOptions(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
    options: optimize.Options,
) std.mem.Allocator.Error!EmissionStats {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const compacted = try optimize.prepareSerializedTableAlloc(arena.allocator(), serialized, options);
    const action_owners = try collectStateArrayOwners(allocator, serialize.SerializedActionEntry, compacted.states, stateActions);
    defer allocator.free(action_owners);
    const goto_owners = try collectStateArrayOwners(allocator, serialize.SerializedGotoEntry, compacted.states, stateGotos);
    defer allocator.free(goto_owners);
    const unresolved_owners = try collectStateArrayOwners(allocator, serialize.SerializedUnresolvedEntry, compacted.states, stateUnresolved);
    defer allocator.free(unresolved_owners);

    var action_entry_count: usize = 0;
    var goto_entry_count: usize = 0;
    var unresolved_entry_count: usize = 0;
    for (compacted.states) |serialized_state| {
        action_entry_count += serialized_state.actions.len;
        goto_entry_count += serialized_state.gotos.len;
        unresolved_entry_count += serialized_state.unresolved.len;
    }

    return .{
        .state_count = compacted.states.len,
        .merged_state_count = serialized.states.len - compacted.states.len,
        .blocked = compacted.blocked,
        .action_entry_count = action_entry_count,
        .goto_entry_count = goto_entry_count,
        .unresolved_entry_count = unresolved_entry_count,
        .action_rows = collectRowSharingStats(serialize.SerializedActionEntry, compacted.states, action_owners, stateActions, true),
        .goto_rows = collectRowSharingStats(serialize.SerializedGotoEntry, compacted.states, goto_owners, stateGotos, true),
        .unresolved_rows = collectRowSharingStats(serialize.SerializedUnresolvedEntry, compacted.states, unresolved_owners, stateUnresolved, false),
    };
}

/// Write parser C to an existing writer using the default emission options.
pub fn writeParserC(
    writer: anytype,
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) !void {
    return try writeParserCWithOptions(writer, allocator, serialized, .{});
}

/// Write parser C to an existing writer using explicit emission options.
pub fn writeParserCWithOptions(
    writer: anytype,
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
    options: optimize.Options,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const compacted = try optimize.prepareSerializedTableAlloc(arena.allocator(), serialized, options);
    const compatibility = compat.currentRuntimeCompatibility();
    const has_unresolved = hasUnresolvedStateRows(compacted.states);
    const emitted_symbols = try collectEmittedSymbols(allocator, compacted);
    defer deinitEmittedSymbols(allocator, emitted_symbols);
    const parse_action_list = if (compacted.parse_action_list.len > 0)
        compacted.parse_action_list
    else
        try serialize.buildParseActionListAlloc(arena.allocator(), compacted.states, compacted.productions);
    const unresolved_owners = try collectStateArrayOwners(arena.allocator(), serialize.SerializedUnresolvedEntry, compacted.states, stateUnresolved);
    const small_parse_table = if (compacted.small_parse_table.rows.len > 0 or compacted.small_parse_table.map.len > 0)
        compacted.small_parse_table
    else
        try serialize.buildSmallParseTableAlloc(arena.allocator(), compacted.states, serializedLargeStateCount(compacted), parse_action_list, compacted.productions);
    const runtime_lex = try buildRuntimeLexTableAlloc(arena.allocator(), compacted.lex_tables);

    try compat.writeContractPrelude(writer, compatibility);
    if (has_unresolved) try writer.writeAll("#include <string.h>\n\n");
    try compat.writeCompilerOptimizationPragmas(writer, runtime_lex.table.states.len);
    try compat.writeContractTypesAndConstants(writer, compatibility);
    if (options.glr_loop) {
        try writer.writeAll("#define GEN_Z_SITTER_ENABLE_GLR_LOOP 1\n\n");
        try writeGlrVersionStorage(writer);
    }
    if (has_unresolved) try writeUnresolvedEntryType(writer);
    try writer.print("#define STATE_COUNT {d}\n", .{compacted.states.len});
    const large_state_count_value = serializedLargeStateCount(compacted);
    try writer.print("#define LARGE_STATE_COUNT {d}\n", .{large_state_count_value});
    try writer.print("#define SYMBOL_COUNT {d}\n", .{emitted_symbols.len});
    try writer.print("#define TOKEN_COUNT {d}\n", .{tokenCount(emitted_symbols)});
    try writer.print("#define EXTERNAL_TOKEN_COUNT {d}\n", .{externalTokenCount(emitted_symbols)});
    try writer.print("#define PRODUCTION_ID_COUNT {d}\n", .{compacted.productions.len});
    try writer.print("#define FIELD_COUNT {d}\n", .{compacted.field_map.names.len});
    try writer.print("#define ALIAS_COUNT {d}\n", .{aliasSymbolCount(emitted_symbols)});
    try writer.print("#define MAX_ALIAS_SEQUENCE_LENGTH {d}\n", .{maxAliasSequenceLength(compacted)});
    try writer.print("#define MAX_RESERVED_WORD_SET_SIZE {d}\n\n", .{compacted.reserved_words.max_size});

    // Grammar lowering validates `word_token`; by emission it must have a runtime symbol ID.
    const keyword_capture_id: u16 = if (compacted.word_token) |wt|
        symbolIdForRef(emitted_symbols, wt) orelse unreachable
    else
        0;

    if (runtime_lex.table.states.len == 0) {
        try writer.writeAll("static bool ts_lex(TSLexer *lexer, TSStateId state) {\n");
        try writer.writeAll("  (void)lexer;\n");
        try writer.writeAll("  (void)state;\n");
        try writer.writeAll("  return false;\n");
        try writer.writeAll("}\n\n");
    } else {
        const resolver_context = RuntimeSymbolResolverContext{ .symbols = emitted_symbols };
        try lexer_emit_c.emitLexFunctionWithResolverAlloc(
            arena.allocator(),
            writer,
            "ts_lex",
            runtime_lex.table,
            .{
                .context = &resolver_context,
                .resolve = resolveRuntimeSymbol,
            },
        );
    }
    if (compacted.keyword_lex_table) |keyword_lex_table| {
        const resolver_context = RuntimeSymbolResolverContext{ .symbols = emitted_symbols };
        try lexer_emit_c.emitLexFunctionWithResolverAlloc(
            arena.allocator(),
            writer,
            "ts_lex_keywords",
            keyword_lex_table,
            .{
                .context = &resolver_context,
                .resolve = resolveRuntimeSymbol,
            },
        );
    }
    try writer.writeAll("static const char * const ts_symbol_names[SYMBOL_COUNT] = {\n");
    for (emitted_symbols, 0..) |symbol, index| {
        try writer.print("  [{d}] = \"", .{index});
        try writeCStringLiteralContents(writer, symbol.label);
        try writer.writeAll("\",\n");
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSSymbolMetadata ts_symbol_metadata[SYMBOL_COUNT] = {\n");
    for (emitted_symbols, 0..) |symbol, index| {
        try writer.print("  [{d}] = {{ .visible = {}, .named = {}, .supertype = {} }},\n", .{ index, symbol.visible, symbol.named, symbol.supertype });
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSSymbol ts_symbol_map[SYMBOL_COUNT] = {\n");
    for (emitted_symbols, 0..) |symbol, index| {
        try writer.print("  [{d}] = {d},\n", .{ index, symbol.public_symbol });
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const char * const ts_field_names[FIELD_COUNT + 1] = {\n");
    try writer.writeAll("  [0] = \"\",\n");
    for (compacted.field_map.names) |field| {
        try writer.print("  [{d}] = \"", .{field.id});
        try writeCStringLiteralContents(writer, field.name);
        try writer.writeAll("\",\n");
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSFieldMapEntry ts_field_map_entries[] = {\n");
    if (compacted.field_map.entries.len == 0) {
        try writer.writeAll("  { 0 },\n");
    } else {
        for (compacted.field_map.entries, 0..) |entry, index| {
            try writer.print(
                "  [{d}] = {{ .field_id = {d}, .child_index = {d}, .inherited = {} }},\n",
                .{ index, entry.field_id, entry.child_index, entry.inherited },
            );
        }
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSMapSlice ts_field_map_slices[] = {\n");
    if (compacted.field_map.slices.len == 0) {
        try writer.writeAll("  { 0 },\n");
    } else {
        for (compacted.field_map.slices, 0..) |slice, index| {
            try writer.print("  [{d}] = {{ .index = {d}, .length = {d} }},\n", .{ index, slice.index, slice.length });
        }
    }
    try writer.writeAll("};\n\n");

    try writeNonTerminalAliasMap(writer, allocator, emitted_symbols, compacted.alias_sequences);
    try writer.writeAll("static const TSSymbol ts_alias_sequences[][MAX_ALIAS_SEQUENCE_LENGTH > 0 ? MAX_ALIAS_SEQUENCE_LENGTH : 1] = {\n");
    if (compacted.productions.len == 0) {
        try writer.writeAll("  { 0 },\n");
    } else {
        for (compacted.productions, 0..) |_, production_id| {
            try writer.print("  [{d}] = {{", .{production_id});
            const sequence_len = maxAliasSequenceLength(compacted);
            if (sequence_len == 0) {
                try writer.writeAll(" 0");
            } else {
                for (0..sequence_len) |step_index| {
                    const alias_symbol_id = aliasSymbolIdForPosition(emitted_symbols, compacted.alias_sequences, production_id, step_index) orelse 0;
                    if (step_index > 0) try writer.writeByte(',');
                    try writer.print(" {d}", .{alias_symbol_id});
                }
            }
            try writer.writeAll(" },\n");
        }
    }
    try writer.writeAll("};\n\n");
    try writer.writeAll("static const TSStateId ts_primary_state_ids[STATE_COUNT] = {\n");
    for (compacted.states, 0..) |serialized_state, index| {
        const primary_state_id = if (index < compacted.primary_state_ids.len)
            compacted.primary_state_ids[index]
        else
            serialized_state.id;
        try writer.print("  [{d}] = {d},\n", .{ index, primary_state_id });
    }
    try writer.writeAll("};\n\n");
    try writeSupertypeTables(writer, emitted_symbols, compacted.supertype_map);

    try writer.writeAll("static const uint16_t ts_parse_table[LARGE_STATE_COUNT][SYMBOL_COUNT] = {\n");
    for (compacted.states[0..large_state_count_value], 0..) |serialized_state, index| {
        try writer.print("  [STATE({d})] = {{\n", .{index});
        for (serialized_state.gotos) |entry| {
            const symbol_id = symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory;
            try writer.print("    [{d}] = STATE({d}),\n", .{ symbol_id, entry.state });
        }
        for (serialized_state.actions) |entry| {
            const symbol_id = symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory;
            const action_index = serialize.parseActionListIndexForActionEntry(parse_action_list, entry, compacted.productions) orelse return error.OutOfMemory;
            try writer.print("    [{d}] = ACTIONS({d}),\n", .{ symbol_id, action_index });
        }
        try writer.writeAll("  },\n");
    }
    try writer.writeAll("};\n\n");

    if (large_state_count_value < compacted.states.len) {
        try writer.writeAll("static const uint16_t ts_small_parse_table[] = {\n");
        for (small_parse_table.rows) |row| {
            try writer.print("  [{d}] = {d},\n", .{ row.offset, row.groups.len });
            for (row.groups) |group| {
                switch (group.kind) {
                    .state => try writer.print("  STATE({d}), {d},", .{ group.value, group.symbols.len }),
                    .action => try writer.print("  ACTIONS({d}), {d},", .{ group.value, group.symbols.len }),
                }
                for (group.symbols) |symbol| {
                    const symbol_id = symbolIdForRef(emitted_symbols, symbol) orelse return error.OutOfMemory;
                    try writer.print(" {d},", .{symbol_id});
                }
                try writer.writeByte('\n');
            }
        }
        try writer.writeAll("};\n\n");
        try writer.writeAll("static const uint32_t ts_small_parse_table_map[] = {\n");
        for (small_parse_table.map, large_state_count_value..) |offset, index| {
            try writer.print("  [SMALL_STATE({d})] = {d},\n", .{ index, offset });
        }
        try writer.writeAll("};\n\n");
    }

    try writer.writeAll("static const TSParseActionEntry ts_parse_actions[] = {\n");
    for (parse_action_list) |entry| {
        try writer.print("  [{d}] = {{ .entry = {{ .count = {d}, .reusable = {} }} }},", .{ entry.index, entry.actions.len, entry.reusable });
        if (entry.actions.len == 0) {
            try writer.writeByte('\n');
        } else {
            for (entry.actions) |action| {
                try writer.writeByte(' ');
                try writeRuntimeAction(writer, emitted_symbols, action);
                try writer.writeByte(',');
            }
            try writer.writeByte('\n');
        }
    }
    try writer.writeAll("};\n\n");

    if (options.glr_loop) {
        try writeGlrParseHelpers(writer, large_state_count_value < compacted.states.len);
        try writeGlrActionDispatch(writer);
    }

    if (has_unresolved) {
        for (compacted.states, 0..) |serialized_state, index| {
            if (serialized_state.unresolved.len == 0 or unresolved_owners[index] != index) continue;
            try writer.print("static const TSUnresolvedEntry ts_state_{d}_unresolved[] = {{\n", .{index});
            for (serialized_state.unresolved) |entry| {
                try writeUnresolvedEntry(writer, emitted_symbols, parse_action_list, compacted.productions, entry);
            }
            try writer.writeAll("};\n\n");
        }
    }

    try writer.writeAll("static const TSLexerMode ts_lex_modes[STATE_COUNT] = {\n");
    for (compacted.states, 0..) |_, index| {
        const mode = if (index < compacted.lex_modes.len)
            compacted.lex_modes[index]
        else
            lexer_serialize.SerializedLexMode{ .lex_state = 0 };
        const lex_state = runtimeLexStateForMode(runtime_lex.lex_state_starts, mode.lex_state);
        try writer.print(
            "  [{d}] = {{ .lex_state = {d}, .external_lex_state = {d}, .reserved_word_set_id = {d} }},\n",
            .{ index, lex_state, mode.external_lex_state, mode.reserved_word_set_id },
        );
    }
    try writer.writeAll("};\n\n");
    if (has_unresolved) try writeUnresolvedAccessors(writer, compacted.states, unresolved_owners);
    if (options.glr_loop and has_unresolved) try writeGlrUnresolvedForkHelpers(writer);
    if (options.glr_loop) try writeGlrVersionCondenseHelpers(writer);
    if (options.glr_loop) try writeGlrInputLexerHelpers(writer);
    if (options.glr_loop) try writeGlrVersionStepLoop(writer, has_unresolved);
    if (options.glr_loop) try writeGlrMainParseFunction(writer);
    try writeReservedWords(writer, emitted_symbols, compacted.reserved_words);
    try writeExternalScannerTables(writer, emitted_symbols, compacted.grammar_name, compacted.external_scanner);

    try writer.writeAll("static const TSLanguage ts_language = {\n");
    try writer.writeAll("  .abi_version = LANGUAGE_VERSION,\n");
    try writer.writeAll("  .symbol_count = SYMBOL_COUNT,\n");
    try writer.writeAll("  .alias_count = ALIAS_COUNT,\n");
    try writer.writeAll("  .token_count = TOKEN_COUNT,\n");
    try writer.writeAll("  .external_token_count = EXTERNAL_TOKEN_COUNT,\n");
    try writer.writeAll("  .state_count = STATE_COUNT,\n");
    try writer.writeAll("  .large_state_count = LARGE_STATE_COUNT,\n");
    try writer.writeAll("  .production_id_count = PRODUCTION_ID_COUNT,\n");
    try writer.writeAll("  .field_count = FIELD_COUNT,\n");
    try writer.writeAll("  .max_alias_sequence_length = MAX_ALIAS_SEQUENCE_LENGTH,\n");
    try writer.writeAll("  .parse_table = &ts_parse_table[0][0],\n");
    if (large_state_count_value < compacted.states.len) {
        try writer.writeAll("  .small_parse_table = ts_small_parse_table,\n");
        try writer.writeAll("  .small_parse_table_map = ts_small_parse_table_map,\n");
    }
    try writer.writeAll("  .parse_actions = ts_parse_actions,\n");
    try writer.writeAll("  .symbol_names = ts_symbol_names,\n");
    try writer.writeAll("  .field_names = ts_field_names,\n");
    try writer.writeAll("  .field_map_slices = ts_field_map_slices,\n");
    try writer.writeAll("  .field_map_entries = ts_field_map_entries,\n");
    try writer.writeAll("  .symbol_metadata = ts_symbol_metadata,\n");
    try writer.writeAll("  .public_symbol_map = ts_symbol_map,\n");
    try writer.writeAll("  .alias_map = ts_non_terminal_alias_map,\n");
    try writer.writeAll("  .alias_sequences = &ts_alias_sequences[0][0],\n");
    try writer.writeAll("  .lex_modes = ts_lex_modes,\n");
    try writer.writeAll("  .lex_fn = ts_lex,\n");
    if (compacted.keyword_lex_table != null) {
        try writer.writeAll("  .keyword_lex_fn = ts_lex_keywords,\n");
    } else {
        try writer.writeAll("  .keyword_lex_fn = NULL,\n");
    }
    try writer.print("  .keyword_capture_token = {d},\n", .{keyword_capture_id});
    if (externalTokenCount(emitted_symbols) != 0) {
        try writer.writeAll("  .external_scanner = {\n");
        if (compacted.external_scanner.states.len != 0) {
            try writer.writeAll("    .states = &ts_external_scanner_states[0][0],\n");
        }
        try writer.writeAll("    .symbol_map = ts_external_scanner_symbol_map,\n");
        try writer.writeAll("    .create = ");
        try writeExternalScannerFunctionName(writer, compacted.grammar_name, "create");
        try writer.writeAll(",\n");
        try writer.writeAll("    .destroy = ");
        try writeExternalScannerFunctionName(writer, compacted.grammar_name, "destroy");
        try writer.writeAll(",\n");
        try writer.writeAll("    .scan = ");
        try writeExternalScannerFunctionName(writer, compacted.grammar_name, "scan");
        try writer.writeAll(",\n");
        try writer.writeAll("    .serialize = ");
        try writeExternalScannerFunctionName(writer, compacted.grammar_name, "serialize");
        try writer.writeAll(",\n");
        try writer.writeAll("    .deserialize = ");
        try writeExternalScannerFunctionName(writer, compacted.grammar_name, "deserialize");
        try writer.writeAll(",\n");
        try writer.writeAll("  },\n");
    }
    try writer.writeAll("  .primary_state_ids = ts_primary_state_ids,\n");
    try writer.writeAll("  .name = \"");
    try writeCStringLiteralContents(writer, compacted.grammar_name);
    try writer.writeAll("\",\n");
    try writer.print("  .supertype_count = {d},\n", .{compacted.supertype_map.symbols.len});
    if (compacted.supertype_map.symbols.len != 0) {
        try writer.writeAll("  .supertype_symbols = ts_supertype_symbols,\n");
        try writer.writeAll("  .supertype_map_slices = ts_supertype_map_slices,\n");
        try writer.writeAll("  .supertype_map_entries = ts_supertype_map_entries,\n");
    }
    if (compacted.reserved_words.sets.len > 1) {
        try writer.writeAll("  .reserved_words = &ts_reserved_words[0][0],\n");
    }
    try writer.print("  .max_reserved_word_set_size = {d},\n", .{compacted.reserved_words.max_size});
    try writer.print(
        "  .metadata = {{ .major_version = {d}, .minor_version = {d}, .patch_version = {d} }},\n",
        .{ compacted.grammar_version[0], compacted.grammar_version[1], compacted.grammar_version[2] },
    );
    try writer.writeAll("};\n\n");
    try writer.writeAll("const TSLanguage *tree_sitter_generated(void) {\n");
    try writer.writeAll("  return &ts_language;\n");
    try writer.writeAll("}\n");
}

fn writeRuntimeAction(
    writer: anytype,
    symbols: []const EmittedSymbol,
    action: serialize.SerializedParseAction,
) !void {
    switch (action.kind) {
        .shift => try writer.print(
            "{{ .action = {{ .shift = {{ .type = TSParseActionTypeShift, .state = {d}, .extra = {}, .repetition = {} }} }} }}",
            .{ action.state, action.extra, action.repetition },
        ),
        .reduce => {
            const symbol_id = symbolIdForRef(symbols, action.symbol) orelse 0;
            try writer.print(
                "{{ .action = {{ .reduce = {{ .type = TSParseActionTypeReduce, .child_count = {d}, .symbol = {d}, .dynamic_precedence = {d}, .production_id = {d} }} }} }}",
                .{ action.child_count, symbol_id, action.dynamic_precedence, action.production_id },
            );
        },
        .accept => try writer.writeAll("{ .action = { .type = TSParseActionTypeAccept } }"),
        .recover => try writer.writeAll("{ .action = { .type = TSParseActionTypeRecover } }"),
    }
}

fn writeGlrVersionStorage(writer: anytype) !void {
    try writer.writeAll("#define GEN_Z_SITTER_MAX_PARSE_VERSIONS 8\n\n");
    try writer.writeAll("#define GEN_Z_SITTER_MAX_PARSE_STACK_DEPTH 256\n\n");
    try writer.writeAll("#define GEN_Z_SITTER_MAX_VALUE_STACK_DEPTH 256\n\n");
    try writer.writeAll("#define GEN_Z_SITTER_MAX_GENERATED_NODES 256\n\n");
    try writer.writeAll("#define GEN_Z_SITTER_NO_NODE UINT16_MAX\n\n");
    try writer.writeAll("#define GEN_Z_SITTER_MAX_ERROR_COST_DIFFERENCE 3\n\n");
    try writer.writeAll("#define GEN_Z_SITTER_MAX_RECOVERY_ATTEMPTS 8\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  TSSymbol symbol;\n");
    try writer.writeAll("  uint32_t start_byte;\n");
    try writer.writeAll("  uint32_t end_byte;\n");
    try writer.writeAll("  uint16_t production_id;\n");
    try writer.writeAll("  uint16_t child_count;\n");
    try writer.writeAll("  uint16_t first_child;\n");
    try writer.writeAll("} TSGeneratedNode;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  bool accepted;\n");
    try writer.writeAll("  uint32_t consumed_bytes;\n");
    try writer.writeAll("  uint16_t root_node;\n");
    try writer.writeAll("  uint16_t node_count;\n");
    try writer.writeAll("  uint32_t error_count;\n");
    try writer.writeAll("  int32_t dynamic_precedence;\n");
    try writer.writeAll("  TSGeneratedNode nodes[GEN_Z_SITTER_MAX_GENERATED_NODES];\n");
    try writer.writeAll("} TSGeneratedParseResult;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  TSSymbol symbol;\n");
    try writer.writeAll("  uint32_t start_byte;\n");
    try writer.writeAll("  uint32_t end_byte;\n");
    try writer.writeAll("  uint16_t production_id;\n");
    try writer.writeAll("  uint16_t child_count;\n");
    try writer.writeAll("  uint16_t node_id;\n");
    try writer.writeAll("} TSGeneratedValue;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  TSStateId state;\n");
    try writer.writeAll("  TSStateId stack[GEN_Z_SITTER_MAX_PARSE_STACK_DEPTH];\n");
    try writer.writeAll("  TSGeneratedValue values[GEN_Z_SITTER_MAX_VALUE_STACK_DEPTH];\n");
    try writer.writeAll("  TSGeneratedNode nodes[GEN_Z_SITTER_MAX_GENERATED_NODES];\n");
    try writer.writeAll("  uint16_t stack_len;\n");
    try writer.writeAll("  uint16_t value_len;\n");
    try writer.writeAll("  uint16_t node_count;\n");
    try writer.writeAll("  uint32_t byte_offset;\n");
    try writer.writeAll("  uint32_t error_count;\n");
    try writer.writeAll("  int32_t dynamic_precedence;\n");
    try writer.writeAll("  bool shifted;\n");
    try writer.writeAll("  bool active;\n");
    try writer.writeAll("} TSGeneratedParseVersion;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  TSGeneratedParseVersion versions[GEN_Z_SITTER_MAX_PARSE_VERSIONS];\n");
    try writer.writeAll("  uint16_t count;\n");
    try writer.writeAll("} TSGeneratedParseVersionSet;\n\n");
    try writer.writeAll("static void ts_generated_parse_versions_init(TSGeneratedParseVersionSet *set, TSStateId start_state) {\n");
    try writer.writeAll("  set->count = 1;\n");
    try writer.writeAll("  for (uint16_t i = 0; i < GEN_Z_SITTER_MAX_PARSE_VERSIONS; i++) {\n");
    try writer.writeAll("    set->versions[i].state = 0;\n");
    try writer.writeAll("    set->versions[i].stack_len = 0;\n");
    try writer.writeAll("    set->versions[i].value_len = 0;\n");
    try writer.writeAll("    set->versions[i].node_count = 0;\n");
    try writer.writeAll("    set->versions[i].byte_offset = 0;\n");
    try writer.writeAll("    set->versions[i].error_count = 0;\n");
    try writer.writeAll("    set->versions[i].dynamic_precedence = 0;\n");
    try writer.writeAll("    set->versions[i].shifted = false;\n");
    try writer.writeAll("    set->versions[i].active = false;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  set->versions[0].state = start_state;\n");
    try writer.writeAll("  set->versions[0].stack[0] = start_state;\n");
    try writer.writeAll("  set->versions[0].stack_len = 1;\n");
    try writer.writeAll("  set->versions[0].active = true;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_version_push_state(TSGeneratedParseVersion *version, TSStateId state) {\n");
    try writer.writeAll("  if (version->stack_len >= GEN_Z_SITTER_MAX_PARSE_STACK_DEPTH) return false;\n");
    try writer.writeAll("  version->stack[version->stack_len++] = state;\n");
    try writer.writeAll("  version->state = state;\n");
    try writer.writeAll("  return true;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_version_push_node(TSGeneratedParseVersion *version, TSGeneratedNode node, uint16_t *out_node_id) {\n");
    try writer.writeAll("  if (version->node_count >= GEN_Z_SITTER_MAX_GENERATED_NODES) return false;\n");
    try writer.writeAll("  *out_node_id = version->node_count;\n");
    try writer.writeAll("  version->nodes[version->node_count++] = node;\n");
    try writer.writeAll("  return true;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_version_push_value(TSGeneratedParseVersion *version, TSGeneratedValue value) {\n");
    try writer.writeAll("  if (version->value_len >= GEN_Z_SITTER_MAX_VALUE_STACK_DEPTH) return false;\n");
    try writer.writeAll("  version->values[version->value_len++] = value;\n");
    try writer.writeAll("  return true;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_version_reduce_value(TSGeneratedParseVersion *version, const TSParseAction *action) {\n");
    try writer.writeAll("  if (version->value_len < action->reduce.child_count) return false;\n");
    try writer.writeAll("  uint16_t first_child = version->value_len - action->reduce.child_count;\n");
    try writer.writeAll("  uint32_t start_byte = action->reduce.child_count > 0 ? version->values[first_child].start_byte : version->byte_offset;\n");
    try writer.writeAll("  uint32_t end_byte = action->reduce.child_count > 0 ? version->values[version->value_len - 1].end_byte : version->byte_offset;\n");
    try writer.writeAll("  uint16_t first_child_node = action->reduce.child_count > 0 ? version->values[first_child].node_id : GEN_Z_SITTER_NO_NODE;\n");
    try writer.writeAll("  uint16_t node_id = GEN_Z_SITTER_NO_NODE;\n");
    try writer.writeAll("  if (!ts_generated_version_push_node(version, (TSGeneratedNode){\n");
    try writer.writeAll("    .symbol = action->reduce.symbol,\n");
    try writer.writeAll("    .start_byte = start_byte,\n");
    try writer.writeAll("    .end_byte = end_byte,\n");
    try writer.writeAll("    .production_id = action->reduce.production_id,\n");
    try writer.writeAll("    .child_count = action->reduce.child_count,\n");
    try writer.writeAll("    .first_child = first_child_node,\n");
    try writer.writeAll("  }, &node_id)) return false;\n");
    try writer.writeAll("  version->value_len = first_child;\n");
    try writer.writeAll("  return ts_generated_version_push_value(version, (TSGeneratedValue){\n");
    try writer.writeAll("    .symbol = action->reduce.symbol,\n");
    try writer.writeAll("    .start_byte = start_byte,\n");
    try writer.writeAll("    .end_byte = end_byte,\n");
    try writer.writeAll("    .production_id = action->reduce.production_id,\n");
    try writer.writeAll("    .child_count = action->reduce.child_count,\n");
    try writer.writeAll("    .node_id = node_id,\n");
    try writer.writeAll("  });\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_version_push_shift_value(TSGeneratedParseVersion *version, TSSymbol symbol, uint32_t advance_bytes) {\n");
    try writer.writeAll("  uint16_t node_id = GEN_Z_SITTER_NO_NODE;\n");
    try writer.writeAll("  if (!ts_generated_version_push_node(version, (TSGeneratedNode){\n");
    try writer.writeAll("    .symbol = symbol,\n");
    try writer.writeAll("    .start_byte = version->byte_offset,\n");
    try writer.writeAll("    .end_byte = version->byte_offset + advance_bytes,\n");
    try writer.writeAll("    .production_id = 0,\n");
    try writer.writeAll("    .child_count = 0,\n");
    try writer.writeAll("    .first_child = GEN_Z_SITTER_NO_NODE,\n");
    try writer.writeAll("  }, &node_id)) return false;\n");
    try writer.writeAll("  return ts_generated_version_push_value(version, (TSGeneratedValue){\n");
    try writer.writeAll("    .symbol = symbol,\n");
    try writer.writeAll("    .start_byte = version->byte_offset,\n");
    try writer.writeAll("    .end_byte = version->byte_offset + advance_bytes,\n");
    try writer.writeAll("    .production_id = 0,\n");
    try writer.writeAll("    .child_count = 0,\n");
    try writer.writeAll("    .node_id = node_id,\n");
    try writer.writeAll("  });\n");
    try writer.writeAll("}\n\n");
}

fn writeGlrParseHelpers(writer: anytype, has_small_parse_table: bool) !void {
    try writer.writeAll("static uint16_t ts_generated_parse_table_entry(TSStateId state, TSSymbol symbol) {\n");
    try writer.writeAll("  if (state < LARGE_STATE_COUNT) {\n");
    try writer.writeAll("    return ts_parse_table[state][symbol];\n");
    try writer.writeAll("  }\n");
    if (has_small_parse_table) {
        try writer.writeAll("  uint32_t index = ts_small_parse_table_map[SMALL_STATE(state)];\n");
        try writer.writeAll("  uint16_t group_count = ts_small_parse_table[index++];\n");
        try writer.writeAll("  for (uint16_t group_index = 0; group_index < group_count; group_index++) {\n");
        try writer.writeAll("    uint16_t value = ts_small_parse_table[index++];\n");
        try writer.writeAll("    uint16_t symbol_count = ts_small_parse_table[index++];\n");
        try writer.writeAll("    for (uint16_t symbol_index = 0; symbol_index < symbol_count; symbol_index++) {\n");
        try writer.writeAll("      if (ts_small_parse_table[index++] == symbol) return value;\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("  }\n");
    } else {
        try writer.writeAll("  (void)symbol;\n");
    }
    try writer.writeAll("  return 0;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static const TSParseActionEntry *ts_generated_parse_actions_for(TSStateId state, TSSymbol symbol) {\n");
    try writer.writeAll("  return &ts_parse_actions[ts_generated_parse_table_entry(state, symbol)];\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static TSStateId ts_generated_goto_state(TSStateId state, TSSymbol symbol) {\n");
    try writer.writeAll("  return (TSStateId)ts_generated_parse_table_entry(state, symbol);\n");
    try writer.writeAll("}\n\n");
}

fn writeGlrActionDispatch(writer: anytype) !void {
    try writer.writeAll("typedef enum {\n");
    try writer.writeAll("  TSGeneratedParseStepNoAction,\n");
    try writer.writeAll("  TSGeneratedParseStepShift,\n");
    try writer.writeAll("  TSGeneratedParseStepReduce,\n");
    try writer.writeAll("  TSGeneratedParseStepAccept,\n");
    try writer.writeAll("  TSGeneratedParseStepRecover,\n");
    try writer.writeAll("} TSGeneratedParseStepStatus;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  TSGeneratedParseStepStatus status;\n");
    try writer.writeAll("  TSStateId next_state;\n");
    try writer.writeAll("  uint8_t child_count;\n");
    try writer.writeAll("  TSSymbol symbol;\n");
    try writer.writeAll("  uint16_t production_id;\n");
    try writer.writeAll("} TSGeneratedParseStep;\n\n");
    try writer.writeAll("static TSGeneratedParseStep ts_generated_apply_parse_action(TSGeneratedParseVersion *version, const TSParseAction *action) {\n");
    try writer.writeAll("  TSGeneratedParseStep step = { 0 };\n");
    try writer.writeAll("  switch ((TSParseActionType)action->type) {\n");
    try writer.writeAll("    case TSParseActionTypeShift:\n");
    try writer.writeAll("      if (!ts_generated_version_push_state(version, action->shift.state)) break;\n");
    try writer.writeAll("      version->shifted = true;\n");
    try writer.writeAll("      step.status = TSGeneratedParseStepShift;\n");
    try writer.writeAll("      step.next_state = action->shift.state;\n");
    try writer.writeAll("      break;\n");
    try writer.writeAll("    case TSParseActionTypeReduce:\n");
    try writer.writeAll("      version->dynamic_precedence += action->reduce.dynamic_precedence;\n");
    try writer.writeAll("      if (version->stack_len <= action->reduce.child_count) break;\n");
    try writer.writeAll("      if (!ts_generated_version_reduce_value(version, action)) break;\n");
    try writer.writeAll("      version->stack_len -= action->reduce.child_count;\n");
    try writer.writeAll("      {\n");
    try writer.writeAll("        TSStateId top = version->stack[version->stack_len - 1];\n");
    try writer.writeAll("        TSStateId next = ts_generated_goto_state(top, action->reduce.symbol);\n");
    try writer.writeAll("        if (next == 0) break;\n");
    try writer.writeAll("        if (!ts_generated_version_push_state(version, next)) break;\n");
    try writer.writeAll("      }\n");
    try writer.writeAll("      step.status = TSGeneratedParseStepReduce;\n");
    try writer.writeAll("      step.child_count = action->reduce.child_count;\n");
    try writer.writeAll("      step.symbol = action->reduce.symbol;\n");
    try writer.writeAll("      step.production_id = action->reduce.production_id;\n");
    try writer.writeAll("      break;\n");
    try writer.writeAll("    case TSParseActionTypeAccept:\n");
    try writer.writeAll("      step.status = TSGeneratedParseStepAccept;\n");
    try writer.writeAll("      break;\n");
    try writer.writeAll("    case TSParseActionTypeRecover:\n");
    try writer.writeAll("      step.status = TSGeneratedParseStepRecover;\n");
    try writer.writeAll("      break;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return step;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static TSGeneratedParseStep ts_generated_parse_version_step(TSGeneratedParseVersion *version, TSSymbol lookahead_symbol) {\n");
    try writer.writeAll("  const TSParseActionEntry *entry = ts_generated_parse_actions_for(version->state, lookahead_symbol);\n");
    try writer.writeAll("  if (entry->entry.count == 0) return (TSGeneratedParseStep){ .status = TSGeneratedParseStepNoAction };\n");
    try writer.writeAll("  TSGeneratedParseStep step = ts_generated_apply_parse_action(version, &entry[1].action);\n");
    try writer.writeAll("  if (step.status == TSGeneratedParseStepShift) step.symbol = lookahead_symbol;\n");
    try writer.writeAll("  return step;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_recover_to_stack_action(TSGeneratedParseVersion *version, TSSymbol lookahead_symbol) {\n");
    try writer.writeAll("  if (version->stack_len <= 1) return false;\n");
    try writer.writeAll("  for (uint16_t depth = version->stack_len - 1; depth > 0; depth--) {\n");
    try writer.writeAll("    TSStateId candidate = version->stack[depth - 1];\n");
    try writer.writeAll("    const TSParseActionEntry *entry = ts_generated_parse_actions_for(candidate, lookahead_symbol);\n");
    try writer.writeAll("    if (entry->entry.count == 0) continue;\n");
    try writer.writeAll("    version->stack_len = depth;\n");
    try writer.writeAll("    version->state = candidate;\n");
    try writer.writeAll("    version->error_count++;\n");
    try writer.writeAll("    return true;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return false;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static TSGeneratedParseStep ts_generated_drive_version(TSGeneratedParseVersion *version, TSSymbol lookahead_symbol) {\n");
    try writer.writeAll("  TSGeneratedParseStep step;\n");
    try writer.writeAll("  uint8_t recovery_attempts = 0;\n");
    try writer.writeAll("  do {\n");
    try writer.writeAll("    step = ts_generated_parse_version_step(version, lookahead_symbol);\n");
    try writer.writeAll("    if (step.status == TSGeneratedParseStepNoAction) {\n");
    try writer.writeAll("      if (recovery_attempts++ >= GEN_Z_SITTER_MAX_RECOVERY_ATTEMPTS) return step;\n");
    try writer.writeAll("      if (ts_generated_recover_to_stack_action(version, lookahead_symbol)) continue;\n");
    try writer.writeAll("      if (lookahead_symbol == 0) return step;\n");
    try writer.writeAll("      version->byte_offset++;\n");
    try writer.writeAll("      version->error_count++;\n");
    try writer.writeAll("      step.status = TSGeneratedParseStepRecover;\n");
    try writer.writeAll("      return step;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  } while (step.status == TSGeneratedParseStepReduce);\n");
    try writer.writeAll("  return step;\n");
    try writer.writeAll("}\n\n");
}

fn writeUnresolvedEntryType(writer: anytype) !void {
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  uint16_t symbol_id;\n");
    try writer.writeAll("  uint16_t reason;\n");
    try writer.writeAll("  uint16_t action_index;\n");
    try writer.writeAll("  uint16_t action_count;\n");
    try writer.writeAll("} TSUnresolvedEntry;\n\n");
}

fn writeUnresolvedEntry(
    writer: anytype,
    symbols: []const EmittedSymbol,
    parse_action_list: []const serialize.SerializedParseActionListEntry,
    productions: []const serialize.SerializedProductionInfo,
    entry: serialize.SerializedUnresolvedEntry,
) !void {
    const symbol_id = symbolIdForRef(symbols, entry.symbol) orelse return error.OutOfMemory;
    const action_index = serialize.parseActionListIndexForUnresolvedEntry(parse_action_list, entry, productions) orelse return error.OutOfMemory;
    try writer.print(
        "  {{ .symbol_id = {d}, .reason = {d}, .action_index = {d}, .action_count = {d} }},\n",
        .{ symbol_id, unresolvedReasonCode(entry.reason), action_index, entry.candidate_actions.len },
    );
}

fn writeUnresolvedAccessors(
    writer: anytype,
    states: []const serialize.SerializedState,
    owners: []const usize,
) !void {
    try writer.writeAll("bool ts_parser_runtime_has_unresolved_states(void) {\n");
    try writer.writeAll("  return ");
    try writer.writeAll(if (hasUnresolvedStateRows(states)) "true" else "false");
    try writer.writeAll(";\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id) {\n");
    try writer.writeAll("  switch (state_id) {\n");
    for (states, 0..) |state_value, index| {
        if (state_value.unresolved.len == 0) continue;
        try writer.print("    case {d}: return ts_state_{d}_unresolved;\n", .{ index, owners[index] });
    }
    try writer.writeAll("    default: return NULL;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("uint16_t ts_parser_unresolved_count(uint16_t state_id) {\n");
    try writer.writeAll("  switch (state_id) {\n");
    for (states, 0..) |state_value, index| {
        if (state_value.unresolved.len == 0) continue;
        try writer.print("    case {d}: return {d};\n", .{ index, state_value.unresolved.len });
    }
    try writer.writeAll("    default: return 0;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) {\n");
    try writer.writeAll("  return ts_parser_unresolved_count(state_id) != 0;\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSUnresolvedEntry *entries = ts_parser_unresolved(state_id);\n");
    try writer.writeAll("  return entries && index < ts_parser_unresolved_count(state_id) ? &entries[index] : NULL;\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol) {\n");
    try writer.writeAll("  const TSUnresolvedEntry *entries = ts_parser_unresolved(state_id);\n");
    try writer.writeAll("  uint16_t count = ts_parser_unresolved_count(state_id);\n");
    try writer.writeAll("  for (uint16_t i = 0; i < count; i++) {\n");
    try writer.writeAll("    if (strcmp(ts_symbol_names[entries[i].symbol_id], symbol) == 0) return &entries[i];\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return NULL;\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol) {\n");
    try writer.writeAll("  return ts_parser_find_unresolved(state_id, symbol) != NULL;\n");
    try writer.writeAll("}\n\n");
}

fn writeGlrUnresolvedForkHelpers(writer: anytype) !void {
    try writer.writeAll("static bool ts_generated_clone_parse_version(TSGeneratedParseVersionSet *set, uint16_t source_index, uint16_t *target_index) {\n");
    try writer.writeAll("  if (source_index >= set->count || set->count >= GEN_Z_SITTER_MAX_PARSE_VERSIONS) return false;\n");
    try writer.writeAll("  *target_index = set->count;\n");
    try writer.writeAll("  set->versions[set->count] = set->versions[source_index];\n");
    try writer.writeAll("  set->count++;\n");
    try writer.writeAll("  return true;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static uint16_t ts_generated_fork_unresolved_actions(TSGeneratedParseVersionSet *set, uint16_t version_index, TSSymbol lookahead_symbol, uint32_t advance_bytes) {\n");
    try writer.writeAll("  if (version_index >= set->count) return 0;\n");
    try writer.writeAll("  TSGeneratedParseVersion *base = &set->versions[version_index];\n");
    try writer.writeAll("  const TSUnresolvedEntry *entries = ts_parser_unresolved(base->state);\n");
    try writer.writeAll("  uint16_t entry_count = ts_parser_unresolved_count(base->state);\n");
    try writer.writeAll("  uint16_t applied = 0;\n");
    try writer.writeAll("  for (uint16_t entry_index = 0; entry_index < entry_count; entry_index++) {\n");
    try writer.writeAll("    const TSUnresolvedEntry *unresolved = &entries[entry_index];\n");
    try writer.writeAll("    if (unresolved->symbol_id != lookahead_symbol) continue;\n");
    try writer.writeAll("    const TSParseActionEntry *action_entry = &ts_parse_actions[unresolved->action_index];\n");
    try writer.writeAll("    for (uint16_t action_index = 0; action_index < unresolved->action_count; action_index++) {\n");
    try writer.writeAll("      uint16_t target_index = version_index;\n");
    try writer.writeAll("      if (applied > 0 && !ts_generated_clone_parse_version(set, version_index, &target_index)) return applied;\n");
    try writer.writeAll("      set->versions[target_index].shifted = false;\n");
    try writer.writeAll("      TSGeneratedParseStep step = ts_generated_apply_parse_action(&set->versions[target_index], &action_entry[1 + action_index].action);\n");
    try writer.writeAll("      if (step.status == TSGeneratedParseStepShift && !ts_generated_version_push_shift_value(&set->versions[target_index], lookahead_symbol, advance_bytes)) {\n");
    try writer.writeAll("        set->versions[target_index].active = false;\n");
    try writer.writeAll("        continue;\n");
    try writer.writeAll("      }\n");
    try writer.writeAll("      if (step.status == TSGeneratedParseStepReduce) (void)ts_generated_drive_version(&set->versions[target_index], lookahead_symbol);\n");
    try writer.writeAll("      applied++;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return applied;\n");
    try writer.writeAll("}\n\n");
}

fn writeGlrVersionCondenseHelpers(writer: anytype) !void {
    try writer.writeAll("static bool ts_generated_parse_versions_same_position(const TSGeneratedParseVersion *left, const TSGeneratedParseVersion *right) {\n");
    try writer.writeAll("  if (left->active != right->active) return false;\n");
    try writer.writeAll("  if (left->state != right->state) return false;\n");
    try writer.writeAll("  if (left->byte_offset != right->byte_offset) return false;\n");
    try writer.writeAll("  if (left->stack_len != right->stack_len) return false;\n");
    try writer.writeAll("  if (left->value_len != right->value_len) return false;\n");
    try writer.writeAll("  for (uint16_t index = 0; index < left->stack_len; index++) {\n");
    try writer.writeAll("    if (left->stack[index] != right->stack[index]) return false;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  for (uint16_t index = 0; index < left->value_len; index++) {\n");
    try writer.writeAll("    if (left->values[index].symbol != right->values[index].symbol) return false;\n");
    try writer.writeAll("    if (left->values[index].start_byte != right->values[index].start_byte) return false;\n");
    try writer.writeAll("    if (left->values[index].end_byte != right->values[index].end_byte) return false;\n");
    try writer.writeAll("    if (left->values[index].production_id != right->values[index].production_id) return false;\n");
    try writer.writeAll("    if (left->values[index].child_count != right->values[index].child_count) return false;\n");
    try writer.writeAll("    if (left->values[index].node_id != right->values[index].node_id) return false;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  if (left->node_count != right->node_count) return false;\n");
    try writer.writeAll("  for (uint16_t index = 0; index < left->node_count; index++) {\n");
    try writer.writeAll("    if (left->nodes[index].symbol != right->nodes[index].symbol) return false;\n");
    try writer.writeAll("    if (left->nodes[index].start_byte != right->nodes[index].start_byte) return false;\n");
    try writer.writeAll("    if (left->nodes[index].end_byte != right->nodes[index].end_byte) return false;\n");
    try writer.writeAll("    if (left->nodes[index].production_id != right->nodes[index].production_id) return false;\n");
    try writer.writeAll("    if (left->nodes[index].child_count != right->nodes[index].child_count) return false;\n");
    try writer.writeAll("    if (left->nodes[index].first_child != right->nodes[index].first_child) return false;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return true;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static void ts_generated_condense_parse_versions(TSGeneratedParseVersionSet *set) {\n");
    try writer.writeAll("  uint32_t min_error_count = UINT32_MAX;\n");
    try writer.writeAll("  for (uint16_t scan_index = 0; scan_index < set->count; scan_index++) {\n");
    try writer.writeAll("    if (set->versions[scan_index].active && set->versions[scan_index].error_count < min_error_count) {\n");
    try writer.writeAll("      min_error_count = set->versions[scan_index].error_count;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  uint16_t write_index = 0;\n");
    try writer.writeAll("  for (uint16_t read_index = 0; read_index < set->count; read_index++) {\n");
    try writer.writeAll("    if (!set->versions[read_index].active) continue;\n");
    try writer.writeAll("    if (min_error_count != UINT32_MAX && set->versions[read_index].error_count > min_error_count + GEN_Z_SITTER_MAX_ERROR_COST_DIFFERENCE) continue;\n");
    try writer.writeAll("    bool duplicate = false;\n");
    try writer.writeAll("    for (uint16_t existing_index = 0; existing_index < write_index; existing_index++) {\n");
    try writer.writeAll("      if (ts_generated_parse_versions_same_position(&set->versions[existing_index], &set->versions[read_index])) {\n");
    try writer.writeAll("        if (set->versions[read_index].error_count < set->versions[existing_index].error_count) {\n");
    try writer.writeAll("          set->versions[existing_index] = set->versions[read_index];\n");
    try writer.writeAll("        } else if (set->versions[read_index].error_count == set->versions[existing_index].error_count && set->versions[read_index].dynamic_precedence > set->versions[existing_index].dynamic_precedence) {\n");
    try writer.writeAll("          set->versions[existing_index].dynamic_precedence = set->versions[read_index].dynamic_precedence;\n");
    try writer.writeAll("        }\n");
    try writer.writeAll("        duplicate = true;\n");
    try writer.writeAll("        break;\n");
    try writer.writeAll("      }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    if (duplicate) continue;\n");
    try writer.writeAll("    if (write_index != read_index) set->versions[write_index] = set->versions[read_index];\n");
    try writer.writeAll("    write_index++;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  for (uint16_t clear_index = write_index; clear_index < set->count; clear_index++) {\n");
    try writer.writeAll("    set->versions[clear_index].active = false;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  set->count = write_index;\n");
    try writer.writeAll("}\n\n");
}

fn writeGlrInputLexerHelpers(writer: anytype) !void {
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  TSLexer base;\n");
    try writer.writeAll("  const char *input;\n");
    try writer.writeAll("  uint32_t length;\n");
    try writer.writeAll("  uint32_t offset;\n");
    try writer.writeAll("  uint32_t end_offset;\n");
    try writer.writeAll("} TSGeneratedInputLexer;\n\n");
    try writer.writeAll("static void ts_generated_input_lexer_sync(TSGeneratedInputLexer *lexer) {\n");
    try writer.writeAll("  lexer->base.lookahead = lexer->offset < lexer->length ? (unsigned char)lexer->input[lexer->offset] : 0;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static void ts_generated_input_lexer_advance(TSLexer *base, bool skip) {\n");
    try writer.writeAll("  (void)skip;\n");
    try writer.writeAll("  TSGeneratedInputLexer *lexer = (TSGeneratedInputLexer *)base;\n");
    try writer.writeAll("  if (lexer->offset < lexer->length) lexer->offset++;\n");
    try writer.writeAll("  ts_generated_input_lexer_sync(lexer);\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static void ts_generated_input_lexer_mark_end(TSLexer *base) {\n");
    try writer.writeAll("  TSGeneratedInputLexer *lexer = (TSGeneratedInputLexer *)base;\n");
    try writer.writeAll("  lexer->end_offset = lexer->offset;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static uint32_t ts_generated_input_lexer_get_column(TSLexer *base) {\n");
    try writer.writeAll("  TSGeneratedInputLexer *lexer = (TSGeneratedInputLexer *)base;\n");
    try writer.writeAll("  return lexer->offset;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_input_lexer_is_at_included_range_start(const TSLexer *base) {\n");
    try writer.writeAll("  (void)base;\n");
    try writer.writeAll("  return false;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_input_lexer_eof(const TSLexer *base) {\n");
    try writer.writeAll("  const TSGeneratedInputLexer *lexer = (const TSGeneratedInputLexer *)base;\n");
    try writer.writeAll("  return lexer->offset >= lexer->length;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static void ts_generated_input_lexer_log(const TSLexer *base, const char *format, ...) {\n");
    try writer.writeAll("  (void)base;\n");
    try writer.writeAll("  (void)format;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static bool ts_generated_lex_symbol(const char *input, uint32_t length, TSStateId parse_state, TSSymbol *out_symbol, uint32_t *out_advance_bytes) {\n");
    try writer.writeAll("  TSGeneratedInputLexer lexer = { 0 };\n");
    try writer.writeAll("  lexer.input = input;\n");
    try writer.writeAll("  lexer.length = length;\n");
    try writer.writeAll("  lexer.base.advance = ts_generated_input_lexer_advance;\n");
    try writer.writeAll("  lexer.base.mark_end = ts_generated_input_lexer_mark_end;\n");
    try writer.writeAll("  lexer.base.get_column = ts_generated_input_lexer_get_column;\n");
    try writer.writeAll("  lexer.base.is_at_included_range_start = ts_generated_input_lexer_is_at_included_range_start;\n");
    try writer.writeAll("  lexer.base.eof = ts_generated_input_lexer_eof;\n");
    try writer.writeAll("  lexer.base.log = ts_generated_input_lexer_log;\n");
    try writer.writeAll("  ts_generated_input_lexer_sync(&lexer);\n");
    try writer.writeAll("  if (!ts_lex(&lexer.base, ts_lex_modes[parse_state].lex_state)) return false;\n");
    try writer.writeAll("  *out_symbol = lexer.base.result_symbol;\n");
    try writer.writeAll("  *out_advance_bytes = lexer.end_offset;\n");
    try writer.writeAll("  return true;\n");
    try writer.writeAll("}\n\n");
}

fn writeGlrVersionStepLoop(writer: anytype, has_unresolved: bool) !void {
    try writer.writeAll("static bool ts_generated_step_parse_versions(TSGeneratedParseVersionSet *set, uint16_t lead_index, TSSymbol lookahead_symbol, uint32_t advance_bytes) {\n");
    try writer.writeAll("  if (lead_index >= set->count || !set->versions[lead_index].active) return false;\n");
    try writer.writeAll("  uint32_t target_byte_offset = set->versions[lead_index].byte_offset;\n");
    try writer.writeAll("  TSStateId target_state = set->versions[lead_index].state;\n");
    try writer.writeAll("  uint16_t initial_count = set->count;\n");
    try writer.writeAll("  for (uint16_t version_index = 0; version_index < initial_count; version_index++) {\n");
    try writer.writeAll("    TSGeneratedParseVersion *version = &set->versions[version_index];\n");
    try writer.writeAll("    if (!version->active) continue;\n");
    try writer.writeAll("    if (version->byte_offset != target_byte_offset || version->state != target_state) continue;\n");
    try writer.writeAll("    version->shifted = false;\n");
    if (has_unresolved) {
        try writer.writeAll("    if (ts_generated_fork_unresolved_actions(set, version_index, lookahead_symbol, advance_bytes) != 0) continue;\n");
    }
    try writer.writeAll("    TSGeneratedParseStep step = ts_generated_drive_version(version, lookahead_symbol);\n");
    try writer.writeAll("    if (step.status == TSGeneratedParseStepShift && !ts_generated_version_push_shift_value(version, step.symbol, advance_bytes)) {\n");
    try writer.writeAll("      version->active = false;\n");
    try writer.writeAll("      continue;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    switch (step.status) {\n");
    try writer.writeAll("      case TSGeneratedParseStepNoAction:\n");
    try writer.writeAll("        version->active = false;\n");
    try writer.writeAll("        break;\n");
    try writer.writeAll("      case TSGeneratedParseStepAccept:\n");
    try writer.writeAll("        return true;\n");
    try writer.writeAll("      case TSGeneratedParseStepShift:\n");
    try writer.writeAll("      case TSGeneratedParseStepReduce:\n");
    try writer.writeAll("      case TSGeneratedParseStepRecover:\n");
    try writer.writeAll("        break;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  ts_generated_condense_parse_versions(set);\n");
    try writer.writeAll("  return false;\n");
    try writer.writeAll("}\n\n");
}

fn writeGlrMainParseFunction(writer: anytype) !void {
    try writer.writeAll("bool ts_generated_parse_result(const char *input, uint32_t length, TSGeneratedParseResult *out_result) {\n");
    try writer.writeAll("  TSGeneratedParseResult result = { 0 };\n");
    try writer.writeAll("  result.root_node = GEN_Z_SITTER_NO_NODE;\n");
    try writer.writeAll("  TSGeneratedParseVersionSet set;\n");
    try writer.writeAll("  ts_generated_parse_versions_init(&set, 0);\n");
    try writer.writeAll("  for (;;) {\n");
    try writer.writeAll("    TSGeneratedParseVersion *lead = NULL;\n");
    try writer.writeAll("    uint16_t lead_index = 0;\n");
    try writer.writeAll("    for (uint16_t i = 0; i < set.count; i++) {\n");
    try writer.writeAll("      if (!set.versions[i].active) continue;\n");
    try writer.writeAll("      if (!lead || set.versions[i].byte_offset < lead->byte_offset) {\n");
    try writer.writeAll("        lead = &set.versions[i];\n");
    try writer.writeAll("        lead_index = i;\n");
    try writer.writeAll("      }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    if (!lead) {\n");
    try writer.writeAll("      if (out_result) *out_result = result;\n");
    try writer.writeAll("      return false;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    TSSymbol lookahead_symbol = 0;\n");
    try writer.writeAll("    uint32_t advance_bytes = 0;\n");
    try writer.writeAll("    if (lead->byte_offset < length) {\n");
    try writer.writeAll("      if (!ts_generated_lex_symbol(input + lead->byte_offset, length - lead->byte_offset, lead->state, &lookahead_symbol, &advance_bytes)) {\n");
    try writer.writeAll("        if (out_result) *out_result = result;\n");
    try writer.writeAll("        return false;\n");
    try writer.writeAll("      }\n");
    try writer.writeAll("      if (advance_bytes == 0) {\n");
    try writer.writeAll("        if (out_result) *out_result = result;\n");
    try writer.writeAll("        return false;\n");
    try writer.writeAll("      }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    bool accepted = ts_generated_step_parse_versions(&set, lead_index, lookahead_symbol, advance_bytes);\n");
    try writer.writeAll("    if (accepted) {\n");
    try writer.writeAll("      result.accepted = true;\n");
    try writer.writeAll("      result.consumed_bytes = lead->byte_offset + advance_bytes;\n");
    try writer.writeAll("      result.root_node = lead->value_len > 0 ? lead->values[lead->value_len - 1].node_id : GEN_Z_SITTER_NO_NODE;\n");
    try writer.writeAll("      result.node_count = lead->node_count;\n");
    try writer.writeAll("      result.error_count = lead->error_count;\n");
    try writer.writeAll("      result.dynamic_precedence = lead->dynamic_precedence;\n");
    try writer.writeAll("      for (uint16_t node_index = 0; node_index < lead->node_count; node_index++) {\n");
    try writer.writeAll("        result.nodes[node_index] = lead->nodes[node_index];\n");
    try writer.writeAll("      }\n");
    try writer.writeAll("      if (out_result) *out_result = result;\n");
    try writer.writeAll("      return true;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    bool any_active = false;\n");
    try writer.writeAll("    for (uint16_t i = 0; i < set.count; i++) {\n");
    try writer.writeAll("      if (!set.versions[i].active) continue;\n");
    try writer.writeAll("      if (set.versions[i].shifted && advance_bytes > 0) set.versions[i].byte_offset += advance_bytes;\n");
    try writer.writeAll("      set.versions[i].shifted = false;\n");
    try writer.writeAll("      any_active = true;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    if (!any_active || advance_bytes == 0) {\n");
    try writer.writeAll("      if (out_result) *out_result = result;\n");
    try writer.writeAll("      return false;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("bool ts_generated_parse(const char *input, uint32_t length, uint32_t *out_consumed_bytes) {\n");
    try writer.writeAll("  TSGeneratedParseResult result;\n");
    try writer.writeAll("  bool accepted = ts_generated_parse_result(input, length, &result);\n");
    try writer.writeAll("  if (out_consumed_bytes) *out_consumed_bytes = result.consumed_bytes;\n");
    try writer.writeAll("  return accepted;\n");
    try writer.writeAll("}\n\n");
}

fn hasUnresolvedStateRows(states: []const serialize.SerializedState) bool {
    for (states) |state| {
        if (state.unresolved.len > 0) return true;
    }
    return false;
}

fn writeSupertypeTables(
    writer: anytype,
    symbols: []const EmittedSymbol,
    supertype_map: serialize.SerializedSupertypeMap,
) EmitError!void {
    if (supertype_map.symbols.len == 0) return;

    try writer.writeAll("static const TSSymbol ts_supertype_symbols[] = {\n");
    for (supertype_map.symbols, 0..) |symbol, index| {
        const symbol_id = symbolIdForRef(symbols, symbol) orelse return error.OutOfMemory;
        try writer.print("  [{d}] = {d},\n", .{ index, symbol_id });
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSMapSlice ts_supertype_map_slices[SYMBOL_COUNT] = {\n");
    for (supertype_map.slices) |slice| {
        const symbol_id = symbolIdForRef(symbols, slice.supertype) orelse return error.OutOfMemory;
        try writer.print("  [{d}] = {{ .index = {d}, .length = {d} }},\n", .{ symbol_id, slice.index, slice.length });
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSSymbol ts_supertype_map_entries[] = {\n");
    if (supertype_map.entries.len == 0) {
        try writer.writeAll("  0,\n");
    } else {
        for (supertype_map.entries, 0..) |entry, index| {
            const symbol_id = supertypeEntrySymbolId(symbols, entry) orelse return error.OutOfMemory;
            try writer.print("  [{d}] = {d},\n", .{ index, symbol_id });
        }
    }
    try writer.writeAll("};\n\n");
}

fn supertypeEntrySymbolId(
    symbols: []const EmittedSymbol,
    entry: serialize.SerializedSupertypeMapEntry,
) ?u16 {
    if (entry.alias_name) |name| {
        return aliasSymbolIdForName(symbols, name, entry.alias_named);
    }
    return symbolIdForRef(symbols, entry.symbol);
}

fn writeReservedWords(
    writer: anytype,
    symbols: []const EmittedSymbol,
    reserved_words: serialize.SerializedReservedWords,
) EmitError!void {
    if (reserved_words.sets.len <= 1) return;

    try writer.writeAll("static const TSSymbol ts_reserved_words[][MAX_RESERVED_WORD_SET_SIZE > 0 ? MAX_RESERVED_WORD_SET_SIZE : 1] = {\n");
    for (reserved_words.sets, 0..) |set, set_index| {
        try writer.print("  [{d}] = {{", .{set_index});
        const column_count = @max(@as(usize, reserved_words.max_size), 1);
        for (0..column_count) |column| {
            const symbol_id = if (column < set.len)
                symbolIdForRef(symbols, set[column]) orelse return error.OutOfMemory
            else
                0;
            if (column > 0) try writer.writeByte(',');
            try writer.print(" {d}", .{symbol_id});
        }
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n\n");
}

fn writeExternalScannerTables(
    writer: anytype,
    symbols: []const EmittedSymbol,
    grammar_name: []const u8,
    external_scanner: serialize.SerializedExternalScanner,
) EmitError!void {
    if (external_scanner.symbols.len == 0) return;

    try writer.writeAll("enum ts_external_scanner_symbol_identifiers {\n");
    for (external_scanner.symbols, 0..) |symbol_ref, local_index| {
        const symbol = emittedSymbolForRef(symbols, symbol_ref) orelse return error.OutOfMemory;
        try writer.writeAll("  ts_external_token_");
        try writeCIdentifierFragment(writer, symbol.label);
        try writer.print(" = {d},\n", .{local_index});
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSSymbol ts_external_scanner_symbol_map[EXTERNAL_TOKEN_COUNT] = {\n");
    for (external_scanner.symbols, 0..) |symbol_ref, local_index| {
        const symbol_id = symbolIdForRef(symbols, symbol_ref) orelse return error.OutOfMemory;
        try writer.print("  [{d}] = {d},\n", .{ local_index, symbol_id });
    }
    try writer.writeAll("};\n\n");

    if (external_scanner.states.len != 0) {
        try writer.writeAll("static const bool ts_external_scanner_states[][EXTERNAL_TOKEN_COUNT] = {\n");
        for (external_scanner.states, 0..) |state_set, state_index| {
            try writer.print("  [{d}] = {{", .{state_index});
            for (0..external_scanner.symbols.len) |symbol_index| {
                if (symbol_index > 0) try writer.writeByte(',');
                const enabled = symbol_index < state_set.len and state_set[symbol_index];
                try writer.print(" {}", .{enabled});
            }
            try writer.writeAll(" },\n");
        }
        try writer.writeAll("};\n\n");
    }

    try writer.writeAll("extern void *");
    try writeExternalScannerFunctionName(writer, grammar_name, "create");
    try writer.writeAll("(void);\n");
    try writer.writeAll("extern void ");
    try writeExternalScannerFunctionName(writer, grammar_name, "destroy");
    try writer.writeAll("(void *);\n");
    try writer.writeAll("extern bool ");
    try writeExternalScannerFunctionName(writer, grammar_name, "scan");
    try writer.writeAll("(void *, TSLexer *, const bool *);\n");
    try writer.writeAll("extern unsigned ");
    try writeExternalScannerFunctionName(writer, grammar_name, "serialize");
    try writer.writeAll("(void *, char *);\n");
    try writer.writeAll("extern void ");
    try writeExternalScannerFunctionName(writer, grammar_name, "deserialize");
    try writer.writeAll("(void *, const char *, unsigned);\n\n");
}

fn emittedSymbolForRef(symbols: []const EmittedSymbol, symbol_ref: syntax_grammar.SymbolRef) ?EmittedSymbol {
    for (symbols) |symbol| {
        if (symbol.ref) |candidate| {
            if (symbolRefEql(candidate, symbol_ref)) return symbol;
        }
    }
    return null;
}

fn writeExternalScannerFunctionName(writer: anytype, grammar_name: []const u8, suffix: []const u8) EmitError!void {
    try writer.writeAll("tree_sitter_");
    try writeCIdentifierFragment(writer, grammar_name);
    try writer.writeAll("_external_scanner_");
    try writer.writeAll(suffix);
}

fn writeCIdentifierFragment(writer: anytype, value: []const u8) EmitError!void {
    var wrote_any = false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('_');
        }
        wrote_any = true;
    }
    if (!wrote_any) try writer.writeByte('_');
}

const RuntimeLexTable = struct {
    table: lexer_serialize.SerializedLexTable,
    lex_state_starts: []const u16,
};

fn buildRuntimeLexTableAlloc(
    allocator: std.mem.Allocator,
    lex_tables: []const lexer_serialize.SerializedLexTable,
) EmitError!RuntimeLexTable {
    const starts = try allocator.alloc(u16, lex_tables.len);
    var state_count: usize = 0;
    for (lex_tables, 0..) |table, index| {
        starts[index] = @intCast(state_count + table.start_state_id);
        state_count += table.states.len;
    }

    const states = try allocator.alloc(lexer_serialize.SerializedLexState, state_count);
    var state_index: usize = 0;
    var offset: u32 = 0;
    for (lex_tables) |table| {
        for (table.states) |state_value| {
            const transitions = try allocator.alloc(lexer_serialize.SerializedLexTransition, state_value.transitions.len);
            for (state_value.transitions, 0..) |transition, transition_index| {
                transitions[transition_index] = .{
                    .ranges = transition.ranges,
                    .next_state_id = transition.next_state_id + offset,
                    .skip = transition.skip,
                };
            }
            states[state_index] = .{
                .accept_symbol = state_value.accept_symbol,
                .eof_target = if (state_value.eof_target) |target| target + offset else null,
                .transitions = transitions,
            };
            state_index += 1;
        }
        offset += @intCast(table.states.len);
    }

    return .{
        .table = .{
            .start_state_id = if (starts.len == 0) 0 else starts[0],
            .states = states,
        },
        .lex_state_starts = starts,
    };
}

fn runtimeLexStateForMode(lex_state_starts: []const u16, lex_state_id: u16) u16 {
    if (lex_state_id >= lex_state_starts.len) return lex_state_id;
    return lex_state_starts[lex_state_id];
}

const RuntimeSymbolResolverContext = struct {
    symbols: []const EmittedSymbol,
};

fn resolveRuntimeSymbol(context: *const anyopaque, symbol: syntax_grammar.SymbolRef) ?u16 {
    const typed: *const RuntimeSymbolResolverContext = @ptrCast(@alignCast(context));
    return symbolIdForRef(typed.symbols, symbol);
}

fn serializedLargeStateCount(serialized: serialize.SerializedTable) usize {
    if (serialized.large_state_count != 0 or serialized.states.len == 0) return serialized.large_state_count;
    return @min(serialized.states.len, 2);
}

fn tokenCount(symbols: []const EmittedSymbol) usize {
    var count: usize = 0;
    for (symbols) |symbol| {
        const ref = symbol.ref orelse continue;
        if (symbolKindIsTerminal(ref) or symbolKindIsExternal(ref)) count += 1;
    }
    return count;
}

fn externalTokenCount(symbols: []const EmittedSymbol) usize {
    var count: usize = 0;
    for (symbols) |symbol| {
        const ref = symbol.ref orelse continue;
        if (symbolKindIsExternal(ref)) count += 1;
    }
    return count;
}

fn aliasSymbolCount(symbols: []const EmittedSymbol) usize {
    var count: usize = 0;
    for (symbols) |symbol| {
        if (symbol.ref == null) count += 1;
    }
    return count;
}

fn maxAliasSequenceLength(serialized: serialize.SerializedTable) usize {
    var max_len: usize = 0;
    for (serialized.alias_sequences) |alias| {
        max_len = @max(max_len, alias.step_index + 1);
    }
    return max_len;
}

fn aliasSymbolIdForPosition(
    symbols: []const EmittedSymbol,
    aliases: []const serialize.SerializedAliasEntry,
    production_id: usize,
    step_index: usize,
) ?u16 {
    for (aliases) |alias| {
        if (alias.production_id != production_id or alias.step_index != step_index) continue;
        return aliasSymbolIdForName(symbols, alias.name, alias.named);
    }
    return null;
}

fn aliasSymbolIdForName(symbols: []const EmittedSymbol, name: []const u8, named: bool) ?u16 {
    for (symbols, 0..) |symbol, index| {
        if (symbol.ref == null and symbol.named == named and std.mem.eql(u8, symbol.label, name)) return @intCast(index);
    }
    return null;
}

fn writeNonTerminalAliasMap(
    writer: anytype,
    allocator: std.mem.Allocator,
    symbols: []const EmittedSymbol,
    aliases: []const serialize.SerializedAliasEntry,
) EmitError!void {
    try writer.writeAll("static const uint16_t ts_non_terminal_alias_map[] = {\n");
    for (symbols, 0..) |symbol, symbol_id| {
        const original = symbol.ref orelse continue;
        if (!symbolKindIsNonTerminal(original)) continue;

        var alias_ids = std.array_list.Managed(u16).init(allocator);
        defer alias_ids.deinit();

        for (aliases) |alias| {
            if (!symbolRefEql(alias.original_symbol, original)) continue;
            const alias_id = aliasSymbolIdForName(symbols, alias.name, alias.named) orelse continue;
            try appendUniqueSortedAliasId(&alias_ids, alias_id);
        }
        if (alias_ids.items.len == 0) continue;

        try writer.print("  {d}, {d},\n", .{ symbol_id, alias_ids.items.len + 1 });
        try writer.print("    {d},\n", .{symbol.public_symbol});
        for (alias_ids.items) |alias_id| {
            try writer.print("    {d},\n", .{alias_id});
        }
    }
    try writer.writeAll("  0,\n");
    try writer.writeAll("};\n");
}

fn appendUniqueSortedAliasId(
    alias_ids: *std.array_list.Managed(u16),
    alias_id: u16,
) std.mem.Allocator.Error!void {
    for (alias_ids.items, 0..) |existing, index| {
        if (existing == alias_id) return;
        if (existing > alias_id) {
            try alias_ids.insert(index, alias_id);
            return;
        }
    }
    try alias_ids.append(alias_id);
}

fn collectStateArrayOwners(
    allocator: std.mem.Allocator,
    comptime T: type,
    states: []const serialize.SerializedState,
    comptime getEntries: fn (serialize.SerializedState) []const T,
) std.mem.Allocator.Error![]usize {
    const owners = try allocator.alloc(usize, states.len);
    for (states, 0..) |state_value, index| {
        owners[index] = index;
        const entries = getEntries(state_value);
        if (entries.len == 0) continue;
        for (states[0..index], 0..) |previous_state, previous_index| {
            if (serializedEntrySlicesEql(T, entries, getEntries(previous_state))) {
                owners[index] = previous_index;
                break;
            }
        }
    }
    return owners;
}

fn collectRowSharingStats(
    comptime T: type,
    states: []const serialize.SerializedState,
    owners: []const usize,
    comptime getEntries: fn (serialize.SerializedState) []const T,
    has_shared_empty_array: bool,
) RowSharingStats {
    var stats = RowSharingStats{
        .total_rows = states.len,
        .empty_rows = 0,
        .unique_non_empty_rows = 0,
        .shared_non_empty_rows = 0,
        .emitted_array_definitions = 0,
    };

    for (states, 0..) |state_value, index| {
        const entries = getEntries(state_value);
        if (entries.len == 0) {
            stats.empty_rows += 1;
            continue;
        }
        if (owners[index] == index) {
            stats.unique_non_empty_rows += 1;
        } else {
            stats.shared_non_empty_rows += 1;
        }
    }

    stats.emitted_array_definitions = stats.unique_non_empty_rows;
    if (has_shared_empty_array and stats.empty_rows > 0) {
        stats.emitted_array_definitions += 1;
    }
    return stats;
}

fn stateActions(state_value: serialize.SerializedState) []const serialize.SerializedActionEntry {
    return state_value.actions;
}

fn stateGotos(state_value: serialize.SerializedState) []const serialize.SerializedGotoEntry {
    return state_value.gotos;
}

fn stateUnresolved(state_value: serialize.SerializedState) []const serialize.SerializedUnresolvedEntry {
    return state_value.unresolved;
}

fn serializedEntrySlicesEql(comptime T: type, left: []const T, right: []const T) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (!serializedEntryEql(T, left_entry, right_entry)) return false;
    }
    return true;
}

fn serializedEntryEql(comptime T: type, left: T, right: T) bool {
    if (T == serialize.SerializedActionEntry) {
        return symbolRefEql(left.symbol, right.symbol) and
            parseActionEql(left.action, right.action) and
            left.extra == right.extra and
            left.repetition == right.repetition;
    }
    if (T == serialize.SerializedGotoEntry) {
        return symbolRefEql(left.symbol, right.symbol) and left.state == right.state;
    }
    if (T == serialize.SerializedUnresolvedEntry) {
        return symbolRefEql(left.symbol, right.symbol) and
            left.reason == right.reason and
            parseActionSlicesEql(left.candidate_actions, right.candidate_actions);
    }
    @compileError("unsupported serialized entry type");
}

fn parseActionEql(left: @import("../parse_table/actions.zig").ParseAction, right: @import("../parse_table/actions.zig").ParseAction) bool {
    return switch (left) {
        .shift => |left_value| switch (right) {
            .shift => |right_value| left_value == right_value,
            else => false,
        },
        .reduce => |left_value| switch (right) {
            .reduce => |right_value| left_value == right_value,
            else => false,
        },
        .accept => switch (right) {
            .accept => true,
            else => false,
        },
    };
}

fn parseActionSlicesEql(
    left: []const @import("../parse_table/actions.zig").ParseAction,
    right: []const @import("../parse_table/actions.zig").ParseAction,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (!parseActionEql(left_entry, right_entry)) return false;
    }
    return true;
}

const EmittedSymbol = struct {
    ref: ?syntax_grammar.SymbolRef = null,
    label: []const u8,
    named: bool,
    visible: bool,
    supertype: bool,
    public_symbol: u16,
    owns_label: bool = false,
};

fn collectEmittedSymbols(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]EmittedSymbol {
    var symbols = std.array_list.Managed(EmittedSymbol).init(allocator);
    defer symbols.deinit();

    for (serialized.symbols) |symbol| {
        try appendUniqueEmittedSymbolWithMetadata(allocator, &symbols, .{
            .ref = symbol.ref,
            .label = symbol.name,
            .named = symbol.named,
            .visible = symbol.visible,
            .supertype = symbol.supertype,
            .public_symbol = symbol.public_symbol,
        });
    }

    for (serialized.states) |state| {
        for (state.actions) |entry| {
            try appendUniqueEmittedSymbol(allocator, &symbols, entry.symbol);
            switch (entry.action) {
                .reduce => |production_id| {
                    if (production_id < serialized.productions.len) {
                        try appendUniqueEmittedSymbol(allocator, &symbols, .{ .non_terminal = serialized.productions[production_id].lhs });
                    }
                },
                .shift, .accept => {},
            }
        }
        for (state.gotos) |entry| {
            try appendUniqueEmittedSymbol(allocator, &symbols, entry.symbol);
        }
        for (state.unresolved) |entry| {
            try appendUniqueEmittedSymbol(allocator, &symbols, entry.symbol);
            for (entry.candidate_actions) |candidate| {
                switch (candidate) {
                    .reduce => |production_id| {
                        if (production_id < serialized.productions.len) {
                            try appendUniqueEmittedSymbol(allocator, &symbols, .{ .non_terminal = serialized.productions[production_id].lhs });
                        }
                    },
                    .shift, .accept => {},
                }
            }
        }
    }

    for (serialized.alias_sequences) |alias| {
        if (symbolKindIsNonTerminal(alias.original_symbol)) {
            try appendUniqueEmittedSymbol(allocator, &symbols, alias.original_symbol);
        }
        try appendUniqueAliasSymbol(&symbols, alias.name, alias.named);
    }

    for (serialized.lex_tables) |lex_table| {
        for (lex_table.states) |lex_state| {
            if (lex_state.accept_symbol) |symbol| {
                try appendUniqueEmittedSymbol(allocator, &symbols, symbol);
            }
        }
    }
    if (serialized.keyword_lex_table) |keyword_lex_table| {
        for (keyword_lex_table.states) |lex_state| {
            if (lex_state.accept_symbol) |symbol| {
                try appendUniqueEmittedSymbol(allocator, &symbols, symbol);
            }
        }
    }
    for (serialized.external_scanner.symbols) |symbol| {
        try appendUniqueEmittedSymbol(allocator, &symbols, symbol);
    }

    for (serialized.supertype_map.symbols) |symbol| {
        try appendUniqueEmittedSymbol(allocator, &symbols, symbol);
    }
    for (serialized.supertype_map.entries) |entry| {
        if (entry.alias_name) |name| {
            try appendUniqueAliasSymbol(&symbols, name, entry.alias_named);
        } else {
            try appendUniqueEmittedSymbol(allocator, &symbols, entry.symbol);
        }
    }
    for (serialized.reserved_words.sets) |set| {
        for (set) |symbol| {
            try appendUniqueEmittedSymbol(allocator, &symbols, symbol);
        }
    }

    std.mem.sort(EmittedSymbol, symbols.items, {}, emittedSymbolLessThan);
    assignPublicSymbolIds(symbols.items);
    return try symbols.toOwnedSlice();
}

fn appendUniqueEmittedSymbol(
    allocator: std.mem.Allocator,
    symbols: *std.array_list.Managed(EmittedSymbol),
    symbol: syntax_grammar.SymbolRef,
) EmitError!void {
    const index = symbols.items.len;
    try appendUniqueEmittedSymbolWithMetadata(allocator, symbols, .{
        .ref = symbol,
        .label = try fallbackSymbolLabelAlloc(allocator, symbol),
        .named = !symbolKindIsTerminal(symbol),
        .visible = !symbolKindIsExternal(symbol) and symbol != .end,
        .supertype = false,
        .public_symbol = @intCast(index),
        .owns_label = true,
    });
}

fn appendUniqueAliasSymbol(
    symbols: *std.array_list.Managed(EmittedSymbol),
    name: []const u8,
    named: bool,
) EmitError!void {
    for (symbols.items) |existing| {
        if (existing.ref == null and existing.named == named and std.mem.eql(u8, existing.label, name)) return;
    }

    try symbols.append(.{
        .label = name,
        .named = named,
        .visible = true,
        .supertype = false,
        .public_symbol = @intCast(symbols.items.len),
    });
}

fn appendUniqueEmittedSymbolWithMetadata(
    allocator: std.mem.Allocator,
    symbols: *std.array_list.Managed(EmittedSymbol),
    symbol: EmittedSymbol,
) EmitError!void {
    for (symbols.items) |existing| {
        if (existing.ref != null and symbol.ref != null and symbolRefEql(existing.ref.?, symbol.ref.?)) {
            if (symbol.owns_label) allocator.free(symbol.label);
            return;
        }
    }

    try symbols.append(symbol);
}

fn fallbackSymbolLabelAlloc(
    allocator: std.mem.Allocator,
    symbol: syntax_grammar.SymbolRef,
) EmitError![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try common.writeSymbol(&buffer.writer, symbol);
    return try buffer.toOwnedSlice();
}

fn writeCStringLiteralContents(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
}

fn deinitEmittedSymbols(allocator: std.mem.Allocator, symbols: []EmittedSymbol) void {
    for (symbols) |symbol| {
        if (symbol.owns_label) allocator.free(symbol.label);
    }
    allocator.free(symbols);
}

fn assignPublicSymbolIds(symbols: []EmittedSymbol) void {
    for (symbols, 0..) |*symbol, index| {
        symbol.public_symbol = @intCast(canonicalPublicSymbolIndex(symbols[0 .. index + 1], symbol.*));
    }
}

fn canonicalPublicSymbolIndex(symbols: []const EmittedSymbol, symbol: EmittedSymbol) usize {
    for (symbols, 0..) |candidate, index| {
        if (publicSymbolKeyEql(candidate, symbol)) return index;
    }
    return symbols.len - 1;
}

fn publicSymbolKeyEql(left: EmittedSymbol, right: EmittedSymbol) bool {
    return left.named == right.named and std.mem.eql(u8, left.label, right.label);
}

fn emittedSymbolLessThan(_: void, a: EmittedSymbol, b: EmittedSymbol) bool {
    if (a.ref) |a_ref| {
        if (b.ref) |b_ref| return symbolSortKey(a_ref) < symbolSortKey(b_ref);
        return true;
    }
    if (b.ref != null) return false;
    if (a.named != b.named) return a.named and !b.named;
    return std.mem.lessThan(u8, a.label, b.label);
}

fn symbolIdForRef(symbols: []const EmittedSymbol, symbol: syntax_grammar.SymbolRef) ?u16 {
    for (symbols, 0..) |entry, index| {
        if (entry.ref) |entry_ref| {
            if (symbolRefEql(entry_ref, symbol)) return @intCast(index);
        }
    }
    return null;
}

fn actionKindCode(action: @import("../parse_table/actions.zig").ParseAction) u16 {
    return switch (action) {
        .shift => 1,
        .reduce => 2,
        .accept => 3,
    };
}

fn unresolvedReasonCode(reason: @import("../parse_table/resolution.zig").UnresolvedReason) u16 {
    return switch (reason) {
        .shift_reduce => 1,
        .shift_reduce_expected => 1,
        .reduce_reduce_deferred => 2,
        .reduce_reduce_expected => 2,
        .multiple_candidates => 3,
        .unsupported_action_mix => 4,
    };
}

fn symbolSortKey(symbol: syntax_grammar.SymbolRef) u64 {
    return switch (symbol) {
        .end => 0,
        .terminal => |index| (@as(u64, 1) << 32) | index,
        .external => |index| (@as(u64, 2) << 32) | index,
        .non_terminal => |index| (@as(u64, 3) << 32) | index,
    };
}

fn symbolRefEql(a: syntax_grammar.SymbolRef, b: syntax_grammar.SymbolRef) bool {
    return switch (a) {
        .end => switch (b) {
            .end => true,
            else => false,
        },
        .non_terminal => |index| switch (b) {
            .non_terminal => |other| index == other,
            else => false,
        },
        .terminal => |index| switch (b) {
            .terminal => |other| index == other,
            else => false,
        },
        .external => |index| switch (b) {
            .external => |other| index == other,
            else => false,
        },
    };
}

fn symbolKindIsTerminal(symbol: syntax_grammar.SymbolRef) bool {
    return switch (symbol) {
        .end, .terminal => true,
        .non_terminal, .external => false,
    };
}

fn symbolKindIsNonTerminal(symbol: syntax_grammar.SymbolRef) bool {
    return switch (symbol) {
        .non_terminal => true,
        .end, .terminal, .external => false,
    };
}

fn symbolKindIsExternal(symbol: syntax_grammar.SymbolRef) bool {
    return switch (symbol) {
        .external => true,
        .end, .non_terminal, .terminal => false,
    };
}

fn symbolKindCode(symbol: syntax_grammar.SymbolRef) u16 {
    return switch (symbol) {
        .end => 2,
        .non_terminal => 1,
        .terminal => 2,
        .external => 3,
    };
}

fn hasUnresolvedStates(serialized: serialize.SerializedTable) bool {
    for (serialized.states) |state| {
        if (state.unresolved.len > 0) return true;
    }
    return false;
}

test "emitParserCAlloc formats parser C skeletons deterministically" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = true,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
                },
                .gotos = &[_]serialize.SerializedGotoEntry{
                    .{ .symbol = .{ .non_terminal = 1 }, .state = 3 },
                },
                .unresolved = &[_]serialize.SerializedUnresolvedEntry{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .reason = .shift_reduce,
                        .candidate_actions = &[_]@import("../parse_table/actions.zig").ParseAction{
                            .{ .shift = 4 },
                            .{ .reduce = 5 },
                        },
                    },
                },
            },
        },
    };

    const emitted = try emitParserCAlloc(allocator, serialized);
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#include <stdint.h>\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSParseActionEntry ts_parse_actions[] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const uint16_t ts_parse_table[LARGE_STATE_COUNT][SYMBOL_COUNT] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSLanguage ts_language = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, ".parse_actions = ts_parse_actions,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, ".symbol_names = ts_symbol_names,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, ".lex_modes = ts_lex_modes,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "struct TSLanguage {\n"));
    try std.testing.expect(std.mem.indexOf(u8, emitted, "typedef struct { uint16_t symbol_id; uint16_t kind; uint16_t value; } TSActionEntry;") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "const TSParser *ts_parser_instance(void)") == null);
}

test "emitParserCAlloc emits EOF as builtin symbol zero" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .end = {} }, .action = .accept },
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAlloc(allocator, serialized);
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = \"end\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { .visible = false, .named = false, .supertype = false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "    [0] = ACTIONS("));
}

test "emitParserCAlloc compacts identical serialized states before row sharing" {
    const allocator = std.testing.allocator;
    const duplicate_unresolved = [_]@import("../parse_table/actions.zig").ParseAction{
        .{ .shift = 7 },
        .{ .reduce = 8 },
    };
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                },
                .gotos = &[_]serialize.SerializedGotoEntry{
                    .{ .symbol = .{ .non_terminal = 0 }, .state = 9 },
                },
                .unresolved = &[_]serialize.SerializedUnresolvedEntry{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .reason = .shift_reduce,
                        .candidate_actions = &duplicate_unresolved,
                    },
                },
            },
            .{
                .id = 1,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                },
                .gotos = &[_]serialize.SerializedGotoEntry{
                    .{ .symbol = .{ .non_terminal = 0 }, .state = 9 },
                },
                .unresolved = &[_]serialize.SerializedUnresolvedEntry{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .reason = .shift_reduce,
                        .candidate_actions = &duplicate_unresolved,
                    },
                },
            },
        },
    };

    const emitted = try emitParserCAlloc(allocator, serialized);
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define STATE_COUNT 1\n"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, emitted, "static const TSActionEntry ts_state_0_actions[] = {\n"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, emitted, "static const TSGotoEntry ts_state_0_gotos[] = {\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, emitted, "static const TSUnresolvedEntry ts_state_0_unresolved[] = {\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, emitted, "static const TSParseActionEntry ts_parse_actions[] = {\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, emitted, "[1] = { .entry = { .count = 1, .reusable = true } }"));
}

test "emitParserCAlloc emits prepared symbol metadata and grammar name" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_name = "quote\"grammar",
        .symbols = &[_]serialize.SerializedSymbolInfo{
            .{
                .ref = .{ .terminal = 1 },
                .name = "string\"token",
                .named = true,
                .visible = true,
                .supertype = false,
                .public_symbol = 4,
            },
            .{
                .ref = .{ .non_terminal = 0 },
                .name = "source_file",
                .named = true,
                .visible = true,
                .supertype = true,
                .public_symbol = 0,
            },
        },
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 2 }, .action = .{ .shift = 1 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = \"string\\\"token\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = \"terminal:2\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = \"source_file\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { .visible = true, .named = true, .supertype = false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { .visible = true, .named = false, .supertype = false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = { .visible = true, .named = true, .supertype = true },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = 0,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = 1,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = 2,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .name = \"quote\\\"grammar\",\n"));
}

test "emitParserCAlloc emits semantic grammar metadata" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_version = .{ 1, 2, 3 },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        emitted,
        1,
        "  .metadata = { .major_version = 1, .minor_version = 2, .patch_version = 3 },\n",
    ));
}

test "emitParserCAlloc emits zero semantic grammar metadata" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .grammar_version = .{ 0, 0, 0 },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        emitted,
        1,
        "  .metadata = { .major_version = 0, .minor_version = 0, .patch_version = 0 },\n",
    ));
}

test "emitParserCAlloc emits serialized supertype tables" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .symbols = &[_]serialize.SerializedSymbolInfo{
            .{ .ref = .{ .non_terminal = 0 }, .name = "source_file", .named = true, .visible = true, .supertype = false, .public_symbol = 0 },
            .{ .ref = .{ .non_terminal = 1 }, .name = "expression", .named = true, .visible = true, .supertype = true, .public_symbol = 1 },
            .{ .ref = .{ .non_terminal = 2 }, .name = "identifier", .named = true, .visible = true, .supertype = false, .public_symbol = 2 },
            .{ .ref = .{ .non_terminal = 3 }, .name = "number", .named = true, .visible = true, .supertype = false, .public_symbol = 3 },
        },
        .supertype_map = .{
            .symbols = &[_]syntax_grammar.SymbolRef{
                .{ .non_terminal = 1 },
            },
            .entries = &[_]serialize.SerializedSupertypeMapEntry{
                .{ .symbol = .{ .non_terminal = 2 } },
                .{ .symbol = .{ .non_terminal = 3 }, .alias_name = "number_alias", .alias_named = true },
            },
            .slices = &[_]serialize.SerializedSupertypeMapSlice{
                .{ .supertype = .{ .non_terminal = 1 }, .index = 0, .length = 2 },
            },
        },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSSymbol ts_supertype_symbols[] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSMapSlice ts_supertype_map_slices[SYMBOL_COUNT] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSSymbol ts_supertype_map_entries[] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { .index = 0, .length = 2 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .supertype_count = 1,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .supertype_symbols = ts_supertype_symbols,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .supertype_map_slices = ts_supertype_map_slices,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .supertype_map_entries = ts_supertype_map_entries,\n"));
}

test "emitParserCAlloc emits serialized field map tables" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .field_map = .{
            .names = &[_]serialize.SerializedFieldName{
                .{ .id = 1, .name = "left" },
                .{ .id = 2, .name = "right\"field" },
            },
            .entries = &[_]serialize.SerializedFieldMapEntry{
                .{ .field_id = 1, .child_index = 0, .inherited = false },
                .{ .field_id = 2, .child_index = 2, .inherited = true },
            },
            .slices = &[_]serialize.SerializedFieldMapSlice{
                .{ .index = 0, .length = 2 },
            },
        },
        .productions = &[_]serialize.SerializedProductionInfo{
            .{ .lhs = 0, .child_count = 3, .dynamic_precedence = 0 },
        },
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define FIELD_COUNT 2\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const char * const ts_field_names[FIELD_COUNT + 1] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = \"\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = \"left\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = \"right\\\"field\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSFieldMapEntry ts_field_map_entries[] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { .field_id = 1, .child_index = 0, .inherited = false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { .field_id = 2, .child_index = 2, .inherited = true },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSMapSlice ts_field_map_slices[] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { .index = 0, .length = 2 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .field_count = FIELD_COUNT,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .field_names = ts_field_names,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .field_map_slices = ts_field_map_slices,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .field_map_entries = ts_field_map_entries,\n"));
}

test "emitParserCAlloc emits runtime alias sequences" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .symbols = &[_]serialize.SerializedSymbolInfo{
            .{
                .ref = .{ .non_terminal = 0 },
                .name = "source_file",
                .named = true,
                .visible = true,
                .supertype = false,
                .public_symbol = 0,
            },
            .{
                .ref = .{ .non_terminal = 1 },
                .name = "value_alias",
                .named = true,
                .visible = true,
                .supertype = false,
                .public_symbol = 1,
            },
        },
        .productions = &[_]serialize.SerializedProductionInfo{
            .{ .lhs = 0, .child_count = 2, .dynamic_precedence = 0 },
            .{ .lhs = 1, .child_count = 3, .dynamic_precedence = 0 },
        },
        .alias_sequences = &[_]serialize.SerializedAliasEntry{
            .{ .production_id = 0, .step_index = 1, .original_symbol = .{ .non_terminal = 0 }, .name = "value_alias", .named = true },
            .{ .production_id = 1, .step_index = 2, .original_symbol = .{ .non_terminal = 1 }, .name = "anon_alias", .named = false },
            .{ .production_id = 1, .step_index = 0, .original_symbol = .{ .non_terminal = 1 }, .name = "value_alias", .named = true },
        },
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAlloc(allocator, serialized);
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define ALIAS_COUNT 2\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define MAX_ALIAS_SEQUENCE_LENGTH 3\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const uint16_t ts_non_terminal_alias_map[] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  0, 2,\n    0,\n    2,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  1, 3,\n    1,\n    2,\n    3,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSSymbol ts_alias_sequences[][MAX_ALIAS_SEQUENCE_LENGTH > 0 ? MAX_ALIAS_SEQUENCE_LENGTH : 1] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .alias_count = ALIAS_COUNT,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .max_alias_sequence_length = MAX_ALIAS_SEQUENCE_LENGTH,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .alias_sequences = &ts_alias_sequences[0][0],\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "\"value_alias\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "\"anon_alias\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { 0, 2, 0 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { 2, 0, 3 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = 1,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [3] = 3,\n"));
}

test "emitParserCAlloc keeps emitted GLR loop feature disabled by default" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.indexOf(u8, emitted, "GEN_Z_SITTER_ENABLE_GLR_LOOP") == null);
}

test "emitParserCAlloc emits opt-in GLR loop feature macro" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define GEN_Z_SITTER_ENABLE_GLR_LOOP 1\n\n"));
}

test "emitParserCAlloc emits opt-in GLR parser version storage" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define GEN_Z_SITTER_MAX_PARSE_VERSIONS 8\n\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define GEN_Z_SITTER_MAX_PARSE_STACK_DEPTH 256\n\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define GEN_Z_SITTER_MAX_VALUE_STACK_DEPTH 256\n\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define GEN_Z_SITTER_MAX_GENERATED_NODES 256\n\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define GEN_Z_SITTER_NO_NODE UINT16_MAX\n\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define GEN_Z_SITTER_MAX_ERROR_COST_DIFFERENCE 3\n\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define GEN_Z_SITTER_MAX_RECOVERY_ATTEMPTS 8\n\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "typedef struct {\n  TSSymbol symbol;\n  uint32_t start_byte;\n  uint32_t end_byte;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  uint16_t first_child;\n} TSGeneratedNode;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "typedef struct {\n  bool accepted;\n  uint32_t consumed_bytes;\n  uint16_t root_node;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  uint32_t error_count;\n  int32_t dynamic_precedence;\n  TSGeneratedNode nodes[GEN_Z_SITTER_MAX_GENERATED_NODES];\n} TSGeneratedParseResult;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "typedef struct {\n  TSSymbol symbol;\n  uint32_t start_byte;\n  uint32_t end_byte;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  uint16_t node_id;\n} TSGeneratedValue;\n\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "typedef struct {\n  TSStateId state;\n  TSStateId stack[GEN_Z_SITTER_MAX_PARSE_STACK_DEPTH];\n  TSGeneratedValue values[GEN_Z_SITTER_MAX_VALUE_STACK_DEPTH];\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  TSGeneratedNode nodes[GEN_Z_SITTER_MAX_GENERATED_NODES];\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  uint16_t value_len;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  uint16_t node_count;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  uint32_t error_count;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  bool shifted;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "TSGeneratedParseVersion versions[GEN_Z_SITTER_MAX_PARSE_VERSIONS];\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static void ts_generated_parse_versions_init(TSGeneratedParseVersionSet *set, TSStateId start_state) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_version_push_state(TSGeneratedParseVersion *version, TSStateId state) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_version_push_node(TSGeneratedParseVersion *version, TSGeneratedNode node, uint16_t *out_node_id) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_version_push_value(TSGeneratedParseVersion *version, TSGeneratedValue value) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_version_reduce_value(TSGeneratedParseVersion *version, const TSParseAction *action) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_version_push_shift_value(TSGeneratedParseVersion *version, TSSymbol symbol, uint32_t advance_bytes) {\n"));
}

test "emitParserCAlloc emits opt-in GLR parse table helpers" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static uint16_t ts_generated_parse_table_entry(TSStateId state, TSSymbol symbol) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "return ts_parse_table[state][symbol];\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSParseActionEntry *ts_generated_parse_actions_for(TSStateId state, TSSymbol symbol) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static TSStateId ts_generated_goto_state(TSStateId state, TSSymbol symbol) {\n"));
}

test "emitParserCAlloc emits opt-in GLR action dispatch helpers" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "typedef enum {\n  TSGeneratedParseStepNoAction,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static TSGeneratedParseStep ts_generated_apply_parse_action(TSGeneratedParseVersion *version, const TSParseAction *action) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (!ts_generated_version_push_state(version, action->shift.state)) break;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "version->shifted = true;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "version->dynamic_precedence += action->reduce.dynamic_precedence;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (version->stack_len <= action->reduce.child_count) break;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (!ts_generated_version_reduce_value(version, action)) break;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "version->stack_len -= action->reduce.child_count;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "TSStateId next = ts_generated_goto_state(top, action->reduce.symbol);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (!ts_generated_version_push_state(version, next)) break;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static TSGeneratedParseStep ts_generated_parse_version_step(TSGeneratedParseVersion *version, TSSymbol lookahead_symbol) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_recover_to_stack_action(TSGeneratedParseVersion *version, TSSymbol lookahead_symbol) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "const TSParseActionEntry *entry = ts_generated_parse_actions_for(candidate, lookahead_symbol);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "version->stack_len = depth;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "version->error_count++;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static TSGeneratedParseStep ts_generated_drive_version(TSGeneratedParseVersion *version, TSSymbol lookahead_symbol) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "uint8_t recovery_attempts = 0;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (recovery_attempts++ >= GEN_Z_SITTER_MAX_RECOVERY_ATTEMPTS) return step;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (ts_generated_recover_to_stack_action(version, lookahead_symbol)) continue;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (lookahead_symbol == 0) return step;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "version->byte_offset++;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "step.status = TSGeneratedParseStepRecover;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  } while (step.status == TSGeneratedParseStepReduce);\n"));
}

test "emitParserCAlloc emits opt-in GLR unresolved fork helpers" {
    const allocator = std.testing.allocator;
    const candidates = [_]parse_actions.ParseAction{
        .{ .shift = 1 },
        .{ .reduce = 0 },
    };
    const serialized = serialize.SerializedTable{
        .blocked = true,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
                },
                .gotos = &.{},
                .unresolved = &[_]serialize.SerializedUnresolvedEntry{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .reason = .shift_reduce,
                        .candidate_actions = &candidates,
                    },
                },
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_clone_parse_version(TSGeneratedParseVersionSet *set, uint16_t source_index, uint16_t *target_index) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static uint16_t ts_generated_fork_unresolved_actions(TSGeneratedParseVersionSet *set, uint16_t version_index, TSSymbol lookahead_symbol, uint32_t advance_bytes) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (unresolved->symbol_id != lookahead_symbol) continue;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "set->versions[target_index].shifted = false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "TSGeneratedParseStep step = ts_generated_apply_parse_action(&set->versions[target_index], &action_entry[1 + action_index].action);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (step.status == TSGeneratedParseStepShift && !ts_generated_version_push_shift_value(&set->versions[target_index], lookahead_symbol, advance_bytes)) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (step.status == TSGeneratedParseStepReduce) (void)ts_generated_drive_version(&set->versions[target_index], lookahead_symbol);\n"));
}

test "emitParserCAlloc emits opt-in GLR version condensation helpers" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_parse_versions_same_position(const TSGeneratedParseVersion *left, const TSGeneratedParseVersion *right) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (left->stack_len != right->stack_len) return false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (left->value_len != right->value_len) return false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (left->stack[index] != right->stack[index]) return false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (left->values[index].symbol != right->values[index].symbol) return false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (left->values[index].node_id != right->values[index].node_id) return false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (left->node_count != right->node_count) return false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (left->nodes[index].first_child != right->nodes[index].first_child) return false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static void ts_generated_condense_parse_versions(TSGeneratedParseVersionSet *set) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "uint32_t min_error_count = UINT32_MAX;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "set->versions[read_index].error_count > min_error_count + GEN_Z_SITTER_MAX_ERROR_COST_DIFFERENCE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (!set->versions[read_index].active) continue;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "set->versions[existing_index] = set->versions[read_index];\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "set->versions[existing_index].dynamic_precedence = set->versions[read_index].dynamic_precedence;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "set->count = write_index;\n"));
}

test "emitParserCAlloc emits opt-in GLR active-version step loop" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_step_parse_versions(TSGeneratedParseVersionSet *set, uint16_t lead_index, TSSymbol lookahead_symbol, uint32_t advance_bytes) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "uint32_t target_byte_offset = set->versions[lead_index].byte_offset;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (version->byte_offset != target_byte_offset || version->state != target_state) continue;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "TSGeneratedParseStep step = ts_generated_drive_version(version, lookahead_symbol);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (step.status == TSGeneratedParseStepShift && !ts_generated_version_push_shift_value(version, step.symbol, advance_bytes)) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "version->shifted = false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "version->active = false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "ts_generated_condense_parse_versions(set);\n"));
}

test "emitParserCAlloc emits opt-in GLR raw input lexer adapter" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .lex_modes = &[_]lexer_serialize.SerializedLexMode{
            .{ .lex_state = 3 },
        },
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "typedef struct {\n  TSLexer base;\n  const char *input;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static void ts_generated_input_lexer_advance(TSLexer *base, bool skip) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_generated_lex_symbol(const char *input, uint32_t length, TSStateId parse_state, TSSymbol *out_symbol, uint32_t *out_advance_bytes) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (!ts_lex(&lexer.base, ts_lex_modes[parse_state].lex_state)) return false;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "*out_symbol = lexer.base.result_symbol;\n"));
}

test "emitParserCAlloc emits opt-in GLR raw input parse entry point" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "bool ts_generated_parse_result(const char *input, uint32_t length, TSGeneratedParseResult *out_result) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "TSGeneratedParseResult result = { 0 };\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "result.root_node = GEN_Z_SITTER_NO_NODE;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "ts_generated_parse_versions_init(&set, 0);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (!lead || set.versions[i].byte_offset < lead->byte_offset) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (!ts_generated_lex_symbol(input + lead->byte_offset, length - lead->byte_offset, lead->state, &lookahead_symbol, &advance_bytes)) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (out_result) *out_result = result;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "bool accepted = ts_generated_step_parse_versions(&set, lead_index, lookahead_symbol, advance_bytes);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "result.accepted = true;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "result.consumed_bytes = lead->byte_offset + advance_bytes;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "result.root_node = lead->value_len > 0 ? lead->values[lead->value_len - 1].node_id : GEN_Z_SITTER_NO_NODE;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "result.node_count = lead->node_count;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "result.error_count = lead->error_count;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "result.nodes[node_index] = lead->nodes[node_index];\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "bool ts_generated_parse(const char *input, uint32_t length, uint32_t *out_consumed_bytes) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "bool accepted = ts_generated_parse_result(input, length, &result);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "if (set.versions[i].shifted && advance_bytes > 0) set.versions[i].byte_offset += advance_bytes;\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "set.versions[i].shifted = false;\n"));
}

test "emitParserCAlloc emits serialized lex modes" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .lex_modes = &[_]lexer_serialize.SerializedLexMode{
            .{ .lex_state = 3, .external_lex_state = 0, .reserved_word_set_id = 1 },
            .{ .lex_state = 9, .external_lex_state = 2, .reserved_word_set_id = 0 },
        },
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
            .{
                .id = 1,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSLexerMode ts_lex_modes[STATE_COUNT] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { .lex_state = 3, .external_lex_state = 0, .reserved_word_set_id = 1 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { .lex_state = 9, .external_lex_state = 2, .reserved_word_set_id = 0 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .lex_modes = ts_lex_modes,\n"));
}

test "emitParserCAlloc emits non-terminal extra lex-mode sentinel" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .lex_modes = &[_]lexer_serialize.SerializedLexMode{
            .{ .lex_state = std.math.maxInt(u16) },
        },
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        emitted,
        1,
        "  [0] = { .lex_state = 65535, .external_lex_state = 0, .reserved_word_set_id = 0 },\n",
    ));
}

test "emitParserCAlloc emits serialized lexer tables and remaps lex mode starts" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .symbols = &[_]serialize.SerializedSymbolInfo{
            .{
                .ref = .{ .terminal = 0 },
                .name = "letter_a",
                .named = false,
                .visible = true,
                .supertype = false,
                .public_symbol = 0,
            },
            .{
                .ref = .{ .terminal = 1 },
                .name = "letter_b",
                .named = false,
                .visible = true,
                .supertype = false,
                .public_symbol = 1,
            },
        },
        .lex_modes = &[_]lexer_serialize.SerializedLexMode{
            .{ .lex_state = 0 },
            .{ .lex_state = 1 },
        },
        .lex_tables = &[_]lexer_serialize.SerializedLexTable{
            .{
                .start_state_id = 0,
                .states = &[_]lexer_serialize.SerializedLexState{
                    .{
                        .transitions = &[_]lexer_serialize.SerializedLexTransition{
                            .{
                                .ranges = &[_]lexer_serialize.SerializedCharacterRange{
                                    .{ .start = 'a', .end_inclusive = 'a' },
                                },
                                .next_state_id = 1,
                                .skip = false,
                            },
                        },
                    },
                    .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
                },
            },
            .{
                .start_state_id = 0,
                .states = &[_]lexer_serialize.SerializedLexState{
                    .{
                        .transitions = &[_]lexer_serialize.SerializedLexTransition{
                            .{
                                .ranges = &[_]lexer_serialize.SerializedCharacterRange{
                                    .{ .start = 'b', .end_inclusive = 'b' },
                                },
                                .next_state_id = 1,
                                .skip = false,
                            },
                        },
                    },
                    .{ .accept_symbol = .{ .terminal = 1 }, .transitions = &.{} },
                },
            },
        },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
            .{ .id = 1, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_lex(TSLexer *lexer, TSStateId state) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "    case 0:\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      if (lookahead == 97) ADVANCE(1);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "    case 2:\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      if (lookahead == 98) ADVANCE(3);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { .lex_state = 2, .external_lex_state = 0, .reserved_word_set_id = 0 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .keyword_lex_fn = NULL,\n"));
}

test "emitParserCAlloc emits compiler optimization pragmas for large lexer tables" {
    const allocator = std.testing.allocator;
    const lex_states = try allocator.alloc(lexer_serialize.SerializedLexState, compat.large_lexer_optimization_state_threshold + 1);
    defer allocator.free(lex_states);
    for (lex_states) |*state_value| {
        state_value.* = .{ .transitions = &.{} };
    }

    const serialized = serialize.SerializedTable{
        .blocked = false,
        .lex_tables = &[_]lexer_serialize.SerializedLexTable{
            .{
                .start_state_id = 0,
                .states = lex_states,
            },
        },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#pragma clang optimize off\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#pragma GCC optimize (\"O0\")\n"));
    const pragma_index = std.mem.indexOf(u8, emitted, "#pragma clang optimize off\n") orelse unreachable;
    const lexer_index = std.mem.indexOf(u8, emitted, "static bool ts_lex") orelse unreachable;
    try std.testing.expect(pragma_index < lexer_index);
}

test "emitParserCAlloc emits serialized reserved words" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .symbols = &[_]serialize.SerializedSymbolInfo{
            .{ .ref = .{ .terminal = 0 }, .name = "if", .named = false, .visible = true, .supertype = false, .public_symbol = 0 },
            .{ .ref = .{ .terminal = 1 }, .name = "else", .named = false, .visible = true, .supertype = false, .public_symbol = 1 },
        },
        .reserved_words = .{
            .sets = &[_][]const syntax_grammar.SymbolRef{
                &.{},
                &.{ .{ .terminal = 0 }, .{ .terminal = 1 } },
            },
            .max_size = 2,
        },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define MAX_RESERVED_WORD_SET_SIZE 2\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSSymbol ts_reserved_words[][MAX_RESERVED_WORD_SET_SIZE > 0 ? MAX_RESERVED_WORD_SET_SIZE : 1] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { 0, 0 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { 0, 1 },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .reserved_words = &ts_reserved_words[0][0],\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .max_reserved_word_set_size = 2,\n"));
}

test "emitParserCAlloc emits keyword lexer when serialized" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .symbols = &[_]serialize.SerializedSymbolInfo{
            .{ .ref = .{ .terminal = 0 }, .name = "if", .named = false, .visible = true, .supertype = false, .public_symbol = 0 },
            .{ .ref = .{ .terminal = 1 }, .name = "identifier", .named = true, .visible = true, .supertype = false, .public_symbol = 1 },
        },
        .word_token = .{ .terminal = 1 },
        .keyword_lex_table = .{
            .start_state_id = 0,
            .states = &[_]lexer_serialize.SerializedLexState{
                .{
                    .transitions = &[_]lexer_serialize.SerializedLexTransition{
                        .{
                            .ranges = &[_]lexer_serialize.SerializedCharacterRange{
                                .{ .start = 'i', .end_inclusive = 'i' },
                            },
                            .next_state_id = 1,
                            .skip = false,
                        },
                    },
                },
                .{ .accept_symbol = .{ .terminal = 0 }, .transitions = &.{} },
            },
        },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static bool ts_lex_keywords(TSLexer *lexer, TSStateId state) {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      if (lookahead == 105) ADVANCE(1);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "      ACCEPT_TOKEN(0);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .keyword_lex_fn = ts_lex_keywords,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .keyword_capture_token = 1,\n"));
}

test "emitParserCAlloc emits external scanner symbols and declarations" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = true,
        .grammar_name = "external grammar",
        .symbols = &[_]serialize.SerializedSymbolInfo{
            .{ .ref = .{ .external = 0 }, .name = "OPEN", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
            .{ .ref = .{ .external = 1 }, .name = "CLOSE", .named = false, .visible = false, .supertype = false, .public_symbol = 1 },
            .{ .ref = .{ .external = 2 }, .name = "ERROR_SENTINEL", .named = false, .visible = false, .supertype = false, .public_symbol = 2 },
        },
        .external_scanner = .{
            .symbols = &[_]syntax_grammar.SymbolRef{
                .{ .external = 0 },
                .{ .external = 1 },
                .{ .external = 2 },
            },
            .states = &[_][]const bool{
                &.{ false, false, false },
                &.{ true, false, false },
                &.{ true, true, false },
            },
        },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define EXTERNAL_TOKEN_COUNT 3\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "enum ts_external_scanner_symbol_identifiers {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  ts_external_token_OPEN = 0,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  ts_external_token_CLOSE = 1,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  ts_external_token_ERROR_SENTINEL = 2,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSSymbol ts_external_scanner_symbol_map[EXTERNAL_TOKEN_COUNT] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = 2,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const bool ts_external_scanner_states[][EXTERNAL_TOKEN_COUNT] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { false, false, false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { true, false, false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = { true, true, false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "extern void *tree_sitter_external_grammar_external_scanner_create(void);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "extern bool tree_sitter_external_grammar_external_scanner_scan(void *, TSLexer *, const bool *);\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "    .states = &ts_external_scanner_states[0][0],\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "    .symbol_map = ts_external_scanner_symbol_map,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "    .create = tree_sitter_external_grammar_external_scanner_create,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "    .deserialize = tree_sitter_external_grammar_external_scanner_deserialize,\n"));
}

test "emitParserCAlloc emits primary state ids by parse state" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .large_state_count = 3,
        .symbols = &[_]serialize.SerializedSymbolInfo{
            .{
                .ref = .{ .terminal = 0 },
                .name = "token",
                .named = false,
                .visible = true,
                .supertype = false,
                .public_symbol = 0,
            },
        },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .core_id = 4, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
            .{ .id = 1, .core_id = 9, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
            .{ .id = 2, .core_id = 4, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
        .primary_state_ids = &[_]@import("../parse_table/state.zig").StateId{ 0, 1, 0 },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSStateId ts_primary_state_ids[STATE_COUNT] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = 0,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = 1,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = 0,\n"));
}

test "emitParserCAlloc emits full runtime parse action fields" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .parse_action_list = &[_]serialize.SerializedParseActionListEntry{
            .{ .index = 0, .reusable = false, .actions = &.{} },
            .{
                .index = 1,
                .reusable = true,
                .actions = &[_]serialize.SerializedParseAction{
                    .{ .kind = .shift, .state = 9, .extra = true, .repetition = true },
                },
            },
            .{
                .index = 3,
                .reusable = false,
                .actions = &[_]serialize.SerializedParseAction{
                    .{ .kind = .recover },
                },
            },
        },
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "TSParseActionTypeShift"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, ".state = 9"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, ".extra = true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, ".repetition = true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "{ .action = { .type = TSParseActionTypeRecover } }"));
}

test "emitParserCAlloc emits self-contained C that compiles" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .productions = &[_]serialize.SerializedProductionInfo{
            .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
        },
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
                    .{ .symbol = .{ .terminal = 1 }, .action = .{ .reduce = 0 } },
                },
                .gotos = &[_]serialize.SerializedGotoEntry{
                    .{ .symbol = .{ .non_terminal = 0 }, .state = 1 },
                },
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAlloc(allocator, serialized);
    defer allocator.free(emitted);

    var result = try compile_smoke.compileParserC(allocator, emitted);
    defer result.deinit(allocator);

    try std.testing.expect(result == .success);
}

test "emitParserCAlloc emits opt-in GLR storage C that compiles" {
    const allocator = std.testing.allocator;
    const serialized = serialize.SerializedTable{
        .blocked = false,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    defer allocator.free(emitted);

    var result = try compile_smoke.compileParserC(allocator, emitted);
    defer result.deinit(allocator);

    try std.testing.expect(result == .success);
}

test "collectEmissionStats reports shared empty and canonical non-empty rows" {
    const allocator = std.testing.allocator;
    const duplicate_unresolved = [_]@import("../parse_table/actions.zig").ParseAction{
        .{ .shift = 7 },
        .{ .reduce = 8 },
    };
    const serialized = serialize.SerializedTable{
        .blocked = true,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                },
                .gotos = &[_]serialize.SerializedGotoEntry{
                    .{ .symbol = .{ .non_terminal = 0 }, .state = 9 },
                },
                .unresolved = &[_]serialize.SerializedUnresolvedEntry{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .reason = .shift_reduce,
                        .candidate_actions = &duplicate_unresolved,
                    },
                },
            },
            .{
                .id = 1,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                },
                .gotos = &[_]serialize.SerializedGotoEntry{
                    .{ .symbol = .{ .non_terminal = 0 }, .state = 9 },
                },
                .unresolved = &[_]serialize.SerializedUnresolvedEntry{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .reason = .shift_reduce,
                        .candidate_actions = &duplicate_unresolved,
                    },
                },
            },
            .{
                .id = 2,
                .actions = &.{},
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
    };

    const stats = try collectEmissionStats(allocator, serialized);

    try std.testing.expectEqual(@as(usize, 2), stats.state_count);
    try std.testing.expectEqual(@as(usize, 1), stats.merged_state_count);
    try std.testing.expect(stats.blocked);
    try std.testing.expectEqual(@as(usize, 1), stats.action_entry_count);
    try std.testing.expectEqual(@as(usize, 1), stats.goto_entry_count);
    try std.testing.expectEqual(@as(usize, 1), stats.unresolved_entry_count);

    try std.testing.expectEqual(RowSharingStats{
        .total_rows = 2,
        .empty_rows = 1,
        .unique_non_empty_rows = 1,
        .shared_non_empty_rows = 0,
        .emitted_array_definitions = 2,
    }, stats.action_rows);
    try std.testing.expectEqual(RowSharingStats{
        .total_rows = 2,
        .empty_rows = 1,
        .unique_non_empty_rows = 1,
        .shared_non_empty_rows = 0,
        .emitted_array_definitions = 2,
    }, stats.goto_rows);
    try std.testing.expectEqual(RowSharingStats{
        .total_rows = 2,
        .empty_rows = 1,
        .unique_non_empty_rows = 1,
        .shared_non_empty_rows = 0,
        .emitted_array_definitions = 1,
    }, stats.unresolved_rows);
}

test "collectEmissionStatsWithOptions preserves duplicate states when compaction is disabled" {
    const allocator = std.testing.allocator;
    const duplicate_unresolved = [_]@import("../parse_table/actions.zig").ParseAction{
        .{ .shift = 7 },
        .{ .reduce = 8 },
    };
    const serialized = serialize.SerializedTable{
        .blocked = true,
        .states = &[_]serialize.SerializedState{
            .{
                .id = 0,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                },
                .gotos = &[_]serialize.SerializedGotoEntry{
                    .{ .symbol = .{ .non_terminal = 0 }, .state = 1 },
                },
                .unresolved = &[_]serialize.SerializedUnresolvedEntry{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .reason = .shift_reduce,
                        .candidate_actions = &duplicate_unresolved,
                    },
                },
            },
            .{
                .id = 1,
                .actions = &[_]serialize.SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                },
                .gotos = &[_]serialize.SerializedGotoEntry{
                    .{ .symbol = .{ .non_terminal = 0 }, .state = 1 },
                },
                .unresolved = &[_]serialize.SerializedUnresolvedEntry{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .reason = .shift_reduce,
                        .candidate_actions = &duplicate_unresolved,
                    },
                },
            },
        },
    };

    const stats = try collectEmissionStatsWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
    });

    try std.testing.expectEqual(@as(usize, 2), stats.state_count);
    try std.testing.expectEqual(@as(usize, 0), stats.merged_state_count);
    try std.testing.expectEqual(@as(usize, 2), stats.action_entry_count);
    try std.testing.expectEqual(@as(usize, 2), stats.goto_entry_count);
    try std.testing.expectEqual(@as(usize, 2), stats.unresolved_entry_count);
    try std.testing.expectEqual(@as(usize, 1), stats.action_rows.shared_non_empty_rows);
    try std.testing.expectEqual(@as(usize, 1), stats.goto_rows.shared_non_empty_rows);
    try std.testing.expectEqual(@as(usize, 1), stats.unresolved_rows.shared_non_empty_rows);
}

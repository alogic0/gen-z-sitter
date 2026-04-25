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
    const emitted_symbols = try collectEmittedSymbols(allocator, compacted);
    defer deinitEmittedSymbols(allocator, emitted_symbols);
    const parse_action_list = if (compacted.parse_action_list.len > 0)
        compacted.parse_action_list
    else
        try serialize.buildParseActionListAlloc(arena.allocator(), compacted.states, compacted.productions);
    const small_parse_table = if (compacted.small_parse_table.rows.len > 0 or compacted.small_parse_table.map.len > 0)
        compacted.small_parse_table
    else
        try serialize.buildSmallParseTableAlloc(arena.allocator(), compacted.states, serializedLargeStateCount(compacted), parse_action_list, compacted.productions);
    const runtime_lex = try buildRuntimeLexTableAlloc(arena.allocator(), compacted.lex_tables);

    try compat.writeContractPrelude(writer, compatibility);
    try compat.writeContractTypesAndConstants(writer, compatibility);
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

    const keyword_capture_id: u16 = if (compacted.word_token) |wt|
        symbolIdForRef(emitted_symbols, wt) orelse 0
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
        try lexer_emit_c.emitLexFunctionWithResolver(
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
        try lexer_emit_c.emitLexFunctionWithResolver(
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
            const action_index = serialize.parseActionListIndexForParseAction(parse_action_list, entry.action, compacted.productions) orelse return error.OutOfMemory;
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
        return symbolRefEql(left.symbol, right.symbol) and parseActionEql(left.action, right.action);
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
        .visible = !symbolKindIsExternal(symbol),
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
        .reduce_reduce_deferred => 2,
        .reduce_reduce_expected => 2,
        .multiple_candidates => 3,
        .unsupported_action_mix => 4,
    };
}

fn symbolSortKey(symbol: syntax_grammar.SymbolRef) u64 {
    return switch (symbol) {
        .non_terminal => |index| (@as(u64, 0) << 32) | index,
        .terminal => |index| (@as(u64, 1) << 32) | index,
        .external => |index| (@as(u64, 2) << 32) | index,
    };
}

fn symbolRefEql(a: syntax_grammar.SymbolRef, b: syntax_grammar.SymbolRef) bool {
    return switch (a) {
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
        .terminal => true,
        .non_terminal, .external => false,
    };
}

fn symbolKindIsNonTerminal(symbol: syntax_grammar.SymbolRef) bool {
    return switch (symbol) {
        .non_terminal => true,
        .terminal, .external => false,
    };
}

fn symbolKindIsExternal(symbol: syntax_grammar.SymbolRef) bool {
    return switch (symbol) {
        .external => true,
        .non_terminal, .terminal => false,
    };
}

fn symbolKindCode(symbol: syntax_grammar.SymbolRef) u16 {
    return switch (symbol) {
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
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, emitted, "static const TSUnresolvedEntry ts_state_0_unresolved[] = {\n"));
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

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = \"source_file\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = \"string\\\"token\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = \"terminal:2\",\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [0] = { .visible = true, .named = true, .supertype = true },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { .visible = true, .named = true, .supertype = false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = { .visible = true, .named = false, .supertype = false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = 1,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = 2,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  .name = \"quote\\\"grammar\",\n"));
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
                .{ .field_id = 2, .child_index = 2, .inherited = false },
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
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { .field_id = 2, .child_index = 2, .inherited = false },\n"));
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
            .{ .ref = .{ .external = 0 }, .name = "_indent", .named = false, .visible = false, .supertype = false, .public_symbol = 0 },
            .{ .ref = .{ .external = 1 }, .name = "dedent-token", .named = false, .visible = false, .supertype = false, .public_symbol = 1 },
        },
        .external_scanner = .{
            .symbols = &[_]syntax_grammar.SymbolRef{
                .{ .external = 0 },
                .{ .external = 1 },
            },
            .states = &[_][]const bool{
                &.{ false, false },
                &.{ true, false },
                &.{ true, true },
            },
        },
        .states = &[_]serialize.SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
    };

    const emitted = try emitParserCAllocWithOptions(allocator, serialized, .{ .compact_duplicate_states = false });
    defer allocator.free(emitted);

    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "#define EXTERNAL_TOKEN_COUNT 2\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "enum ts_external_scanner_symbol_identifiers {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  ts_external_token__indent = 0,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  ts_external_token_dedent_token = 1,\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const TSSymbol ts_external_scanner_symbol_map[EXTERNAL_TOKEN_COUNT] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "static const bool ts_external_scanner_states[][EXTERNAL_TOKEN_COUNT] = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [1] = { true, false },\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "  [2] = { true, true },\n"));
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

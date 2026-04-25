const std = @import("std");
const parse_actions = @import("../parse_table/actions.zig");
const serialize = @import("../parse_table/serialize.zig");
const syntax_grammar = @import("../ir/syntax_grammar.zig");
const common = @import("common.zig");
const compat = @import("compat.zig");
const compile_smoke = @import("../compat/compile_smoke.zig");
const optimize = @import("optimize.zig");

pub const EmitError = std.mem.Allocator.Error || std.Io.Writer.Error;

pub const RowSharingStats = struct {
    total_rows: usize,
    empty_rows: usize,
    unique_non_empty_rows: usize,
    shared_non_empty_rows: usize,
    emitted_array_definitions: usize,
};

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

pub fn emitParserCAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]const u8 {
    return try emitParserCAllocWithOptions(allocator, serialized, .{});
}

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

pub fn collectEmissionStats(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) std.mem.Allocator.Error!EmissionStats {
    return try collectEmissionStatsWithOptions(allocator, serialized, .{});
}

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

pub fn writeParserC(
    writer: anytype,
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) !void {
    return try writeParserCWithOptions(writer, allocator, serialized, .{});
}

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

    var action_lists = std.array_list.Managed(ParseActionList).init(allocator);
    defer action_lists.deinit();
    try action_lists.append(.{ .action = null, .index = 0 });

    try compat.writeContractPrelude(writer, compatibility);
    try compat.writeContractTypesAndConstants(writer, compatibility);
    try writer.print("#define STATE_COUNT {d}\n", .{compacted.states.len});
    try writer.print("#define LARGE_STATE_COUNT {d}\n", .{largeStateCount(compacted, emitted_symbols.len)});
    try writer.print("#define SYMBOL_COUNT {d}\n", .{emitted_symbols.len});
    try writer.print("#define TOKEN_COUNT {d}\n", .{tokenCount(emitted_symbols)});
    try writer.print("#define EXTERNAL_TOKEN_COUNT {d}\n", .{externalTokenCount(emitted_symbols)});
    try writer.print("#define PRODUCTION_ID_COUNT {d}\n", .{compacted.productions.len});
    try writer.writeAll("#define FIELD_COUNT 0\n");
    try writer.print("#define ALIAS_COUNT {d}\n", .{compacted.alias_sequences.len});
    try writer.writeAll("#define MAX_ALIAS_SEQUENCE_LENGTH 0\n\n");

    const keyword_capture_id: u16 = if (compacted.word_token) |wt|
        symbolIdForRef(emitted_symbols, wt) orelse 0
    else
        0;

    try writer.writeAll("static bool ts_lex(TSLexer *lexer, TSStateId state) {\n");
    try writer.writeAll("  (void)lexer;\n");
    try writer.writeAll("  (void)state;\n");
    try writer.writeAll("  return false;\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static const char * const ts_symbol_names[SYMBOL_COUNT] = {\n");
    for (emitted_symbols, 0..) |symbol, index| {
        try writer.print("  [{d}] = \"", .{index});
        try writer.writeAll(symbol.label);
        try writer.writeAll("\",\n");
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSSymbolMetadata ts_symbol_metadata[SYMBOL_COUNT] = {\n");
    for (emitted_symbols, 0..) |symbol, index| {
        const visible = !symbolKindIsExternal(symbol.ref);
        const named = !symbolKindIsTerminal(symbol.ref);
        try writer.print("  [{d}] = {{ .visible = {}, .named = {}, .supertype = false }},\n", .{ index, visible, named });
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSSymbol ts_symbol_map[SYMBOL_COUNT] = {\n");
    for (emitted_symbols, 0..) |_, index| {
        try writer.print("  [{d}] = {d},\n", .{ index, index });
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const uint16_t ts_non_terminal_alias_map[] = { 0 };\n");
    try writer.writeAll("static const TSStateId ts_primary_state_ids[SYMBOL_COUNT] = { 0 };\n\n");

    const large_state_count_value = largeStateCount(compacted, emitted_symbols.len);
    try writer.writeAll("static const uint16_t ts_parse_table[LARGE_STATE_COUNT][SYMBOL_COUNT] = {\n");
    for (compacted.states[0..large_state_count_value], 0..) |serialized_state, index| {
        try writer.print("  [STATE({d})] = {{\n", .{index});
        for (serialized_state.gotos) |entry| {
            const symbol_id = symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory;
            try writer.print("    [{d}] = STATE({d}),\n", .{ symbol_id, entry.state });
        }
        for (serialized_state.actions) |entry| {
            const symbol_id = symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory;
            const action_index = try internActionList(&action_lists, compacted, emitted_symbols, entry.action);
            try writer.print("    [{d}] = ACTIONS({d}),\n", .{ symbol_id, action_index });
        }
        try writer.writeAll("  },\n");
    }
    try writer.writeAll("};\n\n");

    if (large_state_count_value < compacted.states.len) {
        try writer.writeAll("static const uint16_t ts_small_parse_table[] = {\n");
        var offset: usize = 0;
        for (compacted.states[large_state_count_value..]) |serialized_state| {
            const entry_count = serialized_state.actions.len + serialized_state.gotos.len;
            try writer.print("  [{d}] = {d},\n", .{ offset, entry_count });
            offset += 1;
            for (serialized_state.gotos) |entry| {
                const symbol_id = symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory;
                try writer.print("  STATE({d}), 1, {d},\n", .{ entry.state, symbol_id });
                offset += 3;
            }
            for (serialized_state.actions) |entry| {
                const symbol_id = symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory;
                const action_index = try internActionList(&action_lists, compacted, emitted_symbols, entry.action);
                try writer.print("  ACTIONS({d}), 1, {d},\n", .{ action_index, symbol_id });
                offset += 3;
            }
        }
        try writer.writeAll("};\n\n");
        try writer.writeAll("static const uint32_t ts_small_parse_table_map[] = {\n");
        offset = 0;
        for (compacted.states[large_state_count_value..], large_state_count_value..) |serialized_state, index| {
            try writer.print("  [SMALL_STATE({d})] = {d},\n", .{ index, offset });
            offset += 1 + 3 * (serialized_state.actions.len + serialized_state.gotos.len);
        }
        try writer.writeAll("};\n\n");
    }

    try writer.writeAll("static const TSParseActionEntry ts_parse_actions[] = {\n");
    for (action_lists.items) |entry| {
        if (entry.action) |action| {
            try writer.print("  [{d}] = {{ .entry = {{ .count = 1, .reusable = true }} }}, ", .{entry.index});
            try writeRuntimeAction(writer, compacted, emitted_symbols, action);
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("  [0] = { .entry = { .count = 0, .reusable = false } },\n");
        }
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("static const TSLexerMode ts_lex_modes[STATE_COUNT] = {\n");
    for (compacted.states, 0..) |_, index| {
        try writer.print("  [{d}] = {{ .lex_state = 0, .external_lex_state = 0 }},\n", .{index});
    }
    try writer.writeAll("};\n\n");

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
    try writer.writeAll("  .symbol_metadata = ts_symbol_metadata,\n");
    try writer.writeAll("  .public_symbol_map = ts_symbol_map,\n");
    try writer.writeAll("  .alias_map = ts_non_terminal_alias_map,\n");
    try writer.writeAll("  .lex_modes = ts_lex_modes,\n");
    try writer.writeAll("  .lex_fn = ts_lex,\n");
    try writer.print("  .keyword_capture_token = {d},\n", .{keyword_capture_id});
    try writer.writeAll("  .primary_state_ids = ts_primary_state_ids,\n");
    try writer.writeAll("  .name = \"generated\",\n");
    try writer.writeAll("};\n\n");
    try writer.writeAll("const TSLanguage *tree_sitter_generated(void) {\n");
    try writer.writeAll("  return &ts_language;\n");
    try writer.writeAll("}\n");
}

const ParseActionList = struct {
    action: ?parse_actions.ParseAction,
    index: u16,
};

fn internActionList(
    action_lists: *std.array_list.Managed(ParseActionList),
    serialized: serialize.SerializedTable,
    symbols: []const EmittedSymbol,
    action: parse_actions.ParseAction,
) !u16 {
    for (action_lists.items) |entry| {
        if (entry.action) |existing| {
            if (runtimeActionEql(serialized, symbols, existing, action)) return entry.index;
        }
    }
    const index: u16 = @intCast(action_lists.items.len * 2 - 1);
    try action_lists.append(.{ .action = action, .index = index });
    return index;
}

fn runtimeActionEql(
    serialized: serialize.SerializedTable,
    symbols: []const EmittedSymbol,
    left: parse_actions.ParseAction,
    right: parse_actions.ParseAction,
) bool {
    return switch (left) {
        .shift => |left_state| switch (right) {
            .shift => |right_state| left_state == right_state,
            else => false,
        },
        .reduce => |left_production| switch (right) {
            .reduce => |right_production| blk: {
                const left_info = productionInfo(serialized, left_production);
                const right_info = productionInfo(serialized, right_production);
                const left_symbol = symbolIdForRef(symbols, .{ .non_terminal = left_info.lhs }) orelse 0;
                const right_symbol = symbolIdForRef(symbols, .{ .non_terminal = right_info.lhs }) orelse 0;
                break :blk left_info.child_count == right_info.child_count and
                    left_symbol == right_symbol and
                    left_info.dynamic_precedence == right_info.dynamic_precedence and
                    left_production == right_production;
            },
            else => false,
        },
        .accept => switch (right) {
            .accept => true,
            else => false,
        },
    };
}

fn writeRuntimeAction(
    writer: anytype,
    serialized: serialize.SerializedTable,
    symbols: []const EmittedSymbol,
    action: parse_actions.ParseAction,
) !void {
    switch (action) {
        .shift => |state_id| try writer.print("{{ .action = {{ .shift = {{ .type = TSParseActionTypeShift, .state = {d} }} }} }}", .{state_id}),
        .reduce => |production_id| {
            const info = productionInfo(serialized, production_id);
            const symbol_id = symbolIdForRef(symbols, .{ .non_terminal = info.lhs }) orelse 0;
            try writer.print(
                "{{ .action = {{ .reduce = {{ .type = TSParseActionTypeReduce, .child_count = {d}, .symbol = {d}, .dynamic_precedence = {d}, .production_id = {d} }} }} }}",
                .{ info.child_count, symbol_id, info.dynamic_precedence, production_id },
            );
        },
        .accept => try writer.writeAll("{ .action = { .type = TSParseActionTypeAccept } }"),
    }
}

fn productionInfo(serialized: serialize.SerializedTable, production_id: u32) serialize.SerializedProductionInfo {
    if (production_id < serialized.productions.len) return serialized.productions[production_id];
    return .{ .lhs = 0, .child_count = 0, .dynamic_precedence = 0 };
}

fn largeStateCount(serialized: serialize.SerializedTable, symbol_count: usize) usize {
    const threshold = @min(@as(usize, 64), symbol_count / 2);
    var count: usize = 0;
    for (serialized.states, 0..) |state_value, index| {
        if (index <= 1 or state_value.actions.len + state_value.gotos.len > threshold) {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

fn tokenCount(symbols: []const EmittedSymbol) usize {
    var count: usize = 0;
    for (symbols) |symbol| {
        if (symbolKindIsTerminal(symbol.ref) or symbolKindIsExternal(symbol.ref)) count += 1;
    }
    return count;
}

fn externalTokenCount(symbols: []const EmittedSymbol) usize {
    var count: usize = 0;
    for (symbols) |symbol| {
        if (symbolKindIsExternal(symbol.ref)) count += 1;
    }
    return count;
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
    ref: syntax_grammar.SymbolRef,
    label: []u8,
};

fn collectEmittedSymbols(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]EmittedSymbol {
    var symbols = std.array_list.Managed(EmittedSymbol).init(allocator);
    defer symbols.deinit();

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

    std.mem.sort(EmittedSymbol, symbols.items, {}, emittedSymbolLessThan);
    return try symbols.toOwnedSlice();
}

fn appendUniqueEmittedSymbol(
    allocator: std.mem.Allocator,
    symbols: *std.array_list.Managed(EmittedSymbol),
    symbol: syntax_grammar.SymbolRef,
) EmitError!void {
    for (symbols.items) |existing| {
        if (symbolRefEql(existing.ref, symbol)) return;
    }

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try common.writeSymbol(&buffer.writer, symbol);

    try symbols.append(.{
        .ref = symbol,
        .label = try buffer.toOwnedSlice(),
    });
}

fn deinitEmittedSymbols(allocator: std.mem.Allocator, symbols: []EmittedSymbol) void {
    for (symbols) |symbol| {
        allocator.free(symbol.label);
    }
    allocator.free(symbols);
}

fn emittedSymbolLessThan(_: void, a: EmittedSymbol, b: EmittedSymbol) bool {
    return symbolSortKey(a.ref) < symbolSortKey(b.ref);
}

fn symbolIdForRef(symbols: []const EmittedSymbol, symbol: syntax_grammar.SymbolRef) ?u16 {
    for (symbols, 0..) |entry, index| {
        if (symbolRefEql(entry.ref, symbol)) return @intCast(index);
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

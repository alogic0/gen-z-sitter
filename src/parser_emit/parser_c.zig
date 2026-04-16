const std = @import("std");
const serialize = @import("../parse_table/serialize.zig");
const syntax_grammar = @import("../ir/syntax_grammar.zig");
const common = @import("common.zig");
const compat = @import("compat.zig");

pub const EmitError = std.mem.Allocator.Error || std.fs.File.WriteError;

pub fn emitParserCAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try writeParserC(out.writer(), allocator, serialized);
    return try out.toOwnedSlice();
}

pub fn writeParserC(
    writer: anytype,
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) !void {
    const compatibility = compat.currentRuntimeCompatibility();
    const emitted_symbols = try collectEmittedSymbols(allocator, serialized);
    defer deinitEmittedSymbols(allocator, emitted_symbols);

    try compat.writeContractPrelude(writer, compatibility);
    try writer.print("#define TS_PARSER_BLOCKED {}\n", .{serialized.blocked});
    try writer.print("#define TS_STATE_COUNT {d}\n", .{serialized.states.len});
    try writer.print("#define TS_SYMBOL_COUNT {d}\n\n", .{emitted_symbols.len});
    try compat.writeContractTypesAndConstants(writer, compatibility);
    try writer.writeAll("static bool ts_string_eq(const char *a, const char *b) {\n");
    try writer.writeAll("  if (!a || !b) return false;\n");
    try writer.writeAll("  while (a[0] != 0 && b[0] != 0) {\n");
    try writer.writeAll("    if (a[0] != b[0]) return false;\n");
    try writer.writeAll("    a += 1;\n");
    try writer.writeAll("    b += 1;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return a[0] == b[0];\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("static const TSCompatibilityInfo ts_compatibility = {\n");
    try writer.print("  .language_version = {d},\n", .{compatibility.language_version});
    try writer.print("  .min_compatible_language_version = {d},\n", .{compatibility.min_compatible_language_version});
    try writer.writeAll("  .target = \"");
    try writer.writeAll(compat.targetName(compatibility.target));
    try writer.writeAll("\",\n");
    try writer.writeAll("  .layer = \"");
    try writer.writeAll(compat.layerName(compatibility.layer));
    try writer.writeAll("\",\n");
    try writer.writeAll("};\n\n");
    try writer.writeAll("static const TSSymbolInfo ts_symbols[TS_SYMBOL_COUNT] = {\n");
    for (emitted_symbols, 0..) |symbol, index| {
        try writer.writeAll("  {\n");
        try writer.print("    .id = {d},\n", .{index});
        try writer.writeAll("    .name = \"");
        try writer.writeAll(symbol.label);
        try writer.writeAll("\",\n");
        try writer.print("    .kind = {d},\n", .{symbolKindCode(symbol.ref)});
        try writer.print("    .terminal = {},\n", .{symbolKindIsTerminal(symbol.ref)});
        try writer.print("    .external = {},\n", .{symbolKindIsExternal(symbol.ref)});
        try writer.writeAll("  },\n");
    }
    try writer.writeAll("};\n\n");

    for (serialized.states, 0..) |serialized_state, index| {
        try writer.print("/* state {d} */\n", .{serialized_state.id});

        try writer.print("static const TSActionEntry ts_state_{d}_actions[] = {{\n", .{serialized_state.id});
        for (serialized_state.actions) |entry| {
            try writer.print(
                "  {{ {d}, {d}, ",
                .{
                    symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory,
                    actionKindCode(entry.action),
                },
            );
            try common.writeActionValue(writer, entry.action);
            try writer.writeAll(" },\n");
        }
        try writer.writeAll("};\n");

        try writer.print("static const TSGotoEntry ts_state_{d}_gotos[] = {{\n", .{serialized_state.id});
        for (serialized_state.gotos) |entry| {
            try writer.print(
                "  {{ {d}, {d} }},\n",
                .{
                    symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory,
                    entry.state,
                },
            );
        }
        try writer.writeAll("};\n");

        if (serialized_state.unresolved.len > 0) {
            try writer.print("static const TSUnresolvedEntry ts_state_{d}_unresolved[] = {{\n", .{serialized_state.id});
            for (serialized_state.unresolved) |entry| {
                try writer.print(
                    "  {{ {d}, {d}, {d} }},\n",
                    .{
                        symbolIdForRef(emitted_symbols, entry.symbol) orelse return error.OutOfMemory,
                        unresolvedReasonCode(entry.reason),
                        entry.candidate_actions.len,
                    },
                );
            }
            try writer.writeAll("};\n");
        }

        if (index + 1 < serialized.states.len) try writer.writeByte('\n');
    }

    try writer.writeAll("static const TSStateTable ts_states[TS_STATE_COUNT] = {\n");
    for (serialized.states) |serialized_state| {
        try writer.writeAll("  {\n");
        try writer.print("    .actions = ts_state_{d}_actions,\n", .{serialized_state.id});
        try writer.print("    .action_count = {d},\n", .{serialized_state.actions.len});
        try writer.print("    .gotos = ts_state_{d}_gotos,\n", .{serialized_state.id});
        try writer.print("    .goto_count = {d},\n", .{serialized_state.gotos.len});
        if (serialized_state.unresolved.len > 0) {
            try writer.print("    .unresolved = ts_state_{d}_unresolved,\n", .{serialized_state.id});
        } else {
            try writer.writeAll("    .unresolved = 0,\n");
        }
        try writer.print("    .unresolved_count = {d},\n", .{serialized_state.unresolved.len});
        try writer.writeAll("  },\n");
    }
    try writer.writeAll("};\n");
    try writer.writeAll("\n");
    try writer.writeAll("static const TSParser ts_parser = {\n");
    try writer.print("  .blocked = {},\n", .{serialized.blocked});
    try writer.writeAll("  .symbol_count = TS_SYMBOL_COUNT,\n");
    try writer.writeAll("  .state_count = TS_STATE_COUNT,\n");
    try writer.writeAll("  .symbols = ts_symbols,\n");
    try writer.writeAll("  .states = ts_states,\n");
    try writer.writeAll("  .compatibility = &ts_compatibility,\n");
    try writer.writeAll("};\n");
    try writer.writeAll("\n");
    try writer.writeAll("static const TSRuntimeStateInfo ts_runtime_states[TS_STATE_COUNT] = {\n");
    for (serialized.states) |serialized_state| {
        try writer.writeAll("  {\n");
        try writer.print("    .action_count = {d},\n", .{serialized_state.actions.len});
        try writer.print("    .goto_count = {d},\n", .{serialized_state.gotos.len});
        try writer.print("    .unresolved_count = {d},\n", .{serialized_state.unresolved.len});
        try writer.print("    .has_unresolved = {},\n", .{serialized_state.unresolved.len > 0});
        try writer.writeAll("  },\n");
    }
    try writer.writeAll("};\n");
    try writer.writeAll("\n");
    try writer.writeAll("static const TSParserRuntime ts_runtime = {\n");
    try writer.print("  .blocked = {},\n", .{serialized.blocked});
    try writer.print("  .has_unresolved_states = {},\n", .{hasUnresolvedStates(serialized)});
    try writer.writeAll("  .state_count = TS_STATE_COUNT,\n");
    try writer.writeAll("  .parser = &ts_parser,\n");
    try writer.writeAll("  .states = ts_runtime_states,\n");
    try writer.writeAll("};\n");
    try writer.writeAll("\n");
    try writer.writeAll("static const TSLanguage ts_language = {\n");
    try writer.writeAll("  .parser = &ts_parser,\n");
    try writer.writeAll("  .runtime = &ts_runtime,\n");
    try writer.writeAll("  .compatibility = &ts_compatibility,\n");
    try writer.writeAll("};\n");
    try writer.writeAll("\n");
    try compat.writeContractAccessors(writer);
    try writer.writeAll("int16_t ts_parser_find_symbol_id(const char *symbol) {\n");
    try writer.writeAll("  const TSParser *parser = ts_parser_instance();\n");
    try writer.writeAll("  uint16_t i = 0;\n");
    try writer.writeAll("  while (parser && i < parser->symbol_count) {\n");
    try writer.writeAll("    if (ts_string_eq(parser->symbols[i].name, symbol)) return (int16_t)i;\n");
    try writer.writeAll("    i += 1;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return -1;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSActionEntry *ts_parser_actions(uint16_t state_id) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state ? state->actions : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_action_count(uint16_t state_id) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state ? state->action_count : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSGotoEntry *ts_parser_gotos(uint16_t state_id) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state ? state->gotos : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_goto_count(uint16_t state_id) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state ? state->goto_count : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state ? state->unresolved : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_unresolved_count(uint16_t state_id) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state ? state->unresolved_count : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSActionEntry *ts_parser_action_at(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state && index < state->action_count ? &state->actions[index] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state && index < state->goto_count ? &state->gotos[index] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state && index < state->unresolved_count ? &state->unresolved[index] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const char *ts_parser_action_symbol(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSActionEntry *entry = ts_parser_action_at(state_id, index);\n");
    try writer.writeAll("  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const char *ts_parser_action_kind(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSActionEntry *entry = ts_parser_action_at(state_id, index);\n");
    try writer.writeAll("  if (!entry) return 0;\n");
    try writer.writeAll("  switch (entry->kind) {\n");
    try writer.writeAll("    case TS_ACTION_SHIFT: return \"shift\";\n");
    try writer.writeAll("    case TS_ACTION_REDUCE: return \"reduce\";\n");
    try writer.writeAll("    case TS_ACTION_ACCEPT: return \"accept\";\n");
    try writer.writeAll("    default: return 0;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_action_is_shift(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const char *kind = ts_parser_action_kind(state_id, index);\n");
    try writer.writeAll("  return kind && ts_string_eq(kind, \"shift\");\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_action_is_reduce(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const char *kind = ts_parser_action_kind(state_id, index);\n");
    try writer.writeAll("  return kind && ts_string_eq(kind, \"reduce\");\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_action_is_accept(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const char *kind = ts_parser_action_kind(state_id, index);\n");
    try writer.writeAll("  return kind && ts_string_eq(kind, \"accept\");\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_action_value(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSActionEntry *entry = ts_parser_action_at(state_id, index);\n");
    try writer.writeAll("  return entry ? entry->value : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const char *ts_parser_goto_symbol(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSGotoEntry *entry = ts_parser_goto_at(state_id, index);\n");
    try writer.writeAll("  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_goto_target(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSGotoEntry *entry = ts_parser_goto_at(state_id, index);\n");
    try writer.writeAll("  return entry ? entry->state : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const char *ts_parser_unresolved_symbol(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);\n");
    try writer.writeAll("  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const char *ts_parser_unresolved_reason(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);\n");
    try writer.writeAll("  if (!entry) return 0;\n");
    try writer.writeAll("  switch (entry->reason) {\n");
    try writer.writeAll("    case TS_UNRESOLVED_SHIFT_REDUCE: return \"shift_reduce\";\n");
    try writer.writeAll("    case TS_UNRESOLVED_REDUCE_REDUCE_DEFERRED: return \"reduce_reduce_deferred\";\n");
    try writer.writeAll("    default: return 0;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_unresolved_candidates(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);\n");
    try writer.writeAll("  return entry ? entry->candidates : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSActionEntry *ts_parser_find_action(uint16_t state_id, const char *symbol) {\n");
    try writer.writeAll("  uint16_t count = ts_parser_action_count(state_id);\n");
    try writer.writeAll("  uint16_t i = 0;\n");
    try writer.writeAll("  while (i < count) {\n");
    try writer.writeAll("    const TSActionEntry *entry = ts_parser_action_at(state_id, i);\n");
    try writer.writeAll("    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;\n");
    try writer.writeAll("    i += 1;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSGotoEntry *ts_parser_find_goto(uint16_t state_id, const char *symbol) {\n");
    try writer.writeAll("  uint16_t count = ts_parser_goto_count(state_id);\n");
    try writer.writeAll("  uint16_t i = 0;\n");
    try writer.writeAll("  while (i < count) {\n");
    try writer.writeAll("    const TSGotoEntry *entry = ts_parser_goto_at(state_id, i);\n");
    try writer.writeAll("    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;\n");
    try writer.writeAll("    i += 1;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol) {\n");
    try writer.writeAll("  uint16_t count = ts_parser_unresolved_count(state_id);\n");
    try writer.writeAll("  uint16_t i = 0;\n");
    try writer.writeAll("  while (i < count) {\n");
    try writer.writeAll("    const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, i);\n");
    try writer.writeAll("    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;\n");
    try writer.writeAll("    i += 1;\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  return 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_has_action(uint16_t state_id, const char *symbol) {\n");
    try writer.writeAll("  return ts_parser_find_action(state_id, symbol) != 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_has_goto(uint16_t state_id, const char *symbol) {\n");
    try writer.writeAll("  return ts_parser_find_goto(state_id, symbol) != 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol) {\n");
    try writer.writeAll("  return ts_parser_find_unresolved(state_id, symbol) != 0;\n");
    try writer.writeAll("}\n");
}

const EmittedSymbol = struct {
    ref: syntax_grammar.SymbolRef,
    label: []u8,
};

fn collectEmittedSymbols(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) std.mem.Allocator.Error![]EmittedSymbol {
    var symbols = std.array_list.Managed(EmittedSymbol).init(allocator);
    defer symbols.deinit();

    for (serialized.states) |state| {
        for (state.actions) |entry| {
            try appendUniqueEmittedSymbol(allocator, &symbols, entry.symbol);
        }
        for (state.gotos) |entry| {
            try appendUniqueEmittedSymbol(allocator, &symbols, entry.symbol);
        }
        for (state.unresolved) |entry| {
            try appendUniqueEmittedSymbol(allocator, &symbols, entry.symbol);
        }
    }

    std.mem.sort(EmittedSymbol, symbols.items, {}, emittedSymbolLessThan);
    return try symbols.toOwnedSlice();
}

fn appendUniqueEmittedSymbol(
    allocator: std.mem.Allocator,
    symbols: *std.array_list.Managed(EmittedSymbol),
    symbol: syntax_grammar.SymbolRef,
) std.mem.Allocator.Error!void {
    for (symbols.items) |existing| {
        if (symbolRefEql(existing.ref, symbol)) return;
    }

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    try common.writeSymbol(buffer.writer(), symbol);

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

    try std.testing.expectEqualStrings(
        \\/* generated parser.c skeleton */
        \\/* top-level layout: ts_language -> parser/runtime/compatibility */
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\
        \\#define TS_PARSER_BLOCKED true
        \\#define TS_STATE_COUNT 1
        \\#define TS_SYMBOL_COUNT 3
        \\
        \\#define TS_LANGUAGE_VERSION 15
        \\#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION 13
        \\#define TS_SYMBOL_KIND_NON_TERMINAL 1
        \\#define TS_SYMBOL_KIND_TERMINAL 2
        \\#define TS_SYMBOL_KIND_EXTERNAL 3
        \\#define TS_ACTION_SHIFT 1
        \\#define TS_ACTION_REDUCE 2
        \\#define TS_ACTION_ACCEPT 3
        \\#define TS_UNRESOLVED_SHIFT_REDUCE 1
        \\#define TS_UNRESOLVED_REDUCE_REDUCE_DEFERRED 2
        \\
        \\typedef struct { uint16_t symbol_id; uint16_t kind; uint16_t value; } TSActionEntry;
        \\typedef struct { uint16_t symbol_id; uint16_t state; } TSGotoEntry;
        \\typedef struct { uint16_t symbol_id; uint16_t reason; uint16_t candidates; } TSUnresolvedEntry;
        \\
        \\typedef struct {
        \\  uint16_t id;
        \\  const char *name;
        \\  uint16_t kind;
        \\  bool terminal;
        \\  bool external;
        \\} TSSymbolInfo;
        \\
        \\typedef struct {
        \\  uint16_t language_version;
        \\  uint16_t min_compatible_language_version;
        \\  const char *target;
        \\  const char *layer;
        \\} TSCompatibilityInfo;
        \\
        \\typedef struct {
        \\  const TSActionEntry *actions;
        \\  uint16_t action_count;
        \\  const TSGotoEntry *gotos;
        \\  uint16_t goto_count;
        \\  const TSUnresolvedEntry *unresolved;
        \\  uint16_t unresolved_count;
        \\} TSStateTable;
        \\
        \\typedef struct {
        \\  bool blocked;
        \\  uint16_t symbol_count;
        \\  uint16_t state_count;
        \\  const TSSymbolInfo *symbols;
        \\  const TSStateTable *states;
        \\  const TSCompatibilityInfo *compatibility;
        \\} TSParser;
        \\
        \\typedef struct {
        \\  uint16_t action_count;
        \\  uint16_t goto_count;
        \\  uint16_t unresolved_count;
        \\  bool has_unresolved;
        \\} TSRuntimeStateInfo;
        \\
        \\typedef struct {
        \\  bool blocked;
        \\  bool has_unresolved_states;
        \\  uint16_t state_count;
        \\  const TSParser *parser;
        \\  const TSRuntimeStateInfo *states;
        \\} TSParserRuntime;
        \\
        \\typedef struct {
        \\  const TSParser *parser;
        \\  const TSParserRuntime *runtime;
        \\  const TSCompatibilityInfo *compatibility;
        \\} TSLanguage;
        \\
        \\static bool ts_string_eq(const char *a, const char *b) {
        \\  if (!a || !b) return false;
        \\  while (a[0] != 0 && b[0] != 0) {
        \\    if (a[0] != b[0]) return false;
        \\    a += 1;
        \\    b += 1;
        \\  }
        \\  return a[0] == b[0];
        \\}
        \\
        \\static const TSCompatibilityInfo ts_compatibility = {
        \\  .language_version = 15,
        \\  .min_compatible_language_version = 13,
        \\  .target = "tree-sitter-runtime-surface",
        \\  .layer = "intermediate",
        \\};
        \\
        \\static const TSSymbolInfo ts_symbols[TS_SYMBOL_COUNT] = {
        \\  {
        \\    .id = 0,
        \\    .name = "non_terminal:1",
        \\    .kind = 1,
        \\    .terminal = false,
        \\    .external = false,
        \\  },
        \\  {
        \\    .id = 1,
        \\    .name = "terminal:0",
        \\    .kind = 2,
        \\    .terminal = true,
        \\    .external = false,
        \\  },
        \\  {
        \\    .id = 2,
        \\    .name = "terminal:1",
        \\    .kind = 2,
        \\    .terminal = true,
        \\    .external = false,
        \\  },
        \\};
        \\
        \\/* state 0 */
        \\static const TSActionEntry ts_state_0_actions[] = {
        \\  { 1, 1, 2 },
        \\};
        \\static const TSGotoEntry ts_state_0_gotos[] = {
        \\  { 0, 3 },
        \\};
        \\static const TSUnresolvedEntry ts_state_0_unresolved[] = {
        \\  { 2, 1, 2 },
        \\};
        \\static const TSStateTable ts_states[TS_STATE_COUNT] = {
        \\  {
        \\    .actions = ts_state_0_actions,
        \\    .action_count = 1,
        \\    .gotos = ts_state_0_gotos,
        \\    .goto_count = 1,
        \\    .unresolved = ts_state_0_unresolved,
        \\    .unresolved_count = 1,
        \\  },
        \\};
        \\
        \\static const TSParser ts_parser = {
        \\  .blocked = true,
        \\  .symbol_count = TS_SYMBOL_COUNT,
        \\  .state_count = TS_STATE_COUNT,
        \\  .symbols = ts_symbols,
        \\  .states = ts_states,
        \\  .compatibility = &ts_compatibility,
        \\};
        \\
        \\static const TSRuntimeStateInfo ts_runtime_states[TS_STATE_COUNT] = {
        \\  {
        \\    .action_count = 1,
        \\    .goto_count = 1,
        \\    .unresolved_count = 1,
        \\    .has_unresolved = true,
        \\  },
        \\};
        \\
        \\static const TSParserRuntime ts_runtime = {
        \\  .blocked = true,
        \\  .has_unresolved_states = true,
        \\  .state_count = TS_STATE_COUNT,
        \\  .parser = &ts_parser,
        \\  .states = ts_runtime_states,
        \\};
        \\
        \\static const TSLanguage ts_language = {
        \\  .parser = &ts_parser,
        \\  .runtime = &ts_runtime,
        \\  .compatibility = &ts_compatibility,
        \\};
        \\
        \\const TSLanguage *ts_language_instance(void) {
        \\  return &ts_language;
        \\}
        \\
        \\const TSParser *ts_language_parser(const TSLanguage *language) {
        \\  return language ? language->parser : 0;
        \\}
        \\
        \\const TSParserRuntime *ts_language_runtime(const TSLanguage *language) {
        \\  return language ? language->runtime : 0;
        \\}
        \\
        \\const TSCompatibilityInfo *ts_language_compatibility(const TSLanguage *language) {
        \\  return language ? language->compatibility : 0;
        \\}
        \\
        \\const TSParser *ts_parser_instance(void) {
        \\  return ts_language_parser(ts_language_instance());
        \\}
        \\
        \\const TSCompatibilityInfo *ts_parser_compatibility(void) {
        \\  return ts_language_compatibility(ts_language_instance());
        \\}
        \\
        \\uint16_t ts_parser_language_version(void) {
        \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
        \\  return compatibility ? compatibility->language_version : 0;
        \\}
        \\
        \\uint16_t ts_parser_min_compatible_language_version(void) {
        \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
        \\  return compatibility ? compatibility->min_compatible_language_version : 0;
        \\}
        \\
        \\const char *ts_parser_compatibility_target(void) {
        \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
        \\  return compatibility ? compatibility->target : 0;
        \\}
        \\
        \\const char *ts_parser_compatibility_layer(void) {
        \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
        \\  return compatibility ? compatibility->layer : 0;
        \\}
        \\
        \\const TSParserRuntime *ts_parser_runtime(void) {
        \\  return ts_language_runtime(ts_language_instance());
        \\}
        \\
        \\bool ts_parser_runtime_is_blocked(void) {
        \\  const TSParserRuntime *runtime = ts_parser_runtime();
        \\  return runtime ? runtime->blocked : false;
        \\}
        \\
        \\bool ts_parser_runtime_has_unresolved_states(void) {
        \\  const TSParserRuntime *runtime = ts_parser_runtime();
        \\  return runtime ? runtime->has_unresolved_states : false;
        \\}
        \\
        \\const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id) {
        \\  const TSParserRuntime *runtime = ts_parser_runtime();
        \\  return runtime && state_id < runtime->state_count ? &runtime->states[state_id] : 0;
        \\}
        \\
        \\bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) {
        \\  const TSRuntimeStateInfo *state = ts_parser_runtime_state(state_id);
        \\  return state ? state->has_unresolved : false;
        \\}
        \\
        \\const TSStateTable *ts_parser_state(uint16_t state_id) {
        \\  const TSParser *parser = ts_parser_instance();
        \\  return parser && state_id < parser->state_count ? &parser->states[state_id] : 0;
        \\}
        \\
        \\bool ts_parser_is_blocked(void) {
        \\  const TSParser *parser = ts_parser_instance();
        \\  return parser ? parser->blocked : false;
        \\}
        \\
        \\uint16_t ts_parser_symbol_count(void) {
        \\  const TSParser *parser = ts_parser_instance();
        \\  return parser ? parser->symbol_count : 0;
        \\}
        \\
        \\uint16_t ts_parser_state_count(void) {
        \\  const TSParser *parser = ts_parser_instance();
        \\  return parser ? parser->state_count : 0;
        \\}
        \\
        \\const TSSymbolInfo *ts_parser_symbol(uint16_t symbol_id) {
        \\  const TSParser *parser = ts_parser_instance();
        \\  return parser && symbol_id < parser->symbol_count ? &parser->symbols[symbol_id] : 0;
        \\}
        \\
        \\const char *ts_parser_symbol_name(uint16_t symbol_id) {
        \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
        \\  return symbol ? symbol->name : 0;
        \\}
        \\
        \\uint16_t ts_parser_symbol_id(uint16_t symbol_id) {
        \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
        \\  return symbol ? symbol->id : 0;
        \\}
        \\
        \\uint16_t ts_parser_symbol_kind(uint16_t symbol_id) {
        \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
        \\  return symbol ? symbol->kind : 0;
        \\}
        \\
        \\bool ts_parser_symbol_is_terminal(uint16_t symbol_id) {
        \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
        \\  return symbol ? symbol->terminal : false;
        \\}
        \\
        \\bool ts_parser_symbol_is_external(uint16_t symbol_id) {
        \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
        \\  return symbol ? symbol->external : false;
        \\}
        \\
        \\int16_t ts_parser_find_symbol_id(const char *symbol) {
        \\  const TSParser *parser = ts_parser_instance();
        \\  uint16_t i = 0;
        \\  while (parser && i < parser->symbol_count) {
        \\    if (ts_string_eq(parser->symbols[i].name, symbol)) return (int16_t)i;
        \\    i += 1;
        \\  }
        \\  return -1;
        \\}
        \\
        \\const TSActionEntry *ts_parser_actions(uint16_t state_id) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state ? state->actions : 0;
        \\}
        \\
        \\uint16_t ts_parser_action_count(uint16_t state_id) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state ? state->action_count : 0;
        \\}
        \\
        \\const TSGotoEntry *ts_parser_gotos(uint16_t state_id) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state ? state->gotos : 0;
        \\}
        \\
        \\uint16_t ts_parser_goto_count(uint16_t state_id) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state ? state->goto_count : 0;
        \\}
        \\
        \\const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state ? state->unresolved : 0;
        \\}
        \\
        \\uint16_t ts_parser_unresolved_count(uint16_t state_id) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state ? state->unresolved_count : 0;
        \\}
        \\
        \\const TSActionEntry *ts_parser_action_at(uint16_t state_id, uint16_t index) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state && index < state->action_count ? &state->actions[index] : 0;
        \\}
        \\
        \\const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state && index < state->goto_count ? &state->gotos[index] : 0;
        \\}
        \\
        \\const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state && index < state->unresolved_count ? &state->unresolved[index] : 0;
        \\}
        \\
        \\const char *ts_parser_action_symbol(uint16_t state_id, uint16_t index) {
        \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
        \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
        \\}
        \\
        \\const char *ts_parser_action_kind(uint16_t state_id, uint16_t index) {
        \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
        \\  if (!entry) return 0;
        \\  switch (entry->kind) {
        \\    case TS_ACTION_SHIFT: return "shift";
        \\    case TS_ACTION_REDUCE: return "reduce";
        \\    case TS_ACTION_ACCEPT: return "accept";
        \\    default: return 0;
        \\  }
        \\}
        \\
        \\bool ts_parser_action_is_shift(uint16_t state_id, uint16_t index) {
        \\  const char *kind = ts_parser_action_kind(state_id, index);
        \\  return kind && ts_string_eq(kind, "shift");
        \\}
        \\
        \\bool ts_parser_action_is_reduce(uint16_t state_id, uint16_t index) {
        \\  const char *kind = ts_parser_action_kind(state_id, index);
        \\  return kind && ts_string_eq(kind, "reduce");
        \\}
        \\
        \\bool ts_parser_action_is_accept(uint16_t state_id, uint16_t index) {
        \\  const char *kind = ts_parser_action_kind(state_id, index);
        \\  return kind && ts_string_eq(kind, "accept");
        \\}
        \\
        \\uint16_t ts_parser_action_value(uint16_t state_id, uint16_t index) {
        \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
        \\  return entry ? entry->value : 0;
        \\}
        \\
        \\const char *ts_parser_goto_symbol(uint16_t state_id, uint16_t index) {
        \\  const TSGotoEntry *entry = ts_parser_goto_at(state_id, index);
        \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
        \\}
        \\
        \\uint16_t ts_parser_goto_target(uint16_t state_id, uint16_t index) {
        \\  const TSGotoEntry *entry = ts_parser_goto_at(state_id, index);
        \\  return entry ? entry->state : 0;
        \\}
        \\
        \\const char *ts_parser_unresolved_symbol(uint16_t state_id, uint16_t index) {
        \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
        \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
        \\}
        \\
        \\const char *ts_parser_unresolved_reason(uint16_t state_id, uint16_t index) {
        \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
        \\  if (!entry) return 0;
        \\  switch (entry->reason) {
        \\    case TS_UNRESOLVED_SHIFT_REDUCE: return "shift_reduce";
        \\    case TS_UNRESOLVED_REDUCE_REDUCE_DEFERRED: return "reduce_reduce_deferred";
        \\    default: return 0;
        \\  }
        \\}
        \\
        \\uint16_t ts_parser_unresolved_candidates(uint16_t state_id, uint16_t index) {
        \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
        \\  return entry ? entry->candidates : 0;
        \\}
        \\
        \\const TSActionEntry *ts_parser_find_action(uint16_t state_id, const char *symbol) {
        \\  uint16_t count = ts_parser_action_count(state_id);
        \\  uint16_t i = 0;
        \\  while (i < count) {
        \\    const TSActionEntry *entry = ts_parser_action_at(state_id, i);
        \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
        \\    i += 1;
        \\  }
        \\  return 0;
        \\}
        \\
        \\const TSGotoEntry *ts_parser_find_goto(uint16_t state_id, const char *symbol) {
        \\  uint16_t count = ts_parser_goto_count(state_id);
        \\  uint16_t i = 0;
        \\  while (i < count) {
        \\    const TSGotoEntry *entry = ts_parser_goto_at(state_id, i);
        \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
        \\    i += 1;
        \\  }
        \\  return 0;
        \\}
        \\
        \\const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol) {
        \\  uint16_t count = ts_parser_unresolved_count(state_id);
        \\  uint16_t i = 0;
        \\  while (i < count) {
        \\    const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, i);
        \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
        \\    i += 1;
        \\  }
        \\  return 0;
        \\}
        \\
        \\bool ts_parser_has_action(uint16_t state_id, const char *symbol) {
        \\  return ts_parser_find_action(state_id, symbol) != 0;
        \\}
        \\
        \\bool ts_parser_has_goto(uint16_t state_id, const char *symbol) {
        \\  return ts_parser_find_goto(state_id, symbol) != 0;
        \\}
        \\
        \\bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol) {
        \\  return ts_parser_find_unresolved(state_id, symbol) != 0;
        \\}
        \\
    , emitted);
}

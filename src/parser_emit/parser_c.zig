const std = @import("std");
const serialize = @import("../parse_table/serialize.zig");
const common = @import("common.zig");

pub const EmitError = std.mem.Allocator.Error || std.fs.File.WriteError;

pub fn emitParserCAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try writeParserC(out.writer(), serialized);
    return try out.toOwnedSlice();
}

pub fn writeParserC(
    writer: anytype,
    serialized: serialize.SerializedTable,
) !void {
    try writer.writeAll("/* generated parser.c skeleton */\n");
    try writer.writeAll("#include <stdbool.h>\n");
    try writer.writeAll("#include <stdint.h>\n\n");
    try writer.print("#define TS_PARSER_BLOCKED {}\n", .{serialized.blocked});
    try writer.print("#define TS_STATE_COUNT {d}\n\n", .{serialized.states.len});
    try writer.writeAll("typedef struct { const char *symbol; const char *kind; uint16_t value; } TSActionEntry;\n");
    try writer.writeAll("typedef struct { const char *symbol; uint16_t state; } TSGotoEntry;\n");
    try writer.writeAll("typedef struct { const char *symbol; const char *reason; uint16_t candidates; } TSUnresolvedEntry;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  const TSActionEntry *actions;\n");
    try writer.writeAll("  uint16_t action_count;\n");
    try writer.writeAll("  const TSGotoEntry *gotos;\n");
    try writer.writeAll("  uint16_t goto_count;\n");
    try writer.writeAll("  const TSUnresolvedEntry *unresolved;\n");
    try writer.writeAll("  uint16_t unresolved_count;\n");
    try writer.writeAll("} TSStateTable;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  bool blocked;\n");
    try writer.writeAll("  uint16_t state_count;\n");
    try writer.writeAll("  const TSStateTable *states;\n");
    try writer.writeAll("} TSParser;\n\n");

    for (serialized.states, 0..) |serialized_state, index| {
        try writer.print("/* state {d} */\n", .{serialized_state.id});

        try writer.print("static const TSActionEntry ts_state_{d}_actions[] = {{\n", .{serialized_state.id});
        for (serialized_state.actions) |entry| {
            try writer.writeAll("  { ");
            try common.writeQuotedSymbol(writer, entry.symbol);
            try writer.writeAll(", ");
            try writer.writeByte('"');
            try common.writeActionKind(writer, entry.action);
            try writer.writeAll("\", ");
            try common.writeActionValue(writer, entry.action);
            try writer.writeAll(" },\n");
        }
        try writer.writeAll("};\n");

        try writer.print("static const TSGotoEntry ts_state_{d}_gotos[] = {{\n", .{serialized_state.id});
        for (serialized_state.gotos) |entry| {
            try writer.writeAll("  { ");
            try common.writeQuotedSymbol(writer, entry.symbol);
            try writer.print(", {d} }},\n", .{entry.state});
        }
        try writer.writeAll("};\n");

        if (serialized_state.unresolved.len > 0) {
            try writer.print("static const TSUnresolvedEntry ts_state_{d}_unresolved[] = {{\n", .{serialized_state.id});
            for (serialized_state.unresolved) |entry| {
                try writer.writeAll("  { ");
                try common.writeQuotedSymbol(writer, entry.symbol);
                try writer.writeAll(", \"");
                try common.writeUnresolvedReason(writer, entry.reason);
                try writer.print("\", {d} }},\n", .{entry.candidate_actions.len});
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
    try writer.writeAll("  .state_count = TS_STATE_COUNT,\n");
    try writer.writeAll("  .states = ts_states,\n");
    try writer.writeAll("};\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSParser *ts_parser_instance(void) {\n");
    try writer.writeAll("  return &ts_parser;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSStateTable *ts_parser_state(uint16_t state_id) {\n");
    try writer.writeAll("  return state_id < TS_STATE_COUNT ? &ts_states[state_id] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_is_blocked(void) {\n");
    try writer.writeAll("  return ts_parser.blocked;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_state_count(void) {\n");
    try writer.writeAll("  return ts_parser.state_count;\n");
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
    try writer.writeAll("  return state and index < state->action_count ? &state->actions[index] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state and index < state->goto_count ? &state->gotos[index] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) {\n");
    try writer.writeAll("  const TSStateTable *state = ts_parser_state(state_id);\n");
    try writer.writeAll("  return state and index < state->unresolved_count ? &state->unresolved[index] : 0;\n");
    try writer.writeAll("}\n");
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
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\
        \\#define TS_PARSER_BLOCKED true
        \\#define TS_STATE_COUNT 1
        \\
        \\typedef struct { const char *symbol; const char *kind; uint16_t value; } TSActionEntry;
        \\typedef struct { const char *symbol; uint16_t state; } TSGotoEntry;
        \\typedef struct { const char *symbol; const char *reason; uint16_t candidates; } TSUnresolvedEntry;
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
        \\  uint16_t state_count;
        \\  const TSStateTable *states;
        \\} TSParser;
        \\
        \\/* state 0 */
        \\static const TSActionEntry ts_state_0_actions[] = {
        \\  { "terminal:0", "shift", 2 },
        \\};
        \\static const TSGotoEntry ts_state_0_gotos[] = {
        \\  { "non_terminal:1", 3 },
        \\};
        \\static const TSUnresolvedEntry ts_state_0_unresolved[] = {
        \\  { "terminal:1", "shift_reduce", 2 },
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
        \\  .state_count = TS_STATE_COUNT,
        \\  .states = ts_states,
        \\};
        \\
        \\const TSParser *ts_parser_instance(void) {
        \\  return &ts_parser;
        \\}
        \\
        \\const TSStateTable *ts_parser_state(uint16_t state_id) {
        \\  return state_id < TS_STATE_COUNT ? &ts_states[state_id] : 0;
        \\}
        \\
        \\bool ts_parser_is_blocked(void) {
        \\  return ts_parser.blocked;
        \\}
        \\
        \\uint16_t ts_parser_state_count(void) {
        \\  return ts_parser.state_count;
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
        \\  return state and index < state->action_count ? &state->actions[index] : 0;
        \\}
        \\
        \\const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state and index < state->goto_count ? &state->gotos[index] : 0;
        \\}
        \\
        \\const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) {
        \\  const TSStateTable *state = ts_parser_state(state_id);
        \\  return state and index < state->unresolved_count ? &state->unresolved[index] : 0;
        \\}
        \\
    , emitted);
}

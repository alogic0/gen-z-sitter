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
        \\
    , emitted);
}

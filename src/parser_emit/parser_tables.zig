const std = @import("std");
const serialize = @import("../parse_table/serialize.zig");
const common = @import("common.zig");
const optimize = @import("optimize.zig");

/// Errors produced while rendering the textual parser-table dump.
pub const EmitError = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    ParseActionListTooLarge,
};

/// Render the textual parser-table dump into an owned buffer.
pub fn emitSerializedTableAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]const u8 {
    return try emitSerializedTableAllocWithOptions(allocator, serialized, .{});
}

/// Render the textual parser-table dump using explicit optimization options.
pub fn emitSerializedTableAllocWithOptions(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
    options: optimize.Options,
) EmitError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const compacted = try optimize.prepareSerializedTableAlloc(arena.allocator(), serialized, options);
    try writeSerializedTable(&out.writer, compacted);
    return try out.toOwnedSlice();
}

/// Write the textual parser-table dump to an existing writer.
pub fn writeSerializedTable(
    writer: anytype,
    serialized: serialize.SerializedTable,
) !void {
    try writer.print("parser_tables blocked={}\n", .{serialized.blocked});
    try writer.print("state_count={d}\n", .{serialized.states.len});

    for (serialized.states, 0..) |serialized_state, index| {
        try writer.print("state {d} {{\n", .{serialized_state.id});

        for (serialized_state.actions) |entry| {
            try writer.writeAll("  action ");
            try common.writeSymbol(writer, entry.symbol);
            try writer.writeByte(' ');
            try common.writeActionWithValue(writer, entry.action);
            try writer.writeByte('\n');
        }

        for (serialized_state.gotos) |entry| {
            try writer.writeAll("  goto ");
            try common.writeSymbol(writer, entry.symbol);
            try writer.print(" {d}\n", .{entry.state});
        }

        for (serialized_state.unresolved) |entry| {
            try writer.writeAll("  unresolved ");
            try common.writeSymbol(writer, entry.symbol);
            try writer.writeByte(' ');
            try common.writeUnresolvedReason(writer, entry.reason);
            try writer.print(" candidates={d}\n", .{entry.candidate_actions.len});
        }

        try writer.writeAll("}");
        if (index + 1 < serialized.states.len) try writer.writeByte('\n');
        if (index + 1 < serialized.states.len) try writer.writeByte('\n');
    }
}

test "emitSerializedTableAlloc formats parser-table skeletons deterministically" {
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
                            @import("../parse_table/actions.zig").reduce(5),
                        },
                    },
                },
            },
        },
    };

    const emitted = try emitSerializedTableAlloc(allocator, serialized);
    defer allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\parser_tables blocked=true
        \\state_count=1
        \\state 0 {
        \\  action terminal:0 shift 2
        \\  goto non_terminal:1 3
        \\  unresolved terminal:1 shift_reduce candidates=2
        \\}
    , emitted);
}

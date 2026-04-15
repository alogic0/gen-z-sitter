const std = @import("std");
const serialize = @import("../parse_table/serialize.zig");
const common = @import("common.zig");

pub const EmitError = std.mem.Allocator.Error || std.fs.File.WriteError;

pub fn emitCTableSkeletonAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try writeCTableSkeleton(out.writer(), serialized);
    return try out.toOwnedSlice();
}

pub fn writeCTableSkeleton(
    writer: anytype,
    serialized: serialize.SerializedTable,
) !void {
    try writer.writeAll("/* generated parser table skeleton */\n");
    try writer.print("#define TS_SERIALIZED_TABLE_BLOCKED {}\n", .{serialized.blocked});
    try writer.print("#define TS_STATE_COUNT {d}\n\n", .{serialized.states.len});

    for (serialized.states, 0..) |serialized_state, index| {
        try writer.print("/* state {d} */\n", .{serialized_state.id});
        try writer.print("static const unsigned TS_STATE_{d}_ACTION_COUNT = {d};\n", .{
            serialized_state.id,
            serialized_state.actions.len,
        });
        for (serialized_state.actions, 0..) |entry, action_index| {
            try writer.print("/* action[{d}] ", .{action_index});
            try common.writeSymbol(writer, entry.symbol);
            try writer.writeAll(" ");
            try common.writeActionWithValue(writer, entry.action);
            try writer.writeAll(" */\n");
        }

        try writer.print("static const unsigned TS_STATE_{d}_GOTO_COUNT = {d};\n", .{
            serialized_state.id,
            serialized_state.gotos.len,
        });
        for (serialized_state.gotos, 0..) |entry, goto_index| {
            try writer.print("/* goto[{d}] ", .{goto_index});
            try common.writeSymbol(writer, entry.symbol);
            try writer.print(" -> {d} */\n", .{entry.state});
        }

        if (serialized_state.unresolved.len > 0) {
            try writer.print("static const unsigned TS_STATE_{d}_UNRESOLVED_COUNT = {d};\n", .{
                serialized_state.id,
                serialized_state.unresolved.len,
            });
            for (serialized_state.unresolved, 0..) |entry, unresolved_index| {
                try writer.print("/* unresolved[{d}] ", .{unresolved_index});
                try common.writeSymbol(writer, entry.symbol);
                try writer.writeByte(' ');
                try common.writeUnresolvedReason(writer, entry.reason);
                try writer.print(" candidates={d} */\n", .{entry.candidate_actions.len});
            }
        }

        if (index + 1 < serialized.states.len) try writer.writeByte('\n');
    }
}

test "emitCTableSkeletonAlloc formats C-like parser tables deterministically" {
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

    const emitted = try emitCTableSkeletonAlloc(allocator, serialized);
    defer allocator.free(emitted);

    try std.testing.expectEqualStrings(
        \\/* generated parser table skeleton */
        \\#define TS_SERIALIZED_TABLE_BLOCKED true
        \\#define TS_STATE_COUNT 1
        \\
        \\/* state 0 */
        \\static const unsigned TS_STATE_0_ACTION_COUNT = 1;
        \\/* action[0] terminal:0 shift 2 */
        \\static const unsigned TS_STATE_0_GOTO_COUNT = 1;
        \\/* goto[0] non_terminal:1 -> 3 */
        \\static const unsigned TS_STATE_0_UNRESOLVED_COUNT = 1;
        \\/* unresolved[0] terminal:1 shift_reduce candidates=2 */
        \\
    , emitted);
}

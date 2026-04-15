const std = @import("std");
const serialize = @import("../parse_table/serialize.zig");

pub const EmitError = std.mem.Allocator.Error || std.fs.File.WriteError;

pub fn emitSerializedTableAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) EmitError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try writeSerializedTable(out.writer(), serialized);
    return try out.toOwnedSlice();
}

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
            try writeSymbol(writer, entry.symbol);
            try writer.writeByte(' ');
            switch (entry.action) {
                .shift => |target| try writer.print("shift {d}\n", .{target}),
                .reduce => |production_id| try writer.print("reduce {d}\n", .{production_id}),
                .accept => try writer.writeAll("accept\n"),
            }
        }

        for (serialized_state.gotos) |entry| {
            try writer.writeAll("  goto ");
            try writeSymbol(writer, entry.symbol);
            try writer.print(" {d}\n", .{entry.state});
        }

        for (serialized_state.unresolved) |entry| {
            try writer.writeAll("  unresolved ");
            try writeSymbol(writer, entry.symbol);
            try writer.writeByte(' ');
            try writer.writeAll(@tagName(entry.reason));
            try writer.print(" candidates={d}\n", .{entry.candidate_actions.len});
        }

        try writer.writeAll("}");
        if (index + 1 < serialized.states.len) try writer.writeByte('\n');
        if (index + 1 < serialized.states.len) try writer.writeByte('\n');
    }
}

fn writeSymbol(writer: anytype, symbol: @import("../ir/syntax_grammar.zig").SymbolRef) !void {
    switch (symbol) {
        .non_terminal => |symbol_index| try writer.print("non_terminal:{d}", .{symbol_index}),
        .terminal => |symbol_index| try writer.print("terminal:{d}", .{symbol_index}),
        .external => |symbol_index| try writer.print("external:{d}", .{symbol_index}),
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
                            .{ .reduce = 5 },
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

const std = @import("std");
const item = @import("item.zig");
const state = @import("state.zig");

pub const DebugDumpError = std.mem.Allocator.Error || std.fs.File.WriteError;

pub fn dumpStatesAlloc(
    allocator: std.mem.Allocator,
    states: []const state.ParseState,
) DebugDumpError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try writeStates(out.writer(), states);
    return try out.toOwnedSlice();
}

pub fn writeStates(writer: anytype, states: []const state.ParseState) !void {
    for (states, 0..) |parse_state, index| {
        try writer.print("state {d}\n", .{parse_state.id});

        try writer.writeAll("  items:\n");
        for (parse_state.items) |parse_item| {
            try writer.print("    {f}\n", .{parse_item});
        }

        try writer.writeAll("  transitions:\n");
        for (parse_state.transitions) |transition| {
            try writer.print("    {s}:{d} -> {d}\n", .{ @tagName(transition.symbol.kind), transition.symbol.index, transition.state });
        }

        if (parse_state.conflicts.len > 0) {
            try writer.writeAll("  conflicts:\n");
            for (parse_state.conflicts) |conflict| {
                try writer.print("    {s}", .{@tagName(conflict.kind)});
                if (conflict.symbol) |symbol| {
                    try writer.print(" on {s}:{d}", .{ @tagName(symbol.kind), symbol.index });
                }
                try writer.writeByte('\n');
                for (conflict.items) |parse_item| {
                    try writer.print("      {f}\n", .{parse_item});
                }
            }
        }

        if (index + 1 < states.len) try writer.writeByte('\n');
    }
}

test "dumpStatesAlloc formats parser states deterministically" {
    const allocator = std.testing.allocator;
    const conflict_items = [_]item.ParseItem{
        item.ParseItem.init(0, 1),
        item.ParseItem.withLookahead(2, 0, .{ .kind = .external, .index = 5 }),
    };
    const states = [_]state.ParseState{
        .{
            .id = 0,
            .items = &[_]item.ParseItem{
                item.ParseItem.init(0, 0),
                item.ParseItem.withLookahead(1, 2, .{ .kind = .non_terminal, .index = 4 }),
            },
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .kind = .non_terminal, .index = 3 }, .state = 1 },
            },
            .conflicts = &[_]state.Conflict{
                .{
                    .kind = .shift_reduce,
                    .symbol = .{ .kind = .external, .index = 7 },
                    .items = conflict_items[0..],
                },
            },
        },
    };

    const dump = try dumpStatesAlloc(allocator, states[0..]);
    defer allocator.free(dump);

    try std.testing.expectEqualStrings(
        \\state 0
        \\  items:
        \\    #0@0
        \\    #1@2 ?non_terminal:4
        \\  transitions:
        \\    non_terminal:3 -> 1
        \\  conflicts:
        \\    shift_reduce on external:7
        \\      #0@1
        \\      #2@0 ?external:5
        \\
    , dump);
}

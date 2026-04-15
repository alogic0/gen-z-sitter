const std = @import("std");
const actions = @import("actions.zig");
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

pub fn dumpStatesWithActionsAlloc(
    allocator: std.mem.Allocator,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) DebugDumpError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try writeStatesWithActions(out.writer(), states, action_table);
    return try out.toOwnedSlice();
}

pub fn dumpActionTableAlloc(
    allocator: std.mem.Allocator,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) DebugDumpError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try writeActionTable(out.writer(), states, action_table);
    return try out.toOwnedSlice();
}

pub fn dumpGroupedActionTableAlloc(
    allocator: std.mem.Allocator,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) DebugDumpError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try writeGroupedActionTableAlloc(allocator, out.writer(), states, action_table);
    return try out.toOwnedSlice();
}

pub fn writeStates(writer: anytype, states: []const state.ParseState) !void {
    try writeStatesWithActions(writer, states, .{ .states = &.{} });
}

pub fn writeStatesWithActions(
    writer: anytype,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) !void {
    for (states, 0..) |parse_state, index| {
        try writer.print("state {d}\n", .{parse_state.id});

        try writer.writeAll("  items:\n");
        for (parse_state.items) |parse_item| {
            try writer.print("    {f}\n", .{parse_item});
        }

        try writer.writeAll("  transitions:\n");
        for (parse_state.transitions) |transition| {
            switch (transition.symbol) {
                .non_terminal => |symbol_index| try writer.print("    non_terminal:{d} -> {d}\n", .{ symbol_index, transition.state }),
                .terminal => |symbol_index| try writer.print("    terminal:{d} -> {d}\n", .{ symbol_index, transition.state }),
                .external => |symbol_index| try writer.print("    external:{d} -> {d}\n", .{ symbol_index, transition.state }),
            }
        }

        const state_actions = action_table.entriesForState(parse_state.id);
        if (action_table.states.len > 0) {
            try writer.writeAll("  actions:\n");
            for (state_actions) |entry| {
                try writer.writeAll("    ");
                try writeSymbol(writer, entry.symbol);
                try writer.writeAll(" => ");
                switch (entry.action) {
                    .shift => |target| try writer.print("shift {d}\n", .{target}),
                    .reduce => |production_id| try writer.print("reduce {d}\n", .{production_id}),
                    .accept => try writer.writeAll("accept\n"),
                }
            }
        }

        if (parse_state.conflicts.len > 0) {
            try writer.writeAll("  conflicts:\n");
            for (parse_state.conflicts) |conflict| {
                try writer.print("    {s}", .{@tagName(conflict.kind)});
                if (conflict.symbol) |symbol| {
                    try writer.writeAll(" on ");
                    try writeSymbol(writer, symbol);
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

pub fn writeActionTable(
    writer: anytype,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) !void {
    for (states, 0..) |parse_state, index| {
        try writer.print("state {d}\n", .{parse_state.id});
        try writer.writeAll("  actions:\n");
        for (action_table.entriesForState(parse_state.id)) |entry| {
            try writer.writeAll("    ");
            try writeSymbol(writer, entry.symbol);
            try writer.writeAll(" => ");
            switch (entry.action) {
                .shift => |target| try writer.print("shift {d}\n", .{target}),
                .reduce => |production_id| try writer.print("reduce {d}\n", .{production_id}),
                .accept => try writer.writeAll("accept\n"),
            }
        }

        if (parse_state.conflicts.len > 0) {
            try writer.writeAll("  conflicts:\n");
            for (parse_state.conflicts) |conflict| {
                try writer.print("    {s}", .{@tagName(conflict.kind)});
                if (conflict.symbol) |symbol| {
                    try writer.writeAll(" on ");
                    try writeSymbol(writer, symbol);
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

pub fn writeGroupedActionTableAlloc(
    allocator: std.mem.Allocator,
    writer: anytype,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) !void {
    const grouped_table = try actions.groupActionTable(allocator, action_table);
    defer {
        for (grouped_table.states) |grouped_state| {
            for (grouped_state.groups) |group| allocator.free(group.entries);
            allocator.free(grouped_state.groups);
        }
        allocator.free(grouped_table.states);
    }

    for (states, 0..) |parse_state, index| {
        try writer.print("state {d}\n", .{parse_state.id});
        try writer.writeAll("  actions:\n");

        for (grouped_table.groupsForState(parse_state.id)) |group| {
            try writer.writeAll("    ");
            try writeSymbol(writer, group.symbol);
            try writer.writeAll(":\n");

            for (group.entries) |entry| {
                try writer.writeAll("      ");
                switch (entry.action) {
                    .shift => |target| try writer.print("shift {d}\n", .{target}),
                    .reduce => |production_id| try writer.print("reduce {d}\n", .{production_id}),
                    .accept => try writer.writeAll("accept\n"),
                }
            }
        }

        if (parse_state.conflicts.len > 0) {
            try writer.writeAll("  conflicts:\n");
            for (parse_state.conflicts) |conflict| {
                try writer.print("    {s}", .{@tagName(conflict.kind)});
                if (conflict.symbol) |symbol| {
                    try writer.writeAll(" on ");
                    try writeSymbol(writer, symbol);
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

fn writeSymbol(writer: anytype, symbol: @import("../ir/syntax_grammar.zig").SymbolRef) !void {
    switch (symbol) {
        .non_terminal => |symbol_index| try writer.print("non_terminal:{d}", .{symbol_index}),
        .terminal => |symbol_index| try writer.print("terminal:{d}", .{symbol_index}),
        .external => |symbol_index| try writer.print("external:{d}", .{symbol_index}),
    }
}

test "dumpStatesAlloc formats parser states deterministically" {
    const allocator = std.testing.allocator;
    const conflict_items = [_]item.ParseItem{
        item.ParseItem.init(0, 1),
        item.ParseItem.withLookahead(2, 0, .{ .external = 5 }),
    };
    const states = [_]state.ParseState{
        .{
            .id = 0,
            .items = &[_]item.ParseItem{
                item.ParseItem.init(0, 0),
                item.ParseItem.withLookahead(1, 2, .{ .non_terminal = 4 }),
            },
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 3 }, .state = 1 },
            },
            .conflicts = &[_]state.Conflict{
                .{
                    .kind = .shift_reduce,
                    .symbol = .{ .external = 7 },
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

test "dumpStatesWithActionsAlloc formats parser actions deterministically" {
    const allocator = std.testing.allocator;
    const states = [_]state.ParseState{
        .{
            .id = 0,
            .items = &[_]item.ParseItem{
                item.ParseItem.init(0, 0),
            },
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .terminal = 0 }, .state = 2 },
            },
        },
    };
    const action_table = actions.ActionTable{
        .states = &[_]actions.StateActions{
            .{
                .state_id = 0,
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
                    .{ .symbol = .{ .external = 1 }, .action = .{ .accept = {} } },
                },
            },
        },
    };

    const dump = try dumpStatesWithActionsAlloc(allocator, states[0..], action_table);
    defer allocator.free(dump);

    try std.testing.expectEqualStrings(
        \\state 0
        \\  items:
        \\    #0@0
        \\  transitions:
        \\    terminal:0 -> 2
        \\  actions:
        \\    terminal:0 => shift 2
        \\    external:1 => accept
        \\
    , dump);
}

test "dumpActionTableAlloc formats action tables deterministically" {
    const allocator = std.testing.allocator;
    const states = [_]state.ParseState{
        .{
            .id = 0,
            .items = &[_]item.ParseItem{},
            .transitions = &[_]state.Transition{},
            .conflicts = &[_]state.Conflict{
                .{
                    .kind = .shift_reduce,
                    .symbol = .{ .terminal = 0 },
                    .items = &[_]item.ParseItem{
                        item.ParseItem.init(1, 1),
                        item.ParseItem.withLookahead(2, 1, .{ .terminal = 0 }),
                    },
                },
            },
        },
    };
    const action_table = actions.ActionTable{
        .states = &[_]actions.StateActions{
            .{
                .state_id = 0,
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 3 } },
                },
            },
        },
    };

    const dump = try dumpActionTableAlloc(allocator, states[0..], action_table);
    defer allocator.free(dump);

    try std.testing.expectEqualStrings(
        \\state 0
        \\  actions:
        \\    terminal:0 => shift 2
        \\    terminal:0 => reduce 3
        \\  conflicts:
        \\    shift_reduce on terminal:0
        \\      #1@1
        \\      #2@1 ?terminal:0
        \\
    , dump);
}

test "dumpGroupedActionTableAlloc groups actions by symbol deterministically" {
    const allocator = std.testing.allocator;
    const states = [_]state.ParseState{
        .{
            .id = 0,
            .items = &[_]item.ParseItem{},
            .transitions = &[_]state.Transition{},
            .conflicts = &[_]state.Conflict{
                .{
                    .kind = .shift_reduce,
                    .symbol = .{ .terminal = 0 },
                    .items = &[_]item.ParseItem{
                        item.ParseItem.init(1, 1),
                        item.ParseItem.withLookahead(2, 1, .{ .terminal = 0 }),
                    },
                },
            },
        },
    };
    const action_table = actions.ActionTable{
        .states = &[_]actions.StateActions{
            .{
                .state_id = 0,
                .entries = &[_]actions.ActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .reduce = 3 } },
                    .{ .symbol = .{ .external = 1 }, .action = .{ .accept = {} } },
                },
            },
        },
    };

    const dump = try dumpGroupedActionTableAlloc(allocator, states[0..], action_table);
    defer allocator.free(dump);

    try std.testing.expectEqualStrings(
        \\state 0
        \\  actions:
        \\    terminal:0:
        \\      shift 2
        \\      reduce 3
        \\    external:1:
        \\      accept
        \\  conflicts:
        \\    shift_reduce on terminal:0
        \\      #1@1
        \\      #2@1 ?terminal:0
        \\
    , dump);
}

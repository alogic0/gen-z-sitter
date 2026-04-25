const std = @import("std");
const actions = @import("actions.zig");
const item = @import("item.zig");
const resolution = @import("resolution.zig");
const serialize = @import("serialize.zig");
const state = @import("state.zig");

pub const DebugDumpError = std.mem.Allocator.Error || std.Io.Writer.Error;

pub fn dumpStatesAlloc(
    allocator: std.mem.Allocator,
    states: []const state.ParseState,
) DebugDumpError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeStates(&out.writer, states);
    return try out.toOwnedSlice();
}

pub fn dumpStatesWithActionsAlloc(
    allocator: std.mem.Allocator,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) DebugDumpError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeStatesWithActions(&out.writer, states, action_table);
    return try out.toOwnedSlice();
}

pub fn dumpActionTableAlloc(
    allocator: std.mem.Allocator,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) DebugDumpError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeActionTable(&out.writer, states, action_table);
    return try out.toOwnedSlice();
}

pub fn dumpGroupedActionTableAlloc(
    allocator: std.mem.Allocator,
    states: []const state.ParseState,
    action_table: actions.ActionTable,
) DebugDumpError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeGroupedActionTableAlloc(allocator, &out.writer, states, action_table);
    return try out.toOwnedSlice();
}

pub fn dumpResolvedActionTableAlloc(
    allocator: std.mem.Allocator,
    resolved_table: resolution.ResolvedActionTable,
) DebugDumpError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeResolvedActionTable(&out.writer, resolved_table);
    return try out.toOwnedSlice();
}

pub fn dumpSerializedTableAlloc(
    allocator: std.mem.Allocator,
    serialized_table: serialize.SerializedTable,
) DebugDumpError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeSerializedTable(&out.writer, serialized_table);
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

pub fn writeResolvedActionTable(
    writer: anytype,
    resolved_table: resolution.ResolvedActionTable,
) !void {
    for (resolved_table.states, 0..) |resolved_state, index| {
        try writer.print("state {d}\n", .{resolved_state.state_id});
        try writer.writeAll("  resolved_actions:\n");

        for (resolved_state.groups) |group| {
            try writer.writeAll("    ");
            try writeSymbol(writer, group.symbol);
            try writer.writeAll(": ");
            switch (group.decision) {
                .chosen => |chosen| {
                    switch (chosen) {
                        .shift => |target| try writer.print("shift {d}\n", .{target}),
                        .reduce => |production_id| try writer.print("reduce {d}\n", .{production_id}),
                        .accept => try writer.writeAll("accept\n"),
                    }
                },
                .unresolved => |reason| {
                    try writer.writeAll("unresolved");
                    try writer.writeAll(" (");
                    try writer.writeAll(@tagName(reason));
                    try writer.writeByte(')');
                    try writer.writeByte('\n');
                    for (group.candidate_actions) |candidate| {
                        try writer.writeAll("      candidate ");
                        switch (candidate) {
                            .shift => |target| try writer.print("shift {d}\n", .{target}),
                            .reduce => |production_id| try writer.print("reduce {d}\n", .{production_id}),
                            .accept => try writer.writeAll("accept\n"),
                        }
                    }
                },
            }
        }

        if (index + 1 < resolved_table.states.len) try writer.writeByte('\n');
    }
}

pub fn writeSerializedTable(
    writer: anytype,
    serialized_table: serialize.SerializedTable,
) !void {
    try writer.print("serialized_table blocked={}\n", .{serialized_table.blocked});
    for (serialized_table.states, 0..) |serialized_state, index| {
        try writer.print("state {d}\n", .{serialized_state.id});

        try writer.writeAll("  actions:\n");
        for (serialized_state.actions) |entry| {
            try writer.writeAll("    ");
            try writeSymbol(writer, entry.symbol);
            try writer.writeAll(" => ");
            switch (entry.action) {
                .shift => |target| try writer.print("shift {d}\n", .{target}),
                .reduce => |production_id| try writer.print("reduce {d}\n", .{production_id}),
                .accept => try writer.writeAll("accept\n"),
            }
        }

        try writer.writeAll("  gotos:\n");
        for (serialized_state.gotos) |entry| {
            try writer.writeAll("    ");
            try writeSymbol(writer, entry.symbol);
            try writer.print(" -> {d}\n", .{entry.state});
        }

        if (serialized_state.unresolved.len > 0) {
            try writer.writeAll("  unresolved:\n");
            for (serialized_state.unresolved) |entry| {
                try writer.writeAll("    ");
                try writeSymbol(writer, entry.symbol);
                try writer.writeAll(" (");
                try writer.writeAll(@tagName(entry.reason));
                try writer.writeAll(")\n");
                for (entry.candidate_actions) |candidate| {
                    try writer.writeAll("      candidate ");
                    switch (candidate) {
                        .shift => |target| try writer.print("shift {d}\n", .{target}),
                        .reduce => |production_id| try writer.print("reduce {d}\n", .{production_id}),
                        .accept => try writer.writeAll("accept\n"),
                    }
                }
            }
        }

        if (index + 1 < serialized_table.states.len) try writer.writeByte('\n');
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
        item.ParseItem.init(2, 0),
    };
    var state_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 0, 0, item.ParseItem.init(0, 0)),
        try item.ParseItemSetEntry.initEmpty(allocator, 0, 0, item.ParseItem.init(1, 2)),
    };
    defer for (state_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const states = [_]state.ParseState{
        .{
            .id = 0,
            .items = state_items[0..],
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
        \\    #1@2
        \\  transitions:
        \\    non_terminal:3 -> 1
        \\  conflicts:
        \\    shift_reduce on external:7
        \\      #0@1
        \\      #2@0
        \\
    , dump);
}

test "dumpStatesWithActionsAlloc formats parser actions deterministically" {
    const allocator = std.testing.allocator;
    var state_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 0, 0, item.ParseItem.init(0, 0)),
    };
    defer for (state_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const states = [_]state.ParseState{
        .{
            .id = 0,
            .items = state_items[0..],
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
            .items = &[_]item.ParseItemSetEntry{},
            .transitions = &[_]state.Transition{},
            .conflicts = &[_]state.Conflict{
                .{
                    .kind = .shift_reduce,
                    .symbol = .{ .terminal = 0 },
                    .items = &[_]item.ParseItem{
                        item.ParseItem.init(1, 1),
                        item.ParseItem.init(2, 1),
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
        \\      #2@1
        \\
    , dump);
}

test "dumpGroupedActionTableAlloc groups actions by symbol deterministically" {
    const allocator = std.testing.allocator;
    const states = [_]state.ParseState{
        .{
            .id = 0,
            .items = &[_]item.ParseItemSetEntry{},
            .transitions = &[_]state.Transition{},
            .conflicts = &[_]state.Conflict{
                .{
                    .kind = .shift_reduce,
                    .symbol = .{ .terminal = 0 },
                    .items = &[_]item.ParseItem{
                        item.ParseItem.init(1, 1),
                        item.ParseItem.init(2, 1),
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
        \\      #2@1
        \\
    , dump);
}

test "dumpResolvedActionTableAlloc formats chosen and unresolved groups deterministically" {
    const allocator = std.testing.allocator;
    const resolved = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .reduce = 2 }},
                        .decision = .{ .chosen = .{ .reduce = 2 } },
                    },
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &[_]actions.ParseAction{
                            .{ .shift = 3 },
                            .{ .reduce = 4 },
                        },
                        .decision = .{ .unresolved = .shift_reduce },
                    },
                },
            },
        },
    };

    const dump = try dumpResolvedActionTableAlloc(allocator, resolved);
    defer allocator.free(dump);

    try std.testing.expectEqualStrings(
        \\state 0
        \\  resolved_actions:
        \\    terminal:0: reduce 2
        \\    terminal:1: unresolved (shift_reduce)
        \\      candidate shift 3
        \\      candidate reduce 4
        \\
    , dump);
}

test "dumpSerializedTableAlloc formats serialized tables deterministically" {
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
                        .candidate_actions = &[_]actions.ParseAction{
                            .{ .shift = 4 },
                            .{ .reduce = 5 },
                        },
                    },
                },
            },
        },
    };

    const dump = try dumpSerializedTableAlloc(allocator, serialized);
    defer allocator.free(dump);

    try std.testing.expectEqualStrings(
        \\serialized_table blocked=true
        \\state 0
        \\  actions:
        \\    terminal:0 => shift 2
        \\  gotos:
        \\    non_terminal:1 -> 3
        \\  unresolved:
        \\    terminal:1 (shift_reduce)
        \\      candidate shift 4
        \\      candidate reduce 5
        \\
    , dump);
}

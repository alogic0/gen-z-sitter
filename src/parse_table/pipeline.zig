const std = @import("std");
const grammar_ir = @import("../ir/grammar_ir.zig");
const actions = @import("actions.zig");
const debug_dump = @import("debug_dump.zig");
const build = @import("build.zig");
const state = @import("state.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const flatten_grammar = @import("../grammar/prepare/flatten_grammar.zig");
const fixtures = @import("../tests/fixtures.zig");
const json_loader = @import("../grammar/json_loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");

pub const PipelineError =
    extract_tokens.ExtractTokensError ||
    flatten_grammar.FlattenGrammarError ||
    build.BuildError ||
    debug_dump.DebugDumpError ||
    std.json.ParseError(std.json.Scanner) ||
    std.mem.Allocator.Error;

pub fn generateStateDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    const result = try build.buildStates(allocator, flattened);
    return try debug_dump.dumpStatesAlloc(allocator, result.states);
}

pub fn buildStatesFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError!build.BuildResult {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    return try build.buildStates(allocator, flattened);
}

pub fn generateStateActionDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try debug_dump.dumpStatesWithActionsAlloc(allocator, result.states, result.actions);
}

pub fn generateActionTableDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try debug_dump.dumpActionTableAlloc(allocator, result.states, result.actions);
}

pub fn generateGroupedActionTableDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try debug_dump.dumpGroupedActionTableAlloc(allocator, result.states, result.actions);
}

test "generateStateDumpFromPrepared matches the tiny parser-state golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableTinyGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableTinyDump().contents, dump);
}

test "generateStateActionDumpFromPrepared matches the tiny parser-state action golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableTinyGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(
        \\state 0
        \\  items:
        \\    #0@0
        \\    #1@0
        \\    #2@0
        \\  transitions:
        \\    non_terminal:0 -> 1
        \\    non_terminal:1 -> 2
        \\    terminal:0 -> 3
        \\  actions:
        \\    terminal:0 => shift 3
        \\
        \\state 1
        \\  items:
        \\    #0@1
        \\  transitions:
        \\  actions:
        \\
        \\state 2
        \\  items:
        \\    #1@1
        \\  transitions:
        \\  actions:
        \\
        \\state 3
        \\  items:
        \\    #2@1
        \\  transitions:
        \\  actions:
        \\
    , dump);
}

test "buildStatesFromPrepared reports a focused shift/reduce conflict fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    var saw_shift_reduce = false;
    for (result.states) |parse_state| {
        for (parse_state.conflicts) |conflict| {
            if (conflict.kind == .shift_reduce) {
                saw_shift_reduce = true;
                try std.testing.expect(conflict.symbol != null);
            }
        }
    }

    try std.testing.expect(saw_shift_reduce);
}

test "generateStateDumpFromPrepared matches the conflict parser-state golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableConflictDump().contents, dump);
}

test "generateStateActionDumpFromPrepared matches the conflict parser-state action golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableConflictActionDump().contents, dump);
}

test "generateActionTableDumpFromPrepared matches the conflict action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableConflictActionTableDump().contents, dump);
}

test "generateGroupedActionTableDumpFromPrepared matches the conflict grouped action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateGroupedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableConflictGroupedActionTableDump().contents, dump);
}

test "generateGroupedActionTableDumpFromPrepared matches the reduce/reduce grouped action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateGroupedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableReduceReduceGroupedActionTableDump().contents, dump);
}

test "generateActionTableDumpFromPrepared matches the reduce/reduce action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableReduceReduceActionTableDump().contents, dump);
}

test "generateActionTableDumpFromPrepared matches the metadata-rich action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataActionTableDump().contents, dump);
}

test "generateGroupedActionTableDumpFromPrepared matches the metadata-rich grouped action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateGroupedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataGroupedActionTableDump().contents, dump);
}

test "generateStateActionDumpFromPrepared matches the reduce/reduce parser-state action golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableReduceReduceActionDump().contents, dump);
}

test "buildStatesFromPrepared reuses identical advanced states deterministically" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqual(@as(state.StateId, 3), result.states[0].transitions[2].state);
    try std.testing.expectEqual(result.states[0].transitions[2].state, result.states[4].transitions[1].state);
}

test "buildStatesFromPrepared reports a focused reduce/reduce conflict fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    var saw_reduce_reduce = false;
    for (result.states) |parse_state| {
        for (parse_state.conflicts) |conflict| {
            if (conflict.kind == .reduce_reduce) {
                saw_reduce_reduce = true;
                try std.testing.expect(conflict.symbol != null);
                try std.testing.expectEqual(@as(u32, 0), conflict.symbol.?.terminal);
                try std.testing.expectEqual(@as(usize, 2), conflict.items.len);
            }
        }
    }

    try std.testing.expect(saw_reduce_reduce);
}

test "buildStatesFromPrepared supports metadata-rich grammar through the real preparation path" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqual(@as(usize, 7), result.states.len);
    try std.testing.expect(result.states[0].transitions.len >= 2);
}

test "generateStateActionDumpFromPrepared matches the metadata-rich parser-state action golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataActionDump().contents, dump);
}

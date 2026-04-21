const std = @import("std");
const grammar_ir = @import("../ir/grammar_ir.zig");
const actions = @import("actions.zig");
const debug_dump = @import("debug_dump.zig");
const build = @import("build.zig");
const resolution = @import("resolution.zig");
const serialize = @import("serialize.zig");
const parser_tables_emit = @import("../parser_emit/parser_tables.zig");
const c_tables_emit = @import("../parser_emit/c_tables.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const compat_checks = @import("../parser_emit/compat_checks.zig");
const process_support = @import("../support/process.zig");
const state = @import("state.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const flatten_grammar = @import("../grammar/prepare/flatten_grammar.zig");
const fixtures = @import("../tests/fixtures.zig");
const grammar_loader = @import("../grammar/loader.zig");
const json_loader = @import("../grammar/json_loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const emit_optimize = @import("../parser_emit/optimize.zig");
const runtime_io = @import("../support/runtime_io.zig");

threadlocal var scoped_progress_enabled: bool = false;

fn envFlagEnabled(name: []const u8) bool {
    const value = std.process.Environ.getAlloc(runtime_io.environ(), std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

fn hasProgressTargetFilter() bool {
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        "GEN_Z_SITTER_PARSE_TABLE_TARGET_FILTER",
    ) catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len != 0;
}

pub fn setScopedProgressEnabled(enabled: bool) void {
    scoped_progress_enabled = enabled;
}

fn shouldLogPipelineProgress() bool {
    const requested =
        envFlagEnabled("GEN_Z_SITTER_PARSE_TABLE_PROGRESS") or
        envFlagEnabled("GEN_Z_SITTER_PROGRESS");
    if (!requested) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn logPipelineStart(step: []const u8) void {
    std.debug.print("[parse_table_pipeline] start {s}\n", .{step});
}

fn logPipelineDone(step: []const u8) void {
    std.debug.print("[parse_table_pipeline] done  {s}\n", .{step});
}

fn maybeStartTimer(enabled: bool) bool {
    return enabled;
}

fn maybeLogPipelineDone(step: []const u8, enabled: bool) void {
    if (enabled) logPipelineDone(step);
}

fn logPipelineSummary(comptime format: []const u8, args: anytype) void {
    std.debug.print("[parse_table_pipeline] " ++ format ++ "\n", args);
}

pub const PipelineError =
    extract_tokens.ExtractTokensError ||
    flatten_grammar.FlattenGrammarError ||
    build.BuildError ||
    serialize.SerializeError ||
    parser_tables_emit.EmitError ||
    c_tables_emit.EmitError ||
    parser_c_emit.EmitError ||
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
    return try buildStatesFromPreparedWithOptions(allocator, prepared, .{});
}

pub fn buildStatesFromPreparedWithOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    build_options: build.BuildOptions,
) PipelineError!build.BuildResult {
    const progress_log = shouldLogPipelineProgress();
    std.debug.print("[parse_table/pipeline] buildStatesFromPreparedWithOptions enter\n", .{});

    var timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/pipeline] stage extract_tokens\n", .{});
    if (progress_log) logPipelineStart("extract_tokens");
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    if (progress_log) maybeLogPipelineDone("extract_tokens", timer);

    timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/pipeline] stage flatten_grammar\n", .{});
    if (progress_log) logPipelineStart("flatten_grammar");
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    if (progress_log) maybeLogPipelineDone("flatten_grammar", timer);

    timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/pipeline] stage build_states\n", .{});
    if (progress_log) logPipelineStart("build_states");
    const result = try build.buildStatesWithOptions(allocator, flattened, build_options);
    if (progress_log) {
        maybeLogPipelineDone("build_states", timer);
        logPipelineSummary(
            "build_states summary states={d} unresolved_decisions={} serialization_ready={}",
            .{ result.states.len, result.hasUnresolvedDecisions(), result.isSerializationReady() },
        );
    }
    return result;
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

pub fn generateResolvedActionTableDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try debug_dump.dumpResolvedActionTableAlloc(allocator, result.resolved_actions);
}

pub fn generateSerializedTableDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    const serialized = try serialize.serializeBuildResult(allocator, result, mode);
    return try debug_dump.dumpSerializedTableAlloc(allocator, serialized);
}

pub fn generateParserTableEmitterDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError![]const u8 {
    return try generateParserTableEmitterDumpFromPreparedWithOptions(allocator, prepared, mode, .{});
}

pub fn generateParserTableEmitterDumpFromPreparedWithOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
    options: emit_optimize.Options,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    const serialized = try serialize.serializeBuildResult(allocator, result, mode);
    return try parser_tables_emit.emitSerializedTableAllocWithOptions(allocator, serialized, options);
}

pub fn generateCTableEmitterDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError![]const u8 {
    return try generateCTableEmitterDumpFromPreparedWithOptions(allocator, prepared, mode, .{});
}

pub fn generateCTableEmitterDumpFromPreparedWithOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
    options: emit_optimize.Options,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    const serialized = try serialize.serializeBuildResult(allocator, result, mode);
    return try c_tables_emit.emitCTableSkeletonAllocWithOptions(allocator, serialized, options);
}

pub fn generateParserCEmitterDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError![]const u8 {
    return try generateParserCEmitterDumpFromPreparedWithOptions(allocator, prepared, mode, .{});
}

pub fn generateParserCEmitterDumpFromPreparedWithOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
    options: emit_optimize.Options,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    const serialized = try serialize.serializeBuildResult(allocator, result, mode);
    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, options);
}

pub fn serializeTableFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError!serialize.SerializedTable {
    return try serializeTableFromPreparedWithBuildOptions(allocator, prepared, mode, .{});
}

pub fn serializeTableFromPreparedWithBuildOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
    build_options: build.BuildOptions,
) PipelineError!serialize.SerializedTable {
    const progress_log = shouldLogPipelineProgress();
    std.debug.print("[parse_table/pipeline] serializeTableFromPreparedWithBuildOptions enter mode={s}\n", .{@tagName(mode)});
    const result = try buildStatesFromPreparedWithOptions(allocator, prepared, build_options);
    const timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/pipeline] stage serialize_build_result\n", .{});
    if (progress_log) logPipelineStart("serialize_build_result");
    const serialized = try serialize.serializeBuildResult(allocator, result, mode);
    if (progress_log) {
        maybeLogPipelineDone("serialize_build_result", timer);
        logPipelineSummary(
            "serialize_build_result summary mode={s} serialized_states={d} blocked={}",
            .{ @tagName(mode), serialized.states.len, serialized.blocked },
        );
    }
    return serialized;
}

fn writeModuleExportsJsonFile(dir: std.fs.Dir, sub_path: []const u8, json_contents: []const u8) !void {
    const js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{json_contents});
    defer std.testing.allocator.free(js);
    try dir.writeFile(.{
        .sub_path = sub_path,
        .data = js,
    });
}

fn expectParserCDumpCompiles(contents: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "parser.c",
        .data = contents,
    });

    const source_path = try tmp.dir.realpathAlloc(std.testing.allocator, "parser.c");
    defer std.testing.allocator.free(source_path);

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const object_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "parser.o" });
    defer std.testing.allocator.free(object_path);

    var result = try process_support.runCapture(
        std.testing.allocator,
        &.{ "zig", "cc", "-std=c11", "-c", source_path, "-o", object_path },
    );
    defer result.deinit(std.testing.allocator);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("zig cc stderr:\n{s}\n", .{result.stderr});
                try std.testing.expectEqual(@as(u8, 0), code);
            }
        },
        else => return error.UnexpectedCompilerTermination,
    }
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

test "generateGroupedActionTableDumpFromPrepared matches the tiny grouped action-table golden fixture" {
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
    const dump = try generateGroupedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableTinyGroupedActionTableDump().contents, dump);
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
    try std.testing.expectEqual(result.states.len, result.resolved_actions.states.len);
    try std.testing.expect(result.resolved_actions.groupsForState(result.states[0].id).len > 0);
    try std.testing.expect(result.isSerializationReady());
    try std.testing.expect(!result.hasUnresolvedDecisions());
    const chosen = try result.chosenDecisionsAlloc(pipeline_arena.allocator());
    try std.testing.expect(chosen.len > 0);
    const snapshot = try result.decisionSnapshotAlloc(pipeline_arena.allocator());
    try std.testing.expect(snapshot.isSerializationReady());
    try std.testing.expect(snapshot.unresolved.len == 0);
    try std.testing.expect(snapshot.chosen.len > 0);
}

test "resolveActionTableSkeleton leaves the first precedence-sensitive grammar unresolved" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTablePrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);
    const grouped = try actions.groupActionTable(pipeline_arena.allocator(), result.actions);
    const resolved = try resolution.resolveActionTableSkeleton(pipeline_arena.allocator(), grouped);

    var saw_unresolved = false;
    for (result.states) |parse_state| {
        for (parse_state.conflicts) |conflict| {
            if (conflict.kind != .shift_reduce) continue;
            if (conflict.symbol == null) continue;

            const decision = resolved.decisionFor(parse_state.id, conflict.symbol.?) orelse continue;
            try std.testing.expectEqual(
                resolution.UnresolvedReason.shift_reduce,
                switch (decision) {
                    .chosen => unreachable,
                    .unresolved => |reason| reason,
                },
            );
            try std.testing.expect(
                resolved.candidateActionsFor(parse_state.id, conflict.symbol.?).len >= 2,
            );
            saw_unresolved = true;
        }
    }

    try std.testing.expect(saw_unresolved);
}

test "generateResolvedActionTableDumpFromPrepared chooses reduce for the first precedence-sensitive grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTablePrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTablePrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared chooses reduce for the first named-precedence grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNamedPrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNamedPrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared chooses shift for the second named-precedence grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNamedPrecedenceShiftGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNamedPrecedenceShiftResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared chooses reduce for the first dynamic-precedence grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableDynamicPrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableDynamicPrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared chooses shift for the first negative-dynamic-precedence grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNegativeDynamicPrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNegativeDynamicPrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared lets dynamic precedence outrank named precedence" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableDynamicBeatsNamedPrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableDynamicBeatsNamedPrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared chooses shift for the first negative-precedence grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNegativePrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNegativePrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared keeps unresolved conflict groups explicit" {
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
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expect(!result.isSerializationReady());
    try std.testing.expect(result.hasUnresolvedDecisions());
    const unresolved = try result.unresolvedDecisionsAlloc(pipeline_arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), unresolved.len);
    try std.testing.expectEqual(resolution.UnresolvedReason.shift_reduce, unresolved[0].reason);
    const snapshot = try result.decisionSnapshotAlloc(pipeline_arena.allocator());
    try std.testing.expect(!snapshot.isSerializationReady());
    try std.testing.expect(snapshot.unresolved.len == 1);
    try std.testing.expectEqualStrings(fixtures.parseTableConflictResolvedActionDump().contents, dump);
}

test "buildStatesFromPrepared serializes metadata-rich grammar in strict mode" {
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
    const serialized = try serialize.serializeBuildResult(
        pipeline_arena.allocator(),
        result,
        .strict,
    );

    try std.testing.expect(serialized.isSerializationReady());
    try std.testing.expect(serialized.states.len > 0);
}

test "buildStatesFromPrepared rejects unresolved conflict grammar in strict serialization mode" {
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

    try std.testing.expectError(
        error.UnresolvedDecisions,
        serialize.serializeBuildResult(pipeline_arena.allocator(), result, .strict),
    );
}

test "generateSerializedTableDumpFromPrepared matches the metadata-rich serialized-table golden fixture" {
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
    const dump = try generateSerializedTableDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataSerializedDump().contents, dump);
}

test "generateSerializedTableDumpFromPrepared matches the conflict diagnostic serialized-table golden fixture" {
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
    const dump = try generateSerializedTableDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .diagnostic,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableConflictSerializedDump().contents, dump);
}

test "generateParserTableEmitterDumpFromPrepared matches the metadata-rich emitter golden fixture" {
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
    const dump = try generateParserTableEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataEmitterDump().contents, dump);
}

test "generateParserTableEmitterDumpFromPrepared matches the conflict diagnostic emitter golden fixture" {
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
    const dump = try generateParserTableEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .diagnostic,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableConflictEmitterDump().contents, dump);
}

test "generateCTableEmitterDumpFromPrepared matches the metadata-rich C-like emitter golden fixture" {
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
    const dump = try generateCTableEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataCTablesDump().contents, dump);
}

test "generateCTableEmitterDumpFromPrepared matches the conflict diagnostic C-like emitter golden fixture" {
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
    const dump = try generateCTableEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .diagnostic,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableConflictCTablesDump().contents, dump);
}

test "generateParserCEmitterDumpFromPrepared matches the metadata-rich parser.c-like emitter golden fixture" {
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
    const dump = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataParserCDump().contents, dump);
    try compat_checks.validateParserCCompatibilitySurface(dump);
    try expectParserCDumpCompiles(dump);
}

test "generateParserCEmitterDumpFromPrepared matches the conflict diagnostic parser.c-like emitter golden fixture" {
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
    const dump = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .diagnostic,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableConflictParserCDump().contents, dump);
    try compat_checks.validateParserCCompatibilitySurface(dump);
    try expectParserCDumpCompiles(dump);
}

test "generateParserCEmitterDumpFromPrepared matches the metadata-rich parser.c-like emitter golden fixture through grammar.js" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeModuleExportsJsonFile(tmp.dir, "grammar.js", fixtures.parseTableMetadataGrammarJson().contents);

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
    defer std.testing.allocator.free(grammar_path);

    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &loaded.json.grammar);
    const dump = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataParserCDump().contents, dump);
}

test "generateParserCEmitterDumpFromPrepared keeps behavioral config parser output stable across grammar.json and grammar.js" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.behavioralConfigGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared_from_json = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump_from_json = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared_from_json,
        .strict,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data = fixtures.behavioralConfigGrammarJs().contents,
    });

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
    defer std.testing.allocator.free(grammar_path);

    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var parse_arena_js = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena_js.deinit();
    var pipeline_arena_js = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena_js.deinit();

    const prepared_from_js = try parse_grammar.parseRawGrammar(parse_arena_js.allocator(), &loaded.json.grammar);
    const dump_from_js = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena_js.allocator(),
        prepared_from_js,
        .strict,
    );

    try std.testing.expectEqualStrings(dump_from_json, dump_from_js);
}

test "generateResolvedActionTableDumpFromPrepared keeps reduce/reduce conflict groups explicit" {
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
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableReduceReduceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared resolves the first associativity-sensitive grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableAssociativityGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableAssociativityResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared keeps equal-precedence non-associative conflicts unresolved" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNonAssociativeGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNonAssociativeResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared resolves the first right-associativity-sensitive grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableRightAssociativityGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableRightAssociativityResolvedActionDump().contents, dump);
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

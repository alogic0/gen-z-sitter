const std = @import("std");
const fixtures = @import("src/tests/fixtures.zig");
const json_loader = @import("src/grammar/json_loader.zig");
const parse_grammar = @import("src/grammar/parse_grammar.zig");
const parse_table_pipeline = @import("src/parse_table/pipeline.zig");
const serialize = @import("src/parse_table/serialize.zig");
const runtime_io = @import("src/support/runtime_io.zig");

const fixtures_path = "src/tests/fixtures.zig";

const DumpKind = enum {
    state,
    state_action,
    action_table,
    grouped_action_table,
    resolved_action_table,
    serialized_strict,
    serialized_diagnostic,
    parser_table_strict,
    parser_table_diagnostic,
    parser_c_strict,
    parser_c_diagnostic,
};

const GoldenTarget = struct {
    grammar: *const fn () fixtures.Fixture,
    expected: *const fn () fixtures.Fixture,
    expected_fn_name: []const u8,
    kind: DumpKind,
};

const targets = [_]GoldenTarget{
    .{ .grammar = fixtures.parseTableTinyGrammarJson, .expected = fixtures.parseTableTinyDump, .expected_fn_name = "parseTableTinyDump", .kind = .state },
    .{ .grammar = fixtures.parseTableConflictGrammarJson, .expected = fixtures.parseTableConflictDump, .expected_fn_name = "parseTableConflictDump", .kind = .state },
    .{ .grammar = fixtures.parseTableConflictGrammarJson, .expected = fixtures.parseTableConflictActionDump, .expected_fn_name = "parseTableConflictActionDump", .kind = .state_action },
    .{ .grammar = fixtures.parseTableReduceReduceGrammarJson, .expected = fixtures.parseTableReduceReduceActionDump, .expected_fn_name = "parseTableReduceReduceActionDump", .kind = .state_action },
    .{ .grammar = fixtures.parseTableMetadataGrammarJson, .expected = fixtures.parseTableMetadataActionDump, .expected_fn_name = "parseTableMetadataActionDump", .kind = .state_action },
    .{ .grammar = fixtures.parseTableMetadataGrammarJson, .expected = fixtures.parseTableMetadataSerializedDump, .expected_fn_name = "parseTableMetadataSerializedDump", .kind = .serialized_strict },
    .{ .grammar = fixtures.parseTableConflictGrammarJson, .expected = fixtures.parseTableConflictSerializedDump, .expected_fn_name = "parseTableConflictSerializedDump", .kind = .serialized_diagnostic },
    .{ .grammar = fixtures.parseTableMetadataGrammarJson, .expected = fixtures.parseTableMetadataEmitterDump, .expected_fn_name = "parseTableMetadataEmitterDump", .kind = .parser_table_strict },
    .{ .grammar = fixtures.parseTableConflictGrammarJson, .expected = fixtures.parseTableConflictEmitterDump, .expected_fn_name = "parseTableConflictEmitterDump", .kind = .parser_table_diagnostic },
    .{ .grammar = fixtures.parseTableMetadataGrammarJson, .expected = fixtures.parseTableMetadataParserCDump, .expected_fn_name = "parseTableMetadataParserCDump", .kind = .parser_c_strict },
    .{ .grammar = fixtures.parseTableConflictGrammarJson, .expected = fixtures.parseTableConflictParserCDump, .expected_fn_name = "parseTableConflictParserCDump", .kind = .parser_c_diagnostic },
    .{ .grammar = fixtures.parseTableConflictGrammarJson, .expected = fixtures.parseTableConflictActionTableDump, .expected_fn_name = "parseTableConflictActionTableDump", .kind = .action_table },
    .{ .grammar = fixtures.parseTableConflictGrammarJson, .expected = fixtures.parseTableConflictGroupedActionTableDump, .expected_fn_name = "parseTableConflictGroupedActionTableDump", .kind = .grouped_action_table },
    .{ .grammar = fixtures.parseTableTinyGrammarJson, .expected = fixtures.parseTableTinyGroupedActionTableDump, .expected_fn_name = "parseTableTinyGroupedActionTableDump", .kind = .grouped_action_table },
    .{ .grammar = fixtures.parseTableReduceReduceGrammarJson, .expected = fixtures.parseTableReduceReduceGroupedActionTableDump, .expected_fn_name = "parseTableReduceReduceGroupedActionTableDump", .kind = .grouped_action_table },
    .{ .grammar = fixtures.parseTableReduceReduceGrammarJson, .expected = fixtures.parseTableReduceReduceActionTableDump, .expected_fn_name = "parseTableReduceReduceActionTableDump", .kind = .action_table },
    .{ .grammar = fixtures.parseTableMetadataGrammarJson, .expected = fixtures.parseTableMetadataGroupedActionTableDump, .expected_fn_name = "parseTableMetadataGroupedActionTableDump", .kind = .grouped_action_table },
    .{ .grammar = fixtures.parseTableMetadataGrammarJson, .expected = fixtures.parseTableMetadataActionTableDump, .expected_fn_name = "parseTableMetadataActionTableDump", .kind = .action_table },
    .{ .grammar = fixtures.parseTablePrecedenceGrammarJson, .expected = fixtures.parseTablePrecedenceResolvedActionDump, .expected_fn_name = "parseTablePrecedenceResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableNamedPrecedenceGrammarJson, .expected = fixtures.parseTableNamedPrecedenceResolvedActionDump, .expected_fn_name = "parseTableNamedPrecedenceResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableNamedPrecedenceShiftGrammarJson, .expected = fixtures.parseTableNamedPrecedenceShiftResolvedActionDump, .expected_fn_name = "parseTableNamedPrecedenceShiftResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableDynamicPrecedenceGrammarJson, .expected = fixtures.parseTableDynamicPrecedenceResolvedActionDump, .expected_fn_name = "parseTableDynamicPrecedenceResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableNegativeDynamicPrecedenceGrammarJson, .expected = fixtures.parseTableNegativeDynamicPrecedenceResolvedActionDump, .expected_fn_name = "parseTableNegativeDynamicPrecedenceResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableDynamicBeatsNamedPrecedenceGrammarJson, .expected = fixtures.parseTableDynamicBeatsNamedPrecedenceResolvedActionDump, .expected_fn_name = "parseTableDynamicBeatsNamedPrecedenceResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableNegativePrecedenceGrammarJson, .expected = fixtures.parseTableNegativePrecedenceResolvedActionDump, .expected_fn_name = "parseTableNegativePrecedenceResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableAssociativityGrammarJson, .expected = fixtures.parseTableAssociativityResolvedActionDump, .expected_fn_name = "parseTableAssociativityResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableNonAssociativeGrammarJson, .expected = fixtures.parseTableNonAssociativeResolvedActionDump, .expected_fn_name = "parseTableNonAssociativeResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableRightAssociativityGrammarJson, .expected = fixtures.parseTableRightAssociativityResolvedActionDump, .expected_fn_name = "parseTableRightAssociativityResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableConflictGrammarJson, .expected = fixtures.parseTableConflictResolvedActionDump, .expected_fn_name = "parseTableConflictResolvedActionDump", .kind = .resolved_action_table },
    .{ .grammar = fixtures.parseTableReduceReduceGrammarJson, .expected = fixtures.parseTableReduceReduceResolvedActionDump, .expected_fn_name = "parseTableReduceReduceResolvedActionDump", .kind = .resolved_action_table },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    runtime_io.set(init.io, init.minimal.environ);

    const argv_z = try init.minimal.args.toSlice(allocator);
    defer allocator.free(argv_z);
    const write = parseOptions(argv_z[1..]) catch {
        try std.Io.File.stderr().writeStreamingAll(init.io, usage());
        std.process.exit(2);
    };

    var generated = try allocator.alloc([]const u8, targets.len);
    defer {
        for (generated) |dump| allocator.free(dump);
        allocator.free(generated);
    }

    var changed = false;
    for (targets, 0..) |target, index| {
        generated[index] = try generateDumpForFixtureAlloc(allocator, target.grammar(), target.kind);
        if (!std.mem.eql(u8, generated[index], target.expected().contents)) {
            changed = true;
            std.debug.print("[refresh_parse_table_goldens] stale {s}\n", .{target.expected_fn_name});
        }
    }

    if (!write) {
        if (changed) return error.ParseTableGoldenMismatch;
        std.debug.print("[refresh_parse_table_goldens] all parse-table goldens are current\n", .{});
        return;
    }

    var source: []const u8 = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), fixtures_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(source);
    for (targets, generated) |target, dump| {
        const updated = try replaceGoldenFunctionAlloc(allocator, source, target.expected_fn_name, dump);
        allocator.free(source);
        source = updated;
    }
    try std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = fixtures_path, .data = source });
    std.debug.print("[refresh_parse_table_goldens] wrote {s}\n", .{fixtures_path});
}

fn parseOptions(args: []const [:0]const u8) !bool {
    if (args.len != 1) return error.InvalidArguments;
    if (std.mem.eql(u8, args[0], "--check")) return false;
    if (std.mem.eql(u8, args[0], "--write")) return true;
    return error.InvalidArguments;
}

fn usage() []const u8 {
    return
    \\Usage:
    \\  zig run refresh_parse_table_goldens.zig -- --check
    \\  zig run refresh_parse_table_goldens.zig -- --write
    \\
    ;
}

fn generateDumpForFixtureAlloc(
    allocator: std.mem.Allocator,
    grammar: fixtures.Fixture,
    kind: DumpKind,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), grammar.contents, .{});
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &raw);
    const dump = switch (kind) {
        .state => try parse_table_pipeline.generateStateDumpFromPrepared(arena.allocator(), prepared),
        .state_action => try parse_table_pipeline.generateStateActionDumpFromPrepared(arena.allocator(), prepared),
        .action_table => try parse_table_pipeline.generateActionTableDumpFromPrepared(arena.allocator(), prepared),
        .grouped_action_table => try parse_table_pipeline.generateGroupedActionTableDumpFromPrepared(arena.allocator(), prepared),
        .resolved_action_table => try parse_table_pipeline.generateResolvedActionTableDumpFromPrepared(arena.allocator(), prepared),
        .serialized_strict => try parse_table_pipeline.generateSerializedTableDumpFromPrepared(arena.allocator(), prepared, .strict),
        .serialized_diagnostic => try parse_table_pipeline.generateSerializedTableDumpFromPrepared(arena.allocator(), prepared, .diagnostic),
        .parser_table_strict => try parse_table_pipeline.generateParserTableEmitterDumpFromPrepared(arena.allocator(), prepared, .strict),
        .parser_table_diagnostic => try parse_table_pipeline.generateParserTableEmitterDumpFromPrepared(arena.allocator(), prepared, .diagnostic),
        .parser_c_strict => try parse_table_pipeline.generateParserCEmitterDumpFromPrepared(arena.allocator(), prepared, .strict),
        .parser_c_diagnostic => try parse_table_pipeline.generateParserCEmitterDumpFromPrepared(arena.allocator(), prepared, .diagnostic),
    };
    return try allocator.dupe(u8, dump);
}

fn replaceGoldenFunctionAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    fn_name: []const u8,
    dump: []const u8,
) ![]const u8 {
    const fn_marker = try std.fmt.allocPrint(allocator, "pub fn {s}() Fixture {{", .{fn_name});
    defer allocator.free(fn_marker);
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.GoldenFunctionNotFound;
    const content_marker = "        .contents =\n";
    const content_start = std.mem.indexOfPos(u8, source, fn_start, content_marker) orelse return error.GoldenContentsNotFound;
    const literal_start = content_start + content_marker.len;
    const literal_end = std.mem.indexOfPos(u8, source, literal_start, "\n        ,\n    };\n}") orelse return error.GoldenContentsEndNotFound;

    var replacement: std.Io.Writer.Allocating = .init(allocator);
    errdefer replacement.deinit();
    var lines = std.mem.splitScalar(u8, dump, '\n');
    while (lines.next()) |line| {
        try replacement.writer.writeAll("        \\\\");
        try replacement.writer.writeAll(line);
        try replacement.writer.writeByte('\n');
    }
    const replacement_slice = try replacement.toOwnedSlice();
    defer allocator.free(replacement_slice);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(source[0..literal_start]);
    try out.writer.writeAll(replacement_slice);
    try out.writer.writeAll(source[literal_end..]);
    return try out.toOwnedSlice();
}

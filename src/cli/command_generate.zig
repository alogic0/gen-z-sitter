const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const diag = @import("../support/diag.zig");
const debug_dump = @import("../grammar/debug_dump.zig");
const grammar_ir = @import("../ir/grammar_ir.zig");
const grammar_loader = @import("../grammar/loader.zig");
const json_loader = @import("../grammar/json_loader.zig");
const fs_support = @import("../support/fs.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const node_type_pipeline = @import("../node_types/pipeline.zig");
const parse_table_build = @import("../parse_table/build.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const parser_tables_emit = @import("../parser_emit/parser_tables.zig");
const parser_compat = @import("../parser_emit/compat.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const emit_optimize = @import("../parser_emit/optimize.zig");
const upstream_summary = @import("../compat/upstream_summary.zig");
const fixtures = @import("../tests/fixtures.zig");

const EmittedSizeStats = struct {
    parser_tables_baseline_bytes: usize,
    parser_tables_emitted_bytes: usize,
    parser_c_baseline_bytes: usize,
    parser_c_emitted_bytes: usize,
};

const ParseTableMinimizationStats = struct {
    default_state_count: usize,
    minimized_state_count: usize,
    merged_state_count: usize,
    computed: bool = true,
};

const ExpectedConflictSummary = struct {
    declared_count: usize,
    unused_indexes: []const usize,

    pub fn unusedCount(self: ExpectedConflictSummary) usize {
        return self.unused_indexes.len;
    }
};

const JsonSummaryResult = struct {
    json: []const u8,
    expected_conflicts: ExpectedConflictSummary,
};

pub fn runGenerate(allocator: std.mem.Allocator, io: std.Io, opts: args.GenerateOptions) !void {
    if (opts.grammar_path.len == 0) {
        return error.InvalidArguments;
    }
    if (opts.abi_version != parser_compat.language_version) {
        var note_buffer: [96]u8 = undefined;
        const note = try std.fmt.bufPrint(&note_buffer, "only ABI {d} is currently supported", .{parser_compat.language_version});
        try diag.printStderr(io, .{
            .kind = .usage,
            .message = "unsupported ABI version",
            .note = note,
        });
        return error.InvalidArguments;
    }
    if (opts.emit_parser_c and opts.no_parser) {
        try diag.printStderr(io, .{
            .kind = .usage,
            .message = "--emit-parser-c cannot be combined with --no-parser",
        });
        return error.InvalidArguments;
    }
    if (opts.emit_parser_c and opts.output_dir == null) {
        try diag.printStderr(io, .{
            .kind = .usage,
            .message = "--emit-parser-c requires --output <dir>",
        });
        return error.InvalidArguments;
    }

    var loaded = grammar_loader.loadGrammarFileWithOptions(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
    }) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                try diag.printStderr(io, .{
                    .kind = .internal,
                    .message = grammar_loader.errorMessage(err),
                    .note = grammar_loader.errorNote(err),
                    .path = opts.grammar_path,
                });
                return err;
            },
            else => {
                try diag.printStderr(io, .{
                    .kind = if (err == error.IoFailure or err == error.ProcessFailure) .io else .usage,
                    .message = grammar_loader.errorMessage(err),
                    .note = grammar_loader.errorNote(err),
                    .path = opts.grammar_path,
                });
                return error.InvalidArguments;
            },
        }
    };
    defer loaded.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const prepared = parse_grammar.parseRawGrammar(parse_arena.allocator(), &loaded.json.grammar) catch |err| {
        const diagnostic = parse_grammar.errorDiagnostic(err);
        try diag.printStderr(io, .{
            .kind = .usage,
            .message = diagnostic.summary,
            .note = diagnostic.note,
            .path = opts.grammar_path,
        });
        return error.InvalidArguments;
    };

    if (opts.debug_prepared) {
        const dump = try debug_dump.dumpPreparedGrammar(allocator, prepared);
        defer allocator.free(dump);
        if (!builtin.is_test) {
            try std.Io.File.stdout().writeStreamingAll(io, dump);
        }
        return;
    }

    if (opts.debug_node_types) {
        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const json = node_type_pipeline.generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared) catch |err| switch (err) {
            error.InvalidSupertype => {
                try diag.printStderr(io, .{
                    .kind = .usage,
                    .message = "invalid supertype for node-types computation",
                    .path = opts.grammar_path,
                });
                return error.InvalidArguments;
            },
            else => return err,
        };

        if (!builtin.is_test) {
            try std.Io.File.stdout().writeStreamingAll(io, json);
        }
        return;
    }

    if (opts.debug_conflicts) {
        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const json = try upstream_summary.generateLocalConflictSummaryJsonFromPreparedAlloc(pipeline_arena.allocator(), prepared, .{
            .minimize_states = opts.minimize_states,
        });
        if (!builtin.is_test) {
            try std.Io.File.stdout().writeStreamingAll(io, json);
        }
        return;
    }

    if (opts.debug_production_info) {
        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const json = try upstream_summary.generateLocalProductionInfoSummaryJsonFromPreparedAlloc(pipeline_arena.allocator(), prepared, .{
            .minimize_states = opts.minimize_states,
        });
        if (!builtin.is_test) {
            try std.Io.File.stdout().writeStreamingAll(io, json);
        }
        return;
    }

    if (opts.report_states_for_rule) |rule_name| {
        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const dump = parse_table_pipeline.generateStateActionDumpForRuleFromPrepared(
            pipeline_arena.allocator(),
            prepared,
            rule_name,
        ) catch |err| switch (err) {
            error.UnknownRule => {
                try diag.printStderr(io, .{
                    .kind = .usage,
                    .message = "unknown rule for state report",
                    .note = rule_name,
                    .path = opts.grammar_path,
                });
                return error.InvalidArguments;
            },
            else => return err,
        };

        if (!builtin.is_test) {
            try std.Io.File.stdout().writeStreamingAll(io, dump);
        }
        return;
    }

    if (opts.output_dir) |output_dir| {
        try fs_support.ensureDir(output_dir);

        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const json = node_type_pipeline.generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared) catch |err| switch (err) {
            error.InvalidSupertype => {
                try diag.printStderr(io, .{
                    .kind = .usage,
                    .message = "invalid supertype for node-types computation",
                    .path = opts.grammar_path,
                });
                return error.InvalidArguments;
            },
            else => return err,
        };

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, "node-types.json" });
        defer allocator.free(output_path);
        try fs_support.writeFile(output_path, json);

        if (opts.emit_parser_c) {
            const build_options = parse_table_build.BuildOptions{
                .minimize_states = opts.minimize_states,
                .strict_expected_conflicts = opts.strict_expected_conflicts,
            };
            const parser_c = emitParserCFromPreparedAlloc(
                pipeline_arena.allocator(),
                prepared,
                build_options,
                .{
                    .compact_duplicate_states = opts.optimize_merge_states,
                    .glr_loop = opts.glr_loop,
                },
            ) catch |err| switch (err) {
                error.ParseActionListTooLarge,
                error.RuntimeFieldCountTooLarge,
                error.RuntimeLargeStateCountTooLarge,
                error.RuntimeLexStateCountTooLarge,
                error.RuntimeParseActionListTooLarge,
                error.RuntimeProductionCountTooLarge,
                error.RuntimeStateCountTooLarge,
                error.RuntimeSymbolCountTooLarge,
                => {
                    try diag.printStderr(io, .{
                        .kind = .usage,
                        .message = "grammar exceeds generated parser runtime table capacity",
                        .note = runtimeLimitErrorNote(err),
                        .path = opts.grammar_path,
                    });
                    return error.InvalidArguments;
                },
                else => return err,
            };
            const parser_path = try std.fs.path.join(allocator, &.{ output_dir, "parser.c" });
            defer allocator.free(parser_path);
            try fs_support.writeFile(parser_path, parser_c);
        }

        if (!opts.json_summary) {
            try diag.printStdout(io, .{
                .kind = .info,
                .message = if (opts.emit_parser_c) "wrote generated artifacts" else "wrote node-types.json",
                .path = output_dir,
            });
        }
    }

    if (opts.json_summary) {
        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const build_options = parse_table_build.BuildOptions{
            .minimize_states = opts.minimize_states,
            .strict_expected_conflicts = opts.strict_expected_conflicts,
        };
        const summary = try generateJsonSummaryWithReportAlloc(
            pipeline_arena.allocator(),
            loaded.json.grammar,
            prepared,
            build_options,
            .{ .compact_duplicate_states = opts.optimize_merge_states },
        );
        try printExpectedConflictWarnings(pipeline_arena.allocator(), io, prepared, summary.expected_conflicts);
        if (!builtin.is_test) {
            try std.Io.File.stdout().writeStreamingAll(io, summary.json);
        }
        return;
    }

    try diag.printStdout(io, .{
        .kind = .info,
        .message = "loaded grammar successfully",
        .path = opts.grammar_path,
    });
    try diag.printStdout(io, .{
        .kind = .info,
        .message = "grammar",
        .note = loaded.json.grammar.name,
    });

    var counts_buffer: [64]u8 = undefined;
    const rule_count = try std.fmt.bufPrint(&counts_buffer, "rules: {}", .{loaded.json.grammar.ruleCount()});
    try diag.printStdout(io, .{
        .kind = .info,
        .message = rule_count,
    });

    const external_count = try std.fmt.bufPrint(&counts_buffer, "externals: {}", .{loaded.json.grammar.externals.len});
    try diag.printStdout(io, .{
        .kind = .info,
        .message = external_count,
    });

    const extras_count = try std.fmt.bufPrint(&counts_buffer, "extras: {}", .{loaded.json.grammar.extras.len});
    try diag.printStdout(io, .{
        .kind = .info,
        .message = extras_count,
    });

    const symbol_count = try std.fmt.bufPrint(&counts_buffer, "symbols: {}", .{prepared.symbols.len});
    try diag.printStdout(io, .{
        .kind = .info,
        .message = symbol_count,
    });
}

fn emitParserCFromPreparedAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    build_options: parse_table_build.BuildOptions,
    options: emit_optimize.Options,
) ![]const u8 {
    const serialized = try parse_table_pipeline.serializeTableFromPreparedWithScopedBuildOptions(
        allocator,
        prepared,
        .diagnostic,
        build_options,
    );
    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, options);
}

fn runtimeLimitErrorNote(err: anyerror) []const u8 {
    return switch (err) {
        error.ParseActionListTooLarge,
        error.RuntimeParseActionListTooLarge,
        => "parse action list does not fit the current uint16_t runtime table format",
        error.RuntimeFieldCountTooLarge => "field count does not fit the current uint16_t runtime table format",
        error.RuntimeLargeStateCountTooLarge => "large state count does not fit the current uint16_t runtime table format",
        error.RuntimeLexStateCountTooLarge => "lexer state count does not fit the current uint16_t runtime table format",
        error.RuntimeProductionCountTooLarge => "production count does not fit the current uint16_t runtime table format",
        error.RuntimeStateCountTooLarge => "parse state count does not fit the current uint16_t runtime table format",
        error.RuntimeSymbolCountTooLarge => "symbol count does not fit the current uint16_t runtime table format",
        else => "generated parser table exceeds the current runtime table format",
    };
}

fn generateJsonSummaryAlloc(
    allocator: std.mem.Allocator,
    grammar: anytype,
    prepared: grammar_ir.PreparedGrammar,
    build_options: parse_table_build.BuildOptions,
    options: emit_optimize.Options,
) ![]const u8 {
    const result = try generateJsonSummaryWithReportAlloc(
        allocator,
        grammar,
        prepared,
        build_options,
        options,
    );
    return result.json;
}

fn generateJsonSummaryWithReportAlloc(
    allocator: std.mem.Allocator,
    grammar: anytype,
    prepared: grammar_ir.PreparedGrammar,
    build_options: parse_table_build.BuildOptions,
    options: emit_optimize.Options,
) !JsonSummaryResult {
    const table_result = try parse_table_pipeline.serializeTableAndExpectedConflictReportFromPreparedWithScopedBuildOptions(
        allocator,
        prepared,
        .diagnostic,
        build_options,
    );
    const serialized = table_result.serialized;
    const baseline_stats = try parser_c_emit.collectEmissionStatsWithOptions(allocator, serialized, .{
        .compact_duplicate_states = false,
    });
    const parser_stats = try parser_c_emit.collectEmissionStatsWithOptions(allocator, serialized, options);
    const serialized_state_count = serialized.states.len;
    const parse_table_minimization = try collectParseTableMinimizationStats(
        allocator,
        prepared,
        build_options,
        serialized_state_count,
    );
    const expected_conflicts = ExpectedConflictSummary{
        .declared_count = prepared.expected_conflicts.len,
        .unused_indexes = table_result.expected_conflict_report.unused_expected_conflict_indexes,
    };
    const emitted_size_stats = try collectEmittedSizeStats(allocator, serialized, options);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n");
    try writer.print("  \"blocked\": {s},\n", .{if (parser_stats.blocked) "true" else "false"});
    try writer.print("  \"rule_count\": {d},\n", .{grammar.ruleCount()});
    try writer.print("  \"external_count\": {d},\n", .{grammar.externals.len});
    try writer.print("  \"extra_count\": {d},\n", .{grammar.extras.len});
    try writer.print("  \"symbol_count\": {d},\n", .{prepared.symbols.len});
    try writer.print("  \"serialized_state_count\": {d},\n", .{serialized_state_count});
    try writer.print("  \"emitted_state_count\": {d},\n", .{parser_stats.state_count});
    try writer.print("  \"state_count\": {d},\n", .{parser_stats.state_count});
    try writer.print("  \"merged_state_count\": {d},\n", .{parser_stats.merged_state_count});
    try writer.print("  \"action_entry_count\": {d},\n", .{parser_stats.action_entry_count});
    try writer.print("  \"goto_entry_count\": {d},\n", .{parser_stats.goto_entry_count});
    try writer.print("  \"unresolved_entry_count\": {d},\n", .{parser_stats.unresolved_entry_count});
    try writer.writeAll("  \"optimization\": { ");
    try writer.print(
        "\"compact_duplicate_states\": {s}, \"minimize_states\": {s}",
        .{
            if (options.compact_duplicate_states) "true" else "false",
            if (build_options.minimize_states) "true" else "false",
        },
    );
    try writer.writeAll(" },\n");
    try writer.writeAll("  \"parse_table_minimization\": { ");
    try writer.print("\"default_state_count\": {d}, ", .{parse_table_minimization.default_state_count});
    try writer.print("\"minimized_state_count\": {d}, ", .{parse_table_minimization.minimized_state_count});
    try writer.print("\"merged_state_count\": {d}", .{parse_table_minimization.merged_state_count});
    if (!parse_table_minimization.computed) {
        try writer.writeAll(", \"computed\": false");
    }
    try writer.writeAll(" },\n");
    try writer.writeAll("  \"expected_conflicts\": { ");
    try writer.print("\"declared_count\": {d}, ", .{expected_conflicts.declared_count});
    try writer.print("\"unused_count\": {d}, ", .{expected_conflicts.unusedCount()});
    try writer.writeAll("\"unused_indexes\": [");
    for (expected_conflicts.unused_indexes, 0..) |unused_index, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{unused_index});
    }
    try writer.writeAll("] },\n");
    try writer.writeAll("  \"savings\": { ");
    try writer.print("\"state_count_delta\": {d}, ", .{serialized_state_count - parser_stats.state_count});
    try writer.print(
        "\"action_array_definitions_saved\": {d}, ",
        .{baseline_stats.action_rows.emitted_array_definitions - parser_stats.action_rows.emitted_array_definitions},
    );
    try writer.print(
        "\"goto_array_definitions_saved\": {d}, ",
        .{baseline_stats.goto_rows.emitted_array_definitions - parser_stats.goto_rows.emitted_array_definitions},
    );
    try writer.print(
        "\"unresolved_array_definitions_saved\": {d}, ",
        .{baseline_stats.unresolved_rows.emitted_array_definitions - parser_stats.unresolved_rows.emitted_array_definitions},
    );
    try writer.print(
        "\"total_array_definitions_saved\": {d}",
        .{
            (baseline_stats.action_rows.emitted_array_definitions - parser_stats.action_rows.emitted_array_definitions) +
                (baseline_stats.goto_rows.emitted_array_definitions - parser_stats.goto_rows.emitted_array_definitions) +
                (baseline_stats.unresolved_rows.emitted_array_definitions - parser_stats.unresolved_rows.emitted_array_definitions),
        },
    );
    try writer.writeAll(" },\n");
    try writer.writeAll("  \"emitted_bytes\": { ");
    try writer.print("\"parser_tables_baseline\": {d}, ", .{emitted_size_stats.parser_tables_baseline_bytes});
    try writer.print("\"parser_tables_emitted\": {d}, ", .{emitted_size_stats.parser_tables_emitted_bytes});
    try writer.print("\"parser_c_baseline\": {d}, ", .{emitted_size_stats.parser_c_baseline_bytes});
    try writer.print("\"parser_c_emitted\": {d}", .{emitted_size_stats.parser_c_emitted_bytes});
    try writer.writeAll(" },\n");
    try writer.writeAll("  \"baseline_action_rows\": ");
    try writeRowSharingStats(writer, baseline_stats.action_rows);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"emitted_action_rows\": ");
    try writeRowSharingStats(writer, parser_stats.action_rows);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"baseline_goto_rows\": ");
    try writeRowSharingStats(writer, baseline_stats.goto_rows);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"emitted_goto_rows\": ");
    try writeRowSharingStats(writer, parser_stats.goto_rows);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"baseline_unresolved_rows\": ");
    try writeRowSharingStats(writer, baseline_stats.unresolved_rows);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"emitted_unresolved_rows\": ");
    try writeRowSharingStats(writer, parser_stats.unresolved_rows);
    try writer.writeAll("\n}\n");

    return .{
        .json = try out.toOwnedSlice(),
        .expected_conflicts = expected_conflicts,
    };
}

fn printExpectedConflictWarnings(
    allocator: std.mem.Allocator,
    io: std.Io,
    prepared: grammar_ir.PreparedGrammar,
    expected_conflicts: ExpectedConflictSummary,
) !void {
    if (expected_conflicts.unusedCount() == 0) return;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    for (expected_conflicts.unused_indexes) |expected_index| {
        try writeExpectedConflictWarning(&out.writer, prepared, expected_index);
    }

    const warnings = try out.toOwnedSlice();
    defer allocator.free(warnings);

    if (!builtin.is_test) {
        try std.Io.File.stderr().writeStreamingAll(io, warnings);
    }
}

fn writeExpectedConflictWarning(
    writer: anytype,
    prepared: grammar_ir.PreparedGrammar,
    expected_index: usize,
) !void {
    const conflict_set = prepared.expected_conflicts[expected_index];
    try writer.print("warning: expected_conflicts[{d}] declared but no conflict found: [", .{expected_index});
    for (conflict_set, 0..) |symbol, symbol_index| {
        if (symbol_index != 0) try writer.writeAll(", ");
        try writeJsonString(writer, preparedSymbolName(prepared, symbol));
    }
    try writer.writeAll("]\n");
}

fn preparedSymbolName(prepared: grammar_ir.PreparedGrammar, symbol_id: @import("../ir/symbols.zig").SymbolId) []const u8 {
    for (prepared.symbols) |symbol| {
        if (symbol.id.kind == symbol_id.kind and symbol.id.index == symbol_id.index) return symbol.name;
    }
    return "<unknown>";
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn collectParseTableMinimizationStats(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    build_options: parse_table_build.BuildOptions,
    serialized_state_count: usize,
) !ParseTableMinimizationStats {
    if (!build_options.minimize_states) {
        return .{
            .default_state_count = serialized_state_count,
            .minimized_state_count = serialized_state_count,
            .merged_state_count = 0,
        };
    }

    _ = allocator;
    _ = prepared;
    return .{
        .default_state_count = 0,
        .minimized_state_count = serialized_state_count,
        .merged_state_count = 0,
        .computed = false,
    };
}

fn collectEmittedSizeStats(
    allocator: std.mem.Allocator,
    serialized: @import("../parse_table/serialize.zig").SerializedTable,
    options: emit_optimize.Options,
) !EmittedSizeStats {
    const baseline_options = emit_optimize.Options{ .compact_duplicate_states = false };

    const parser_tables_baseline = try parser_tables_emit.emitSerializedTableAllocWithOptions(allocator, serialized, baseline_options);
    defer allocator.free(parser_tables_baseline);
    const parser_tables_emitted = try parser_tables_emit.emitSerializedTableAllocWithOptions(allocator, serialized, options);
    defer allocator.free(parser_tables_emitted);

    const parser_c_baseline = try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, baseline_options);
    defer allocator.free(parser_c_baseline);
    const parser_c_emitted = try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, options);
    defer allocator.free(parser_c_emitted);

    return .{
        .parser_tables_baseline_bytes = parser_tables_baseline.len,
        .parser_tables_emitted_bytes = parser_tables_emitted.len,
        .parser_c_baseline_bytes = parser_c_baseline.len,
        .parser_c_emitted_bytes = parser_c_emitted.len,
    };
}

fn writeRowSharingStats(writer: anytype, stats: parser_c_emit.RowSharingStats) !void {
    try writer.writeAll("{ ");
    try writer.print("\"total_rows\": {d}, ", .{stats.total_rows});
    try writer.print("\"empty_rows\": {d}, ", .{stats.empty_rows});
    try writer.print("\"unique_non_empty_rows\": {d}, ", .{stats.unique_non_empty_rows});
    try writer.print("\"shared_non_empty_rows\": {d}, ", .{stats.shared_non_empty_rows});
    try writer.print("\"emitted_array_definitions\": {d}", .{stats.emitted_array_definitions});
    try writer.writeAll(" }");
}

test "runGenerate rejects empty grammar path" {
    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = "",
    }));
}

test "runGenerate succeeds for a valid grammar.json file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
    });
}

test "runGenerate rejects unsupported ABI versions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
        .abi_version = parser_compat.language_version + 1,
    }));
}

test "generateJsonSummaryAlloc reports parser row-sharing stats" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var summary_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer summary_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const summary = try generateJsonSummaryAlloc(summary_arena.allocator(), raw, prepared, .{}, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"blocked\": true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"serialized_state_count\": 7"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_state_count\": 7"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"state_count\": 7"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"merged_state_count\": 0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"optimization\": { \"compact_duplicate_states\": true, \"minimize_states\": false }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"parse_table_minimization\": { \"default_state_count\": 7, \"minimized_state_count\": 7, \"merged_state_count\": 0 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"expected_conflicts\": { \"declared_count\": 0, \"unused_count\": 0, \"unused_indexes\": [] }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"savings\": { \"state_count_delta\": 0, \"action_array_definitions_saved\": 0, \"goto_array_definitions_saved\": 0, \"unresolved_array_definitions_saved\": 0, \"total_array_definitions_saved\": 0 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_bytes\": { "));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"action_entry_count\": 11"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"unresolved_entry_count\": 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"baseline_action_rows\": { \"total_rows\": 7, \"empty_rows\": 0, \"unique_non_empty_rows\": 6, \"shared_non_empty_rows\": 1, \"emitted_array_definitions\": 6 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_action_rows\": { \"total_rows\": 7, \"empty_rows\": 0, \"unique_non_empty_rows\": 6, \"shared_non_empty_rows\": 1, \"emitted_array_definitions\": 6 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"baseline_goto_rows\": { \"total_rows\": 7, \"empty_rows\": 5, \"unique_non_empty_rows\": 2, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 3 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_goto_rows\": { \"total_rows\": 7, \"empty_rows\": 5, \"unique_non_empty_rows\": 2, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 3 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"baseline_unresolved_rows\": { \"total_rows\": 7, \"empty_rows\": 6, \"unique_non_empty_rows\": 1, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 1 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_unresolved_rows\": { \"total_rows\": 7, \"empty_rows\": 6, \"unique_non_empty_rows\": 1, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 1 }"));
}

test "generateJsonSummaryAlloc can disable duplicate-state compaction stats" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var summary_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer summary_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const summary = try generateJsonSummaryAlloc(summary_arena.allocator(), raw, prepared, .{}, .{
        .compact_duplicate_states = false,
    });

    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"serialized_state_count\": 6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_state_count\": 6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"state_count\": 6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"merged_state_count\": 0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"optimization\": { \"compact_duplicate_states\": false, \"minimize_states\": false }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"parse_table_minimization\": { \"default_state_count\": 6, \"minimized_state_count\": 6, \"merged_state_count\": 0 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"savings\": { \"state_count_delta\": 0, \"action_array_definitions_saved\": 0, \"goto_array_definitions_saved\": 0, \"unresolved_array_definitions_saved\": 0, \"total_array_definitions_saved\": 0 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"parser_tables_baseline\": "));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"parser_c_emitted\": "));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"baseline_action_rows\": { \"total_rows\": 6, \"empty_rows\": 0, \"unique_non_empty_rows\": 6, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 6 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_action_rows\": { \"total_rows\": 6, \"empty_rows\": 0, \"unique_non_empty_rows\": 6, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 6 }"));
}

test "generateJsonSummaryAlloc reports minimized parse-table option" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var summary_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer summary_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const summary = try generateJsonSummaryAlloc(
        summary_arena.allocator(),
        raw,
        prepared,
        .{ .minimize_states = true },
        .{},
    );

    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"optimization\": { \"compact_duplicate_states\": true, \"minimize_states\": true }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"parse_table_minimization\": { \"default_state_count\": 0, \"minimized_state_count\": 6, \"merged_state_count\": 0, \"computed\": false }"));
}

test "generateJsonSummaryAlloc reports serialized versus emitted state counts when compaction keeps states" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var summary_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer summary_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const summary = try generateJsonSummaryAlloc(summary_arena.allocator(), raw, prepared, .{}, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"serialized_state_count\": 6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_state_count\": 6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"merged_state_count\": 0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"optimization\": { \"compact_duplicate_states\": true, \"minimize_states\": false }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"savings\": { \"state_count_delta\": 0, \"action_array_definitions_saved\": 0, \"goto_array_definitions_saved\": 0, \"unresolved_array_definitions_saved\": 0, \"total_array_definitions_saved\": 0 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_bytes\": { "));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"baseline_action_rows\": { \"total_rows\": 6, \"empty_rows\": 0, \"unique_non_empty_rows\": 6, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 6 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_action_rows\": { \"total_rows\": 6, \"empty_rows\": 0, \"unique_non_empty_rows\": 6, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 6 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"baseline_goto_rows\": { \"total_rows\": 6, \"empty_rows\": 5, \"unique_non_empty_rows\": 1, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 2 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"emitted_goto_rows\": { \"total_rows\": 6, \"empty_rows\": 5, \"unique_non_empty_rows\": 1, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 2 }"));
}

test "generateJsonSummaryAlloc reports unused expected conflict indexes" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var summary_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer summary_arena.deinit();

    const contents =
        \\{
        \\  "name": "unused_expected_conflict_summary",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), contents, .{});
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const summary = try generateJsonSummaryAlloc(summary_arena.allocator(), raw, prepared, .{}, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"blocked\": false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"expected_conflicts\": { \"declared_count\": 1, \"unused_count\": 1, \"unused_indexes\": [0] }"));
}

test "writeExpectedConflictWarning renders unused conflict declaration" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    const contents =
        \\{
        \\  "name": "unused_expected_conflict_warning",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), contents, .{});
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeExpectedConflictWarning(&out.writer, prepared, 0);

    try std.testing.expectEqualStrings(
        "warning: expected_conflicts[0] declared but no conflict found: [\"source_file\", \"expr\"]\n",
        out.written(),
    );
}

test "collectEmittedSizeStats reports generated byte counts" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var stats_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer stats_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const serialized = try parse_table_pipeline.serializeTableFromPrepared(stats_arena.allocator(), prepared, .diagnostic);
    const size_stats = try collectEmittedSizeStats(stats_arena.allocator(), serialized, .{});

    try std.testing.expect(size_stats.parser_tables_baseline_bytes > 0);
    try std.testing.expect(size_stats.parser_tables_emitted_bytes > 0);
    try std.testing.expect(size_stats.parser_c_baseline_bytes > 0);
    try std.testing.expect(size_stats.parser_c_emitted_bytes > 0);
}

test "runGenerate supports debug prepared output mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
        .debug_prepared = true,
    });
}

test "runGenerate supports debug node types output mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
        .debug_node_types = true,
    });
}

test "runGenerate supports parser state reports for a rule" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
        .report_states_for_rule = "expr",
    });
}

test "runGenerate rejects parser state reports for unknown rules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
        .report_states_for_rule = "missing_rule",
    }));
}

test "runGenerate json summary supports strict expected conflicts flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents =
        \\{
        \\  "name": "strict_expected_conflict_cli",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.UnusedExpectedConflict, runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
        .json_summary = true,
        .strict_expected_conflicts = true,
    }));
}

test "runGenerate json summary permits unused expected conflicts without strict flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents =
        \\{
        \\  "name": "non_strict_expected_conflict_cli",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
        .json_summary = true,
        .strict_expected_conflicts = false,
    });
}

test "runGenerate writes node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });
    try tmp.dir.createDirPath(std.testing.io, "out");

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "out", std.testing.allocator);
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, node_types_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.validResolvedNodeTypesJson().contents, written);
}

test "runGenerate writes parser.c when requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });
    try tmp.dir.createDirPath(std.testing.io, "out");

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "out", std.testing.allocator);
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
        .emit_parser_c = true,
    });

    const parser_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "parser.c" });
    defer std.testing.allocator.free(parser_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, parser_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);

    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "static const TSLanguage ts_language = {\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "const TSLanguage *tree_sitter_basic(void) {\n"));
}

test "runtimeLimitErrorNote explains parser C capacity errors" {
    try std.testing.expectEqualStrings(
        "parse state count does not fit the current uint16_t runtime table format",
        runtimeLimitErrorNote(error.RuntimeStateCountTooLarge),
    );
    try std.testing.expectEqualStrings(
        "parse action list does not fit the current uint16_t runtime table format",
        runtimeLimitErrorNote(error.RuntimeParseActionListTooLarge),
    );
}

test "runGenerate writes experimental GLR parser.c when requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });
    try tmp.dir.createDirPath(std.testing.io, "out");

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "out", std.testing.allocator);
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
        .emit_parser_c = true,
        .glr_loop = true,
    });

    const parser_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "parser.c" });
    defer std.testing.allocator.free(parser_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, parser_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);

    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "#define GEN_Z_SITTER_ENABLE_GLR_LOOP 1\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "bool ts_generated_parse("));
}

test "runGenerate writes field and children node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.fieldChildrenGrammarJson().contents,
    });
    try tmp.dir.createDirPath(std.testing.io, "out");

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "out", std.testing.allocator);
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, node_types_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.fieldChildrenNodeTypesJson().contents, written);
}

test "runGenerate writes hidden wrapper node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.hiddenWrapperGrammarJson().contents,
    });
    try tmp.dir.createDirPath(std.testing.io, "out");

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "out", std.testing.allocator);
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, node_types_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.hiddenWrapperNodeTypesJson().contents, written);
}

test "runGenerate writes extra aliased body node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.extraAliasedBodyGrammarJson().contents,
    });
    try tmp.dir.createDirPath(std.testing.io, "out");

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "out", std.testing.allocator);
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, node_types_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.extraAliasedBodyNodeTypesJson().contents, written);
}

test "runGenerate writes external collision node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.externalCollisionGrammarJson().contents,
    });
    try tmp.dir.createDirPath(std.testing.io, "out");

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "out", std.testing.allocator);
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, node_types_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.externalCollisionNodeTypesJson().contents, written);
}

test "runGenerate succeeds for a valid grammar.js file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data = fixtures.validBlankGrammarJs().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
        .js_runtime = "node",
    });
}

test "runGenerate writes node-types.json from grammar.js when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data = fixtures.validResolvedGrammarJs().contents,
    });
    try tmp.dir.createDirPath(std.testing.io, "out");

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "out", std.testing.allocator);
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, node_types_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.validResolvedNodeTypesJson().contents, written);
}

test "runGenerate maps unsupported extension to InvalidArguments" {
    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = "grammar.txt",
    }));
}

test "runGenerate maps semantic parse errors to InvalidArguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.undefinedSymbolGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, std.testing.io, .{
        .grammar_path = path,
    }));
}

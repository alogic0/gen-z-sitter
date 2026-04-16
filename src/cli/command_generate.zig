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
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const fixtures = @import("../tests/fixtures.zig");

pub fn runGenerate(allocator: std.mem.Allocator, opts: args.GenerateOptions) !void {
    if (opts.grammar_path.len == 0) {
        return error.InvalidArguments;
    }

    var loaded = grammar_loader.loadGrammarFile(allocator, opts.grammar_path) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                try diag.printStderr(.{
                    .kind = .internal,
                    .message = grammar_loader.errorMessage(err),
                    .path = opts.grammar_path,
                });
                return err;
            },
            else => {
                try diag.printStderr(.{
                    .kind = if (err == error.IoFailure or err == error.ProcessFailure) .io else .usage,
                    .message = grammar_loader.errorMessage(err),
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
        try diag.printStderr(.{
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
            try std.fs.File.stdout().writeAll(dump);
        }
        return;
    }

    if (opts.debug_node_types) {
        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const json = node_type_pipeline.generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared) catch |err| switch (err) {
            error.InvalidSupertype => {
                try diag.printStderr(.{
                    .kind = .usage,
                    .message = "invalid supertype for node-types computation",
                    .path = opts.grammar_path,
                });
                return error.InvalidArguments;
            },
            else => return err,
        };

        if (!builtin.is_test) {
            try std.fs.File.stdout().writeAll(json);
        }
        return;
    }

    if (opts.output_dir) |output_dir| {
        try fs_support.ensureDir(output_dir);

        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const json = node_type_pipeline.generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared) catch |err| switch (err) {
            error.InvalidSupertype => {
                try diag.printStderr(.{
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

        if (!opts.json_summary) {
            try diag.printStdout(.{
                .kind = .info,
                .message = "wrote node-types.json",
                .path = output_path,
            });
        }
    }

    if (opts.json_summary) {
        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const summary = try generateJsonSummaryAlloc(
            pipeline_arena.allocator(),
            loaded.json.grammar,
            prepared,
        );
        if (!builtin.is_test) {
            try std.fs.File.stdout().writeAll(summary);
        }
        return;
    }

    try diag.printStdout(.{
        .kind = .info,
        .message = "loaded grammar successfully",
        .path = opts.grammar_path,
    });
    try diag.printStdout(.{
        .kind = .info,
        .message = "grammar",
        .note = loaded.json.grammar.name,
    });

    var counts_buffer: [64]u8 = undefined;
    const rule_count = try std.fmt.bufPrint(&counts_buffer, "rules: {}", .{loaded.json.grammar.ruleCount()});
    try diag.printStdout(.{
        .kind = .info,
        .message = rule_count,
    });

    const external_count = try std.fmt.bufPrint(&counts_buffer, "externals: {}", .{loaded.json.grammar.externals.len});
    try diag.printStdout(.{
        .kind = .info,
        .message = external_count,
    });

    const extras_count = try std.fmt.bufPrint(&counts_buffer, "extras: {}", .{loaded.json.grammar.extras.len});
    try diag.printStdout(.{
        .kind = .info,
        .message = extras_count,
    });

    const symbol_count = try std.fmt.bufPrint(&counts_buffer, "symbols: {}", .{prepared.symbols.len});
    try diag.printStdout(.{
        .kind = .info,
        .message = symbol_count,
    });
}

fn generateJsonSummaryAlloc(
    allocator: std.mem.Allocator,
    grammar: anytype,
    prepared: grammar_ir.PreparedGrammar,
) ![]const u8 {
    const serialized = try parse_table_pipeline.serializeTableFromPrepared(allocator, prepared, .diagnostic);
    const parser_stats = try parser_c_emit.collectEmissionStats(allocator, serialized);

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{\n");
    try writer.print("  \"blocked\": {s},\n", .{if (parser_stats.blocked) "true" else "false"});
    try writer.print("  \"rule_count\": {d},\n", .{grammar.ruleCount()});
    try writer.print("  \"external_count\": {d},\n", .{grammar.externals.len});
    try writer.print("  \"extra_count\": {d},\n", .{grammar.extras.len});
    try writer.print("  \"symbol_count\": {d},\n", .{prepared.symbols.len});
    try writer.print("  \"state_count\": {d},\n", .{parser_stats.state_count});
    try writer.print("  \"merged_state_count\": {d},\n", .{parser_stats.merged_state_count});
    try writer.print("  \"action_entry_count\": {d},\n", .{parser_stats.action_entry_count});
    try writer.print("  \"goto_entry_count\": {d},\n", .{parser_stats.goto_entry_count});
    try writer.print("  \"unresolved_entry_count\": {d},\n", .{parser_stats.unresolved_entry_count});
    try writer.writeAll("  \"action_rows\": ");
    try writeRowSharingStats(writer, parser_stats.action_rows);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"goto_rows\": ");
    try writeRowSharingStats(writer, parser_stats.goto_rows);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"unresolved_rows\": ");
    try writeRowSharingStats(writer, parser_stats.unresolved_rows);
    try writer.writeAll("\n}\n");

    return try out.toOwnedSlice();
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
    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, .{
        .grammar_path = "",
    }));
}

test "runGenerate succeeds for a valid grammar.json file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = path,
    });
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
    const summary = try generateJsonSummaryAlloc(summary_arena.allocator(), raw, prepared);

    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"blocked\": true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"state_count\": 6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"merged_state_count\": 0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"action_entry_count\": 4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"unresolved_entry_count\": 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"action_rows\": { \"total_rows\": 6, \"empty_rows\": 2, \"unique_non_empty_rows\": 3, \"shared_non_empty_rows\": 1, \"emitted_array_definitions\": 4 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"goto_rows\": { \"total_rows\": 6, \"empty_rows\": 4, \"unique_non_empty_rows\": 2, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 3 }"));
    try std.testing.expect(std.mem.containsAtLeast(u8, summary, 1, "\"unresolved_rows\": { \"total_rows\": 6, \"empty_rows\": 5, \"unique_non_empty_rows\": 1, \"shared_non_empty_rows\": 0, \"emitted_array_definitions\": 1 }"));
}

test "runGenerate supports debug prepared output mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = path,
        .debug_prepared = true,
    });
}

test "runGenerate supports debug node types output mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = path,
        .debug_node_types = true,
    });
}

test "runGenerate writes node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.validResolvedNodeTypesJson().contents, written);
}

test "runGenerate writes field and children node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.fieldChildrenGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.fieldChildrenNodeTypesJson().contents, written);
}

test "runGenerate writes hidden wrapper node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.hiddenWrapperGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.hiddenWrapperNodeTypesJson().contents, written);
}

test "runGenerate writes extra aliased body node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.extraAliasedBodyGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.extraAliasedBodyNodeTypesJson().contents, written);
}

test "runGenerate writes external collision node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.externalCollisionGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.externalCollisionNodeTypesJson().contents, written);
}

test "runGenerate succeeds for a valid grammar.js file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data = fixtures.validBlankGrammarJs().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = path,
    });
}

test "runGenerate writes node-types.json from grammar.js when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data = fixtures.validResolvedGrammarJs().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.validResolvedNodeTypesJson().contents, written);
}

test "runGenerate maps unsupported extension to InvalidArguments" {
    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, .{
        .grammar_path = "grammar.txt",
    }));
}

test "runGenerate maps semantic parse errors to InvalidArguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.undefinedSymbolGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, .{
        .grammar_path = path,
    }));
}

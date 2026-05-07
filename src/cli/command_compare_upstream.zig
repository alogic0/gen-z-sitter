const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const node_types_diff = @import("../compat/node_types_diff.zig");
const upstream_summary = @import("../compat/upstream_summary.zig");
const diag = @import("../support/diag.zig");
const fs_support = @import("../support/fs.zig");
const process_support = @import("../support/process.zig");
const runtime_io = @import("../support/runtime_io.zig");
const fixtures = @import("../tests/fixtures.zig");

pub fn runCompareUpstream(allocator: std.mem.Allocator, io: std.Io, opts: args.CompareUpstreamOptions) !void {
    if (opts.grammar_path.len == 0) return error.InvalidArguments;

    const local = try upstream_summary.generateLocalSummaryAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer upstream_summary.deinitSummary(allocator, local);
    const local_prepared = try upstream_summary.generateLocalPreparedIrSummaryAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });

    const output_root = opts.output_dir orelse ".zig-cache/upstream-compare";
    const snapshot = try runUpstreamSnapshotAlloc(allocator, opts, output_root, local.grammar_name);
    defer snapshot.deinit(allocator);
    var local_artifacts: LocalArtifacts = .{};
    defer local_artifacts.deinit(allocator);
    const diffs = if (snapshot.summary) |summary|
        try upstream_summary.compareSummariesAlloc(allocator, local, summary)
    else
        &.{};
    defer if (snapshot.summary != null) upstream_summary.deinitDiffs(allocator, diffs);

    const corpus = if (opts.structural_only)
        try skippedCorpusComparisonAlloc(allocator, "structural_only", "skipped by --structural-only")
    else
        try runCorpusComparisonAlloc(allocator, opts, output_root, local.grammar_name, snapshot, &local_artifacts);
    defer corpus.deinit(allocator);
    const node_types = if (opts.structural_only)
        null
    else
        try compareNodeTypesArtifactsAlloc(allocator, local_artifacts, snapshot);
    defer if (node_types) |diff| diff.deinit(allocator);

    const report = try renderReportAlloc(allocator, local, local_prepared, local_artifacts, snapshot, diffs, corpus, node_types);
    defer allocator.free(report);

    if (opts.output_dir) |output_dir| {
        try fs_support.ensureDir(output_dir);
        const output_path = try std.fs.path.join(allocator, &.{ output_dir, "local-upstream-summary.json" });
        defer allocator.free(output_path);
        try fs_support.writeFile(output_path, report);
        if (!builtin.is_test) {
            try diag.printStdout(io, .{
                .kind = .info,
                .message = "wrote upstream comparison summary",
                .path = output_path,
            });
        }
        return;
    }

    if (!builtin.is_test) {
        try std.Io.File.stdout().writeStreamingAll(io, report);
    }
}

const ReferenceStatus = struct {
    tree_sitter_dir: []const u8,
    available: bool,
    snapshot_status: []const u8,
    note: []const u8,
    output_dir: ?[]const u8 = null,
    parser_c_path: ?[]const u8 = null,
    node_types_path: ?[]const u8 = null,
    action_list_summary_path: ?[]const u8 = null,
    summary: ?upstream_summary.Summary = null,

    fn deinit(self: ReferenceStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.tree_sitter_dir);
        allocator.free(self.snapshot_status);
        allocator.free(self.note);
        if (self.output_dir) |value| allocator.free(value);
        if (self.parser_c_path) |value| allocator.free(value);
        if (self.node_types_path) |value| allocator.free(value);
        if (self.action_list_summary_path) |value| allocator.free(value);
        if (self.summary) |summary| upstream_summary.deinitSummary(allocator, summary);
    }
};

const ParserRunResult = struct {
    has_error: bool,
    consumed_bytes: usize,
    tree: []const u8,

    fn deinit(self: ParserRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tree);
    }
};

const CorpusSampleResult = struct {
    name: []const u8,
    input: []const u8,
    local: ?ParserRunResult,
    upstream: ?ParserRunResult,
    matches: bool,

    fn deinit(self: CorpusSampleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.input);
        if (self.local) |result| result.deinit(allocator);
        if (self.upstream) |result| result.deinit(allocator);
    }
};

const CorpusComparison = struct {
    status: []const u8,
    note: []const u8,
    samples: []const CorpusSampleResult = &.{},

    fn deinit(self: CorpusComparison, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        allocator.free(self.note);
        for (self.samples) |sample| sample.deinit(allocator);
        allocator.free(self.samples);
    }
};

const RuntimeCorpusConfig = struct {
    config_path: []const u8,
    external_scanner_source: ?[]const u8 = null,
    external_scanner_include_dir: ?[]const u8 = null,
    sample_files: []const []const u8 = &.{},

    fn deinit(self: RuntimeCorpusConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        if (self.external_scanner_source) |value| allocator.free(value);
        if (self.external_scanner_include_dir) |value| allocator.free(value);
        for (self.sample_files) |sample| allocator.free(sample);
        allocator.free(self.sample_files);
    }
};

const LocalArtifacts = struct {
    output_dir: ?[]const u8 = null,
    raw_grammar_path: ?[]const u8 = null,
    parse_states_path: ?[]const u8 = null,
    parse_states_summary_path: ?[]const u8 = null,
    item_set_snapshot_path: ?[]const u8 = null,
    conflict_summary_path: ?[]const u8 = null,
    token_conflicts_path: ?[]const u8 = null,
    minimization_summary_path: ?[]const u8 = null,
    action_list_summary_path: ?[]const u8 = null,
    production_info_summary_path: ?[]const u8 = null,
    regex_surface_path: ?[]const u8 = null,
    lex_table_summary_path: ?[]const u8 = null,
    parser_c_path: ?[]const u8 = null,
    node_types_path: ?[]const u8 = null,
    prepared_ir_path: ?[]const u8 = null,

    fn deinit(self: LocalArtifacts, allocator: std.mem.Allocator) void {
        if (self.output_dir) |value| allocator.free(value);
        if (self.raw_grammar_path) |value| allocator.free(value);
        if (self.parse_states_path) |value| allocator.free(value);
        if (self.parse_states_summary_path) |value| allocator.free(value);
        if (self.item_set_snapshot_path) |value| allocator.free(value);
        if (self.conflict_summary_path) |value| allocator.free(value);
        if (self.token_conflicts_path) |value| allocator.free(value);
        if (self.minimization_summary_path) |value| allocator.free(value);
        if (self.action_list_summary_path) |value| allocator.free(value);
        if (self.production_info_summary_path) |value| allocator.free(value);
        if (self.regex_surface_path) |value| allocator.free(value);
        if (self.lex_table_summary_path) |value| allocator.free(value);
        if (self.parser_c_path) |value| allocator.free(value);
        if (self.node_types_path) |value| allocator.free(value);
        if (self.prepared_ir_path) |value| allocator.free(value);
    }
};

fn runUpstreamSnapshotAlloc(
    allocator: std.mem.Allocator,
    opts: args.CompareUpstreamOptions,
    output_root: []const u8,
    grammar_name: []const u8,
) !ReferenceStatus {
    const render_path = try std.fs.path.join(allocator, &.{ opts.tree_sitter_dir, "crates/generate/src/render.rs" });
    defer allocator.free(render_path);
    const runtime_path = try std.fs.path.join(allocator, &.{ opts.tree_sitter_dir, "lib/src/parser.c" });
    defer allocator.free(runtime_path);

    const has_render = pathExists(render_path);
    const has_runtime = pathExists(runtime_path);
    const available = has_render and has_runtime;
    if (!available) {
        return .{
            .tree_sitter_dir = try allocator.dupe(u8, opts.tree_sitter_dir),
            .available = false,
            .snapshot_status = try allocator.dupe(u8, "missing_checkout"),
            .note = try allocator.dupe(u8, "upstream checkout not found or incomplete; summary is local-only"),
        };
    }

    const snapshot_root = try std.fs.path.join(allocator, &.{ output_root, "upstream" });
    errdefer allocator.free(snapshot_root);
    std.Io.Dir.cwd().deleteTree(runtime_io.get(), snapshot_root) catch {};
    try fs_support.ensureDir(snapshot_root);

    var result = process_support.runCapture(allocator, &.{
        "tree-sitter",
        "generate",
        "--output",
        snapshot_root,
        opts.grammar_path,
    }) catch |err| {
        allocator.free(snapshot_root);
        return .{
            .tree_sitter_dir = try allocator.dupe(u8, opts.tree_sitter_dir),
            .available = true,
            .snapshot_status = try allocator.dupe(u8, "missing_tool"),
            .note = try std.fmt.allocPrint(allocator, "could not run tree-sitter generate: {s}", .{@errorName(err)}),
        };
    };
    defer result.deinit(allocator);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(snapshot_root);
                return .{
                    .tree_sitter_dir = try allocator.dupe(u8, opts.tree_sitter_dir),
                    .available = true,
                    .snapshot_status = try allocator.dupe(u8, "failed"),
                    .note = try std.fmt.allocPrint(allocator, "tree-sitter generate failed with exit code {d}: {s}", .{ code, result.stderr }),
                };
            }
        },
        else => {
            allocator.free(snapshot_root);
            return .{
                .tree_sitter_dir = try allocator.dupe(u8, opts.tree_sitter_dir),
                .available = true,
                .snapshot_status = try allocator.dupe(u8, "failed"),
                .note = try std.fmt.allocPrint(allocator, "tree-sitter generate terminated: {any}", .{result.term}),
            };
        },
    }

    const parser_c_path = try std.fs.path.join(allocator, &.{ snapshot_root, "parser.c" });
    errdefer allocator.free(parser_c_path);
    const node_types_path = try std.fs.path.join(allocator, &.{ snapshot_root, "node-types.json" });
    errdefer allocator.free(node_types_path);
    const action_list_summary_path = try std.fs.path.join(allocator, &.{ snapshot_root, "action-list-summary.json" });
    errdefer allocator.free(action_list_summary_path);
    const parser_c = try fs_support.readFileAlloc(allocator, parser_c_path, 64 * 1024 * 1024);
    defer allocator.free(parser_c);
    const node_types = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), node_types_path, allocator, .limited(64 * 1024 * 1024)) catch null;
    defer if (node_types) |contents| allocator.free(contents);
    const summary = try upstream_summary.parseUpstreamParserCSummaryAlloc(allocator, grammar_name, parser_c, node_types);
    const action_list_summary = try upstream_summary.generateParserCActionListSummaryJsonAlloc(allocator, parser_c);
    defer allocator.free(action_list_summary);
    try fs_support.writeFile(action_list_summary_path, action_list_summary);

    return .{
        .tree_sitter_dir = try allocator.dupe(u8, opts.tree_sitter_dir),
        .available = true,
        .snapshot_status = try allocator.dupe(u8, "generated"),
        .note = try allocator.dupe(u8, "upstream parser.c and node-types.json generated into the comparison output directory"),
        .output_dir = snapshot_root,
        .parser_c_path = parser_c_path,
        .node_types_path = node_types_path,
        .action_list_summary_path = action_list_summary_path,
        .summary = summary,
    };
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime_io.get(), path, .{}) catch return false;
    return true;
}

fn compareNodeTypesArtifactsAlloc(
    allocator: std.mem.Allocator,
    local_artifacts: LocalArtifacts,
    snapshot: ReferenceStatus,
) !?node_types_diff.NodeTypesDiff {
    const local_path = local_artifacts.node_types_path orelse return null;
    const upstream_path = snapshot.node_types_path orelse return null;
    const local_json = try fs_support.readFileAlloc(allocator, local_path, 64 * 1024 * 1024);
    defer allocator.free(local_json);
    const upstream_json = try fs_support.readFileAlloc(allocator, upstream_path, 64 * 1024 * 1024);
    defer allocator.free(upstream_json);
    return try node_types_diff.compareNodeTypesJsonAlloc(allocator, local_json, upstream_json);
}

fn runCorpusComparisonAlloc(
    allocator: std.mem.Allocator,
    opts: args.CompareUpstreamOptions,
    output_root: []const u8,
    grammar_name: []const u8,
    snapshot: ReferenceStatus,
    local_artifacts: *LocalArtifacts,
) !CorpusComparison {
    try writeLocalArtifactsAlloc(allocator, opts, output_root, local_artifacts);

    if (snapshot.parser_c_path == null) {
        return .{
            .status = try allocator.dupe(u8, "skipped"),
            .note = try allocator.dupe(u8, "upstream parser.c was not generated"),
        };
    }
    if (!pathExists("../tree-sitter/lib/src/lib.c") or !pathExists("../tree-sitter/lib/include/tree_sitter/api.h")) {
        return .{
            .status = try allocator.dupe(u8, "skipped"),
            .note = try allocator.dupe(u8, "reference tree-sitter runtime files are missing"),
        };
    }

    const local_parser_path = local_artifacts.parser_c_path.?;

    const driver_path = try std.fs.path.join(allocator, &.{ output_root, "corpus_driver.c" });
    defer allocator.free(driver_path);
    const driver_source = try corpusDriverSourceAlloc(allocator, grammar_name);
    defer allocator.free(driver_source);
    try fs_support.writeFile(driver_path, driver_source);

    const local_exe = try std.fs.path.join(allocator, &.{ output_root, "local-parser-runner" });
    defer allocator.free(local_exe);
    const upstream_exe = try std.fs.path.join(allocator, &.{ output_root, "upstream-parser-runner" });
    defer allocator.free(upstream_exe);
    const runtime_config = try loadRuntimeCorpusConfigForGrammarAlloc(allocator, opts.grammar_path, grammar_name);
    defer if (runtime_config) |config| config.deinit(allocator);
    compileParserRunner(allocator, local_parser_path, output_root, driver_path, local_exe, runtime_config) catch |err| {
        return .{
            .status = try allocator.dupe(u8, "runner_compile_failed"),
            .note = try std.fmt.allocPrint(allocator, "local corpus runner failed to compile: {s}", .{@errorName(err)}),
        };
    };
    compileParserRunner(allocator, snapshot.parser_c_path.?, snapshot.output_dir.?, driver_path, upstream_exe, runtime_config) catch |err| {
        return .{
            .status = try allocator.dupe(u8, "runner_compile_failed"),
            .note = try std.fmt.allocPrint(allocator, "upstream corpus runner failed to compile: {s}", .{@errorName(err)}),
        };
    };

    const samples = try loadCorpusSamplesAlloc(allocator, opts.grammar_path, grammar_name, runtime_config);
    defer {
        for (samples) |sample| {
            allocator.free(sample.name);
            allocator.free(sample.input);
        }
        allocator.free(samples);
    }

    const results = try allocator.alloc(CorpusSampleResult, samples.len);
    var result_count: usize = 0;
    errdefer {
        for (results[0..result_count]) |result| result.deinit(allocator);
        allocator.free(results);
    }
    var all_match = true;
    var any_failed = false;
    for (samples, 0..) |sample, index| {
        const local_result = runParserRunnerAlloc(allocator, local_exe, sample.input) catch null;
        const upstream_result = runParserRunnerAlloc(allocator, upstream_exe, sample.input) catch null;
        any_failed = any_failed or local_result == null or upstream_result == null;
        const matches = if (local_result != null and upstream_result != null)
            local_result.?.has_error == upstream_result.?.has_error and
                local_result.?.consumed_bytes == upstream_result.?.consumed_bytes and
                std.mem.eql(u8, local_result.?.tree, upstream_result.?.tree)
        else
            false;
        all_match = all_match and matches;
        results[index] = .{
            .name = try allocator.dupe(u8, sample.name),
            .input = try allocator.dupe(u8, sample.input),
            .local = local_result,
            .upstream = upstream_result,
            .matches = matches,
        };
        result_count += 1;
    }

    return .{
        .status = try allocator.dupe(u8, if (all_match) "matched" else if (any_failed) "runner_failed" else "different"),
        .note = try allocator.dupe(u8, "compared local and upstream generated parsers on bounded samples"),
        .samples = results,
    };
}

fn skippedCorpusComparisonAlloc(
    allocator: std.mem.Allocator,
    status: []const u8,
    note: []const u8,
) !CorpusComparison {
    return .{
        .status = try allocator.dupe(u8, status),
        .note = try allocator.dupe(u8, note),
    };
}

fn writeLocalArtifactsAlloc(
    allocator: std.mem.Allocator,
    opts: args.CompareUpstreamOptions,
    output_root: []const u8,
    local_artifacts: *LocalArtifacts,
) !void {
    const local_dir = try std.fs.path.join(allocator, &.{ output_root, "local" });
    errdefer allocator.free(local_dir);
    std.Io.Dir.cwd().deleteTree(runtime_io.get(), local_dir) catch {};
    try fs_support.ensureDir(local_dir);
    const local_raw_grammar_path = try std.fs.path.join(allocator, &.{ local_dir, "raw-grammar.json" });
    errdefer allocator.free(local_raw_grammar_path);
    const local_parse_states_path = try std.fs.path.join(allocator, &.{ local_dir, "parse-states.txt" });
    errdefer allocator.free(local_parse_states_path);
    const local_parse_states_summary_path = try std.fs.path.join(allocator, &.{ local_dir, "parse-states-summary.json" });
    errdefer allocator.free(local_parse_states_summary_path);
    const local_item_set_snapshot_path = try std.fs.path.join(allocator, &.{ local_dir, "item-set-snapshot.json" });
    errdefer allocator.free(local_item_set_snapshot_path);
    const local_conflict_summary_path = try std.fs.path.join(allocator, &.{ local_dir, "conflict-summary.json" });
    errdefer allocator.free(local_conflict_summary_path);
    const local_token_conflicts_path = try std.fs.path.join(allocator, &.{ local_dir, "token-conflicts.json" });
    errdefer allocator.free(local_token_conflicts_path);
    const local_minimization_summary_path = try std.fs.path.join(allocator, &.{ local_dir, "minimization-summary.json" });
    errdefer allocator.free(local_minimization_summary_path);
    const local_action_list_summary_path = try std.fs.path.join(allocator, &.{ local_dir, "action-list-summary.json" });
    errdefer allocator.free(local_action_list_summary_path);
    const local_production_info_summary_path = try std.fs.path.join(allocator, &.{ local_dir, "production-info-summary.json" });
    errdefer allocator.free(local_production_info_summary_path);
    const local_regex_surface_path = try std.fs.path.join(allocator, &.{ local_dir, "regex-surface.json" });
    errdefer allocator.free(local_regex_surface_path);
    const local_lex_table_summary_path = try std.fs.path.join(allocator, &.{ local_dir, "lex-table-summary.json" });
    errdefer allocator.free(local_lex_table_summary_path);
    const local_parser_path = try std.fs.path.join(allocator, &.{ local_dir, "parser.c" });
    errdefer allocator.free(local_parser_path);
    const local_node_types_path = try std.fs.path.join(allocator, &.{ local_dir, "node-types.json" });
    errdefer allocator.free(local_node_types_path);
    const local_prepared_ir_path = try std.fs.path.join(allocator, &.{ local_dir, "prepared-ir.json" });
    errdefer allocator.free(local_prepared_ir_path);
    const local_parser_c = try upstream_summary.generateLocalParserCAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_parser_c);
    try fs_support.writeFile(local_parser_path, local_parser_c);
    const local_raw_grammar_json = try upstream_summary.generateLocalRawGrammarSnapshotJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_raw_grammar_json);
    try fs_support.writeFile(local_raw_grammar_path, local_raw_grammar_json);
    const local_parse_state_dump = try upstream_summary.generateLocalParseStateDumpAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .report_states_for_rule = opts.report_states_for_rule,
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_parse_state_dump);
    try fs_support.writeFile(local_parse_states_path, local_parse_state_dump);
    const local_parse_state_summary = try upstream_summary.generateLocalParseStateSummaryJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_parse_state_summary);
    try fs_support.writeFile(local_parse_states_summary_path, local_parse_state_summary);
    const local_item_set_snapshot = try upstream_summary.generateLocalItemSetSnapshotJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .report_states_for_rule = opts.report_states_for_rule,
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_item_set_snapshot);
    try fs_support.writeFile(local_item_set_snapshot_path, local_item_set_snapshot);
    const local_conflict_summary = try upstream_summary.generateLocalConflictSummaryJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_conflict_summary);
    try fs_support.writeFile(local_conflict_summary_path, local_conflict_summary);
    const local_token_conflicts = try upstream_summary.generateLocalTokenConflictSummaryJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_token_conflicts);
    try fs_support.writeFile(local_token_conflicts_path, local_token_conflicts);
    const local_minimization_summary = try upstream_summary.generateLocalMinimizationSummaryJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_minimization_summary);
    try fs_support.writeFile(local_minimization_summary_path, local_minimization_summary);
    const local_action_list_summary = try upstream_summary.generateLocalActionListSummaryJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_action_list_summary);
    try fs_support.writeFile(local_action_list_summary_path, local_action_list_summary);
    const local_production_info_summary = try upstream_summary.generateLocalProductionInfoSummaryJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_production_info_summary);
    try fs_support.writeFile(local_production_info_summary_path, local_production_info_summary);
    const local_regex_surface = try upstream_summary.generateLocalRegexSurfaceSummaryJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_regex_surface);
    try fs_support.writeFile(local_regex_surface_path, local_regex_surface);
    const local_lex_table_summary = try upstream_summary.generateLocalLexTableSummaryJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_lex_table_summary);
    try fs_support.writeFile(local_lex_table_summary_path, local_lex_table_summary);
    const local_node_types_json = try upstream_summary.generateLocalNodeTypesJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_node_types_json);
    try fs_support.writeFile(local_node_types_path, local_node_types_json);
    const local_prepared_ir_json = try upstream_summary.generateLocalPreparedIrSnapshotJsonAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer allocator.free(local_prepared_ir_json);
    try fs_support.writeFile(local_prepared_ir_path, local_prepared_ir_json);

    local_artifacts.output_dir = local_dir;
    local_artifacts.raw_grammar_path = local_raw_grammar_path;
    local_artifacts.parse_states_path = local_parse_states_path;
    local_artifacts.parse_states_summary_path = local_parse_states_summary_path;
    local_artifacts.item_set_snapshot_path = local_item_set_snapshot_path;
    local_artifacts.conflict_summary_path = local_conflict_summary_path;
    local_artifacts.token_conflicts_path = local_token_conflicts_path;
    local_artifacts.minimization_summary_path = local_minimization_summary_path;
    local_artifacts.action_list_summary_path = local_action_list_summary_path;
    local_artifacts.production_info_summary_path = local_production_info_summary_path;
    local_artifacts.regex_surface_path = local_regex_surface_path;
    local_artifacts.lex_table_summary_path = local_lex_table_summary_path;
    local_artifacts.parser_c_path = local_parser_path;
    local_artifacts.node_types_path = local_node_types_path;
    local_artifacts.prepared_ir_path = local_prepared_ir_path;
}

const CorpusSample = struct {
    name: []const u8,
    input: []const u8,
};

fn loadCorpusSamplesAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    grammar_name: []const u8,
    runtime_config: ?RuntimeCorpusConfig,
) ![]const CorpusSample {
    if (runtime_config) |config| {
        if (config.sample_files.len != 0) {
            const samples = try allocator.alloc(CorpusSample, config.sample_files.len);
            var initialized: usize = 0;
            errdefer {
                for (samples[0..initialized]) |sample| {
                    allocator.free(sample.name);
                    allocator.free(sample.input);
                }
                allocator.free(samples);
            }
            for (config.sample_files, 0..) |sample_path, index| {
                samples[index] = .{
                    .name = try allocator.dupe(u8, std.fs.path.basename(sample_path)),
                    .input = try fs_support.readFileAlloc(allocator, sample_path, 64 * 1024),
                };
                initialized += 1;
            }
            return samples;
        }
    }

    const grammar_dir = std.fs.path.dirname(grammar_path) orelse ".";
    const valid_path = try std.fs.path.join(allocator, &.{ grammar_dir, "valid.txt" });
    defer allocator.free(valid_path);
    const invalid_path = try std.fs.path.join(allocator, &.{ grammar_dir, "invalid.txt" });
    defer allocator.free(invalid_path);

    if (pathExists(valid_path) and pathExists(invalid_path)) {
        const samples = try allocator.alloc(CorpusSample, 2);
        samples[0] = .{
            .name = try allocator.dupe(u8, "valid.txt"),
            .input = try fs_support.readFileAlloc(allocator, valid_path, 64 * 1024),
        };
        samples[1] = .{
            .name = try allocator.dupe(u8, "invalid.txt"),
            .input = try fs_support.readFileAlloc(allocator, invalid_path, 64 * 1024),
        };
        return samples;
    }

    if (std.mem.eql(u8, grammar_name, "json")) {
        const samples = try allocator.alloc(CorpusSample, 2);
        samples[0] = .{ .name = try allocator.dupe(u8, "json.accepted.object"), .input = try allocator.dupe(u8, "{}") };
        samples[1] = .{ .name = try allocator.dupe(u8, "json.invalid.identifier"), .input = try allocator.dupe(u8, "x") };
        return samples;
    }

    const samples = try allocator.alloc(CorpusSample, 1);
    samples[0] = .{ .name = try allocator.dupe(u8, "empty"), .input = try allocator.dupe(u8, "") };
    return samples;
}

fn compileParserRunner(
    allocator: std.mem.Allocator,
    parser_path: []const u8,
    parser_include_dir: []const u8,
    driver_path: []const u8,
    exe_path: []const u8,
    runtime_config: ?RuntimeCorpusConfig,
) !void {
    const include_arg = try includeArgAlloc(allocator, parser_include_dir);
    defer allocator.free(include_arg);
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{
        "zig",
        "cc",
        parser_path,
        "../tree-sitter/lib/src/lib.c",
        driver_path,
    });
    if (runtime_config) |config| {
        if (config.external_scanner_source) |scanner_source| try argv.append(scanner_source);
    }
    try argv.appendSlice(&.{
        "-I../tree-sitter/lib/include",
        "-I../tree-sitter/lib/src",
        include_arg,
    });
    var scanner_include_arg: ?[]const u8 = null;
    defer if (scanner_include_arg) |value| allocator.free(value);
    if (runtime_config) |config| {
        if (config.external_scanner_include_dir) |include_dir| {
            scanner_include_arg = try includeArgAlloc(allocator, include_dir);
            try argv.append(scanner_include_arg.?);
        }
    }
    try argv.appendSlice(&.{ "-o", exe_path });

    var result = try process_support.runCapture(allocator, argv.items);
    defer result.deinit(allocator);
    if (result.term != .exited or result.term.exited != 0) return error.CompileCorpusRunnerFailed;
}

fn includeArgAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "-I{s}", .{path});
}

fn loadRuntimeCorpusConfigForGrammarAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    grammar_name: []const u8,
) !?RuntimeCorpusConfig {
    const grammar_dir = std.fs.path.dirname(grammar_path) orelse ".";
    const scanner_config_dir = try std.fmt.allocPrint(allocator, "{s}_scanner_json", .{grammar_dir});
    defer allocator.free(scanner_config_dir);
    if (try loadRuntimeCorpusConfigAtDirAlloc(allocator, scanner_config_dir)) |config| return config;

    const json_config_dir = try std.fmt.allocPrint(allocator, "{s}_json", .{grammar_dir});
    defer allocator.free(json_config_dir);
    if (try loadRuntimeCorpusConfigAtDirAlloc(allocator, json_config_dir)) |config| return config;

    const named_scanner_config_dir = try std.fmt.allocPrint(allocator, "compat_targets/tree_sitter_{s}_scanner_json", .{grammar_name});
    defer allocator.free(named_scanner_config_dir);
    if (try loadRuntimeCorpusConfigAtDirAlloc(allocator, named_scanner_config_dir)) |config| return config;

    return null;
}

fn loadRuntimeCorpusConfigAtDirAlloc(
    allocator: std.mem.Allocator,
    config_dir: []const u8,
) !?RuntimeCorpusConfig {
    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "runtime_proof_config.json" });
    errdefer allocator.free(config_path);
    const contents = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), config_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(config_path);
            return null;
        },
        else => return err,
    };
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidRuntimeProofConfig,
    };

    return .{
        .config_path = config_path,
        .external_scanner_source = try optionalJsonStringAlloc(allocator, root, "external_scanner_source"),
        .external_scanner_include_dir = try optionalJsonStringAlloc(allocator, root, "external_scanner_include_dir"),
        .sample_files = try optionalJsonStringArrayAlloc(allocator, root, "sample_files"),
    };
}

fn optionalJsonStringAlloc(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    field_name: []const u8,
) !?[]const u8 {
    const value = root.get(field_name) orelse return null;
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        .null => null,
        else => error.InvalidRuntimeProofConfig,
    };
}

fn optionalJsonStringArrayAlloc(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    field_name: []const u8,
) ![]const []const u8 {
    const value = root.get(field_name) orelse return &.{};
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidRuntimeProofConfig,
    };
    const result = try allocator.alloc([]const u8, array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| allocator.free(item);
        allocator.free(result);
    }
    for (array.items, 0..) |item, index| {
        const text = switch (item) {
            .string => |string_value| string_value,
            else => return error.InvalidRuntimeProofConfig,
        };
        result[index] = try allocator.dupe(u8, text);
        initialized += 1;
    }
    return result;
}

fn runParserRunnerAlloc(allocator: std.mem.Allocator, exe_path: []const u8, input: []const u8) !ParserRunResult {
    var result = try process_support.runCapture(allocator, &.{ "timeout", "5", exe_path, input });
    defer result.deinit(allocator);
    if (result.term != .exited or result.term.exited != 0) return error.CorpusRunnerFailed;
    return parseParserRunnerOutputAlloc(allocator, result.stdout);
}

fn parseParserRunnerOutputAlloc(allocator: std.mem.Allocator, output: []const u8) !ParserRunResult {
    const has_error_prefix = "has_error=";
    const consumed_prefix = "consumed_bytes=";
    const tree_prefix = "tree=";
    const has_error_start = std.mem.indexOf(u8, output, has_error_prefix) orelse return error.InvalidCorpusRunnerOutput;
    const has_error_value_start = has_error_start + has_error_prefix.len;
    const has_error_value_end = std.mem.indexOfScalarPos(u8, output, has_error_value_start, '\n') orelse return error.InvalidCorpusRunnerOutput;
    const consumed_start = std.mem.indexOf(u8, output, consumed_prefix) orelse return error.InvalidCorpusRunnerOutput;
    const consumed_value_start = consumed_start + consumed_prefix.len;
    const consumed_value_end = std.mem.indexOfScalarPos(u8, output, consumed_value_start, '\n') orelse return error.InvalidCorpusRunnerOutput;
    const tree_start = std.mem.indexOf(u8, output, tree_prefix) orelse return error.InvalidCorpusRunnerOutput;
    const tree_value_start = tree_start + tree_prefix.len;
    const tree_value_end = std.mem.indexOfScalarPos(u8, output, tree_value_start, '\n') orelse output.len;
    return .{
        .has_error = std.mem.eql(u8, output[has_error_value_start..has_error_value_end], "1"),
        .consumed_bytes = try std.fmt.parseUnsigned(usize, output[consumed_value_start..consumed_value_end], 10),
        .tree = try allocator.dupe(u8, output[tree_value_start..tree_value_end]),
    };
}

fn corpusDriverSourceAlloc(allocator: std.mem.Allocator, grammar_name: []const u8) ![]const u8 {
    const function_name = try treeSitterFunctionNameAlloc(allocator, grammar_name);
    defer allocator.free(function_name);
    return try std.fmt.allocPrint(
        allocator,
        \\#include <stdio.h>
        \\#include <stdlib.h>
        \\#include <string.h>
        \\#include <tree_sitter/api.h>
        \\const TSLanguage *{s}(void);
        \\int main(int argc, char **argv) {{
        \\  if (argc < 2) return 2;
        \\  const char *input = argv[1];
        \\  TSParser *parser = ts_parser_new();
        \\  if (!parser) return 3;
        \\  if (!ts_parser_set_language(parser, {s}())) return 4;
        \\  TSTree *tree = ts_parser_parse_string(parser, NULL, input, (uint32_t)strlen(input));
        \\  if (!tree) return 5;
        \\  TSNode root = ts_tree_root_node(tree);
        \\  char *tree_string = ts_node_string(root);
        \\  if (!tree_string) return 6;
        \\  printf("has_error=%d\n", ts_node_has_error(root));
        \\  printf("consumed_bytes=%u\n", (unsigned)strlen(input));
        \\  printf("tree=%s\n", tree_string);
        \\  free(tree_string);
        \\  ts_tree_delete(tree);
        \\  ts_parser_delete(parser);
        \\  return 0;
        \\}}
        \\
    ,
        .{ function_name, function_name },
    );
}

fn treeSitterFunctionNameAlloc(allocator: std.mem.Allocator, grammar_name: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("tree_sitter_");
    for (grammar_name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.writer.writeByte(ch);
        } else {
            try out.writer.writeByte('_');
        }
    }
    return try out.toOwnedSlice();
}

fn renderReportAlloc(
    allocator: std.mem.Allocator,
    local: upstream_summary.Summary,
    local_prepared: upstream_summary.PreparedIrSummary,
    local_artifacts: LocalArtifacts,
    reference: ReferenceStatus,
    diffs: []const upstream_summary.SummaryDiff,
    corpus: CorpusComparison,
    node_types: ?node_types_diff.NodeTypesDiff,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n");
    try writer.writeAll("  \"local\":\n");
    try upstream_summary.writeSummaryJson(writer, local, 2);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"local_prepared_ir\":\n");
    try upstream_summary.writePreparedIrSummaryJson(writer, local_prepared, 2);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"prepared_ir_comparison\":\n");
    try upstream_summary.writePreparedIrComparisonKeysJson(writer, local_prepared, 2);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"local_artifacts\": {\n");
    try writer.writeAll("    \"output_dir\": ");
    try writeOptionalJsonString(writer, local_artifacts.output_dir);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"raw_grammar_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.raw_grammar_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"parse_states_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.parse_states_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"parse_states_summary_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.parse_states_summary_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"item_set_snapshot_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.item_set_snapshot_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"conflict_summary_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.conflict_summary_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"token_conflicts_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.token_conflicts_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"minimization_summary_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.minimization_summary_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"action_list_summary_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.action_list_summary_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"production_info_summary_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.production_info_summary_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"regex_surface_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.regex_surface_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"lex_table_summary_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.lex_table_summary_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"parser_c_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.parser_c_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"node_types_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.node_types_path);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"prepared_ir_path\": ");
    try writeOptionalJsonString(writer, local_artifacts.prepared_ir_path);
    try writer.writeAll("\n");
    try writer.writeAll("  },\n");
    try writer.writeAll("  \"upstream\": {\n");
    try writer.writeAll("    \"tree_sitter_dir\": ");
    try writeJsonString(writer, reference.tree_sitter_dir);
    try writer.writeAll(",\n");
    try writer.print("    \"available\": {s},\n", .{if (reference.available) "true" else "false"});
    try writer.writeAll("    \"snapshot_status\": ");
    try writeJsonString(writer, reference.snapshot_status);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"note\": ");
    try writeJsonString(writer, reference.note);
    if (reference.output_dir) |value| {
        try writer.writeAll(",\n");
        try writer.writeAll("    \"output_dir\": ");
        try writeJsonString(writer, value);
    }
    if (reference.parser_c_path) |value| {
        try writer.writeAll(",\n");
        try writer.writeAll("    \"parser_c_path\": ");
        try writeJsonString(writer, value);
    }
    if (reference.node_types_path) |value| {
        try writer.writeAll(",\n");
        try writer.writeAll("    \"node_types_path\": ");
        try writeJsonString(writer, value);
    }
    if (reference.action_list_summary_path) |value| {
        try writer.writeAll(",\n");
        try writer.writeAll("    \"action_list_summary_path\": ");
        try writeJsonString(writer, value);
    }
    if (reference.summary) |summary| {
        try writer.writeAll(",\n");
        try writer.writeAll("    \"summary\":\n");
        try upstream_summary.writeSummaryJson(writer, summary, 4);
    }
    try writer.writeAll("\n");
    try writer.writeAll("  },\n");
    try writer.writeAll("  \"diffs\": ");
    try upstream_summary.writeDiffsJson(writer, diffs, 0);
    try writer.writeAll(",\n");
    try writeCorpusComparisonJson(writer, corpus);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"node_types_diff\": ");
    if (node_types) |diff| {
        try node_types_diff.writeJson(writer, diff, 2);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('\n');
    try writer.writeAll("}\n");

    return try out.toOwnedSlice();
}

fn writeCorpusComparisonJson(writer: anytype, corpus: CorpusComparison) !void {
    try writer.writeAll("  \"corpus_samples\": {\n");
    try writer.writeAll("    \"status\": ");
    try writeJsonString(writer, corpus.status);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"note\": ");
    try writeJsonString(writer, corpus.note);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"samples\": [");
    if (corpus.samples.len != 0) try writer.writeByte('\n');
    for (corpus.samples, 0..) |sample, index| {
        try writer.writeAll("      {\n");
        try writer.writeAll("        \"name\": ");
        try writeJsonString(writer, sample.name);
        try writer.writeAll(",\n");
        try writer.print("        \"input_bytes\": {d},\n", .{sample.input.len});
        try writer.print("        \"matches\": {s},\n", .{if (sample.matches) "true" else "false"});
        try writer.writeAll("        \"local\": ");
        try writeParserRunJson(writer, sample.local);
        try writer.writeAll(",\n");
        try writer.writeAll("        \"upstream\": ");
        try writeParserRunJson(writer, sample.upstream);
        try writer.writeByte('\n');
        try writer.writeAll("      }");
        if (index + 1 != corpus.samples.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (corpus.samples.len != 0) try writer.writeAll("    ");
    try writer.writeAll("]\n");
    try writer.writeAll("  }");
}

fn writeParserRunJson(writer: anytype, maybe_result: ?ParserRunResult) !void {
    const result = maybe_result orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.writeAll("{ \"has_error\": ");
    try writer.writeAll(if (result.has_error) "true" else "false");
    try writer.print(", \"consumed_bytes\": {d}", .{result.consumed_bytes});
    try writer.writeAll(", \"tree\": ");
    try writeJsonString(writer, result.tree);
    try writer.writeAll(" }");
}

fn writeOptionalJsonString(writer: anytype, maybe_value: ?[]const u8) !void {
    if (maybe_value) |value| {
        try writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
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

test "runCompareUpstream writes local summary report" {
    var grammar_tmp = std.testing.tmpDir(.{});
    defer grammar_tmp.cleanup();

    try grammar_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });
    const grammar_path = try grammar_tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);

    var output_tmp = std.testing.tmpDir(.{});
    defer output_tmp.cleanup();
    const output_path = try output_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(output_path);

    try runCompareUpstream(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_path,
        .tree_sitter_dir = "/definitely/missing/tree-sitter",
    });

    const report = try output_tmp.dir.readFileAlloc(std.testing.io, "local-upstream-summary.json", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"local_prepared_ir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"prepared_ir_comparison\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"upstream_oracle_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"raw_grammar_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"parse_states_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"parse_states_summary_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"item_set_snapshot_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "local/item-set-snapshot.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"conflict_summary_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "local/conflict-summary.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"token_conflicts_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "local/token-conflicts.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"minimization_summary_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "local/minimization-summary.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"production_info_summary_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "local/production-info-summary.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"regex_surface_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "local/regex-surface.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"lex_table_summary_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "local/lex-table-summary.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"prepared_ir_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"upstream\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"available\": false") != null);
}

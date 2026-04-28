const std = @import("std");
const runtime_io = @import("../support/runtime_io.zig");
const targets = @import("targets.zig");
const result_model = @import("result.zig");
const compile_smoke = @import("compile_smoke.zig");
const report_json = @import("report_json.zig");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const flatten_grammar = @import("../grammar/prepare/flatten_grammar.zig");
const parse_table_build = @import("../parse_table/build.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const parser_tables_emit = @import("../parser_emit/parser_tables.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const compat_checks = @import("../parser_emit/compat_checks.zig");
const emit_optimize = @import("../parser_emit/optimize.zig");
const scanner_serialize = @import("../scanner/serialize.zig");
const behavioral_harness = @import("../behavioral/harness.zig");
const runtime_link = @import("runtime_link.zig");

pub const RunOptions = struct {
    optimize: emit_optimize.Options = .{},
    progress_log: bool = false,
    profile_timings: bool = false,
    stop_after_stage: ?result_model.StepName = null,
};

var cached_shortlist_runs_for_tests: ?[]result_model.TargetRunResult = null;

pub fn runShortlistTargetsAlloc(
    allocator: std.mem.Allocator,
    options: RunOptions,
) ![]result_model.TargetRunResult {
    const shortlist = targets.shortlistTargets();
    std.debug.print("[compat/harness] runShortlistTargetsAlloc shortlist_len={d}\n", .{shortlist.len});
    const excluded_targets = loadExcludedTargetsEnv(allocator) catch null;
    defer if (excluded_targets) |items| {
        for (items) |entry| allocator.free(entry);
        allocator.free(items);
    };

    if (excluded_targets == null or excluded_targets.?.len == 0) {
        std.debug.print("[compat/harness] runShortlistTargetsAlloc no exclusions\n", .{});
        return try runTargetsAlloc(allocator, shortlist, options);
    }

    const filtered = try filterTargetsAlloc(allocator, shortlist, excluded_targets.?);
    defer allocator.free(filtered);
    return try runTargetsAlloc(allocator, filtered, options);
}

pub fn cachedShortlistTargetsForTests() ![]const result_model.TargetRunResult {
    std.debug.print("[compat/harness] cachedShortlistTargetsForTests enter\n", .{});

    if (cached_shortlist_runs_for_tests) |runs| {
        std.debug.print("[compat/harness] cachedShortlistTargetsForTests cache_hit len={d}\n", .{runs.len});
        return runs;
    }

    std.debug.print("[compat/harness] cachedShortlistTargetsForTests cache_miss starting shortlist run\n", .{});
    const runs = try runShortlistTargetsAlloc(std.heap.page_allocator, .{});
    std.debug.print("[compat/harness] cachedShortlistTargetsForTests shortlist run complete len={d}\n", .{runs.len});
    cached_shortlist_runs_for_tests = runs;
    return runs;
}

pub fn runStagedTargetsAlloc(
    allocator: std.mem.Allocator,
    options: RunOptions,
) ![]result_model.TargetRunResult {
    return try runTargetsAlloc(allocator, targets.firstWaveTargets(), options);
}

pub fn runTargetsAlloc(
    allocator: std.mem.Allocator,
    target_list: []const targets.Target,
    options: RunOptions,
) ![]result_model.TargetRunResult {
    const progress_log = shouldLogProgress(options);
    const runs = try allocator.alloc(result_model.TargetRunResult, target_list.len);
    errdefer allocator.free(runs);

    for (target_list, 0..) |target, index| {
        const target_start_ts = std.Io.Timestamp.now(runtime_io.get(), .awake);
        std.debug.print("[compat/harness] target_start {d}/{d} {s}\n", .{ index + 1, target_list.len, target.id });
        if (progress_log) {
            std.debug.print("[compat_harness] start {d}/{d} {s}\n", .{ index + 1, target_list.len, target.id });
        }
        runs[index] = try runTarget(allocator, target, options);
        const target_elapsed_ms = @as(f64, @floatFromInt(target_start_ts.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake)).nanoseconds)) / @as(f64, std.time.ns_per_ms);
        std.debug.print("[compat/harness] target_done {d}/{d} {s} ({d:.0} ms)\n", .{ index + 1, target_list.len, target.id, target_elapsed_ms });
        if (progress_log) {
            std.debug.print(
                "[compat_harness] done  {d}/{d} {s} classification={s} first_failed_stage={s}\n",
                .{
                    index + 1,
                    target_list.len,
                    target.id,
                    @tagName(runs[index].final_classification),
                    if (runs[index].first_failed_stage) |stage| @tagName(stage) else "none",
                },
            );
        }
    }

    return runs;
}

fn shouldLogProgress(options: RunOptions) bool {
    if (options.progress_log) return true;

    const value = runtime_io.environ().getPosix("GEN_Z_SITTER_PROGRESS") orelse return false;
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

fn shouldLogDetailProgress(options: RunOptions) bool {
    if (shouldLogProgress(options)) return true;

    const value = runtime_io.environ().getPosix("GEN_Z_SITTER_COMPAT_DETAIL_PROGRESS") orelse return false;
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

fn runScannerRuntimeLinkProofAlloc(allocator: std.mem.Allocator, target_id: []const u8) ![]const u8 {
    var config = try loadRuntimeProofConfigAlloc(allocator, target_id);
    defer config.deinit(allocator);

    try executeRuntimeProofConfig(allocator, config);
    return try std.fmt.allocPrint(
        allocator,
        "runtime proof config={s} proof_id={s} proof_level={s} extra_proofs={d} sample_files={d} blocked_surfaces={d}",
        .{
            config.config_path orelse "<none>",
            @tagName(config.proof_id),
            @tagName(config.proof_level),
            config.additional_proof_ids.len,
            config.sample_file_count,
            config.known_blocked_surface_count,
        },
    );
}

fn executeRuntimeProofConfig(allocator: std.mem.Allocator, config: RuntimeProofConfig) !void {
    try executeRuntimeProofId(allocator, config.proof_id);
    for (config.additional_proof_ids) |proof_id| {
        try executeRuntimeProofId(allocator, proof_id);
    }
}

fn executeRuntimeProofId(allocator: std.mem.Allocator, proof_id: RuntimeProofId) !void {
    switch (proof_id) {
        .bracket_lang_staged_scanner => return try runtime_link.linkAndRunBracketLangParser(allocator),
        .haskell_real_external_scanner => return try runtime_link.linkAndRunHaskellParserWithRealExternalScanner(allocator),
        .haskell_generated_glr_real_external_scanner => return try runtime_link.linkAndRunHaskellGeneratedGlrParserWithRealExternalScanner(allocator),
        .bash_real_external_scanner => return try runtime_link.linkAndRunBashParserWithRealExternalScanner(allocator),
        .bash_generated_glr_real_external_scanner => return try runtime_link.linkAndRunBashGeneratedGlrParserWithRealExternalScanner(allocator),
        .javascript_ternary_real_external_scanner => return try runtime_link.linkAndRunJavascriptTernaryParserWithRealExternalScanner(allocator),
        .javascript_ternary_invalid_real_external_scanner => return try runtime_link.linkAndRunJavascriptTernaryInvalidParserWithRealExternalScanner(allocator),
        .javascript_jsx_text_real_external_scanner => return try runtime_link.linkAndRunJavascriptJsxTextParserWithRealExternalScanner(allocator),
        .javascript_jsx_text_invalid_real_external_scanner => return try runtime_link.linkAndRunJavascriptJsxTextInvalidParserWithRealExternalScanner(allocator),
        .javascript_ternary_generated_glr_real_external_scanner => return try runtime_link.linkAndRunJavascriptTernaryGeneratedGlrParserWithRealExternalScanner(allocator),
        .typescript_ternary_real_external_scanner => return try runtime_link.linkAndRunTypescriptTernaryParserWithRealExternalScanner(allocator),
        .typescript_ternary_invalid_real_external_scanner => return try runtime_link.linkAndRunTypescriptTernaryInvalidParserWithRealExternalScanner(allocator),
        .typescript_jsx_text_real_external_scanner => return try runtime_link.linkAndRunTypescriptJsxTextParserWithRealExternalScanner(allocator),
        .typescript_jsx_text_invalid_real_external_scanner => return try runtime_link.linkAndRunTypescriptJsxTextInvalidParserWithRealExternalScanner(allocator),
        .python_newline_real_external_scanner => return try runtime_link.linkAndRunPythonNewlineParserWithRealExternalScanner(allocator),
        .python_newline_generated_glr_real_external_scanner => return try runtime_link.linkAndRunPythonNewlineGeneratedGlrParserWithRealExternalScanner(allocator),
        .python_string_real_external_scanner => return try runtime_link.linkAndRunPythonStringParserWithRealExternalScanner(allocator),
        .python_string_invalid_real_external_scanner => return try runtime_link.linkAndRunPythonStringInvalidParserWithRealExternalScanner(allocator),
        .python_indent_dedent_real_external_scanner => return try runtime_link.linkAndRunPythonIndentDedentParserWithRealExternalScanner(allocator),
        .python_indent_dedent_invalid_real_external_scanner => return try runtime_link.linkAndRunPythonIndentDedentInvalidParserWithRealExternalScanner(allocator),
        .rust_float_literal_real_external_scanner => return try runtime_link.linkAndRunRustFloatLiteralParserWithRealExternalScanner(allocator),
        .rust_raw_string_real_external_scanner => return try runtime_link.linkAndRunRustRawStringParserWithRealExternalScanner(allocator),
        .rust_raw_string_invalid_real_external_scanner => return try runtime_link.linkAndRunRustRawStringInvalidParserWithRealExternalScanner(allocator),
    }
}

fn shouldStopAfter(options: RunOptions, stage: result_model.StepName) bool {
    return options.stop_after_stage == stage;
}

fn loadExcludedTargetsEnv(allocator: std.mem.Allocator) !?[][]const u8 {
    const raw = runtime_io.environ().getPosix("GEN_Z_SITTER_COMPAT_EXCLUDE_TARGETS") orelse return null;

    if (raw.len == 0) return null;

    var entries = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit();
    }

    var iter = std.mem.tokenizeScalar(u8, raw, ',');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len == 0) continue;
        try entries.append(try allocator.dupe(u8, trimmed));
    }

    if (entries.items.len == 0) {
        entries.deinit();
        return null;
    }

    return try entries.toOwnedSlice();
}

fn shouldExcludeTarget(target_id: []const u8, excluded_targets: [][]const u8) bool {
    for (excluded_targets) |excluded| {
        if (std.mem.eql(u8, target_id, excluded)) return true;
    }
    return false;
}

fn filterTargetsAlloc(
    allocator: std.mem.Allocator,
    target_list: []const targets.Target,
    excluded_targets: [][]const u8,
) ![]targets.Target {
    var filtered = std.array_list.Managed(targets.Target).init(allocator);
    defer filtered.deinit();

    for (target_list) |target| {
        if (shouldExcludeTarget(target.id, excluded_targets)) continue;
        try filtered.append(target);
    }

    return try filtered.toOwnedSlice();
}

fn logDetailStart(target_id: []const u8, step: []const u8) void {
    std.debug.print("[compat_harness_detail] start {s} {s}\n", .{ target_id, step });
}

fn logDetailDone(target_id: []const u8, step: []const u8, start_ts: std.Io.Timestamp) void {
    std.debug.print("[compat_harness_detail] done  {s} {s} ({d:.2} ms)\n", .{ target_id, step, elapsedMs(start_ts) });
}

fn elapsedMs(start_ts: std.Io.Timestamp) f64 {
    const elapsed = start_ts.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake));
    return @as(f64, @floatFromInt(elapsed.nanoseconds)) / @as(f64, std.time.ns_per_ms);
}

fn parseConstructProfileSnapshot(
    profile: parse_table_build.ConstructProfile,
) result_model.ParseConstructProfileSnapshot {
    return .{
        .states_processed = profile.states_processed,
        .successor_groups = profile.successor_groups,
        .successor_seed_items = profile.successor_seed_items,
        .state_intern_calls = profile.state_intern_calls,
        .state_intern_reused = profile.state_intern_reused,
        .state_intern_new = profile.state_intern_new,
        .state_items_stored = profile.state_items_stored,
        .closure_cache_hits = profile.closure_cache_hits,
        .closure_cache_misses = profile.closure_cache_misses,
        .closure_runs = profile.closure_runs,
        .closure_items_returned = profile.closure_items_returned,
        .closure_expansion_cache_hits = profile.closure_expansion_cache_hits,
        .closure_expansion_cache_misses = profile.closure_expansion_cache_misses,
        .successor_seed_cache_hits = profile.successor_seed_cache_hits,
        .successor_seed_cache_misses = profile.successor_seed_cache_misses,
        .item_set_hash_calls = profile.item_set_hash_calls,
        .item_set_hash_entries = profile.item_set_hash_entries,
        .item_set_eql_calls = profile.item_set_eql_calls,
        .item_set_eql_entries = profile.item_set_eql_entries,
        .symbol_set_init_empty_count = profile.symbol_set_init_empty_count,
        .symbol_set_clone_count = profile.symbol_set_clone_count,
        .symbol_set_free_count = profile.symbol_set_free_count,
        .symbol_set_alloc_bytes = profile.symbol_set_alloc_bytes,
        .symbol_set_free_bytes = profile.symbol_set_free_bytes,
        .collect_transitions_ns = profile.collect_transitions_ns,
        .extra_transitions_ns = profile.extra_transitions_ns,
        .reserved_word_ns = profile.reserved_word_ns,
        .build_actions_ns = profile.build_actions_ns,
        .detect_conflicts_ns = profile.detect_conflicts_ns,
    };
}

fn lexEmissionSnapshot(stats: parser_c_emit.LexEmissionStats) result_model.LexEmissionSnapshot {
    return .{
        .table_count = stats.table_count,
        .state_count = stats.state_count,
        .transition_count = stats.transition_count,
        .range_count = stats.range_count,
        .accept_state_count = stats.accept_state_count,
        .eof_target_count = stats.eof_target_count,
        .skip_transition_count = stats.skip_transition_count,
        .large_range_transition_count = stats.large_range_transition_count,
        .max_transition_range_count = stats.max_transition_range_count,
        .keyword_state_count = stats.keyword_state_count,
        .keyword_transition_count = stats.keyword_transition_count,
        .keyword_range_count = stats.keyword_range_count,
    };
}

test "parseConstructProfileSnapshot carries SymbolSet allocation counters" {
    const snapshot = parseConstructProfileSnapshot(.{
        .symbol_set_init_empty_count = 2,
        .symbol_set_clone_count = 3,
        .symbol_set_free_count = 4,
        .symbol_set_alloc_bytes = 512,
        .symbol_set_free_bytes = 256,
    });

    try std.testing.expectEqual(@as(usize, 2), snapshot.symbol_set_init_empty_count);
    try std.testing.expectEqual(@as(usize, 3), snapshot.symbol_set_clone_count);
    try std.testing.expectEqual(@as(usize, 4), snapshot.symbol_set_free_count);
    try std.testing.expectEqual(@as(usize, 512), snapshot.symbol_set_alloc_bytes);
    try std.testing.expectEqual(@as(usize, 256), snapshot.symbol_set_free_bytes);
}

test "parseTargetBuildConfig supports thresholded closure pressure" {
    const config = try parseTargetBuildConfig(std.testing.allocator,
        \\{
        \\  "closure_pressure_mode": "thresholded_lr0",
        \\  "closure_pressure_thresholds": {
        \\    "max_closure_items": 3584,
        \\    "max_duplicate_hits": 12000,
        \\    "max_contexts_per_non_terminal": 160
        \\  }
        \\}
    );

    try std.testing.expectEqual(parse_table_build.ClosurePressureMode.thresholded_lr0, config.closure_pressure_mode);
    try std.testing.expectEqual(@as(usize, 3584), config.closure_pressure_thresholds.max_closure_items);
    try std.testing.expectEqual(@as(usize, 12000), config.closure_pressure_thresholds.max_duplicate_hits);
    try std.testing.expectEqual(@as(usize, 160), config.closure_pressure_thresholds.max_contexts_per_non_terminal);
}

test "parseTargetBuildConfig rejects thresholds without pressure mode" {
    try std.testing.expectError(error.InvalidTargetBuildConfig, parseTargetBuildConfig(std.testing.allocator,
        \\{
        \\  "closure_pressure_thresholds": {
        \\    "max_closure_items": 3584
        \\  }
        \\}
    ));
}

test "targetBuildConfigPathAlloc uses target id directory" {
    const path = try targetBuildConfigPathAlloc(std.testing.allocator, "tree_sitter_haskell_json");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("compat_targets/tree_sitter_haskell_json/build_config.json", path);
}

test "parseRuntimeProofConfig records generic proof metadata" {
    var config = try parseRuntimeProofConfig(std.testing.allocator,
        \\{
        \\  "proof_level": "full_runtime_link",
        \\  "proof_id": "bash_real_external_scanner",
        \\  "additional_proof_ids": ["bash_generated_glr_real_external_scanner"],
        \\  "external_scanner_source": "../tree-sitter-grammars/tree-sitter-bash/src/scanner.c",
        \\  "sample_files": ["compat_targets/tree_sitter_bash/valid.txt"],
        \\  "known_blocked_surfaces": []
        \\}
    );
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(RuntimeProofLevel.full_runtime_link, config.proof_level);
    try std.testing.expectEqual(RuntimeProofId.bash_real_external_scanner, config.proof_id);
    try std.testing.expectEqual(@as(usize, 1), config.additional_proof_ids.len);
    try std.testing.expectEqual(RuntimeProofId.bash_generated_glr_real_external_scanner, config.additional_proof_ids[0]);
    try std.testing.expectEqual(@as(usize, 1), config.sample_file_count);
    try std.testing.expectEqual(@as(usize, 0), config.known_blocked_surface_count);
    try std.testing.expectEqualStrings("../tree-sitter-grammars/tree-sitter-bash/src/scanner.c", config.external_scanner_source.?);
}

test "runtimeProofConfigPathAlloc uses target id directory" {
    const path = try runtimeProofConfigPathAlloc(std.testing.allocator, "tree_sitter_bash_json");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("compat_targets/tree_sitter_bash_json/runtime_proof_config.json", path);
}

fn functionSpanBytes(source: []const u8, start_marker: []const u8, end_marker: []const u8) usize {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return 0;
    const end = std.mem.indexOfPos(u8, source, start + start_marker.len, end_marker) orelse return source.len - start;
    return end - start;
}

fn mainLexFunctionBytes(source: []const u8) usize {
    const start_marker = "static bool ts_lex(TSLexer *lexer, TSStateId state)";
    const keyword_marker = "static bool ts_lex_keywords(TSLexer *lexer, TSStateId state)";
    const modes_marker = "static const TSLexerMode ts_lex_modes";
    const start = std.mem.indexOf(u8, source, start_marker) orelse return 0;
    const keyword_start = std.mem.indexOfPos(u8, source, start + start_marker.len, keyword_marker);
    const modes_start = std.mem.indexOfPos(u8, source, start + start_marker.len, modes_marker);
    const end = keyword_start orelse modes_start orelse source.len;
    return end - start;
}

fn logDetailSummary(comptime format: []const u8, args: anytype) void {
    std.debug.print("[compat_harness_detail] " ++ format ++ "\n", args);
}

fn logSimulationSummary(target_id: []const u8, label: []const u8, result: behavioral_harness.SimulationResult) void {
    switch (result) {
        .accepted => |accepted| logDetailSummary(
            "{s} {s} result=accepted consumed_bytes={d} shifted_tokens={d}",
            .{ target_id, label, accepted.consumed_bytes, accepted.shifted_tokens },
        ),
        .rejected => |rejected| logDetailSummary(
            "{s} {s} result=rejected consumed_bytes={d} shifted_tokens={d} reason={s}",
            .{ target_id, label, rejected.consumed_bytes, rejected.shifted_tokens, @tagName(rejected.reason) },
        ),
    }
}

fn logExternalSampleSummary(target_id: []const u8, label: []const u8, sample: behavioral_harness.ExternalBoundarySample) void {
    logDetailSummary(
        "{s} {s} consumed_bytes={d} external_matches={d} lexical_matches={d}",
        .{ target_id, label, sample.consumed_bytes, sample.external_matches, sample.lexical_matches },
    );
}

fn shouldEnableParseTableScopedProgress(target_id: []const u8) bool {
    const value = runtime_io.environ().getPosix("GEN_Z_SITTER_PARSE_TABLE_TARGET_FILTER") orelse return false;

    if (value.len == 0) return false;
    return std.mem.eql(u8, value, target_id);
}

const TargetBuildConfig = struct {
    config_path: ?[]const u8 = null,
    closure_pressure_mode: parse_table_build.ClosurePressureMode = .none,
    closure_pressure_thresholds: parse_table_build.ClosurePressureThresholds = .{},

    fn hasClosurePressure(self: TargetBuildConfig) bool {
        return self.closure_pressure_mode != .none;
    }
};

const RuntimeProofLevel = enum {
    full_runtime_link,
};

const RuntimeProofId = enum {
    bracket_lang_staged_scanner,
    haskell_real_external_scanner,
    haskell_generated_glr_real_external_scanner,
    bash_real_external_scanner,
    bash_generated_glr_real_external_scanner,
    javascript_ternary_real_external_scanner,
    javascript_ternary_invalid_real_external_scanner,
    javascript_jsx_text_real_external_scanner,
    javascript_jsx_text_invalid_real_external_scanner,
    javascript_ternary_generated_glr_real_external_scanner,
    typescript_ternary_real_external_scanner,
    typescript_ternary_invalid_real_external_scanner,
    typescript_jsx_text_real_external_scanner,
    typescript_jsx_text_invalid_real_external_scanner,
    python_newline_real_external_scanner,
    python_newline_generated_glr_real_external_scanner,
    python_string_real_external_scanner,
    python_string_invalid_real_external_scanner,
    python_indent_dedent_real_external_scanner,
    python_indent_dedent_invalid_real_external_scanner,
    rust_float_literal_real_external_scanner,
    rust_raw_string_real_external_scanner,
    rust_raw_string_invalid_real_external_scanner,
};

const RuntimeProofConfig = struct {
    config_path: ?[]const u8 = null,
    proof_level: RuntimeProofLevel = .full_runtime_link,
    proof_id: RuntimeProofId,
    additional_proof_ids: []const RuntimeProofId = &.{},
    external_scanner_source: ?[]const u8 = null,
    external_scanner_include_dir: ?[]const u8 = null,
    sample_file_count: usize = 0,
    known_blocked_surface_count: usize = 0,

    fn deinit(self: *RuntimeProofConfig, allocator: std.mem.Allocator) void {
        if (self.config_path) |value| allocator.free(value);
        allocator.free(self.additional_proof_ids);
        if (self.external_scanner_source) |value| allocator.free(value);
        if (self.external_scanner_include_dir) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn loadTargetBuildConfigAlloc(allocator: std.mem.Allocator, target: targets.Target) !TargetBuildConfig {
    const config_path = try targetBuildConfigPathAlloc(allocator, target.id);
    errdefer allocator.free(config_path);

    const contents = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), config_path, allocator, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(config_path);
            return .{};
        },
        else => return err,
    };
    defer allocator.free(contents);

    var config = try parseTargetBuildConfig(allocator, contents);
    config.config_path = config_path;
    return config;
}

fn targetBuildConfigPathAlloc(allocator: std.mem.Allocator, target_id: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ "compat_targets", target_id, "build_config.json" });
}

fn loadRuntimeProofConfigAlloc(allocator: std.mem.Allocator, target_id: []const u8) !RuntimeProofConfig {
    const config_path = try runtimeProofConfigPathAlloc(allocator, target_id);
    errdefer allocator.free(config_path);

    const contents = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), config_path, allocator, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingRuntimeProofConfig,
        else => return err,
    };
    defer allocator.free(contents);

    var config = try parseRuntimeProofConfig(allocator, contents);
    config.config_path = config_path;
    return config;
}

fn runtimeProofConfigPathAlloc(allocator: std.mem.Allocator, target_id: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ "compat_targets", target_id, "runtime_proof_config.json" });
}

fn parseRuntimeProofConfig(allocator: std.mem.Allocator, contents: []const u8) !RuntimeProofConfig {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidRuntimeProofConfig,
    };

    const proof_level = try parseRuntimeProofLevel(requiredStringField(root, "proof_level") orelse return error.InvalidRuntimeProofConfig);
    const proof_id = try parseRuntimeProofId(requiredStringField(root, "proof_id") orelse return error.InvalidRuntimeProofConfig);

    return .{
        .proof_level = proof_level,
        .proof_id = proof_id,
        .additional_proof_ids = try parseAdditionalRuntimeProofIdsAlloc(allocator, root),
        .external_scanner_source = try optionalStringFieldAlloc(allocator, root, "external_scanner_source"),
        .external_scanner_include_dir = try optionalStringFieldAlloc(allocator, root, "external_scanner_include_dir"),
        .sample_file_count = optionalArrayFieldLen(root, "sample_files"),
        .known_blocked_surface_count = optionalArrayFieldLen(root, "known_blocked_surfaces"),
    };
}

fn parseAdditionalRuntimeProofIdsAlloc(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) ![]const RuntimeProofId {
    const value = root.get("additional_proof_ids") orelse return &.{};
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidRuntimeProofConfig,
    };

    const proof_ids = try allocator.alloc(RuntimeProofId, array.items.len);
    errdefer allocator.free(proof_ids);
    for (array.items, 0..) |item, index| {
        const text = switch (item) {
            .string => |string_value| string_value,
            else => return error.InvalidRuntimeProofConfig,
        };
        proof_ids[index] = try parseRuntimeProofId(text);
    }
    return proof_ids;
}

fn parseRuntimeProofLevel(value: []const u8) !RuntimeProofLevel {
    if (std.mem.eql(u8, value, "full_runtime_link")) return .full_runtime_link;
    return error.InvalidRuntimeProofConfig;
}

fn parseRuntimeProofId(value: []const u8) !RuntimeProofId {
    inline for (@typeInfo(RuntimeProofId).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(RuntimeProofId, field.name);
    }
    return error.InvalidRuntimeProofConfig;
}

fn requiredStringField(root: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = root.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalStringFieldAlloc(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    name: []const u8,
) !?[]const u8 {
    const value = root.get(name) orelse return null;
    const text = switch (value) {
        .string => |string_value| string_value,
        else => return error.InvalidRuntimeProofConfig,
    };
    return try allocator.dupe(u8, text);
}

fn optionalArrayFieldLen(root: std.json.ObjectMap, name: []const u8) usize {
    const value = root.get(name) orelse return 0;
    return switch (value) {
        .array => |array| array.items.len,
        else => 0,
    };
}

fn parseTargetBuildConfig(allocator: std.mem.Allocator, contents: []const u8) !TargetBuildConfig {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidTargetBuildConfig,
    };

    var config: TargetBuildConfig = .{};
    if (root.get("closure_pressure_mode")) |mode_value| {
        const mode_text = switch (mode_value) {
            .string => |value| value,
            else => return error.InvalidTargetBuildConfig,
        };
        config.closure_pressure_mode = if (std.mem.eql(u8, mode_text, "none"))
            .none
        else if (std.mem.eql(u8, mode_text, "thresholded_lr0"))
            .thresholded_lr0
        else
            return error.InvalidTargetBuildConfig;
    }

    if (root.get("closure_pressure_thresholds")) |thresholds_value| {
        const thresholds = switch (thresholds_value) {
            .object => |object| object,
            else => return error.InvalidTargetBuildConfig,
        };
        config.closure_pressure_thresholds = .{
            .max_closure_items = try optionalUsizeField(thresholds, "max_closure_items"),
            .max_duplicate_hits = try optionalUsizeField(thresholds, "max_duplicate_hits"),
            .max_contexts_per_non_terminal = try optionalUsizeField(thresholds, "max_contexts_per_non_terminal"),
        };
    }

    if (config.closure_pressure_mode == .thresholded_lr0 and !config.closure_pressure_thresholds.enabled()) {
        return error.InvalidTargetBuildConfig;
    }
    if (config.closure_pressure_mode == .none and config.closure_pressure_thresholds.enabled()) {
        return error.InvalidTargetBuildConfig;
    }
    return config;
}

fn optionalUsizeField(object: std.json.ObjectMap, name: []const u8) !usize {
    const value = object.get(name) orelse return 0;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidTargetBuildConfig,
        else => error.InvalidTargetBuildConfig,
    };
}

pub fn runTarget(
    allocator: std.mem.Allocator,
    target: targets.Target,
    options: RunOptions,
) !result_model.TargetRunResult {
    var run = result_model.TargetRunResult.init(target);
    errdefer run.deinit(allocator);
    const detail_progress = shouldLogDetailProgress(options);
    std.debug.print("[compat/harness] runTarget enter {s}\n", .{target.id});

    if (target.candidate_status == .excluded_out_of_scope) {
        return failRun(
            &run,
            .load,
            .out_of_scope_for_scanner_boundary,
            .out_of_scope_scanner_boundary,
            try std.fmt.allocPrint(allocator, "target is excluded from parser-only execution: {s}", .{target.notes}),
        );
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    std.debug.print("[compat/harness] stage load {s}\n", .{target.id});
    const load_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    if (detail_progress) logDetailStart(target.id, "load");
    var loaded = grammar_loader.loadGrammarFile(arena.allocator(), target.grammar_path) catch |err| {
        return failRun(
            &run,
            .load,
            classifyLoadFailure(err),
            mismatchCategoryForLoadFailure(err),
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ target.grammar_path, grammar_loader.errorMessage(err) }),
        );
    };
    if (detail_progress) logDetailDone(target.id, "load", load_timer);
    run.load.status = .passed;
    defer loaded.deinit();
    if (shouldStopAfter(options, .load)) return run;

    std.debug.print("[compat/harness] stage prepare {s}\n", .{target.id});
    const prepare_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    if (detail_progress) logDetailStart(target.id, "prepare");
    const prepared = parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar) catch |err| {
        const diagnostic = parse_grammar.errorDiagnostic(err);
        return failRun(
            &run,
            .prepare,
            .failed_due_to_parser_only_gap,
            .preparation_lowering_mismatch,
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ target.grammar_path, diagnostic.summary }),
        );
    };
    if (detail_progress) logDetailDone(target.id, "prepare", prepare_timer);
    run.prepare.status = .passed;
    if (shouldStopAfter(options, .prepare)) return run;

    if (target.boundary_kind == .parser_only and target.parser_boundary_check_mode == .prepare_only) {
        return failRun(
            &run,
            .serialize,
            .deferred_for_parser_boundary,
            .routine_serialize_proof_boundary,
            try std.fmt.allocPrint(
                allocator,
                "routine lookahead-sensitive serialize proof is deferred for {s}: the current stable shortlist only proves load and prepare here, while the only passing next proof is the standalone coarse serialize-only probe",
                .{target.id},
            ),
        );
    }

    if (target.boundary_kind == .parser_only and target.parser_boundary_check_mode == .serialize_only) {
        const scoped_parse_table_progress = shouldEnableParseTableScopedProgress(target.id);
        if (scoped_parse_table_progress) {
            parse_table_build.setScopedProgressEnabled(true);
            parse_table_pipeline.setScopedProgressEnabled(true);
        }
        defer if (scoped_parse_table_progress) {
            parse_table_build.setScopedProgressEnabled(false);
            parse_table_pipeline.setScopedProgressEnabled(false);
        };

        std.debug.print("[compat/harness] stage serialize {s}\n", .{target.id});
        const serialize_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "routine_coarse_serialize_only");
        var parse_construct_profile = parse_table_build.ConstructProfile{};
        const serialized = parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
            arena.allocator(),
            prepared,
            .diagnostic,
            .{
                .closure_lookahead_mode = .none,
                .construct_profile = &parse_construct_profile,
            },
        ) catch |err| {
            return failRun(
                &run,
                .serialize,
                .deferred_for_parser_boundary,
                .routine_serialize_proof_boundary,
                try std.fmt.allocPrint(allocator, "routine coarse serialize-only proof failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) {
            logDetailDone(target.id, "routine_coarse_serialize_only", serialize_timer);
            logDetailSummary(
                "{s} routine_coarse_serialize_only serialized_states={d} blocked={}",
                .{ target.id, serialized.states.len, serialized.blocked },
            );
        }
        run.serialize.status = .passed;
        if (shouldStopAfter(options, .serialize)) return run;
        std.debug.print("[compat/harness] stage emit_parser_tables {s}\n", .{target.id});
        const parser_tables_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "emit_parser_tables");
        const parser_tables = parser_tables_emit.emitSerializedTableAllocWithOptions(arena.allocator(), serialized, options.optimize) catch |err| {
            return failRun(
                &run,
                .emit_parser_tables,
                .deferred_for_parser_boundary,
                .routine_emitted_surface_proof_boundary,
                try std.fmt.allocPrint(allocator, "routine parser-table emission proof failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) {
            logDetailDone(target.id, "emit_parser_tables", parser_tables_timer);
            logDetailSummary(
                "{s} emit_parser_tables bytes={d}",
                .{ target.id, parser_tables.len },
            );
        }
        run.emit_parser_tables.status = .passed;
        if (shouldStopAfter(options, .emit_parser_tables)) return run;
        std.debug.print("[compat/harness] stage emit_parser_c {s}\n", .{target.id});
        const parser_c_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "emit_parser_c");
        const parser_c = parser_c_emit.emitParserCAllocWithOptions(arena.allocator(), serialized, options.optimize) catch |err| {
            return failRun(
                &run,
                .emit_parser_c,
                .deferred_for_parser_boundary,
                .routine_emitted_surface_proof_boundary,
                try std.fmt.allocPrint(allocator, "routine parser.c emission proof failed: {s}", .{@errorName(err)}),
            );
        };
        const parser_c_ms = elapsedMs(parser_c_timer);
        if (detail_progress) {
            logDetailDone(target.id, "emit_parser_c", parser_c_timer);
            logDetailSummary(
                "{s} emit_parser_c bytes={d}",
                .{ target.id, parser_c.len },
            );
        }
        run.emit_parser_c.status = .passed;
        if (shouldStopAfter(options, .emit_parser_c)) return run;
        std.debug.print("[compat/harness] stage compat_check {s}\n", .{target.id});
        const compat_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "compat_check");
        compat_checks.validateParserCCompatibilitySurface(parser_c) catch |err| {
            return failRun(
                &run,
                .compat_check,
                .deferred_for_parser_boundary,
                .routine_emitted_surface_proof_boundary,
                try std.fmt.allocPrint(allocator, "routine compatibility check failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) logDetailDone(target.id, "compat_check", compat_timer);
        run.compat_check.status = .passed;
        if (shouldStopAfter(options, .compat_check)) return run;
        std.debug.print("[compat/harness] stage compile_smoke {s}\n", .{target.id});
        const compile_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "compile_smoke");
        var compile_result = compile_smoke.compileParserC(allocator, parser_c) catch |err| {
            return failRun(
                &run,
                .compile_smoke,
                .infrastructure_failure,
                .infrastructure_failure,
                try std.fmt.allocPrint(allocator, "routine compile-smoke infrastructure failure: {s}", .{@errorName(err)}),
            );
        };
        defer compile_result.deinit(allocator);
        switch (compile_result) {
            .success => |success| {
                const compile_smoke_ms = elapsedMs(compile_timer);
                if (detail_progress) logDetailDone(target.id, "compile_smoke", compile_timer);
                run.compile_smoke.status = .passed;
                const lex_stats = parser_c_emit.collectLexEmissionStats(serialized);
                run.emission = .{
                    .blocked = serialized.blocked,
                    .serialized_state_count = serialized.states.len,
                    .emitted_state_count = 0,
                    .merged_state_count = 0,
                    .action_entry_count = 0,
                    .goto_entry_count = 0,
                    .unresolved_entry_count = 0,
                    .parser_tables_bytes = parser_tables.len,
                    .parser_c_bytes = parser_c.len,
                    .lex_function_bytes = mainLexFunctionBytes(parser_c),
                    .keyword_lex_function_bytes = functionSpanBytes(
                        parser_c,
                        "static bool ts_lex_keywords(TSLexer *lexer, TSStateId state)",
                        "static const TSLexerMode ts_lex_modes",
                    ),
                    .emit_parser_c_ms = if (options.profile_timings) parser_c_ms else null,
                    .compile_smoke_ms = if (options.profile_timings) compile_smoke_ms else null,
                    .compile_smoke_max_rss_bytes = success.max_rss_bytes,
                    .parse_construct_profile = parseConstructProfileSnapshot(parse_construct_profile),
                    .lex = lexEmissionSnapshot(lex_stats),
                };
                if (shouldStopAfter(options, .compile_smoke)) return run;
            },
            .compiler_error => |stderr| {
                return failRun(
                    &run,
                    .compile_smoke,
                    .deferred_for_parser_boundary,
                    .routine_emitted_surface_proof_boundary,
                    try std.fmt.allocPrint(allocator, "routine compile-smoke proof failed:\n{s}", .{stderr}),
                );
            },
        }

        return run;
    }

    if (target.boundary_kind == .scanner_external_scanner) {
        const scanner_extract_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "scanner_extract_tokens");
        const extracted = extract_tokens.extractTokens(arena.allocator(), prepared) catch |err| {
            return failRun(
                &run,
                .serialize,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner-boundary token extraction failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) {
            logDetailDone(target.id, "scanner_extract_tokens", scanner_extract_timer);
            logDetailSummary(
                "{s} scanner_extract_tokens syntax_variables={d} lexical_variables={d} external_tokens={d}",
                .{ target.id, extracted.syntax.variables.len, extracted.lexical.variables.len, extracted.syntax.external_tokens.len },
            );
        }

        const scanner_serialize_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "scanner_serialize_boundary");
        const serialized_boundary = scanner_serialize.serializeExternalScannerBoundary(arena.allocator(), extracted.syntax) catch |err| {
            return failRun(
                &run,
                .serialize,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "external-scanner boundary extraction failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) {
            logDetailDone(target.id, "scanner_serialize_boundary", scanner_serialize_timer);
            logDetailSummary(
                "{s} scanner_serialize_boundary ready={} tokens={d} unsupported_features={d}",
                .{ target.id, serialized_boundary.isReady(), serialized_boundary.tokens.len, serialized_boundary.unsupported_features.len },
            );
        }

        if (!serialized_boundary.isReady()) {
            return failRun(
                &run,
                .serialize,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try formatUnsupportedExternalFeaturesAlloc(allocator, serialized_boundary.unsupported_features),
            );
        }
        run.serialize.status = .passed;
        if (shouldStopAfter(options, .serialize)) return run;

        if (target.scanner_boundary_check_mode == .full_runtime_link) {
            const runtime_link_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
            if (detail_progress) logDetailStart(target.id, "scanner_runtime_link");
            const proof_detail = runScannerRuntimeLinkProofAlloc(allocator, target.id) catch |err| {
                return failRun(
                    &run,
                    .scanner_boundary_check,
                    .deferred_for_scanner_boundary,
                    .scanner_external_scanner_boundary_gap,
                    try std.fmt.allocPrint(allocator, "scanner runtime-link proof failed for {s}: {s}", .{ target.id, @errorName(err) }),
                );
            };
            if (detail_progress) logDetailDone(target.id, "scanner_runtime_link", runtime_link_timer);
            run.scanner_boundary_check.status = .passed;
            run.scanner_boundary_check.detail = proof_detail;
            return run;
        }

        if (target.scanner_boundary_check_mode == .structural_only) {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(
                    allocator,
                    "sampled scanner-boundary simulation is deferred for {s}: the current harness only proves structural first-boundary extraction here, while this target still requires broader stateful multi-token external-scanner modeling",
                    .{target.id},
                ),
            );
        }

        if (target.scanner_boundary_check_mode == .sampled_external_only) {
            const valid_input_path = target.scanner_valid_input_path orelse
                return failRun(
                    &run,
                    .scanner_boundary_check,
                    .deferred_for_scanner_boundary,
                    .scanner_external_scanner_boundary_gap,
                    try std.fmt.allocPrint(allocator, "scanner target is missing a valid input path: {s}", .{target.id}),
                );
            const valid_input = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), valid_input_path, arena.allocator(), .limited(64 * 1024)) catch |err| {
                return failRun(
                    &run,
                    .scanner_boundary_check,
                    .infrastructure_failure,
                    .infrastructure_failure,
                    try std.fmt.allocPrint(allocator, "failed to read scanner valid input {s}: {s}", .{ valid_input_path, @errorName(err) }),
                );
            };

            const sampled_external_valid_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
            if (detail_progress) {
                logDetailSummary("{s} scanner_valid_input bytes={d} path={s}", .{ target.id, valid_input.len, valid_input_path });
                logDetailStart(target.id, "sampled_external_only_valid");
            }

            const valid_sample = behavioral_harness.sampleExtractedExternalBoundaryOnly(
                arena.allocator(),
                prepared,
                extracted.syntax,
                extracted.lexical,
                serialized_boundary,
                valid_input,
            ) catch |err| {
                return failRun(
                    &run,
                    .scanner_boundary_check,
                    .deferred_for_scanner_boundary,
                    .scanner_external_scanner_boundary_gap,
                    try std.fmt.allocPrint(allocator, "scanner sampled external-only valid-path probe failed: {s}", .{@errorName(err)}),
                );
            };
            if (detail_progress) {
                logDetailDone(target.id, "sampled_external_only_valid", sampled_external_valid_timer);
                logExternalSampleSummary(target.id, "sampled_external_only_valid", valid_sample);
            }

            const invalid_input_path = target.scanner_invalid_input_path orelse
                return failRun(
                    &run,
                    .scanner_boundary_check,
                    .deferred_for_scanner_boundary,
                    .scanner_external_scanner_boundary_gap,
                    try std.fmt.allocPrint(allocator, "scanner target is missing an invalid input path: {s}", .{target.id}),
                );
            const invalid_input = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), invalid_input_path, arena.allocator(), .limited(64 * 1024)) catch |err| {
                return failRun(
                    &run,
                    .scanner_boundary_check,
                    .infrastructure_failure,
                    .infrastructure_failure,
                    try std.fmt.allocPrint(allocator, "failed to read scanner invalid input {s}: {s}", .{ invalid_input_path, @errorName(err) }),
                );
            };

            const sampled_external_invalid_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
            if (detail_progress) {
                logDetailSummary("{s} scanner_invalid_input bytes={d} path={s}", .{ target.id, invalid_input.len, invalid_input_path });
                logDetailStart(target.id, "sampled_external_only_invalid");
            }

            const invalid_sample = behavioral_harness.sampleExtractedExternalBoundaryOnly(
                arena.allocator(),
                prepared,
                extracted.syntax,
                extracted.lexical,
                serialized_boundary,
                invalid_input,
            ) catch |err| {
                return failRun(
                    &run,
                    .scanner_boundary_check,
                    .deferred_for_scanner_boundary,
                    .scanner_external_scanner_boundary_gap,
                    try std.fmt.allocPrint(allocator, "scanner sampled external-only invalid-path probe failed: {s}", .{@errorName(err)}),
                );
            };
            if (detail_progress) {
                logDetailDone(target.id, "sampled_external_only_invalid", sampled_external_invalid_timer);
                logExternalSampleSummary(target.id, "sampled_external_only_invalid", invalid_sample);
            }

            if (!(valid_sample.external_matches > 0 and valid_sample.consumed_bytes > invalid_sample.consumed_bytes)) {
                return failRun(
                    &run,
                    .scanner_boundary_check,
                    .deferred_for_scanner_boundary,
                    .scanner_external_scanner_boundary_gap,
                    try std.fmt.allocPrint(
                        allocator,
                        "sampled external-only scanner probe did not make stronger valid-path progress for {s}: valid bytes={d} externals={d}, invalid bytes={d} externals={d}",
                        .{
                            target.id,
                            valid_sample.consumed_bytes,
                            valid_sample.external_matches,
                            invalid_sample.consumed_bytes,
                            invalid_sample.external_matches,
                        },
                    ),
                );
            }

            run.scanner_boundary_check.status = .passed;
            if (shouldStopAfter(options, .scanner_boundary_check)) return run;
            return run;
        }

        if (extracted.lexical.separators.len != 0) {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(
                    allocator,
                    "sampled behavioral external-scanner simulation does not support lexical separators yet for {s}: separators={d}",
                    .{ target.id, extracted.lexical.separators.len },
                ),
            );
        }

        const scanner_flatten_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "scanner_flatten");
        const flattened = flatten_grammar.flattenGrammar(arena.allocator(), extracted.syntax) catch |err| {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner-boundary flattening failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) {
            logDetailDone(target.id, "scanner_flatten", scanner_flatten_timer);
            logDetailSummary("{s} scanner_flatten variables={d}", .{ target.id, flattened.variables.len });
        }

        const scoped_parse_table_progress = shouldEnableParseTableScopedProgress(target.id);
        if (scoped_parse_table_progress) {
            parse_table_build.setScopedProgressEnabled(true);
            parse_table_pipeline.setScopedProgressEnabled(true);
        }
        defer if (scoped_parse_table_progress) {
            parse_table_build.setScopedProgressEnabled(false);
            parse_table_pipeline.setScopedProgressEnabled(false);
        };

        const scanner_build_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) logDetailStart(target.id, "scanner_build_states");
        const target_build_config = loadTargetBuildConfigAlloc(arena.allocator(), target) catch |err| {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "build_config load failed: {s}", .{@errorName(err)}),
            );
        };
        const build_options: parse_table_build.BuildOptions = .{
            .closure_pressure_mode = target_build_config.closure_pressure_mode,
            .closure_pressure_thresholds = target_build_config.closure_pressure_thresholds,
        };
        if (detail_progress and target_build_config.hasClosurePressure()) {
            const thresholds = build_options.closure_pressure_thresholds;
            logDetailSummary(
                "{s} scanner_build_states build_config={s} closure_pressure_mode={s} max_closure_items={d} max_duplicate_hits={d} max_contexts_per_non_terminal={d}",
                .{
                    target.id,
                    target_build_config.config_path orelse "<none>",
                    @tagName(target_build_config.closure_pressure_mode),
                    thresholds.max_closure_items,
                    thresholds.max_duplicate_hits,
                    thresholds.max_contexts_per_non_terminal,
                },
            );
        }
        const build_result = parse_table_build.buildStatesWithOptions(arena.allocator(), flattened, build_options) catch |err| {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner-boundary state construction failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) {
            logDetailDone(target.id, "scanner_build_states", scanner_build_timer);
            logDetailSummary(
                "{s} scanner_build_states states={d} productions={d}",
                .{ target.id, build_result.states.len, build_result.productions.len },
            );
        }

        const valid_input_path = target.scanner_valid_input_path orelse
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner target is missing a valid input path: {s}", .{target.id}),
            );
        const valid_input = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), valid_input_path, arena.allocator(), .limited(64 * 1024)) catch |err| {
            return failRun(
                &run,
                .scanner_boundary_check,
                .infrastructure_failure,
                .infrastructure_failure,
                try std.fmt.allocPrint(allocator, "failed to read scanner valid input {s}: {s}", .{ valid_input_path, @errorName(err) }),
            );
        };
        const sampled_behavioral_valid_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) {
            logDetailSummary("{s} scanner_valid_input bytes={d} path={s}", .{ target.id, valid_input.len, valid_input_path });
            logDetailStart(target.id, "sampled_behavioral_valid");
        }

        const simulation = behavioral_harness.simulateBuiltWithSerializedExternalBoundary(
            arena.allocator(),
            build_result,
            prepared,
            extracted.lexical,
            serialized_boundary,
            valid_input,
        ) catch |err| {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner valid-path simulation failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) {
            logDetailDone(target.id, "sampled_behavioral_valid", sampled_behavioral_valid_timer);
            logSimulationSummary(target.id, "sampled_behavioral_valid", simulation);
        }

        if (!isCompatibilitySafeValidResult(simulation)) {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner valid-path simulation was not compatibility-safe for {s}", .{target.id}),
            );
        }

        const invalid_input_path = target.scanner_invalid_input_path orelse
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner target is missing an invalid input path: {s}", .{target.id}),
            );
        const invalid_input = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), invalid_input_path, arena.allocator(), .limited(64 * 1024)) catch |err| {
            return failRun(
                &run,
                .scanner_boundary_check,
                .infrastructure_failure,
                .infrastructure_failure,
                try std.fmt.allocPrint(allocator, "failed to read scanner invalid input {s}: {s}", .{ invalid_input_path, @errorName(err) }),
            );
        };
        const sampled_behavioral_invalid_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
        if (detail_progress) {
            logDetailSummary("{s} scanner_invalid_input bytes={d} path={s}", .{ target.id, invalid_input.len, invalid_input_path });
            logDetailStart(target.id, "sampled_behavioral_invalid");
        }

        const invalid_simulation = behavioral_harness.simulateBuiltWithSerializedExternalBoundary(
            arena.allocator(),
            build_result,
            prepared,
            extracted.lexical,
            serialized_boundary,
            invalid_input,
        ) catch |err| {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner invalid-path simulation failed: {s}", .{@errorName(err)}),
            );
        };
        if (detail_progress) {
            logDetailDone(target.id, "sampled_behavioral_invalid", sampled_behavioral_invalid_timer);
            logSimulationSummary(target.id, "sampled_behavioral_invalid", invalid_simulation);
        }

        if (!(progressOf(simulation) > progressOf(invalid_simulation))) {
            return failRun(
                &run,
                .scanner_boundary_check,
                .deferred_for_scanner_boundary,
                .scanner_external_scanner_boundary_gap,
                try std.fmt.allocPrint(allocator, "scanner invalid path did not make less progress than the valid path for {s}", .{target.id}),
            );
        }

        run.scanner_boundary_check.status = .passed;
        if (shouldStopAfter(options, .scanner_boundary_check)) return run;
        return run;
    }

    const scoped_parse_table_progress = shouldEnableParseTableScopedProgress(target.id);
    if (scoped_parse_table_progress) {
        parse_table_build.setScopedProgressEnabled(true);
        parse_table_pipeline.setScopedProgressEnabled(true);
    }
    defer if (scoped_parse_table_progress) {
        parse_table_build.setScopedProgressEnabled(false);
        parse_table_pipeline.setScopedProgressEnabled(false);
    };

    var parse_construct_profile = parse_table_build.ConstructProfile{};
    const serialized = parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena.allocator(),
        prepared,
        .diagnostic,
        .{ .construct_profile = &parse_construct_profile },
    ) catch |err| {
        return failRun(
            &run,
            .serialize,
            .failed_due_to_parser_only_gap,
            .parse_table_construction_gap,
            try std.fmt.allocPrint(allocator, "serialize failed: {s}", .{@errorName(err)}),
        );
    };
    run.serialize.status = .passed;
    if (shouldStopAfter(options, .serialize)) return run;

    const parser_tables = parser_tables_emit.emitSerializedTableAllocWithOptions(arena.allocator(), serialized, options.optimize) catch |err| {
        return failRun(
            &run,
            .emit_parser_tables,
            .failed_due_to_parser_only_gap,
            .emitted_surface_structural_gap,
            try std.fmt.allocPrint(allocator, "parser-table emission failed: {s}", .{@errorName(err)}),
        );
    };
    run.emit_parser_tables.status = .passed;
    if (shouldStopAfter(options, .emit_parser_tables)) return run;

    const parser_c_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const parser_c = parser_c_emit.emitParserCAllocWithOptions(arena.allocator(), serialized, options.optimize) catch |err| {
        return failRun(
            &run,
            .emit_parser_c,
            .failed_due_to_parser_only_gap,
            .emitted_surface_structural_gap,
            try std.fmt.allocPrint(allocator, "parser.c emission failed: {s}", .{@errorName(err)}),
        );
    };
    const parser_c_ms = elapsedMs(parser_c_timer);
    run.emit_parser_c.status = .passed;
    if (shouldStopAfter(options, .emit_parser_c)) return run;

    const emission_stats = try parser_c_emit.collectEmissionStatsWithOptions(arena.allocator(), serialized, options.optimize);
    run.emission = .{
        .blocked = emission_stats.blocked,
        .serialized_state_count = serialized.states.len,
        .emitted_state_count = emission_stats.state_count,
        .merged_state_count = emission_stats.merged_state_count,
        .action_entry_count = emission_stats.action_entry_count,
        .goto_entry_count = emission_stats.goto_entry_count,
        .unresolved_entry_count = emission_stats.unresolved_entry_count,
        .parser_tables_bytes = parser_tables.len,
        .parser_c_bytes = parser_c.len,
        .lex_function_bytes = mainLexFunctionBytes(parser_c),
        .keyword_lex_function_bytes = functionSpanBytes(
            parser_c,
            "static bool ts_lex_keywords(TSLexer *lexer, TSStateId state)",
            "static const TSLexerMode ts_lex_modes",
        ),
        .emit_parser_c_ms = if (options.profile_timings) parser_c_ms else null,
        .parse_construct_profile = parseConstructProfileSnapshot(parse_construct_profile),
        .lex = lexEmissionSnapshot(emission_stats.lex),
    };
    if (emission_stats.blocked) {
        const extracted = extract_tokens.extractTokens(arena.allocator(), prepared) catch |err| {
            return failRun(
                &run,
                .emit_parser_c,
                .infrastructure_failure,
                .infrastructure_failure,
                try std.fmt.allocPrint(allocator, "blocked-boundary replay extraction failed: {s}", .{@errorName(err)}),
            );
        };
        const build_result = parse_table_pipeline.buildStatesFromPrepared(arena.allocator(), prepared) catch |err| {
            return failRun(
                &run,
                .emit_parser_c,
                .infrastructure_failure,
                .infrastructure_failure,
                try std.fmt.allocPrint(allocator, "blocked-boundary replay build failed: {s}", .{@errorName(err)}),
            );
        };
        run.blocked_boundary = try buildBlockedBoundarySnapshotAlloc(allocator, serialized, extracted, build_result);
    }

    if (emission_stats.blocked != target.expected_blocked) {
        const blocked_summary = if (run.blocked_boundary) |blocked_boundary|
            try summarizeBlockedBoundaryAlloc(allocator, blocked_boundary)
        else
            try allocator.dupe(u8, "blocked boundary summary unavailable");
        defer allocator.free(blocked_summary);
        const blocked_category = if (run.blocked_boundary) |blocked_boundary|
            classifyBlockedBoundary(blocked_boundary)
        else
            result_model.MismatchCategory.emitted_surface_structural_gap;
        return failRun(
            &run,
            .emit_parser_c,
            .failed_due_to_parser_only_gap,
            blocked_category,
            try std.fmt.allocPrint(
                allocator,
                "unexpected blocked status: expected {}, got {}; {s}",
                .{ target.expected_blocked, emission_stats.blocked, blocked_summary },
            ),
        );
    }

    if (target.candidate_status == .deferred_parser_wave and emission_stats.blocked) {
        const blocked_boundary = run.blocked_boundary orelse {
            return failRun(
                &run,
                .emit_parser_c,
                .deferred_for_parser_boundary,
                .emitted_surface_structural_gap,
                try allocator.dupe(u8, "expected deferred parser boundary, but blocked boundary snapshot was unavailable"),
            );
        };
        const blocked_summary = try summarizeBlockedBoundaryAlloc(allocator, blocked_boundary);
        defer allocator.free(blocked_summary);
        return failRun(
            &run,
            .emit_parser_c,
            .deferred_for_parser_boundary,
            classifyBlockedBoundary(blocked_boundary),
            try std.fmt.allocPrint(
                allocator,
                "parser-wave target remains deferred at emit_parser_c: {s}",
                .{blocked_summary},
            ),
        );
    }

    if (target.candidate_status == .deferred_control_fixture and emission_stats.blocked) {
        run.final_classification = .frozen_control_fixture;
        run.mismatch_category = .intentional_control_fixture;
    }

    compat_checks.validateParserCCompatibilitySurface(parser_c) catch |err| {
        return failRun(
            &run,
            .compat_check,
            .failed_due_to_parser_only_gap,
            .emitted_surface_structural_gap,
            try std.fmt.allocPrint(allocator, "compatibility check failed: {s}", .{@errorName(err)}),
        );
    };
    run.compat_check.status = .passed;
    if (shouldStopAfter(options, .compat_check)) return run;

    const compile_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    var compile_result = compile_smoke.compileParserC(allocator, parser_c) catch |err| {
        return failRun(
            &run,
            .compile_smoke,
            .infrastructure_failure,
            .infrastructure_failure,
            try std.fmt.allocPrint(allocator, "compile-smoke infrastructure failure: {s}", .{@errorName(err)}),
        );
    };
    defer compile_result.deinit(allocator);

    switch (compile_result) {
        .success => |success| {
            if (options.profile_timings) {
                if (run.emission) |*emission| emission.compile_smoke_ms = elapsedMs(compile_timer);
            }
            if (run.emission) |*emission| emission.compile_smoke_max_rss_bytes = success.max_rss_bytes;
            run.compile_smoke.status = .passed;
            if (shouldStopAfter(options, .compile_smoke)) return run;
        },
        .compiler_error => |stderr| {
            return failRun(
                &run,
                .compile_smoke,
                .failed_due_to_parser_only_gap,
                .compile_smoke_failure,
                try std.fmt.allocPrint(allocator, "compiler rejected emitted parser.c:\n{s}", .{stderr}),
            );
        },
    }

    return run;
}

fn failRun(
    run: *result_model.TargetRunResult,
    stage: result_model.StepName,
    classification: result_model.FinalClassification,
    mismatch_category: result_model.MismatchCategory,
    detail: []const u8,
) !result_model.TargetRunResult {
    const step = stepForName(run, stage);
    step.status = .failed;
    step.detail = detail;
    run.first_failed_stage = stage;
    run.final_classification = classification;
    run.mismatch_category = mismatch_category;
    return run.*;
}

fn stepForName(run: *result_model.TargetRunResult, stage: result_model.StepName) *result_model.StepResult {
    return switch (stage) {
        .load => &run.load,
        .prepare => &run.prepare,
        .serialize => &run.serialize,
        .scanner_boundary_check => &run.scanner_boundary_check,
        .emit_parser_tables => &run.emit_parser_tables,
        .emit_parser_c => &run.emit_parser_c,
        .compat_check => &run.compat_check,
        .compile_smoke => &run.compile_smoke,
    };
}

fn isCompatibilitySafeValidResult(result: behavioral_harness.SimulationResult) bool {
    return switch (result) {
        .accepted => |accepted| accepted.consumed_bytes > 0 and accepted.shifted_tokens > 0,
        .rejected => |rejected| rejected.consumed_bytes > 0 and rejected.shifted_tokens > 0 and rejected.reason != .unresolved_decision and rejected.reason != .missing_goto,
    };
}

fn progressOf(result: behavioral_harness.SimulationResult) usize {
    return switch (result) {
        .accepted => |accepted| accepted.consumed_bytes,
        .rejected => |rejected| rejected.consumed_bytes,
    };
}

fn classifyLoadFailure(err: grammar_loader.LoaderError) result_model.FinalClassification {
    return switch (err) {
        error.IoFailure, error.ProcessFailure => .infrastructure_failure,
        else => .failed_due_to_parser_only_gap,
    };
}

fn mismatchCategoryForLoadFailure(err: grammar_loader.LoaderError) result_model.MismatchCategory {
    return switch (err) {
        error.IoFailure, error.ProcessFailure => .infrastructure_failure,
        else => .grammar_input_load_mismatch,
    };
}

fn summarizeBlockedBoundaryAlloc(
    allocator: std.mem.Allocator,
    snapshot: result_model.BlockedBoundarySnapshot,
) ![]const u8 {
    var samples = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (samples.items) |sample| allocator.free(sample);
        samples.deinit();
    }

    for (snapshot.samples) |sample| {
        try samples.append(try std.fmt.allocPrint(
            allocator,
            "state {d} {s}:{d} ({s}) {s} candidates={d} actions=[{s}]",
            .{
                sample.state_id,
                @tagName(sample.symbol_kind),
                sample.symbol_index,
                sample.symbol_name,
                sample.reason,
                sample.candidate_count,
                sample.candidate_actions_summary,
            },
        ));
    }

    var sample_text: std.Io.Writer.Allocating = .init(allocator);
    defer sample_text.deinit();
    for (samples.items, 0..) |sample, index| {
        if (index > 0) try sample_text.writer.writeAll("; ");
        try sample_text.writer.writeAll(sample);
    }

    const dominant_text = try formatDominantSignaturesAlloc(allocator, snapshot.dominant_signatures);
    defer allocator.free(dominant_text);

    return try std.fmt.allocPrint(
        allocator,
        "blocked boundary summary: states={d}, entries={d}, reasons={{shift_reduce:{d}, reduce_reduce_deferred:{d}, multiple_candidates:{d}, unsupported_action_mix:{d}}}, dominant_signatures=[{s}], samples=[{s}]",
        .{
            snapshot.unresolved_state_count,
            snapshot.unresolved_entry_count,
            snapshot.reasons.shift_reduce,
            snapshot.reasons.reduce_reduce_deferred,
            snapshot.reasons.multiple_candidates,
            snapshot.reasons.unsupported_action_mix,
            dominant_text,
            sample_text.writer.buffered(),
        },
    );
}

fn formatUnsupportedExternalFeaturesAlloc(
    allocator: std.mem.Allocator,
    features: []const scanner_serialize.UnsupportedExternalScannerFeature,
) ![]const u8 {
    var parts = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit();
    }

    for (features) |feature| {
        const part = switch (feature) {
            .missing_external_tokens => try allocator.dupe(u8, "missing_external_tokens"),
            .extra_symbols => |count| try std.fmt.allocPrint(allocator, "extra_symbols:{d}", .{count}),
        };
        try parts.append(part);
    }

    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    try text.writer.writeAll("external-scanner boundary remains blocked by unsupported features: ");
    for (parts.items, 0..) |part, index| {
        if (index > 0) try text.writer.writeAll(", ");
        try text.writer.writeAll(part);
    }
    return try text.toOwnedSlice();
}

fn classifyBlockedBoundary(
    snapshot: result_model.BlockedBoundarySnapshot,
) result_model.MismatchCategory {
    const reasons = snapshot.reasons;
    if (reasons.shift_reduce > 0 and
        reasons.reduce_reduce_deferred == 0 and
        reasons.multiple_candidates == 0 and
        reasons.unsupported_action_mix == 0)
    {
        return .shift_reduce_boundary;
    }
    return .parse_table_construction_gap;
}

fn buildBlockedBoundarySnapshotAlloc(
    allocator: std.mem.Allocator,
    serialized: @import("../parse_table/serialize.zig").SerializedTable,
    extracted: extract_tokens.ExtractedGrammars,
    build_result: parse_table_build.BuildResult,
) !result_model.BlockedBoundarySnapshot {
    var unresolved_state_count: usize = 0;
    var unresolved_entry_count: usize = 0;
    var reasons = result_model.BlockedBoundaryReasonCounts{};
    var samples = std.array_list.Managed(result_model.BlockedBoundarySample).init(allocator);
    defer samples.deinit();
    var signature_counts = std.array_list.Managed(result_model.BlockedBoundarySignature).init(allocator);
    defer {
        for (signature_counts.items) |signature| {
            allocator.free(signature.symbol_name);
            allocator.free(signature.reason);
            allocator.free(signature.candidate_actions_summary);
        }
        signature_counts.deinit();
    }

    for (serialized.states) |state_value| {
        if (state_value.unresolved.len == 0) continue;
        unresolved_state_count += 1;
        unresolved_entry_count += state_value.unresolved.len;

        for (state_value.unresolved) |entry| {
            switch (entry.reason) {
                .shift_reduce => reasons.shift_reduce += 1,
                .shift_reduce_expected => reasons.shift_reduce += 1,
                .reduce_reduce_deferred => reasons.reduce_reduce_deferred += 1,
                .reduce_reduce_expected => reasons.reduce_reduce_expected += 1,
                .multiple_candidates => reasons.multiple_candidates += 1,
                .unsupported_action_mix => reasons.unsupported_action_mix += 1,
            }

            const symbol_name = symbolNameFor(extracted, entry.symbol);
            const candidate_actions_summary = try formatCandidateActionsAlloc(allocator, extracted, build_result, entry.candidate_actions);
            defer allocator.free(candidate_actions_summary);
            try recordDominantSignature(allocator, &signature_counts, symbol_name, @tagName(entry.reason), candidate_actions_summary);

            if (samples.items.len < 6) {
                const symbol_parts = symbolParts(entry.symbol);
                try samples.append(.{
                    .state_id = state_value.id,
                    .symbol_kind = symbol_parts.kind,
                    .symbol_index = symbol_parts.index,
                    .symbol_name = try allocator.dupe(u8, symbol_name),
                    .reason = try allocator.dupe(u8, @tagName(entry.reason)),
                    .candidate_count = entry.candidate_actions.len,
                    .candidate_actions_summary = try allocator.dupe(u8, candidate_actions_summary),
                });
            }
        }
    }

    sortDominantSignatures(signature_counts.items);
    const dominant_len = @min(signature_counts.items.len, 8);
    const dominant_signatures = try allocator.alloc(result_model.BlockedBoundarySignature, dominant_len);
    for (signature_counts.items[0..dominant_len], 0..) |signature, index| {
        dominant_signatures[index] = .{
            .symbol_name = try allocator.dupe(u8, signature.symbol_name),
            .reason = try allocator.dupe(u8, signature.reason),
            .candidate_actions_summary = try allocator.dupe(u8, signature.candidate_actions_summary),
            .count = signature.count,
        };
    }

    return .{
        .unresolved_state_count = unresolved_state_count,
        .unresolved_entry_count = unresolved_entry_count,
        .reasons = reasons,
        .samples = try samples.toOwnedSlice(),
        .dominant_signatures = dominant_signatures,
    };
}

fn symbolNameFor(extracted: extract_tokens.ExtractedGrammars, symbol: @import("../ir/syntax_grammar.zig").SymbolRef) []const u8 {
    return switch (symbol) {
        .end => "end",
        .terminal => |index| if (index < extracted.lexical.variables.len)
            extracted.lexical.variables[index].name
        else
            "<unknown-terminal>",
        .non_terminal => |index| if (index < extracted.syntax.variables.len)
            extracted.syntax.variables[index].name
        else
            "<unknown-non-terminal>",
        .external => |index| if (index < extracted.syntax.external_tokens.len)
            extracted.syntax.external_tokens[index].name
        else
            "<unknown-external>",
    };
}

fn formatCandidateActionsAlloc(
    allocator: std.mem.Allocator,
    extracted: extract_tokens.ExtractedGrammars,
    build_result: parse_table_build.BuildResult,
    candidate_actions: []const @import("../parse_table/actions.zig").ParseAction,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    for (candidate_actions, 0..) |action, index| {
        if (index > 0) try out.writer.writeAll(", ");
        switch (action) {
            .shift => |state_id| try out.writer.print("shift:{d}", .{state_id}),
            .reduce => |production_id| {
                const label = productionLabelFor(extracted, build_result, production_id);
                try out.writer.print("reduce:{d}({s})", .{ production_id, label });
            },
            .accept => try out.writer.writeAll("accept"),
        }
    }

    return try out.toOwnedSlice();
}

fn productionLabelFor(
    extracted: extract_tokens.ExtractedGrammars,
    build_result: parse_table_build.BuildResult,
    production_id: u32,
) []const u8 {
    if (production_id >= build_result.productions.len) return "<unknown-production>";
    const production = build_result.productions[production_id];
    if (production.augmented) return "<augmented>";
    if (production.lhs >= extracted.syntax.variables.len) return "<unknown-lhs>";
    return extracted.syntax.variables[production.lhs].name;
}

fn recordDominantSignature(
    allocator: std.mem.Allocator,
    signatures: *std.array_list.Managed(result_model.BlockedBoundarySignature),
    symbol_name: []const u8,
    reason: []const u8,
    candidate_actions_summary: []const u8,
) !void {
    for (signatures.items) |*signature| {
        if (!std.mem.eql(u8, signature.symbol_name, symbol_name)) continue;
        if (!std.mem.eql(u8, signature.reason, reason)) continue;
        if (!std.mem.eql(u8, signature.candidate_actions_summary, candidate_actions_summary)) continue;
        signature.count += 1;
        return;
    }

    try signatures.append(.{
        .symbol_name = try allocator.dupe(u8, symbol_name),
        .reason = try allocator.dupe(u8, reason),
        .candidate_actions_summary = try allocator.dupe(u8, candidate_actions_summary),
        .count = 1,
    });
}

fn sortDominantSignatures(signatures: []result_model.BlockedBoundarySignature) void {
    std.mem.sort(result_model.BlockedBoundarySignature, signatures, {}, struct {
        fn lessThan(_: void, left: result_model.BlockedBoundarySignature, right: result_model.BlockedBoundarySignature) bool {
            if (left.count != right.count) return left.count > right.count;
            const name_order = std.mem.order(u8, left.symbol_name, right.symbol_name);
            if (name_order != .eq) return name_order == .lt;
            const action_order = std.mem.order(u8, left.candidate_actions_summary, right.candidate_actions_summary);
            if (action_order != .eq) return action_order == .lt;
            return std.mem.order(u8, left.reason, right.reason) == .lt;
        }
    }.lessThan);
}

fn formatDominantSignaturesAlloc(
    allocator: std.mem.Allocator,
    signatures: []const result_model.BlockedBoundarySignature,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    for (signatures, 0..) |signature, index| {
        if (index > 0) try out.writer.writeAll("; ");
        try out.writer.print(
            "{s} {s} actions=[{s}] count={d}",
            .{ signature.symbol_name, signature.reason, signature.candidate_actions_summary, signature.count },
        );
    }

    return try out.toOwnedSlice();
}

fn symbolParts(symbol: @import("../ir/syntax_grammar.zig").SymbolRef) struct {
    kind: result_model.BlockedSymbolKind,
    index: u32,
} {
    return switch (symbol) {
        .end => .{ .kind = .terminal, .index = 0 },
        .terminal => |index| .{ .kind = .terminal, .index = index },
        .non_terminal => |index| .{ .kind = .non_terminal, .index = index },
        .external => |index| .{ .kind = .external, .index = index },
    };
}

test "runStagedTargetsAlloc executes the staged parser-only shortlist" {
    const allocator = std.testing.allocator;

    const runs = try runStagedTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    try std.testing.expectEqual(@as(usize, 7), runs.len);

    for (runs) |run| {
        try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, run.final_classification);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.load.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.prepare.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.serialize.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.emit_parser_tables.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.emit_parser_c.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.compat_check.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.compile_smoke.status);
        try std.testing.expect(run.emission != null);
    }

    try std.testing.expectEqual(false, runs[0].emission.?.blocked);
    try std.testing.expectEqual(false, runs[1].emission.?.blocked);
    try std.testing.expectEqual(false, runs[2].emission.?.blocked);
    try std.testing.expectEqual(false, runs[3].emission.?.blocked);
    try std.testing.expectEqual(false, runs[4].emission.?.blocked);
    try std.testing.expectEqual(false, runs[5].emission.?.blocked);
    try std.testing.expectEqual(false, runs[6].emission.?.blocked);
}

test "runTarget reports infrastructure failures for missing files" {
    const allocator = std.testing.allocator;

    var run = try runTarget(allocator, .{
        .id = "missing",
        .display_name = "Missing",
        .grammar_path = "compat_targets/does_not_exist/grammar.json",
        .family = .parse_table_tiny,
        .source_kind = .grammar_json,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_first_wave,
        .notes = "missing file test",
        .success_criteria = "missing file should fail deterministically",
    }, .{});
    defer run.deinit(allocator);

    try std.testing.expectEqual(result_model.FinalClassification.infrastructure_failure, run.final_classification);
    try std.testing.expectEqual(result_model.MismatchCategory.infrastructure_failure, run.mismatch_category);
    try std.testing.expectEqual(result_model.StepName.load, run.first_failed_stage.?);
    try std.testing.expectEqual(result_model.StepStatus.failed, run.load.status);
}

test "runTarget reports out-of-scope classification for explicitly excluded candidates" {
    const allocator = std.testing.allocator;

    var run = try runTarget(allocator, .{
        .id = "excluded_scanner",
        .display_name = "Excluded Scanner",
        .grammar_path = "compat_targets/hidden_external_fields/grammar.json",
        .family = .hidden_external_fields,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .excluded_out_of_scope,
        .notes = "explicitly excluded compatibility case",
        .success_criteria = "stay excluded",
    }, .{});
    defer run.deinit(allocator);

    try std.testing.expectEqual(result_model.FinalClassification.out_of_scope_for_scanner_boundary, run.final_classification);
    try std.testing.expectEqual(result_model.MismatchCategory.out_of_scope_scanner_boundary, run.mismatch_category);
    try std.testing.expectEqual(result_model.StepName.load, run.first_failed_stage.?);
    try std.testing.expectEqual(result_model.StepStatus.failed, run.load.status);
}

test "runStagedTargetsAlloc can be rendered to a deterministic JSON report" {
    const allocator = std.testing.allocator;

    const runs = try cachedShortlistTargetsForTests();

    const json = try report_json.renderRunReportAlloc(allocator, runs);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"parse_table_tiny_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"repeat_choice_seq_js\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tree_sitter_ziggy_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tree_sitter_ziggy_schema_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hidden_external_fields_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hidden_external_fields_js\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"blocked_targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"symbol_set_alloc_bytes\"") != null);
}

test "runShortlistTargetsAlloc includes out-of-scope and deferred shortlist entries" {
    const runs = try cachedShortlistTargetsForTests();

    try std.testing.expectEqual(@as(usize, 24), runs.len);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[2].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[3].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[4].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[5].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[6].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[7].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[8].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[9].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.frozen_control_fixture, runs[10].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[11].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[12].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[13].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[14].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[15].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[16].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[17].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[18].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[19].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[20].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[21].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[22].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[23].final_classification);
}

test "runShortlistTargetsAlloc promotes the external Ziggy targets, tree_sitter_c, and keeps only staged blocked controls" {
    const runs = try cachedShortlistTargetsForTests();

    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[2].mismatch_category);
    try std.testing.expect(runs[2].blocked_boundary != null);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[2].final_classification);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[3].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[4].mismatch_category);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[3].blocked_boundary);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[4].blocked_boundary);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[3].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[4].final_classification);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[4].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[4].emit_parser_tables.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[4].emit_parser_c.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[4].compat_check.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[4].compile_smoke.status);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[5].mismatch_category);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[5].blocked_boundary);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[5].final_classification);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].emit_parser_tables.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].emit_parser_c.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].compat_check.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].compile_smoke.status);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[6].mismatch_category);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[6].blocked_boundary);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[6].final_classification);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[6].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[6].emit_parser_tables.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[6].emit_parser_c.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[6].compat_check.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[6].compile_smoke.status);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[7].mismatch_category);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[7].blocked_boundary);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[8].mismatch_category);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[8].blocked_boundary);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[9].mismatch_category);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[9].blocked_boundary);
    try std.testing.expectEqual(result_model.MismatchCategory.intentional_control_fixture, runs[10].mismatch_category);
    try std.testing.expect(runs[10].blocked_boundary != null);
    try std.testing.expectEqual(@as(usize, 1), runs[10].blocked_boundary.?.reasons.shift_reduce);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[11].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[12].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[13].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[14].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[15].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[16].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[17].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[18].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[19].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[20].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[21].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[22].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[23].mismatch_category);
}

test "runShortlistTargetsAlloc promotes tree_sitter_c through compile smoke" {
    const runs = try cachedShortlistTargetsForTests();

    try std.testing.expectEqualStrings("tree_sitter_c_json", runs[5].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_first_wave, runs[5].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].emit_parser_tables.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].emit_parser_c.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].compat_check.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[5].compile_smoke.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[5].final_classification);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[5].mismatch_category);
}

test "runShortlistTargetsAlloc promotes tree_sitter_haskell through runtime link" {
    const runs = try cachedShortlistTargetsForTests();

    try std.testing.expectEqualStrings("tree_sitter_haskell_json", runs[8].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[8].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[8].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[8].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[8].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[8].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[8].final_classification);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[8].mismatch_category);
    try std.testing.expectEqual(targets.BoundaryKind.scanner_external_scanner, runs[8].boundary_kind);
    try std.testing.expectEqual(targets.RealExternalScannerProofScope.full_runtime_link, runs[8].real_external_scanner_proof_scope);
    try std.testing.expect(std.mem.indexOf(u8, runs[8].success_criteria, "runtime-link fixture") != null);
}

test "runShortlistTargetsAlloc promotes tree_sitter_bash through runtime link" {
    const runs = try cachedShortlistTargetsForTests();

    try std.testing.expectEqualStrings("tree_sitter_bash_json", runs[9].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[9].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[9].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[9].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[9].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[9].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[9].final_classification);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[9].mismatch_category);
    try std.testing.expectEqual(targets.BoundaryKind.scanner_external_scanner, runs[9].boundary_kind);
    try std.testing.expectEqual(targets.RealExternalScannerProofScope.full_runtime_link, runs[9].real_external_scanner_proof_scope);
    try std.testing.expect(std.mem.indexOf(u8, runs[9].success_criteria, "runtime-link fixture") != null);
}

test "runShortlistTargetsAlloc keeps parse_table_conflict as an explicit blocked control case" {
    const runs = try cachedShortlistTargetsForTests();

    try std.testing.expectEqualStrings("parse_table_conflict_json", runs[10].id);
    try std.testing.expectEqual(targets.CandidateStatus.deferred_control_fixture, runs[10].candidate_status);
    try std.testing.expectEqual(result_model.FinalClassification.frozen_control_fixture, runs[10].final_classification);
    try std.testing.expectEqual(result_model.MismatchCategory.intentional_control_fixture, runs[10].mismatch_category);
    try std.testing.expectEqual(true, runs[10].expected_blocked);
    try std.testing.expect(runs[10].blocked_boundary != null);
    try std.testing.expectEqual(@as(usize, 1), runs[10].blocked_boundary.?.unresolved_entry_count);
    try std.testing.expectEqualStrings("+", runs[10].blocked_boundary.?.samples[0].symbol_name);
    try std.testing.expect(std.mem.indexOf(u8, runs[10].blocked_boundary.?.samples[0].candidate_actions_summary, "reduce:2(expr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, runs[10].notes, "intentionally ambiguous") != null);
}

test "runShortlistTargetsAlloc promotes scanner-wave targets through the staged scanner boundary" {
    const runs = try cachedShortlistTargetsForTests();

    try std.testing.expectEqualStrings("bracket_lang_json", runs[11].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[11].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[11].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[11].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[11].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[11].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[11].final_classification);
    try std.testing.expect(std.mem.indexOf(u8, runs[11].success_criteria, "nested item tree") != null);

    try std.testing.expectEqualStrings("hidden_external_fields_json", runs[12].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[12].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[12].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[12].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[12].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[12].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[12].final_classification);
    try std.testing.expect(std.mem.indexOf(u8, runs[12].success_criteria, "invalid path makes less progress") != null);

    try std.testing.expectEqualStrings("hidden_external_fields_js", runs[13].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[13].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[13].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[13].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[13].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[13].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[13].final_classification);
    try std.testing.expect(std.mem.indexOf(u8, runs[13].success_criteria, "invalid path makes less progress") != null);

    try std.testing.expectEqualStrings("mixed_semantics_json", runs[14].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[14].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[14].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[14].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[14].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[14].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[14].final_classification);
    try std.testing.expect(std.mem.indexOf(u8, runs[14].notes, "extras present elsewhere in the grammar") != null);

    try std.testing.expectEqualStrings("mixed_semantics_js", runs[15].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[15].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[15].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[15].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[15].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[15].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[15].final_classification);
    try std.testing.expect(std.mem.indexOf(u8, runs[15].success_criteria, "without depending on extras") != null);

    try std.testing.expectEqualStrings("tree_sitter_typescript_scanner_json", runs[21].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[21].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[21].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[21].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[21].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[21].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[21].final_classification);
    try std.testing.expect(std.mem.indexOf(u8, runs[21].success_criteria, "_ternary_qmark") != null);

    try std.testing.expectEqualStrings("tree_sitter_rust_scanner_json", runs[23].id);
    try std.testing.expectEqual(targets.CandidateStatus.intended_scanner_wave, runs[23].candidate_status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[23].load.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[23].prepare.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[23].serialize.status);
    try std.testing.expectEqual(result_model.StepStatus.passed, runs[23].scanner_boundary_check.status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[23].final_classification);
    try std.testing.expect(std.mem.indexOf(u8, runs[23].success_criteria, "float_literal") != null);
}

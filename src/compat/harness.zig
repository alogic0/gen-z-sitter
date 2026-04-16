const std = @import("std");
const targets = @import("targets.zig");
const result_model = @import("result.zig");
const compile_smoke = @import("compile_smoke.zig");
const report_json = @import("report_json.zig");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const parser_tables_emit = @import("../parser_emit/parser_tables.zig");
const c_tables_emit = @import("../parser_emit/c_tables.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const compat_checks = @import("../parser_emit/compat_checks.zig");
const emit_optimize = @import("../parser_emit/optimize.zig");

pub const RunOptions = struct {
    optimize: emit_optimize.Options = .{},
};

pub fn runShortlistTargetsAlloc(
    allocator: std.mem.Allocator,
    options: RunOptions,
) ![]result_model.TargetRunResult {
    return try runTargetsAlloc(allocator, targets.shortlistTargets(), options);
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
    const runs = try allocator.alloc(result_model.TargetRunResult, target_list.len);
    errdefer allocator.free(runs);

    for (target_list, 0..) |target, index| {
        runs[index] = try runTarget(allocator, target, options);
    }

    return runs;
}

pub fn runTarget(
    allocator: std.mem.Allocator,
    target: targets.Target,
    options: RunOptions,
) !result_model.TargetRunResult {
    var run = result_model.TargetRunResult.init(target);
    errdefer run.deinit(allocator);

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

    var loaded = grammar_loader.loadGrammarFile(arena.allocator(), target.grammar_path) catch |err| {
        return failRun(
            &run,
            .load,
            classifyLoadFailure(err),
            mismatchCategoryForLoadFailure(err),
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ target.grammar_path, grammar_loader.errorMessage(err) }),
        );
    };
    run.load.status = .passed;
    defer loaded.deinit();

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
    run.prepare.status = .passed;

    const serialized = parse_table_pipeline.serializeTableFromPrepared(arena.allocator(), prepared, .diagnostic) catch |err| {
        return failRun(
            &run,
            .serialize,
            .failed_due_to_parser_only_gap,
            .parse_table_construction_gap,
            try std.fmt.allocPrint(allocator, "serialize failed: {s}", .{@errorName(err)}),
        );
    };
    run.serialize.status = .passed;

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

    const c_tables = c_tables_emit.emitCTableSkeletonAllocWithOptions(arena.allocator(), serialized, options.optimize) catch |err| {
        return failRun(
            &run,
            .emit_c_tables,
            .failed_due_to_parser_only_gap,
            .emitted_surface_structural_gap,
            try std.fmt.allocPrint(allocator, "C-table emission failed: {s}", .{@errorName(err)}),
        );
    };
    run.emit_c_tables.status = .passed;

    const parser_c = parser_c_emit.emitParserCAllocWithOptions(arena.allocator(), serialized, options.optimize) catch |err| {
        return failRun(
            &run,
            .emit_parser_c,
            .failed_due_to_parser_only_gap,
            .emitted_surface_structural_gap,
            try std.fmt.allocPrint(allocator, "parser.c emission failed: {s}", .{@errorName(err)}),
        );
    };
    run.emit_parser_c.status = .passed;

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
        .c_tables_bytes = c_tables.len,
        .parser_c_bytes = parser_c.len,
    };

    if (emission_stats.blocked != target.expected_blocked) {
        const blocked_summary = try summarizeBlockedBoundaryAlloc(allocator, serialized);
        defer allocator.free(blocked_summary);
        const blocked_category = classifyBlockedBoundary(serialized);
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
        .success => {
            run.compile_smoke.status = .passed;
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
        .emit_parser_tables => &run.emit_parser_tables,
        .emit_c_tables => &run.emit_c_tables,
        .emit_parser_c => &run.emit_parser_c,
        .compat_check => &run.compat_check,
        .compile_smoke => &run.compile_smoke,
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
    serialized: @import("../parse_table/serialize.zig").SerializedTable,
) ![]const u8 {
    var unresolved_states: usize = 0;
    var unresolved_entries: usize = 0;
    var shift_reduce: usize = 0;
    var reduce_reduce_deferred: usize = 0;
    var multiple_candidates: usize = 0;
    var unsupported_action_mix: usize = 0;

    var samples = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (samples.items) |sample| allocator.free(sample);
        samples.deinit();
    }

    for (serialized.states) |state_value| {
        if (state_value.unresolved.len == 0) continue;
        unresolved_states += 1;
        unresolved_entries += state_value.unresolved.len;

        for (state_value.unresolved) |entry| {
            switch (entry.reason) {
                .shift_reduce => shift_reduce += 1,
                .reduce_reduce_deferred => reduce_reduce_deferred += 1,
                .multiple_candidates => multiple_candidates += 1,
                .unsupported_action_mix => unsupported_action_mix += 1,
            }

            if (samples.items.len < 4) {
                try samples.append(try std.fmt.allocPrint(
                    allocator,
                    "state {d} {s} {s} candidates={d}",
                    .{
                        state_value.id,
                        symbolRefLabel(entry.symbol),
                        @tagName(entry.reason),
                        entry.candidate_actions.len,
                    },
                ));
            }
        }
    }

    var sample_text = std.array_list.Managed(u8).init(allocator);
    defer sample_text.deinit();
    const sample_writer = sample_text.writer();
    for (samples.items, 0..) |sample, index| {
        if (index > 0) try sample_writer.writeAll("; ");
        try sample_writer.writeAll(sample);
    }

    return try std.fmt.allocPrint(
        allocator,
        "blocked boundary summary: states={d}, entries={d}, reasons={{shift_reduce:{d}, reduce_reduce_deferred:{d}, multiple_candidates:{d}, unsupported_action_mix:{d}}}, samples=[{s}]",
        .{
            unresolved_states,
            unresolved_entries,
            shift_reduce,
            reduce_reduce_deferred,
            multiple_candidates,
            unsupported_action_mix,
            sample_text.items,
        },
    );
}

fn classifyBlockedBoundary(
    serialized: @import("../parse_table/serialize.zig").SerializedTable,
) result_model.MismatchCategory {
    var saw_unresolved = false;
    for (serialized.states) |state_value| {
        for (state_value.unresolved) |entry| {
            saw_unresolved = true;
            if (entry.reason != .shift_reduce) return .parse_table_construction_gap;
        }
    }

    if (saw_unresolved) return .shift_reduce_boundary;
    return .parse_table_construction_gap;
}

fn symbolRefLabel(symbol: @import("../ir/syntax_grammar.zig").SymbolRef) []const u8 {
    return switch (symbol) {
        .terminal => "terminal",
        .non_terminal => "non_terminal",
        .external => "external",
    };
}

test "runStagedTargetsAlloc executes the staged parser-only shortlist" {
    const allocator = std.testing.allocator;

    const runs = try runStagedTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    try std.testing.expectEqual(@as(usize, 3), runs.len);

    for (runs) |run| {
        try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, run.final_classification);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.load.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.prepare.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.serialize.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.emit_parser_tables.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.emit_c_tables.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.emit_parser_c.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.compat_check.status);
        try std.testing.expectEqual(result_model.StepStatus.passed, run.compile_smoke.status);
        try std.testing.expect(run.emission != null);
    }

    try std.testing.expectEqual(false, runs[0].emission.?.blocked);
    try std.testing.expectEqual(false, runs[1].emission.?.blocked);
    try std.testing.expectEqual(true, runs[2].emission.?.blocked);
}

test "runTarget reports infrastructure failures for missing files" {
    const allocator = std.testing.allocator;

    var run = try runTarget(allocator, .{
        .id = "missing",
        .display_name = "Missing",
        .grammar_path = "compat_targets/does_not_exist/grammar.json",
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

test "runTarget reports out-of-scope classification for excluded shortlist candidates" {
    const allocator = std.testing.allocator;

    const shortlist = targets.shortlistTargets();
    var excluded_target: ?targets.Target = null;
    for (shortlist) |target| {
        if (target.candidate_status == .excluded_out_of_scope) {
            excluded_target = target;
            break;
        }
    }

    var run = try runTarget(allocator, excluded_target.?, .{});
    defer run.deinit(allocator);

    try std.testing.expectEqual(result_model.FinalClassification.out_of_scope_for_scanner_boundary, run.final_classification);
    try std.testing.expectEqual(result_model.MismatchCategory.out_of_scope_scanner_boundary, run.mismatch_category);
    try std.testing.expectEqual(result_model.StepName.load, run.first_failed_stage.?);
    try std.testing.expectEqual(result_model.StepStatus.failed, run.load.status);
}

test "runStagedTargetsAlloc can be rendered to a deterministic JSON report" {
    const allocator = std.testing.allocator;

    const runs = try runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const json = try report_json.renderRunReportAlloc(allocator, runs);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"parse_table_tiny_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"repeat_choice_seq_js\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tree_sitter_ziggy_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tree_sitter_ziggy_schema_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hidden_external_fields_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"blocked_targets\"") != null);
}

test "runShortlistTargetsAlloc includes out-of-scope and deferred shortlist entries" {
    const allocator = std.testing.allocator;

    const runs = try runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    try std.testing.expectEqual(@as(usize, 7), runs.len);
    try std.testing.expectEqual(result_model.FinalClassification.failed_due_to_parser_only_gap, runs[3].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.failed_due_to_parser_only_gap, runs[4].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.out_of_scope_for_scanner_boundary, runs[6].final_classification);
}

test "runShortlistTargetsAlloc records blocked-boundary summaries for deferred Ziggy targets" {
    const allocator = std.testing.allocator;

    const runs = try runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    try std.testing.expectEqual(result_model.MismatchCategory.shift_reduce_boundary, runs[3].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.shift_reduce_boundary, runs[4].mismatch_category);
    try std.testing.expect(runs[3].emit_parser_c.detail != null);
    try std.testing.expect(runs[4].emit_parser_c.detail != null);
    try std.testing.expect(std.mem.indexOf(u8, runs[3].emit_parser_c.detail.?, "blocked boundary summary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, runs[4].emit_parser_c.detail.?, "blocked boundary summary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, runs[3].emit_parser_c.detail.?, "shift_reduce") != null);
    try std.testing.expect(std.mem.indexOf(u8, runs[4].emit_parser_c.detail.?, "shift_reduce") != null);
}

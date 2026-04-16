const std = @import("std");
const targets = @import("targets.zig");
const result_model = @import("result.zig");
const compile_smoke = @import("compile_smoke.zig");
const report_json = @import("report_json.zig");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const parse_table_build = @import("../parse_table/build.zig");
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
        const blocked_summary = try summarizeBlockedBoundaryAlloc(allocator, run.blocked_boundary.?);
        defer allocator.free(blocked_summary);
        const blocked_category = classifyBlockedBoundary(run.blocked_boundary.?);
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

    var sample_text = std.array_list.Managed(u8).init(allocator);
    defer sample_text.deinit();
    const sample_writer = sample_text.writer();
    for (samples.items, 0..) |sample, index| {
        if (index > 0) try sample_writer.writeAll("; ");
        try sample_writer.writeAll(sample);
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
            sample_text.items,
        },
    );
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
                .reduce_reduce_deferred => reasons.reduce_reduce_deferred += 1,
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
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    const writer = out.writer();
    for (candidate_actions, 0..) |action, index| {
        if (index > 0) try writer.writeAll(", ");
        switch (action) {
            .shift => |state_id| try writer.print("shift:{d}", .{state_id}),
            .reduce => |production_id| {
                const label = productionLabelFor(extracted, build_result, production_id);
                try writer.print("reduce:{d}({s})", .{ production_id, label });
            },
            .accept => try writer.writeAll("accept"),
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
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    const writer = out.writer();
    for (signatures, 0..) |signature, index| {
        if (index > 0) try writer.writeAll("; ");
        try writer.print(
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
        .terminal => |index| .{ .kind = .terminal, .index = index },
        .non_terminal => |index| .{ .kind = .non_terminal, .index = index },
        .external => |index| .{ .kind = .external, .index = index },
    };
}

test "runStagedTargetsAlloc executes the staged parser-only shortlist" {
    const allocator = std.testing.allocator;

    const runs = try runStagedTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    try std.testing.expectEqual(@as(usize, 5), runs.len);

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
    try std.testing.expectEqual(false, runs[3].emission.?.blocked);
    try std.testing.expectEqual(false, runs[4].emission.?.blocked);
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
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[3].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[4].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.out_of_scope_for_scanner_boundary, runs[6].final_classification);
}

test "runShortlistTargetsAlloc promotes the external Ziggy targets and keeps only staged blocked controls" {
    const allocator = std.testing.allocator;

    const runs = try runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[3].mismatch_category);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[4].mismatch_category);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[3].blocked_boundary);
    try std.testing.expectEqual(@as(?result_model.BlockedBoundarySnapshot, null), runs[4].blocked_boundary);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[3].final_classification);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[4].final_classification);
    try std.testing.expect(runs[5].blocked_boundary != null);
    try std.testing.expectEqual(result_model.MismatchCategory.none, runs[5].mismatch_category);
    try std.testing.expectEqual(@as(usize, 1), runs[5].blocked_boundary.?.reasons.shift_reduce);
}

test "runShortlistTargetsAlloc keeps parse_table_conflict as an explicit blocked control case" {
    const allocator = std.testing.allocator;

    const runs = try runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    try std.testing.expectEqualStrings("parse_table_conflict_json", runs[5].id);
    try std.testing.expectEqual(targets.CandidateStatus.deferred_later_wave, runs[5].candidate_status);
    try std.testing.expectEqual(result_model.FinalClassification.passed_within_current_boundary, runs[5].final_classification);
    try std.testing.expectEqual(true, runs[5].expected_blocked);
    try std.testing.expect(runs[5].blocked_boundary != null);
    try std.testing.expectEqual(@as(usize, 1), runs[5].blocked_boundary.?.unresolved_entry_count);
    try std.testing.expectEqualStrings("expr", runs[5].blocked_boundary.?.samples[0].symbol_name);
    try std.testing.expect(std.mem.indexOf(u8, runs[5].blocked_boundary.?.samples[0].candidate_actions_summary, "reduce:2(expr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, runs[5].notes, "intentionally ambiguous") != null);
}

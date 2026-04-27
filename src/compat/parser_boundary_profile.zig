const std = @import("std");
const json_support = @import("../support/json.zig");
const grammar_loader = @import("../grammar/loader.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const GrammarShapeMetrics = struct {
    rule_count: usize,
    precedence_count: usize,
    conflict_count: usize,
    external_count: usize,
    extra_count: usize,
    inline_rule_count: usize,
    supertype_count: usize,
    reserved_set_count: usize,
    has_word_token: bool,
    word_token: ?[]const u8,
};

pub const ParserBoundaryProfileEntry = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    family: targets.TargetFamily,
    parser_boundary_check_mode: targets.ParserBoundaryCheckMode,
    next_parser_boundary_check_mode: targets.ParserBoundaryCheckMode,
    candidate_status: targets.CandidateStatus,
    final_classification: result_model.FinalClassification,
    mismatch_category: result_model.MismatchCategory,
    current_proven_steps: []const result_model.StepName,
    deferred_from_step: result_model.StepName,
    not_run_steps: []const result_model.StepName,
    detail: []const u8,
    grammar_shape: GrammarShapeMetrics,
};

pub const ParserBoundaryProfileReport = struct {
    schema_version: u32,
    target_count: usize,
    entries: []ParserBoundaryProfileEntry,

    pub fn deinit(self: *ParserBoundaryProfileReport, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.display_name);
            allocator.free(entry.grammar_path);
            allocator.free(entry.current_proven_steps);
            allocator.free(entry.not_run_steps);
            allocator.free(entry.detail);
            if (entry.grammar_shape.word_token) |word_token| allocator.free(word_token);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub fn buildParserBoundaryProfileAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !ParserBoundaryProfileReport {
    var entries = std.array_list.Managed(ParserBoundaryProfileEntry).init(allocator);
    defer entries.deinit();

    for (runs) |run| {
        if (run.candidate_status != .deferred_parser_wave) continue;
        try entries.append(try buildEntryAlloc(allocator, run));
    }

    const owned = try entries.toOwnedSlice();
    return .{
        .schema_version = 1,
        .target_count = owned.len,
        .entries = owned,
    };
}

pub fn renderParserBoundaryProfileAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildParserBoundaryProfileAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

fn buildEntryAlloc(
    allocator: std.mem.Allocator,
    run: result_model.TargetRunResult,
) !ParserBoundaryProfileEntry {
    const current_proven_steps = try collectStepsAlloc(allocator, run, .passed);
    const not_run_steps = try collectStepsAlloc(allocator, run, .not_run);
    errdefer allocator.free(current_proven_steps);
    errdefer allocator.free(not_run_steps);

    const failure_detail = switch (run.first_failed_stage.?) {
        .load => run.load.detail.?,
        .prepare => run.prepare.detail.?,
        .serialize => run.serialize.detail.?,
        .scanner_boundary_check => run.scanner_boundary_check.detail.?,
        .emit_parser_tables => run.emit_parser_tables.detail.?,
        .emit_parser_c => run.emit_parser_c.detail.?,
        .compat_check => run.compat_check.detail.?,
        .compile_smoke => run.compile_smoke.detail.?,
    };

    const grammar_shape = try collectGrammarShapeMetricsAlloc(allocator, run.grammar_path);

    return .{
        .id = try allocator.dupe(u8, run.id),
        .display_name = try allocator.dupe(u8, run.display_name),
        .grammar_path = try allocator.dupe(u8, run.grammar_path),
        .family = run.family,
        .parser_boundary_check_mode = run.parser_boundary_check_mode,
        .next_parser_boundary_check_mode = switch (run.parser_boundary_check_mode) {
            .prepare_only => .serialize_only,
            .serialize_only => .full_pipeline,
            else => run.parser_boundary_check_mode,
        },
        .candidate_status = run.candidate_status,
        .final_classification = run.final_classification,
        .mismatch_category = run.mismatch_category,
        .current_proven_steps = current_proven_steps,
        .deferred_from_step = run.first_failed_stage.?,
        .not_run_steps = not_run_steps,
        .detail = if (run.mismatch_category == .routine_serialize_proof_boundary)
            try std.fmt.allocPrint(
                allocator,
                "routine lookahead-sensitive serialize proof is still deferred for {s}: the shortlist stays at prepare_only, while the only passing next proof remains the standalone coarse serialize-only probe",
                .{run.id},
            )
        else if (run.mismatch_category == .routine_emitted_surface_proof_boundary)
            try std.fmt.allocPrint(
                allocator,
                "routine coarse serialize-only proof, parser-table emission, C-table emission, parser.c emission, and compatibility validation now pass for {s}, but broader emitted parser surfaces remain deferred because no routine-safe next emitted-surface step is promoted yet",
                .{run.id},
            )
        else
            try allocator.dupe(u8, failure_detail),
        .grammar_shape = grammar_shape,
    };
}

fn collectGrammarShapeMetricsAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
) !GrammarShapeMetrics {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var loaded = try grammar_loader.loadGrammarFile(arena.allocator(), grammar_path);
    defer loaded.deinit();

    const grammar = loaded.json.grammar;
    return .{
        .rule_count = grammar.ruleCount(),
        .precedence_count = grammar.precedences.len,
        .conflict_count = grammar.expected_conflicts.len,
        .external_count = grammar.externals.len,
        .extra_count = grammar.extras.len,
        .inline_rule_count = grammar.inline_rules.len,
        .supertype_count = grammar.supertypes.len,
        .reserved_set_count = grammar.reserved.len,
        .has_word_token = grammar.word != null,
        .word_token = if (grammar.word) |word| try allocator.dupe(u8, word) else null,
    };
}

fn collectStepsAlloc(
    allocator: std.mem.Allocator,
    run: result_model.TargetRunResult,
    status: result_model.StepStatus,
) ![]result_model.StepName {
    var items = std.array_list.Managed(result_model.StepName).init(allocator);
    defer items.deinit();

    inline for ([_]result_model.StepName{
        .load,
        .prepare,
        .serialize,
        .emit_parser_tables,
        .emit_parser_c,
        .scanner_boundary_check,
        .compat_check,
        .compile_smoke,
    }) |step_name| {
        const step = switch (step_name) {
            .load => run.load,
            .prepare => run.prepare,
            .serialize => run.serialize,
            .emit_parser_tables => run.emit_parser_tables,
            .emit_parser_c => run.emit_parser_c,
            .scanner_boundary_check => run.scanner_boundary_check,
            .compat_check => run.compat_check,
            .compile_smoke => run.compile_smoke,
        };
        if (step.status == status) try items.append(step_name);
    }

    return try items.toOwnedSlice();
}

test "buildParserBoundaryProfileAlloc summarizes deferred parser-only targets" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    var report = try buildParserBoundaryProfileAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), report.target_count);
    try std.testing.expectEqual(@as(usize, 4), report.entries.len);
}

test "renderParserBoundaryProfileAlloc matches the checked-in parser boundary profile artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    const rendered = try renderParserBoundaryProfileAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "compat_targets/parser_boundary_profile.json", allocator, .limited(1024 * 1024));
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimEnd(u8, expected, "\n");
    const normalized_rendered = std.mem.trimEnd(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

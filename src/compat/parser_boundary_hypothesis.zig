const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const EvaluationSurface = enum {
    routine_refresh,
    standalone_probe,
};

pub const HypothesisDecision = enum {
    keep_standalone_probe,
    promote_to_routine_refresh,
    freeze_current_boundary,
};

pub const RoutineBoundaryHypothesis = enum {
    no_safe_routine_step_yet,
    candidate_exists,
};

pub const StandaloneProbeStatus = enum {
    not_implemented,
    implemented_passing,
};

pub const ParserBoundaryHypothesisEntry = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    family: targets.TargetFamily,
    current_parser_boundary_check_mode: targets.ParserBoundaryCheckMode,
    proposed_parser_boundary_check_mode: targets.ParserBoundaryCheckMode,
    evaluation_surface: EvaluationSurface,
    routine_refresh_safe: bool,
    routine_boundary_hypothesis: RoutineBoundaryHypothesis,
    routine_refresh_candidate_mode: ?targets.ParserBoundaryCheckMode,
    routine_refresh_blocker: ?[]const u8,
    singleton_parser_wave: bool,
    current_proven_steps: []const result_model.StepName,
    deferred_from_step: result_model.StepName,
    standalone_probe_status: StandaloneProbeStatus,
    standalone_probe_detail: ?[]const u8,
    measured_standalone_serialized_state_count: ?usize,
    decision: HypothesisDecision,
    rationale: []const u8,
};

pub const ParserBoundaryHypothesisReport = struct {
    schema_version: u32,
    deferred_parser_wave_target_count: usize,
    singleton_parser_wave: bool,
    entries: []ParserBoundaryHypothesisEntry,

    pub fn deinit(self: *ParserBoundaryHypothesisReport, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.display_name);
            allocator.free(entry.grammar_path);
            allocator.free(entry.current_proven_steps);
            if (entry.routine_refresh_blocker) |detail| allocator.free(detail);
            if (entry.standalone_probe_detail) |detail| allocator.free(detail);
            allocator.free(entry.rationale);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub fn buildParserBoundaryHypothesisAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !ParserBoundaryHypothesisReport {
    const deferred_count = countDeferredParserWave(runs);
    const singleton = deferred_count == 1;

    var entries = std.array_list.Managed(ParserBoundaryHypothesisEntry).init(allocator);
    defer entries.deinit();

    for (runs) |run| {
        if (run.candidate_status != .deferred_parser_wave) continue;
        try entries.append(try buildEntryAlloc(allocator, run, singleton));
    }

    const owned = try entries.toOwnedSlice();
    return .{
        .schema_version = 1,
        .deferred_parser_wave_target_count = deferred_count,
        .singleton_parser_wave = singleton,
        .entries = owned,
    };
}

pub fn renderParserBoundaryHypothesisAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildParserBoundaryHypothesisAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

fn countDeferredParserWave(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.candidate_status == .deferred_parser_wave) count += 1;
    }
    return count;
}

fn buildEntryAlloc(
    allocator: std.mem.Allocator,
    run: result_model.TargetRunResult,
    singleton_parser_wave: bool,
) !ParserBoundaryHypothesisEntry {
    const current_proven_steps = try collectPassedStepsAlloc(allocator, run);
    errdefer allocator.free(current_proven_steps);

    const proposed_mode: targets.ParserBoundaryCheckMode = switch (run.parser_boundary_check_mode) {
        .prepare_only => .serialize_only,
        .serialize_only => .full_pipeline,
        .full_pipeline => .full_pipeline,
    };

    const evaluation_surface: EvaluationSurface = switch (proposed_mode) {
        .serialize_only => .standalone_probe,
        .full_pipeline => .standalone_probe,
        else => .routine_refresh,
    };

    const routine_refresh_safe = false;
    const routine_boundary_hypothesis: RoutineBoundaryHypothesis = .no_safe_routine_step_yet;
    const routine_refresh_candidate_mode: ?targets.ParserBoundaryCheckMode = null;
    const routine_refresh_blocker = if (run.parser_boundary_check_mode == .serialize_only)
        try std.fmt.allocPrint(
            allocator,
            "no routine-safe full-pipeline parser step is promoted yet for {s}; routine coarse serialize-only proof, parser-table emission, C-table emission, parser.c emission, and compatibility validation now pass, but broader emitted parser surfaces remain deferred because there is still no routine-safe next emitted-surface step",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "tree_sitter_ziggy_schema_json"))
        try std.fmt.allocPrint(
            allocator,
            "no routine-safe parser boundary step is promoted yet for {s}; the current full-pipeline blocker is emit_parser_c with 5 unresolved shift/reduce entries dominated by doc_comment and struct_union, so the next useful step is direct upstream comparison instead of another routine-boundary promotion guess",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "repeat_choice_seq_js"))
        try std.fmt.allocPrint(
            allocator,
            "no routine-safe parser boundary step is promoted yet for {s}; the current full-pipeline blocker is an intentional 2-entry shift/reduce ambiguity where the next identifier/number token can either continue the current _entry tail or start the next repeated source_file entry, so the target stays deferred unless a later milestone deliberately broadens ambiguity handling",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "tree_sitter_javascript_json"))
        try std.fmt.allocPrint(
            allocator,
            "no routine-safe parser boundary step is promoted yet for {s}; the measured standalone coarse serialize-only probe reaches 1299 serialized states but remains blocked, while full lookahead-sensitive serialization stays outside the bounded routine compatibility budget",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "tree_sitter_python_json"))
        try std.fmt.allocPrint(
            allocator,
            "no routine-safe parser boundary step is promoted yet for {s}; the measured standalone coarse serialize-only probe reaches 1038 serialized states but remains blocked, while external-scanner runtime-link proof remains a later promotion step",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "tree_sitter_typescript_json"))
        try std.fmt.allocPrint(
            allocator,
            "no routine-safe parser boundary step is promoted yet for {s}; the measured standalone coarse serialize-only probe reaches 5359 serialized states but remains blocked, so parser-table promotion needs a narrower follow-up",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "tree_sitter_rust_json"))
        try std.fmt.allocPrint(
            allocator,
            "no routine-safe parser boundary step is promoted yet for {s}; the measured standalone coarse serialize-only probe reaches 2659 serialized states but remains blocked, so parser-table promotion needs a narrower follow-up",
            .{run.id},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "no routine-safe parser boundary step is promoted yet for {s}; the only measured next proof is a standalone coarse serialize-only probe with 2336 serialized states, and that still stops short of a routine lookahead-sensitive serialize claim",
            .{run.id},
        );
    const decision: HypothesisDecision = .keep_standalone_probe;
    const standalone_probe_status: StandaloneProbeStatus = if (std.mem.eql(u8, run.id, "tree_sitter_c_json") or std.mem.eql(u8, run.id, "tree_sitter_javascript_json") or std.mem.eql(u8, run.id, "tree_sitter_python_json") or std.mem.eql(u8, run.id, "tree_sitter_typescript_json") or std.mem.eql(u8, run.id, "tree_sitter_rust_json"))
        .implemented_passing
    else
        .not_implemented;
    const standalone_probe_detail = if (std.mem.eql(u8, run.id, "tree_sitter_javascript_json"))
        try std.fmt.allocPrint(
            allocator,
            "standalone coarse serialize-only probe is implemented and reaches 1299 serialized states for {s}, but records blocked=true, so routine lookahead-sensitive serialization remains deferred",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "tree_sitter_python_json"))
        try std.fmt.allocPrint(
            allocator,
            "standalone coarse serialize-only probe is implemented and reaches 1038 serialized states for {s}, but records blocked=true, so routine parser-table and external-scanner proofs remain deferred",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "tree_sitter_typescript_json"))
        try std.fmt.allocPrint(
            allocator,
            "standalone coarse serialize-only probe is implemented and reaches 5359 serialized states for {s}, but records blocked=true, so routine parser-table proof remains deferred",
            .{run.id},
        )
    else if (std.mem.eql(u8, run.id, "tree_sitter_rust_json"))
        try std.fmt.allocPrint(
            allocator,
            "standalone coarse serialize-only probe is implemented and reaches 2659 serialized states for {s}, but records blocked=true, so routine parser-table proof remains deferred",
            .{run.id},
        )
    else if (standalone_probe_status == .implemented_passing)
        try std.fmt.allocPrint(
            allocator,
            "standalone coarse serialize-only probe is implemented and currently passes for {s}; the checked-in parser boundary probe records serialized_state_count=2336 and blocked=false while keeping full lookahead-sensitive parser proof out of the routine boundary",
            .{run.id},
        )
    else
        null;
    const rationale = if (std.mem.eql(u8, run.id, "tree_sitter_ziggy_schema_json"))
        try std.fmt.allocPrint(
            allocator,
            "the next named proof step for {s} is direct upstream comparison of the current emit_parser_c conflict set, not a broader routine refresh step; it remains scoped to {s} until the 5 unresolved shift/reduce entries are either fixed or explicitly proven to be a real staged-boundary limitation",
            .{ run.id, @tagName(evaluation_surface) },
        )
    else if (std.mem.eql(u8, run.id, "repeat_choice_seq_js"))
        try std.fmt.allocPrint(
            allocator,
            "the next named proof step for {s} is not a broader routine refresh; it remains scoped to {s} because the staged grammar intentionally keeps the current 2-entry shift/reduce ambiguity as a parser-boundary fixture rather than an upstream-mismatch candidate",
            .{ run.id, @tagName(evaluation_surface) },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "the next named proof step for {s} is {s}; it remains scoped to {s} because the routine compatibility refresh should stay fast and stable while this deferred parser-wave target is evaluated more narrowly, and no routine-safe next step beyond the current boundary is promoted yet",
            .{ run.id, @tagName(proposed_mode), @tagName(evaluation_surface) },
        );

    return .{
        .id = try allocator.dupe(u8, run.id),
        .display_name = try allocator.dupe(u8, run.display_name),
        .grammar_path = try allocator.dupe(u8, run.grammar_path),
        .family = run.family,
        .current_parser_boundary_check_mode = run.parser_boundary_check_mode,
        .proposed_parser_boundary_check_mode = proposed_mode,
        .evaluation_surface = evaluation_surface,
        .routine_refresh_safe = routine_refresh_safe,
        .routine_boundary_hypothesis = routine_boundary_hypothesis,
        .routine_refresh_candidate_mode = routine_refresh_candidate_mode,
        .routine_refresh_blocker = routine_refresh_blocker,
        .singleton_parser_wave = singleton_parser_wave,
        .current_proven_steps = current_proven_steps,
        .deferred_from_step = run.first_failed_stage.?,
        .standalone_probe_status = standalone_probe_status,
        .standalone_probe_detail = standalone_probe_detail,
        .measured_standalone_serialized_state_count = if (std.mem.eql(u8, run.id, "tree_sitter_javascript_json"))
            1299
        else if (std.mem.eql(u8, run.id, "tree_sitter_python_json"))
            1038
        else if (std.mem.eql(u8, run.id, "tree_sitter_typescript_json"))
            5359
        else if (std.mem.eql(u8, run.id, "tree_sitter_rust_json"))
            2659
        else if (standalone_probe_status == .implemented_passing or run.parser_boundary_check_mode == .serialize_only)
            2336
        else
            null,
        .decision = decision,
        .rationale = rationale,
    };
}

fn collectPassedStepsAlloc(
    allocator: std.mem.Allocator,
    run: result_model.TargetRunResult,
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
        if (step.status == .passed) try items.append(step_name);
    }

    return try items.toOwnedSlice();
}

test "buildParserBoundaryHypothesisAlloc summarizes the current deferred parser-wave set" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    var report = try buildParserBoundaryHypothesisAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), report.deferred_parser_wave_target_count);
    try std.testing.expect(!report.singleton_parser_wave);
    try std.testing.expectEqual(@as(usize, 0), report.entries.len);
}

test "renderParserBoundaryHypothesisAlloc matches the checked-in parser boundary hypothesis artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    const rendered = try renderParserBoundaryHypothesisAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "compat_targets/parser_boundary_hypothesis.json", allocator, .limited(1024 * 1024));
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimEnd(u8, expected, "\n");
    const normalized_rendered = std.mem.trimEnd(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

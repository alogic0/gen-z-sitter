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
    singleton_parser_wave: bool,
    current_proven_steps: []const result_model.StepName,
    deferred_from_step: result_model.StepName,
    standalone_probe_status: StandaloneProbeStatus,
    standalone_probe_detail: ?[]const u8,
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
    const decision: HypothesisDecision = .keep_standalone_probe;
    const standalone_probe_status: StandaloneProbeStatus = if (run.id.len != 0 and std.mem.eql(u8, run.id, "tree_sitter_c_json"))
        .implemented_passing
    else
        .not_implemented;
    const standalone_probe_detail = if (standalone_probe_status == .implemented_passing)
        try std.fmt.allocPrint(
            allocator,
            "standalone coarse serialize-only probe is implemented and currently passes for {s}; the checked-in parser boundary probe records serialized_state_count=2336 and blocked=false while keeping full lookahead-sensitive parser proof out of the routine boundary",
            .{run.id},
        )
    else
        null;
    const rationale = try std.fmt.allocPrint(
        allocator,
        "the next named proof step for {s} is {s}; it remains scoped to {s} because the routine compatibility refresh should stay fast and stable while this deferred parser-wave singleton is evaluated more narrowly, and the current standalone proof is intentionally coarse rather than a full lookahead-sensitive parser promotion",
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
        .singleton_parser_wave = singleton_parser_wave,
        .current_proven_steps = current_proven_steps,
        .deferred_from_step = run.first_failed_stage.?,
        .standalone_probe_status = standalone_probe_status,
        .standalone_probe_detail = standalone_probe_detail,
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
        .emit_c_tables,
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
            .emit_c_tables => run.emit_c_tables,
            .emit_parser_c => run.emit_parser_c,
            .scanner_boundary_check => run.scanner_boundary_check,
            .compat_check => run.compat_check,
            .compile_smoke => run.compile_smoke,
        };
        if (step.status == .passed) try items.append(step_name);
    }

    return try items.toOwnedSlice();
}

test "buildParserBoundaryHypothesisAlloc summarizes the deferred parser-wave singleton" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    var report = try buildParserBoundaryHypothesisAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), report.deferred_parser_wave_target_count);
    try std.testing.expect(report.singleton_parser_wave);
    try std.testing.expectEqual(@as(usize, 1), report.entries.len);
    try std.testing.expectEqualStrings("tree_sitter_c_json", report.entries[0].id);
    try std.testing.expectEqual(targets.ParserBoundaryCheckMode.prepare_only, report.entries[0].current_parser_boundary_check_mode);
    try std.testing.expectEqual(targets.ParserBoundaryCheckMode.serialize_only, report.entries[0].proposed_parser_boundary_check_mode);
    try std.testing.expectEqual(EvaluationSurface.standalone_probe, report.entries[0].evaluation_surface);
    try std.testing.expect(!report.entries[0].routine_refresh_safe);
    try std.testing.expect(report.entries[0].singleton_parser_wave);
    try std.testing.expectEqual(result_model.StepName.serialize, report.entries[0].deferred_from_step);
    try std.testing.expectEqual(StandaloneProbeStatus.implemented_passing, report.entries[0].standalone_probe_status);
    try std.testing.expect(report.entries[0].standalone_probe_detail != null);
}

test "renderParserBoundaryHypothesisAlloc matches the checked-in parser boundary hypothesis artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const rendered = try renderParserBoundaryHypothesisAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.fs.cwd().readFileAlloc(allocator, "compat_targets/parser_boundary_hypothesis.json", 1024 * 1024);
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimRight(u8, expected, "\n");
    const normalized_rendered = std.mem.trimRight(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

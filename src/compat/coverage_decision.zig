const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const NextMilestone = enum {
    scanner_and_external_scanner_compatibility_onboarding,
    second_wave_parser_only_repo_coverage,
    broader_compatibility_polish,
    deeper_parse_table_minimization,
};

pub const TargetSummary = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    notes: []const u8,
};

pub const CoverageDecisionReport = struct {
    schema_version: u32,
    first_wave_target_count: usize,
    first_wave_passed_count: usize,
    first_wave_non_passing_count: usize,
    parser_only_boundary_proven: bool,
    proven_boundary: []const []const u8,
    deferred_parser_only_targets: []TargetSummary,
    deferred_scanner_targets: []TargetSummary,
    recommended_next_milestone: NextMilestone,
    recommendation_rationale: []const []const u8,

    pub fn deinit(self: *CoverageDecisionReport, allocator: std.mem.Allocator) void {
        deinitStringSlice(allocator, self.proven_boundary);
        deinitTargetSummaries(allocator, self.deferred_parser_only_targets);
        deinitTargetSummaries(allocator, self.deferred_scanner_targets);
        deinitStringSlice(allocator, self.recommendation_rationale);
        self.* = undefined;
    }
};

pub fn buildCoverageDecisionAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !CoverageDecisionReport {
    const first_wave_target_count = countByStatus(runs, .intended_first_wave);
    const first_wave_passed_count = countFirstWavePassed(runs);
    const first_wave_non_passing_count = first_wave_target_count - first_wave_passed_count;

    const deferred_scanner_targets = try collectTargetSummariesAlloc(allocator, runs, .deferred_scanner_wave);
    const recommended_next_milestone: NextMilestone = if (deferred_scanner_targets.len == 0)
        .broader_compatibility_polish
    else
        .scanner_and_external_scanner_compatibility_onboarding;
    const recommendation_rationale = if (deferred_scanner_targets.len == 0)
        try duplicateStringSliceAlloc(allocator, &.{
            "the promoted first-wave parser-only shortlist currently passes within the staged boundary",
            "the only remaining deferred parser-only target is an intentional conflict control fixture rather than an unresolved external-grammar blocker",
            "a second scanner grammar family now passes within the staged first-boundary checks, so the next promoted milestone can shift from scanner onboarding toward broader compatibility polish",
        })
    else
        try duplicateStringSliceAlloc(allocator, &.{
            "the promoted first-wave parser-only shortlist currently passes within the staged boundary",
            "the only remaining deferred parser-only target is an intentional conflict control fixture rather than an unresolved external-grammar blocker",
            "the initial staged scanner wave now has compatibility-safe promoted targets, but second-wave scanner targets remain deferred, so the current promoted milestone should focus on broadening scanner evidence across additional grammar families",
        });

    return .{
        .schema_version = 1,
        .first_wave_target_count = first_wave_target_count,
        .first_wave_passed_count = first_wave_passed_count,
        .first_wave_non_passing_count = first_wave_non_passing_count,
        .parser_only_boundary_proven = first_wave_non_passing_count == 0,
        .proven_boundary = try collectProvenBoundaryAlloc(allocator, runs),
        .deferred_parser_only_targets = try collectTargetSummariesAlloc(allocator, runs, .deferred_control_fixture),
        .deferred_scanner_targets = deferred_scanner_targets,
        .recommended_next_milestone = recommended_next_milestone,
        .recommendation_rationale = recommendation_rationale,
    };
}

pub fn renderCoverageDecisionAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildCoverageDecisionAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

fn countByStatus(runs: []const result_model.TargetRunResult, status: targets.CandidateStatus) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.candidate_status == status) count += 1;
    }
    return count;
}

fn countFirstWavePassed(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.candidate_status != .intended_first_wave) continue;
        if (run.final_classification == .passed_within_current_boundary) count += 1;
    }
    return count;
}

fn countScannerWavePassed(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.candidate_status != .intended_scanner_wave) continue;
        if (run.final_classification == .passed_within_current_boundary) count += 1;
    }
    return count;
}

fn collectProvenBoundaryAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]const []const u8 {
    const first_wave_target_count = countByStatus(runs, .intended_first_wave);
    const first_wave_passed_count = countFirstWavePassed(runs);
    const scanner_wave_passed_count = countScannerWavePassed(runs);
    const blocked_count = countBlocked(runs);
    return try allocator.dupe([]const u8, &.{
        try std.fmt.allocPrint(allocator, "{d} intended first-wave parser-only targets are currently in the run set", .{first_wave_target_count}),
        try std.fmt.allocPrint(allocator, "{d} intended first-wave targets currently pass within the staged parser-only boundary", .{first_wave_passed_count}),
        try std.fmt.allocPrint(allocator, "{d} intended scanner-wave targets currently pass within the staged scanner boundary", .{scanner_wave_passed_count}),
        try std.fmt.allocPrint(allocator, "{d} shortlist targets currently emit a blocked parser surface while remaining classified outcomes rather than infrastructure failures", .{blocked_count}),
    });
}

fn countBlocked(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.emission) |emission| {
            if (emission.blocked) count += 1;
        }
    }
    return count;
}

fn collectTargetSummariesAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
    status: targets.CandidateStatus,
) ![]TargetSummary {
    var items = std.array_list.Managed(TargetSummary).init(allocator);
    defer items.deinit();

    for (runs) |run| {
        if (run.candidate_status != status) continue;
        try items.append(.{
            .id = try allocator.dupe(u8, run.id),
            .display_name = try allocator.dupe(u8, run.display_name),
            .grammar_path = try allocator.dupe(u8, run.grammar_path),
            .notes = try allocator.dupe(u8, run.notes),
        });
    }

    return try items.toOwnedSlice();
}

fn deinitTargetSummaries(allocator: std.mem.Allocator, items: []TargetSummary) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.display_name);
        allocator.free(item.grammar_path);
        allocator.free(item.notes);
    }
    allocator.free(items);
}

fn deinitStringSlice(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn duplicateStringSliceAlloc(
    allocator: std.mem.Allocator,
    items: []const []const u8,
) ![]const []const u8 {
    const duped = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(duped);

    for (items, 0..) |item, index| {
        duped[index] = try allocator.dupe(u8, item);
    }

    return duped;
}

test "buildCoverageDecisionAlloc summarizes the current next-step decision" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    var report = try buildCoverageDecisionAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), report.first_wave_target_count);
    try std.testing.expectEqual(@as(usize, 5), report.first_wave_passed_count);
    try std.testing.expectEqual(@as(usize, 0), report.first_wave_non_passing_count);
    try std.testing.expect(report.parser_only_boundary_proven);
    try std.testing.expectEqual(NextMilestone.scanner_and_external_scanner_compatibility_onboarding, report.recommended_next_milestone);
    try std.testing.expectEqual(@as(usize, 1), report.deferred_parser_only_targets.len);
    try std.testing.expectEqual(@as(usize, 1), report.deferred_scanner_targets.len);
}

test "renderCoverageDecisionAlloc matches the checked-in coverage decision artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const rendered = try renderCoverageDecisionAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.fs.cwd().readFileAlloc(allocator, "compat_targets/coverage_decision.json", 1024 * 1024);
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimRight(u8, expected, "\n");
    const normalized_rendered = std.mem.trimRight(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

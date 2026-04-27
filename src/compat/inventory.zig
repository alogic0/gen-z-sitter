const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const BoundarySummary = struct {
    total_shortlist_targets: usize,
    first_wave_targets: usize,
    first_wave_passed: usize,
    first_wave_non_passing: usize,
    scanner_wave_targets: usize,
    scanner_wave_passed: usize,
    scanner_wave_non_passing: usize,
    deferred_parser_targets: usize,
    standalone_parser_proof_targets: usize,
    deferred_control_targets: usize,
    frozen_control_fixtures: usize,
    deferred_scanner_targets: usize,
    excluded_targets: usize,
    blocked_targets: usize,
    blocked_control_targets: usize,
};

pub const InventoryEntry = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    family: targets.TargetFamily,
    boundary_kind: targets.BoundaryKind,
    standalone_parser_proof_scope: targets.StandaloneParserProofScope,
    candidate_status: targets.CandidateStatus,
    expected_blocked: bool,
    emission_blocked: bool,
    final_classification: result_model.FinalClassification,
    mismatch_category: result_model.MismatchCategory,
    first_failed_stage: ?result_model.StepName,
    detail: ?[]const u8,
    notes: []const u8,
};

pub const FamilyCoverageEntry = struct {
    family: targets.TargetFamily,
    boundary_kind: targets.BoundaryKind,
    target_count: usize,
    passed_count: usize,
    control_count: usize,
    deferred_count: usize,
    blocked_count: usize,
};

pub const InventoryReport = struct {
    schema_version: u32,
    boundary: BoundarySummary,
    family_coverage: []FamilyCoverageEntry,
    proven_first_wave_targets: []InventoryEntry,
    proven_scanner_wave_targets: []InventoryEntry,
    deferred_parser_targets: []InventoryEntry,
    deferred_control_targets: []InventoryEntry,
    deferred_scanner_targets: []InventoryEntry,
    in_scope_failures: []InventoryEntry,
    out_of_scope_targets: []InventoryEntry,

    pub fn deinit(self: *InventoryReport, allocator: std.mem.Allocator) void {
        allocator.free(self.family_coverage);
        deinitInventoryEntries(allocator, self.proven_first_wave_targets);
        deinitInventoryEntries(allocator, self.proven_scanner_wave_targets);
        deinitInventoryEntries(allocator, self.deferred_parser_targets);
        deinitInventoryEntries(allocator, self.deferred_control_targets);
        deinitInventoryEntries(allocator, self.deferred_scanner_targets);
        deinitInventoryEntries(allocator, self.in_scope_failures);
        deinitInventoryEntries(allocator, self.out_of_scope_targets);
        self.* = undefined;
    }
};

pub fn buildInventoryReportAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !InventoryReport {
    return .{
        .schema_version = 1,
        .boundary = collectBoundarySummary(runs),
        .family_coverage = try collectFamilyCoverageAlloc(allocator, runs),
        .proven_first_wave_targets = try collectEntriesAlloc(allocator, runs, includeProvenFirstWaveTarget),
        .proven_scanner_wave_targets = try collectEntriesAlloc(allocator, runs, includeProvenScannerWaveTarget),
        .deferred_parser_targets = try collectEntriesAlloc(allocator, runs, includeDeferredParserTarget),
        .deferred_control_targets = try collectEntriesAlloc(allocator, runs, includeDeferredControl),
        .deferred_scanner_targets = try collectEntriesAlloc(allocator, runs, includeDeferredScannerTarget),
        .in_scope_failures = try collectEntriesAlloc(allocator, runs, includeInScopeFailure),
        .out_of_scope_targets = try collectEntriesAlloc(allocator, runs, includeOutOfScope),
    };
}

pub fn renderInventoryReportAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildInventoryReportAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

pub fn collectBoundarySummary(runs: []const result_model.TargetRunResult) BoundarySummary {
    var summary = BoundarySummary{
        .total_shortlist_targets = runs.len,
        .first_wave_targets = 0,
        .first_wave_passed = 0,
        .first_wave_non_passing = 0,
        .scanner_wave_targets = 0,
        .scanner_wave_passed = 0,
        .scanner_wave_non_passing = 0,
        .deferred_parser_targets = 0,
        .standalone_parser_proof_targets = 0,
        .deferred_control_targets = 0,
        .frozen_control_fixtures = 0,
        .deferred_scanner_targets = 0,
        .excluded_targets = 0,
        .blocked_targets = 0,
        .blocked_control_targets = 0,
    };

    for (runs) |run| {
        switch (run.candidate_status) {
            .intended_first_wave => {
                summary.first_wave_targets += 1;
                if (run.final_classification == .passed_within_current_boundary) {
                    summary.first_wave_passed += 1;
                } else {
                    summary.first_wave_non_passing += 1;
                }
            },
            .intended_scanner_wave => {
                summary.scanner_wave_targets += 1;
                if (run.final_classification == .passed_within_current_boundary) {
                    summary.scanner_wave_passed += 1;
                } else {
                    summary.scanner_wave_non_passing += 1;
                }
            },
            .deferred_parser_wave => summary.deferred_parser_targets += 1,
            .deferred_control_fixture => {
                summary.deferred_control_targets += 1;
                if (run.final_classification == .frozen_control_fixture) {
                    summary.frozen_control_fixtures += 1;
                }
            },
            .deferred_scanner_wave => summary.deferred_scanner_targets += 1,
            .excluded_out_of_scope => summary.excluded_targets += 1,
        }
        if (run.standalone_parser_proof_scope != .none) {
            summary.standalone_parser_proof_targets += 1;
        }
        if (run.emission) |emission| {
            if (emission.blocked) {
                summary.blocked_targets += 1;
                if (run.candidate_status == .deferred_control_fixture) summary.blocked_control_targets += 1;
            }
        }
    }

    return summary;
}

fn collectEntriesAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
    comptime predicate: fn (result_model.TargetRunResult) bool,
) ![]InventoryEntry {
    var entries = std.array_list.Managed(InventoryEntry).init(allocator);
    defer entries.deinit();

    for (runs) |run| {
        if (!predicate(run)) continue;
        try entries.append(try cloneInventoryEntry(allocator, run));
    }

    return try entries.toOwnedSlice();
}

fn cloneInventoryEntry(
    allocator: std.mem.Allocator,
    run: result_model.TargetRunResult,
) !InventoryEntry {
    return .{
        .id = try allocator.dupe(u8, run.id),
        .display_name = try allocator.dupe(u8, run.display_name),
        .grammar_path = try allocator.dupe(u8, run.grammar_path),
        .family = run.family,
        .boundary_kind = run.boundary_kind,
        .standalone_parser_proof_scope = run.standalone_parser_proof_scope,
        .candidate_status = run.candidate_status,
        .expected_blocked = run.expected_blocked,
        .emission_blocked = if (run.emission) |emission| emission.blocked else false,
        .final_classification = run.final_classification,
        .mismatch_category = run.mismatch_category,
        .first_failed_stage = run.first_failed_stage,
        .detail = if (firstFailureDetail(run)) |detail| try allocator.dupe(u8, detail) else null,
        .notes = try allocator.dupe(u8, run.notes),
    };
}

fn deinitInventoryEntries(allocator: std.mem.Allocator, entries: []InventoryEntry) void {
    for (entries) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.display_name);
        allocator.free(entry.grammar_path);
        if (entry.detail) |detail| allocator.free(detail);
        allocator.free(entry.notes);
    }
    allocator.free(entries);
}

fn collectFamilyCoverageAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]FamilyCoverageEntry {
    var items = std.array_list.Managed(FamilyCoverageEntry).init(allocator);
    defer items.deinit();

    for (runs) |run| {
        const index = findFamilyCoverageIndex(items.items, run.family) orelse blk: {
            try items.append(.{
                .family = run.family,
                .boundary_kind = run.boundary_kind,
                .target_count = 0,
                .passed_count = 0,
                .control_count = 0,
                .deferred_count = 0,
                .blocked_count = 0,
            });
            break :blk items.items.len - 1;
        };

        items.items[index].target_count += 1;
        switch (run.final_classification) {
            .passed_within_current_boundary => items.items[index].passed_count += 1,
            .frozen_control_fixture => items.items[index].control_count += 1,
            .deferred_for_parser_boundary => items.items[index].deferred_count += 1,
            .deferred_for_scanner_boundary => items.items[index].deferred_count += 1,
            .failed_due_to_parser_only_gap,
            .out_of_scope_for_scanner_boundary,
            .infrastructure_failure,
            => {},
        }
        if (run.emission) |emission| {
            if (emission.blocked) items.items[index].blocked_count += 1;
        }
    }

    return try items.toOwnedSlice();
}

fn findFamilyCoverageIndex(items: []const FamilyCoverageEntry, family: targets.TargetFamily) ?usize {
    for (items, 0..) |item, index| {
        if (item.family == family) return index;
    }
    return null;
}

fn firstFailureDetail(run: result_model.TargetRunResult) ?[]const u8 {
    if (run.first_failed_stage) |stage| {
        return switch (stage) {
            .load => run.load.detail,
            .prepare => run.prepare.detail,
            .serialize => run.serialize.detail,
            .scanner_boundary_check => run.scanner_boundary_check.detail,
            .emit_parser_tables => run.emit_parser_tables.detail,
            .emit_parser_c => run.emit_parser_c.detail,
            .compat_check => run.compat_check.detail,
            .compile_smoke => run.compile_smoke.detail,
        };
    }
    return null;
}

fn includeInScopeFailure(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .intended_first_wave and run.final_classification != .passed_within_current_boundary;
}

fn includeProvenFirstWaveTarget(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .intended_first_wave and run.final_classification == .passed_within_current_boundary;
}

fn includeDeferredControl(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .deferred_control_fixture;
}

fn includeDeferredParserTarget(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .deferred_parser_wave;
}

fn includeProvenScannerWaveTarget(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .intended_scanner_wave and run.final_classification == .passed_within_current_boundary;
}

fn includeDeferredScannerTarget(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .deferred_scanner_wave;
}

fn includeOutOfScope(run: result_model.TargetRunResult) bool {
    return run.final_classification == .out_of_scope_for_scanner_boundary;
}

test "buildInventoryReportAlloc summarizes the shortlist boundary" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    var report = try buildInventoryReportAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 20), report.boundary.total_shortlist_targets);
    try std.testing.expectEqual(@as(usize, 7), report.boundary.first_wave_targets);
    try std.testing.expectEqual(@as(usize, 7), report.boundary.first_wave_passed);
    try std.testing.expectEqual(@as(usize, 7), report.boundary.scanner_wave_targets);
    try std.testing.expectEqual(@as(usize, 7), report.boundary.scanner_wave_passed);
    try std.testing.expectEqual(@as(usize, 5), report.boundary.deferred_parser_targets);
    try std.testing.expectEqual(@as(usize, 1), report.boundary.deferred_control_targets);
    try std.testing.expectEqual(@as(usize, 1), report.boundary.frozen_control_fixtures);
    try std.testing.expectEqual(@as(usize, 0), report.boundary.deferred_scanner_targets);
    try std.testing.expectEqual(@as(usize, 0), report.boundary.excluded_targets);
    try std.testing.expectEqual(@as(usize, 1), report.boundary.blocked_control_targets);
    try std.testing.expectEqual(@as(usize, 18), report.family_coverage.len);
    try std.testing.expectEqual(targets.TargetFamily.c, report.family_coverage[5].family);
    try std.testing.expectEqual(targets.TargetFamily.zig, report.family_coverage[6].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[5].passed_count);
    try std.testing.expectEqual(@as(usize, 0), report.family_coverage[5].deferred_count);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[6].passed_count);
    try std.testing.expectEqual(@as(usize, 0), report.family_coverage[6].deferred_count);
    try std.testing.expectEqual(targets.TargetFamily.json, report.family_coverage[7].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[7].target_count);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[7].passed_count);
    try std.testing.expectEqual(targets.TargetFamily.haskell, report.family_coverage[8].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[8].passed_count);
    try std.testing.expectEqual(@as(usize, 0), report.family_coverage[8].deferred_count);
    try std.testing.expectEqual(targets.TargetFamily.bash, report.family_coverage[9].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[9].passed_count);
    try std.testing.expectEqual(targets.TargetFamily.parse_table_conflict, report.family_coverage[10].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[10].control_count);
    try std.testing.expectEqual(targets.TargetFamily.bracket_lang, report.family_coverage[11].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[11].passed_count);
    try std.testing.expectEqual(targets.TargetFamily.hidden_external_fields, report.family_coverage[12].family);
    try std.testing.expectEqual(@as(usize, 2), report.family_coverage[12].passed_count);
    try std.testing.expectEqual(targets.TargetFamily.mixed_semantics, report.family_coverage[13].family);
    try std.testing.expectEqual(@as(usize, 2), report.family_coverage[13].passed_count);
    try std.testing.expectEqual(targets.TargetFamily.javascript, report.family_coverage[14].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[14].deferred_count);
    try std.testing.expectEqual(targets.TargetFamily.python, report.family_coverage[15].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[15].deferred_count);
    try std.testing.expectEqual(targets.TargetFamily.typescript, report.family_coverage[16].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[16].deferred_count);
    try std.testing.expectEqual(targets.TargetFamily.rust, report.family_coverage[17].family);
    try std.testing.expectEqual(@as(usize, 1), report.family_coverage[17].deferred_count);
    try std.testing.expectEqual(@as(usize, 7), report.proven_first_wave_targets.len);
    try std.testing.expectEqual(@as(usize, 7), report.proven_scanner_wave_targets.len);
    try std.testing.expectEqual(@as(usize, 5), report.deferred_parser_targets.len);
    try std.testing.expectEqual(@as(usize, 1), report.deferred_control_targets.len);
    try std.testing.expectEqual(@as(usize, 0), report.deferred_scanner_targets.len);
}

test "renderInventoryReportAlloc emits deterministic boundary JSON" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    const json = try renderInventoryReportAlloc(allocator, runs);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"boundary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"family_coverage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proven_first_wave_targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proven_scanner_wave_targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"deferred_parser_targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"deferred_control_targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"deferred_scanner_targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"in_scope_failures\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"out_of_scope_targets\"") != null);
}

test "renderInventoryReportAlloc matches the checked-in shortlist inventory artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    const rendered = try renderInventoryReportAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "compat_targets/shortlist_inventory.json", allocator, .limited(1024 * 1024));
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimEnd(u8, expected, "\n");
    const normalized_rendered = std.mem.trimEnd(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

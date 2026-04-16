const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const BoundarySummary = struct {
    total_shortlist_targets: usize,
    first_wave_targets: usize,
    first_wave_passed: usize,
    first_wave_non_passing: usize,
    deferred_control_targets: usize,
    excluded_targets: usize,
    blocked_targets: usize,
    blocked_control_targets: usize,
};

pub const InventoryEntry = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    candidate_status: targets.CandidateStatus,
    expected_blocked: bool,
    emission_blocked: bool,
    final_classification: result_model.FinalClassification,
    mismatch_category: result_model.MismatchCategory,
    first_failed_stage: ?result_model.StepName,
    detail: ?[]const u8,
    notes: []const u8,
};

pub const InventoryReport = struct {
    schema_version: u32,
    boundary: BoundarySummary,
    proven_first_wave_targets: []InventoryEntry,
    deferred_control_targets: []InventoryEntry,
    in_scope_failures: []InventoryEntry,
    out_of_scope_targets: []InventoryEntry,

    pub fn deinit(self: *InventoryReport, allocator: std.mem.Allocator) void {
        deinitInventoryEntries(allocator, self.proven_first_wave_targets);
        deinitInventoryEntries(allocator, self.deferred_control_targets);
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
        .proven_first_wave_targets = try collectEntriesAlloc(allocator, runs, includeProvenFirstWaveTarget),
        .deferred_control_targets = try collectEntriesAlloc(allocator, runs, includeDeferredControl),
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
        .deferred_control_targets = 0,
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
            .deferred_later_wave => summary.deferred_control_targets += 1,
            .excluded_out_of_scope => summary.excluded_targets += 1,
        }
        if (run.emission) |emission| {
            if (emission.blocked) {
                summary.blocked_targets += 1;
                if (run.candidate_status == .deferred_later_wave) summary.blocked_control_targets += 1;
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

fn firstFailureDetail(run: result_model.TargetRunResult) ?[]const u8 {
    if (run.first_failed_stage) |stage| {
        return switch (stage) {
            .load => run.load.detail,
            .prepare => run.prepare.detail,
            .serialize => run.serialize.detail,
            .emit_parser_tables => run.emit_parser_tables.detail,
            .emit_c_tables => run.emit_c_tables.detail,
            .emit_parser_c => run.emit_parser_c.detail,
            .compat_check => run.compat_check.detail,
            .compile_smoke => run.compile_smoke.detail,
        };
    }
    return null;
}

fn includeInScopeFailure(run: result_model.TargetRunResult) bool {
    return run.candidate_status != .excluded_out_of_scope and run.final_classification != .passed_within_current_boundary;
}

fn includeProvenFirstWaveTarget(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .intended_first_wave and run.final_classification == .passed_within_current_boundary;
}

fn includeDeferredControl(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .deferred_later_wave;
}

fn includeOutOfScope(run: result_model.TargetRunResult) bool {
    return run.final_classification == .out_of_scope_for_scanner_boundary;
}

test "buildInventoryReportAlloc summarizes the shortlist boundary" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    var report = try buildInventoryReportAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), report.boundary.total_shortlist_targets);
    try std.testing.expectEqual(@as(usize, 5), report.boundary.first_wave_targets);
    try std.testing.expectEqual(@as(usize, 5), report.boundary.first_wave_passed);
    try std.testing.expectEqual(@as(usize, 1), report.boundary.deferred_control_targets);
    try std.testing.expectEqual(@as(usize, 1), report.boundary.excluded_targets);
    try std.testing.expectEqual(@as(usize, 1), report.boundary.blocked_control_targets);
    try std.testing.expectEqual(@as(usize, 5), report.proven_first_wave_targets.len);
    try std.testing.expectEqual(@as(usize, 1), report.out_of_scope_targets.len);
    try std.testing.expectEqual(@as(usize, 1), report.deferred_control_targets.len);
}

test "renderInventoryReportAlloc emits deterministic boundary JSON" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const json = try renderInventoryReportAlloc(allocator, runs);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"boundary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proven_first_wave_targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"deferred_control_targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"in_scope_failures\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"out_of_scope_targets\"") != null);
}

test "renderInventoryReportAlloc matches the checked-in shortlist inventory artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const rendered = try renderInventoryReportAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.fs.cwd().readFileAlloc(allocator, "compat_targets/shortlist_inventory.json", 1024 * 1024);
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimRight(u8, expected, "\n");
    const normalized_rendered = std.mem.trimRight(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const MismatchEntry = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    candidate_status: targets.CandidateStatus,
    first_failed_stage: ?result_model.StepName,
    detail: ?[]const u8,
    notes: []const u8,
};

pub const MismatchInventoryReport = struct {
    schema_version: u32,
    first_wave_non_passing_count: usize,
    parser_only_incompatibilities: []MismatchEntry,
    grammar_input_shape_issues: []MismatchEntry,
    compile_surface_issues: []MismatchEntry,
    harness_limitations: []MismatchEntry,
    deferred_control_targets: []MismatchEntry,
    out_of_scope_targets: []MismatchEntry,

    pub fn deinit(self: *MismatchInventoryReport, allocator: std.mem.Allocator) void {
        deinitEntries(allocator, self.parser_only_incompatibilities);
        deinitEntries(allocator, self.grammar_input_shape_issues);
        deinitEntries(allocator, self.compile_surface_issues);
        deinitEntries(allocator, self.harness_limitations);
        deinitEntries(allocator, self.deferred_control_targets);
        deinitEntries(allocator, self.out_of_scope_targets);
        self.* = undefined;
    }
};

pub fn buildMismatchInventoryAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !MismatchInventoryReport {
    return .{
        .schema_version = 1,
        .first_wave_non_passing_count = countFirstWaveNonPassing(runs),
        .parser_only_incompatibilities = try collectEntriesAlloc(allocator, runs, includeParserOnlyIncompatibility),
        .grammar_input_shape_issues = try collectEntriesAlloc(allocator, runs, includeGrammarInputShapeIssue),
        .compile_surface_issues = try collectEntriesAlloc(allocator, runs, includeCompileSurfaceIssue),
        .harness_limitations = try collectEntriesAlloc(allocator, runs, includeHarnessLimitation),
        .deferred_control_targets = try collectEntriesAlloc(allocator, runs, includeDeferredControl),
        .out_of_scope_targets = try collectEntriesAlloc(allocator, runs, includeOutOfScope),
    };
}

pub fn renderMismatchInventoryAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildMismatchInventoryAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

fn countFirstWaveNonPassing(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.candidate_status != .intended_first_wave) continue;
        if (run.final_classification != .passed_within_current_boundary) count += 1;
    }
    return count;
}

fn collectEntriesAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
    comptime predicate: fn (result_model.TargetRunResult) bool,
) ![]MismatchEntry {
    var entries = std.array_list.Managed(MismatchEntry).init(allocator);
    defer entries.deinit();

    for (runs) |run| {
        if (!predicate(run)) continue;
        try entries.append(try cloneEntry(allocator, run));
    }

    return try entries.toOwnedSlice();
}

fn cloneEntry(allocator: std.mem.Allocator, run: result_model.TargetRunResult) !MismatchEntry {
    return .{
        .id = try allocator.dupe(u8, run.id),
        .display_name = try allocator.dupe(u8, run.display_name),
        .grammar_path = try allocator.dupe(u8, run.grammar_path),
        .candidate_status = run.candidate_status,
        .first_failed_stage = run.first_failed_stage,
        .detail = if (firstFailureDetail(run)) |detail| try allocator.dupe(u8, detail) else null,
        .notes = try allocator.dupe(u8, run.notes),
    };
}

fn deinitEntries(allocator: std.mem.Allocator, entries: []MismatchEntry) void {
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

fn includeParserOnlyIncompatibility(run: result_model.TargetRunResult) bool {
    return switch (run.mismatch_category) {
        .preparation_lowering_mismatch,
        .parse_table_construction_gap,
        .shift_reduce_boundary,
        .emitted_surface_structural_gap,
        => true,
        else => false,
    };
}

fn includeGrammarInputShapeIssue(run: result_model.TargetRunResult) bool {
    return run.mismatch_category == .grammar_input_load_mismatch;
}

fn includeCompileSurfaceIssue(run: result_model.TargetRunResult) bool {
    return run.mismatch_category == .compile_smoke_failure;
}

fn includeHarnessLimitation(run: result_model.TargetRunResult) bool {
    return run.mismatch_category == .infrastructure_failure;
}

fn includeOutOfScope(run: result_model.TargetRunResult) bool {
    return run.mismatch_category == .out_of_scope_scanner_boundary;
}

fn includeDeferredControl(run: result_model.TargetRunResult) bool {
    return run.candidate_status == .deferred_later_wave;
}

test "buildMismatchInventoryAlloc classifies the current shortlist" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    var report = try buildMismatchInventoryAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), report.first_wave_non_passing_count);
    try std.testing.expectEqual(@as(usize, 0), report.parser_only_incompatibilities.len);
    try std.testing.expectEqual(@as(usize, 0), report.grammar_input_shape_issues.len);
    try std.testing.expectEqual(@as(usize, 0), report.compile_surface_issues.len);
    try std.testing.expectEqual(@as(usize, 0), report.harness_limitations.len);
    try std.testing.expectEqual(@as(usize, 1), report.deferred_control_targets.len);
    try std.testing.expectEqual(@as(usize, 1), report.out_of_scope_targets.len);
}

test "renderMismatchInventoryAlloc matches the checked-in shortlist mismatch inventory artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const rendered = try renderMismatchInventoryAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.fs.cwd().readFileAlloc(allocator, "compat_targets/shortlist_mismatch_inventory.json", 1024 * 1024);
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimRight(u8, expected, "\n");
    const normalized_rendered = std.mem.trimRight(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

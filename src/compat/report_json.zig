const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");

pub const AggregateCounts = struct {
    total_targets: usize,
    first_wave_targets: usize,
    first_wave_passed: usize,
    scanner_wave_targets: usize,
    scanner_wave_passed: usize,
    deferred_control_targets: usize,
    deferred_scanner_targets: usize,
    passed_within_current_boundary: usize,
    deferred_for_scanner_boundary: usize,
    failed_due_to_parser_only_gap: usize,
    out_of_scope_for_scanner_boundary: usize,
    infrastructure_failure: usize,
    blocked_targets: usize,
    blocked_control_targets: usize,
    mismatch_categories: MismatchCategoryCounts,
};

pub const MismatchCategoryCounts = struct {
    grammar_input_load_mismatch: usize,
    preparation_lowering_mismatch: usize,
    scanner_external_scanner_boundary_gap: usize,
    parse_table_construction_gap: usize,
    shift_reduce_boundary: usize,
    intentional_control_fixture: usize,
    emitted_surface_structural_gap: usize,
    compile_smoke_failure: usize,
    out_of_scope_scanner_boundary: usize,
    infrastructure_failure: usize,
};

pub fn renderRunReportAlloc(
    allocator: std.mem.Allocator,
    results: []const result_model.TargetRunResult,
) ![]u8 {
    const aggregate = collectAggregateCounts(results);
    return try json_support.stringifyAlloc(allocator, .{
        .schema_version = 1,
        .aggregate = aggregate,
        .results = results,
    });
}

pub fn collectAggregateCounts(results: []const result_model.TargetRunResult) AggregateCounts {
    var counts = AggregateCounts{
        .total_targets = results.len,
        .first_wave_targets = 0,
        .first_wave_passed = 0,
        .scanner_wave_targets = 0,
        .scanner_wave_passed = 0,
        .deferred_control_targets = 0,
        .deferred_scanner_targets = 0,
        .passed_within_current_boundary = 0,
        .deferred_for_scanner_boundary = 0,
        .failed_due_to_parser_only_gap = 0,
        .out_of_scope_for_scanner_boundary = 0,
        .infrastructure_failure = 0,
        .blocked_targets = 0,
        .blocked_control_targets = 0,
        .mismatch_categories = .{
            .grammar_input_load_mismatch = 0,
            .preparation_lowering_mismatch = 0,
            .scanner_external_scanner_boundary_gap = 0,
            .parse_table_construction_gap = 0,
            .shift_reduce_boundary = 0,
            .intentional_control_fixture = 0,
            .emitted_surface_structural_gap = 0,
            .compile_smoke_failure = 0,
            .out_of_scope_scanner_boundary = 0,
            .infrastructure_failure = 0,
        },
    };

    for (results) |run| {
        switch (run.candidate_status) {
            .intended_first_wave => counts.first_wave_targets += 1,
            .intended_scanner_wave => counts.scanner_wave_targets += 1,
            .deferred_control_fixture => counts.deferred_control_targets += 1,
            .deferred_scanner_wave => counts.deferred_scanner_targets += 1,
            .excluded_out_of_scope => {},
        }
        switch (run.final_classification) {
            .passed_within_current_boundary => {
                counts.passed_within_current_boundary += 1;
                if (run.candidate_status == .intended_first_wave) counts.first_wave_passed += 1;
                if (run.candidate_status == .intended_scanner_wave) counts.scanner_wave_passed += 1;
            },
            .deferred_for_scanner_boundary => counts.deferred_for_scanner_boundary += 1,
            .failed_due_to_parser_only_gap => counts.failed_due_to_parser_only_gap += 1,
            .out_of_scope_for_scanner_boundary => counts.out_of_scope_for_scanner_boundary += 1,
            .infrastructure_failure => counts.infrastructure_failure += 1,
        }
        switch (run.mismatch_category) {
            .none => {},
            .grammar_input_load_mismatch => counts.mismatch_categories.grammar_input_load_mismatch += 1,
            .preparation_lowering_mismatch => counts.mismatch_categories.preparation_lowering_mismatch += 1,
            .scanner_external_scanner_boundary_gap => counts.mismatch_categories.scanner_external_scanner_boundary_gap += 1,
            .parse_table_construction_gap => counts.mismatch_categories.parse_table_construction_gap += 1,
            .shift_reduce_boundary => counts.mismatch_categories.shift_reduce_boundary += 1,
            .intentional_control_fixture => counts.mismatch_categories.intentional_control_fixture += 1,
            .emitted_surface_structural_gap => counts.mismatch_categories.emitted_surface_structural_gap += 1,
            .compile_smoke_failure => counts.mismatch_categories.compile_smoke_failure += 1,
            .out_of_scope_scanner_boundary => counts.mismatch_categories.out_of_scope_scanner_boundary += 1,
            .infrastructure_failure => counts.mismatch_categories.infrastructure_failure += 1,
        }
        if (run.emission) |emission| {
            if (emission.blocked) {
                counts.blocked_targets += 1;
                if (run.candidate_status == .deferred_control_fixture) counts.blocked_control_targets += 1;
            }
        }
    }

    return counts;
}

test "renderRunReportAlloc emits deterministic structured JSON" {
    const allocator = std.testing.allocator;

    const results = [_]result_model.TargetRunResult{
        .{
            .id = "sample",
            .display_name = "Sample",
            .grammar_path = "grammar.json",
            .source_kind = .grammar_json,
            .provenance = .{ .origin_kind = .staged_in_repo },
            .candidate_status = .intended_first_wave,
            .expected_blocked = false,
            .notes = "sample",
            .success_criteria = "sample",
        },
    };

    const json = try renderRunReportAlloc(allocator, results[0..]);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"results\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mismatch_categories\"") != null);
}

test "renderRunReportAlloc matches the checked-in shortlist report artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const rendered = try renderRunReportAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.fs.cwd().readFileAlloc(allocator, "compat_targets/shortlist_report.json", 1024 * 1024);
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimRight(u8, expected, "\n");
    const normalized_rendered = std.mem.trimRight(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

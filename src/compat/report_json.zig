const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const AggregateCounts = struct {
    total_targets: usize,
    first_wave_targets: usize,
    first_wave_passed: usize,
    scanner_wave_targets: usize,
    scanner_wave_passed: usize,
    deferred_parser_targets: usize,
    standalone_parser_proof_targets: usize,
    deferred_control_targets: usize,
    deferred_scanner_targets: usize,
    passed_within_current_boundary: usize,
    frozen_control_fixture: usize,
    deferred_for_parser_boundary: usize,
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
    routine_serialize_proof_boundary: usize,
    routine_emitted_surface_proof_boundary: usize,
    scanner_external_scanner_boundary_gap: usize,
    parse_table_construction_gap: usize,
    shift_reduce_boundary: usize,
    intentional_control_fixture: usize,
    emitted_surface_structural_gap: usize,
    compile_smoke_failure: usize,
    out_of_scope_scanner_boundary: usize,
    infrastructure_failure: usize,
};

pub const FamilyAggregate = struct {
    family: targets.TargetFamily,
    boundary_kind: targets.BoundaryKind,
    target_count: usize,
    passed_count: usize,
    control_count: usize,
    deferred_count: usize,
    blocked_count: usize,
};

pub fn renderRunReportAlloc(
    allocator: std.mem.Allocator,
    results: []const result_model.TargetRunResult,
) ![]u8 {
    const aggregate = collectAggregateCounts(results);
    const family_coverage = try collectFamilyAggregatesAlloc(allocator, results);
    defer allocator.free(family_coverage);
    return try json_support.stringifyAlloc(allocator, .{
        .schema_version = 1,
        .aggregate = aggregate,
        .family_coverage = family_coverage,
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
        .deferred_parser_targets = 0,
        .standalone_parser_proof_targets = 0,
        .deferred_control_targets = 0,
        .deferred_scanner_targets = 0,
        .passed_within_current_boundary = 0,
        .frozen_control_fixture = 0,
        .deferred_for_parser_boundary = 0,
        .deferred_for_scanner_boundary = 0,
        .failed_due_to_parser_only_gap = 0,
        .out_of_scope_for_scanner_boundary = 0,
        .infrastructure_failure = 0,
        .blocked_targets = 0,
        .blocked_control_targets = 0,
        .mismatch_categories = .{
            .grammar_input_load_mismatch = 0,
            .preparation_lowering_mismatch = 0,
            .routine_serialize_proof_boundary = 0,
            .routine_emitted_surface_proof_boundary = 0,
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
            .deferred_parser_wave => counts.deferred_parser_targets += 1,
            .deferred_control_fixture => counts.deferred_control_targets += 1,
            .deferred_scanner_wave => counts.deferred_scanner_targets += 1,
            .excluded_out_of_scope => {},
        }
        if (run.standalone_parser_proof_scope != .none) {
            counts.standalone_parser_proof_targets += 1;
        }
        switch (run.final_classification) {
            .passed_within_current_boundary => {
                counts.passed_within_current_boundary += 1;
                if (run.candidate_status == .intended_first_wave) counts.first_wave_passed += 1;
                if (run.candidate_status == .intended_scanner_wave) counts.scanner_wave_passed += 1;
            },
            .frozen_control_fixture => counts.frozen_control_fixture += 1,
            .deferred_for_parser_boundary => counts.deferred_for_parser_boundary += 1,
            .deferred_for_scanner_boundary => counts.deferred_for_scanner_boundary += 1,
            .failed_due_to_parser_only_gap => counts.failed_due_to_parser_only_gap += 1,
            .out_of_scope_for_scanner_boundary => counts.out_of_scope_for_scanner_boundary += 1,
            .infrastructure_failure => counts.infrastructure_failure += 1,
        }
        switch (run.mismatch_category) {
            .none => {},
            .grammar_input_load_mismatch => counts.mismatch_categories.grammar_input_load_mismatch += 1,
            .preparation_lowering_mismatch => counts.mismatch_categories.preparation_lowering_mismatch += 1,
            .routine_serialize_proof_boundary => counts.mismatch_categories.routine_serialize_proof_boundary += 1,
            .routine_emitted_surface_proof_boundary => counts.mismatch_categories.routine_emitted_surface_proof_boundary += 1,
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

fn collectFamilyAggregatesAlloc(
    allocator: std.mem.Allocator,
    results: []const result_model.TargetRunResult,
) ![]FamilyAggregate {
    var items = std.array_list.Managed(FamilyAggregate).init(allocator);
    defer items.deinit();

    for (results) |run| {
        const index = findFamilyAggregateIndex(items.items, run.family) orelse blk: {
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

fn findFamilyAggregateIndex(items: []const FamilyAggregate, family: targets.TargetFamily) ?usize {
    for (items, 0..) |item, index| {
        if (item.family == family) return index;
    }
    return null;
}

test "renderRunReportAlloc emits deterministic structured JSON" {
    const allocator = std.testing.allocator;

    const results = [_]result_model.TargetRunResult{
        .{
            .id = "sample",
            .display_name = "Sample",
            .grammar_path = "grammar.json",
            .family = .behavioral_config,
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"family_coverage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"results\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mismatch_categories\"") != null);
}

test "renderRunReportAlloc matches the checked-in shortlist report artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    const rendered = try renderRunReportAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "compat_targets/shortlist_report.json", allocator, .limited(1024 * 1024));
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimEnd(u8, expected, "\n");
    const normalized_rendered = std.mem.trimEnd(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

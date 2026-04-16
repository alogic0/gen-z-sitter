const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");

pub const AggregateCounts = struct {
    total_targets: usize,
    passed_within_current_boundary: usize,
    failed_due_to_parser_only_gap: usize,
    out_of_scope_for_scanner_boundary: usize,
    infrastructure_failure: usize,
    blocked_targets: usize,
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
        .passed_within_current_boundary = 0,
        .failed_due_to_parser_only_gap = 0,
        .out_of_scope_for_scanner_boundary = 0,
        .infrastructure_failure = 0,
        .blocked_targets = 0,
    };

    for (results) |run| {
        switch (run.final_classification) {
            .passed_within_current_boundary => counts.passed_within_current_boundary += 1,
            .failed_due_to_parser_only_gap => counts.failed_due_to_parser_only_gap += 1,
            .out_of_scope_for_scanner_boundary => counts.out_of_scope_for_scanner_boundary += 1,
            .infrastructure_failure => counts.infrastructure_failure += 1,
        }
        if (run.emission) |emission| {
            if (emission.blocked) counts.blocked_targets += 1;
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
            .expected_blocked = false,
            .notes = "sample",
        },
    };

    const json = try renderRunReportAlloc(allocator, results[0..]);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"results\"") != null);
}

const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const ShiftReduceProfileEntry = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    candidate_status: targets.CandidateStatus,
    first_failed_stage: ?result_model.StepName,
    detail: ?[]const u8,
    blocked_boundary: result_model.BlockedBoundarySnapshot,

    pub fn deinit(self: *ShiftReduceProfileEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.display_name);
        allocator.free(self.grammar_path);
        if (self.detail) |detail| allocator.free(detail);
        self.blocked_boundary.deinit(allocator);
        self.* = undefined;
    }
};

pub const ShiftReduceProfileReport = struct {
    schema_version: u32,
    profiled_target_count: usize,
    total_unresolved_states: usize,
    total_unresolved_entries: usize,
    aggregate_reasons: result_model.BlockedBoundaryReasonCounts,
    targets: []ShiftReduceProfileEntry,

    pub fn deinit(self: *ShiftReduceProfileReport, allocator: std.mem.Allocator) void {
        for (self.targets) |*entry| entry.deinit(allocator);
        allocator.free(self.targets);
        self.* = undefined;
    }
};

pub fn buildShiftReduceProfileAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !ShiftReduceProfileReport {
    var entries = std.array_list.Managed(ShiftReduceProfileEntry).init(allocator);
    defer entries.deinit();

    var total_unresolved_states: usize = 0;
    var total_unresolved_entries: usize = 0;
    var aggregate_reasons = result_model.BlockedBoundaryReasonCounts{};

    for (runs) |run| {
        if (run.mismatch_category != .shift_reduce_boundary) continue;
        const blocked_boundary = run.blocked_boundary orelse continue;

        total_unresolved_states += blocked_boundary.unresolved_state_count;
        total_unresolved_entries += blocked_boundary.unresolved_entry_count;
        aggregate_reasons.shift_reduce += blocked_boundary.reasons.shift_reduce;
        aggregate_reasons.reduce_reduce_deferred += blocked_boundary.reasons.reduce_reduce_deferred;
        aggregate_reasons.multiple_candidates += blocked_boundary.reasons.multiple_candidates;
        aggregate_reasons.unsupported_action_mix += blocked_boundary.reasons.unsupported_action_mix;

        try entries.append(.{
            .id = try allocator.dupe(u8, run.id),
            .display_name = try allocator.dupe(u8, run.display_name),
            .grammar_path = try allocator.dupe(u8, run.grammar_path),
            .candidate_status = run.candidate_status,
            .first_failed_stage = run.first_failed_stage,
            .detail = if (firstFailureDetail(run)) |detail| try allocator.dupe(u8, detail) else null,
            .blocked_boundary = try blocked_boundary.cloneAlloc(allocator),
        });
    }

    return .{
        .schema_version = 1,
        .profiled_target_count = entries.items.len,
        .total_unresolved_states = total_unresolved_states,
        .total_unresolved_entries = total_unresolved_entries,
        .aggregate_reasons = aggregate_reasons,
        .targets = try entries.toOwnedSlice(),
    };
}

pub fn renderShiftReduceProfileAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildShiftReduceProfileAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

fn firstFailureDetail(run: result_model.TargetRunResult) ?[]const u8 {
    if (run.first_failed_stage) |stage| {
        return switch (stage) {
            .load => run.load.detail,
            .prepare => run.prepare.detail,
            .serialize => run.serialize.detail,
            .scanner_boundary_check => run.scanner_boundary_check.detail,
            .emit_parser_tables => run.emit_parser_tables.detail,
            .emit_c_tables => run.emit_c_tables.detail,
            .emit_parser_c => run.emit_parser_c.detail,
            .compat_check => run.compat_check.detail,
            .compile_smoke => run.compile_smoke.detail,
        };
    }
    return null;
}

test "buildShiftReduceProfileAlloc reflects the current deferred parser-wave shift-reduce blocker set" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    var report = try buildShiftReduceProfileAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), report.profiled_target_count);
    try std.testing.expectEqual(@as(usize, 7), report.total_unresolved_states);
    try std.testing.expectEqual(@as(usize, 7), report.total_unresolved_entries);
    try std.testing.expectEqual(@as(usize, 7), report.aggregate_reasons.shift_reduce);
    try std.testing.expectEqual(@as(usize, 0), report.aggregate_reasons.reduce_reduce_deferred);
    try std.testing.expectEqual(@as(usize, 0), report.aggregate_reasons.multiple_candidates);
    try std.testing.expectEqual(@as(usize, 0), report.aggregate_reasons.unsupported_action_mix);
    try std.testing.expectEqual(@as(usize, 2), report.targets.len);
    try std.testing.expectEqualStrings("repeat_choice_seq_js", report.targets[0].id);
    try std.testing.expectEqual(targets.CandidateStatus.deferred_parser_wave, report.targets[0].candidate_status);
    try std.testing.expectEqualStrings("tree_sitter_ziggy_schema_json", report.targets[1].id);
    try std.testing.expectEqual(targets.CandidateStatus.deferred_parser_wave, report.targets[1].candidate_status);
}

test "renderShiftReduceProfileAlloc matches the checked-in shortlist shift-reduce artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    const rendered = try renderShiftReduceProfileAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.fs.cwd().readFileAlloc(allocator, "compat_targets/shortlist_shift_reduce_profile.json", 1024 * 1024);
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimRight(u8, expected, "\n");
    const normalized_rendered = std.mem.trimRight(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

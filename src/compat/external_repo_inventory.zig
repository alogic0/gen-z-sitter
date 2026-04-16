const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const ExternalRepoEntry = struct {
    id: []const u8,
    family: targets.TargetFamily,
    display_name: []const u8,
    grammar_path: []const u8,
    source_kind: targets.SourceKind,
    boundary_kind: targets.BoundaryKind,
    upstream_repository: ?[]const u8,
    upstream_revision: ?[]const u8,
    upstream_grammar_path: ?[]const u8,
    final_classification: result_model.FinalClassification,
    mismatch_category: result_model.MismatchCategory,
    notes: []const u8,
};

pub const ExternalRepoFamilyEntry = struct {
    family: targets.TargetFamily,
    boundary_kind: targets.BoundaryKind,
    target_count: usize,
    passed_count: usize,
};

pub const ExternalRepoBoundaryEntry = struct {
    boundary_kind: targets.BoundaryKind,
    target_count: usize,
    passed_count: usize,
};

pub const ExternalEvidenceNextStep = enum {
    onboard_additional_local_external_snapshots_when_available,
};

pub const ExternalRepoInventoryReport = struct {
    schema_version: u32,
    total_external_repo_targets: usize,
    passed_external_repo_targets: usize,
    family_coverage: []ExternalRepoFamilyEntry,
    boundary_coverage: []ExternalRepoBoundaryEntry,
    current_limitations: []const []const u8,
    recommended_next_step: ExternalEvidenceNextStep,
    targets: []ExternalRepoEntry,

    pub fn deinit(self: *ExternalRepoInventoryReport, allocator: std.mem.Allocator) void {
        allocator.free(self.family_coverage);
        allocator.free(self.boundary_coverage);
        deinitStringSlice(allocator, self.current_limitations);
        deinitEntries(allocator, self.targets);
        self.* = undefined;
    }
};

pub fn buildExternalRepoInventoryAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !ExternalRepoInventoryReport {
    return .{
        .schema_version = 1,
        .total_external_repo_targets = countExternalTargets(runs),
        .passed_external_repo_targets = countPassedExternalTargets(runs),
        .family_coverage = try collectFamilyCoverageAlloc(allocator, runs),
        .boundary_coverage = try collectBoundaryCoverageAlloc(allocator, runs),
        .current_limitations = try duplicateStringSliceAlloc(allocator, &.{
            "the current checked-in real external evidence is limited to 2 parser-only snapshots that were already available locally",
            "the current local workspace does not contain additional checked-out real grammar repos beyond the already snapshotted Ziggy sources",
            "no real external scanner or external-scanner snapshots are represented yet in the dedicated external-repo evidence artifact",
        }),
        .recommended_next_step = .onboard_additional_local_external_snapshots_when_available,
        .targets = try collectEntriesAlloc(allocator, runs),
    };
}

pub fn renderExternalRepoInventoryAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildExternalRepoInventoryAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

fn countExternalTargets(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.provenance.origin_kind == .external_repo_snapshot) count += 1;
    }
    return count;
}

fn countPassedExternalTargets(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.provenance.origin_kind != .external_repo_snapshot) continue;
        if (run.final_classification == .passed_within_current_boundary) count += 1;
    }
    return count;
}

fn collectFamilyCoverageAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]ExternalRepoFamilyEntry {
    var items = std.array_list.Managed(ExternalRepoFamilyEntry).init(allocator);
    defer items.deinit();

    for (runs) |run| {
        if (run.provenance.origin_kind != .external_repo_snapshot) continue;
        const index = findFamilyIndex(items.items, run.family) orelse blk: {
            try items.append(.{
                .family = run.family,
                .boundary_kind = run.boundary_kind,
                .target_count = 0,
                .passed_count = 0,
            });
            break :blk items.items.len - 1;
        };

        items.items[index].target_count += 1;
        if (run.final_classification == .passed_within_current_boundary) {
            items.items[index].passed_count += 1;
        }
    }

    return try items.toOwnedSlice();
}

fn collectBoundaryCoverageAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]ExternalRepoBoundaryEntry {
    var items = std.array_list.Managed(ExternalRepoBoundaryEntry).init(allocator);
    defer items.deinit();

    for (runs) |run| {
        if (run.provenance.origin_kind != .external_repo_snapshot) continue;
        const index = findBoundaryIndex(items.items, run.boundary_kind) orelse blk: {
            try items.append(.{
                .boundary_kind = run.boundary_kind,
                .target_count = 0,
                .passed_count = 0,
            });
            break :blk items.items.len - 1;
        };

        items.items[index].target_count += 1;
        if (run.final_classification == .passed_within_current_boundary) {
            items.items[index].passed_count += 1;
        }
    }

    return try items.toOwnedSlice();
}

fn findFamilyIndex(items: []const ExternalRepoFamilyEntry, family: targets.TargetFamily) ?usize {
    for (items, 0..) |item, index| {
        if (item.family == family) return index;
    }
    return null;
}

fn findBoundaryIndex(items: []const ExternalRepoBoundaryEntry, boundary_kind: targets.BoundaryKind) ?usize {
    for (items, 0..) |item, index| {
        if (item.boundary_kind == boundary_kind) return index;
    }
    return null;
}

fn collectEntriesAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]ExternalRepoEntry {
    var items = std.array_list.Managed(ExternalRepoEntry).init(allocator);
    defer items.deinit();

    for (runs) |run| {
        if (run.provenance.origin_kind != .external_repo_snapshot) continue;
        try items.append(.{
            .id = try allocator.dupe(u8, run.id),
            .family = run.family,
            .display_name = try allocator.dupe(u8, run.display_name),
            .grammar_path = try allocator.dupe(u8, run.grammar_path),
            .source_kind = run.source_kind,
            .boundary_kind = run.boundary_kind,
            .upstream_repository = if (run.provenance.upstream_repository) |value| try allocator.dupe(u8, value) else null,
            .upstream_revision = if (run.provenance.upstream_revision) |value| try allocator.dupe(u8, value) else null,
            .upstream_grammar_path = if (run.provenance.upstream_grammar_path) |value| try allocator.dupe(u8, value) else null,
            .final_classification = run.final_classification,
            .mismatch_category = run.mismatch_category,
            .notes = try allocator.dupe(u8, run.notes),
        });
    }

    return try items.toOwnedSlice();
}

fn deinitEntries(allocator: std.mem.Allocator, items: []ExternalRepoEntry) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.display_name);
        allocator.free(item.grammar_path);
        if (item.upstream_repository) |value| allocator.free(value);
        if (item.upstream_revision) |value| allocator.free(value);
        if (item.upstream_grammar_path) |value| allocator.free(value);
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

test "buildExternalRepoInventoryAlloc summarizes the current external evidence" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    var report = try buildExternalRepoInventoryAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), report.total_external_repo_targets);
    try std.testing.expectEqual(@as(usize, 2), report.passed_external_repo_targets);
    try std.testing.expectEqual(@as(usize, 2), report.family_coverage.len);
    try std.testing.expectEqual(@as(usize, 1), report.boundary_coverage.len);
    try std.testing.expectEqual(targets.BoundaryKind.parser_only, report.boundary_coverage[0].boundary_kind);
    try std.testing.expectEqual(targets.TargetFamily.ziggy, report.family_coverage[0].family);
    try std.testing.expectEqual(targets.TargetFamily.ziggy_schema, report.family_coverage[1].family);
    try std.testing.expectEqual(@as(usize, 3), report.current_limitations.len);
    try std.testing.expectEqual(ExternalEvidenceNextStep.onboard_additional_local_external_snapshots_when_available, report.recommended_next_step);
    try std.testing.expectEqual(@as(usize, 2), report.targets.len);
}

test "renderExternalRepoInventoryAlloc matches the checked-in external repo inventory artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const rendered = try renderExternalRepoInventoryAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.fs.cwd().readFileAlloc(allocator, "compat_targets/external_repo_inventory.json", 1024 * 1024);
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimRight(u8, expected, "\n");
    const normalized_rendered = std.mem.trimRight(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

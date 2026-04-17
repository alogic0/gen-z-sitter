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
    proof_scope: targets.RealExternalScannerProofScope,
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
    narrow_or_promote_onboarded_external_parser_targets,
    narrow_or_promote_onboarded_external_scanner_targets,
    broader_compatibility_polish,
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
    const total_external_repo_targets = countExternalTargets(runs);
    const passed_external_repo_targets = countPassedExternalTargets(runs);
    const total_external_parser_targets = countExternalTargetsByBoundary(runs, .parser_only);
    const passed_external_parser_targets = countPassedExternalTargetsByBoundary(runs, .parser_only);
    const total_external_scanner_targets = countExternalTargetsByBoundary(runs, .scanner_external_scanner);
    const passed_external_scanner_targets = countPassedExternalTargetsByBoundary(runs, .scanner_external_scanner);
    return .{
        .schema_version = 1,
        .total_external_repo_targets = total_external_repo_targets,
        .passed_external_repo_targets = passed_external_repo_targets,
        .family_coverage = try collectFamilyCoverageAlloc(allocator, runs),
        .boundary_coverage = try collectBoundaryCoverageAlloc(allocator, runs),
        .current_limitations = try collectCurrentLimitationsAlloc(
            allocator,
            total_external_repo_targets,
            passed_external_repo_targets,
            total_external_parser_targets,
            passed_external_parser_targets,
            total_external_scanner_targets,
            passed_external_scanner_targets,
        ),
        .recommended_next_step = if (total_external_parser_targets != 0 and passed_external_parser_targets < total_external_parser_targets)
            .narrow_or_promote_onboarded_external_parser_targets
        else if (total_external_scanner_targets != 0 and passed_external_scanner_targets == 0)
            .narrow_or_promote_onboarded_external_scanner_targets
        else if (total_external_scanner_targets != 0 and passed_external_scanner_targets > 0)
            .broader_compatibility_polish
        else
            .onboard_additional_local_external_snapshots_when_available,
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

fn countExternalTargetsByBoundary(
    runs: []const result_model.TargetRunResult,
    boundary_kind: targets.BoundaryKind,
) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.provenance.origin_kind != .external_repo_snapshot) continue;
        if (run.boundary_kind == boundary_kind) count += 1;
    }
    return count;
}

fn countPassedExternalTargetsByBoundary(
    runs: []const result_model.TargetRunResult,
    boundary_kind: targets.BoundaryKind,
) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (run.provenance.origin_kind != .external_repo_snapshot) continue;
        if (run.boundary_kind != boundary_kind) continue;
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
            .proof_scope = run.real_external_scanner_proof_scope,
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

fn collectCurrentLimitationsAlloc(
    allocator: std.mem.Allocator,
    total_external_repo_targets: usize,
    passed_external_repo_targets: usize,
    total_external_parser_targets: usize,
    passed_external_parser_targets: usize,
    total_external_scanner_targets: usize,
    passed_external_scanner_targets: usize,
) ![]const []const u8 {
    _ = total_external_repo_targets;
    _ = passed_external_repo_targets;

    if (total_external_parser_targets != 0 and passed_external_parser_targets < total_external_parser_targets) {
        return try duplicateStringSliceAlloc(allocator, &.{
            "the checked-in real external evidence now includes a larger parser-only snapshot that is still held at an explicit deferred parser boundary",
            "tree-sitter-c currently proves load and prepare cleanly, but the stable shortlist does not yet claim the full emitted and compiled parser surface for a grammar of that size",
            "real external scanner evidence and the promoted Ziggy parser-only snapshots remain passing while this larger parser-only target stays explicitly deferred",
        });
    }

    if (total_external_scanner_targets == 0) {
        return try duplicateStringSliceAlloc(allocator, &.{
            "the current checked-in real external evidence is limited to parser-only snapshots that were already available locally",
            "the current local workspace does not contain additional checked-out real grammar repos beyond the already snapshotted Ziggy sources",
            "no real external scanner or external-scanner snapshots are represented yet in the dedicated external-repo evidence artifact",
        });
    }

    if (passed_external_scanner_targets == 0) {
        return try duplicateStringSliceAlloc(allocator, &.{
            "the checked-in real external evidence now includes both parser-only and scanner-family snapshots, but the real external scanner evidence is still deferred",
            "tree-sitter-haskell is the first onboarded real external scanner snapshot and currently fails during external-boundary serialization because the scanner surface still uses unsupported features such as multiple external tokens and non-leading external steps",
            "real external parser-only evidence is currently broader and more mature than real external scanner evidence",
        });
    }

    return try duplicateStringSliceAlloc(allocator, &.{
        "the checked-in real external evidence now includes at least one passing external scanner-family snapshot",
        "the next step is to widen real external scanner-family coverage without collapsing parser-only and scanner evidence into a single flat claim",
    });
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

    try std.testing.expectEqual(@as(usize, 5), report.total_external_repo_targets);
    try std.testing.expectEqual(@as(usize, 4), report.passed_external_repo_targets);
    try std.testing.expectEqual(@as(usize, 5), report.family_coverage.len);
    try std.testing.expectEqual(@as(usize, 2), report.boundary_coverage.len);
    try std.testing.expectEqual(targets.BoundaryKind.parser_only, report.boundary_coverage[0].boundary_kind);
    try std.testing.expectEqual(targets.BoundaryKind.scanner_external_scanner, report.boundary_coverage[1].boundary_kind);
    try std.testing.expectEqual(targets.TargetFamily.ziggy, report.family_coverage[0].family);
    try std.testing.expectEqual(targets.TargetFamily.ziggy_schema, report.family_coverage[1].family);
    try std.testing.expectEqual(targets.TargetFamily.c, report.family_coverage[2].family);
    try std.testing.expectEqual(targets.TargetFamily.haskell, report.family_coverage[3].family);
    try std.testing.expectEqual(targets.TargetFamily.bash, report.family_coverage[4].family);
    try std.testing.expectEqual(@as(usize, 3), report.current_limitations.len);
    try std.testing.expectEqual(ExternalEvidenceNextStep.narrow_or_promote_onboarded_external_parser_targets, report.recommended_next_step);
    try std.testing.expectEqual(@as(usize, 5), report.targets.len);
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

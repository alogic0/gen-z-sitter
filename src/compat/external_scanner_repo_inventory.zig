const std = @import("std");
const json_support = @import("../support/json.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

pub const ExternalScannerRepoEntry = struct {
    id: []const u8,
    family: targets.TargetFamily,
    display_name: []const u8,
    grammar_path: []const u8,
    source_kind: targets.SourceKind,
    proof_scope: targets.RealExternalScannerProofScope,
    upstream_repository: ?[]const u8,
    upstream_revision: ?[]const u8,
    upstream_grammar_path: ?[]const u8,
    final_classification: result_model.FinalClassification,
    mismatch_category: result_model.MismatchCategory,
    notes: []const u8,
};

pub const ExternalScannerProofScopeEntry = struct {
    proof_scope: targets.RealExternalScannerProofScope,
    target_count: usize,
    passed_count: usize,
};

pub const ExternalScannerEvidenceNextStep = enum {
    acquire_or_snapshot_local_external_scanner_grammars,
    narrow_or_promote_onboarded_external_scanner_targets,
    broader_compatibility_polish,
};

pub const ExternalScannerRepoInventoryReport = struct {
    schema_version: u32,
    total_external_scanner_targets: usize,
    passed_external_scanner_targets: usize,
    proof_scope_coverage: []ExternalScannerProofScopeEntry,
    current_limitations: []const []const u8,
    recommended_next_step: ExternalScannerEvidenceNextStep,
    targets: []ExternalScannerRepoEntry,

    pub fn deinit(self: *ExternalScannerRepoInventoryReport, allocator: std.mem.Allocator) void {
        allocator.free(self.proof_scope_coverage);
        deinitStringSlice(allocator, self.current_limitations);
        deinitEntries(allocator, self.targets);
        self.* = undefined;
    }
};

pub fn buildExternalScannerRepoInventoryAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !ExternalScannerRepoInventoryReport {
    const total_external_scanner_targets = countExternalScannerTargets(runs);
    const passed_external_scanner_targets = countPassedExternalScannerTargets(runs);
    return .{
        .schema_version = 1,
        .total_external_scanner_targets = total_external_scanner_targets,
        .passed_external_scanner_targets = passed_external_scanner_targets,
        .proof_scope_coverage = try collectProofScopeCoverageAlloc(allocator, runs),
        .current_limitations = try collectCurrentLimitationsAlloc(
            allocator,
            total_external_scanner_targets,
            passed_external_scanner_targets,
        ),
        .recommended_next_step = if (total_external_scanner_targets == 0)
            .acquire_or_snapshot_local_external_scanner_grammars
        else if (passed_external_scanner_targets == 0)
            .narrow_or_promote_onboarded_external_scanner_targets
        else
            .broader_compatibility_polish,
        .targets = try collectEntriesAlloc(allocator, runs),
    };
}

pub fn renderExternalScannerRepoInventoryAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildExternalScannerRepoInventoryAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

fn countExternalScannerTargets(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (isExternalScannerTarget(run)) count += 1;
    }
    return count;
}

fn countPassedExternalScannerTargets(runs: []const result_model.TargetRunResult) usize {
    var count: usize = 0;
    for (runs) |run| {
        if (!isExternalScannerTarget(run)) continue;
        if (run.final_classification == .passed_within_current_boundary) count += 1;
    }
    return count;
}

fn isExternalScannerTarget(run: result_model.TargetRunResult) bool {
    return run.provenance.origin_kind == .external_repo_snapshot and
        run.boundary_kind == .scanner_external_scanner;
}

fn collectProofScopeCoverageAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]ExternalScannerProofScopeEntry {
    var items = std.array_list.Managed(ExternalScannerProofScopeEntry).init(allocator);
    defer items.deinit();

    for (runs) |run| {
        if (!isExternalScannerTarget(run)) continue;
        const index = findProofScopeIndex(items.items, run.real_external_scanner_proof_scope) orelse blk: {
            try items.append(.{
                .proof_scope = run.real_external_scanner_proof_scope,
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

fn findProofScopeIndex(
    items: []const ExternalScannerProofScopeEntry,
    proof_scope: targets.RealExternalScannerProofScope,
) ?usize {
    for (items, 0..) |item, index| {
        if (item.proof_scope == proof_scope) return index;
    }
    return null;
}

fn collectEntriesAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]ExternalScannerRepoEntry {
    var items = std.array_list.Managed(ExternalScannerRepoEntry).init(allocator);
    defer items.deinit();

    for (runs) |run| {
        if (!isExternalScannerTarget(run)) continue;
        try items.append(.{
            .id = try allocator.dupe(u8, run.id),
            .family = run.family,
            .display_name = try allocator.dupe(u8, run.display_name),
            .grammar_path = try allocator.dupe(u8, run.grammar_path),
            .source_kind = run.source_kind,
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
    total_external_scanner_targets: usize,
    passed_external_scanner_targets: usize,
) ![]const []const u8 {
    if (total_external_scanner_targets == 0) {
        return try duplicateStringSliceAlloc(allocator, &.{
            "no real external scanner or external-scanner snapshots are currently represented in the local compatibility shortlist",
            "the current workspace does not contain additional checked-out real scanner grammar repos beyond the already snapshotted parser-only Ziggy sources",
            "the checked-out tree-sitter-c and tree-sitter-zig repos under ~/prog/tree-sitter-grammars do not currently help for this milestone because their grammar.json snapshots declare externals as [] and they do not include scanner implementation files",
            "the repo has staged scanner-boundary proof, but it does not yet have real external scanner-family evidence",
        });
    }

    if (passed_external_scanner_targets == 0) {
        return try duplicateStringSliceAlloc(allocator, &.{
            "the checked-in real external scanner evidence now includes onboarded scanner snapshots, but none currently pass within the staged scanner boundary",
            "tree-sitter-haskell currently fails during external-boundary serialization because the scanner surface still uses unsupported features such as multiple external tokens and non-leading external steps",
            "the repo still has staged scanner-boundary proof, but real external scanner evidence remains narrower and deferred behind that first unsupported-feature boundary",
        });
    }

    return try duplicateStringSliceAlloc(allocator, &.{
        "real external scanner evidence is now represented by passing focused runtime-link fixtures",
        "the current real external scanner proof links and executes scanner.c, but remains focused on selected token paths rather than full upstream grammar parsing",
        "the next step is broader compatibility polish beyond the scanner ABI/link boundary",
    });
}

fn deinitEntries(allocator: std.mem.Allocator, items: []ExternalScannerRepoEntry) void {
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

test "buildExternalScannerRepoInventoryAlloc summarizes the current real external scanner evidence" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    var report = try buildExternalScannerRepoInventoryAlloc(allocator, runs);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 6), report.total_external_scanner_targets);
    try std.testing.expectEqual(@as(usize, 6), report.passed_external_scanner_targets);
    try std.testing.expectEqual(@as(usize, 1), report.proof_scope_coverage.len);
    try std.testing.expectEqual(targets.RealExternalScannerProofScope.full_runtime_link, report.proof_scope_coverage[0].proof_scope);
    try std.testing.expectEqual(@as(usize, 3), report.current_limitations.len);
    try std.testing.expectEqual(ExternalScannerEvidenceNextStep.broader_compatibility_polish, report.recommended_next_step);
    try std.testing.expectEqual(@as(usize, 6), report.targets.len);
}

test "renderExternalScannerRepoInventoryAlloc matches the checked-in external scanner repo inventory artifact" {
    const allocator = std.testing.allocator;
    const harness = @import("harness.zig");

    const runs = try harness.cachedShortlistTargetsForTests();

    const rendered = try renderExternalScannerRepoInventoryAlloc(allocator, runs);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "compat_targets/external_scanner_repo_inventory.json", allocator, .limited(1024 * 1024));
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimEnd(u8, expected, "\n");
    const normalized_rendered = std.mem.trimEnd(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

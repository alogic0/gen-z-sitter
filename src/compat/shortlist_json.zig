const std = @import("std");
const json_support = @import("../support/json.zig");
const targets = @import("targets.zig");

pub const ShortlistArtifact = struct {
    schema_version: u32,
    selection_rules: []const []const u8,
    disqualification_rules: []const []const u8,
    targets: []const ShortlistEntry,
};

pub const ShortlistEntry = struct {
    id: []const u8,
    family: targets.TargetFamily,
    boundary_kind: targets.BoundaryKind,
    status: targets.CandidateStatus,
    source_kind: targets.SourceKind,
    origin_kind: targets.OriginKind,
    grammar_path: []const u8,
    upstream_repository: ?[]const u8,
    upstream_revision: ?[]const u8,
    upstream_grammar_path: ?[]const u8,
    why: []const u8,
    success_means: []const u8,
};

pub fn renderShortlistArtifactAlloc(allocator: std.mem.Allocator) ![]u8 {
    const shortlist_entries = try collectShortlistEntriesAlloc(allocator, targets.shortlistTargets());
    defer allocator.free(shortlist_entries);

    return try json_support.stringifyAlloc(allocator, ShortlistArtifact{
        .schema_version = 1,
        .selection_rules = &selection_rules,
        .disqualification_rules = &disqualification_rules,
        .targets = shortlist_entries,
    });
}

fn collectShortlistEntriesAlloc(
    allocator: std.mem.Allocator,
    shortlist: []const targets.Target,
) ![]ShortlistEntry {
    const entries = try allocator.alloc(ShortlistEntry, shortlist.len);
    for (shortlist, 0..) |target, index| {
        entries[index] = .{
            .id = target.id,
            .family = target.family,
            .boundary_kind = target.boundary_kind,
            .status = target.candidate_status,
            .source_kind = target.source_kind,
            .origin_kind = target.provenance.origin_kind,
            .grammar_path = target.grammar_path,
            .upstream_repository = target.provenance.upstream_repository,
            .upstream_revision = target.provenance.upstream_revision,
            .upstream_grammar_path = target.provenance.upstream_grammar_path,
            .why = target.notes,
            .success_means = target.success_criteria,
        };
    }
    return entries;
}

const selection_rules = [_][]const u8{
    "parser-only first-wave targets must not require external scanners for their primary parse path",
    "scanner-wave targets may depend on the first external-scanner boundary if that dependency is explicit and staged",
    "grammar should avoid depending on runtime surfaces that the repo does not yet claim",
    "grammar should be small enough to keep harness iteration cheap",
    "the shortlist should include more than one grammar style",
};

const disqualification_rules = [_][]const u8{
    "requires broader scanner or runtime parity than the current staged surface",
    "depends on runtime or ABI surfaces explicitly deferred beyond current milestones",
    "is too large or brittle to serve as a stable first-wave harness target",
};

test "renderShortlistArtifactAlloc emits provenance-aware shortlist JSON" {
    const allocator = std.testing.allocator;

    const json = try renderShortlistArtifactAlloc(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"tree_sitter_ziggy_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mixed_semantics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"external_repo_snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"upstream_revision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scanner_external_scanner\"") != null);
}

test "renderShortlistArtifactAlloc matches the checked-in shortlist artifact" {
    const allocator = std.testing.allocator;

    const rendered = try renderShortlistArtifactAlloc(allocator);
    defer allocator.free(rendered);

    const expected = try std.fs.cwd().readFileAlloc(allocator, "compat_targets/shortlist.json", 1024 * 1024);
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimRight(u8, expected, "\n");
    const normalized_rendered = std.mem.trimRight(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

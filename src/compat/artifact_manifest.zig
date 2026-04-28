const std = @import("std");
const json_support = @import("../support/json.zig");

pub const RefreshKind = enum {
    routine_refresh,
    standalone_probe,
};

pub const ArtifactEntry = struct {
    path: []const u8,
    refresh_kind: RefreshKind,
    generator: []const u8,
    description: []const u8,
};

pub const ArtifactManifest = struct {
    schema_version: u32,
    routine_refresh_script: []const u8,
    standalone_probe_scripts: []const []const u8,
    artifacts: []const ArtifactEntry,
};

const standalone_probe_scripts = [_][]const u8{
    "update_parser_boundary_probe.zig",
};

const artifact_entries = [_]ArtifactEntry{
    .{
        .path = "compat_targets/shortlist.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "versioned shortlist and target metadata",
    },
    .{
        .path = "compat_targets/shortlist_inventory.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "aggregate shortlist boundary summary and family coverage",
    },
    .{
        .path = "compat_targets/shortlist_report.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "full machine-readable shortlist run report",
    },
    .{
        .path = "compat_targets/shortlist_mismatch_inventory.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "classified mismatch inventory for the current shortlist",
    },
    .{
        .path = "compat_targets/parser_boundary_profile.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "machine-readable profile for deferred parser-only targets",
    },
    .{
        .path = "compat_targets/coverage_decision.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "current recommended next milestone and rationale",
    },
    .{
        .path = "compat_targets/shortlist_shift_reduce_profile.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "focused shift-reduce blocker profile for deferred parser targets",
    },
    .{
        .path = "compat_targets/external_repo_inventory.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "inventory of real external snapshot evidence",
    },
    .{
        .path = "compat_targets/external_scanner_repo_inventory.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "inventory of real external scanner proof surfaces",
    },
    .{
        .path = "compat_targets/deferred_real_grammar_classification.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "classification notes for deferred JavaScript, Python, TypeScript, and Rust parser-wave targets",
    },
    .{
        .path = "compat_targets/release_boundary.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "compact staged release boundary summary for promoted grammars, deferred grammars, and known runtime-surface gaps",
    },
    .{
        .path = "compat_targets/artifact_manifest.json",
        .refresh_kind = .routine_refresh,
        .generator = "update_compat_artifacts.zig",
        .description = "machine-readable index of routine artifacts and standalone probes",
    },
    .{
        .path = "compat_targets/parser_boundary_probe.json",
        .refresh_kind = .standalone_probe,
        .generator = "update_parser_boundary_probe.zig",
        .description = "isolated parser-boundary probe output for heavier deferred parser experiments",
    },
};

pub fn renderArtifactManifestAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try json_support.stringifyAlloc(allocator, ArtifactManifest{
        .schema_version = 1,
        .routine_refresh_script = "update_compat_artifacts.zig",
        .standalone_probe_scripts = &standalone_probe_scripts,
        .artifacts = &artifact_entries,
    });
}

test "renderArtifactManifestAlloc matches the checked-in artifact manifest" {
    const allocator = std.testing.allocator;

    const rendered = try renderArtifactManifestAlloc(allocator);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "compat_targets/artifact_manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimEnd(u8, expected, "\n");
    const normalized_rendered = std.mem.trimEnd(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

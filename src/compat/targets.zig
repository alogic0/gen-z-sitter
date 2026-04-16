const std = @import("std");

pub const SourceKind = enum {
    grammar_json,
    grammar_js,
};

pub const OriginKind = enum {
    staged_in_repo,
    external_repo_snapshot,
};

pub const CandidateStatus = enum {
    intended_first_wave,
    deferred_later_wave,
    excluded_out_of_scope,
};

pub const Provenance = struct {
    origin_kind: OriginKind,
    upstream_repository: ?[]const u8 = null,
    upstream_revision: ?[]const u8 = null,
    upstream_grammar_path: ?[]const u8 = null,
};

pub const Target = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    source_kind: SourceKind,
    provenance: Provenance = .{ .origin_kind = .staged_in_repo },
    candidate_status: CandidateStatus,
    expected_blocked: bool = false,
    notes: []const u8,
    success_criteria: []const u8,
};

pub const shortlist_targets = [_]Target{
    .{
        .id = "parse_table_tiny_json",
        .display_name = "Parse Table Tiny (JSON)",
        .grammar_path = "compat_targets/parse_table_tiny/grammar.json",
        .source_kind = .grammar_json,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "smallest staged parser-only JSON target",
        .success_criteria = "load, prepare, emit all parser surfaces, pass compat-check, and compile emitted parser.c",
    },
    .{
        .id = "behavioral_config_json",
        .display_name = "Behavioral Config (JSON)",
        .grammar_path = "compat_targets/behavioral_config/grammar.json",
        .source_kind = .grammar_json,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "richer scanner-free JSON target",
        .success_criteria = "load, prepare, emit all parser surfaces, pass compat-check, and compile emitted parser.c",
    },
    .{
        .id = "repeat_choice_seq_js",
        .display_name = "Repeat Choice Seq (JS)",
        .grammar_path = "compat_targets/repeat_choice_seq/grammar.js",
        .source_kind = .grammar_js,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_first_wave,
        .expected_blocked = true,
        .notes = "parser-only JS target that exercises the staged blocked boundary",
        .success_criteria = "load through node, emit parser surfaces, and preserve the staged blocked boundary without infrastructure failure",
    },
    .{
        .id = "tree_sitter_ziggy_json",
        .display_name = "tree-sitter-ziggy (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_ziggy/grammar.json",
        .source_kind = .grammar_json,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-ziggy",
            .upstream_revision = "4353b20ef2ac750e35c6d68e4eb2a07c2d7cf901",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .deferred_later_wave,
        .expected_blocked = false,
        .notes = "real external parser-only grammar snapshot from the local tree-sitter-ziggy repo, deferred until its blocked parser-emission gap is classified for promotion",
        .success_criteria = "load the snapshotted upstream grammar.json and classify its current parser-only gap before promoting it into the first-wave run set",
    },
    .{
        .id = "tree_sitter_ziggy_schema_json",
        .display_name = "tree-sitter-ziggy-schema (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_ziggy_schema/grammar.json",
        .source_kind = .grammar_json,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-ziggy-schema",
            .upstream_revision = "4353b20ef2ac750e35c6d68e4eb2a07c2d7cf901",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .deferred_later_wave,
        .expected_blocked = false,
        .notes = "real external parser-only grammar snapshot from the local tree-sitter-ziggy-schema repo, deferred until its blocked parser-emission gap is classified for promotion after the word-token lowering fix",
        .success_criteria = "load the snapshotted upstream grammar.json and classify its current parser-only gap before promoting it into the first-wave run set",
    },
    .{
        .id = "parse_table_conflict_json",
        .display_name = "Parse Table Conflict (JSON)",
        .grammar_path = "compat_targets/parse_table_conflict/grammar.json",
        .source_kind = .grammar_json,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .deferred_later_wave,
        .expected_blocked = true,
        .notes = "parser-only ambiguity case deferred until mismatch classification is richer",
        .success_criteria = "classify the unresolved conflict boundary explicitly before promoting it into the first-wave run set",
    },
    .{
        .id = "hidden_external_fields_json",
        .display_name = "Hidden External Fields (JSON)",
        .grammar_path = "compat_targets/hidden_external_fields/grammar.json",
        .source_kind = .grammar_json,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .excluded_out_of_scope,
        .expected_blocked = false,
        .notes = "requires external scanner handling outside the current parser-only boundary",
        .success_criteria = "remain explicitly excluded until external-scanner coverage is in scope",
    },
};

pub fn shortlistTargets() []const Target {
    return shortlist_targets[0..];
}

pub fn firstWaveTargets() []const Target {
    return shortlist_targets[0..3];
}

test "stagedTargets exposes a small versioned shortlist" {
    const shortlist = shortlistTargets();
    try std.testing.expectEqual(@as(usize, 7), shortlist.len);
    try std.testing.expect(shortlist[0].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[3].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[3].candidate_status == .deferred_later_wave);
    try std.testing.expect(shortlist[5].candidate_status == .deferred_later_wave);
    try std.testing.expect(shortlist[6].candidate_status == .excluded_out_of_scope);
}

test "firstWaveTargets returns only the intended first-wave run set" {
    const shortlist = firstWaveTargets();
    try std.testing.expectEqual(@as(usize, 3), shortlist.len);
    try std.testing.expect(shortlist[0].source_kind == .grammar_json);
    try std.testing.expect(shortlist[2].source_kind == .grammar_js);
    for (shortlist) |target| {
        try std.testing.expect(target.candidate_status == .intended_first_wave);
    }
}

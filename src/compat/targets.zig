const std = @import("std");

pub const SourceKind = enum {
    grammar_json,
    grammar_js,
};

pub const BoundaryKind = enum {
    parser_only,
    scanner_external_scanner,
};

pub const TargetFamily = enum {
    parse_table_tiny,
    behavioral_config,
    repeat_choice_seq,
    ziggy,
    ziggy_schema,
    parse_table_conflict,
    hidden_external_fields,
    mixed_semantics,
};

pub const OriginKind = enum {
    staged_in_repo,
    external_repo_snapshot,
};

pub const CandidateStatus = enum {
    intended_first_wave,
    intended_scanner_wave,
    deferred_control_fixture,
    deferred_scanner_wave,
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
    family: TargetFamily,
    source_kind: SourceKind,
    boundary_kind: BoundaryKind = .parser_only,
    provenance: Provenance = .{ .origin_kind = .staged_in_repo },
    candidate_status: CandidateStatus,
    expected_blocked: bool = false,
    scanner_valid_input_path: ?[]const u8 = null,
    scanner_invalid_input_path: ?[]const u8 = null,
    notes: []const u8,
    success_criteria: []const u8,
};

pub const shortlist_targets = [_]Target{
    .{
        .id = "parse_table_tiny_json",
        .display_name = "Parse Table Tiny (JSON)",
        .grammar_path = "compat_targets/parse_table_tiny/grammar.json",
        .family = .parse_table_tiny,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
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
        .family = .behavioral_config,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
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
        .family = .repeat_choice_seq,
        .source_kind = .grammar_js,
        .boundary_kind = .parser_only,
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
        .family = .ziggy,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-ziggy",
            .upstream_revision = "4353b20ef2ac750e35c6d68e4eb2a07c2d7cf901",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "real external parser-only grammar snapshot from the local tree-sitter-ziggy repo, now promoted after the repeat-auxiliary shift/reduce fix",
        .success_criteria = "load the snapshotted upstream grammar.json, emit all parser surfaces, pass compat-check, and compile emitted parser.c",
    },
    .{
        .id = "tree_sitter_ziggy_schema_json",
        .display_name = "tree-sitter-ziggy-schema (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_ziggy_schema/grammar.json",
        .family = .ziggy_schema,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-ziggy-schema",
            .upstream_revision = "4353b20ef2ac750e35c6d68e4eb2a07c2d7cf901",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "real external parser-only grammar snapshot from the local tree-sitter-ziggy-schema repo, now promoted after the word-token lowering and repeat-auxiliary fixes",
        .success_criteria = "load the snapshotted upstream grammar.json, emit all parser surfaces, pass compat-check, and compile emitted parser.c",
    },
    .{
        .id = "parse_table_conflict_json",
        .display_name = "Parse Table Conflict (JSON)",
        .grammar_path = "compat_targets/parse_table_conflict/grammar.json",
        .family = .parse_table_conflict,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .deferred_control_fixture,
        .expected_blocked = true,
        .notes = "intentionally ambiguous parser-only control fixture kept deferred to preserve a known shift/reduce boundary without precedence annotations",
        .success_criteria = "remain explicitly blocked as a control case unless a later milestone intentionally broadens conflict-resolution policy",
    },
    .{
        .id = "hidden_external_fields_json",
        .display_name = "Hidden External Fields (JSON)",
        .grammar_path = "compat_targets/hidden_external_fields/grammar.json",
        .family = .hidden_external_fields,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_scanner_wave,
        .expected_blocked = false,
        .scanner_valid_input_path = "compat_targets/hidden_external_fields/valid.txt",
        .scanner_invalid_input_path = "compat_targets/hidden_external_fields/invalid.txt",
        .notes = "staged external-scanner JSON target promoted into the first scanner wave when the valid path stays compatibility-safe and the invalid path makes less progress through the first external boundary",
        .success_criteria = "load, prepare, extract the first external-scanner boundary, keep the valid path compatibility-safe, and ensure the invalid path makes less progress",
    },
    .{
        .id = "hidden_external_fields_js",
        .display_name = "Hidden External Fields (JS)",
        .grammar_path = "compat_targets/hidden_external_fields/grammar.js",
        .family = .hidden_external_fields,
        .source_kind = .grammar_js,
        .boundary_kind = .scanner_external_scanner,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_scanner_wave,
        .expected_blocked = false,
        .scanner_valid_input_path = "compat_targets/hidden_external_fields/valid.txt",
        .scanner_invalid_input_path = "compat_targets/hidden_external_fields/invalid.txt",
        .notes = "staged external-scanner JS target promoted into the first scanner wave when the valid path stays compatibility-safe and the invalid path makes less progress through the node loader and first external boundary",
        .success_criteria = "load through node, prepare, extract the first external-scanner boundary, keep the valid path compatibility-safe, and ensure the invalid path makes less progress",
    },
    .{
        .id = "mixed_semantics_json",
        .display_name = "Mixed Semantics (JSON)",
        .grammar_path = "compat_targets/mixed_semantics/grammar.json",
        .family = .mixed_semantics,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_scanner_wave,
        .expected_blocked = false,
        .scanner_valid_input_path = "compat_targets/mixed_semantics/valid.txt",
        .scanner_invalid_input_path = "compat_targets/mixed_semantics/invalid.txt",
        .notes = "staged external-scanner JSON target promoted in the second scanner wave when the first external boundary remains compatibility-safe even with extras present elsewhere in the grammar",
        .success_criteria = "load, prepare, extract the first external-scanner boundary, keep the valid path compatibility-safe, and ensure the invalid path makes less progress without depending on extras",
    },
    .{
        .id = "mixed_semantics_js",
        .display_name = "Mixed Semantics (JS)",
        .grammar_path = "compat_targets/mixed_semantics/grammar.js",
        .family = .mixed_semantics,
        .source_kind = .grammar_js,
        .boundary_kind = .scanner_external_scanner,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_scanner_wave,
        .expected_blocked = false,
        .scanner_valid_input_path = "compat_targets/mixed_semantics/valid.txt",
        .scanner_invalid_input_path = "compat_targets/mixed_semantics/invalid.txt",
        .notes = "staged external-scanner JS target mirroring mixed_semantics, promoted in the second scanner wave when the node loader preserves the same first-boundary behavior",
        .success_criteria = "load through node, prepare, extract the first external-scanner boundary, keep the valid path compatibility-safe, and ensure the invalid path makes less progress without depending on extras",
    },
};

pub fn shortlistTargets() []const Target {
    return shortlist_targets[0..];
}

pub fn firstWaveTargets() []const Target {
    return shortlist_targets[0..5];
}

test "stagedTargets exposes a small versioned shortlist" {
    const shortlist = shortlistTargets();
    try std.testing.expectEqual(@as(usize, 10), shortlist.len);
    try std.testing.expect(shortlist[0].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[3].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[3].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[5].candidate_status == .deferred_control_fixture);
    try std.testing.expect(shortlist[6].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[7].boundary_kind == .scanner_external_scanner);
    try std.testing.expect(shortlist[7].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[7].scanner_invalid_input_path != null);
    try std.testing.expect(shortlist[8].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[8].family == .mixed_semantics);
    try std.testing.expect(shortlist[8].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[9].source_kind == .grammar_js);
    try std.testing.expect(shortlist[9].family == .mixed_semantics);
}

test "firstWaveTargets returns only the intended first-wave run set" {
    const shortlist = firstWaveTargets();
    try std.testing.expectEqual(@as(usize, 5), shortlist.len);
    try std.testing.expect(shortlist[0].source_kind == .grammar_json);
    try std.testing.expect(shortlist[2].source_kind == .grammar_js);
    try std.testing.expect(shortlist[3].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[4].provenance.origin_kind == .external_repo_snapshot);
    for (shortlist) |target| {
        try std.testing.expect(target.candidate_status == .intended_first_wave);
    }
}

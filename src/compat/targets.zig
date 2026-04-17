const std = @import("std");

pub const SourceKind = enum {
    grammar_json,
    grammar_js,
};

pub const BoundaryKind = enum {
    parser_only,
    scanner_external_scanner,
};

pub const ParserBoundaryCheckMode = enum {
    full_pipeline,
    prepare_only,
    serialize_only,
};

pub const ScannerBoundaryCheckMode = enum {
    sampled_behavioral,
    sampled_external_only,
    structural_only,
};

pub const RealExternalScannerProofScope = enum {
    none,
    sampled_external_sequence,
    sampled_expansion_path,
};

pub const TargetFamily = enum {
    parse_table_tiny,
    behavioral_config,
    repeat_choice_seq,
    ziggy,
    ziggy_schema,
    c,
    haskell,
    bash,
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
    deferred_parser_wave,
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
    parser_boundary_check_mode: ParserBoundaryCheckMode = .full_pipeline,
    scanner_boundary_check_mode: ScannerBoundaryCheckMode = .sampled_behavioral,
    real_external_scanner_proof_scope: RealExternalScannerProofScope = .none,
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
        .id = "tree_sitter_c_json",
        .display_name = "tree-sitter-c (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_c/grammar.json",
        .family = .c,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .parser_boundary_check_mode = .prepare_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-c",
            .upstream_revision = "ae19b676b13bdcc13b7665397e6d9b14975473dd",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .deferred_parser_wave,
        .expected_blocked = false,
        .notes = "real external parser-only grammar snapshot from the local tree-sitter-c repo, kept at a prepare-only parser boundary while M34 evaluates serialize-only as the next stable proof layer for grammars of this size",
        .success_criteria = "load and prepare the snapshotted upstream grammar.json cleanly, and keep the next serialize-only parser-boundary step explicit until a later milestone proves a broader emitted surface",
    },
    .{
        .id = "tree_sitter_haskell_json",
        .display_name = "tree-sitter-haskell (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_haskell/grammar.json",
        .family = .haskell,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .scanner_boundary_check_mode = .sampled_external_only,
        .real_external_scanner_proof_scope = .sampled_external_sequence,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-haskell",
            .upstream_revision = "0975ef72fc3c47b530309ca93937d7d143523628",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_scanner_wave,
        .expected_blocked = false,
        .scanner_valid_input_path = "compat_targets/tree_sitter_haskell/valid.txt",
        .scanner_invalid_input_path = "compat_targets/tree_sitter_haskell/invalid.txt",
        .notes = "real external scanner grammar snapshot from the local tree-sitter-haskell repo, using indentation-sensitive layout externals and scanner.c; M30 promotes it into a sampled external-sequence proof layer before any broader parser-integrated scanner claim",
        .success_criteria = "load the snapshotted upstream grammar.json, extract the first external-scanner boundary, and prove a sampled real external scanner path makes stronger progress on the valid input than on the invalid input",
    },
    .{
        .id = "tree_sitter_bash_json",
        .display_name = "tree-sitter-bash (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_bash/grammar.json",
        .family = .bash,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .scanner_boundary_check_mode = .sampled_external_only,
        .real_external_scanner_proof_scope = .sampled_expansion_path,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-bash",
            .upstream_revision = "a06c2e4415e9bc0346c6b86d401879ffb44058f7",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_scanner_wave,
        .expected_blocked = false,
        .scanner_valid_input_path = "compat_targets/tree_sitter_bash/valid.txt",
        .scanner_invalid_input_path = "compat_targets/tree_sitter_bash/invalid.txt",
        .notes = "real external scanner grammar snapshot from the local tree-sitter-bash repo, promoted in M31 through a narrow sampled expansion path that exercises _bare_dollar and variable_name without claiming broader heredoc or full scanner.c runtime support",
        .success_criteria = "load the snapshotted upstream grammar.json, extract the first external-scanner boundary, and prove a sampled Bash expansion path makes stronger progress on the valid input than on the invalid input",
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
    try std.testing.expectEqual(@as(usize, 13), shortlist.len);
    try std.testing.expect(shortlist[0].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[3].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[3].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[5].candidate_status == .deferred_parser_wave);
    try std.testing.expect(shortlist[5].family == .c);
    try std.testing.expect(shortlist[5].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[5].parser_boundary_check_mode == .prepare_only);
    try std.testing.expect(shortlist[6].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[6].family == .haskell);
    try std.testing.expect(shortlist[6].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[6].scanner_boundary_check_mode == .sampled_external_only);
    try std.testing.expect(shortlist[6].real_external_scanner_proof_scope == .sampled_external_sequence);
    try std.testing.expect(shortlist[6].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[6].scanner_invalid_input_path != null);
    try std.testing.expect(shortlist[7].family == .bash);
    try std.testing.expect(shortlist[7].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[7].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[7].scanner_boundary_check_mode == .sampled_external_only);
    try std.testing.expect(shortlist[7].real_external_scanner_proof_scope == .sampled_expansion_path);
    try std.testing.expect(shortlist[7].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[7].scanner_invalid_input_path != null);
    try std.testing.expect(shortlist[8].candidate_status == .deferred_control_fixture);
    try std.testing.expect(shortlist[9].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[10].boundary_kind == .scanner_external_scanner);
    try std.testing.expect(shortlist[10].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[10].scanner_invalid_input_path != null);
    try std.testing.expect(shortlist[11].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[11].family == .mixed_semantics);
    try std.testing.expect(shortlist[11].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[12].source_kind == .grammar_js);
    try std.testing.expect(shortlist[12].family == .mixed_semantics);
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

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
    full_runtime_link,
};

pub const RealExternalScannerProofScope = enum {
    none,
    sampled_external_sequence,
    sampled_expansion_path,
    full_runtime_link,
};

pub const StandaloneParserProofScope = enum {
    none,
    coarse_serialize_only,
};

pub const TargetFamily = enum {
    parse_table_tiny,
    behavioral_config,
    repeat_choice_seq,
    ziggy,
    ziggy_schema,
    zig,
    json,
    javascript,
    python,
    typescript,
    rust,
    c,
    haskell,
    bash,
    parse_table_conflict,
    bracket_lang,
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
    standalone_parser_proof_scope: StandaloneParserProofScope = .none,
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
        .notes = "staged parser-only JS fixture intentionally mirrors an upstream-rejected ambiguity: tree-sitter reports an unresolved _entry shift/reduce conflict and requires associativity or an explicit conflict declaration",
        .success_criteria = "load through node and keep the upstream-rejected 2-entry _entry shift/reduce parser-boundary signature stable; this fixture must not be used as a parser-generation promotion target",
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
        .notes = "real external parser-only grammar snapshot from the local tree-sitter-ziggy-schema repo, now promoted after aligning repeat-auxiliary shift/reduce resolution with upstream tree-sitter behavior",
        .success_criteria = "load the snapshotted upstream grammar.json, emit all parser surfaces, pass compat-check, and compile emitted parser.c",
    },
    .{
        .id = "tree_sitter_c_json",
        .display_name = "tree-sitter-c (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_c/grammar.json",
        .family = .c,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .parser_boundary_check_mode = .serialize_only,
        .standalone_parser_proof_scope = .coarse_serialize_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-c",
            .upstream_revision = "ae19b676b13bdcc13b7665397e6d9b14975473dd",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "real external parser-only grammar snapshot from the local tree-sitter-c repo, now promoted through routine coarse serialize-only, parser-table emission, C-table emission, parser.c emission, compatibility validation, and compile-smoke",
        .success_criteria = "load, prepare, complete the routine coarse serialize-only parser step, emit parser tables plus C tables, emit parser.c, pass compatibility validation, and pass compile-smoke cleanly",
    },
    .{
        .id = "tree_sitter_zig_json",
        .display_name = "tree-sitter-zig (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_zig/grammar.json",
        .family = .zig,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .parser_boundary_check_mode = .serialize_only,
        .standalone_parser_proof_scope = .coarse_serialize_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-zig",
            .upstream_revision = "6479aa13f32f701c383083d8b28360ebd682fb7d",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "real external parser-only grammar snapshot from the local tree-sitter-zig repo, staged through the routine coarse parser boundary with focused accepted and invalid runtime-link proofs for a variable declaration sample",
        .success_criteria = "load, prepare, complete the routine coarse serialize-only parser step, keep parser.c compile-smoke evidence, and keep the focused Zig runtime-link samples passing under explicit bounded tests",
    },
    .{
        .id = "tree_sitter_json_json",
        .display_name = "tree-sitter-json (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_json/grammar.json",
        .family = .json,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-json",
            .upstream_revision = "001c28d7a29832b06b0e831ec77845553c89b56d",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "small real scanner-free parser-only snapshot from the local tree-sitter-json repo, added as the next fast end-to-end real-world regression target",
        .success_criteria = "load the snapshotted upstream grammar.json, emit all parser surfaces, pass compatibility validation, and compile emitted parser.c",
    },
    .{
        .id = "tree_sitter_haskell_json",
        .display_name = "tree-sitter-haskell (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_haskell/grammar.json",
        .family = .haskell,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .scanner_boundary_check_mode = .full_runtime_link,
        .real_external_scanner_proof_scope = .full_runtime_link,
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
        .notes = "real external scanner grammar snapshot from the local tree-sitter-haskell repo, with focused regular-parser and generated-GLR runtime-link proofs that compile generated parser C against the upstream scanner.c and exercise its initial update/start layout sequence plus a varsym token",
        .success_criteria = "load the snapshotted upstream grammar.json, extract the external-scanner boundary, and keep both focused Haskell scanner runtime-link fixtures passing against the real scanner.c",
    },
    .{
        .id = "tree_sitter_bash_json",
        .display_name = "tree-sitter-bash (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_bash/grammar.json",
        .family = .bash,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .scanner_boundary_check_mode = .full_runtime_link,
        .real_external_scanner_proof_scope = .full_runtime_link,
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
        .notes = "real external scanner grammar snapshot from the local tree-sitter-bash repo, with focused regular-parser and generated-GLR runtime-link proofs that compile generated parser C against the upstream scanner.c and exercise the bare-dollar external token ABI",
        .success_criteria = "load the snapshotted upstream grammar.json, extract the external-scanner boundary, and keep both focused Bash scanner runtime-link fixtures passing against the real scanner.c",
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
        .id = "bracket_lang_json",
        .display_name = "Bracket Lang (JSON)",
        .grammar_path = "compat_targets/bracket_lang/grammar.json",
        .family = .bracket_lang,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .scanner_boundary_check_mode = .full_runtime_link,
        .real_external_scanner_proof_scope = .full_runtime_link,
        .standalone_parser_proof_scope = .coarse_serialize_only,
        .provenance = .{ .origin_kind = .staged_in_repo },
        .candidate_status = .intended_scanner_wave,
        .expected_blocked = false,
        .notes = "staged recursive external-scanner runtime fixture that proves generated scanner tables through a full parser C link without claiming broad real-scanner promotion",
        .success_criteria = "load grammar.json, prepare, emit parser.c, compile with scanner.c, link against the tree-sitter runtime, parse (()), and assert the nested item tree has no ERROR root",
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
    .{
        .id = "tree_sitter_javascript_json",
        .display_name = "tree-sitter-javascript (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_javascript/grammar.json",
        .family = .javascript,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .parser_boundary_check_mode = .serialize_only,
        .standalone_parser_proof_scope = .coarse_serialize_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-javascript",
            .upstream_revision = "58404d8cf191d69f2674a8fd507bd5776f46cb11",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "real JavaScript grammar snapshot from the local tree-sitter-javascript repo, promoted to the bounded coarse serialize-only parser proof while full parser-table and scanner runtime proofs remain deferred",
        .success_criteria = "load, prepare, and complete the bounded coarse serialize-only parser step while keeping full parser-table and scanner runtime proofs deferred until bounded measurements are available",
    },
    .{
        .id = "tree_sitter_javascript_scanner_json",
        .display_name = "tree-sitter-javascript scanner (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_javascript/grammar.json",
        .family = .javascript,
        .source_kind = .grammar_json,
        .boundary_kind = .scanner_external_scanner,
        .scanner_boundary_check_mode = .full_runtime_link,
        .real_external_scanner_proof_scope = .full_runtime_link,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-javascript",
            .upstream_revision = "58404d8cf191d69f2674a8fd507bd5776f46cb11",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_scanner_wave,
        .expected_blocked = false,
        .notes = "real JavaScript external scanner proof that links generated parser C against the upstream scanner.c and exercises the ternary_qmark token path",
        .success_criteria = "load the snapshotted upstream grammar.json, extract the external-scanner boundary, and keep a focused JavaScript ternary_qmark runtime-link fixture passing against the real scanner.c",
    },
    .{
        .id = "tree_sitter_python_json",
        .display_name = "tree-sitter-python (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_python/grammar.json",
        .family = .python,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .parser_boundary_check_mode = .serialize_only,
        .standalone_parser_proof_scope = .coarse_serialize_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-python",
            .upstream_revision = "26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "real Python grammar snapshot from the local tree-sitter-python repo, now promoted to the bounded coarse serialize-only parser proof while full parser-table and external-scanner runtime-link proofs remain deferred",
        .success_criteria = "load, prepare, and complete the bounded coarse serialize-only parser step while keeping full parser-table and external-scanner runtime-link proofs deferred until bounded measurements are available",
    },
    .{
        .id = "tree_sitter_typescript_json",
        .display_name = "tree-sitter-typescript (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_typescript/grammar.json",
        .family = .typescript,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .parser_boundary_check_mode = .serialize_only,
        .standalone_parser_proof_scope = .coarse_serialize_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-typescript",
            .upstream_revision = "75b3874edb2dc714fb1fd77a32013d0f8699989f",
            .upstream_grammar_path = "typescript/src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "real TypeScript grammar snapshot from the local tree-sitter-typescript repo, now promoted to the bounded coarse serialize-only parser proof while full parser-table and runtime-link proofs remain deferred",
        .success_criteria = "load, prepare, and complete the bounded coarse serialize-only parser step while keeping full parser-table and runtime-link proofs deferred until bounded measurements are available",
    },
    .{
        .id = "tree_sitter_rust_json",
        .display_name = "tree-sitter-rust (JSON snapshot)",
        .grammar_path = "compat_targets/tree_sitter_rust/grammar.json",
        .family = .rust,
        .source_kind = .grammar_json,
        .boundary_kind = .parser_only,
        .parser_boundary_check_mode = .serialize_only,
        .standalone_parser_proof_scope = .coarse_serialize_only,
        .provenance = .{
            .origin_kind = .external_repo_snapshot,
            .upstream_repository = "tree-sitter-rust",
            .upstream_revision = "77a3747266f4d621d0757825e6b11edcbf991ca5",
            .upstream_grammar_path = "src/grammar.json",
        },
        .candidate_status = .intended_first_wave,
        .expected_blocked = false,
        .notes = "real Rust grammar snapshot from the local tree-sitter-rust repo, now promoted to the bounded coarse serialize-only parser proof while full lookahead-sensitive parser-table emission remains deferred",
        .success_criteria = "load, prepare, and complete the bounded coarse serialize-only parser step while keeping full parser-table and runtime-link proofs deferred until bounded measurements are available",
    },
};

pub fn shortlistTargets() []const Target {
    return shortlist_targets[0..];
}

const first_wave_targets = [_]Target{
    shortlist_targets[0],
    shortlist_targets[1],
    shortlist_targets[3],
    shortlist_targets[4],
    shortlist_targets[5],
    shortlist_targets[6],
    shortlist_targets[7],
};

pub fn firstWaveTargets() []const Target {
    return first_wave_targets[0..];
}

test "stagedTargets exposes a small versioned shortlist" {
    const shortlist = shortlistTargets();
    try std.testing.expectEqual(@as(usize, 21), shortlist.len);
    try std.testing.expect(shortlist[0].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[3].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[3].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[5].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[5].family == .c);
    try std.testing.expect(shortlist[5].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[5].parser_boundary_check_mode == .serialize_only);
    try std.testing.expect(shortlist[6].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[6].family == .zig);
    try std.testing.expect(shortlist[6].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[6].parser_boundary_check_mode == .serialize_only);
    try std.testing.expect(shortlist[6].standalone_parser_proof_scope == .coarse_serialize_only);
    try std.testing.expect(shortlist[7].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[7].family == .json);
    try std.testing.expect(shortlist[7].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[8].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[8].family == .haskell);
    try std.testing.expect(shortlist[8].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[8].scanner_boundary_check_mode == .full_runtime_link);
    try std.testing.expect(shortlist[8].real_external_scanner_proof_scope == .full_runtime_link);
    try std.testing.expect(shortlist[8].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[8].scanner_invalid_input_path != null);
    try std.testing.expect(shortlist[9].family == .bash);
    try std.testing.expect(shortlist[9].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[9].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[9].scanner_boundary_check_mode == .full_runtime_link);
    try std.testing.expect(shortlist[9].real_external_scanner_proof_scope == .full_runtime_link);
    try std.testing.expect(shortlist[9].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[9].scanner_invalid_input_path != null);
    try std.testing.expect(shortlist[10].candidate_status == .deferred_control_fixture);
    try std.testing.expect(shortlist[11].family == .bracket_lang);
    try std.testing.expect(shortlist[11].scanner_boundary_check_mode == .full_runtime_link);
    try std.testing.expect(shortlist[11].real_external_scanner_proof_scope == .full_runtime_link);
    try std.testing.expect(shortlist[11].standalone_parser_proof_scope == .coarse_serialize_only);
    try std.testing.expect(shortlist[12].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[13].boundary_kind == .scanner_external_scanner);
    try std.testing.expect(shortlist[13].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[13].scanner_invalid_input_path != null);
    try std.testing.expect(shortlist[14].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[14].family == .mixed_semantics);
    try std.testing.expect(shortlist[14].scanner_valid_input_path != null);
    try std.testing.expect(shortlist[15].source_kind == .grammar_js);
    try std.testing.expect(shortlist[15].family == .mixed_semantics);
    try std.testing.expect(shortlist[16].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[16].family == .javascript);
    try std.testing.expect(shortlist[16].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[16].parser_boundary_check_mode == .serialize_only);
    try std.testing.expect(shortlist[16].standalone_parser_proof_scope == .coarse_serialize_only);
    try std.testing.expect(shortlist[17].candidate_status == .intended_scanner_wave);
    try std.testing.expect(shortlist[17].family == .javascript);
    try std.testing.expect(shortlist[17].boundary_kind == .scanner_external_scanner);
    try std.testing.expect(shortlist[17].scanner_boundary_check_mode == .full_runtime_link);
    try std.testing.expect(shortlist[17].real_external_scanner_proof_scope == .full_runtime_link);
    try std.testing.expect(shortlist[18].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[18].family == .python);
    try std.testing.expect(shortlist[18].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[18].parser_boundary_check_mode == .serialize_only);
    try std.testing.expect(shortlist[18].standalone_parser_proof_scope == .coarse_serialize_only);
    try std.testing.expect(shortlist[19].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[19].family == .typescript);
    try std.testing.expect(shortlist[19].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[19].parser_boundary_check_mode == .serialize_only);
    try std.testing.expect(shortlist[19].standalone_parser_proof_scope == .coarse_serialize_only);
    try std.testing.expect(shortlist[20].candidate_status == .intended_first_wave);
    try std.testing.expect(shortlist[20].family == .rust);
    try std.testing.expect(shortlist[20].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[20].parser_boundary_check_mode == .serialize_only);
    try std.testing.expect(shortlist[20].standalone_parser_proof_scope == .coarse_serialize_only);
}

test "firstWaveTargets returns only the intended first-wave run set" {
    const shortlist = firstWaveTargets();
    try std.testing.expectEqual(@as(usize, 7), shortlist.len);
    try std.testing.expect(shortlist[0].source_kind == .grammar_json);
    try std.testing.expect(shortlist[2].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[3].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expect(shortlist[4].provenance.origin_kind == .external_repo_snapshot);
    try std.testing.expectEqualStrings("tree_sitter_ziggy_json", shortlist[2].id);
    try std.testing.expectEqualStrings("tree_sitter_ziggy_schema_json", shortlist[3].id);
    try std.testing.expectEqualStrings("tree_sitter_c_json", shortlist[4].id);
    try std.testing.expectEqualStrings("tree_sitter_zig_json", shortlist[5].id);
    try std.testing.expectEqualStrings("tree_sitter_json_json", shortlist[6].id);
    for (shortlist) |target| {
        try std.testing.expect(target.candidate_status == .intended_first_wave);
    }
}

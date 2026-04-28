const std = @import("std");
const targets = @import("targets.zig");

pub const StepName = enum {
    load,
    prepare,
    serialize,
    scanner_boundary_check,
    emit_parser_tables,
    emit_parser_c,
    compat_check,
    compile_smoke,
};

pub const StepStatus = enum {
    not_run,
    passed,
    failed,
};

pub const FinalClassification = enum {
    passed_within_current_boundary,
    frozen_control_fixture,
    deferred_for_parser_boundary,
    deferred_for_scanner_boundary,
    failed_due_to_parser_only_gap,
    out_of_scope_for_scanner_boundary,
    infrastructure_failure,
};

pub const MismatchCategory = enum {
    none,
    grammar_input_load_mismatch,
    preparation_lowering_mismatch,
    routine_serialize_proof_boundary,
    routine_emitted_surface_proof_boundary,
    scanner_external_scanner_boundary_gap,
    parse_table_construction_gap,
    shift_reduce_boundary,
    intentional_control_fixture,
    emitted_surface_structural_gap,
    compile_smoke_failure,
    out_of_scope_scanner_boundary,
    infrastructure_failure,
};

pub const StepResult = struct {
    status: StepStatus = .not_run,
    detail: ?[]const u8 = null,

    pub fn deinit(self: *StepResult, allocator: std.mem.Allocator) void {
        if (self.detail) |detail| allocator.free(detail);
        self.* = .{};
    }
};

pub const ParseConstructProfileSnapshot = struct {
    states_processed: usize = 0,
    successor_groups: usize = 0,
    successor_seed_items: usize = 0,
    state_intern_calls: usize = 0,
    state_intern_reused: usize = 0,
    state_intern_new: usize = 0,
    state_items_stored: usize = 0,
    closure_cache_hits: usize = 0,
    closure_cache_misses: usize = 0,
    closure_runs: usize = 0,
    closure_items_returned: usize = 0,
    closure_expansion_cache_hits: usize = 0,
    closure_expansion_cache_misses: usize = 0,
    successor_seed_cache_hits: usize = 0,
    successor_seed_cache_misses: usize = 0,
    item_set_hash_calls: usize = 0,
    item_set_hash_entries: usize = 0,
    item_set_eql_calls: usize = 0,
    item_set_eql_entries: usize = 0,
    symbol_set_init_empty_count: usize = 0,
    symbol_set_clone_count: usize = 0,
    symbol_set_free_count: usize = 0,
    symbol_set_alloc_bytes: usize = 0,
    symbol_set_free_bytes: usize = 0,
    collect_transitions_ns: u64 = 0,
    extra_transitions_ns: u64 = 0,
    reserved_word_ns: u64 = 0,
    build_actions_ns: u64 = 0,
    detect_conflicts_ns: u64 = 0,
};

pub const LexEmissionSnapshot = struct {
    table_count: usize = 0,
    state_count: usize = 0,
    transition_count: usize = 0,
    range_count: usize = 0,
    accept_state_count: usize = 0,
    eof_target_count: usize = 0,
    skip_transition_count: usize = 0,
    large_range_transition_count: usize = 0,
    max_transition_range_count: usize = 0,
    keyword_state_count: usize = 0,
    keyword_transition_count: usize = 0,
    keyword_range_count: usize = 0,
};

pub const EmissionSnapshot = struct {
    blocked: bool,
    serialized_state_count: usize,
    emitted_state_count: usize,
    merged_state_count: usize,
    action_entry_count: usize,
    goto_entry_count: usize,
    unresolved_entry_count: usize,
    parser_tables_bytes: usize,
    parser_c_bytes: usize,
    lex_function_bytes: usize = 0,
    keyword_lex_function_bytes: usize = 0,
    emit_parser_c_ms: ?f64 = null,
    compile_smoke_ms: ?f64 = null,
    compile_smoke_max_rss_bytes: ?usize = null,
    parse_construct_profile: ?ParseConstructProfileSnapshot = null,
    lex: ?LexEmissionSnapshot = null,
};

pub const BlockedSymbolKind = enum {
    terminal,
    non_terminal,
    external,
};

pub const BlockedBoundaryReasonCounts = struct {
    shift_reduce: usize = 0,
    reduce_reduce_deferred: usize = 0,
    reduce_reduce_expected: usize = 0,
    multiple_candidates: usize = 0,
    unsupported_action_mix: usize = 0,
};

pub const BlockedBoundarySample = struct {
    state_id: u32,
    symbol_kind: BlockedSymbolKind,
    symbol_index: u32,
    symbol_name: []const u8,
    reason: []const u8,
    candidate_count: usize,
    candidate_actions_summary: []const u8,

    pub fn cloneAlloc(self: BlockedBoundarySample, allocator: std.mem.Allocator) !BlockedBoundarySample {
        return .{
            .state_id = self.state_id,
            .symbol_kind = self.symbol_kind,
            .symbol_index = self.symbol_index,
            .symbol_name = try allocator.dupe(u8, self.symbol_name),
            .reason = try allocator.dupe(u8, self.reason),
            .candidate_count = self.candidate_count,
            .candidate_actions_summary = try allocator.dupe(u8, self.candidate_actions_summary),
        };
    }
};

pub const BlockedBoundarySignature = struct {
    symbol_name: []const u8,
    reason: []const u8,
    candidate_actions_summary: []const u8,
    count: usize,

    pub fn cloneAlloc(self: BlockedBoundarySignature, allocator: std.mem.Allocator) !BlockedBoundarySignature {
        return .{
            .symbol_name = try allocator.dupe(u8, self.symbol_name),
            .reason = try allocator.dupe(u8, self.reason),
            .candidate_actions_summary = try allocator.dupe(u8, self.candidate_actions_summary),
            .count = self.count,
        };
    }
};

pub const BlockedBoundarySnapshot = struct {
    unresolved_state_count: usize,
    unresolved_entry_count: usize,
    reasons: BlockedBoundaryReasonCounts,
    samples: []const BlockedBoundarySample,
    dominant_signatures: []const BlockedBoundarySignature,

    pub fn cloneAlloc(self: BlockedBoundarySnapshot, allocator: std.mem.Allocator) !BlockedBoundarySnapshot {
        const cloned_samples = try allocator.alloc(BlockedBoundarySample, self.samples.len);
        var initialized: usize = 0;
        errdefer {
            for (cloned_samples[0..initialized]) |cloned_sample| {
                allocator.free(cloned_sample.symbol_name);
                allocator.free(cloned_sample.reason);
                allocator.free(cloned_sample.candidate_actions_summary);
            }
            allocator.free(cloned_samples);
        }

        const cloned_signatures = try allocator.alloc(BlockedBoundarySignature, self.dominant_signatures.len);
        var initialized_signatures: usize = 0;
        errdefer {
            for (cloned_signatures[0..initialized_signatures]) |cloned_signature| {
                allocator.free(cloned_signature.symbol_name);
                allocator.free(cloned_signature.reason);
                allocator.free(cloned_signature.candidate_actions_summary);
            }
            allocator.free(cloned_signatures);
        }

        for (self.samples, 0..) |sample, index| {
            cloned_samples[index] = try sample.cloneAlloc(allocator);
            initialized += 1;
        }

        for (self.dominant_signatures, 0..) |signature, index| {
            cloned_signatures[index] = try signature.cloneAlloc(allocator);
            initialized_signatures += 1;
        }

        return .{
            .unresolved_state_count = self.unresolved_state_count,
            .unresolved_entry_count = self.unresolved_entry_count,
            .reasons = self.reasons,
            .samples = cloned_samples,
            .dominant_signatures = cloned_signatures,
        };
    }

    pub fn deinit(self: *BlockedBoundarySnapshot, allocator: std.mem.Allocator) void {
        for (self.samples) |sample| {
            allocator.free(sample.symbol_name);
            allocator.free(sample.reason);
            allocator.free(sample.candidate_actions_summary);
        }
        allocator.free(self.samples);
        for (self.dominant_signatures) |signature| {
            allocator.free(signature.symbol_name);
            allocator.free(signature.reason);
            allocator.free(signature.candidate_actions_summary);
        }
        allocator.free(self.dominant_signatures);
        self.* = undefined;
    }
};

pub const TargetRunResult = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    family: targets.TargetFamily,
    source_kind: targets.SourceKind,
    boundary_kind: targets.BoundaryKind = .parser_only,
    parser_boundary_check_mode: targets.ParserBoundaryCheckMode = .full_pipeline,
    real_external_scanner_proof_scope: targets.RealExternalScannerProofScope = .none,
    standalone_parser_proof_scope: targets.StandaloneParserProofScope = .none,
    provenance: targets.Provenance,
    candidate_status: targets.CandidateStatus,
    expected_blocked: bool,
    notes: []const u8,
    success_criteria: []const u8,
    first_failed_stage: ?StepName = null,
    final_classification: FinalClassification = .passed_within_current_boundary,
    mismatch_category: MismatchCategory = .none,
    load: StepResult = .{},
    prepare: StepResult = .{},
    serialize: StepResult = .{},
    emit_parser_tables: StepResult = .{},
    emit_parser_c: StepResult = .{},
    scanner_boundary_check: StepResult = .{},
    compat_check: StepResult = .{},
    compile_smoke: StepResult = .{},
    emission: ?EmissionSnapshot = null,
    blocked_boundary: ?BlockedBoundarySnapshot = null,

    pub fn init(target: targets.Target) TargetRunResult {
        return .{
            .id = target.id,
            .display_name = target.display_name,
            .grammar_path = target.grammar_path,
            .family = target.family,
            .source_kind = target.source_kind,
            .boundary_kind = target.boundary_kind,
            .parser_boundary_check_mode = target.parser_boundary_check_mode,
            .real_external_scanner_proof_scope = target.real_external_scanner_proof_scope,
            .standalone_parser_proof_scope = target.standalone_parser_proof_scope,
            .provenance = target.provenance,
            .candidate_status = target.candidate_status,
            .expected_blocked = target.expected_blocked,
            .notes = target.notes,
            .success_criteria = target.success_criteria,
        };
    }

    pub fn deinit(self: *TargetRunResult, allocator: std.mem.Allocator) void {
        self.load.deinit(allocator);
        self.prepare.deinit(allocator);
        self.serialize.deinit(allocator);
        self.emit_parser_tables.deinit(allocator);
        self.emit_parser_c.deinit(allocator);
        self.scanner_boundary_check.deinit(allocator);
        self.compat_check.deinit(allocator);
        self.compile_smoke.deinit(allocator);
        if (self.blocked_boundary) |*blocked_boundary| blocked_boundary.deinit(allocator);
        self.* = undefined;
    }
};

pub fn deinitRunResults(allocator: std.mem.Allocator, results: []TargetRunResult) void {
    for (results) |*run| run.deinit(allocator);
    allocator.free(results);
}

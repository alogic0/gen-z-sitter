const std = @import("std");
const targets = @import("targets.zig");

pub const StepName = enum {
    load,
    prepare,
    serialize,
    emit_parser_tables,
    emit_c_tables,
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
    failed_due_to_parser_only_gap,
    out_of_scope_for_scanner_boundary,
    infrastructure_failure,
};

pub const MismatchCategory = enum {
    none,
    grammar_input_load_mismatch,
    preparation_lowering_mismatch,
    parse_table_construction_gap,
    shift_reduce_boundary,
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

pub const EmissionSnapshot = struct {
    blocked: bool,
    serialized_state_count: usize,
    emitted_state_count: usize,
    merged_state_count: usize,
    action_entry_count: usize,
    goto_entry_count: usize,
    unresolved_entry_count: usize,
    parser_tables_bytes: usize,
    c_tables_bytes: usize,
    parser_c_bytes: usize,
};

pub const TargetRunResult = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    source_kind: targets.SourceKind,
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
    emit_c_tables: StepResult = .{},
    emit_parser_c: StepResult = .{},
    compat_check: StepResult = .{},
    compile_smoke: StepResult = .{},
    emission: ?EmissionSnapshot = null,

    pub fn init(target: targets.Target) TargetRunResult {
        return .{
            .id = target.id,
            .display_name = target.display_name,
            .grammar_path = target.grammar_path,
            .source_kind = target.source_kind,
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
        self.emit_c_tables.deinit(allocator);
        self.emit_parser_c.deinit(allocator);
        self.compat_check.deinit(allocator);
        self.compile_smoke.deinit(allocator);
        self.* = undefined;
    }
};

pub fn deinitRunResults(allocator: std.mem.Allocator, results: []TargetRunResult) void {
    for (results) |*run| run.deinit(allocator);
    allocator.free(results);
}

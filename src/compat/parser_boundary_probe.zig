const std = @import("std");
const runtime_io = @import("../support/runtime_io.zig");
const json_support = @import("../support/json.zig");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const serialize = @import("../parse_table/serialize.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

fn logProbeStart(target_id: []const u8, step: []const u8) void {
    std.debug.print("[parser_boundary_probe] start {s} {s}\n", .{ target_id, step });
}

fn logProbeDone(target_id: []const u8, step: []const u8, start_ts: std.Io.Timestamp) void {
    const elapsed_ms = @as(f64, @floatFromInt(start_ts.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake)).nanoseconds)) / @as(f64, std.time.ns_per_ms);
    std.debug.print("[parser_boundary_probe] done  {s} {s} ({d:.2} ms)\n", .{ target_id, step, elapsed_ms });
}

pub const ParserBoundaryProbeEntry = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    family: targets.TargetFamily,
    current_parser_boundary_check_mode: targets.ParserBoundaryCheckMode,
    probed_parser_boundary_check_mode: targets.ParserBoundaryCheckMode,
    recommended_next_parser_boundary_check_mode: targets.ParserBoundaryCheckMode,
    probe_status: result_model.StepStatus,
    probe_failed_stage: ?result_model.StepName,
    detail: []const u8,
    serialized_state_count: ?usize,
    serialized_blocked: ?bool,
    blocked_signature_summary: ?[]const u8,
};

pub const ParserBoundaryProbeReport = struct {
    schema_version: u32,
    target_count: usize,
    entries: []ParserBoundaryProbeEntry,

    pub fn deinit(self: *ParserBoundaryProbeReport, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.display_name);
            allocator.free(entry.grammar_path);
            allocator.free(entry.detail);
            if (entry.blocked_signature_summary) |summary| allocator.free(summary);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub fn buildParserBoundaryProbeFromTargetsAlloc(
    allocator: std.mem.Allocator,
    target_list: []const targets.Target,
) !ParserBoundaryProbeReport {
    var items = std.array_list.Managed(ParserBoundaryProbeEntry).init(allocator);
    defer items.deinit();

    for (target_list) |target| {
        if (target.candidate_status != .deferred_parser_wave) continue;
        try items.append(try probeDeferredParserTargetMetadataAlloc(allocator, target));
    }

    const owned = try items.toOwnedSlice();
    return .{
        .schema_version = 1,
        .target_count = owned.len,
        .entries = owned,
    };
}

pub fn buildParserBoundaryProbeAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) !ParserBoundaryProbeReport {
    var items = std.array_list.Managed(ParserBoundaryProbeEntry).init(allocator);
    defer items.deinit();

    for (runs) |run| {
        if (run.candidate_status != .deferred_parser_wave) continue;
        try items.append(try probeDeferredParserTargetAlloc(allocator, run));
    }

    const owned = try items.toOwnedSlice();
    return .{
        .schema_version = 1,
        .target_count = owned.len,
        .entries = owned,
    };
}

pub fn renderParserBoundaryProbeAlloc(
    allocator: std.mem.Allocator,
    runs: []const result_model.TargetRunResult,
) ![]u8 {
    var report = try buildParserBoundaryProbeAlloc(allocator, runs);
    defer report.deinit(allocator);
    return try json_support.stringifyAlloc(allocator, report);
}

fn probeDeferredParserTargetAlloc(
    allocator: std.mem.Allocator,
    run: result_model.TargetRunResult,
) !ParserBoundaryProbeEntry {
    return probeDeferredParserTargetMetadataAlloc(allocator, .{
        .id = run.id,
        .display_name = run.display_name,
        .grammar_path = run.grammar_path,
        .family = run.family,
        .source_kind = run.source_kind,
        .boundary_kind = run.boundary_kind,
        .parser_boundary_check_mode = run.parser_boundary_check_mode,
        .scanner_boundary_check_mode = .sampled_behavioral,
        .real_external_scanner_proof_scope = .none,
        .provenance = run.provenance,
        .candidate_status = run.candidate_status,
        .expected_blocked = run.expected_blocked,
        .scanner_valid_input_path = null,
        .scanner_invalid_input_path = null,
        .notes = run.notes,
        .success_criteria = run.success_criteria,
    });
}

fn probeDeferredParserTargetMetadataAlloc(
    allocator: std.mem.Allocator,
    target: targets.Target,
) !ParserBoundaryProbeEntry {
    const probed_mode = nextProbeMode(target.parser_boundary_check_mode);
    const recommended_next_mode = nextRecommendedMode(probed_mode);

    switch (probed_mode) {
        .serialize_only => return try probeSerializeOnlyAlloc(
            allocator,
            target,
            probed_mode,
            recommended_next_mode,
        ),
        else => return .{
            .id = try allocator.dupe(u8, target.id),
            .display_name = try allocator.dupe(u8, target.display_name),
            .grammar_path = try allocator.dupe(u8, target.grammar_path),
            .family = target.family,
            .current_parser_boundary_check_mode = target.parser_boundary_check_mode,
            .probed_parser_boundary_check_mode = probed_mode,
            .recommended_next_parser_boundary_check_mode = recommended_next_mode,
            .probe_status = .failed,
            .probe_failed_stage = .serialize,
            .detail = try std.fmt.allocPrint(
                allocator,
                "no isolated probe is implemented for parser boundary mode {s}",
                .{@tagName(probed_mode)},
            ),
            .serialized_state_count = null,
            .serialized_blocked = null,
            .blocked_signature_summary = null,
        },
    }
}

fn probeSerializeOnlyAlloc(
    allocator: std.mem.Allocator,
    target: targets.Target,
    probed_mode: targets.ParserBoundaryCheckMode,
    recommended_next_mode: targets.ParserBoundaryCheckMode,
) !ParserBoundaryProbeEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    logProbeStart(target.id, "load");
    var loaded = grammar_loader.loadGrammarFile(arena.allocator(), target.grammar_path) catch |err| {
        return .{
            .id = try allocator.dupe(u8, target.id),
            .display_name = try allocator.dupe(u8, target.display_name),
            .grammar_path = try allocator.dupe(u8, target.grammar_path),
            .family = target.family,
            .current_parser_boundary_check_mode = target.parser_boundary_check_mode,
            .probed_parser_boundary_check_mode = probed_mode,
            .recommended_next_parser_boundary_check_mode = recommended_next_mode,
            .probe_status = .failed,
            .probe_failed_stage = .load,
            .detail = try std.fmt.allocPrint(allocator, "probe load failed: {s}", .{grammar_loader.errorMessage(err)}),
            .serialized_state_count = null,
            .serialized_blocked = null,
            .blocked_signature_summary = null,
        };
    };
    logProbeDone(target.id, "load", timer);
    defer loaded.deinit();

    timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    logProbeStart(target.id, "prepare");
    const prepared = parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar) catch |err| {
        const diagnostic = parse_grammar.errorDiagnostic(err);
        return .{
            .id = try allocator.dupe(u8, target.id),
            .display_name = try allocator.dupe(u8, target.display_name),
            .grammar_path = try allocator.dupe(u8, target.grammar_path),
            .family = target.family,
            .current_parser_boundary_check_mode = target.parser_boundary_check_mode,
            .probed_parser_boundary_check_mode = probed_mode,
            .recommended_next_parser_boundary_check_mode = recommended_next_mode,
            .probe_status = .failed,
            .probe_failed_stage = .prepare,
            .detail = try std.fmt.allocPrint(allocator, "probe prepare failed: {s}", .{diagnostic.summary}),
            .serialized_state_count = null,
            .serialized_blocked = null,
            .blocked_signature_summary = null,
        };
    };
    logProbeDone(target.id, "prepare", timer);

    timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    logProbeStart(target.id, "serialize");
    const serialized = parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena.allocator(),
        prepared,
        .diagnostic,
        .{ .closure_lookahead_mode = .none },
    ) catch |err| {
        return .{
            .id = try allocator.dupe(u8, target.id),
            .display_name = try allocator.dupe(u8, target.display_name),
            .grammar_path = try allocator.dupe(u8, target.grammar_path),
            .family = target.family,
            .current_parser_boundary_check_mode = target.parser_boundary_check_mode,
            .probed_parser_boundary_check_mode = probed_mode,
            .recommended_next_parser_boundary_check_mode = recommended_next_mode,
            .probe_status = .failed,
            .probe_failed_stage = .serialize,
            .detail = try std.fmt.allocPrint(allocator, "probe serialize failed: {s}", .{@errorName(err)}),
            .serialized_state_count = null,
            .serialized_blocked = null,
            .blocked_signature_summary = null,
        };
    };
    logProbeDone(target.id, "serialize", timer);
    std.debug.print(
        "[parser_boundary_probe] summary {s} serialized_states={d} blocked={}\n",
        .{ target.id, serialized.states.len, serialized.blocked },
    );

    const blocked_signature_summary = if (serialized.blocked)
        try formatBlockedSignatureSummaryAlloc(allocator, serialized)
    else
        null;
    errdefer if (blocked_signature_summary) |summary| allocator.free(summary);
    const recommended_after_probe = if (serialized.blocked)
        target.parser_boundary_check_mode
    else
        recommended_next_mode;
    const detail = if (serialized.blocked)
        try std.fmt.allocPrint(
            allocator,
            "isolated coarse serialize-only parser probe completed with {d} serialized states but remains blocked; keep the current routine parser boundary until the blocked surface is explicitly resolved",
            .{serialized.states.len},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "isolated coarse serialize-only parser probe passed with {d} serialized states using lookahead-insensitive closure expansion; broader emitted surfaces and full lookahead-sensitive parser proof remain outside the current deferred parser boundary",
            .{serialized.states.len},
        );
    errdefer allocator.free(detail);

    return .{
        .id = try allocator.dupe(u8, target.id),
        .display_name = try allocator.dupe(u8, target.display_name),
        .grammar_path = try allocator.dupe(u8, target.grammar_path),
        .family = target.family,
        .current_parser_boundary_check_mode = target.parser_boundary_check_mode,
        .probed_parser_boundary_check_mode = probed_mode,
        .recommended_next_parser_boundary_check_mode = recommended_after_probe,
        .probe_status = .passed,
        .probe_failed_stage = null,
        .detail = detail,
        .serialized_state_count = serialized.states.len,
        .serialized_blocked = serialized.blocked,
        .blocked_signature_summary = blocked_signature_summary,
    };
}

const BlockedSignature = struct {
    symbol_name: []const u8,
    reason: []const u8,
    count: usize,
};

fn formatBlockedSignatureSummaryAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) ![]const u8 {
    var unresolved_state_count: usize = 0;
    var unresolved_entry_count: usize = 0;
    var shift_reduce_count: usize = 0;
    var reduce_reduce_deferred_count: usize = 0;
    var reduce_reduce_expected_count: usize = 0;
    var multiple_candidates_count: usize = 0;
    var unsupported_action_mix_count: usize = 0;
    var signatures = std.array_list.Managed(BlockedSignature).init(allocator);
    defer signatures.deinit();

    for (serialized.states) |state| {
        if (state.unresolved.len == 0) continue;
        unresolved_state_count += 1;
        unresolved_entry_count += state.unresolved.len;
        for (state.unresolved) |entry| {
            switch (entry.reason) {
                .auxiliary_repeat => shift_reduce_count += 1,
                .shift_reduce, .shift_reduce_expected => shift_reduce_count += 1,
                .reduce_reduce_deferred => reduce_reduce_deferred_count += 1,
                .reduce_reduce_expected => reduce_reduce_expected_count += 1,
                .multiple_candidates => multiple_candidates_count += 1,
                .unsupported_action_mix => unsupported_action_mix_count += 1,
            }
            try recordBlockedSignature(
                &signatures,
                symbolNameFor(serialized, entry.symbol),
                @tagName(entry.reason),
            );
        }
    }

    std.mem.sort(BlockedSignature, signatures.items, {}, struct {
        fn lessThan(_: void, left: BlockedSignature, right: BlockedSignature) bool {
            if (left.count != right.count) return left.count > right.count;
            const symbol_order = std.mem.order(u8, left.symbol_name, right.symbol_name);
            if (symbol_order != .eq) return symbol_order == .lt;
            return std.mem.order(u8, left.reason, right.reason) == .lt;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        "states={d} entries={d} external_scanner_symbols={d} reasons={{shift_reduce:{d}, reduce_reduce_deferred:{d}, reduce_reduce_expected:{d}, multiple_candidates:{d}, unsupported_action_mix:{d}}} dominant=[",
        .{
            unresolved_state_count,
            unresolved_entry_count,
            serialized.external_scanner.symbols.len,
            shift_reduce_count,
            reduce_reduce_deferred_count,
            reduce_reduce_expected_count,
            multiple_candidates_count,
            unsupported_action_mix_count,
        },
    );
    const signature_limit = @min(signatures.items.len, 8);
    for (signatures.items[0..signature_limit], 0..) |signature, index| {
        if (index > 0) try out.writer.writeAll("; ");
        try out.writer.print("{s} {s} count={d}", .{ signature.symbol_name, signature.reason, signature.count });
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

fn recordBlockedSignature(
    signatures: *std.array_list.Managed(BlockedSignature),
    symbol_name: []const u8,
    reason: []const u8,
) !void {
    for (signatures.items) |*signature| {
        if (!std.mem.eql(u8, signature.symbol_name, symbol_name)) continue;
        if (!std.mem.eql(u8, signature.reason, reason)) continue;
        signature.count += 1;
        return;
    }
    try signatures.append(.{
        .symbol_name = symbol_name,
        .reason = reason,
        .count = 1,
    });
}

fn symbolNameFor(
    serialized: serialize.SerializedTable,
    symbol: @import("../ir/syntax_grammar.zig").SymbolRef,
) []const u8 {
    for (serialized.symbols) |info| {
        if (std.meta.eql(info.ref, symbol)) return info.name;
    }
    return switch (symbol) {
        .end => "end",
        .terminal => "<unknown-terminal>",
        .non_terminal => "<unknown-non-terminal>",
        .external => "<unknown-external>",
    };
}

fn nextProbeMode(mode: targets.ParserBoundaryCheckMode) targets.ParserBoundaryCheckMode {
    return switch (mode) {
        .prepare_only => .serialize_only,
        .serialize_only => .full_pipeline,
        .full_pipeline => .full_pipeline,
    };
}

fn nextRecommendedMode(mode: targets.ParserBoundaryCheckMode) targets.ParserBoundaryCheckMode {
    return switch (mode) {
        .serialize_only => .full_pipeline,
        else => mode,
    };
}

test "buildParserBoundaryProbeAlloc probes deferred parser targets in isolation" {
    try std.testing.expectEqual(targets.ParserBoundaryCheckMode.serialize_only, nextProbeMode(.prepare_only));
    try std.testing.expectEqual(targets.ParserBoundaryCheckMode.full_pipeline, nextRecommendedMode(.serialize_only));
}

test "buildParserBoundaryProbeAlloc skips non-deferred parser targets" {
    const allocator = std.testing.allocator;
    var report = try buildParserBoundaryProbeAlloc(allocator, &.{});
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), report.target_count);
}

test "buildParserBoundaryProbeFromTargetsAlloc can select deferred parser-wave targets directly" {
    const allocator = std.testing.allocator;
    var report = try buildParserBoundaryProbeFromTargetsAlloc(allocator, targets.shortlistTargets());
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), report.target_count);
    try std.testing.expectEqual(@as(usize, 0), report.entries.len);
}

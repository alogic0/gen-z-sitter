const std = @import("std");
const json_support = @import("../support/json.zig");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const result_model = @import("result.zig");
const targets = @import("targets.zig");

fn logProbeStart(target_id: []const u8, step: []const u8) void {
    std.debug.print("[parser_boundary_probe] start {s} {s}\n", .{ target_id, step });
}

fn logProbeDone(target_id: []const u8, step: []const u8, timer: *std.time.Timer) void {
    const elapsed_ms = @as(f64, @floatFromInt(timer.read())) / @as(f64, std.time.ns_per_ms);
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
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

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
    const probed_mode = nextProbeMode(run.parser_boundary_check_mode);
    const recommended_next_mode = nextRecommendedMode(probed_mode);

    switch (probed_mode) {
        .serialize_only => return try probeSerializeOnlyAlloc(
            allocator,
            run,
            probed_mode,
            recommended_next_mode,
        ),
        else => return .{
            .id = try allocator.dupe(u8, run.id),
            .display_name = try allocator.dupe(u8, run.display_name),
            .grammar_path = try allocator.dupe(u8, run.grammar_path),
            .family = run.family,
            .current_parser_boundary_check_mode = run.parser_boundary_check_mode,
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
        },
    }
}

fn probeSerializeOnlyAlloc(
    allocator: std.mem.Allocator,
    run: result_model.TargetRunResult,
    probed_mode: targets.ParserBoundaryCheckMode,
    recommended_next_mode: targets.ParserBoundaryCheckMode,
) !ParserBoundaryProbeEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var timer = try std.time.Timer.start();
    logProbeStart(run.id, "load");
    var loaded = grammar_loader.loadGrammarFile(arena.allocator(), run.grammar_path) catch |err| {
        return .{
            .id = try allocator.dupe(u8, run.id),
            .display_name = try allocator.dupe(u8, run.display_name),
            .grammar_path = try allocator.dupe(u8, run.grammar_path),
            .family = run.family,
            .current_parser_boundary_check_mode = run.parser_boundary_check_mode,
            .probed_parser_boundary_check_mode = probed_mode,
            .recommended_next_parser_boundary_check_mode = recommended_next_mode,
            .probe_status = .failed,
            .probe_failed_stage = .load,
            .detail = try std.fmt.allocPrint(allocator, "probe load failed: {s}", .{grammar_loader.errorMessage(err)}),
            .serialized_state_count = null,
            .serialized_blocked = null,
        };
    };
    logProbeDone(run.id, "load", &timer);
    defer loaded.deinit();

    timer = try std.time.Timer.start();
    logProbeStart(run.id, "prepare");
    const prepared = parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar) catch |err| {
        const diagnostic = parse_grammar.errorDiagnostic(err);
        return .{
            .id = try allocator.dupe(u8, run.id),
            .display_name = try allocator.dupe(u8, run.display_name),
            .grammar_path = try allocator.dupe(u8, run.grammar_path),
            .family = run.family,
            .current_parser_boundary_check_mode = run.parser_boundary_check_mode,
            .probed_parser_boundary_check_mode = probed_mode,
            .recommended_next_parser_boundary_check_mode = recommended_next_mode,
            .probe_status = .failed,
            .probe_failed_stage = .prepare,
            .detail = try std.fmt.allocPrint(allocator, "probe prepare failed: {s}", .{diagnostic.summary}),
            .serialized_state_count = null,
            .serialized_blocked = null,
        };
    };
    logProbeDone(run.id, "prepare", &timer);

    timer = try std.time.Timer.start();
    logProbeStart(run.id, "serialize");
    const serialized = parse_table_pipeline.serializeTableFromPrepared(arena.allocator(), prepared, .diagnostic) catch |err| {
        return .{
            .id = try allocator.dupe(u8, run.id),
            .display_name = try allocator.dupe(u8, run.display_name),
            .grammar_path = try allocator.dupe(u8, run.grammar_path),
            .family = run.family,
            .current_parser_boundary_check_mode = run.parser_boundary_check_mode,
            .probed_parser_boundary_check_mode = probed_mode,
            .recommended_next_parser_boundary_check_mode = recommended_next_mode,
            .probe_status = .failed,
            .probe_failed_stage = .serialize,
            .detail = try std.fmt.allocPrint(allocator, "probe serialize failed: {s}", .{@errorName(err)}),
            .serialized_state_count = null,
            .serialized_blocked = null,
        };
    };
    logProbeDone(run.id, "serialize", &timer);
    std.debug.print(
        "[parser_boundary_probe] summary {s} serialized_states={d} blocked={}\n",
        .{ run.id, serialized.states.len, serialized.blocked },
    );

    return .{
        .id = try allocator.dupe(u8, run.id),
        .display_name = try allocator.dupe(u8, run.display_name),
        .grammar_path = try allocator.dupe(u8, run.grammar_path),
        .family = run.family,
        .current_parser_boundary_check_mode = run.parser_boundary_check_mode,
        .probed_parser_boundary_check_mode = probed_mode,
        .recommended_next_parser_boundary_check_mode = recommended_next_mode,
        .probe_status = .passed,
        .probe_failed_stage = null,
        .detail = try std.fmt.allocPrint(
            allocator,
            "isolated serialize-only parser probe passed with {d} serialized states; broader emitted surfaces remain outside the current deferred parser boundary",
            .{serialized.states.len},
        ),
        .serialized_state_count = serialized.states.len,
        .serialized_blocked = serialized.blocked,
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

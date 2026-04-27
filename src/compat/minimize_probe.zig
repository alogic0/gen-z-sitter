const std = @import("std");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const targets = @import("targets.zig");

pub const MinimizationProbe = struct {
    target_id: []const u8,
    default_state_count: usize,
    minimized_state_count: usize,

    pub fn mergedCount(self: MinimizationProbe) usize {
        return self.default_state_count - self.minimized_state_count;
    }
};

pub const MinimizationAggregate = struct {
    target_count: usize,
    default_state_count: usize,
    minimized_state_count: usize,
    merged_state_count: usize,

    pub fn addProbe(self: *MinimizationAggregate, probe: MinimizationProbe) void {
        self.target_count += 1;
        self.default_state_count += probe.default_state_count;
        self.minimized_state_count += probe.minimized_state_count;
        self.merged_state_count += probe.mergedCount();
    }
};

pub const SkippedMinimizationTarget = struct {
    target_id: []const u8,
    reason: []const u8,
};

pub const MinimizationReport = struct {
    probes: []const MinimizationProbe,
    skipped: []const SkippedMinimizationTarget,
    aggregate: MinimizationAggregate,

    pub fn deinit(self: MinimizationReport, allocator: std.mem.Allocator) void {
        allocator.free(self.probes);
    }
};

const bounded_target_ids = [_][]const u8{
    "parse_table_tiny_json",
    "behavioral_config_json",
    "parse_table_conflict_json",
    "bracket_lang_json",
    "hidden_external_fields_json",
    "mixed_semantics_json",
};

const skipped_targets = [_]SkippedMinimizationTarget{
    .{
        .target_id = "repeat_choice_seq_js",
        .reason = "blocked control grammar that upstream rejects as ambiguous",
    },
    .{
        .target_id = "tree_sitter_ziggy_json",
        .reason = "large real-grammar snapshot kept out of fast unit minimization probes",
    },
    .{
        .target_id = "tree_sitter_ziggy_schema_json",
        .reason = "large real-grammar snapshot kept out of fast unit minimization probes",
    },
    .{
        .target_id = "tree_sitter_c_json",
        .reason = "large real-grammar snapshot kept out of fast unit minimization probes",
    },
    .{
        .target_id = "tree_sitter_zig_json",
        .reason = "large real-grammar snapshot kept out of fast unit minimization probes",
    },
    .{
        .target_id = "tree_sitter_json_json",
        .reason = "real parser-only snapshot kept out of fast unit minimization probes",
    },
    .{
        .target_id = "tree_sitter_javascript_json",
        .reason = "large real parser-only snapshot kept out of fast unit minimization probes",
    },
    .{
        .target_id = "tree_sitter_haskell_json",
        .reason = "large real external-scanner snapshot kept out of fast unit minimization probes",
    },
    .{
        .target_id = "tree_sitter_bash_json",
        .reason = "large real external-scanner snapshot kept out of fast unit minimization probes",
    },
    .{
        .target_id = "hidden_external_fields_js",
        .reason = "JS-loader variant kept out of the fast minimization probe",
    },
    .{
        .target_id = "mixed_semantics_js",
        .reason = "JS-loader variant kept out of the fast minimization probe",
    },
};

pub fn boundedTargetIds() []const []const u8 {
    return bounded_target_ids[0..];
}

pub fn skippedTargets() []const SkippedMinimizationTarget {
    return skipped_targets[0..];
}

pub fn probeTargetAlloc(
    allocator: std.mem.Allocator,
    target: targets.Target,
) !MinimizationProbe {
    var loaded = try grammar_loader.loadGrammarFile(allocator, target.grammar_path);
    defer loaded.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &loaded.json.grammar);
    const default_result = try parse_table_pipeline.buildStatesFromPreparedWithOptions(
        allocator,
        prepared,
        .{},
    );
    const minimized_result = try parse_table_pipeline.buildStatesFromPreparedWithOptions(
        allocator,
        prepared,
        .{ .minimize_states = true },
    );

    return .{
        .target_id = target.id,
        .default_state_count = default_result.states.len,
        .minimized_state_count = minimized_result.states.len,
    };
}

pub fn aggregateProbes(probes: []const MinimizationProbe) MinimizationAggregate {
    var aggregate: MinimizationAggregate = .{
        .target_count = 0,
        .default_state_count = 0,
        .minimized_state_count = 0,
        .merged_state_count = 0,
    };
    for (probes) |probe| aggregate.addProbe(probe);
    return aggregate;
}

pub fn buildBoundedReportAlloc(allocator: std.mem.Allocator) !MinimizationReport {
    const probes = try allocator.alloc(MinimizationProbe, boundedTargetIds().len);
    errdefer allocator.free(probes);

    for (boundedTargetIds(), 0..) |target_id, index| {
        const target = findTarget(target_id) orelse return error.UnknownTarget;
        probes[index] = try probeTargetAlloc(allocator, target);
    }

    return .{
        .probes = probes,
        .skipped = skippedTargets(),
        .aggregate = aggregateProbes(probes),
    };
}

pub fn renderReportJsonAlloc(
    allocator: std.mem.Allocator,
    report: MinimizationReport,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n");
    try writer.writeAll("  \"aggregate\": { ");
    try writer.print("\"target_count\": {d}, ", .{report.aggregate.target_count});
    try writer.print("\"default_state_count\": {d}, ", .{report.aggregate.default_state_count});
    try writer.print("\"minimized_state_count\": {d}, ", .{report.aggregate.minimized_state_count});
    try writer.print("\"merged_state_count\": {d}", .{report.aggregate.merged_state_count});
    try writer.writeAll(" },\n");

    try writer.writeAll("  \"probes\": [\n");
    for (report.probes, 0..) |probe, index| {
        try writer.writeAll("    { ");
        try writer.writeAll("\"target_id\": ");
        try writeJsonString(writer, probe.target_id);
        try writer.print(", \"default_state_count\": {d}, ", .{probe.default_state_count});
        try writer.print("\"minimized_state_count\": {d}, ", .{probe.minimized_state_count});
        try writer.print("\"merged_state_count\": {d}", .{probe.mergedCount()});
        try writer.writeAll(" }");
        if (index + 1 != report.probes.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.writeAll("  ],\n");

    try writer.writeAll("  \"skipped\": [\n");
    for (report.skipped, 0..) |skipped, index| {
        try writer.writeAll("    { ");
        try writer.writeAll("\"target_id\": ");
        try writeJsonString(writer, skipped.target_id);
        try writer.writeAll(", \"reason\": ");
        try writeJsonString(writer, skipped.reason);
        try writer.writeAll(" }");
        if (index + 1 != report.skipped.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.writeAll("  ]\n");
    try writer.writeAll("}\n");

    return try out.toOwnedSlice();
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn isBoundedTarget(target_id: []const u8) bool {
    for (boundedTargetIds()) |bounded_id| {
        if (std.mem.eql(u8, bounded_id, target_id)) return true;
    }
    return false;
}

fn skippedTargetReason(target_id: []const u8) ?[]const u8 {
    for (skippedTargets()) |skipped| {
        if (std.mem.eql(u8, skipped.target_id, target_id)) return skipped.reason;
    }
    return null;
}

fn findTarget(target_id: []const u8) ?targets.Target {
    for (targets.shortlistTargets()) |target| {
        if (std.mem.eql(u8, target.id, target_id)) return target;
    }
    return null;
}

fn expectBoundedTargetMinimization(target_id: []const u8) !MinimizationProbe {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const target = findTarget(target_id) orelse return error.UnknownTarget;
    const probe = try probeTargetAlloc(arena.allocator(), target);
    try std.testing.expectEqualStrings(target_id, probe.target_id);
    try std.testing.expect(probe.default_state_count > 0);
    try std.testing.expect(probe.minimized_state_count > 0);
    try std.testing.expect(probe.minimized_state_count <= probe.default_state_count);
    return probe;
}

test "bounded compat minimization probe keeps safe target state counts monotonic" {
    for (boundedTargetIds()) |target_id| {
        _ = try expectBoundedTargetMinimization(target_id);
    }
}

test "bounded compat minimization probe reports merged count from state delta" {
    const probe = try expectBoundedTargetMinimization("parse_table_tiny_json");
    try std.testing.expectEqual(
        probe.default_state_count - probe.minimized_state_count,
        probe.mergedCount(),
    );
}

test "bounded compat minimization probe classifies every shortlist target" {
    var classified_count: usize = 0;
    for (targets.shortlistTargets()) |target| {
        if (isBoundedTarget(target.id)) {
            classified_count += 1;
            continue;
        }
        const reason = skippedTargetReason(target.id) orelse return error.UnclassifiedTarget;
        try std.testing.expect(reason.len > 0);
        classified_count += 1;
    }

    try std.testing.expectEqual(targets.shortlistTargets().len, classified_count);
    try std.testing.expectEqual(
        targets.shortlistTargets().len,
        boundedTargetIds().len + skippedTargets().len,
    );
}

test "bounded compat minimization probe aggregates target state counts" {
    const probes = [_]MinimizationProbe{
        try expectBoundedTargetMinimization("parse_table_tiny_json"),
        try expectBoundedTargetMinimization("behavioral_config_json"),
        try expectBoundedTargetMinimization("parse_table_conflict_json"),
        try expectBoundedTargetMinimization("bracket_lang_json"),
        try expectBoundedTargetMinimization("hidden_external_fields_json"),
        try expectBoundedTargetMinimization("mixed_semantics_json"),
    };
    const aggregate = aggregateProbes(&probes);

    try std.testing.expectEqual(@as(usize, probes.len), aggregate.target_count);
    try std.testing.expect(aggregate.default_state_count > 0);
    try std.testing.expect(aggregate.minimized_state_count > 0);
    try std.testing.expect(aggregate.minimized_state_count <= aggregate.default_state_count);
    try std.testing.expectEqual(
        aggregate.default_state_count - aggregate.minimized_state_count,
        aggregate.merged_state_count,
    );
}

test "bounded compat minimization report carries probes skips and aggregate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const report = try buildBoundedReportAlloc(arena.allocator());
    try std.testing.expectEqual(boundedTargetIds().len, report.probes.len);
    try std.testing.expectEqual(skippedTargets().len, report.skipped.len);
    try std.testing.expectEqual(boundedTargetIds().len, report.aggregate.target_count);
    try std.testing.expect(report.aggregate.default_state_count > 0);
    try std.testing.expect(report.aggregate.minimized_state_count > 0);
    try std.testing.expect(report.aggregate.minimized_state_count <= report.aggregate.default_state_count);

    for (report.probes) |probe| {
        try std.testing.expect(isBoundedTarget(probe.target_id));
        try std.testing.expect(probe.minimized_state_count <= probe.default_state_count);
    }
    for (report.skipped) |skipped| {
        try std.testing.expect(!isBoundedTarget(skipped.target_id));
        try std.testing.expect(skipped.reason.len > 0);
    }
}

test "bounded compat minimization report renders deterministic JSON" {
    const probes = [_]MinimizationProbe{
        .{
            .target_id = "small",
            .default_state_count = 5,
            .minimized_state_count = 3,
        },
    };
    const skipped = [_]SkippedMinimizationTarget{
        .{
            .target_id = "large",
            .reason = "too expensive for fast tests",
        },
    };
    const report = MinimizationReport{
        .probes = &probes,
        .skipped = &skipped,
        .aggregate = aggregateProbes(&probes),
    };

    const json = try renderReportJsonAlloc(std.testing.allocator, report);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        \\{
        \\  "aggregate": { "target_count": 1, "default_state_count": 5, "minimized_state_count": 3, "merged_state_count": 2 },
        \\  "probes": [
        \\    { "target_id": "small", "default_state_count": 5, "minimized_state_count": 3, "merged_state_count": 2 }
        \\  ],
        \\  "skipped": [
        \\    { "target_id": "large", "reason": "too expensive for fast tests" }
        \\  ]
        \\}
        \\
    , json);
}

test "bounded compat minimization report JSON escapes strings" {
    const probes = [_]MinimizationProbe{
        .{
            .target_id = "quote\"slash\\",
            .default_state_count = 1,
            .minimized_state_count = 1,
        },
    };
    const report = MinimizationReport{
        .probes = &probes,
        .skipped = &.{},
        .aggregate = aggregateProbes(&probes),
    };

    const json = try renderReportJsonAlloc(std.testing.allocator, report);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"target_id\": \"quote\\\"slash\\\\\""));
}

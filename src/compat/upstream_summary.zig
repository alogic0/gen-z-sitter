const std = @import("std");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const LocalSummaryOptions = struct {
    js_runtime: []const u8 = "node",
    minimize_states: bool = false,
    compact_duplicate_states: bool = true,
};

pub const Summary = struct {
    grammar_name: []const u8,
    blocked: bool,
    rule_count: usize,
    external_count: usize,
    extra_count: usize,
    symbol_count: usize,
    serialized_state_count: usize,
    emitted_state_count: usize,
    large_state_count: usize,
    parse_action_list_count: usize,
    small_parse_row_count: usize,
    small_parse_map_count: usize,
    lex_mode_count: usize,
    external_lex_state_count: usize,
};

pub const DiffClassification = enum {
    expected_local_extension,
    known_unsupported_surface,
    suspected_algorithm_gap,
    regression,
};

pub const SummaryDiff = struct {
    field: []const u8,
    local: []const u8,
    upstream: []const u8,
    classification: DiffClassification,
};

pub fn generateLocalSummaryAlloc(
    allocator: std.mem.Allocator,
    grammar_path: []const u8,
    options: LocalSummaryOptions,
) !Summary {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, grammar_path, .{
        .js_runtime = options.js_runtime,
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const serialized = try parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena.allocator(),
        prepared,
        .diagnostic,
        .{
            .minimize_states = options.minimize_states,
            .strict_expected_conflicts = false,
        },
    );
    const emission_stats = try parser_c_emit.collectEmissionStatsWithOptions(arena.allocator(), serialized, .{
        .compact_duplicate_states = options.compact_duplicate_states,
    });

    return .{
        .grammar_name = try allocator.dupe(u8, loaded.json.grammar.name),
        .blocked = serialized.blocked or emission_stats.blocked,
        .rule_count = loaded.json.grammar.ruleCount(),
        .external_count = loaded.json.grammar.externals.len,
        .extra_count = loaded.json.grammar.extras.len,
        .symbol_count = prepared.symbols.len,
        .serialized_state_count = serialized.states.len,
        .emitted_state_count = emission_stats.state_count,
        .large_state_count = serialized.large_state_count,
        .parse_action_list_count = serialized.parse_action_list.len,
        .small_parse_row_count = serialized.small_parse_table.rows.len,
        .small_parse_map_count = serialized.small_parse_table.map.len,
        .lex_mode_count = serialized.lex_modes.len,
        .external_lex_state_count = serialized.external_scanner.states.len,
    };
}

pub fn deinitSummary(allocator: std.mem.Allocator, summary: Summary) void {
    allocator.free(summary.grammar_name);
}

pub fn renderSummaryJsonAlloc(allocator: std.mem.Allocator, summary: Summary) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeSummaryJson(&out.writer, summary, 0);
    return try out.toOwnedSlice();
}

pub fn writeSummaryJson(writer: anytype, summary: Summary, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try writeFieldPrefix(writer, indent + 2, "grammar_name");
    try writeJsonString(writer, summary.grammar_name);
    try writer.writeAll(",\n");
    try writeFieldPrefix(writer, indent + 2, "blocked");
    try writer.writeAll(if (summary.blocked) "true" else "false");
    try writer.writeAll(",\n");
    try writeUsizeField(writer, indent + 2, "rule_count", summary.rule_count, true);
    try writeUsizeField(writer, indent + 2, "external_count", summary.external_count, true);
    try writeUsizeField(writer, indent + 2, "extra_count", summary.extra_count, true);
    try writeUsizeField(writer, indent + 2, "symbol_count", summary.symbol_count, true);
    try writeUsizeField(writer, indent + 2, "serialized_state_count", summary.serialized_state_count, true);
    try writeUsizeField(writer, indent + 2, "emitted_state_count", summary.emitted_state_count, true);
    try writeUsizeField(writer, indent + 2, "large_state_count", summary.large_state_count, true);
    try writeUsizeField(writer, indent + 2, "parse_action_list_count", summary.parse_action_list_count, true);
    try writeUsizeField(writer, indent + 2, "small_parse_row_count", summary.small_parse_row_count, true);
    try writeUsizeField(writer, indent + 2, "small_parse_map_count", summary.small_parse_map_count, true);
    try writeUsizeField(writer, indent + 2, "lex_mode_count", summary.lex_mode_count, true);
    try writeUsizeField(writer, indent + 2, "external_lex_state_count", summary.external_lex_state_count, false);
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

pub fn compareSummariesAlloc(
    allocator: std.mem.Allocator,
    local: Summary,
    upstream: Summary,
) ![]const SummaryDiff {
    var diffs: std.ArrayList(SummaryDiff) = .empty;
    errdefer deinitDiffs(allocator, diffs.items);

    try compareStringField(allocator, &diffs, "grammar_name", local.grammar_name, upstream.grammar_name, .regression);
    try compareBoolField(allocator, &diffs, "blocked", local.blocked, upstream.blocked, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "rule_count", local.rule_count, upstream.rule_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "external_count", local.external_count, upstream.external_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "extra_count", local.extra_count, upstream.extra_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "symbol_count", local.symbol_count, upstream.symbol_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "serialized_state_count", local.serialized_state_count, upstream.serialized_state_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "emitted_state_count", local.emitted_state_count, upstream.emitted_state_count, .expected_local_extension);
    try compareUsizeField(allocator, &diffs, "large_state_count", local.large_state_count, upstream.large_state_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "parse_action_list_count", local.parse_action_list_count, upstream.parse_action_list_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "small_parse_row_count", local.small_parse_row_count, upstream.small_parse_row_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "small_parse_map_count", local.small_parse_map_count, upstream.small_parse_map_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "lex_mode_count", local.lex_mode_count, upstream.lex_mode_count, .suspected_algorithm_gap);
    try compareUsizeField(allocator, &diffs, "external_lex_state_count", local.external_lex_state_count, upstream.external_lex_state_count, .known_unsupported_surface);

    return try diffs.toOwnedSlice(allocator);
}

pub fn deinitDiffs(allocator: std.mem.Allocator, diffs: []const SummaryDiff) void {
    for (diffs) |diff| {
        allocator.free(diff.field);
        allocator.free(diff.local);
        allocator.free(diff.upstream);
    }
    allocator.free(diffs);
}

pub fn renderDiffsJsonAlloc(allocator: std.mem.Allocator, diffs: []const SummaryDiff) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeDiffsJson(&out.writer, diffs, 0);
    return try out.toOwnedSlice();
}

pub fn writeDiffsJson(writer: anytype, diffs: []const SummaryDiff, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("[");
    if (diffs.len != 0) try writer.writeByte('\n');
    for (diffs, 0..) |diff, index| {
        try writeIndent(writer, indent + 2);
        try writer.writeAll("{ ");
        try writer.writeAll("\"field\": ");
        try writeJsonString(writer, diff.field);
        try writer.writeAll(", \"local\": ");
        try writeJsonString(writer, diff.local);
        try writer.writeAll(", \"upstream\": ");
        try writeJsonString(writer, diff.upstream);
        try writer.writeAll(", \"classification\": ");
        try writeJsonString(writer, @tagName(diff.classification));
        try writer.writeAll(" }");
        if (index + 1 != diffs.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (diffs.len != 0) try writeIndent(writer, indent);
    try writer.writeByte(']');
}

fn compareStringField(
    allocator: std.mem.Allocator,
    diffs: *std.ArrayList(SummaryDiff),
    field: []const u8,
    local: []const u8,
    upstream: []const u8,
    classification: DiffClassification,
) !void {
    if (std.mem.eql(u8, local, upstream)) return;
    try diffs.append(allocator, .{
        .field = try allocator.dupe(u8, field),
        .local = try allocator.dupe(u8, local),
        .upstream = try allocator.dupe(u8, upstream),
        .classification = classification,
    });
}

fn compareBoolField(
    allocator: std.mem.Allocator,
    diffs: *std.ArrayList(SummaryDiff),
    field: []const u8,
    local: bool,
    upstream: bool,
    classification: DiffClassification,
) !void {
    if (local == upstream) return;
    try diffs.append(allocator, .{
        .field = try allocator.dupe(u8, field),
        .local = try allocator.dupe(u8, if (local) "true" else "false"),
        .upstream = try allocator.dupe(u8, if (upstream) "true" else "false"),
        .classification = classification,
    });
}

fn compareUsizeField(
    allocator: std.mem.Allocator,
    diffs: *std.ArrayList(SummaryDiff),
    field: []const u8,
    local: usize,
    upstream: usize,
    classification: DiffClassification,
) !void {
    if (local == upstream) return;
    try diffs.append(allocator, .{
        .field = try allocator.dupe(u8, field),
        .local = try std.fmt.allocPrint(allocator, "{d}", .{local}),
        .upstream = try std.fmt.allocPrint(allocator, "{d}", .{upstream}),
        .classification = classification,
    });
}

fn writeUsizeField(writer: anytype, indent: usize, name: []const u8, value: usize, comma: bool) !void {
    try writeFieldPrefix(writer, indent, name);
    try writer.print("{d}", .{value});
    if (comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn writeFieldPrefix(writer: anytype, indent: usize, name: []const u8) !void {
    try writeIndent(writer, indent);
    try writeJsonString(writer, name);
    try writer.writeAll(": ");
}

fn writeIndent(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
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

test "compareSummariesAlloc classifies changed fields" {
    const local = Summary{
        .grammar_name = "json",
        .blocked = false,
        .rule_count = 1,
        .external_count = 0,
        .extra_count = 1,
        .symbol_count = 4,
        .serialized_state_count = 5,
        .emitted_state_count = 5,
        .large_state_count = 2,
        .parse_action_list_count = 3,
        .small_parse_row_count = 1,
        .small_parse_map_count = 3,
        .lex_mode_count = 5,
        .external_lex_state_count = 0,
    };
    var upstream = local;
    upstream.serialized_state_count = 6;
    upstream.external_lex_state_count = 1;

    const diffs = try compareSummariesAlloc(std.testing.allocator, local, upstream);
    defer deinitDiffs(std.testing.allocator, diffs);

    try std.testing.expectEqual(@as(usize, 2), diffs.len);
    try std.testing.expectEqualStrings("serialized_state_count", diffs[0].field);
    try std.testing.expectEqual(DiffClassification.suspected_algorithm_gap, diffs[0].classification);
    try std.testing.expectEqualStrings("external_lex_state_count", diffs[1].field);
    try std.testing.expectEqual(DiffClassification.known_unsupported_surface, diffs[1].classification);
}

test "generateLocalSummaryAlloc summarizes a tiny grammar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const summary = try generateLocalSummaryAlloc(std.testing.allocator, path, .{});
    defer deinitSummary(std.testing.allocator, summary);

    try std.testing.expectEqualStrings("basic", summary.grammar_name);
    try std.testing.expect(summary.rule_count > 0);
    try std.testing.expect(summary.serialized_state_count > 0);
}

const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const diag = @import("../support/diag.zig");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const parse_table_build = @import("../parse_table/build.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const parse_table_serialize = @import("../parse_table/serialize.zig");
const fixtures = @import("../tests/fixtures.zig");

pub fn runCompatReport(allocator: std.mem.Allocator, io: std.Io, opts: args.CompatReportOptions) !void {
    if (opts.grammar_path.len == 0) return error.InvalidArguments;

    const report = buildCompatReportJsonAlloc(allocator, opts) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try diag.printStderr(io, .{
                .kind = .usage,
                .message = @errorName(err),
                .path = opts.grammar_path,
            });
            return error.InvalidArguments;
        },
    };
    defer allocator.free(report);

    if (!builtin.is_test) {
        try std.Io.File.stdout().writeStreamingAll(io, report);
    }
}

pub fn buildCompatReportJsonAlloc(allocator: std.mem.Allocator, opts: args.CompatReportOptions) ![]const u8 {
    var loaded = try grammar_loader.loadGrammarFileWithOptions(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
    });
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const build_options = parse_table_build.BuildOptions{
        .minimize_states = opts.minimize_states,
        .strict_expected_conflicts = false,
    };
    const serialized = try parse_table_pipeline.serializeTableFromPreparedWithBuildOptions(
        arena.allocator(),
        prepared,
        .diagnostic,
        build_options,
    );

    return renderCompatReportJsonAlloc(allocator, opts, prepared, serialized);
}

fn renderCompatReportJsonAlloc(
    allocator: std.mem.Allocator,
    opts: args.CompatReportOptions,
    prepared: anytype,
    serialized: parse_table_serialize.SerializedTable,
) ![]const u8 {
    const scanner_linked = prepared.external_tokens.len != 0;
    const runtime_fit = runtimeLimitsFit(serialized);
    const serialization_ready = serialized.isSerializationReady();
    const runtime_compatible = serialization_ready and runtime_fit;
    const diagnostic_only = !runtime_compatible;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n");
    try writer.writeAll("  \"grammar_path\": ");
    try writeJsonString(writer, opts.grammar_path);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"grammar_name\": ");
    try writeJsonString(writer, prepared.grammar_name);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"loaded\": true,\n");
    try writer.writeAll("  \"prepared\": true,\n");
    try writer.print("  \"scanner_free\": {s},\n", .{boolText(!scanner_linked)});
    try writer.print("  \"scanner_linked\": {s},\n", .{boolText(scanner_linked)});
    try writer.print("  \"external_token_count\": {d},\n", .{prepared.external_tokens.len});
    try writer.print("  \"state_count\": {d},\n", .{serialized.states.len});
    try writer.print("  \"large_state_count\": {d},\n", .{serialized.large_state_count});
    try writer.print("  \"parse_action_list_count\": {d},\n", .{serialized.parse_action_list.len});
    try writer.print("  \"symbol_count\": {d},\n", .{serialized.symbols.len});
    try writer.print("  \"lex_table_count\": {d},\n", .{serialized.lex_tables.len});
    try writer.print("  \"has_keyword_lex_table\": {s},\n", .{boolText(serialized.keyword_lex_table != null)});
    try writer.print("  \"keyword_unmapped_reserved_word_count\": {d},\n", .{serialized.keyword_unmapped_reserved_word_count});
    try writer.print("  \"blocked\": {s},\n", .{boolText(serialized.blocked)});
    try writer.print("  \"serialization_ready\": {s},\n", .{boolText(serialization_ready)});
    try writer.print("  \"runtime_compatible\": {s},\n", .{boolText(runtime_compatible)});
    try writer.print("  \"diagnostic_only\": {s},\n", .{boolText(diagnostic_only)});
    try writer.writeAll("  \"temporary_glr_available\": true,\n");
    try writer.writeAll("  \"corpus_compared\": false,\n");
    try writer.writeAll("  \"runtime_limits\": { ");
    try writer.print("\"state_count_u16\": {s}, ", .{boolText(fitsRuntimeU16(serialized.states.len))});
    try writer.print("\"large_state_count_u16\": {s}, ", .{boolText(fitsRuntimeU16(serialized.large_state_count))});
    try writer.print("\"parse_action_list_u16\": {s}, ", .{boolText(fitsRuntimeU16(serialized.parse_action_list.len))});
    try writer.print("\"symbol_count_u16\": {s}", .{boolText(fitsRuntimeU16(serialized.symbols.len))});
    try writer.writeAll(" },\n");
    try writer.writeAll("  \"recommended_next_step\": ");
    try writeJsonString(writer, recommendedNextStep(serialized, scanner_linked, runtime_compatible));
    try writer.writeAll("\n}\n");

    return try out.toOwnedSlice();
}

fn runtimeLimitsFit(serialized: parse_table_serialize.SerializedTable) bool {
    return fitsRuntimeU16(serialized.states.len) and
        fitsRuntimeU16(serialized.large_state_count) and
        fitsRuntimeU16(serialized.parse_action_list.len) and
        fitsRuntimeU16(serialized.symbols.len);
}

fn fitsRuntimeU16(value: usize) bool {
    return value <= std.math.maxInt(u16);
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn recommendedNextStep(
    serialized: parse_table_serialize.SerializedTable,
    scanner_linked: bool,
    runtime_compatible: bool,
) []const u8 {
    if (!serialized.isSerializationReady()) {
        return "inspect conflict-summary.json with compare-upstream";
    }
    if (!runtime_compatible) {
        return "inspect runtime limits before parser emission";
    }
    if (serialized.keyword_unmapped_reserved_word_count != 0) {
        return "inspect reserved-word keyword mapping before runtime proof";
    }
    if (scanner_linked) {
        return "run scanner runtime-link proof or compare-upstream";
    }
    return "run compare-upstream for upstream and corpus evidence";
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

test "compat report describes scanner-free grammar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const report = try buildCompatReportJsonAlloc(std.testing.allocator, .{ .grammar_path = path });
    defer std.testing.allocator.free(report);

    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"scanner_free\": true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"scanner_linked\": false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"has_keyword_lex_table\": false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"keyword_unmapped_reserved_word_count\": 0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"serialization_ready\": true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"runtime_compatible\": true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"diagnostic_only\": false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"corpus_compared\": false"));
}

test "compat report treats raw reserved strings as keyword lexable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data =
        \\{
        \\  "name": "reserved_gap_report",
        \\  "word": "identifier",
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "identifier" },
        \\    "identifier": { "type": "PATTERN", "value": "[a-z]+" }
        \\  },
        \\  "reserved": {
        \\    "global": [
        \\      { "type": "STRING", "value": "if" }
        \\    ]
        \\  }
        \\}
        ,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const report = try buildCompatReportJsonAlloc(std.testing.allocator, .{ .grammar_path = path });
    defer std.testing.allocator.free(report);

    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"has_keyword_lex_table\": true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"keyword_unmapped_reserved_word_count\": 0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "run compare-upstream for upstream and corpus evidence"));
}

test "compat report surfaces unsupported reserved keyword blocker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data =
        \\{
        \\  "name": "reserved_pattern_gap_report",
        \\  "word": "identifier",
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "identifier" },
        \\    "identifier": { "type": "PATTERN", "value": "[a-z]+" }
        \\  },
        \\  "reserved": {
        \\    "global": [
        \\      { "type": "PATTERN", "value": "if" }
        \\    ]
        \\  }
        \\}
        ,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const report = try buildCompatReportJsonAlloc(std.testing.allocator, .{ .grammar_path = path });
    defer std.testing.allocator.free(report);

    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"keyword_unmapped_reserved_word_count\": 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "inspect reserved-word keyword mapping before runtime proof"));
}

test "compat report describes external scanner grammar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const report = try buildCompatReportJsonAlloc(std.testing.allocator, .{ .grammar_path = path });
    defer std.testing.allocator.free(report);

    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"scanner_free\": false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"scanner_linked\": true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "\"external_token_count\": 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "run scanner runtime-link proof"));
}

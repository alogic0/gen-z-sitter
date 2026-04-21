const std = @import("std");
const grammar_ir = @import("../ir/grammar_ir.zig");
const scanner_checks = @import("checks.zig");
const scanner_serialize = @import("serialize.zig");
const scanner_dump = @import("debug_dump.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const fixtures = @import("../tests/fixtures.zig");
const grammar_loader = @import("../grammar/loader.zig");
const json_loader = @import("../grammar/json_loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");

pub const PipelineError =
    extract_tokens.ExtractTokensError ||
    grammar_loader.LoaderError ||
    parse_grammar.ParseGrammarError ||
    scanner_checks.ExternalScannerCheckError ||
    scanner_serialize.SerializeError ||
    scanner_dump.DebugDumpError ||
    std.json.ParseError(std.json.Scanner) ||
    std.mem.Allocator.Error;

pub fn generateSerializedExternalScannerDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const serialized = try scanner_serialize.serializeExternalScannerBoundary(allocator, extracted.syntax);
    try scanner_checks.validateSerializedExternalScannerBoundary(serialized);
    return try scanner_dump.dumpSerializedExternalScannerAlloc(allocator, serialized);
}

fn writeModuleExportsJsonFile(dir: std.Io.Dir, sub_path: []const u8, json_contents: []const u8) !void {
    const js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{json_contents});
    defer std.testing.allocator.free(js);
    try dir.writeFile(std.testing.io, .{
        .sub_path = sub_path,
        .data = js,
    });
}

test "generateSerializedExternalScannerDumpFromPrepared matches the hidden external fields ready golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.hiddenExternalFieldsGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateSerializedExternalScannerDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.hiddenExternalFieldsExternalScannerDump().contents, dump);
}

test "generateSerializedExternalScannerDumpFromPrepared matches the mixed semantics blocked external scanner golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.mixedSemanticsGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateSerializedExternalScannerDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.mixedSemanticsExternalScannerDump().contents, dump);
}

test "generateSerializedExternalScannerDumpFromPrepared keeps hidden external fields output stable across grammar.json and grammar.js" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.hiddenExternalFieldsGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared_from_json = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump_from_json = try generateSerializedExternalScannerDumpFromPrepared(pipeline_arena.allocator(), prepared_from_json);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeModuleExportsJsonFile(tmp.dir, "grammar.js", fixtures.hiddenExternalFieldsGrammarJson().contents);

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);

    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var parse_arena_js = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena_js.deinit();
    var pipeline_arena_js = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena_js.deinit();

    const prepared_from_js = try parse_grammar.parseRawGrammar(parse_arena_js.allocator(), &loaded.json.grammar);
    const dump_from_js = try generateSerializedExternalScannerDumpFromPrepared(pipeline_arena_js.allocator(), prepared_from_js);

    try std.testing.expectEqualStrings(dump_from_json, dump_from_js);
}

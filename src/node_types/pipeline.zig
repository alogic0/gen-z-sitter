const std = @import("std");
const grammar_ir = @import("../ir/grammar_ir.zig");
const extract_default_aliases = @import("../grammar/prepare/extract_default_aliases.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const flatten_grammar = @import("../grammar/prepare/flatten_grammar.zig");
const compute = @import("compute.zig");
const render_json = @import("render_json.zig");
const fixtures = @import("../tests/fixtures.zig");
const json_loader = @import("../grammar/json_loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");

pub const PipelineError =
    extract_tokens.ExtractTokensError ||
    flatten_grammar.FlattenGrammarError ||
    extract_default_aliases.ExtractDefaultAliasesError ||
    compute.ComputeNodeTypesError ||
    render_json.RenderJsonError ||
    std.json.ParseError(std.json.Scanner) ||
    std.mem.Allocator.Error;

pub fn generateNodeTypesJsonFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    const aliases = try extract_default_aliases.extractDefaultAliases(allocator, flattened, extracted.lexical);
    const nodes = try compute.computeNodeTypes(allocator, aliases.syntax, extracted.lexical, aliases.defaults);
    return try render_json.renderNodeTypesJsonAlloc(allocator, nodes);
}

test "generateNodeTypesJsonFromPrepared runs the Milestone 3 pipeline from grammar.json" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.validResolvedGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const json = try generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.validResolvedNodeTypesJson().contents, json);
}

test "generateNodeTypesJsonFromPrepared matches the field and children golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.fieldChildrenGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const json = try generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.fieldChildrenNodeTypesJson().contents, json);
}

test "generateNodeTypesJsonFromPrepared matches the hidden wrapper golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.hiddenWrapperGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const json = try generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.hiddenWrapperNodeTypesJson().contents, json);
}

test "generateNodeTypesJsonFromPrepared matches the mixed semantics golden fixture" {
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
    const json = try generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.mixedSemanticsNodeTypesJson().contents, json);
}

test "generateNodeTypesJsonFromPrepared matches the repeat choice and sequence golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.repeatChoiceSeqGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const json = try generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.repeatChoiceSeqNodeTypesJson().contents, json);
}

test "generateNodeTypesJsonFromPrepared matches the alternative fields golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.alternativeFieldsGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const json = try generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.alternativeFieldsNodeTypesJson().contents, json);
}

test "generateNodeTypesJsonFromPrepared matches the hidden alternative fields golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.hiddenAlternativeFieldsGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const json = try generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.hiddenAlternativeFieldsNodeTypesJson().contents, json);
}

test "generateNodeTypesJsonFromPrepared matches the hidden external fields golden fixture" {
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
    const json = try generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.hiddenExternalFieldsNodeTypesJson().contents, json);
}

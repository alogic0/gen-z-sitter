const std = @import("std");
const fixtures = @import("src/tests/fixtures.zig");
const json_loader = @import("src/grammar/json_loader.zig");
const parse_grammar = @import("src/grammar/parse_grammar.zig");
const node_type_pipeline = @import("src/node_types/pipeline.zig");
const runtime_io = @import("src/support/runtime_io.zig");

const fixtures_path = "src/tests/fixtures.zig";

const GoldenTarget = struct {
    grammar: *const fn () fixtures.Fixture,
    expected: *const fn () fixtures.Fixture,
    expected_fn_name: []const u8,
};

const targets = [_]GoldenTarget{
    .{ .grammar = fixtures.validResolvedGrammarJson, .expected = fixtures.validResolvedNodeTypesJson, .expected_fn_name = "validResolvedNodeTypesJson" },
    .{ .grammar = fixtures.fieldChildrenGrammarJson, .expected = fixtures.fieldChildrenNodeTypesJson, .expected_fn_name = "fieldChildrenNodeTypesJson" },
    .{ .grammar = fixtures.hiddenWrapperGrammarJson, .expected = fixtures.hiddenWrapperNodeTypesJson, .expected_fn_name = "hiddenWrapperNodeTypesJson" },
    .{ .grammar = fixtures.mixedSemanticsGrammarJson, .expected = fixtures.mixedSemanticsNodeTypesJson, .expected_fn_name = "mixedSemanticsNodeTypesJson" },
    .{ .grammar = fixtures.repeatChoiceSeqGrammarJson, .expected = fixtures.repeatChoiceSeqNodeTypesJson, .expected_fn_name = "repeatChoiceSeqNodeTypesJson" },
    .{ .grammar = fixtures.alternativeFieldsGrammarJson, .expected = fixtures.alternativeFieldsNodeTypesJson, .expected_fn_name = "alternativeFieldsNodeTypesJson" },
    .{ .grammar = fixtures.hiddenAlternativeFieldsGrammarJson, .expected = fixtures.hiddenAlternativeFieldsNodeTypesJson, .expected_fn_name = "hiddenAlternativeFieldsNodeTypesJson" },
    .{ .grammar = fixtures.hiddenExternalFieldsGrammarJson, .expected = fixtures.hiddenExternalFieldsNodeTypesJson, .expected_fn_name = "hiddenExternalFieldsNodeTypesJson" },
    .{ .grammar = fixtures.extraAliasedBodyGrammarJson, .expected = fixtures.extraAliasedBodyNodeTypesJson, .expected_fn_name = "extraAliasedBodyNodeTypesJson" },
    .{ .grammar = fixtures.externalCollisionGrammarJson, .expected = fixtures.externalCollisionNodeTypesJson, .expected_fn_name = "externalCollisionNodeTypesJson" },
};

const Options = struct {
    write: bool = false,
    evidence_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    runtime_io.set(init.io, init.minimal.environ);

    const argv_z = try init.minimal.args.toSlice(allocator);
    defer allocator.free(argv_z);
    const options = parseOptions(argv_z[1..]) catch |err| switch (err) {
        error.InvalidArguments => {
            try std.Io.File.stderr().writeStreamingAll(init.io, usage());
            std.process.exit(2);
        },
    };

    if (options.write) {
        if (options.evidence_path) |path| {
            try validateEvidenceFile(allocator, path);
        } else {
            try std.Io.File.stderr().writeStreamingAll(init.io, "refresh-node-type-goldens --write requires --evidence <local-upstream-summary.json>\n");
            std.process.exit(2);
        }
    }

    var generated = try allocator.alloc([]const u8, targets.len);
    defer {
        for (generated) |json| allocator.free(json);
        allocator.free(generated);
    }

    var changed = false;
    for (targets, 0..) |target, index| {
        generated[index] = try generateNodeTypesForFixtureAlloc(allocator, target.grammar());
        if (!std.mem.eql(u8, generated[index], target.expected().contents)) {
            changed = true;
            std.debug.print("[refresh_node_type_goldens] stale {s}\n", .{target.expected_fn_name});
        }
    }

    if (!options.write) {
        if (changed) return error.NodeTypeGoldenMismatch;
        std.debug.print("[refresh_node_type_goldens] all node-types goldens are current\n", .{});
        return;
    }

    var source: []const u8 = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), fixtures_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(source);
    for (targets, generated) |target, json| {
        const updated = try replaceGoldenFunctionAlloc(allocator, source, target.expected_fn_name, json);
        allocator.free(source);
        source = updated;
    }
    try std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = fixtures_path, .data = source });
    std.debug.print("[refresh_node_type_goldens] wrote {s}\n", .{fixtures_path});
}

fn parseOptions(args: []const [:0]const u8) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            options.write = false;
        } else if (std.mem.eql(u8, arg, "--write")) {
            options.write = true;
        } else if (std.mem.eql(u8, arg, "--evidence")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.evidence_path = args[i];
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

fn usage() []const u8 {
    return
    \\Usage:
    \\  zig run refresh_node_type_goldens.zig -- --check
    \\  zig run refresh_node_type_goldens.zig -- --write --evidence <local-upstream-summary.json>
    \\
    ;
}

fn validateEvidenceFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const report = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(report);
    if (std.mem.indexOf(u8, report, "\"diffs\"") == null) return error.InvalidEvidenceReport;
    if (std.mem.indexOf(u8, report, "\"classification\": \"regression\"") != null) {
        return error.UpstreamRegressionEvidence;
    }
    if (std.mem.indexOf(u8, report, "\"node_types_diff\"") != null and
        std.mem.indexOf(u8, report, "\"status\": \"different\"") != null)
    {
        return error.NodeTypesStillDifferFromUpstream;
    }
}

fn generateNodeTypesForFixtureAlloc(allocator: std.mem.Allocator, grammar: fixtures.Fixture) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), grammar.contents, .{});
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &raw);
    const json = try node_type_pipeline.generateNodeTypesJsonFromPrepared(arena.allocator(), prepared);
    return try allocator.dupe(u8, json);
}

fn replaceGoldenFunctionAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    fn_name: []const u8,
    json: []const u8,
) ![]const u8 {
    const fn_marker = try std.fmt.allocPrint(allocator, "pub fn {s}() Fixture {{", .{fn_name});
    defer allocator.free(fn_marker);
    const fn_start = std.mem.indexOf(u8, source, fn_marker) orelse return error.GoldenFunctionNotFound;
    const content_marker = "        .contents =\n";
    const content_start = std.mem.indexOfPos(u8, source, fn_start, content_marker) orelse return error.GoldenContentsNotFound;
    const literal_start = content_start + content_marker.len;
    const literal_end = std.mem.indexOfPos(u8, source, literal_start, "\n        ,\n    };\n}") orelse return error.GoldenContentsEndNotFound;

    var replacement: std.Io.Writer.Allocating = .init(allocator);
    errdefer replacement.deinit();
    var lines = std.mem.splitScalar(u8, json, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        try replacement.writer.writeAll("        \\\\");
        try replacement.writer.writeAll(line);
        try replacement.writer.writeByte('\n');
    }
    const replacement_slice = try replacement.toOwnedSlice();
    defer allocator.free(replacement_slice);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(source[0..literal_start]);
    try out.writer.writeAll(replacement_slice);
    try out.writer.writeAll(source[literal_end..]);
    return try out.toOwnedSlice();
}

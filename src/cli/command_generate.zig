const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const diag = @import("../support/diag.zig");
const debug_dump = @import("../grammar/debug_dump.zig");
const grammar_loader = @import("../grammar/loader.zig");
const fs_support = @import("../support/fs.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const node_type_pipeline = @import("../node_types/pipeline.zig");
const fixtures = @import("../tests/fixtures.zig");

pub fn runGenerate(allocator: std.mem.Allocator, opts: args.GenerateOptions) !void {
    if (opts.grammar_path.len == 0) {
        return error.InvalidArguments;
    }

    var loaded = grammar_loader.loadGrammarFile(allocator, opts.grammar_path) catch |err| {
        switch (err) {
            error.UnsupportedJsGrammar => {
                try diag.printStderr(.{
                    .kind = .unimplemented,
                    .message = grammar_loader.errorMessage(err),
                    .path = opts.grammar_path,
                });
                return error.NotImplemented;
            },
            error.OutOfMemory => {
                try diag.printStderr(.{
                    .kind = .internal,
                    .message = grammar_loader.errorMessage(err),
                    .path = opts.grammar_path,
                });
                return err;
            },
            else => {
                try diag.printStderr(.{
                    .kind = if (err == error.IoFailure) .io else .usage,
                    .message = grammar_loader.errorMessage(err),
                    .path = opts.grammar_path,
                });
                return error.InvalidArguments;
            },
        }
    };
    defer loaded.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const prepared = parse_grammar.parseRawGrammar(parse_arena.allocator(), &loaded.json.grammar) catch |err| {
        const diagnostic = parse_grammar.errorDiagnostic(err);
        try diag.printStderr(.{
            .kind = .usage,
            .message = diagnostic.summary,
            .note = diagnostic.note,
            .path = opts.grammar_path,
        });
        return error.InvalidArguments;
    };

    if (opts.debug_prepared) {
        const dump = try debug_dump.dumpPreparedGrammar(allocator, prepared);
        defer allocator.free(dump);
        if (!builtin.is_test) {
            try std.fs.File.stdout().writeAll(dump);
        }
        return;
    }

    if (opts.debug_node_types) {
        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const json = node_type_pipeline.generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared) catch |err| switch (err) {
            error.InvalidSupertype => {
                try diag.printStderr(.{
                    .kind = .usage,
                    .message = "invalid supertype for node-types computation",
                    .path = opts.grammar_path,
                });
                return error.InvalidArguments;
            },
            else => return err,
        };

        if (!builtin.is_test) {
            try std.fs.File.stdout().writeAll(json);
        }
        return;
    }

    if (opts.output_dir) |output_dir| {
        try fs_support.ensureDir(output_dir);

        var pipeline_arena = std.heap.ArenaAllocator.init(allocator);
        defer pipeline_arena.deinit();

        const json = node_type_pipeline.generateNodeTypesJsonFromPrepared(pipeline_arena.allocator(), prepared) catch |err| switch (err) {
            error.InvalidSupertype => {
                try diag.printStderr(.{
                    .kind = .usage,
                    .message = "invalid supertype for node-types computation",
                    .path = opts.grammar_path,
                });
                return error.InvalidArguments;
            },
            else => return err,
        };

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, "node-types.json" });
        defer allocator.free(output_path);
        try fs_support.writeFile(output_path, json);

        try diag.printStdout(.{
            .kind = .info,
            .message = "wrote node-types.json",
            .path = output_path,
        });
    }

    try diag.printStdout(.{
        .kind = .info,
        .message = "loaded grammar.json successfully",
        .path = opts.grammar_path,
    });
    try diag.printStdout(.{
        .kind = .info,
        .message = "grammar",
        .note = loaded.json.grammar.name,
    });

    var counts_buffer: [64]u8 = undefined;
    const rule_count = try std.fmt.bufPrint(&counts_buffer, "rules: {}", .{loaded.json.grammar.ruleCount()});
    try diag.printStdout(.{
        .kind = .info,
        .message = rule_count,
    });

    const external_count = try std.fmt.bufPrint(&counts_buffer, "externals: {}", .{loaded.json.grammar.externals.len});
    try diag.printStdout(.{
        .kind = .info,
        .message = external_count,
    });

    const extras_count = try std.fmt.bufPrint(&counts_buffer, "extras: {}", .{loaded.json.grammar.extras.len});
    try diag.printStdout(.{
        .kind = .info,
        .message = extras_count,
    });

    const symbol_count = try std.fmt.bufPrint(&counts_buffer, "symbols: {}", .{prepared.symbols.len});
    try diag.printStdout(.{
        .kind = .info,
        .message = symbol_count,
    });
}

test "runGenerate rejects empty grammar path" {
    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, .{
        .grammar_path = "",
    }));
}

test "runGenerate succeeds for a valid grammar.json file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = path,
    });
}

test "runGenerate supports debug prepared output mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = path,
        .debug_prepared = true,
    });
}

test "runGenerate supports debug node types output mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = path,
        .debug_node_types = true,
    });
}

test "runGenerate writes node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validResolvedGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.validResolvedNodeTypesJson().contents, written);
}

test "runGenerate writes field and children node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.fieldChildrenGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.fieldChildrenNodeTypesJson().contents, written);
}

test "runGenerate writes hidden wrapper node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.hiddenWrapperGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.hiddenWrapperNodeTypesJson().contents, written);
}

test "runGenerate writes extra aliased body node-types.json when output directory is provided" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.extraAliasedBodyGrammarJson().contents,
    });
    try tmp.dir.makePath("out");

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(grammar_path);
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(output_dir);

    try runGenerate(std.testing.allocator, .{
        .grammar_path = grammar_path,
        .output_dir = output_dir,
    });

    const node_types_path = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "node-types.json" });
    defer std.testing.allocator.free(node_types_path);

    const written = try std.fs.cwd().readFileAlloc(std.testing.allocator, node_types_path, 1024 * 1024);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(fixtures.extraAliasedBodyNodeTypesJson().contents, written);
}

test "runGenerate maps js grammars to NotImplemented" {
    try std.testing.expectError(error.NotImplemented, runGenerate(std.testing.allocator, .{
        .grammar_path = "grammar.js",
    }));
}

test "runGenerate maps unsupported extension to InvalidArguments" {
    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, .{
        .grammar_path = "grammar.txt",
    }));
}

test "runGenerate maps semantic parse errors to InvalidArguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.undefinedSymbolGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidArguments, runGenerate(std.testing.allocator, .{
        .grammar_path = path,
    }));
}

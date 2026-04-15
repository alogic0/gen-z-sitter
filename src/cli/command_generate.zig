const std = @import("std");
const args = @import("args.zig");
const diag = @import("../support/diag.zig");
const grammar_loader = @import("../grammar/loader.zig");
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

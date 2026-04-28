const std = @import("std");
const json_loader = @import("json_loader.zig");
const process_support = @import("../support/process.zig");
const runtime_io = @import("../support/runtime_io.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const LoadError = json_loader.LoadError || error{
    ProcessFailure,
};

pub fn emitGrammarJsonFromJsAlloc(gpa: std.mem.Allocator, path: []const u8) LoadError![]u8 {
    return emitGrammarJsonFromJsAllocWithRuntime(gpa, path, "node");
}

pub fn emitGrammarJsonFromJsAllocWithRuntime(gpa: std.mem.Allocator, path: []const u8, runtime: []const u8) LoadError![]u8 {
    if (isDirectory(path)) {
        return error.InvalidPath;
    }
    if (std.mem.endsWith(u8, path, "/") or std.mem.endsWith(u8, path, "\\")) {
        return error.InvalidPath;
    }
    if (!std.mem.endsWith(u8, path, ".js")) {
        return error.UnsupportedExtension;
    }

    var result = process_support.runCapture(gpa, &.{
        runtime,
        "-e",
        "const path = require('path'); const grammarPath = path.resolve(process.argv[1]); const loaded = require(grammarPath); const grammar = loaded && typeof loaded === 'object' && 'default' in loaded ? loaded.default : loaded; process.stdout.write(JSON.stringify(grammar));",
        path,
    }) catch {
        return error.IoFailure;
    };
    defer result.deinit(gpa);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ProcessFailure,
        else => return error.ProcessFailure,
    }

    return gpa.dupe(u8, result.stdout);
}

pub fn loadGrammarJs(gpa: std.mem.Allocator, path: []const u8) LoadError!json_loader.LoadedJsonGrammar {
    return loadGrammarJsWithRuntime(gpa, path, "node");
}

pub fn loadGrammarJsWithRuntime(gpa: std.mem.Allocator, path: []const u8, runtime: []const u8) LoadError!json_loader.LoadedJsonGrammar {
    const contents = try emitGrammarJsonFromJsAllocWithRuntime(gpa, path, runtime);
    defer gpa.free(contents);
    return json_loader.loadGrammarJsonFromSlice(gpa, contents);
}

fn isDirectory(path: []const u8) bool {
    const io = runtime_io.get();
    const dir = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openDir(io, path, .{});
    if (dir) |opened_dir| {
        opened_dir.close(io);
        return true;
    } else |_| {
        return false;
    }
}

test "loadGrammarJs loads a minimal grammar.js through node" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data = fixtures.validBlankGrammarJs().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var loaded = try loadGrammarJs(std.testing.allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("basic", loaded.grammar.name);
    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.ruleCount());
}

test "loadGrammarJs rejects malformed emitted json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data =
        \\module.exports = "{";
        ,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.JsonParseFailure, loadGrammarJs(std.testing.allocator, path));
}

test "emitGrammarJsonFromJsAlloc produces deterministic compact json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data = fixtures.validResolvedGrammarJs().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const emitted = try emitGrammarJsonFromJsAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(emitted);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), fixtures.validResolvedGrammarJson().contents, .{});
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    const expected = try out.toOwnedSlice();
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, emitted);
}

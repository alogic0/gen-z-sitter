const std = @import("std");
const json_loader = @import("json_loader.zig");
const process_support = @import("../support/process.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const LoadError = json_loader.LoadError || error{
    ProcessFailure,
};

pub fn loadGrammarJs(gpa: std.mem.Allocator, path: []const u8) LoadError!json_loader.LoadedJsonGrammar {
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
        "node",
        "-e",
        "const path = require('path'); const grammarPath = path.resolve(process.argv[1]); const loaded = require(grammarPath); const grammar = loaded && typeof loaded === 'object' && 'default' in loaded ? loaded.default : loaded; process.stdout.write(JSON.stringify(grammar));",
        path,
    }) catch {
        return error.IoFailure;
    };
    defer result.deinit(gpa);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ProcessFailure,
        else => return error.ProcessFailure,
    }

    return json_loader.loadGrammarJsonFromSlice(gpa, result.stdout);
}

fn isDirectory(path: []const u8) bool {
    const dir = if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{})
    else
        std.fs.cwd().openDir(path, .{});
    if (dir) |opened_dir| {
        var opened = opened_dir;
        opened.close();
        return true;
    } else |_| {
        return false;
    }
}

test "loadGrammarJs loads a minimal grammar.js through node" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data = fixtures.validBlankGrammarJs().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
    defer std.testing.allocator.free(path);

    var loaded = try loadGrammarJs(std.testing.allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("basic", loaded.grammar.name);
    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.ruleCount());
}

test "loadGrammarJs rejects malformed emitted json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data =
            \\module.exports = "{";
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.JsonParseFailure, loadGrammarJs(std.testing.allocator, path));
}

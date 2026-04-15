const std = @import("std");
const json_loader = @import("json_loader.zig");
const validate = @import("validate.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const LoaderError = json_loader.LoadError || validate.ValidationError || error{
    UnsupportedJsGrammar,
};

pub const LoadedGrammar = struct {
    json: json_loader.LoadedJsonGrammar,

    pub fn deinit(self: *LoadedGrammar) void {
        self.json.deinit();
        self.* = undefined;
    }
};

pub fn loadGrammarFile(allocator: std.mem.Allocator, path: []const u8) LoaderError!LoadedGrammar {
    if (std.mem.endsWith(u8, path, ".js")) {
        return error.UnsupportedJsGrammar;
    }

    var loaded = try json_loader.loadGrammarJson(allocator, path);
    errdefer loaded.deinit();
    try validate.validateRawGrammar(&loaded.grammar);

    return .{ .json = loaded };
}

pub fn errorMessage(err: LoaderError) []const u8 {
    return switch (err) {
        error.InvalidPath => "invalid grammar path",
        error.UnsupportedExtension => "unsupported grammar file extension",
        error.IoFailure => "failed to read grammar file",
        error.JsonParseFailure => "failed to parse grammar.json",
        error.MissingName => "grammar.json is missing the `name` field",
        error.MissingRules => "grammar.json is missing the `rules` field",
        error.InvalidRuleShape => "grammar.json contains an invalid rule shape",
        error.InvalidReservedWordSet => "reserved word sets must be arrays",
        error.InvalidPrecedenceValue => "invalid precedence value",
        error.OutOfMemory => "out of memory while loading grammar.json",
        error.EmptyName => "grammar name must not be empty",
        error.EmptyRules => "grammar must contain at least one rule",
        error.InvalidExtra => "rules in the `extras` array must not contain empty strings",
        error.UnexpectedPrecedenceEntry => "invalid rule in precedences array; only strings and symbols are allowed",
        error.UnsupportedJsGrammar => "grammar.js loading is deferred in Milestone 1",
    };
}

test "loadGrammarFile rejects .js grammars for now" {
    try std.testing.expectError(error.UnsupportedJsGrammar, loadGrammarFile(std.testing.allocator, "grammar.js"));
}

test "loadGrammarFile rejects empty string extra" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.invalidExtraGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidExtra, loadGrammarFile(std.testing.allocator, path));
}

test "loadGrammarFile rejects unexpected precedence entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.invalidPrecedenceGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.UnexpectedPrecedenceEntry, loadGrammarFile(std.testing.allocator, path));
}

test "loadGrammarFile rejects missing name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.missingNameGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.MissingName, loadGrammarFile(std.testing.allocator, path));
}

test "loadGrammarFile rejects missing rules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.missingRulesGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.MissingRules, loadGrammarFile(std.testing.allocator, path));
}

test "loadGrammarFile rejects empty grammar name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.emptyNameGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.EmptyName, loadGrammarFile(std.testing.allocator, path));
}

test "loadGrammarFile rejects empty rules object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.emptyRulesGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.EmptyRules, loadGrammarFile(std.testing.allocator, path));
}

test "loadGrammarFile rejects invalid reserved word set shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.invalidReservedGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidReservedWordSet, loadGrammarFile(std.testing.allocator, path));
}

test "loadGrammarFile rejects unknown extension" {
    try std.testing.expectError(error.UnsupportedExtension, loadGrammarFile(std.testing.allocator, "grammar.txt"));
}

const std = @import("std");
const support_fs = @import("../support/fs.zig");
const runtime_io = @import("../support/runtime_io.zig");
const raw = @import("raw_grammar.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const LoadError = error{
    InvalidPath,
    UnsupportedExtension,
    IoFailure,
    JsonParseFailure,
    MissingName,
    MissingRules,
    InvalidRuleShape,
    InvalidReservedWordSet,
    InvalidPrecedenceValue,
    OutOfMemory,
};

pub const LoadedJsonGrammar = struct {
    arena: std.heap.ArenaAllocator,
    grammar: raw.RawGrammar,

    pub fn deinit(self: *LoadedJsonGrammar) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn loadGrammarJson(gpa: std.mem.Allocator, path: []const u8) LoadError!LoadedJsonGrammar {
    if (isDirectory(path)) {
        return error.InvalidPath;
    }
    if (std.mem.endsWith(u8, path, "/") or std.mem.endsWith(u8, path, "\\")) {
        return error.InvalidPath;
    }
    if (!std.mem.endsWith(u8, path, ".json")) {
        return error.UnsupportedExtension;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    const allocator = arena.allocator();

    const contents = support_fs.readFileAlloc(allocator, path, 16 * 1024 * 1024) catch {
        arena.deinit();
        return error.IoFailure;
    };

    return loadGrammarJsonFromSliceWithArena(arena, contents);
}

pub fn loadGrammarJsonFromSlice(gpa: std.mem.Allocator, contents: []const u8) LoadError!LoadedJsonGrammar {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    return loadGrammarJsonFromSliceWithArena(arena, contents);
}

fn loadGrammarJsonFromSliceWithArena(arena: std.heap.ArenaAllocator, contents: []const u8) LoadError!LoadedJsonGrammar {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const allocator = owned_arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
        return error.JsonParseFailure;
    };
    defer parsed.deinit();

    const grammar = try parseTopLevel(allocator, parsed.value);
    return .{
        .arena = owned_arena,
        .grammar = grammar,
    };
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

pub fn parseTopLevel(allocator: std.mem.Allocator, value: std.json.Value) LoadError!raw.RawGrammar {
    const object = switch (value) {
        .object => |obj| obj,
        else => return error.JsonParseFailure,
    };

    const name_value = object.get("name") orelse return error.MissingName;
    const rules_value = object.get("rules") orelse return error.MissingRules;

    return .{
        .name = try expectString(name_value),
        .rules = try parseRuleEntries(allocator, rules_value),
        .precedences = try parsePrecedences(allocator, object.get("precedences")),
        .conflicts = try parseConflicts(allocator, object.get("conflicts")),
        .externals = try parseRuleArray(allocator, object.get("externals")),
        .extras = try parseRuleArray(allocator, object.get("extras")),
        .inline_rules = try parseStringArray(allocator, object.get("inline")),
        .supertypes = try parseStringArray(allocator, object.get("supertypes")),
        .word = if (object.get("word")) |word| try expectString(word) else null,
        .reserved = try parseReservedSets(allocator, object.get("reserved")),
    };
}

fn parseRuleEntries(allocator: std.mem.Allocator, value: std.json.Value) LoadError![]const raw.RawRuleEntry {
    const object = switch (value) {
        .object => |obj| obj,
        else => return error.MissingRules,
    };

    var entries = std.array_list.Managed(raw.RawRuleEntry).init(allocator);
    defer entries.deinit();

    var it = object.iterator();
    while (it.next()) |entry| {
        try entries.append(.{
            .name = entry.key_ptr.*,
            .rule = try parseRuleAlloc(allocator, entry.value_ptr.*),
        });
    }

    return try entries.toOwnedSlice();
}

fn parsePrecedences(allocator: std.mem.Allocator, value: ?std.json.Value) LoadError![]const raw.PrecedenceList {
    const precedence_value = value orelse return &.{};
    const top = try expectArray(precedence_value);

    var result = std.array_list.Managed(raw.PrecedenceList).init(allocator);
    defer result.deinit();

    for (top.items) |member| {
        const list = try expectArray(member);
        var parsed_list = std.array_list.Managed(*const raw.RawRule).init(allocator);
        defer parsed_list.deinit();

        for (list.items) |item| {
            try parsed_list.append(try parseRuleAlloc(allocator, item));
        }

        try result.append(try parsed_list.toOwnedSlice());
    }

    return try result.toOwnedSlice();
}

fn parseConflicts(allocator: std.mem.Allocator, value: ?std.json.Value) LoadError![]const raw.ConflictSet {
    const conflicts_value = value orelse return &.{};
    const top = try expectArray(conflicts_value);

    var result = std.array_list.Managed(raw.ConflictSet).init(allocator);
    defer result.deinit();

    for (top.items) |member| {
        try result.append(try parseStringArrayRequired(allocator, member));
    }

    return try result.toOwnedSlice();
}

fn parseRuleArray(allocator: std.mem.Allocator, value: ?std.json.Value) LoadError![]const *const raw.RawRule {
    const array_value = value orelse return &.{};
    const arr = try expectArray(array_value);

    var result = std.array_list.Managed(*const raw.RawRule).init(allocator);
    defer result.deinit();

    for (arr.items) |item| {
        try result.append(try parseRuleAlloc(allocator, item));
    }

    return try result.toOwnedSlice();
}

fn parseStringArray(allocator: std.mem.Allocator, value: ?std.json.Value) LoadError![]const []const u8 {
    const array_value = value orelse return &.{};
    return parseStringArrayRequired(allocator, array_value);
}

fn parseStringArrayRequired(allocator: std.mem.Allocator, value: std.json.Value) LoadError![]const []const u8 {
    const arr = try expectArray(value);
    var result = std.array_list.Managed([]const u8).init(allocator);
    defer result.deinit();

    for (arr.items) |item| {
        try result.append(try expectString(item));
    }

    return try result.toOwnedSlice();
}

fn parseReservedSets(allocator: std.mem.Allocator, value: ?std.json.Value) LoadError![]const raw.RawReservedSet {
    const reserved_value = value orelse return &.{};
    const object = switch (reserved_value) {
        .object => |obj| obj,
        else => return error.InvalidReservedWordSet,
    };

    var result = std.array_list.Managed(raw.RawReservedSet).init(allocator);
    defer result.deinit();

    var it = object.iterator();
    while (it.next()) |entry| {
        const arr = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => return error.InvalidReservedWordSet,
        };

        var members = std.array_list.Managed(*const raw.RawRule).init(allocator);
        defer members.deinit();

        for (arr.items) |item| {
            try members.append(try parseRuleAlloc(allocator, item));
        }

        try result.append(.{
            .context_name = entry.key_ptr.*,
            .members = try members.toOwnedSlice(),
        });
    }

    return try result.toOwnedSlice();
}

fn parseRuleAlloc(allocator: std.mem.Allocator, value: std.json.Value) LoadError!*const raw.RawRule {
    const rule = try allocator.create(raw.RawRule);
    rule.* = try parseRule(allocator, value);
    return rule;
}

fn parseRule(allocator: std.mem.Allocator, value: std.json.Value) LoadError!raw.RawRule {
    const object = switch (value) {
        .object => |obj| obj,
        else => return error.InvalidRuleShape,
    };

    const type_value = object.get("type") orelse return error.InvalidRuleShape;
    const rule_type = try expectString(type_value);

    if (std.mem.eql(u8, rule_type, "ALIAS")) {
        return .{ .alias = .{
            .content = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape),
            .named = try expectBool(object.get("named") orelse return error.InvalidRuleShape),
            .value = try expectString(object.get("value") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "BLANK")) {
        return .blank;
    }
    if (std.mem.eql(u8, rule_type, "STRING")) {
        return .{ .string = try expectString(object.get("value") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "PATTERN")) {
        return .{ .pattern = .{
            .value = try expectString(object.get("value") orelse return error.InvalidRuleShape),
            .flags = if (object.get("flags")) |flags| try expectString(flags) else null,
        } };
    }
    if (std.mem.eql(u8, rule_type, "SYMBOL")) {
        return .{ .symbol = try expectString(object.get("name") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "CHOICE")) {
        return .{ .choice = try parseMembers(allocator, object.get("members") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "FIELD")) {
        return .{ .field = .{
            .name = try expectString(object.get("name") orelse return error.InvalidRuleShape),
            .content = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "SEQ")) {
        return .{ .seq = try parseMembers(allocator, object.get("members") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "REPEAT")) {
        return .{ .repeat = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "REPEAT1")) {
        return .{ .repeat1 = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "PREC_DYNAMIC")) {
        return .{ .prec_dynamic = .{
            .value = try expectI32(object.get("value") orelse return error.InvalidRuleShape),
            .content = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "PREC_LEFT")) {
        return .{ .prec_left = .{
            .value = try parsePrecedenceValue(object.get("value") orelse return error.InvalidRuleShape),
            .content = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "PREC_RIGHT")) {
        return .{ .prec_right = .{
            .value = try parsePrecedenceValue(object.get("value") orelse return error.InvalidRuleShape),
            .content = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "PREC")) {
        return .{ .prec = .{
            .value = try parsePrecedenceValue(object.get("value") orelse return error.InvalidRuleShape),
            .content = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "TOKEN")) {
        return .{ .token = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "IMMEDIATE_TOKEN")) {
        return .{ .immediate_token = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "RESERVED")) {
        return .{ .reserved = .{
            .context_name = try expectString(object.get("context_name") orelse return error.InvalidRuleShape),
            .content = try parseRuleAlloc(allocator, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }

    return error.InvalidRuleShape;
}

fn parseMembers(allocator: std.mem.Allocator, value: std.json.Value) LoadError![]const *const raw.RawRule {
    const arr = try expectArray(value);
    var result = std.array_list.Managed(*const raw.RawRule).init(allocator);
    defer result.deinit();

    for (arr.items) |item| {
        try result.append(try parseRuleAlloc(allocator, item));
    }

    return try result.toOwnedSlice();
}

fn parsePrecedenceValue(value: std.json.Value) LoadError!raw.RawPrecedenceValue {
    return switch (value) {
        .integer => |v| .{ .integer = std.math.cast(i32, v) orelse return error.InvalidPrecedenceValue },
        .string => |v| .{ .name = v },
        else => error.InvalidPrecedenceValue,
    };
}

fn expectString(value: std.json.Value) LoadError![]const u8 {
    return switch (value) {
        .string => |str| str,
        else => error.InvalidRuleShape,
    };
}

fn expectBool(value: std.json.Value) LoadError!bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidRuleShape,
    };
}

fn expectI32(value: std.json.Value) LoadError!i32 {
    return switch (value) {
        .integer => |i| std.math.cast(i32, i) orelse error.InvalidRuleShape,
        else => error.InvalidRuleShape,
    };
}

fn expectArray(value: std.json.Value) LoadError!std.json.Array {
    return switch (value) {
        .array => |arr| arr,
        else => error.InvalidRuleShape,
    };
}

test "loadGrammarJson loads a minimal valid grammar file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    var loaded = try loadGrammarJson(std.testing.allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("basic", loaded.grammar.name);
    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.ruleCount());
}

test "loadGrammarJson rejects invalid precedence value type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.invalidPrecedenceGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    var loaded = try loadGrammarJson(std.testing.allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.precedences.len);
}

test "loadGrammarJson rejects malformed json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.json",
        .data = fixtures.malformedGrammarJson().contents,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.JsonParseFailure, loadGrammarJson(std.testing.allocator, path));
}

test "loadGrammarJson rejects an actual directory path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("grammar.json");
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidPath, loadGrammarJson(std.testing.allocator, path));
}

test "loadGrammarJsonFromSlice loads a valid grammar document" {
    var loaded = try loadGrammarJsonFromSlice(std.testing.allocator, fixtures.validBlankGrammarJson().contents);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("basic", loaded.grammar.name);
    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.ruleCount());
}

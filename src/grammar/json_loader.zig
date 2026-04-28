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
    UnsupportedRuleType,
    OutOfMemory,
};

threadlocal var last_error_note_buffer: [512]u8 = undefined;
threadlocal var last_error_note: ?[]const u8 = null;

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

pub fn errorNote(err: LoadError) ?[]const u8 {
    return switch (err) {
        error.UnsupportedRuleType => last_error_note,
        else => null,
    };
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
    last_error_note = null;

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
    const grammar_name = try expectString(name_value);

    return .{
        .name = grammar_name,
        .version = parseVersion(object.get("version")),
        .rules = try parseRuleEntries(allocator, grammar_name, rules_value),
        .precedences = try parsePrecedences(allocator, grammar_name, object.get("precedences")),
        .expected_conflicts = try parseExpectedConflicts(allocator, object),
        .externals = try parseRuleArray(allocator, grammar_name, "externals", object.get("externals")),
        .extras = try parseRuleArray(allocator, grammar_name, "extras", object.get("extras")),
        .inline_rules = try parseStringArray(allocator, object.get("inline")),
        .supertypes = try parseStringArray(allocator, object.get("supertypes")),
        .word = if (object.get("word")) |word| try expectString(word) else null,
        .reserved = try parseReservedSets(allocator, grammar_name, object.get("reserved")),
    };
}

fn parseVersion(value: ?std.json.Value) [3]u8 {
    const raw_version = if (value) |version_value| switch (version_value) {
        .string => |str| str,
        else => return .{ 0, 0, 0 },
    } else return .{ 0, 0, 0 };

    var parts = std.mem.splitScalar(u8, raw_version, '.');
    var parsed: [3]u8 = undefined;
    for (&parsed) |*part| {
        const text = parts.next() orelse return .{ 0, 0, 0 };
        if (text.len == 0) return .{ 0, 0, 0 };
        part.* = std.fmt.parseUnsigned(u8, text, 10) catch return .{ 0, 0, 0 };
    }
    if (parts.next() != null) return .{ 0, 0, 0 };
    return parsed;
}

fn parseRuleEntries(
    allocator: std.mem.Allocator,
    grammar_name: []const u8,
    value: std.json.Value,
) LoadError![]const raw.RawRuleEntry {
    const object = switch (value) {
        .object => |obj| obj,
        else => return error.MissingRules,
    };

    var entries = std.array_list.Managed(raw.RawRuleEntry).init(allocator);
    defer entries.deinit();

    var it = object.iterator();
    while (it.next()) |entry| {
        const rule_path = try std.fmt.allocPrint(allocator, "rules.{s}", .{entry.key_ptr.*});
        try entries.append(.{
            .name = entry.key_ptr.*,
            .rule = try parseRuleAllocAtPath(allocator, grammar_name, rule_path, entry.value_ptr.*),
        });
    }

    return try entries.toOwnedSlice();
}

fn parsePrecedences(
    allocator: std.mem.Allocator,
    grammar_name: []const u8,
    value: ?std.json.Value,
) LoadError![]const raw.PrecedenceList {
    const precedence_value = value orelse return &.{};
    const top = try expectArray(precedence_value);

    var result = std.array_list.Managed(raw.PrecedenceList).init(allocator);
    defer result.deinit();

    for (top.items, 0..) |member, ordering_index| {
        const list = try expectArray(member);
        var parsed_list = std.array_list.Managed(*const raw.RawRule).init(allocator);
        defer parsed_list.deinit();

        for (list.items, 0..) |item, entry_index| {
            const rule_path = try std.fmt.allocPrint(
                allocator,
                "precedences[{d}][{d}]",
                .{ ordering_index, entry_index },
            );
            try parsed_list.append(try parseRuleAllocAtPath(allocator, grammar_name, rule_path, item));
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

fn parseExpectedConflicts(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) LoadError![]const raw.ConflictSet {
    const conflicts = try parseConflicts(allocator, object.get("conflicts"));
    const expected_conflicts = try parseConflicts(allocator, object.get("expected_conflicts"));
    if (conflicts.len == 0) return expected_conflicts;
    if (expected_conflicts.len == 0) return conflicts;

    var result = try std.array_list.Managed(raw.ConflictSet).initCapacity(
        allocator,
        conflicts.len + expected_conflicts.len,
    );
    defer result.deinit();
    try result.appendSlice(conflicts);
    try result.appendSlice(expected_conflicts);
    return try result.toOwnedSlice();
}

fn parseRuleArray(
    allocator: std.mem.Allocator,
    grammar_name: []const u8,
    label: []const u8,
    value: ?std.json.Value,
) LoadError![]const *const raw.RawRule {
    const array_value = value orelse return &.{};
    const arr = try expectArray(array_value);

    var result = std.array_list.Managed(*const raw.RawRule).init(allocator);
    defer result.deinit();

    for (arr.items, 0..) |item, index| {
        const rule_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ label, index });
        try result.append(try parseRuleAllocAtPath(allocator, grammar_name, rule_path, item));
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

fn parseReservedSets(
    allocator: std.mem.Allocator,
    grammar_name: []const u8,
    value: ?std.json.Value,
) LoadError![]const raw.RawReservedSet {
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

        for (arr.items, 0..) |item, index| {
            const rule_path = try std.fmt.allocPrint(
                allocator,
                "reserved.{s}[{d}]",
                .{ entry.key_ptr.*, index },
            );
            try members.append(try parseRuleAllocAtPath(allocator, grammar_name, rule_path, item));
        }

        try result.append(.{
            .context_name = entry.key_ptr.*,
            .members = try members.toOwnedSlice(),
        });
    }

    return try result.toOwnedSlice();
}

fn parseRuleAlloc(allocator: std.mem.Allocator, value: std.json.Value) LoadError!*const raw.RawRule {
    return parseRuleAllocAtPath(allocator, "<unknown>", "<rule>", value);
}

fn parseRuleAllocAtPath(
    allocator: std.mem.Allocator,
    grammar_name: []const u8,
    rule_path: []const u8,
    value: std.json.Value,
) LoadError!*const raw.RawRule {
    const rule = try allocator.create(raw.RawRule);
    rule.* = try parseRuleAtPath(allocator, grammar_name, rule_path, value);
    return rule;
}

fn parseRule(allocator: std.mem.Allocator, value: std.json.Value) LoadError!raw.RawRule {
    return parseRuleAtPath(allocator, "<unknown>", "<rule>", value);
}

fn parseRuleAtPath(
    allocator: std.mem.Allocator,
    grammar_name: []const u8,
    rule_path: []const u8,
    value: std.json.Value,
) LoadError!raw.RawRule {
    const object = switch (value) {
        .object => |obj| obj,
        else => return error.InvalidRuleShape,
    };

    const type_value = object.get("type") orelse return error.InvalidRuleShape;
    const rule_type = try expectString(type_value);

    if (std.mem.eql(u8, rule_type, "ALIAS")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .alias = .{
            .content = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape),
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
        return .{ .choice = try parseMembers(allocator, grammar_name, rule_path, object.get("members") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "FIELD")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .field = .{
            .name = try expectString(object.get("name") orelse return error.InvalidRuleShape),
            .content = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "SEQ")) {
        return .{ .seq = try parseMembers(allocator, grammar_name, rule_path, object.get("members") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "REPEAT")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .repeat = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "REPEAT1")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .repeat1 = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "PREC_DYNAMIC")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .prec_dynamic = .{
            .value = try expectI32(object.get("value") orelse return error.InvalidRuleShape),
            .content = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "PREC_LEFT")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .prec_left = .{
            .value = try parsePrecedenceValue(object.get("value") orelse return error.InvalidRuleShape),
            .content = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "PREC_RIGHT")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .prec_right = .{
            .value = try parsePrecedenceValue(object.get("value") orelse return error.InvalidRuleShape),
            .content = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "PREC")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .prec = .{
            .value = try parsePrecedenceValue(object.get("value") orelse return error.InvalidRuleShape),
            .content = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }
    if (std.mem.eql(u8, rule_type, "TOKEN")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .token = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "IMMEDIATE_TOKEN")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .immediate_token = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape) };
    }
    if (std.mem.eql(u8, rule_type, "RESERVED")) {
        const content_path = try childRulePath(allocator, rule_path, ".content");
        return .{ .reserved = .{
            .context_name = try expectString(object.get("context_name") orelse return error.InvalidRuleShape),
            .content = try parseRuleAllocAtPath(allocator, grammar_name, content_path, object.get("content") orelse return error.InvalidRuleShape),
        } };
    }

    setUnsupportedRuleTypeNote(grammar_name, rule_path, rule_type);
    return error.UnsupportedRuleType;
}

fn parseMembers(
    allocator: std.mem.Allocator,
    grammar_name: []const u8,
    rule_path: []const u8,
    value: std.json.Value,
) LoadError![]const *const raw.RawRule {
    const arr = try expectArray(value);
    var result = std.array_list.Managed(*const raw.RawRule).init(allocator);
    defer result.deinit();

    for (arr.items, 0..) |item, index| {
        const member_path = try std.fmt.allocPrint(allocator, "{s}.members[{d}]", .{ rule_path, index });
        try result.append(try parseRuleAllocAtPath(allocator, grammar_name, member_path, item));
    }

    return try result.toOwnedSlice();
}

fn childRulePath(allocator: std.mem.Allocator, rule_path: []const u8, suffix: []const u8) LoadError![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ rule_path, suffix });
}

fn setUnsupportedRuleTypeNote(grammar_name: []const u8, rule_path: []const u8, rule_type: []const u8) void {
    last_error_note = std.fmt.bufPrint(
        &last_error_note_buffer,
        "grammar `{s}` rule path `{s}` uses unsupported DSL rule type `{s}`",
        .{ grammar_name, rule_path, rule_type },
    ) catch "unsupported DSL rule type";
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

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var loaded = try loadGrammarJson(std.testing.allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("basic", loaded.grammar.name);
    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.ruleCount());
}

test "loadGrammarJson rejects invalid precedence value type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.invalidPrecedenceGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var loaded = try loadGrammarJson(std.testing.allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.precedences.len);
}

test "loadGrammarJson rejects malformed json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.malformedGrammarJson().contents,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.JsonParseFailure, loadGrammarJson(std.testing.allocator, path));
}

test "loadGrammarJson rejects an actual directory path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "grammar.json");
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidPath, loadGrammarJson(std.testing.allocator, path));
}

test "loadGrammarJsonFromSlice loads a valid grammar document" {
    var loaded = try loadGrammarJsonFromSlice(std.testing.allocator, fixtures.validBlankGrammarJson().contents);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("basic", loaded.grammar.name);
    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.ruleCount());
}

test "loadGrammarJsonFromSlice parses semantic grammar version" {
    const contents =
        \\{
        \\  "name": "versioned",
        \\  "version": "2.3.4",
        \\  "rules": {
        \\    "source_file": { "type": "BLANK" }
        \\  }
        \\}
    ;
    var loaded = try loadGrammarJsonFromSlice(std.testing.allocator, contents);
    defer loaded.deinit();

    try std.testing.expectEqual([3]u8{ 2, 3, 4 }, loaded.grammar.version);
}

test "loadGrammarJsonFromSlice defaults missing and malformed semantic versions" {
    var missing = try loadGrammarJsonFromSlice(std.testing.allocator, fixtures.validBlankGrammarJson().contents);
    defer missing.deinit();
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, missing.grammar.version);

    const contents =
        \\{
        \\  "name": "malformed_version",
        \\  "version": "2.x.4",
        \\  "rules": {
        \\    "source_file": { "type": "BLANK" }
        \\  }
        \\}
    ;
    var malformed = try loadGrammarJsonFromSlice(std.testing.allocator, contents);
    defer malformed.deinit();

    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, malformed.grammar.version);
}

test "loadGrammarJsonFromSlice reports unsupported rule type path" {
    const contents =
        \\{
        \\  "name": "unsupported_demo",
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "SEQ",
        \\      "members": [
        \\        { "type": "UNSUPPORTED_NODE" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    try std.testing.expectError(error.UnsupportedRuleType, loadGrammarJsonFromSlice(std.testing.allocator, contents));
    const note = errorNote(error.UnsupportedRuleType) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, note, "unsupported_demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "rules.source_file.members[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "UNSUPPORTED_NODE") != null);
}

test "loadGrammarJsonFromSlice accepts expected_conflicts spelling" {
    const contents =
        \\{
        \\  "name": "expected_conflict_alias",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "BLANK" }
        \\  }
        \\}
    ;
    var loaded = try loadGrammarJsonFromSlice(std.testing.allocator, contents);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.grammar.expected_conflicts.len);
    try std.testing.expectEqualStrings("source_file", loaded.grammar.expected_conflicts[0][0]);
    try std.testing.expectEqualStrings("expr", loaded.grammar.expected_conflicts[0][1]);
}

test "loadGrammarJsonFromSlice merges conflicts and expected_conflicts" {
    const contents =
        \\{
        \\  "name": "merged_conflicts",
        \\  "conflicts": [["source_file", "expr"]],
        \\  "expected_conflicts": [["source_file", "term"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "BLANK" },
        \\    "term": { "type": "BLANK" }
        \\  }
        \\}
    ;
    var loaded = try loadGrammarJsonFromSlice(std.testing.allocator, contents);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded.grammar.expected_conflicts.len);
    try std.testing.expectEqualStrings("expr", loaded.grammar.expected_conflicts[0][1]);
    try std.testing.expectEqualStrings("term", loaded.grammar.expected_conflicts[1][1]);
}

test "loadGrammarJsonFromSlice rejects malformed expected_conflicts" {
    const contents =
        \\{
        \\  "name": "bad_expected_conflicts",
        \\  "expected_conflicts": ["source_file"],
        \\  "rules": {
        \\    "source_file": { "type": "BLANK" }
        \\  }
        \\}
    ;

    try std.testing.expectError(error.InvalidRuleShape, loadGrammarJsonFromSlice(std.testing.allocator, contents));
}

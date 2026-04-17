const std = @import("std");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const rules = @import("../ir/rules.zig");

pub const ExpandError = std.mem.Allocator.Error || error{
    UnsupportedRule,
    UnsupportedPattern,
};

pub const CharacterSet = struct {
    ranges: std.ArrayListUnmanaged(Range) = .empty,

    pub const Range = struct {
        start: u32,
        end: u32,
    };

    pub fn deinit(self: *CharacterSet, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
        self.* = .{};
    }

    pub fn empty() CharacterSet {
        return .{};
    }

    pub fn fromChar(allocator: std.mem.Allocator, ch: u21) !CharacterSet {
        var result: CharacterSet = .{};
        try result.addCodepointRange(allocator, ch, ch + 1);
        return result;
    }

    pub fn addRange(self: *CharacterSet, allocator: std.mem.Allocator, start: u21, end_inclusive: u21) !void {
        try self.addCodepointRange(allocator, start, end_inclusive + 1);
    }

    pub fn addCodepointRange(self: *CharacterSet, allocator: std.mem.Allocator, start: u32, end: u32) !void {
        if (start >= end) return;

        var index: usize = 0;
        while (index < self.ranges.items.len) : (index += 1) {
            const range = self.ranges.items[index];
            if (range.start > end) {
                try self.ranges.insert(allocator, index, .{ .start = start, .end = end });
                return;
            }
            if (range.end >= start) {
                self.ranges.items[index].start = @min(range.start, start);
                self.ranges.items[index].end = @max(range.end, end);
                while (index + 1 < self.ranges.items.len and
                    self.ranges.items[index + 1].start <= self.ranges.items[index].end)
                {
                    self.ranges.items[index].end = @max(
                        self.ranges.items[index].end,
                        self.ranges.items[index + 1].end,
                    );
                    _ = self.ranges.orderedRemove(index + 1);
                }
                return;
            }
        }

        try self.ranges.append(allocator, .{ .start = start, .end = end });
    }

    pub fn addSet(self: *CharacterSet, allocator: std.mem.Allocator, other: CharacterSet) !void {
        for (other.ranges.items) |range| {
            try self.addCodepointRange(allocator, range.start, range.end);
        }
    }

    pub fn contains(self: CharacterSet, codepoint: u21) bool {
        for (self.ranges.items) |range| {
            if (codepoint >= range.start and codepoint < range.end) return true;
            if (range.start > codepoint) return false;
        }
        return false;
    }
};

pub const NfaState = union(enum) {
    advance: struct {
        chars: CharacterSet,
        state_id: u32,
        is_separator: bool,
        precedence: i32,
    },
    split: struct {
        left: u32,
        right: u32,
    },
    accept: struct {
        variable_index: usize,
        precedence: i32,
    },

    pub fn deinit(self: *NfaState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .advance => |*advance| advance.chars.deinit(allocator),
            else => {},
        }
    }
};

pub const Nfa = struct {
    states: std.ArrayListUnmanaged(NfaState) = .empty,

    pub fn deinit(self: *Nfa, allocator: std.mem.Allocator) void {
        for (self.states.items) |*state| state.deinit(allocator);
        self.states.deinit(allocator);
        self.* = .{};
    }

    pub fn lastStateId(self: Nfa) u32 {
        std.debug.assert(self.states.items.len != 0);
        return @intCast(self.states.items.len - 1);
    }
};

pub const ExpandedLexicalVariable = struct {
    name: []const u8,
    kind: lexical_ir.VariableKind,
    implicit_precedence: i32,
    start_state: u32,
    source_rule: rules.RuleId,
};

pub const ExpandedLexicalGrammar = struct {
    nfa: Nfa,
    variables: []const ExpandedLexicalVariable,

    pub fn deinit(self: *ExpandedLexicalGrammar, allocator: std.mem.Allocator) void {
        self.nfa.deinit(allocator);
        allocator.free(self.variables);
        self.* = undefined;
    }
};

pub const TokenMatch = struct {
    variable_index: usize,
    len: usize,
    implicit_precedence: i32,
};

const MatchCursor = struct {
    codepoint: u21,
    byte_len: usize,
};

const VisitedState = struct {
    state_id: u32,
    offset: usize,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    all_rules: []const rules.Rule,
    nfa: Nfa = .{},
    precedence_stack: std.ArrayListUnmanaged(i32) = .empty,
    is_separator: bool = false,

    fn deinit(self: *Builder) void {
        self.nfa.deinit(self.allocator);
        self.precedence_stack.deinit(self.allocator);
        self.* = undefined;
    }

    fn init(allocator: std.mem.Allocator, all_rules: []const rules.Rule) !Builder {
        var builder = Builder{
            .allocator = allocator,
            .all_rules = all_rules,
        };
        try builder.precedence_stack.append(allocator, 0);
        return builder;
    }

    fn pushAdvance(self: *Builder, chars: CharacterSet, state_id: u32) !void {
        try self.nfa.states.append(self.allocator, .{
            .advance = .{
                .chars = chars,
                .state_id = state_id,
                .is_separator = self.is_separator,
                .precedence = self.precedence_stack.items[self.precedence_stack.items.len - 1],
            },
        });
    }

    fn pushSplit(self: *Builder, left: u32, right: u32) !void {
        try self.nfa.states.append(self.allocator, .{ .split = .{ .left = left, .right = right } });
    }

    fn completionPrecedence(self: *Builder, rule_id: rules.RuleId) i32 {
        return switch (self.all_rules[rule_id]) {
            .metadata => |metadata| switch (metadata.data.precedence) {
                .integer => |value| value,
                else => 0,
            },
            else => 0,
        };
    }

    fn implicitPrecedence(self: *Builder, rule_id: rules.RuleId) i32 {
        return switch (self.all_rules[rule_id]) {
            .string => 2,
            .metadata => |metadata| blk: {
                const inner = self.implicitPrecedence(metadata.inner);
                if (metadata.data.token) break :blk inner + 1;
                break :blk inner;
            },
            else => 0,
        };
    }

    fn isImmediateToken(self: *Builder, rule_id: rules.RuleId) bool {
        return switch (self.all_rules[rule_id]) {
            .metadata => |metadata| metadata.data.immediate_token or self.isImmediateToken(metadata.inner),
            else => false,
        };
    }

    fn expandVariable(self: *Builder, variable_index: usize, variable: lexical_ir.LexicalVariable, separators: []const rules.RuleId) !ExpandedLexicalVariable {
        try self.nfa.states.append(self.allocator, .{
            .accept = .{
                .variable_index = variable_index,
                .precedence = self.completionPrecedence(variable.rule),
            },
        });
        const accept_state = self.nfa.lastStateId();
        _ = try self.expandRule(variable.rule, accept_state);
        if (!self.isImmediateToken(variable.rule) and separators.len != 0) {
            self.is_separator = true;
            defer self.is_separator = false;
            _ = try self.expandSeparatorLoop(separators, self.nfa.lastStateId());
        }

        return .{
            .name = variable.name,
            .kind = variable.kind,
            .implicit_precedence = self.implicitPrecedence(variable.rule),
            .start_state = self.nfa.lastStateId(),
            .source_rule = variable.rule,
        };
    }

    fn expandSeparatorLoop(self: *Builder, separators: []const rules.RuleId, next_state_id: u32) !bool {
        var branch_states = std.ArrayListUnmanaged(u32).empty;
        defer branch_states.deinit(self.allocator);

        try branch_states.append(self.allocator, next_state_id);
        for (separators) |rule_id| {
            const before = self.nfa.states.items.len;
            if (try self.expandRule(rule_id, next_state_id)) {
                try branch_states.append(self.allocator, self.nfa.lastStateId());
            } else {
                self.nfa.states.items.len = before;
            }
        }

        if (branch_states.items.len == 1) return false;

        const loop_target = next_state_id;
        for (branch_states.items[1..]) |state_id| {
            try self.pushSplit(state_id, loop_target);
        }
        return true;
    }

    fn expandRule(self: *Builder, rule_id: rules.RuleId, next_state_id: u32) ExpandError!bool {
        return switch (self.all_rules[rule_id]) {
            .string => |value| blk: {
                var next = next_state_id;
                var iter = std.mem.reverseIterator(value);
                while (iter.next()) |byte| {
                    const chars = try CharacterSet.fromChar(self.allocator, byte);
                    try self.pushAdvance(chars, next);
                    next = self.nfa.lastStateId();
                }
                break :blk value.len != 0;
            },
            .pattern => |pattern| self.expandPattern(pattern, next_state_id),
            .choice => |members| blk: {
                var alternative_states = std.ArrayListUnmanaged(u32).empty;
                defer alternative_states.deinit(self.allocator);
                for (members) |member| {
                    const before = self.nfa.states.items.len;
                    if (try self.expandRule(member, next_state_id)) {
                        try alternative_states.append(self.allocator, self.nfa.lastStateId());
                    } else {
                        self.nfa.states.items.len = before;
                        try alternative_states.append(self.allocator, next_state_id);
                    }
                }
                std.mem.sort(u32, alternative_states.items, {}, std.sort.asc(u32));
                var last: ?u32 = null;
                for (alternative_states.items) |state_id| {
                    if (last != null and last.? == state_id) continue;
                    last = state_id;
                    if (state_id != self.nfa.lastStateId()) {
                        try self.pushSplit(state_id, self.nfa.lastStateId());
                    }
                }
                break :blk true;
            },
            .seq => |members| blk: {
                var result = false;
                var next = next_state_id;
                var i = members.len;
                while (i > 0) {
                    i -= 1;
                    if (try self.expandRule(members[i], next)) result = true;
                    next = self.nfa.lastStateId();
                }
                break :blk result;
            },
            .repeat => |inner| blk: {
                try self.nfa.states.append(self.allocator, .{
                    .accept = .{ .variable_index = 0, .precedence = 0 },
                });
                const loop_split_state_id = self.nfa.lastStateId();
                if (try self.expandRule(inner, loop_split_state_id)) {
                    const inner_start_state = self.nfa.lastStateId();
                    self.nfa.states.items[loop_split_state_id] = .{
                        .split = .{ .left = inner_start_state, .right = next_state_id },
                    };
                    try self.pushSplit(inner_start_state, next_state_id);
                    break :blk true;
                }
                _ = self.nfa.states.pop();
                break :blk false;
            },
            .repeat1 => |inner| blk: {
                try self.nfa.states.append(self.allocator, .{
                    .accept = .{ .variable_index = 0, .precedence = 0 },
                });
                const split_state_id = self.nfa.lastStateId();
                if (try self.expandRule(inner, split_state_id)) {
                    self.nfa.states.items[split_state_id] = .{
                        .split = .{ .left = self.nfa.lastStateId(), .right = next_state_id },
                    };
                    break :blk true;
                }
                _ = self.nfa.states.pop();
                break :blk false;
            },
            .metadata => |metadata| blk: {
                var pushed = false;
                switch (metadata.data.precedence) {
                    .integer => |value| {
                        try self.precedence_stack.append(self.allocator, value);
                        pushed = true;
                    },
                    else => {},
                }
                defer {
                    if (pushed) _ = self.precedence_stack.pop();
                }
                break :blk try self.expandRule(metadata.inner, next_state_id);
            },
            .blank => false,
            else => error.UnsupportedRule,
        };
    }

    fn expandPattern(self: *Builder, pattern: rules.Pattern, next_state_id: u32) ExpandError!bool {
        const value = pattern.value;

        if (std.mem.eql(u8, value, "\\p{Zs}")) {
            var chars = CharacterSet.empty();
            try chars.addRange(self.allocator, ' ', ' ');
            try chars.addCodepointRange(self.allocator, 0xA0, 0xA1);
            try self.pushAdvance(chars, next_state_id);
            return true;
        }

        if (std.mem.eql(u8, value, "[_\\p{Ll}\\p{Lo}]")) {
            var chars = CharacterSet.empty();
            try chars.addRange(self.allocator, '_', '_');
            try chars.addRange(self.allocator, 'a', 'z');
            try chars.addCodepointRange(self.allocator, 0x80, 0x110000);
            try self.pushAdvance(chars, next_state_id);
            return true;
        }

        if (std.mem.eql(u8, value, "[\\p{Lu}\\p{Lt}]")) {
            var chars = CharacterSet.empty();
            try chars.addRange(self.allocator, 'A', 'Z');
            try chars.addCodepointRange(self.allocator, 0x80, 0x110000);
            try self.pushAdvance(chars, next_state_id);
            return true;
        }

        if (std.mem.eql(u8, value, "[\\pL\\p{Mn}\\pN_']*")) {
            var chars = CharacterSet.empty();
            try chars.addRange(self.allocator, 'A', 'Z');
            try chars.addRange(self.allocator, 'a', 'z');
            try chars.addRange(self.allocator, '0', '9');
            try chars.addRange(self.allocator, '_', '_');
            try chars.addRange(self.allocator, '\'', '\'');
            try chars.addCodepointRange(self.allocator, 0x80, 0x110000);
            try self.nfa.states.append(self.allocator, .{
                .split = .{ .left = next_state_id, .right = next_state_id },
            });
            const loop_split_state = self.nfa.lastStateId();
            try self.pushAdvance(chars, loop_split_state);
            const advance_state = self.nfa.lastStateId();
            self.nfa.states.items[loop_split_state] = .{
                .split = .{ .left = advance_state, .right = next_state_id },
            };
            try self.pushSplit(advance_state, next_state_id);
            return true;
        }

        if (std.mem.eql(u8, value, "#*")) {
            const chars = try CharacterSet.fromChar(self.allocator, '#');
            try self.nfa.states.append(self.allocator, .{
                .split = .{ .left = next_state_id, .right = next_state_id },
            });
            const loop_split_state = self.nfa.lastStateId();
            try self.pushAdvance(chars, loop_split_state);
            const advance_state = self.nfa.lastStateId();
            self.nfa.states.items[loop_split_state] = .{
                .split = .{ .left = advance_state, .right = next_state_id },
            };
            try self.pushSplit(advance_state, next_state_id);
            return true;
        }

        if (value.len >= 5 and value[0] == '[' and value[value.len - 1] == '+') {
            const body = value[1 .. value.len - 2];
            if (body.len == 3 and body[1] == '-') {
                var chars = CharacterSet.empty();
                var start = body[0];
                var end = body[2];
                if (pattern.flags) |flags| {
                    if (std.mem.indexOfScalar(u8, flags, 'i') != null) {
                        if (std.ascii.isAlphabetic(start) and std.ascii.isAlphabetic(end)) {
                            start = std.ascii.toLower(start);
                            end = std.ascii.toLower(end);
                            try chars.addRange(self.allocator, start, end);
                            try chars.addRange(self.allocator, std.ascii.toUpper(start), std.ascii.toUpper(end));
                        } else {
                            try chars.addRange(self.allocator, start, end);
                        }
                    } else {
                        try chars.addRange(self.allocator, start, end);
                    }
                } else {
                    try chars.addRange(self.allocator, start, end);
                }

                try self.nfa.states.append(self.allocator, .{
                    .split = .{ .left = next_state_id, .right = next_state_id },
                });
                const split_state = self.nfa.lastStateId();
                try self.pushAdvance(chars, split_state);
                const advance_state = self.nfa.lastStateId();
                self.nfa.states.items[split_state] = .{
                    .split = .{ .left = advance_state, .right = next_state_id },
                };
                return true;
            }
        }

        return error.UnsupportedPattern;
    }
};

pub fn expandExtractedLexicalGrammar(
    allocator: std.mem.Allocator,
    all_rules: []const rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
) ExpandError!ExpandedLexicalGrammar {
    var builder = try Builder.init(allocator, all_rules);
    errdefer builder.deinit();

    const variables = try allocator.alloc(ExpandedLexicalVariable, lexical.variables.len);
    errdefer allocator.free(variables);

    for (lexical.variables, 0..) |variable, index| {
        variables[index] = try builder.expandVariable(index, variable, lexical.separators);
    }

    builder.precedence_stack.deinit(allocator);

    return .{
        .nfa = builder.nfa,
        .variables = variables,
    };
}

pub fn matchVariable(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    variable_index: usize,
    input: []const u8,
) std.mem.Allocator.Error!?usize {
    std.debug.assert(variable_index < grammar.variables.len);

    var visited = std.ArrayListUnmanaged(VisitedState).empty;
    defer visited.deinit(allocator);

    const variable = grammar.variables[variable_index];
    const end_offset = try matchState(
        allocator,
        grammar,
        variable.start_state,
        input,
        0,
        &visited,
    );
    return if (end_offset) |offset| offset else null;
}

pub fn selectBestToken(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    input: []const u8,
) std.mem.Allocator.Error!?TokenMatch {
    var best: ?TokenMatch = null;
    for (grammar.variables, 0..) |variable, index| {
        const match_len = try matchVariable(allocator, grammar, index, input) orelse continue;
        const candidate: TokenMatch = .{
            .variable_index = index,
            .len = match_len,
            .implicit_precedence = variable.implicit_precedence,
        };
        if (best == null or tokenMatchLessThan(best.?, candidate)) best = candidate;
    }
    return best;
}

fn tokenMatchLessThan(current: TokenMatch, candidate: TokenMatch) bool {
    if (candidate.len != current.len) return candidate.len > current.len;
    if (candidate.implicit_precedence != current.implicit_precedence) {
        return candidate.implicit_precedence > current.implicit_precedence;
    }
    return candidate.variable_index < current.variable_index;
}

fn matchState(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    state_id: u32,
    input: []const u8,
    offset: usize,
    visited: *std.ArrayListUnmanaged(VisitedState),
) std.mem.Allocator.Error!?usize {
    for (visited.items) |entry| {
        if (entry.state_id == state_id and entry.offset == offset) return null;
    }
    try visited.append(allocator, .{ .state_id = state_id, .offset = offset });
    defer _ = visited.pop();

    const state = grammar.nfa.states.items[state_id];
    return switch (state) {
        .accept => offset,
        .split => |split| blk: {
            const left = try matchState(allocator, grammar, split.left, input, offset, visited);
            const right = try matchState(allocator, grammar, split.right, input, offset, visited);
            break :blk maxOptionalOffset(left, right);
        },
        .advance => |advance| blk: {
            const cursor = decodeNextCodepoint(input, offset) orelse break :blk null;
            if (!advance.chars.contains(cursor.codepoint)) break :blk null;
            break :blk try matchState(
                allocator,
                grammar,
                advance.state_id,
                input,
                offset + cursor.byte_len,
                visited,
            );
        },
    };
}

fn maxOptionalOffset(left: ?usize, right: ?usize) ?usize {
    if (left == null) return right;
    if (right == null) return left;
    return @max(left.?, right.?);
}

fn decodeNextCodepoint(input: []const u8, offset: usize) ?MatchCursor {
    if (offset >= input.len) return null;

    const first = input[offset];
    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch {
        return .{ .codepoint = first, .byte_len = 1 };
    };
    if (offset + sequence_len > input.len) {
        return .{ .codepoint = first, .byte_len = 1 };
    }
    const codepoint = std.unicode.utf8Decode(input[offset .. offset + sequence_len]) catch {
        return .{ .codepoint = first, .byte_len = 1 };
    };
    return .{
        .codepoint = codepoint,
        .byte_len = sequence_len,
    };
}

test "expandExtractedLexicalGrammar builds lexical NFA for simple string and pattern tokens" {
    const all_rules = [_]rules.Rule{
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
        .{ .string = "42" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "identifier", .kind = .named, .rule = 0 },
            .{ .name = "number", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), expanded.variables.len);
    try std.testing.expect(expanded.nfa.states.items.len >= 3);
    try std.testing.expectEqualStrings("identifier", expanded.variables[0].name);
    try std.testing.expectEqualStrings("number", expanded.variables[1].name);
}

test "expandExtractedLexicalGrammar integrates separator transitions for non-immediate tokens" {
    const all_rules = [_]rules.Rule{
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
        .{ .string = " " },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "identifier", .kind = .named, .rule = 0 },
        },
        .separators = &.{1},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var found_separator_advance = false;
    for (expanded.nfa.states.items) |state| {
        switch (state) {
            .advance => |advance| {
                if (advance.is_separator) found_separator_advance = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found_separator_advance);
}

test "expandExtractedLexicalGrammar supports token seq patterns used by Haskell-style identifiers" {
    const all_rules = [_]rules.Rule{
        .{
            .metadata = .{
                .inner = 1,
                .data = .{ .token = true },
            },
        },
        .{ .seq = &.{ 2, 3, 4 } },
        .{ .pattern = .{ .value = "[_\\p{Ll}\\p{Lo}]", .flags = null } },
        .{ .pattern = .{ .value = "[\\pL\\p{Mn}\\pN_']*", .flags = null } },
        .{ .pattern = .{ .value = "#*", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "variable", .kind = .named, .rule = 0 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expect(expanded.nfa.states.items.len >= 4);
    try std.testing.expectEqual(@as(i32, 1), expanded.variables[0].implicit_precedence);
}

test "selectBestToken matches through the expanded lexical model" {
    const all_rules = [_]rules.Rule{
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
        .{ .string = "let" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "identifier", .kind = .named, .rule = 0 },
            .{ .name = "keyword", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    const keyword = (try selectBestToken(std.testing.allocator, expanded, "let x")).?;
    try std.testing.expectEqual(@as(usize, 1), keyword.variable_index);
    try std.testing.expectEqual(@as(usize, 3), keyword.len);

    const identifier = (try selectBestToken(std.testing.allocator, expanded, "alpha")).?;
    try std.testing.expectEqual(@as(usize, 0), identifier.variable_index);
    try std.testing.expectEqual(@as(usize, 5), identifier.len);
}

test "matchVariable handles mixed pattern and string lexical variables" {
    const all_rules = [_]rules.Rule{
        .{
            .metadata = .{
                .inner = 1,
                .data = .{ .token = true },
            },
        },
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
        .{ .string = "42" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "identifier", .kind = .named, .rule = 0 },
            .{ .name = "number_literal", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, 3), try matchVariable(std.testing.allocator, expanded, 0, "abc42"));
    try std.testing.expectEqual(@as(?usize, 2), try matchVariable(std.testing.allocator, expanded, 1, "42"));
}

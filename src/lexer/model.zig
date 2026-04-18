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

    pub fn full(allocator: std.mem.Allocator) !CharacterSet {
        var result: CharacterSet = .{};
        try result.addCodepointRange(allocator, 0, 0x110000);
        return result;
    }

    pub fn removeCodepointRange(self: *CharacterSet, allocator: std.mem.Allocator, start: u32, end: u32) !void {
        if (start >= end) return;

        var index: usize = 0;
        while (index < self.ranges.items.len) {
            const range = self.ranges.items[index];
            if (range.end <= start) {
                index += 1;
                continue;
            }
            if (range.start >= end) break;

            if (start <= range.start and end >= range.end) {
                _ = self.ranges.orderedRemove(index);
                continue;
            }
            if (start <= range.start) {
                self.ranges.items[index].start = end;
                break;
            }
            if (end >= range.end) {
                self.ranges.items[index].end = start;
                index += 1;
                continue;
            }

            const tail = Range{ .start = end, .end = range.end };
            self.ranges.items[index].end = start;
            try self.ranges.insert(allocator, index + 1, tail);
            break;
        }
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
    completion_precedence: i32,
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
    completion_precedence: i32,
    implicit_precedence: i32,
    kind: lexical_ir.VariableKind,
};

pub const TokenConflictStatus = packed struct(u8) {
    matches_prefix: bool = false,
    does_match_continuation: bool = false,
    matches_same_string: bool = false,
    matches_different_string: bool = false,
    starting_overlap: bool = false,
    _padding: u3 = 0,
};

pub const TokenConflictMap = struct {
    variable_count: usize,
    status_matrix: []TokenConflictStatus,
    starting_chars_by_index: []CharacterSet,

    pub fn deinit(self: *TokenConflictMap, allocator: std.mem.Allocator) void {
        for (self.starting_chars_by_index) |*chars| chars.deinit(allocator);
        allocator.free(self.starting_chars_by_index);
        allocator.free(self.status_matrix);
        self.* = undefined;
    }

    pub fn status(self: TokenConflictMap, left: usize, right: usize) TokenConflictStatus {
        return self.status_matrix[matrixIndex(self.variable_count, left, right)];
    }
};

const MatchCursor = struct {
    codepoint: u21,
    byte_len: usize,
};

const VisitedState = struct {
    state_id: u32,
    offset: usize,
};

const AdvanceTransition = struct {
    chars: CharacterSet,
    target_state: u32,
    is_separator: bool,
    precedence: i32,
};

const ConflictCompletion = struct {
    variable_index: usize,
    precedence: i32,
};

const TokenConflictPairState = struct {
    left: []const u32,
    right: []const u32,
};

const PatternQuantifier = enum {
    once,
    zero_or_more,
    one_or_more,
};

const PatternAtom = struct {
    chars: CharacterSet,
    quantifier: PatternQuantifier = .once,

    fn deinit(self: *PatternAtom, allocator: std.mem.Allocator) void {
        self.chars.deinit(allocator);
        self.* = undefined;
    }
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
            .completion_precedence = self.completionPrecedence(variable.rule),
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
        return self.expandSequencePattern(pattern, next_state_id);
    }

    fn expandSequencePattern(self: *Builder, pattern: rules.Pattern, next_state_id: u32) ExpandError!bool {
        var atoms = std.ArrayListUnmanaged(PatternAtom).empty;
        defer {
            for (atoms.items) |*atom| atom.deinit(self.allocator);
            atoms.deinit(self.allocator);
        }

        try parsePatternAtoms(self.allocator, pattern, &atoms);
        if (atoms.items.len == 0) return false;

        var next = next_state_id;
        var i = atoms.items.len;
        while (i > 0) {
            i -= 1;
            next = try self.expandPatternAtom(atoms.items[i], next);
        }
        return true;
    }

    fn expandPatternAtom(self: *Builder, atom: PatternAtom, next_state_id: u32) !u32 {
        return switch (atom.quantifier) {
            .once => blk: {
                try self.pushAdvance(try cloneCharacterSet(self.allocator, atom.chars), next_state_id);
                break :blk self.nfa.lastStateId();
            },
            .zero_or_more => blk: {
                try self.nfa.states.append(self.allocator, .{
                    .split = .{ .left = next_state_id, .right = next_state_id },
                });
                const loop_split_state = self.nfa.lastStateId();
                try self.pushAdvance(try cloneCharacterSet(self.allocator, atom.chars), loop_split_state);
                const advance_state = self.nfa.lastStateId();
                self.nfa.states.items[loop_split_state] = .{
                    .split = .{ .left = advance_state, .right = next_state_id },
                };
                try self.pushSplit(advance_state, next_state_id);
                break :blk self.nfa.lastStateId();
            },
            .one_or_more => blk: {
                try self.nfa.states.append(self.allocator, .{
                    .split = .{ .left = next_state_id, .right = next_state_id },
                });
                const loop_split_state = self.nfa.lastStateId();
                try self.pushAdvance(try cloneCharacterSet(self.allocator, atom.chars), loop_split_state);
                const advance_state = self.nfa.lastStateId();
                self.nfa.states.items[loop_split_state] = .{
                    .split = .{ .left = advance_state, .right = next_state_id },
                };
                try self.pushSplit(advance_state, next_state_id);
                break :blk advance_state;
            },
        };
    }
};

fn cloneCharacterSet(allocator: std.mem.Allocator, chars: CharacterSet) !CharacterSet {
    var result = CharacterSet.empty();
    try result.addSet(allocator, chars);
    return result;
}

fn parsePatternAtoms(
    allocator: std.mem.Allocator,
    pattern: rules.Pattern,
    atoms: *std.ArrayListUnmanaged(PatternAtom),
) ExpandError!void {
    var index: usize = 0;
    const value = pattern.value;
    while (index < value.len) {
        var atom = try parsePatternAtom(allocator, value, &index, pattern.flags);
        errdefer atom.deinit(allocator);
        if (index < value.len) {
            atom.quantifier = switch (value[index]) {
                '*' => blk: {
                    index += 1;
                    break :blk PatternQuantifier.zero_or_more;
                },
                '+' => blk: {
                    index += 1;
                    break :blk PatternQuantifier.one_or_more;
                },
                else => .once,
            };
        }
        try atoms.append(allocator, atom);
    }
}

fn parsePatternAtom(
    allocator: std.mem.Allocator,
    value: []const u8,
    index: *usize,
    flags: ?[]const u8,
) ExpandError!PatternAtom {
    if (index.* >= value.len) return error.UnsupportedPattern;

    return switch (value[index.*]) {
        '[' => parseBracketClassAtom(allocator, value, index, flags),
        '.' => blk: {
            index.* += 1;
            var chars = try CharacterSet.full(allocator);
            try chars.removeCodepointRange(allocator, '\n', '\n' + 1);
            break :blk .{ .chars = chars };
        },
        '\\' => parseEscapedAtom(allocator, value, index),
        else => blk: {
            const chars = try CharacterSet.fromChar(allocator, value[index.*]);
            index.* += 1;
            break :blk .{ .chars = chars };
        },
    };
}

fn parseBracketClassAtom(
    allocator: std.mem.Allocator,
    value: []const u8,
    index: *usize,
    flags: ?[]const u8,
) ExpandError!PatternAtom {
    std.debug.assert(value[index.*] == '[');
    index.* += 1;
    const negated = index.* < value.len and value[index.*] == '^';
    if (negated) index.* += 1;

    var chars = if (negated) try CharacterSet.full(allocator) else CharacterSet.empty();
    errdefer chars.deinit(allocator);

    while (index.* < value.len and value[index.*] != ']') {
        var entry = try parseClassEntry(allocator, value, index, flags);
        defer entry.deinit(allocator);
        if (negated) {
            for (entry.ranges.items) |range| {
                try chars.removeCodepointRange(allocator, range.start, range.end);
            }
        } else {
            try chars.addSet(allocator, entry);
        }
    }
    if (index.* >= value.len or value[index.*] != ']') return error.UnsupportedPattern;
    index.* += 1;

    return .{ .chars = chars };
}

fn parseClassEntry(
    allocator: std.mem.Allocator,
    value: []const u8,
    index: *usize,
    flags: ?[]const u8,
) ExpandError!CharacterSet {
    var first = try parseClassUnit(allocator, value, index);
    errdefer first.deinit(allocator);

    if (index.* + 1 < value.len and value[index.*] == '-' and value[index.* + 1] != ']') {
        if (first.ranges.items.len != 1) return error.UnsupportedPattern;
        defer first.deinit(allocator);
        index.* += 1;
        var second = try parseClassUnit(allocator, value, index);
        defer second.deinit(allocator);
        if (second.ranges.items.len != 1) return error.UnsupportedPattern;

        var chars = CharacterSet.empty();
        const start_range = first.ranges.items[0];
        const end_range = second.ranges.items[0];
        if (start_range.end != start_range.start + 1 or end_range.end != end_range.start + 1) {
            return error.UnsupportedPattern;
        }
        var start: u8 = @intCast(start_range.start);
        var end: u8 = @intCast(end_range.start);
        if (flags) |pattern_flags| {
            if (std.mem.indexOfScalar(u8, pattern_flags, 'i') != null and
                std.ascii.isAlphabetic(start) and std.ascii.isAlphabetic(end))
            {
                start = std.ascii.toLower(start);
                end = std.ascii.toLower(end);
                try chars.addRange(allocator, start, end);
                try chars.addRange(allocator, std.ascii.toUpper(start), std.ascii.toUpper(end));
                return chars;
            }
        }
        try chars.addRange(allocator, start, end);
        return chars;
    }

    return first;
}

fn parseClassUnit(
    allocator: std.mem.Allocator,
    value: []const u8,
    index: *usize,
) ExpandError!CharacterSet {
    if (index.* >= value.len) return error.UnsupportedPattern;
    if (value[index.*] == '\\') {
        const atom = try parseEscapedAtom(allocator, value, index);
        return atom.chars;
    }

    const chars = try CharacterSet.fromChar(allocator, value[index.*]);
    index.* += 1;
    return chars;
}

fn parseEscapedAtom(
    allocator: std.mem.Allocator,
    value: []const u8,
    index: *usize,
) ExpandError!PatternAtom {
    std.debug.assert(value[index.*] == '\\');
    index.* += 1;
    if (index.* >= value.len) return error.UnsupportedPattern;

    const chars = switch (value[index.*]) {
        'n' => try CharacterSet.fromChar(allocator, '\n'),
        'r' => try CharacterSet.fromChar(allocator, '\r'),
        't' => try CharacterSet.fromChar(allocator, '\t'),
        'd' => blk: {
            var set = CharacterSet.empty();
            try set.addRange(allocator, '0', '9');
            break :blk set;
        },
        's' => blk: {
            var set = CharacterSet.empty();
            try set.addRange(allocator, ' ', ' ');
            try set.addRange(allocator, '\t', '\t');
            try set.addRange(allocator, '\n', '\n');
            try set.addRange(allocator, '\r', '\r');
            break :blk set;
        },
        'p' => try parseUnicodePropertySet(allocator, value, index),
        else => try CharacterSet.fromChar(allocator, value[index.*]),
    };
    if (value[index.*] != 'p') index.* += 1;
    return .{ .chars = chars };
}

fn parseUnicodePropertySet(
    allocator: std.mem.Allocator,
    value: []const u8,
    index: *usize,
) ExpandError!CharacterSet {
    std.debug.assert(value[index.*] == 'p');
    index.* += 1;
    if (index.* >= value.len) return error.UnsupportedPattern;

    var property_name: []const u8 = undefined;
    if (value[index.*] == '{') {
        index.* += 1;
        const start = index.*;
        while (index.* < value.len and value[index.*] != '}') : (index.* += 1) {}
        if (index.* >= value.len) return error.UnsupportedPattern;
        property_name = value[start..index.*];
        index.* += 1;
    } else {
        const start = index.*;
        while (index.* < value.len and std.ascii.isAlphabetic(value[index.*])) : (index.* += 1) {}
        property_name = value[start..index.*];
    }

    var set = CharacterSet.empty();
    if (std.mem.eql(u8, property_name, "Zs")) {
        try set.addRange(allocator, ' ', ' ');
        try set.addCodepointRange(allocator, 0xA0, 0xA1);
        return set;
    }
    if (std.mem.eql(u8, property_name, "Ll")) {
        try set.addRange(allocator, 'a', 'z');
        try set.addCodepointRange(allocator, 0x80, 0x110000);
        return set;
    }
    if (std.mem.eql(u8, property_name, "Lo")) {
        try set.addCodepointRange(allocator, 0x80, 0x110000);
        return set;
    }
    if (std.mem.eql(u8, property_name, "Lu") or std.mem.eql(u8, property_name, "Lt")) {
        try set.addRange(allocator, 'A', 'Z');
        try set.addCodepointRange(allocator, 0x80, 0x110000);
        return set;
    }
    if (std.mem.eql(u8, property_name, "L")) {
        try set.addRange(allocator, 'A', 'Z');
        try set.addRange(allocator, 'a', 'z');
        try set.addCodepointRange(allocator, 0x80, 0x110000);
        return set;
    }
    if (std.mem.eql(u8, property_name, "Mn")) {
        try set.addCodepointRange(allocator, 0x80, 0x110000);
        return set;
    }
    if (std.mem.eql(u8, property_name, "N")) {
        try set.addRange(allocator, '0', '9');
        return set;
    }

    return error.UnsupportedPattern;
}

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
            .completion_precedence = variable.completion_precedence,
            .implicit_precedence = variable.implicit_precedence,
            .kind = variable.kind,
        };
        if (best == null or tokenMatchLessThan(best.?, candidate)) best = candidate;
    }
    return best;
}

pub fn collectTokenMatchesAlloc(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    input: []const u8,
) std.mem.Allocator.Error![]TokenMatch {
    var matches = std.ArrayListUnmanaged(TokenMatch).empty;
    errdefer matches.deinit(allocator);

    for (grammar.variables, 0..) |variable, index| {
        const match_len = try matchVariable(allocator, grammar, index, input) orelse continue;
        try matches.append(allocator, .{
            .variable_index = index,
            .len = match_len,
            .completion_precedence = variable.completion_precedence,
            .implicit_precedence = variable.implicit_precedence,
            .kind = variable.kind,
        });
    }

    std.mem.sort(TokenMatch, matches.items, {}, struct {
        fn lessThan(_: void, lhs: TokenMatch, rhs: TokenMatch) bool {
            return tokenMatchLessThan(rhs, lhs);
        }
    }.lessThan);

    return matches.toOwnedSlice(allocator);
}

pub fn selectPreferredMatch(
    matches: []const TokenMatch,
    conflict_map: TokenConflictMap,
) ?TokenMatch {
    if (matches.len == 0) return null;

    var best = matches[0];
    for (matches[1..]) |candidate| {
        if (tokenMatchPreferredByConflict(conflict_map, best, candidate)) {
            best = candidate;
        }
    }
    return best;
}

pub fn pruneConflictingMatches(
    matches: *std.ArrayListUnmanaged(TokenMatch),
    conflict_map: TokenConflictMap,
) void {
    var index: usize = 0;
    while (index < matches.items.len) {
        const candidate = matches.items[index];
        var dominated = false;

        for (matches.items, 0..) |other, other_index| {
            if (index == other_index) continue;
            if (tokenMatchDominatesByConflict(conflict_map, other, candidate)) {
                dominated = true;
                break;
            }
        }

        if (dominated) {
            _ = matches.orderedRemove(index);
            continue;
        }
        index += 1;
    }
}

pub fn buildTokenConflictMapAlloc(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
) std.mem.Allocator.Error!TokenConflictMap {
    const variable_count = grammar.variables.len;
    const status_matrix = try allocator.alloc(TokenConflictStatus, variable_count * variable_count);
    @memset(status_matrix, .{});
    errdefer allocator.free(status_matrix);

    const starting_chars_by_index = try allocator.alloc(CharacterSet, variable_count);
    errdefer {
        for (starting_chars_by_index[0..variable_count]) |*chars| chars.deinit(allocator);
        allocator.free(starting_chars_by_index);
    }

    for (grammar.variables, 0..) |variable, index| {
        starting_chars_by_index[index] = try startingCharsForVariable(allocator, grammar, variable.start_state);
    }

    for (0..variable_count) |left| {
        for (0..variable_count) |right| {
            if (left == right) continue;
            if (characterSetsIntersect(starting_chars_by_index[left], starting_chars_by_index[right])) {
                status_matrix[matrixIndex(variable_count, left, right)].starting_overlap = true;
            }
        }
    }

    for (0..variable_count) |left| {
        for (0..left) |right| {
            const pair_status = try computeConflictStatusPair(allocator, grammar, left, right);
            status_matrix[matrixIndex(variable_count, left, right)] = pair_status[0];
            status_matrix[matrixIndex(variable_count, right, left)] = pair_status[1];
            if (characterSetsIntersect(starting_chars_by_index[left], starting_chars_by_index[right])) {
                status_matrix[matrixIndex(variable_count, left, right)].starting_overlap = true;
                status_matrix[matrixIndex(variable_count, right, left)].starting_overlap = true;
            }
        }
    }

    return .{
        .variable_count = variable_count,
        .status_matrix = status_matrix,
        .starting_chars_by_index = starting_chars_by_index,
    };
}

fn tokenMatchLessThan(current: TokenMatch, candidate: TokenMatch) bool {
    if (candidate.len != current.len) return candidate.len > current.len;
    if (candidate.completion_precedence != current.completion_precedence) {
        return candidate.completion_precedence > current.completion_precedence;
    }
    if (candidate.implicit_precedence != current.implicit_precedence) {
        return candidate.implicit_precedence > current.implicit_precedence;
    }
    if (candidate.kind != current.kind) return candidate.kind == .named;
    return candidate.variable_index < current.variable_index;
}

fn tokenMatchPreferredByConflict(
    conflict_map: TokenConflictMap,
    current: TokenMatch,
    candidate: TokenMatch,
) bool {
    const candidate_status = conflict_map.status(candidate.variable_index, current.variable_index);
    const current_status = conflict_map.status(current.variable_index, candidate.variable_index);

    if (candidate_status.matches_same_string and !current_status.matches_same_string) return true;
    if (current_status.matches_same_string and !candidate_status.matches_same_string) return false;

    if (candidate.len > current.len and current_status.does_match_continuation) return true;
    if (current.len > candidate.len and candidate_status.does_match_continuation) return false;

    return tokenMatchLessThan(current, candidate);
}

fn tokenMatchDominatesByConflict(
    conflict_map: TokenConflictMap,
    dominator: TokenMatch,
    candidate: TokenMatch,
) bool {
    const dominator_status = conflict_map.status(dominator.variable_index, candidate.variable_index);
    const candidate_status = conflict_map.status(candidate.variable_index, dominator.variable_index);

    if (dominator_status.matches_same_string and !candidate_status.matches_same_string) {
        return tokenMatchLessThan(candidate, dominator);
    }

    if (dominator.len > candidate.len and dominator_status.does_match_continuation) {
        return true;
    }

    return false;
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

fn matrixIndex(variable_count: usize, left: usize, right: usize) usize {
    return variable_count * left + right;
}

fn startingCharsForVariable(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    start_state: u32,
) std.mem.Allocator.Error!CharacterSet {
    const closure = try epsilonClosureAlloc(allocator, grammar, &.{start_state});
    defer allocator.free(closure);

    var result = CharacterSet.empty();
    for (closure) |state_id| {
        switch (grammar.nfa.states.items[state_id]) {
            .advance => |advance| try result.addSet(allocator, advance.chars),
            else => {},
        }
    }
    return result;
}

fn computeConflictStatusPair(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    left_index: usize,
    right_index: usize,
) std.mem.Allocator.Error![2]TokenConflictStatus {
    var queue = std.ArrayListUnmanaged(TokenConflictPairState).empty;
    defer {
        for (queue.items) |state| {
            allocator.free(state.left);
            allocator.free(state.right);
        }
        queue.deinit(allocator);
    }

    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();

    const left_start = try epsilonClosureAlloc(allocator, grammar, &.{grammar.variables[left_index].start_state});
    const right_start = try epsilonClosureAlloc(allocator, grammar, &.{grammar.variables[right_index].start_state});
    try queue.append(allocator, .{ .left = left_start, .right = right_start });
    try visited.put(pairStateHash(left_start, right_start), {});

    var result = [2]TokenConflictStatus{ .{}, .{} };

    while (queue.items.len != 0) {
        const pair_state = queue.pop().?;
        defer allocator.free(pair_state.left);
        defer allocator.free(pair_state.right);

        const left_completion = firstCompletion(pair_state.left, grammar);
        const right_completion = firstCompletion(pair_state.right, grammar);
        if (left_completion != null and right_completion != null) {
            const preferred_left = preferCompletedToken(grammar, left_completion.?, right_completion.?);
            if (preferred_left) {
                result[0].matches_same_string = true;
            } else {
                result[1].matches_same_string = true;
            }
        }

        const left_transitions = try collectTransitionsAlloc(allocator, grammar, pair_state.left);
        defer freeTransitions(allocator, left_transitions);
        const right_transitions = try collectTransitionsAlloc(allocator, grammar, pair_state.right);
        defer freeTransitions(allocator, right_transitions);

        if (left_transitions.len == 0 and right_transitions.len == 0) continue;

        var left_overlap = false;
        var right_overlap = false;
        for (left_transitions) |left_transition| {
            for (right_transitions) |right_transition| {
                if (!characterSetsIntersect(left_transition.chars, right_transition.chars)) continue;
                left_overlap = true;
                right_overlap = true;

                const left_next = try epsilonClosureAlloc(allocator, grammar, &.{left_transition.target_state});
                const right_next = try epsilonClosureAlloc(allocator, grammar, &.{right_transition.target_state});
                const hash = pairStateHash(left_next, right_next);
                if (!visited.contains(hash)) {
                    try visited.put(hash, {});
                    try queue.append(allocator, .{ .left = left_next, .right = right_next });
                } else {
                    allocator.free(left_next);
                    allocator.free(right_next);
                }
            }
        }

        if (!left_overlap and left_transitions.len != 0) result[0].matches_different_string = true;
        if (!right_overlap and right_transitions.len != 0) result[1].matches_different_string = true;

        if (left_completion) |completion| {
            for (right_transitions) |transition| {
                if (preferAdvanceOverCompletion(grammar, completion, transition)) {
                    result[1].does_match_continuation = true;
                } else {
                    result[0].matches_prefix = true;
                }
            }
        }
        if (right_completion) |completion| {
            for (left_transitions) |transition| {
                if (preferAdvanceOverCompletion(grammar, completion, transition)) {
                    result[0].does_match_continuation = true;
                } else {
                    result[1].matches_prefix = true;
                }
            }
        }
    }

    return result;
}

fn epsilonClosureAlloc(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    seeds: []const u32,
) std.mem.Allocator.Error![]u32 {
    var closure = std.ArrayListUnmanaged(u32).empty;
    errdefer closure.deinit(allocator);
    var stack = std.ArrayListUnmanaged(u32).empty;
    defer stack.deinit(allocator);

    for (seeds) |seed| {
        if (!containsState(closure.items, seed)) {
            try closure.append(allocator, seed);
            try stack.append(allocator, seed);
        }
    }

    while (stack.items.len != 0) {
        const state_id = stack.pop().?;
        switch (grammar.nfa.states.items[state_id]) {
            .split => |split| {
                if (!containsState(closure.items, split.left)) {
                    try closure.append(allocator, split.left);
                    try stack.append(allocator, split.left);
                }
                if (!containsState(closure.items, split.right)) {
                    try closure.append(allocator, split.right);
                    try stack.append(allocator, split.right);
                }
            },
            else => {},
        }
    }

    std.mem.sort(u32, closure.items, {}, std.sort.asc(u32));
    return closure.toOwnedSlice(allocator);
}

fn containsState(states: []const u32, target: u32) bool {
    for (states) |state_id| {
        if (state_id == target) return true;
    }
    return false;
}

fn collectTransitionsAlloc(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    states: []const u32,
) std.mem.Allocator.Error![]AdvanceTransition {
    var transitions = std.ArrayListUnmanaged(AdvanceTransition).empty;
    errdefer {
        for (transitions.items) |*transition| transition.chars.deinit(allocator);
        transitions.deinit(allocator);
    }

    for (states) |state_id| {
        switch (grammar.nfa.states.items[state_id]) {
            .advance => |advance| try transitions.append(allocator, .{
                .chars = try cloneCharacterSet(allocator, advance.chars),
                .target_state = advance.state_id,
                .is_separator = advance.is_separator,
                .precedence = advance.precedence,
            }),
            else => {},
        }
    }

    return transitions.toOwnedSlice(allocator);
}

fn freeTransitions(allocator: std.mem.Allocator, transitions: []AdvanceTransition) void {
    for (transitions) |*transition| transition.chars.deinit(allocator);
    allocator.free(transitions);
}

fn firstCompletion(states: []const u32, grammar: ExpandedLexicalGrammar) ?ConflictCompletion {
    var completion: ?ConflictCompletion = null;
    for (states) |state_id| {
        switch (grammar.nfa.states.items[state_id]) {
            .accept => |accept| {
                const candidate: ConflictCompletion = .{
                    .variable_index = accept.variable_index,
                    .precedence = accept.precedence,
                };
                if (completion == null or preferCompletedToken(grammar, candidate, completion.?)) {
                    completion = candidate;
                }
            },
            else => {},
        }
    }
    return completion;
}

fn preferCompletedToken(
    grammar: ExpandedLexicalGrammar,
    left: ConflictCompletion,
    right: ConflictCompletion,
) bool {
    if (left.precedence != right.precedence) return left.precedence > right.precedence;
    const left_var = grammar.variables[left.variable_index];
    const right_var = grammar.variables[right.variable_index];
    if (left_var.implicit_precedence != right_var.implicit_precedence) {
        return left_var.implicit_precedence > right_var.implicit_precedence;
    }
    return left.variable_index < right.variable_index;
}

fn preferAdvanceOverCompletion(
    grammar: ExpandedLexicalGrammar,
    completion: ConflictCompletion,
    transition: AdvanceTransition,
) bool {
    if (transition.precedence != completion.precedence) {
        return transition.precedence > completion.precedence;
    }
    if (transition.is_separator) return false;
    _ = grammar;
    return true;
}

fn pairStateHash(left: []const u32, right: []const u32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, left.len);
    for (left) |value| std.hash.autoHash(&hasher, value);
    std.hash.autoHash(&hasher, right.len);
    for (right) |value| std.hash.autoHash(&hasher, value);
    return hasher.final();
}

fn characterSetsIntersect(left: CharacterSet, right: CharacterSet) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.ranges.items.len and j < right.ranges.items.len) {
        const left_range = left.ranges.items[i];
        const right_range = right.ranges.items[j];
        if (left_range.end <= right_range.start) {
            i += 1;
            continue;
        }
        if (right_range.end <= left_range.start) {
            j += 1;
            continue;
        }
        return true;
    }
    return false;
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

test "matchVariable consumes leading separators for non-immediate tokens" {
    const all_rules = [_]rules.Rule{
        .{ .string = "let" },
        .{ .pattern = .{ .value = "[ ]+", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "keyword", .kind = .named, .rule = 0 },
        },
        .separators = &.{1},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, 5), try matchVariable(std.testing.allocator, expanded, 0, "  let"));
    const match = (try selectBestToken(std.testing.allocator, expanded, "  let")).?;
    try std.testing.expectEqual(@as(usize, 5), match.len);
}

test "matchVariable does not consume leading separators for immediate tokens" {
    const all_rules = [_]rules.Rule{
        .{
            .metadata = .{
                .inner = 1,
                .data = .{ .immediate_token = true },
            },
        },
        .{ .string = "let" },
        .{ .pattern = .{ .value = "[ ]+", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "keyword", .kind = .named, .rule = 0 },
        },
        .separators = &.{2},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, null), try matchVariable(std.testing.allocator, expanded, 0, "  let"));
    try std.testing.expectEqual(@as(?usize, 3), try matchVariable(std.testing.allocator, expanded, 0, "let"));
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

test "collectTokenMatchesAlloc sorts matches by lexer priority" {
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

    const matches = try collectTokenMatchesAlloc(std.testing.allocator, expanded, "let");
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 1), matches[0].variable_index);
    try std.testing.expectEqual(@as(usize, 0), matches[1].variable_index);
}

test "collectTokenMatchesAlloc prefers higher completion precedence before implicit precedence" {
    const all_rules = [_]rules.Rule{
        .{
            .metadata = .{
                .inner = 1,
                .data = .{
                    .precedence = .{ .integer = 5 },
                },
            },
        },
        .{ .string = "let" },
        .{
            .metadata = .{
                .inner = 3,
                .data = .{
                    .token = true,
                },
            },
        },
        .{ .string = "let" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "high_completion", .kind = .named, .rule = 0 },
            .{ .name = "high_implicit", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    const matches = try collectTokenMatchesAlloc(std.testing.allocator, expanded, "let");
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].variable_index);
    try std.testing.expectEqual(@as(i32, 5), matches[0].completion_precedence);
    try std.testing.expectEqual(@as(i32, 3), matches[1].implicit_precedence);
}

test "expandExtractedLexicalGrammar supports ziggy-schema and bash regex forms" {
    const all_rules = [_]rules.Rule{
        .{ .pattern = .{ .value = "[^\"]*", .flags = null } },
        .{ .pattern = .{ .value = "\\d+", .flags = null } },
        .{ .pattern = .{ .value = "[a-zA-Z_][a-zA-Z0-9_]*", .flags = null } },
        .{ .pattern = .{ .value = ".*", .flags = null } },
        .{ .pattern = .{ .value = "\\(", .flags = null } },
        .{ .pattern = .{ .value = "\\s", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "string_body", .kind = .named, .rule = 0 },
            .{ .name = "digits", .kind = .named, .rule = 1 },
            .{ .name = "identifier", .kind = .named, .rule = 2 },
            .{ .name = "comment_tail", .kind = .named, .rule = 3 },
            .{ .name = "lparen", .kind = .named, .rule = 4 },
            .{ .name = "space", .kind = .named, .rule = 5 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, 5), try matchVariable(std.testing.allocator, expanded, 0, "hello\""));
    try std.testing.expectEqual(@as(?usize, 3), try matchVariable(std.testing.allocator, expanded, 1, "123abc"));
    try std.testing.expectEqual(@as(?usize, 6), try matchVariable(std.testing.allocator, expanded, 2, "abc123!"));
    try std.testing.expectEqual(@as(?usize, 3), try matchVariable(std.testing.allocator, expanded, 3, "abc\n"));
    try std.testing.expectEqual(@as(?usize, 1), try matchVariable(std.testing.allocator, expanded, 4, "("));
    try std.testing.expectEqual(@as(?usize, 1), try matchVariable(std.testing.allocator, expanded, 5, " \t"));
}

test "buildTokenConflictMapAlloc marks same-string conflicts for identical literals" {
    const all_rules = [_]rules.Rule{
        .{
            .metadata = .{
                .inner = 1,
                .data = .{ .precedence = .{ .integer = 2 } },
            },
        },
        .{ .string = "let" },
        .{ .string = "let" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "preferred", .kind = .named, .rule = 0 },
            .{ .name = "other", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var conflict_map = try buildTokenConflictMapAlloc(std.testing.allocator, expanded);
    defer conflict_map.deinit(std.testing.allocator);

    try std.testing.expect(conflict_map.status(0, 1).matches_same_string);
    try std.testing.expect(!conflict_map.status(1, 0).matches_same_string);
    try std.testing.expect(conflict_map.status(0, 1).starting_overlap);
}

test "buildTokenConflictMapAlloc marks literal prefix and identifier continuation" {
    const all_rules = [_]rules.Rule{
        .{ .string = "let" },
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "keyword", .kind = .named, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var conflict_map = try buildTokenConflictMapAlloc(std.testing.allocator, expanded);
    defer conflict_map.deinit(std.testing.allocator);

    try std.testing.expect(conflict_map.status(0, 1).matches_same_string);
    try std.testing.expect(!conflict_map.status(0, 1).matches_prefix);
    try std.testing.expect(conflict_map.status(1, 0).does_match_continuation);
}

test "selectPreferredMatch uses conflict map for same-string lexical conflicts" {
    const all_rules = [_]rules.Rule{
        .{ .string = "let" },
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "keyword", .kind = .named, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var conflict_map = try buildTokenConflictMapAlloc(std.testing.allocator, expanded);
    defer conflict_map.deinit(std.testing.allocator);

    const valid_matches = [_]TokenMatch{
        .{
            .variable_index = 1,
            .len = 3,
            .completion_precedence = expanded.variables[1].completion_precedence,
            .implicit_precedence = expanded.variables[1].implicit_precedence,
            .kind = expanded.variables[1].kind,
        },
        .{
            .variable_index = 0,
            .len = 3,
            .completion_precedence = expanded.variables[0].completion_precedence,
            .implicit_precedence = expanded.variables[0].implicit_precedence,
            .kind = expanded.variables[0].kind,
        },
    };

    const preferred = selectPreferredMatch(valid_matches[0..], conflict_map).?;
    try std.testing.expectEqual(@as(usize, 0), preferred.variable_index);
}

test "pruneConflictingMatches removes lower-priority same-string candidates" {
    const all_rules = [_]rules.Rule{
        .{
            .metadata = .{
                .inner = 1,
                .data = .{ .precedence = .{ .integer = 2 } },
            },
        },
        .{ .string = "let" },
        .{ .string = "let" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "preferred", .kind = .named, .rule = 0 },
            .{ .name = "other", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var conflict_map = try buildTokenConflictMapAlloc(std.testing.allocator, expanded);
    defer conflict_map.deinit(std.testing.allocator);

    var valid_matches = std.ArrayListUnmanaged(TokenMatch).empty;
    defer valid_matches.deinit(std.testing.allocator);
    try valid_matches.append(std.testing.allocator, .{
        .variable_index = 1,
        .len = 3,
        .completion_precedence = expanded.variables[1].completion_precedence,
        .implicit_precedence = expanded.variables[1].implicit_precedence,
        .kind = expanded.variables[1].kind,
    });
    try valid_matches.append(std.testing.allocator, .{
        .variable_index = 0,
        .len = 3,
        .completion_precedence = expanded.variables[0].completion_precedence,
        .implicit_precedence = expanded.variables[0].implicit_precedence,
        .kind = expanded.variables[0].kind,
    });

    pruneConflictingMatches(&valid_matches, conflict_map);
    try std.testing.expectEqual(@as(usize, 1), valid_matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), valid_matches.items[0].variable_index);
}

test "pruneConflictingMatches removes shorter valid prefix candidates when a continuation token is also valid" {
    const all_rules = [_]rules.Rule{
        .{ .string = "let" },
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "keyword", .kind = .named, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var conflict_map = try buildTokenConflictMapAlloc(std.testing.allocator, expanded);
    defer conflict_map.deinit(std.testing.allocator);

    var valid_matches = std.ArrayListUnmanaged(TokenMatch).empty;
    defer valid_matches.deinit(std.testing.allocator);
    try valid_matches.append(std.testing.allocator, .{
        .variable_index = 0,
        .len = 3,
        .completion_precedence = expanded.variables[0].completion_precedence,
        .implicit_precedence = expanded.variables[0].implicit_precedence,
        .kind = expanded.variables[0].kind,
    });
    try valid_matches.append(std.testing.allocator, .{
        .variable_index = 1,
        .len = 6,
        .completion_precedence = expanded.variables[1].completion_precedence,
        .implicit_precedence = expanded.variables[1].implicit_precedence,
        .kind = expanded.variables[1].kind,
    });

    pruneConflictingMatches(&valid_matches, conflict_map);
    try std.testing.expectEqual(@as(usize, 1), valid_matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), valid_matches.items[0].variable_index);
}

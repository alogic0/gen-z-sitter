const std = @import("std");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const rules = @import("../ir/rules.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const first_sets = @import("../parse_table/first.zig");
const lexer_table = @import("table.zig");

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

pub const DetailedTokenMatch = struct {
    variable_index: usize,
    len: usize,
    leading_separator_len: usize,
    completion_precedence: i32,
    implicit_precedence: i32,
    kind: lexical_ir.VariableKind,
};

pub const TokenIndexSet = struct {
    values: []bool,

    pub fn initEmpty(allocator: std.mem.Allocator, count: usize) !TokenIndexSet {
        const values = try allocator.alloc(bool, count);
        @memset(values, false);
        return .{ .values = values };
    }

    pub fn deinit(self: *TokenIndexSet, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        self.* = undefined;
    }

    pub fn clone(self: TokenIndexSet, allocator: std.mem.Allocator) !TokenIndexSet {
        return .{ .values = try allocator.dupe(bool, self.values) };
    }

    pub fn insert(self: *TokenIndexSet, index: usize) void {
        self.values[index] = true;
    }

    pub fn contains(self: TokenIndexSet, index: usize) bool {
        return self.values[index];
    }

    pub fn fill(self: *TokenIndexSet) void {
        @memset(self.values, true);
    }
};

pub fn deinitTokenIndexSets(allocator: std.mem.Allocator, sets: []TokenIndexSet) void {
    for (sets) |*set| set.deinit(allocator);
    allocator.free(sets);
}

pub const TokenConflictStatus = packed struct(u16) {
    matches_prefix: bool = false,
    does_match_continuation: bool = false,
    does_match_valid_continuation: bool = false,
    does_match_separators: bool = false,
    matches_same_string: bool = false,
    matches_different_string: bool = false,
    starting_overlap: bool = false,
    _padding: u9 = 0,
};

pub const TokenConflictMap = struct {
    variable_count: usize,
    status_matrix: []TokenConflictStatus,
    following_tokens_by_index: []TokenIndexSet,
    starting_chars_by_index: []CharacterSet,
    following_chars_by_index: []CharacterSet,

    pub fn deinit(self: *TokenConflictMap, allocator: std.mem.Allocator) void {
        for (self.following_tokens_by_index) |*set| set.deinit(allocator);
        allocator.free(self.following_tokens_by_index);
        for (self.starting_chars_by_index) |*chars| chars.deinit(allocator);
        for (self.following_chars_by_index) |*chars| chars.deinit(allocator);
        allocator.free(self.following_chars_by_index);
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
    leading_separator_len: usize,
    has_seen_non_separator: bool,
};

const MatchResult = struct {
    end_offset: usize,
    leading_separator_len: usize,
};

const AdvanceTransition = struct {
    chars: CharacterSet,
    target_state: u32,
    is_separator: bool,
    precedence: i32,
};

const TransitionCollection = struct {
    transitions: []AdvanceTransition,
    has_separator_transitions: bool,
};

const CombinedLexTransition = struct {
    chars: CharacterSet,
    next_state_id: usize,
    is_separator: bool,
    precedence: i32,
};

const CombinedLexState = struct {
    nfa_states: []const u32,
    completion: ?ConflictCompletion,
    transitions: []CombinedLexTransition,
    has_separator_transitions: bool,
};

const CombinedLexStateMachine = struct {
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    allowed_tokens: TokenIndexSet,
    states: std.ArrayListUnmanaged(CombinedLexState) = .empty,

    fn deinit(self: *CombinedLexStateMachine) void {
        for (self.states.items) |*state| {
            self.allocator.free(state.nfa_states);
            for (state.transitions) |*transition| transition.chars.deinit(self.allocator);
            self.allocator.free(state.transitions);
        }
        self.states.deinit(self.allocator);
        self.* = undefined;
    }

    fn internState(self: *CombinedLexStateMachine, nfa_states: []const u32) !usize {
        for (self.states.items, 0..) |state, index| {
            if (std.mem.eql(u32, state.nfa_states, nfa_states)) return index;
        }

        const owned_states = try self.allocator.dupe(u32, nfa_states);
        errdefer self.allocator.free(owned_states);

        const completion = bestCompletionForAllowed(owned_states, self.grammar, self.allowed_tokens);
        try self.states.append(self.allocator, .{
            .nfa_states = owned_states,
            .completion = completion,
            .transitions = &.{},
            .has_separator_transitions = false,
        });
        const state_id = self.states.items.len - 1;

        const transition_collection = try collectTransitionsAlloc(self.allocator, self.grammar, owned_states);
        errdefer {
            _ = self.states.pop();
            freeTransitions(self.allocator, transition_collection.transitions);
        }

        var transitions = try self.allocator.alloc(CombinedLexTransition, transition_collection.transitions.len);
        errdefer {
            _ = self.states.pop();
            self.allocator.free(transitions);
        }

        for (transition_collection.transitions, 0..) |transition, index| {
            const next_states = try epsilonClosureAlloc(self.allocator, self.grammar, &.{transition.target_state});
            defer self.allocator.free(next_states);
            const next_state_id = try self.internState(next_states);
            transitions[index] = .{
                .chars = transition.chars,
                .next_state_id = next_state_id,
                .is_separator = transition.is_separator,
                .precedence = transition.precedence,
            };
        }
        self.allocator.free(transition_collection.transitions);
        self.states.items[state_id].transitions = transitions;
        self.states.items[state_id].has_separator_transitions = transition_collection.has_separator_transitions;
        return state_id;
    }

    fn stateContainsCompletion(self: *const CombinedLexStateMachine, state_id: usize, variable_index: usize) bool {
        for (self.states.items[state_id].nfa_states) |nfa_state_id| {
            switch (self.grammar.nfa.states.items[nfa_state_id]) {
                .accept => |accept| if (accept.variable_index == variable_index) return true,
                else => {},
            }
        }
        return false;
    }

    fn bestToken(self: *const CombinedLexStateMachine, state_id: usize, input: []const u8, offset: usize) !?TokenMatch {
        const state = self.states.items[state_id];
        const completion_match: ?TokenMatch = if (state.completion) |value|
            tokenMatchFromCompletion(self.grammar, value, offset)
        else
            null;

        const cursor = decodeNextCodepoint(input, offset) orelse return completion_match;

        var best_continuation: ?TokenMatch = null;
        for (state.transitions) |transition| {
            if (!transition.chars.contains(cursor.codepoint)) continue;

            const successor_contains_completed = if (state.completion) |value|
                self.stateContainsCompletion(transition.next_state_id, value.variable_index)
            else
                false;

            if (state.completion) |value| {
                if (!preferAdvanceOverCompletion(
                    self.grammar,
                    value,
                    .{
                        .chars = transition.chars,
                        .target_state = 0,
                        .is_separator = transition.is_separator,
                        .precedence = transition.precedence,
                    },
                    successor_contains_completed,
                    state.has_separator_transitions,
                )) continue;
            }

            const candidate = try self.bestToken(
                transition.next_state_id,
                input,
                offset + cursor.byte_len,
            ) orelse continue;

            if (best_continuation == null or tokenMatchLessThan(best_continuation.?, candidate)) {
                best_continuation = candidate;
            }
        }

        if (completion_match == null) return best_continuation;
        if (best_continuation == null) return completion_match;
        return if (tokenMatchLessThan(completion_match.?, best_continuation.?))
            best_continuation
        else
            completion_match;
    }
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
    optional,
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

const RegexRepeat = union(enum) {
    optional,
    zero_or_more,
    one_or_more,
    range: struct {
        min: usize,
        max: ?usize,
    },
};

const RegexNode = union(enum) {
    empty,
    chars: CharacterSet,
    sequence: []RegexNode,
    choice: []RegexNode,
    repeat: struct {
        node: *RegexNode,
        quantifier: RegexRepeat,
    },

    fn deinit(self: *RegexNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty => {},
            .chars => |*chars| chars.deinit(allocator),
            .sequence, .choice => |nodes| {
                for (nodes) |*node| node.deinit(allocator);
                allocator.free(nodes);
            },
            .repeat => |repeat| {
                repeat.node.deinit(allocator);
                allocator.destroy(repeat.node);
            },
        }
        self.* = undefined;
    }
};

const RegexParser = struct {
    allocator: std.mem.Allocator,
    value: []const u8,
    flags: ?[]const u8,
    index: usize = 0,

    fn parse(self: *RegexParser) ExpandError!RegexNode {
        var node = try self.parseChoice();
        errdefer node.deinit(self.allocator);
        if (self.index != self.value.len) return error.UnsupportedPattern;
        return node;
    }

    fn parseChoice(self: *RegexParser) ExpandError!RegexNode {
        var alternatives = std.ArrayListUnmanaged(RegexNode).empty;
        errdefer {
            for (alternatives.items) |*node| node.deinit(self.allocator);
            alternatives.deinit(self.allocator);
        }

        try alternatives.append(self.allocator, try self.parseSequence());
        while (self.index < self.value.len and self.value[self.index] == '|') {
            self.index += 1;
            try alternatives.append(self.allocator, try self.parseSequence());
        }

        if (alternatives.items.len == 1) {
            const node = alternatives.items[0];
            alternatives.deinit(self.allocator);
            return node;
        }

        return .{ .choice = try alternatives.toOwnedSlice(self.allocator) };
    }

    fn parseSequence(self: *RegexParser) ExpandError!RegexNode {
        var nodes = std.ArrayListUnmanaged(RegexNode).empty;
        errdefer {
            for (nodes.items) |*node| node.deinit(self.allocator);
            nodes.deinit(self.allocator);
        }

        while (self.index < self.value.len and self.value[self.index] != ')' and self.value[self.index] != '|') {
            try nodes.append(self.allocator, try self.parseRepeat());
        }

        if (nodes.items.len == 0) return .empty;
        if (nodes.items.len == 1) {
            const node = nodes.items[0];
            nodes.deinit(self.allocator);
            return node;
        }

        return .{ .sequence = try nodes.toOwnedSlice(self.allocator) };
    }

    fn parseRepeat(self: *RegexParser) ExpandError!RegexNode {
        var node = try self.parsePrimary();
        errdefer node.deinit(self.allocator);

        if (self.index >= self.value.len) return node;
        const quantifier: ?RegexRepeat = switch (self.value[self.index]) {
            '?' => blk: {
                self.index += 1;
                break :blk .optional;
            },
            '*' => blk: {
                self.index += 1;
                break :blk .zero_or_more;
            },
            '+' => blk: {
                self.index += 1;
                break :blk .one_or_more;
            },
            '{' => try self.parseRangeQuantifier(),
            else => null,
        };
        if (quantifier == null) return node;

        const inner = try self.allocator.create(RegexNode);
        inner.* = node;
        return .{ .repeat = .{
            .node = inner,
            .quantifier = quantifier.?,
        } };
    }

    fn parsePrimary(self: *RegexParser) ExpandError!RegexNode {
        if (self.index >= self.value.len) return error.UnsupportedPattern;
        return switch (self.value[self.index]) {
            '(' => blk: {
                self.index += 1;
                var node = try self.parseChoice();
                errdefer node.deinit(self.allocator);
                if (self.index >= self.value.len or self.value[self.index] != ')') return error.UnsupportedPattern;
                self.index += 1;
                break :blk node;
            },
            '[' => blk: {
                const atom = try parseBracketClassAtom(self.allocator, self.value, &self.index, self.flags);
                break :blk .{ .chars = atom.chars };
            },
            '.' => blk: {
                self.index += 1;
                var chars = try CharacterSet.full(self.allocator);
                try chars.removeCodepointRange(self.allocator, '\n', '\n' + 1);
                break :blk .{ .chars = chars };
            },
            '\\' => blk: {
                const atom = try parseEscapedAtom(self.allocator, self.value, &self.index);
                break :blk .{ .chars = atom.chars };
            },
            ')', '|', '?', '*', '+', '{' => error.UnsupportedPattern,
            else => blk: {
                const chars = try CharacterSet.fromChar(self.allocator, self.value[self.index]);
                self.index += 1;
                break :blk .{ .chars = chars };
            },
        };
    }

    fn parseRangeQuantifier(self: *RegexParser) ExpandError!?RegexRepeat {
        std.debug.assert(self.value[self.index] == '{');
        self.index += 1;
        const min = try self.parseUnsigned();
        var max: ?usize = min;
        if (self.index < self.value.len and self.value[self.index] == ',') {
            self.index += 1;
            max = if (self.index < self.value.len and std.ascii.isDigit(self.value[self.index]))
                try self.parseUnsigned()
            else
                null;
        }
        if (self.index >= self.value.len or self.value[self.index] != '}') return error.UnsupportedPattern;
        self.index += 1;
        if (max != null and max.? < min) return error.UnsupportedPattern;
        return .{ .range = .{ .min = min, .max = max } };
    }

    fn parseUnsigned(self: *RegexParser) ExpandError!usize {
        const start = self.index;
        var value: usize = 0;
        while (self.index < self.value.len and std.ascii.isDigit(self.value[self.index])) : (self.index += 1) {
            value = value * 10 + (self.value[self.index] - '0');
        }
        if (self.index == start) return error.UnsupportedPattern;
        return value;
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
        var parser = RegexParser{
            .allocator = self.allocator,
            .value = pattern.value,
            .flags = pattern.flags,
        };
        var node = try parser.parse();
        defer node.deinit(self.allocator);
        _ = try self.expandRegexNode(node, next_state_id);
        return node != .empty;
    }

    fn expandRegexNode(self: *Builder, node: RegexNode, next_state_id: u32) ExpandError!u32 {
        return switch (node) {
            .empty => next_state_id,
            .chars => |chars| self.expandPatternAtom(.{ .chars = chars }, next_state_id),
            .sequence => |nodes| blk: {
                var next = next_state_id;
                var i = nodes.len;
                while (i > 0) {
                    i -= 1;
                    next = try self.expandRegexNode(nodes[i], next);
                }
                break :blk next;
            },
            .choice => |nodes| blk: {
                var alternative_states = std.ArrayListUnmanaged(u32).empty;
                defer alternative_states.deinit(self.allocator);
                for (nodes) |alternative| {
                    try alternative_states.append(self.allocator, try self.expandRegexNode(alternative, next_state_id));
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
                break :blk self.nfa.lastStateId();
            },
            .repeat => |repeat| self.expandRegexRepeat(repeat.node.*, repeat.quantifier, next_state_id),
        };
    }

    fn expandRegexRepeat(self: *Builder, node: RegexNode, quantifier: RegexRepeat, next_state_id: u32) ExpandError!u32 {
        return switch (quantifier) {
            .optional => blk: {
                const inner_start = try self.expandRegexNode(node, next_state_id);
                try self.pushSplit(inner_start, next_state_id);
                break :blk self.nfa.lastStateId();
            },
            .zero_or_more => blk: {
                try self.nfa.states.append(self.allocator, .{
                    .split = .{ .left = next_state_id, .right = next_state_id },
                });
                const loop_split_state_id = self.nfa.lastStateId();
                const inner_start = try self.expandRegexNode(node, loop_split_state_id);
                self.nfa.states.items[loop_split_state_id] = .{
                    .split = .{ .left = inner_start, .right = next_state_id },
                };
                try self.pushSplit(inner_start, next_state_id);
                break :blk self.nfa.lastStateId();
            },
            .one_or_more => blk: {
                try self.nfa.states.append(self.allocator, .{
                    .split = .{ .left = next_state_id, .right = next_state_id },
                });
                const loop_split_state_id = self.nfa.lastStateId();
                const inner_start = try self.expandRegexNode(node, loop_split_state_id);
                self.nfa.states.items[loop_split_state_id] = .{
                    .split = .{ .left = inner_start, .right = next_state_id },
                };
                try self.pushSplit(inner_start, next_state_id);
                break :blk inner_start;
            },
            .range => |range| blk: {
                var next = next_state_id;
                if (range.max) |max| {
                    var optional_count = max - range.min;
                    while (optional_count > 0) : (optional_count -= 1) {
                        next = try self.expandRegexRepeat(node, .optional, next);
                    }
                } else {
                    next = try self.expandRegexRepeat(node, .zero_or_more, next);
                }
                var required_count = range.min;
                while (required_count > 0) : (required_count -= 1) {
                    next = try self.expandRegexNode(node, next);
                }
                break :blk next;
            },
        };
    }

    fn expandPatternAtom(self: *Builder, atom: PatternAtom, next_state_id: u32) !u32 {
        return switch (atom.quantifier) {
            .once => blk: {
                try self.pushAdvance(try cloneCharacterSet(self.allocator, atom.chars), next_state_id);
                break :blk self.nfa.lastStateId();
            },
            .optional => blk: {
                try self.pushAdvance(try cloneCharacterSet(self.allocator, atom.chars), next_state_id);
                const advance_state = self.nfa.lastStateId();
                try self.pushSplit(advance_state, next_state_id);
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

fn followingCharsForTokenSetAlloc(
    allocator: std.mem.Allocator,
    starting_chars_by_index: []const CharacterSet,
    following_tokens: TokenIndexSet,
) !CharacterSet {
    var result = CharacterSet.empty();
    for (starting_chars_by_index, 0..) |chars, index| {
        if (!following_tokens.contains(index)) continue;
        try result.addSet(allocator, chars);
    }
    return result;
}

fn mergeTokenIndexSet(target: *TokenIndexSet, incoming: TokenIndexSet) bool {
    var changed = false;
    for (incoming.values, 0..) |present, index| {
        if (!present or target.values[index]) continue;
        target.values[index] = true;
        changed = true;
    }
    return changed;
}

fn mergeTokenIndexSetFromSymbolSet(target: *TokenIndexSet, incoming: first_sets.SymbolSet) bool {
    var changed = false;
    var terminal_iter = incoming.terminals.bits.iterator(.{});
    while (terminal_iter.next()) |index| {
        if (index >= target.values.len or target.values[index]) continue;
        target.values[index] = true;
        changed = true;
    }
    return changed;
}

fn deinitSymbolSet(allocator: std.mem.Allocator, set: first_sets.SymbolSet) void {
    var terminals = set.terminals;
    var externals = set.externals;
    terminals.deinit(allocator);
    externals.deinit(allocator);
}

fn deinitFirstSets(allocator: std.mem.Allocator, sets: first_sets.FirstSets) void {
    for (sets.per_variable) |set| {
        deinitSymbolSet(allocator, set);
    }
    allocator.free(sets.per_variable);
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
                '?' => blk: {
                    index += 1;
                    break :blk PatternQuantifier.optional;
                },
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

    const escaped = value[index.*];
    const chars = switch (escaped) {
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
        'S' => blk: {
            var set = try CharacterSet.full(allocator);
            try set.removeCodepointRange(allocator, ' ', ' ' + 1);
            try set.removeCodepointRange(allocator, '\t', '\t' + 1);
            try set.removeCodepointRange(allocator, '\n', '\n' + 1);
            try set.removeCodepointRange(allocator, '\r', '\r' + 1);
            break :blk set;
        },
        'w' => blk: {
            var set = CharacterSet.empty();
            try set.addRange(allocator, 'a', 'z');
            try set.addRange(allocator, 'A', 'Z');
            try set.addRange(allocator, '0', '9');
            try set.addRange(allocator, '_', '_');
            break :blk set;
        },
        'p' => try parseUnicodePropertySet(allocator, value, index),
        else => try CharacterSet.fromChar(allocator, value[index.*]),
    };
    if (escaped != 'p') index.* += 1;
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
    if (std.mem.eql(u8, property_name, "XID_Start")) {
        try set.addRange(allocator, 'A', 'Z');
        try set.addRange(allocator, 'a', 'z');
        try set.addRange(allocator, '_', '_');
        try set.addCodepointRange(allocator, 0x80, 0x110000);
        return set;
    }
    if (std.mem.eql(u8, property_name, "XID_Continue")) {
        try set.addRange(allocator, 'A', 'Z');
        try set.addRange(allocator, 'a', 'z');
        try set.addRange(allocator, '0', '9');
        try set.addRange(allocator, '_', '_');
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

pub fn matchVariableDetailed(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    variable_index: usize,
    input: []const u8,
) std.mem.Allocator.Error!?MatchResult {
    std.debug.assert(variable_index < grammar.variables.len);

    var visited = std.ArrayListUnmanaged(VisitedState).empty;
    defer visited.deinit(allocator);

    const variable = grammar.variables[variable_index];
    return try matchStateDetailed(
        allocator,
        grammar,
        variable.start_state,
        input,
        0,
        0,
        false,
        &visited,
    );
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

pub fn selectBestTokenForSet(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    allowed_tokens: TokenIndexSet,
    input: []const u8,
) std.mem.Allocator.Error!?TokenMatch {
    return lexer_table.selectBestTokenForSet(allocator, grammar, allowed_tokens, input);
}

pub fn selectBestTokenDetailed(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    input: []const u8,
) std.mem.Allocator.Error!?DetailedTokenMatch {
    var best: ?DetailedTokenMatch = null;
    for (grammar.variables, 0..) |variable, index| {
        const match_result = try matchVariableDetailed(allocator, grammar, index, input) orelse continue;
        const candidate: DetailedTokenMatch = .{
            .variable_index = index,
            .len = match_result.end_offset,
            .leading_separator_len = match_result.leading_separator_len,
            .completion_precedence = variable.completion_precedence,
            .implicit_precedence = variable.implicit_precedence,
            .kind = variable.kind,
        };
        if (best == null or detailedTokenMatchLessThan(best.?, candidate)) best = candidate;
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
    const following_tokens = try allocator.alloc(TokenIndexSet, variable_count);
    defer {
        for (following_tokens[0..variable_count]) |*set| set.deinit(allocator);
        allocator.free(following_tokens);
    }

    for (0..variable_count) |index| {
        following_tokens[index] = try TokenIndexSet.initEmpty(allocator, variable_count);
        following_tokens[index].fill();
    }

    return buildTokenConflictMapWithFollowingTokensAlloc(allocator, grammar, following_tokens);
}

pub fn computeFollowingTokensAlloc(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
    terminal_count: usize,
) (std.mem.Allocator.Error || first_sets.FirstError)![]TokenIndexSet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const computed_first_sets = try first_sets.computeFirstSets(arena_allocator, grammar);

    const variable_follow = try allocator.alloc(TokenIndexSet, grammar.variables.len);
    defer deinitTokenIndexSets(allocator, variable_follow);
    for (0..grammar.variables.len) |index| {
        variable_follow[index] = try TokenIndexSet.initEmpty(allocator, terminal_count);
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (grammar.variables, 0..) |variable, lhs_index| {
            for (variable.productions) |production| {
                for (production.steps, 0..) |step, step_index| {
                    switch (step.symbol) {
                        .non_terminal => |rhs_index| {
                            const suffix_first = try computed_first_sets.firstOfSequence(
                                arena_allocator,
                                production.steps[step_index + 1 ..],
                            );

                            if (mergeTokenIndexSetFromSymbolSet(&variable_follow[rhs_index], suffix_first)) {
                                changed = true;
                            }
                            if (suffix_first.includes_epsilon) {
                                if (mergeTokenIndexSet(&variable_follow[rhs_index], variable_follow[lhs_index])) {
                                    changed = true;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }

    const following_tokens = try allocator.alloc(TokenIndexSet, terminal_count);
    errdefer deinitTokenIndexSets(allocator, following_tokens);
    for (0..terminal_count) |index| {
        following_tokens[index] = try TokenIndexSet.initEmpty(allocator, terminal_count);
    }

    for (grammar.variables, 0..) |variable, lhs_index| {
        for (variable.productions) |production| {
            for (production.steps, 0..) |step, step_index| {
                const terminal_index = switch (step.symbol) {
                    .terminal => |index| index,
                    else => continue,
                };

                const suffix_first = try computed_first_sets.firstOfSequence(
                    arena_allocator,
                    production.steps[step_index + 1 ..],
                );

                _ = mergeTokenIndexSetFromSymbolSet(&following_tokens[terminal_index], suffix_first);
                if (suffix_first.includes_epsilon) {
                    _ = mergeTokenIndexSet(&following_tokens[terminal_index], variable_follow[lhs_index]);
                }
            }
        }
    }

    return following_tokens;
}

pub fn buildTokenConflictMapWithFollowingTokensAlloc(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    following_tokens: []const TokenIndexSet,
) std.mem.Allocator.Error!TokenConflictMap {
    const variable_count = grammar.variables.len;
    std.debug.assert(following_tokens.len == variable_count);

    const status_matrix = try allocator.alloc(TokenConflictStatus, variable_count * variable_count);
    @memset(status_matrix, .{});
    errdefer allocator.free(status_matrix);

    const following_tokens_by_index = try allocator.alloc(TokenIndexSet, variable_count);
    errdefer {
        for (following_tokens_by_index[0..variable_count]) |*set| set.deinit(allocator);
        allocator.free(following_tokens_by_index);
    }

    const starting_chars_by_index = try allocator.alloc(CharacterSet, variable_count);
    errdefer {
        for (starting_chars_by_index[0..variable_count]) |*chars| chars.deinit(allocator);
        allocator.free(starting_chars_by_index);
    }

    const following_chars_by_index = try allocator.alloc(CharacterSet, variable_count);
    errdefer {
        for (following_chars_by_index[0..variable_count]) |*chars| chars.deinit(allocator);
        allocator.free(following_chars_by_index);
    }

    for (grammar.variables, 0..) |variable, index| {
        starting_chars_by_index[index] = try startingCharsForVariable(allocator, grammar, variable.start_state);
    }

    for (0..variable_count) |index| {
        following_tokens_by_index[index] = try following_tokens[index].clone(allocator);
        following_chars_by_index[index] = try followingCharsForTokenSetAlloc(
            allocator,
            starting_chars_by_index,
            following_tokens_by_index[index],
        );
    }

    for (0..variable_count) |left| {
        for (0..variable_count) |right| {
            if (left == right) continue;
            if (characterSetsIntersect(starting_chars_by_index[left], starting_chars_by_index[right])) {
                status_matrix[matrixIndex(variable_count, left, right)].starting_overlap = true;
            }
        }
    }

    const owner_by_state = try computeStateOwnersAlloc(allocator, grammar);
    defer allocator.free(owner_by_state);

    for (0..variable_count) |left| {
        for (0..left) |right| {
            const pair_status = try computeConflictStatusPair(
                allocator,
                grammar,
                owner_by_state,
                left,
                right,
                following_chars_by_index[left],
                following_chars_by_index[right],
            );
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
        .following_tokens_by_index = following_tokens_by_index,
        .starting_chars_by_index = starting_chars_by_index,
        .following_chars_by_index = following_chars_by_index,
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

fn detailedTokenMatchLessThan(current: DetailedTokenMatch, candidate: DetailedTokenMatch) bool {
    return tokenMatchLessThan(
        .{
            .variable_index = current.variable_index,
            .len = current.len,
            .completion_precedence = current.completion_precedence,
            .implicit_precedence = current.implicit_precedence,
            .kind = current.kind,
        },
        .{
            .variable_index = candidate.variable_index,
            .len = candidate.len,
            .completion_precedence = candidate.completion_precedence,
            .implicit_precedence = candidate.implicit_precedence,
            .kind = candidate.kind,
        },
    );
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

    if (candidate_status.does_match_separators and !current_status.does_match_separators) return true;
    if (current_status.does_match_separators and !candidate_status.does_match_separators) return false;

    if (candidate_status.does_match_valid_continuation and !current_status.does_match_valid_continuation) return true;
    if (current_status.does_match_valid_continuation and !candidate_status.does_match_valid_continuation) return false;

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

    if (dominator_status.does_match_separators and !candidate_status.does_match_separators) {
        return true;
    }

    if (dominator_status.does_match_valid_continuation and !candidate_status.does_match_valid_continuation) {
        return true;
    }

    if (dominator.len > candidate.len and dominator_status.does_match_continuation) {
        return true;
    }

    return false;
}

fn tokenMatchFromCompletion(
    grammar: ExpandedLexicalGrammar,
    completion: ConflictCompletion,
    end_offset: usize,
) TokenMatch {
    const variable = grammar.variables[completion.variable_index];
    return .{
        .variable_index = completion.variable_index,
        .len = end_offset,
        .completion_precedence = variable.completion_precedence,
        .implicit_precedence = variable.implicit_precedence,
        .kind = variable.kind,
    };
}

fn bestCompletionForAllowed(
    states: []const u32,
    grammar: ExpandedLexicalGrammar,
    allowed_tokens: TokenIndexSet,
) ?ConflictCompletion {
    var completion: ?ConflictCompletion = null;
    for (states) |state_id| {
        switch (grammar.nfa.states.items[state_id]) {
            .accept => |accept| {
                if (!allowed_tokens.contains(accept.variable_index)) continue;
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
    try visited.append(allocator, .{
        .state_id = state_id,
        .offset = offset,
        .leading_separator_len = 0,
        .has_seen_non_separator = false,
    });
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

fn matchStateDetailed(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    state_id: u32,
    input: []const u8,
    offset: usize,
    leading_separator_len: usize,
    has_seen_non_separator: bool,
    visited: *std.ArrayListUnmanaged(VisitedState),
) std.mem.Allocator.Error!?MatchResult {
    for (visited.items) |entry| {
        if (entry.state_id == state_id and
            entry.offset == offset and
            entry.leading_separator_len == leading_separator_len and
            entry.has_seen_non_separator == has_seen_non_separator) return null;
    }
    try visited.append(allocator, .{
        .state_id = state_id,
        .offset = offset,
        .leading_separator_len = leading_separator_len,
        .has_seen_non_separator = has_seen_non_separator,
    });
    defer _ = visited.pop();

    const state = grammar.nfa.states.items[state_id];
    return switch (state) {
        .accept => .{
            .end_offset = offset,
            .leading_separator_len = leading_separator_len,
        },
        .split => |split| blk: {
            const left = try matchStateDetailed(
                allocator,
                grammar,
                split.left,
                input,
                offset,
                leading_separator_len,
                has_seen_non_separator,
                visited,
            );
            const right = try matchStateDetailed(
                allocator,
                grammar,
                split.right,
                input,
                offset,
                leading_separator_len,
                has_seen_non_separator,
                visited,
            );
            break :blk maxOptionalMatchResult(left, right);
        },
        .advance => |advance| blk: {
            const cursor = decodeNextCodepoint(input, offset) orelse break :blk null;
            if (!advance.chars.contains(cursor.codepoint)) break :blk null;

            const next_has_seen_non_separator = has_seen_non_separator or !advance.is_separator;
            const next_leading_separator_len = if (has_seen_non_separator or !advance.is_separator)
                leading_separator_len
            else
                leading_separator_len + cursor.byte_len;

            break :blk try matchStateDetailed(
                allocator,
                grammar,
                advance.state_id,
                input,
                offset + cursor.byte_len,
                next_leading_separator_len,
                next_has_seen_non_separator,
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

fn maxOptionalMatchResult(left: ?MatchResult, right: ?MatchResult) ?MatchResult {
    if (left == null) return right;
    if (right == null) return left;
    if (left.?.end_offset != right.?.end_offset) {
        return if (left.?.end_offset > right.?.end_offset) left else right;
    }
    if (left.?.leading_separator_len != right.?.leading_separator_len) {
        return if (left.?.leading_separator_len < right.?.leading_separator_len) left else right;
    }
    return left;
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
    owner_by_state: []const usize,
    left_index: usize,
    right_index: usize,
    left_following_chars: CharacterSet,
    right_following_chars: CharacterSet,
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

        const live_owner = singleLiveOwner(owner_by_state, pair_state.left, pair_state.right);
        if (live_owner) |owner| {
            if (owner == left_index) {
                result[0].matches_different_string = true;
            } else if (owner == right_index) {
                result[1].matches_different_string = true;
            }
            continue;
        }

        const left_completion = firstCompletion(pair_state.left, grammar);
        const right_completion = firstCompletion(pair_state.right, grammar);
        const left_transitions = try collectTransitionsAlloc(allocator, grammar, pair_state.left);
        defer freeTransitions(allocator, left_transitions.transitions);
        const right_transitions = try collectTransitionsAlloc(allocator, grammar, pair_state.right);
        defer freeTransitions(allocator, right_transitions.transitions);
        const within_separator = left_transitions.has_separator_transitions or right_transitions.has_separator_transitions;

        if (left_completion != null and within_separator) result[0].does_match_separators = true;
        if (right_completion != null and within_separator) result[1].does_match_separators = true;

        if (left_completion != null and right_completion != null) {
            const preferred_left = preferCompletedToken(grammar, left_completion.?, right_completion.?);
            if (preferred_left) {
                result[0].matches_same_string = true;
            } else {
                result[1].matches_same_string = true;
            }
        }

        if (left_transitions.transitions.len == 0 and right_transitions.transitions.len == 0) continue;

        var left_overlap = false;
        var right_overlap = false;
        for (left_transitions.transitions) |left_transition| {
            for (right_transitions.transitions) |right_transition| {
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

        if (!left_overlap and left_transitions.transitions.len != 0) result[0].matches_different_string = true;
        if (!right_overlap and right_transitions.transitions.len != 0) result[1].matches_different_string = true;

        if (left_completion) |completion| {
            for (right_transitions.transitions) |transition| {
                const successor_contains_completed = transitionCanReachVariable(
                    allocator,
                    grammar,
                    transition.target_state,
                    completion.variable_index,
                ) catch false;
                if (successor_contains_completed) continue;
                if (preferAdvanceOverCompletion(
                    grammar,
                    completion,
                    transition,
                    successor_contains_completed,
                    right_transitions.has_separator_transitions,
                )) {
                    result[1].does_match_continuation = true;
                    if (characterSetsIntersect(transition.chars, left_following_chars)) {
                        result[1].does_match_valid_continuation = true;
                    }
                } else {
                    result[0].matches_prefix = true;
                }
            }
        }
        if (right_completion) |completion| {
            for (left_transitions.transitions) |transition| {
                const successor_contains_completed = transitionCanReachVariable(
                    allocator,
                    grammar,
                    transition.target_state,
                    completion.variable_index,
                ) catch false;
                if (successor_contains_completed) continue;
                if (preferAdvanceOverCompletion(
                    grammar,
                    completion,
                    transition,
                    successor_contains_completed,
                    left_transitions.has_separator_transitions,
                )) {
                    result[0].does_match_continuation = true;
                    if (characterSetsIntersect(transition.chars, right_following_chars)) {
                        result[0].does_match_valid_continuation = true;
                    }
                } else {
                    result[1].matches_prefix = true;
                }
            }
        }
    }

    return result;
}

fn computeStateOwnersAlloc(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
) std.mem.Allocator.Error![]usize {
    const unset = std.math.maxInt(usize);
    const owners = try allocator.alloc(usize, grammar.nfa.states.items.len);
    @memset(owners, unset);

    for (grammar.variables, 0..) |variable, variable_index| {
        var stack = std.ArrayListUnmanaged(u32).empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, variable.start_state);
        while (stack.items.len != 0) {
            const state_id = stack.pop().?;
            const owner = &owners[state_id];
            if (owner.* != unset) {
                std.debug.assert(owner.* == variable_index);
                continue;
            }
            owner.* = variable_index;
            switch (grammar.nfa.states.items[state_id]) {
                .split => |split| {
                    try stack.append(allocator, split.left);
                    try stack.append(allocator, split.right);
                },
                .advance => |advance| try stack.append(allocator, advance.state_id),
                .accept => {},
            }
        }
    }

    return owners;
}

fn singleLiveOwner(owner_by_state: []const usize, left: []const u32, right: []const u32) ?usize {
    var owner: ?usize = null;
    for (left) |state_id| {
        const current = owner_by_state[state_id];
        if (owner == null) {
            owner = current;
        } else if (owner.? != current) {
            return null;
        }
    }
    for (right) |state_id| {
        const current = owner_by_state[state_id];
        if (owner == null) {
            owner = current;
        } else if (owner.? != current) {
            return null;
        }
    }
    return owner;
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
) std.mem.Allocator.Error!TransitionCollection {
    var transitions = std.ArrayListUnmanaged(AdvanceTransition).empty;
    errdefer {
        for (transitions.items) |*transition| transition.chars.deinit(allocator);
        transitions.deinit(allocator);
    }
    var has_separator_transitions = false;

    for (states) |state_id| {
        switch (grammar.nfa.states.items[state_id]) {
            .advance => |advance| {
                if (advance.is_separator) has_separator_transitions = true;
                try transitions.append(allocator, .{
                    .chars = try cloneCharacterSet(allocator, advance.chars),
                    .target_state = advance.state_id,
                    .is_separator = advance.is_separator,
                    .precedence = advance.precedence,
                });
            },
            else => {},
        }
    }

    return .{
        .transitions = try transitions.toOwnedSlice(allocator),
        .has_separator_transitions = has_separator_transitions,
    };
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

fn transitionCanReachVariable(
    allocator: std.mem.Allocator,
    grammar: ExpandedLexicalGrammar,
    target_state: u32,
    variable_index: usize,
) std.mem.Allocator.Error!bool {
    const closure = try epsilonClosureAlloc(allocator, grammar, &.{target_state});
    defer allocator.free(closure);

    for (closure) |state_id| {
        switch (grammar.nfa.states.items[state_id]) {
            .accept => |accept| if (accept.variable_index == variable_index) return true,
            else => {},
        }
    }
    return false;
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
    successor_contains_completed: bool,
    has_separator_transitions: bool,
) bool {
    if (transition.precedence != completion.precedence) {
        return transition.precedence > completion.precedence;
    }
    if (transition.is_separator) return false;
    if (successor_contains_completed) return true;
    if (has_separator_transitions) return false;
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

test "selectBestTokenDetailed reports leading separator prefix separately" {
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

    const match = (try selectBestTokenDetailed(std.testing.allocator, expanded, "  let")).?;
    try std.testing.expectEqual(@as(usize, 5), match.len);
    try std.testing.expectEqual(@as(usize, 2), match.leading_separator_len);
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

test "selectBestTokenForSet matches through combined valid-token traversal" {
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

    var both = try TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len);
    defer both.deinit(std.testing.allocator);
    both.insert(0);
    both.insert(1);

    const keyword = (try selectBestTokenForSet(std.testing.allocator, expanded, both, "let x")).?;
    try std.testing.expectEqual(@as(usize, 1), keyword.variable_index);
    try std.testing.expectEqual(@as(usize, 3), keyword.len);

    var identifier_only = try TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len);
    defer identifier_only.deinit(std.testing.allocator);
    identifier_only.insert(0);

    const identifier = (try selectBestTokenForSet(std.testing.allocator, expanded, identifier_only, "let x")).?;
    try std.testing.expectEqual(@as(usize, 0), identifier.variable_index);
    try std.testing.expectEqual(@as(usize, 3), identifier.len);
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

test "expandExtractedLexicalGrammar supports optional regex atoms" {
    const all_rules = [_]rules.Rule{
        .{ .pattern = .{ .value = "\\r?\\n", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "line_end", .kind = .anonymous, .rule = 0 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, 1), try matchVariable(std.testing.allocator, expanded, 0, "\n"));
    try std.testing.expectEqual(@as(?usize, 2), try matchVariable(std.testing.allocator, expanded, 0, "\r\n"));
}

test "expandExtractedLexicalGrammar supports C grammar regex forms" {
    const all_rules = [_]rules.Rule{
        .{ .pattern = .{ .value = "#[ \t]*define", .flags = null } },
        .{ .pattern = .{ .value = "#[ \\t]*[a-zA-Z0-9]\\w*", .flags = null } },
        .{ .pattern = .{ .value = "[^\\\\\"\\n]+", .flags = null } },
        .{ .pattern = .{ .value = "x[0-9a-fA-F]{1,4}", .flags = null } },
        .{ .pattern = .{ .value = "\\d{2,3}", .flags = null } },
        .{ .pattern = .{ .value = "x[0-9a-fA-F]{2,}", .flags = null } },
        .{ .pattern = .{ .value = "(\\\\+(.|\\r?\\n)|[^\\\\\\n])*", .flags = null } },
        .{ .pattern = .{ .value = "[^*]*\\*+([^/*][^*]*\\*+)*", .flags = null } },
        .{ .pattern = .{
            .value = "(\\p{XID_Start}|\\$|_|\\\\u[0-9A-Fa-f]{4}|\\\\U[0-9A-Fa-f]{8})(\\p{XID_Continue}|\\$|\\\\u[0-9A-Fa-f]{4}|\\\\U[0-9A-Fa-f]{8})*",
            .flags = null,
        } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "preproc", .kind = .anonymous, .rule = 0 },
            .{ .name = "directive", .kind = .anonymous, .rule = 1 },
            .{ .name = "string_content", .kind = .anonymous, .rule = 2 },
            .{ .name = "hex_escape", .kind = .anonymous, .rule = 3 },
            .{ .name = "digits", .kind = .anonymous, .rule = 4 },
            .{ .name = "open_hex_escape", .kind = .anonymous, .rule = 5 },
            .{ .name = "escaped_string", .kind = .anonymous, .rule = 6 },
            .{ .name = "block_comment_tail", .kind = .anonymous, .rule = 7 },
            .{ .name = "identifier", .kind = .named, .rule = 8 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, 8), try matchVariable(std.testing.allocator, expanded, 0, "# define"));
    try std.testing.expectEqual(@as(?usize, 10), try matchVariable(std.testing.allocator, expanded, 1, "# pragma42"));
    try std.testing.expectEqual(@as(?usize, 4), try matchVariable(std.testing.allocator, expanded, 3, "x1afz"));
    try std.testing.expectEqual(@as(?usize, 3), try matchVariable(std.testing.allocator, expanded, 4, "1234"));
    try std.testing.expectEqual(@as(?usize, null), try matchVariable(std.testing.allocator, expanded, 5, "x1"));
    try std.testing.expectEqual(@as(?usize, 5), try matchVariable(std.testing.allocator, expanded, 5, "x1234z"));
    try std.testing.expectEqual(@as(?usize, 5), try matchVariable(std.testing.allocator, expanded, 8, "alpha+"));
    try std.testing.expectEqual(@as(?usize, 6), try matchVariable(std.testing.allocator, expanded, 8, "\\u1234+"));
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
    try std.testing.expect(conflict_map.status(1, 0).does_match_valid_continuation);
}

test "buildTokenConflictMapWithFollowingTokensAlloc derives following chars from token sets" {
    const all_rules = [_]rules.Rule{
        .{ .string = "let" },
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
        .{ .string = "(" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "keyword", .kind = .named, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
            .{ .name = "lparen", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var following_tokens = [_]TokenIndexSet{
        try TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len),
        try TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len),
        try TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len),
    };
    defer {
        for (&following_tokens) |*set| set.deinit(std.testing.allocator);
    }

    following_tokens[0].insert(1);
    following_tokens[1].insert(2);
    following_tokens[2].insert(0);

    var conflict_map = try buildTokenConflictMapWithFollowingTokensAlloc(
        std.testing.allocator,
        expanded,
        &following_tokens,
    );
    defer conflict_map.deinit(std.testing.allocator);

    try std.testing.expect(conflict_map.following_tokens_by_index[0].contains(1));
    try std.testing.expect(!conflict_map.following_tokens_by_index[0].contains(2));
    try std.testing.expect(conflict_map.following_chars_by_index[0].contains('l'));
    try std.testing.expect(!conflict_map.following_chars_by_index[0].contains('('));
    try std.testing.expect(conflict_map.following_chars_by_index[1].contains('('));
    try std.testing.expect(!conflict_map.following_chars_by_index[1].contains('l'));
    try std.testing.expect(conflict_map.following_chars_by_index[2].contains('l'));
}

test "buildTokenConflictMapAlloc marks separator-sensitive conflicts" {
    const all_rules = [_]rules.Rule{
        .{ .string = "let" },
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
        .{ .pattern = .{ .value = "[ ]+", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "keyword", .kind = .named, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
        },
        .separators = &.{2},
    };

    var expanded = try expandExtractedLexicalGrammar(std.testing.allocator, all_rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var conflict_map = try buildTokenConflictMapAlloc(std.testing.allocator, expanded);
    defer conflict_map.deinit(std.testing.allocator);

    try std.testing.expect(conflict_map.status(1, 0).does_match_separators);
}

test "computeFollowingTokensAlloc derives grammar-based token follow sets" {
    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var lhs_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    var rhs_token_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };
    var rhs_tail_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 3 } },
    };
    var tail_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 2 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{
                    .{
                        .steps = source_steps[0..],
                    },
                },
            },
            .{
                .name = "lhs",
                .kind = .named,
                .productions = &.{
                    .{
                        .steps = lhs_steps[0..],
                    },
                },
            },
            .{
                .name = "rhs",
                .kind = .named,
                .productions = &.{
                    .{
                        .steps = rhs_token_steps[0..],
                    },
                    .{
                        .steps = rhs_tail_steps[0..],
                    },
                },
            },
            .{
                .name = "tail",
                .kind = .named,
                .productions = &.{
                    .{
                        .steps = tail_steps[0..],
                    },
                },
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const following = try computeFollowingTokensAlloc(std.testing.allocator, grammar, 3);
    defer deinitTokenIndexSets(std.testing.allocator, following);

    try std.testing.expect(following[0].contains(1));
    try std.testing.expect(following[0].contains(2));
    try std.testing.expect(!following[1].contains(0));
    try std.testing.expect(!following[1].contains(2));
    try std.testing.expect(!following[2].contains(0));
    try std.testing.expect(!following[2].contains(1));
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

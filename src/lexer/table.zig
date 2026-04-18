const std = @import("std");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const lexer_model = @import("model.zig");

pub const LexTransition = struct {
    chars: lexer_model.CharacterSet,
    next_state_id: usize,
    is_separator: bool,
    precedence: i32,
};

pub const LexState = struct {
    nfa_states: []const u32,
    completion: ?ConflictCompletion,
    transitions: []LexTransition,
    has_separator_transitions: bool,
};

pub const LexTable = struct {
    allocator: std.mem.Allocator,
    grammar: lexer_model.ExpandedLexicalGrammar,
    allowed_tokens: lexer_model.TokenIndexSet,
    start_state_id: usize,
    states: []LexState,

    pub fn deinit(self: *LexTable) void {
        for (self.states) |*state| {
            self.allocator.free(state.nfa_states);
            for (state.transitions) |*transition| transition.chars.deinit(self.allocator);
            self.allocator.free(state.transitions);
        }
        self.allocator.free(self.states);
        self.* = undefined;
    }

    pub fn selectBestToken(self: LexTable, input: []const u8) !?lexer_model.TokenMatch {
        return self.bestToken(self.start_state_id, input, 0);
    }

    fn stateContainsCompletion(self: LexTable, state_id: usize, variable_index: usize) bool {
        for (self.states[state_id].nfa_states) |nfa_state_id| {
            switch (self.grammar.nfa.states.items[nfa_state_id]) {
                .accept => |accept| if (accept.variable_index == variable_index) return true,
                else => {},
            }
        }
        return false;
    }

    fn bestToken(self: LexTable, state_id: usize, input: []const u8, offset: usize) !?lexer_model.TokenMatch {
        const state = self.states[state_id];
        const completion_match: ?lexer_model.TokenMatch = if (state.completion) |value|
            tokenMatchFromCompletion(self.grammar, value, offset)
        else
            null;

        const cursor = decodeNextCodepoint(input, offset) orelse return completion_match;

        var best_continuation: ?lexer_model.TokenMatch = null;
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

pub fn buildLexTableForSet(
    allocator: std.mem.Allocator,
    grammar: lexer_model.ExpandedLexicalGrammar,
    allowed_tokens: lexer_model.TokenIndexSet,
) !LexTable {
    var start_states = std.ArrayListUnmanaged(u32).empty;
    defer start_states.deinit(allocator);

    for (grammar.variables, 0..) |variable, index| {
        if (!allowed_tokens.contains(index)) continue;
        try start_states.append(allocator, variable.start_state);
    }
    if (start_states.items.len == 0) {
        return .{
            .allocator = allocator,
            .grammar = grammar,
            .allowed_tokens = allowed_tokens,
            .start_state_id = 0,
            .states = try allocator.alloc(LexState, 0),
        };
    }

    const closure = try epsilonClosureAlloc(allocator, grammar, start_states.items);
    defer allocator.free(closure);

    var builder = LexTableBuilder{
        .allocator = allocator,
        .grammar = grammar,
        .allowed_tokens = allowed_tokens,
    };
    errdefer builder.deinit();

    const start_state_id = try builder.internState(closure);
    return .{
        .allocator = allocator,
        .grammar = grammar,
        .allowed_tokens = allowed_tokens,
        .start_state_id = start_state_id,
        .states = try builder.states.toOwnedSlice(allocator),
    };
}

pub fn selectBestTokenForSet(
    allocator: std.mem.Allocator,
    grammar: lexer_model.ExpandedLexicalGrammar,
    allowed_tokens: lexer_model.TokenIndexSet,
    input: []const u8,
) !?lexer_model.TokenMatch {
    var table = try buildLexTableForSet(allocator, grammar, allowed_tokens);
    defer table.deinit();
    if (table.states.len == 0) return null;
    return table.selectBestToken(input);
}

const MatchCursor = struct {
    codepoint: u21,
    byte_len: usize,
};

const AdvanceTransition = struct {
    chars: lexer_model.CharacterSet,
    target_state: u32,
    is_separator: bool,
    precedence: i32,
};

const TransitionCollection = struct {
    transitions: []AdvanceTransition,
    has_separator_transitions: bool,
};

const ConflictCompletion = struct {
    variable_index: usize,
    precedence: i32,
};

const LexTableBuilder = struct {
    allocator: std.mem.Allocator,
    grammar: lexer_model.ExpandedLexicalGrammar,
    allowed_tokens: lexer_model.TokenIndexSet,
    states: std.ArrayListUnmanaged(LexState) = .empty,

    fn deinit(self: *LexTableBuilder) void {
        for (self.states.items) |*state| {
            self.allocator.free(state.nfa_states);
            for (state.transitions) |*transition| transition.chars.deinit(self.allocator);
            self.allocator.free(state.transitions);
        }
        self.states.deinit(self.allocator);
        self.* = undefined;
    }

    fn internState(self: *LexTableBuilder, nfa_states: []const u32) !usize {
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

        var transitions = try self.allocator.alloc(LexTransition, transition_collection.transitions.len);
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
};

fn tokenMatchLessThan(current: lexer_model.TokenMatch, candidate: lexer_model.TokenMatch) bool {
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

fn tokenMatchFromCompletion(
    grammar: lexer_model.ExpandedLexicalGrammar,
    completion: ConflictCompletion,
    end_offset: usize,
) lexer_model.TokenMatch {
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
    grammar: lexer_model.ExpandedLexicalGrammar,
    allowed_tokens: lexer_model.TokenIndexSet,
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

fn preferCompletedToken(
    grammar: lexer_model.ExpandedLexicalGrammar,
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

fn epsilonClosureAlloc(
    allocator: std.mem.Allocator,
    grammar: lexer_model.ExpandedLexicalGrammar,
    seeds: []const u32,
) ![]u32 {
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
    grammar: lexer_model.ExpandedLexicalGrammar,
    states: []const u32,
) !TransitionCollection {
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

fn preferAdvanceOverCompletion(
    grammar: lexer_model.ExpandedLexicalGrammar,
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

fn cloneCharacterSet(
    allocator: std.mem.Allocator,
    chars: lexer_model.CharacterSet,
) !lexer_model.CharacterSet {
    var result = lexer_model.CharacterSet.empty();
    try result.addSet(allocator, chars);
    return result;
}

test "buildLexTableForSet interns reusable lexer states" {
    const rules = [_]@import("../ir/rules.zig").Rule{
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

    var expanded = try lexer_model.expandExtractedLexicalGrammar(std.testing.allocator, rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var allowed = try lexer_model.TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len);
    defer allowed.deinit(std.testing.allocator);
    allowed.fill();

    var table = try buildLexTableForSet(std.testing.allocator, expanded, allowed);
    defer table.deinit();

    try std.testing.expect(table.states.len != 0);
    try std.testing.expect(table.start_state_id < table.states.len);
    const best = (try table.selectBestToken("let x")).?;
    try std.testing.expectEqual(@as(usize, 1), best.variable_index);
}

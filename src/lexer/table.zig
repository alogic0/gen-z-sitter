const std = @import("std");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const lexer_model = @import("model.zig");
const runtime_io = @import("../support/runtime_io.zig");

fn profileTimer(enabled: bool) ?std.Io.Timestamp {
    if (!enabled) return null;
    return std.Io.Timestamp.now(runtime_io.get(), .awake);
}

fn profileElapsedNs(timer: ?std.Io.Timestamp) u64 {
    const start = timer orelse return 0;
    const duration = start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake));
    return @intCast(duration.nanoseconds);
}

pub const LexTransition = struct {
    chars: lexer_model.CharacterSet,
    next_state_id: usize,
    is_separator: bool,
    precedence: i32,
};

pub const LexState = struct {
    nfa_states: []const u32,
    completion: ?ConflictCompletion,
    eof_valid: bool,
    eof_target: ?usize,
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
        if (self.states.len == 0) return null;
        return self.bestToken(self.start_state_id, input, 0);
    }

    pub fn selectBestTokenDetailed(self: LexTable, input: []const u8) !?lexer_model.DetailedTokenMatch {
        if (self.states.len == 0) return null;
        return self.bestTokenDetailed(self.start_state_id, input, 0, 0, false);
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

    fn bestTokenDetailed(
        self: LexTable,
        state_id: usize,
        input: []const u8,
        offset: usize,
        leading_separator_len: usize,
        has_seen_non_separator: bool,
    ) !?lexer_model.DetailedTokenMatch {
        const state = self.states[state_id];
        const completion_match: ?lexer_model.DetailedTokenMatch = if (state.completion) |value|
            detailedTokenMatchFromCompletion(self.grammar, value, offset, leading_separator_len)
        else
            null;

        const cursor = decodeNextCodepoint(input, offset) orelse return completion_match;

        var best_continuation: ?lexer_model.DetailedTokenMatch = null;
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

            const next_has_seen_non_separator = has_seen_non_separator or !transition.is_separator;
            const next_leading_separator_len = if (has_seen_non_separator or !transition.is_separator)
                leading_separator_len
            else
                leading_separator_len + cursor.byte_len;

            const candidate = try self.bestTokenDetailed(
                transition.next_state_id,
                input,
                offset + cursor.byte_len,
                next_leading_separator_len,
                next_has_seen_non_separator,
            ) orelse continue;

            if (best_continuation == null or detailedTokenMatchLessThan(best_continuation.?, candidate)) {
                best_continuation = candidate;
            }
        }

        if (completion_match == null) return best_continuation;
        if (best_continuation == null) return completion_match;
        return if (detailedTokenMatchLessThan(completion_match.?, best_continuation.?))
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
    return buildLexTableForSetWithOptions(allocator, grammar, allowed_tokens, .{});
}

pub const BuildOptions = struct {
    eof_valid: bool = false,
    profile: ?*BuildProfile = null,
};

pub const BuildProfile = struct {
    start_closure_ns: u64 = 0,
    construct_ns: u64 = 0,
    minimize_ns: u64 = 0,
    sort_ns: u64 = 0,
    intern_calls: usize = 0,
    intern_reused: usize = 0,
    intern_new: usize = 0,
    next_closure_calls: usize = 0,
    next_closure_ns: u64 = 0,
};

pub fn buildLexTableForSetWithOptions(
    allocator: std.mem.Allocator,
    grammar: lexer_model.ExpandedLexicalGrammar,
    allowed_tokens: lexer_model.TokenIndexSet,
    options: BuildOptions,
) !LexTable {
    var start_states = std.ArrayListUnmanaged(u32).empty;
    defer start_states.deinit(allocator);

    for (grammar.variables, 0..) |variable, index| {
        if (!allowed_tokens.contains(index)) continue;
        try start_states.append(allocator, variable.start_state);
    }
    if (start_states.items.len == 0 and !options.eof_valid) {
        return .{
            .allocator = allocator,
            .grammar = grammar,
            .allowed_tokens = allowed_tokens,
            .start_state_id = 0,
            .states = try allocator.alloc(LexState, 0),
        };
    }

    const start_closure_timer = profileTimer(options.profile != null);
    const closure = try epsilonClosureAlloc(allocator, grammar, start_states.items);
    if (options.profile) |profile| profile.start_closure_ns += profileElapsedNs(start_closure_timer);
    defer allocator.free(closure);

    var builder = LexTableBuilder{
        .allocator = allocator,
        .grammar = grammar,
        .allowed_tokens = allowed_tokens,
        .profile = options.profile,
    };
    errdefer builder.deinit();

    const construct_timer = profileTimer(options.profile != null);
    const start_state_id = try builder.internState(closure, options.eof_valid);
    var table: LexTable = .{
        .allocator = allocator,
        .grammar = grammar,
        .allowed_tokens = allowed_tokens,
        .start_state_id = start_state_id,
        .states = try builder.states.toOwnedSlice(allocator),
    };
    if (options.profile) |profile| profile.construct_ns += profileElapsedNs(construct_timer);
    const minimize_timer = profileTimer(options.profile != null);
    try minimizeLexTable(&table);
    if (options.profile) |profile| profile.minimize_ns += profileElapsedNs(minimize_timer);
    const sort_timer = profileTimer(options.profile != null);
    try sortLexTable(&table);
    if (options.profile) |profile| profile.sort_ns += profileElapsedNs(sort_timer);
    return table;
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
    profile: ?*BuildProfile = null,
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

    fn internState(self: *LexTableBuilder, nfa_states: []const u32, eof_valid: bool) !usize {
        if (self.profile) |profile| profile.intern_calls += 1;
        for (self.states.items, 0..) |state, index| {
            if (state.eof_valid != eof_valid) continue;
            if (std.mem.eql(u32, state.nfa_states, nfa_states)) {
                if (self.profile) |profile| profile.intern_reused += 1;
                return index;
            }
        }
        if (self.profile) |profile| profile.intern_new += 1;

        const owned_states = try self.allocator.dupe(u32, nfa_states);
        errdefer self.allocator.free(owned_states);

        const completion = bestCompletionForAllowed(owned_states, self.grammar, self.allowed_tokens);
        try self.states.append(self.allocator, .{
            .nfa_states = owned_states,
            .completion = completion,
            .eof_valid = eof_valid,
            .eof_target = null,
            .transitions = &.{},
            .has_separator_transitions = false,
        });
        const state_id = self.states.items.len - 1;

        if (eof_valid) {
            self.states.items[state_id].eof_target = try self.internState(&.{}, false);
        }

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
            const next_closure_timer = profileTimer(self.profile != null);
            const next_states = try epsilonClosureAlloc(self.allocator, self.grammar, &.{transition.target_state});
            if (self.profile) |profile| {
                profile.next_closure_calls += 1;
                profile.next_closure_ns += profileElapsedNs(next_closure_timer);
            }
            defer self.allocator.free(next_states);
            const next_state_id = try self.internState(next_states, eof_valid and transition.is_separator);
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

fn detailedTokenMatchFromCompletion(
    grammar: lexer_model.ExpandedLexicalGrammar,
    completion: ConflictCompletion,
    end_offset: usize,
    leading_separator_len: usize,
) lexer_model.DetailedTokenMatch {
    const variable = grammar.variables[completion.variable_index];
    return .{
        .variable_index = completion.variable_index,
        .len = end_offset,
        .leading_separator_len = leading_separator_len,
        .completion_precedence = variable.completion_precedence,
        .implicit_precedence = variable.implicit_precedence,
        .kind = variable.kind,
    };
}

fn detailedTokenMatchLessThan(
    current: lexer_model.DetailedTokenMatch,
    candidate: lexer_model.DetailedTokenMatch,
) bool {
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

fn minimizeLexTable(table: *LexTable) !void {
    if (table.states.len <= 1) return;

    const group_ids = try table.allocator.alloc(usize, table.states.len);
    defer table.allocator.free(group_ids);
    @memset(group_ids, 0);
    const new_group_ids = try table.allocator.alloc(usize, table.states.len);
    defer table.allocator.free(new_group_ids);
    const signatures = try table.allocator.alloc(u64, table.states.len);
    defer table.allocator.free(signatures);
    var changed = true;

    while (changed) {
        changed = false;
        var next_group_id: usize = 0;
        for (table.states, 0..) |_, index| {
            signatures[index] = lexStateSignature(table.*, index, group_ids);
        }

        var state_index: usize = 0;
        while (state_index < table.states.len) : (state_index += 1) {
            var matched_group: ?usize = null;
            var prior_index: usize = 0;
            while (prior_index < state_index) : (prior_index += 1) {
                if (signatures[prior_index] != signatures[state_index]) continue;
                if (lexStatesEquivalent(table, state_index, prior_index, group_ids)) {
                    matched_group = new_group_ids[prior_index];
                    break;
                }
            }
            if (matched_group) |group_id| {
                new_group_ids[state_index] = group_id;
            } else {
                new_group_ids[state_index] = next_group_id;
                next_group_id += 1;
            }
        }

        if (!std.mem.eql(usize, group_ids, new_group_ids)) {
            @memcpy(group_ids, new_group_ids);
            changed = true;
        }
    }

    const new_state_count = countDistinctGroups(group_ids);
    if (new_state_count == table.states.len) return;

    const old_states = table.states;
    const new_states = try table.allocator.alloc(LexState, new_state_count);

    var representative_by_group = try table.allocator.alloc(usize, new_state_count);
    defer table.allocator.free(representative_by_group);
    @memset(representative_by_group, std.math.maxInt(usize));

    for (group_ids, 0..) |group_id, state_index| {
        if (representative_by_group[group_id] == std.math.maxInt(usize)) {
            representative_by_group[group_id] = state_index;
        }
    }

    for (0..new_state_count) |group_id| {
        const rep = representative_by_group[group_id];
        new_states[group_id] = old_states[rep];
        if (new_states[group_id].eof_target) |target| {
            new_states[group_id].eof_target = group_ids[target];
        }
        for (new_states[group_id].transitions) |*transition| {
            transition.next_state_id = group_ids[transition.next_state_id];
        }
    }

    table.start_state_id = group_ids[table.start_state_id];
    table.allocator.free(old_states);
    table.states = new_states;
}

fn lexStateSignature(table: LexTable, state_id: usize, group_ids: []const usize) u64 {
    const state = table.states[state_id];
    var hasher = std.hash.Wyhash.init(0);
    const is_start = state_id == table.start_state_id;
    hasher.update(std.mem.asBytes(&is_start));
    hashConflictCompletion(&hasher, state.completion);
    hasher.update(std.mem.asBytes(&state.eof_valid));
    hasher.update(std.mem.asBytes(&state.has_separator_transitions));
    const eof_group = if (state.eof_target) |target| group_ids[target] else std.math.maxInt(usize);
    hasher.update(std.mem.asBytes(&eof_group));
    hasher.update(std.mem.asBytes(&state.transitions.len));
    for (state.transitions) |transition| {
        const target_group = group_ids[transition.next_state_id];
        hasher.update(std.mem.asBytes(&target_group));
        hasher.update(std.mem.asBytes(&transition.is_separator));
        hasher.update(std.mem.asBytes(&transition.precedence));
        hashCharacterSet(&hasher, transition.chars);
    }
    return hasher.final();
}

fn hashConflictCompletion(hasher: *std.hash.Wyhash, completion: ?ConflictCompletion) void {
    const has_completion = completion != null;
    hasher.update(std.mem.asBytes(&has_completion));
    if (completion) |value| {
        hasher.update(std.mem.asBytes(&value.variable_index));
        hasher.update(std.mem.asBytes(&value.precedence));
    }
}

fn hashCharacterSet(hasher: *std.hash.Wyhash, value: lexer_model.CharacterSet) void {
    hasher.update(std.mem.asBytes(&value.ranges.items.len));
    for (value.ranges.items) |range| {
        hasher.update(std.mem.asBytes(&range.start));
        hasher.update(std.mem.asBytes(&range.end));
    }
}

fn sortLexTable(table: *LexTable) !void {
    if (table.states.len <= 1) return;

    const order = try table.allocator.alloc(usize, table.states.len);
    defer table.allocator.free(order);
    for (0..table.states.len) |index| order[index] = index;

    const start_id = table.start_state_id;
    std.mem.sort(usize, order, SortContext{ .table = table.*, .start_state_id = start_id }, lessThanStateId);

    const remap = try table.allocator.alloc(usize, table.states.len);
    defer table.allocator.free(remap);
    for (order, 0..) |old_id, new_id| remap[old_id] = new_id;

    const old_states = table.states;
    const new_states = try table.allocator.alloc(LexState, table.states.len);
    for (order, 0..) |old_id, new_id| {
        new_states[new_id] = old_states[old_id];
        if (new_states[new_id].eof_target) |target| {
            new_states[new_id].eof_target = remap[target];
        }
        for (new_states[new_id].transitions) |*transition| {
            transition.next_state_id = remap[transition.next_state_id];
        }
    }

    table.start_state_id = remap[start_id];
    table.allocator.free(old_states);
    table.states = new_states;
}

const SortContext = struct {
    table: LexTable,
    start_state_id: usize,
};

fn lessThanStateId(context: SortContext, left_id: usize, right_id: usize) bool {
    if (left_id == context.start_state_id) return right_id != context.start_state_id;
    if (right_id == context.start_state_id) return false;
    return lexStateLessThan(context.table.states[left_id], context.table.states[right_id]);
}

fn lexStatesEquivalent(table: *const LexTable, left_id: usize, right_id: usize, group_ids: []const usize) bool {
    const left = table.states[left_id];
    const right = table.states[right_id];
    if ((left_id == table.start_state_id) != (right_id == table.start_state_id)) return false;
    if (!conflictCompletionEql(left.completion, right.completion)) return false;
    if (left.eof_valid != right.eof_valid) return false;
    if (left.has_separator_transitions != right.has_separator_transitions) return false;
    if (left.transitions.len != right.transitions.len) return false;
    for (left.transitions, right.transitions) |left_transition, right_transition| {
        if (group_ids[left_transition.next_state_id] != group_ids[right_transition.next_state_id]) return false;
        if (left_transition.is_separator != right_transition.is_separator) return false;
        if (left_transition.precedence != right_transition.precedence) return false;
        if (!characterSetEql(left_transition.chars, right_transition.chars)) return false;
    }
    if (left.eof_target == null or right.eof_target == null) return left.eof_target == null and right.eof_target == null;
    if (group_ids[left.eof_target.?] != group_ids[right.eof_target.?]) return false;
    return true;
}

fn lexStateLessThan(left: LexState, right: LexState) bool {
    if (!conflictCompletionEql(left.completion, right.completion)) {
        return conflictCompletionLessThan(left.completion, right.completion);
    }
    if (left.eof_valid != right.eof_valid) return !left.eof_valid and right.eof_valid;
    if (left.eof_target != right.eof_target) {
        if (left.eof_target == null) return true;
        if (right.eof_target == null) return false;
        return left.eof_target.? < right.eof_target.?;
    }
    if (left.has_separator_transitions != right.has_separator_transitions) {
        return !left.has_separator_transitions and right.has_separator_transitions;
    }
    if (left.transitions.len != right.transitions.len) return left.transitions.len < right.transitions.len;
    for (left.transitions, right.transitions) |left_transition, right_transition| {
        if (!characterSetEql(left_transition.chars, right_transition.chars)) {
            return characterSetLessThan(left_transition.chars, right_transition.chars);
        }
        if (left_transition.is_separator != right_transition.is_separator) {
            return !left_transition.is_separator and right_transition.is_separator;
        }
        if (left_transition.precedence != right_transition.precedence) {
            return left_transition.precedence < right_transition.precedence;
        }
        if (left_transition.next_state_id != right_transition.next_state_id) {
            return left_transition.next_state_id < right_transition.next_state_id;
        }
    }
    return false;
}

fn conflictCompletionEql(left: ?ConflictCompletion, right: ?ConflictCompletion) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.variable_index == right.?.variable_index and left.?.precedence == right.?.precedence;
}

fn conflictCompletionLessThan(left: ?ConflictCompletion, right: ?ConflictCompletion) bool {
    if (left == null) return right != null;
    if (right == null) return false;
    if (left.?.variable_index != right.?.variable_index) return left.?.variable_index < right.?.variable_index;
    return left.?.precedence < right.?.precedence;
}

fn characterSetEql(left: lexer_model.CharacterSet, right: lexer_model.CharacterSet) bool {
    if (left.ranges.items.len != right.ranges.items.len) return false;
    for (left.ranges.items, right.ranges.items) |left_range, right_range| {
        if (left_range.start != right_range.start or left_range.end != right_range.end) return false;
    }
    return true;
}

fn characterSetLessThan(left: lexer_model.CharacterSet, right: lexer_model.CharacterSet) bool {
    const len = @min(left.ranges.items.len, right.ranges.items.len);
    for (0..len) |index| {
        const left_range = left.ranges.items[index];
        const right_range = right.ranges.items[index];
        if (left_range.start != right_range.start) return left_range.start < right_range.start;
        if (left_range.end != right_range.end) return left_range.end < right_range.end;
    }
    return left.ranges.items.len < right.ranges.items.len;
}

fn countDistinctGroups(group_ids: []const usize) usize {
    var max_group: usize = 0;
    for (group_ids, 0..) |group_id, index| {
        if (index == 0 or group_id > max_group) max_group = group_id;
    }
    return if (group_ids.len == 0) 0 else max_group + 1;
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

test "buildLexTableForSet reports leading separator prefix in detailed matches" {
    const rules = [_]@import("../ir/rules.zig").Rule{
        .{ .string = "let" },
        .{ .pattern = .{ .value = "[ ]+", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "keyword", .kind = .named, .rule = 0 },
        },
        .separators = &.{1},
    };

    var expanded = try lexer_model.expandExtractedLexicalGrammar(std.testing.allocator, rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var allowed = try lexer_model.TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len);
    defer allowed.deinit(std.testing.allocator);
    allowed.fill();

    var table = try buildLexTableForSet(std.testing.allocator, expanded, allowed);
    defer table.deinit();

    const best = (try table.selectBestTokenDetailed("  let")).?;
    try std.testing.expectEqual(@as(usize, 5), best.len);
    try std.testing.expectEqual(@as(usize, 2), best.leading_separator_len);
}

test "buildLexTableForSet sorts lexer states deterministically with start state first" {
    const rules = [_]@import("../ir/rules.zig").Rule{
        .{ .string = "a" },
        .{ .string = "b" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "a_tok", .kind = .named, .rule = 0 },
            .{ .name = "b_tok", .kind = .named, .rule = 1 },
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

    try std.testing.expectEqual(@as(usize, 3), table.states.len);
    try std.testing.expectEqual(@as(usize, 0), table.start_state_id);
    try std.testing.expectEqual(@as(usize, 2), table.states[0].transitions.len);
    try std.testing.expect(table.states[0].transitions[0].next_state_id < table.states.len);
    try std.testing.expect(table.states[0].transitions[1].next_state_id < table.states.len);
    try std.testing.expect(characterSetLessThan(
        table.states[0].transitions[0].chars,
        table.states[0].transitions[1].chars,
    ));
}

test "buildLexTableForSetWithOptions builds an EOF successor for empty valid-token sets" {
    const rules = [_]@import("../ir/rules.zig").Rule{
        .{ .string = "a" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "letter_a", .kind = .named, .rule = 0 },
        },
        .separators = &.{},
    };

    var expanded = try lexer_model.expandExtractedLexicalGrammar(std.testing.allocator, rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var allowed = try lexer_model.TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len);
    defer allowed.deinit(std.testing.allocator);

    var table = try buildLexTableForSetWithOptions(std.testing.allocator, expanded, allowed, .{ .eof_valid = true });
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.states.len);
    const start = table.states[table.start_state_id];
    try std.testing.expect(start.eof_valid);
    try std.testing.expect(start.eof_target != null);
    try std.testing.expect(!table.states[start.eof_target.?].eof_valid);
    try std.testing.expectEqual(@as(?usize, null), table.states[start.eof_target.?].eof_target);
}

test "buildLexTableForSetWithOptions propagates EOF validity across separators" {
    const rules = [_]@import("../ir/rules.zig").Rule{
        .{ .string = "a" },
        .{ .pattern = .{ .value = "[ ]+", .flags = null } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "letter_a", .kind = .named, .rule = 0 },
        },
        .separators = &.{1},
    };

    var expanded = try lexer_model.expandExtractedLexicalGrammar(std.testing.allocator, rules[0..], lexical);
    defer expanded.deinit(std.testing.allocator);

    var allowed = try lexer_model.TokenIndexSet.initEmpty(std.testing.allocator, expanded.variables.len);
    defer allowed.deinit(std.testing.allocator);
    allowed.fill();

    var table = try buildLexTableForSetWithOptions(std.testing.allocator, expanded, allowed, .{ .eof_valid = true });
    defer table.deinit();

    const start = table.states[table.start_state_id];
    var separator_target: ?usize = null;
    for (start.transitions) |transition| {
        if (transition.is_separator) {
            separator_target = transition.next_state_id;
            break;
        }
    }

    try std.testing.expect(separator_target != null);
    try std.testing.expect(table.states[separator_target.?].eof_valid);
    try std.testing.expect(table.states[separator_target.?].eof_target != null);
}

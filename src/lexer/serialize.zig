const std = @import("std");
const grammar_ir = @import("../ir/grammar_ir.zig");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const ir_rules = @import("../ir/rules.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const json_loader = @import("../grammar/json_loader.zig");
const lexer_model = @import("model.zig");
const lexer_table = @import("table.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const fixtures = @import("../tests/fixtures.zig");
const runtime_io = @import("../support/runtime_io.zig");

threadlocal var profile_env_loaded: bool = false;
threadlocal var profile_enabled: bool = false;

fn profileEnabled() bool {
    if (!profile_env_loaded) {
        const value = std.process.Environ.getAlloc(
            runtime_io.environ(),
            std.heap.page_allocator,
            "GEN_Z_SITTER_PARSE_TABLE_PROFILE",
        ) catch "";
        defer if (value.len != 0) std.heap.page_allocator.free(value);
        profile_enabled = value.len != 0 and !std.mem.eql(u8, value, "0");
        profile_env_loaded = true;
    }
    return profile_enabled;
}

fn profileTimer(enabled: bool) ?std.Io.Timestamp {
    if (!enabled) return null;
    return std.Io.Timestamp.now(runtime_io.get(), .awake);
}

fn profileElapsedNs(timer: ?std.Io.Timestamp) u64 {
    const start = timer orelse return 0;
    const duration = start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake));
    return @intCast(duration.nanoseconds);
}

/// Errors produced while serializing the extracted lexical grammar.
pub const SerializeError = std.mem.Allocator.Error || lexer_model.ExpandError;

/// Serialized form of one lexical rule.
pub const SerializedLexicalForm = union(enum) {
    string: []const u8,
    pattern: struct {
        value: []const u8,
        flags: ?[]const u8,
    },
};

/// Runtime-oriented lexical variable metadata.
pub const SerializedLexicalVariable = struct {
    name: []const u8,
    kind: lexical_ir.VariableKind,
    form: SerializedLexicalForm,
    tokenized: bool,
    immediate: bool,
    implicit_precedence: i32,
    start_state: u32,
};

/// Separator rule that the current lexer serialization boundary cannot emit.
pub const UnsupportedSeparator = struct {
    rule: ir_rules.RuleId,
};

/// External token that requires scanner support outside this boundary.
pub const UnsupportedExternalToken = struct {
    name: []const u8,
    kind: syntax_ir.VariableKind,
};

/// Lexer mode entry consumed by generated parser metadata.
pub const SerializedLexMode = struct {
    lex_state: u16,
    external_lex_state: u16 = 0,
    reserved_word_set_id: u16 = 0,
};

/// Inclusive codepoint range consumed by the generated lexer.
pub const SerializedCharacterRange = struct {
    start: u32,
    end_inclusive: u32,
};

/// One serialized lexer transition.
pub const SerializedLexTransition = struct {
    ranges: []const SerializedCharacterRange,
    next_state_id: u32,
    skip: bool,
};

/// One precomputed large character set available to lexer C emission.
pub const SerializedLargeCharacterSet = struct {
    symbol: ?syntax_ir.SymbolRef = null,
    ranges: []const SerializedCharacterRange,
};

/// One serialized lexer state.
pub const SerializedLexState = struct {
    accept_symbol: ?syntax_ir.SymbolRef = null,
    eof_target: ?u32 = null,
    transitions: []const SerializedLexTransition,
};

/// Runtime-oriented lexer table for one valid-token set.
pub const SerializedLexTable = struct {
    start_state_id: u32,
    states: []const SerializedLexState,
    large_character_sets: []const SerializedLargeCharacterSet = &.{},
    lex_state_starts: []const u16 = &.{},
};

/// Build parser-state-indexed lexer modes from serialized parse states.
pub fn buildLexModesAlloc(
    allocator: std.mem.Allocator,
    states: anytype,
) std.mem.Allocator.Error![]const SerializedLexMode {
    const modes = try allocator.alloc(SerializedLexMode, states.len);
    for (states, 0..) |parse_state, index| {
        modes[index] = .{
            .lex_state = @intCast(@min(parse_state.lex_state_id, std.math.maxInt(u16))),
        };
    }
    return modes;
}

/// Build one serialized lexer table for each assigned parser lex-state terminal set.
pub fn buildSerializedLexTablesAlloc(
    allocator: std.mem.Allocator,
    all_rules: []const ir_rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
    terminal_sets: []const []const bool,
) SerializeError![]const SerializedLexTable {
    return buildSerializedLexTablesWithEofAlloc(allocator, all_rules, lexical, terminal_sets, null);
}

/// Build one upstream-shaped main lexer table and return the remapped start
/// state for each parser lex-state terminal set.
pub fn buildSharedSerializedLexTablesAlloc(
    allocator: std.mem.Allocator,
    all_rules: []const ir_rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
    terminal_sets: []const []const bool,
) SerializeError![]const SerializedLexTable {
    return buildSharedSerializedLexTablesWithEofAlloc(allocator, all_rules, lexical, terminal_sets, null);
}

pub fn buildSharedSerializedLexTablesWithEofAlloc(
    allocator: std.mem.Allocator,
    all_rules: []const ir_rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
    terminal_sets: []const []const bool,
    eof_valids: ?[]const bool,
) SerializeError![]const SerializedLexTable {
    const profile_log = profileEnabled();
    const total_timer = profileTimer(profile_log);
    var expanded = try lexer_model.expandExtractedLexicalGrammar(allocator, all_rules, lexical);
    defer expanded.deinit(allocator);

    const allowed_sets = try allocator.alloc(lexer_model.TokenIndexSet, terminal_sets.len);
    var allowed_initialized: usize = 0;
    errdefer {
        for (allowed_sets[0..allowed_initialized]) |*set| set.deinit(allocator);
        allocator.free(allowed_sets);
    }

    var token_set_ns: u64 = 0;
    for (terminal_sets, 0..) |terminal_set, index| {
        const token_set_timer = profileTimer(profile_log);
        allowed_sets[index] = try tokenIndexSetFromTerminalSet(allocator, expanded.variables.len, terminal_set);
        token_set_ns += profileElapsedNs(token_set_timer);
        allowed_initialized += 1;
    }
    defer {
        for (allowed_sets) |*set| set.deinit(allocator);
        allocator.free(allowed_sets);
    }

    var table_profile = lexer_table.BuildProfile{};
    const build_timer = profileTimer(profile_log);
    var multi_table = try lexer_table.buildLexTableForSetsWithOptions(allocator, expanded, allowed_sets, eof_valids, .{
        .profile = if (profile_log) &table_profile else null,
    });
    defer multi_table.deinit();
    const build_table_ns = profileElapsedNs(build_timer);

    var built_transition_count: usize = 0;
    for (multi_table.table.states) |lex_state| built_transition_count += lex_state.transitions.len;

    const tables = try allocator.alloc(SerializedLexTable, 1);
    var initialized_tables: usize = 0;
    errdefer {
        deinitSerializedLexTables(allocator, tables[0..initialized_tables]);
        if (initialized_tables == 0) allocator.free(tables);
    }
    const serialize_timer = profileTimer(profile_log);
    tables[0] = try serializeLexTableAlloc(allocator, multi_table.table);
    initialized_tables = 1;
    tables[0].large_character_sets = try buildLargeCharacterSetsAlloc(allocator, expanded);
    const serialize_table_ns = profileElapsedNs(serialize_timer);

    const starts = try allocator.alloc(u16, multi_table.start_state_ids.len);
    for (multi_table.start_state_ids, 0..) |start_id, index| {
        starts[index] = @intCast(start_id);
    }
    tables[0].lex_state_starts = starts;

    if (profile_log) {
        var serialized_transition_count: usize = 0;
        var serialized_range_count: usize = 0;
        for (tables[0].states) |lex_state| {
            serialized_transition_count += lex_state.transitions.len;
            for (lex_state.transitions) |transition| serialized_range_count += transition.ranges.len;
        }
        std.debug.print(
            "[lexer_serialize_profile] shared_tables=1 lex_states={d} built_states={d} built_transitions={d} serialized_states={d} serialized_transitions={d} serialized_ranges={d} token_set_ms={d:.2} build_table_ms={d:.2} serialize_table_ms={d:.2} total_ms={d:.2}\n",
            .{
                terminal_sets.len,
                multi_table.table.states.len,
                built_transition_count,
                tables[0].states.len,
                serialized_transition_count,
                serialized_range_count,
                @as(f64, @floatFromInt(token_set_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(build_table_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(serialize_table_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(profileElapsedNs(total_timer))) / @as(f64, std.time.ns_per_ms),
            },
        );
        std.debug.print(
            "[lexer_table_profile] start_closure_ms={d:.2} construct_ms={d:.2} minimize_ms={d:.2} sort_ms={d:.2} intern_calls={d} intern_new={d} intern_reused={d} next_closure_calls={d} next_closure_ms={d:.2}\n",
            .{
                @as(f64, @floatFromInt(table_profile.start_closure_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(table_profile.construct_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(table_profile.minimize_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(table_profile.sort_ns)) / @as(f64, std.time.ns_per_ms),
                table_profile.intern_calls,
                table_profile.intern_new,
                table_profile.intern_reused,
                table_profile.next_closure_calls,
                @as(f64, @floatFromInt(table_profile.next_closure_ns)) / @as(f64, std.time.ns_per_ms),
            },
        );
    }

    initialized_tables = 0;
    return tables;
}

pub fn buildSerializedLexTablesWithEofAlloc(
    allocator: std.mem.Allocator,
    all_rules: []const ir_rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
    terminal_sets: []const []const bool,
    eof_valids: ?[]const bool,
) SerializeError![]const SerializedLexTable {
    const profile_log = profileEnabled();
    const total_timer = profileTimer(profile_log);
    var expanded = try lexer_model.expandExtractedLexicalGrammar(allocator, all_rules, lexical);
    defer expanded.deinit(allocator);

    const tables = try allocator.alloc(SerializedLexTable, terminal_sets.len);
    var initialized: usize = 0;
    errdefer {
        deinitSerializedLexTables(allocator, tables[0..initialized]);
        allocator.free(tables);
    }

    var token_set_ns: u64 = 0;
    var build_table_ns: u64 = 0;
    var serialize_table_ns: u64 = 0;
    var built_state_count: usize = 0;
    var built_transition_count: usize = 0;
    var serialized_state_count: usize = 0;
    var serialized_transition_count: usize = 0;
    var serialized_range_count: usize = 0;
    var table_profile = lexer_table.BuildProfile{};

    for (terminal_sets, 0..) |terminal_set, index| {
        const token_set_timer = profileTimer(profile_log);
        var allowed = try tokenIndexSetFromTerminalSet(allocator, expanded.variables.len, terminal_set);
        token_set_ns += profileElapsedNs(token_set_timer);
        defer allowed.deinit(allocator);

        const eof_valid = if (eof_valids) |values| index < values.len and values[index] else false;
        const build_timer = profileTimer(profile_log);
        var table = try lexer_table.buildLexTableForSetWithOptions(allocator, expanded, allowed, .{
            .eof_valid = eof_valid,
            .profile = if (profile_log) &table_profile else null,
        });
        build_table_ns += profileElapsedNs(build_timer);
        defer table.deinit();
        built_state_count += table.states.len;
        for (table.states) |lex_state| built_transition_count += lex_state.transitions.len;

        const serialize_timer = profileTimer(profile_log);
        tables[index] = try serializeLexTableAlloc(allocator, table);
        serialize_table_ns += profileElapsedNs(serialize_timer);
        serialized_state_count += tables[index].states.len;
        for (tables[index].states) |lex_state| {
            serialized_transition_count += lex_state.transitions.len;
            for (lex_state.transitions) |transition| serialized_range_count += transition.ranges.len;
        }
        initialized += 1;
    }

    if (tables.len != 0) {
        tables[0].large_character_sets = try buildLargeCharacterSetsAlloc(allocator, expanded);
    }

    if (profile_log) {
        std.debug.print(
            "[lexer_serialize_profile] tables={d} built_states={d} built_transitions={d} serialized_states={d} serialized_transitions={d} serialized_ranges={d} token_set_ms={d:.2} build_table_ms={d:.2} serialize_table_ms={d:.2} total_ms={d:.2}\n",
            .{
                terminal_sets.len,
                built_state_count,
                built_transition_count,
                serialized_state_count,
                serialized_transition_count,
                serialized_range_count,
                @as(f64, @floatFromInt(token_set_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(build_table_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(serialize_table_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(profileElapsedNs(total_timer))) / @as(f64, std.time.ns_per_ms),
            },
        );
        std.debug.print(
            "[lexer_table_profile] start_closure_ms={d:.2} construct_ms={d:.2} minimize_ms={d:.2} sort_ms={d:.2} intern_calls={d} intern_new={d} intern_reused={d} next_closure_calls={d} next_closure_ms={d:.2}\n",
            .{
                @as(f64, @floatFromInt(table_profile.start_closure_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(table_profile.construct_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(table_profile.minimize_ns)) / @as(f64, std.time.ns_per_ms),
                @as(f64, @floatFromInt(table_profile.sort_ns)) / @as(f64, std.time.ns_per_ms),
                table_profile.intern_calls,
                table_profile.intern_new,
                table_profile.intern_reused,
                table_profile.next_closure_calls,
                @as(f64, @floatFromInt(table_profile.next_closure_ns)) / @as(f64, std.time.ns_per_ms),
            },
        );
    }

    return tables;
}

pub fn deinitSerializedLexTables(
    allocator: std.mem.Allocator,
    tables: []const SerializedLexTable,
) void {
    for (tables) |table| deinitSerializedLexTable(allocator, table);
    allocator.free(tables);
}

pub fn deinitSerializedLexTable(
    allocator: std.mem.Allocator,
    table: SerializedLexTable,
) void {
    for (table.states) |state| {
        for (state.transitions) |transition| allocator.free(transition.ranges);
        allocator.free(state.transitions);
    }
    allocator.free(table.states);
    deinitLargeCharacterSets(allocator, table.large_character_sets);
    allocator.free(table.lex_state_starts);
}

pub fn deinitLargeCharacterSets(
    allocator: std.mem.Allocator,
    large_character_sets: []const SerializedLargeCharacterSet,
) void {
    for (large_character_sets) |set| allocator.free(set.ranges);
    allocator.free(large_character_sets);
}

fn tokenIndexSetFromTerminalSet(
    allocator: std.mem.Allocator,
    variable_count: usize,
    terminal_set: []const bool,
) std.mem.Allocator.Error!lexer_model.TokenIndexSet {
    var allowed = try lexer_model.TokenIndexSet.initEmpty(allocator, variable_count);
    errdefer allowed.deinit(allocator);
    for (allowed.values, 0..) |*value, index| {
        value.* = index < terminal_set.len and terminal_set[index];
    }
    return allowed;
}

fn serializeLexTableAlloc(
    allocator: std.mem.Allocator,
    table: lexer_table.LexTable,
) std.mem.Allocator.Error!SerializedLexTable {
    const states = try allocator.alloc(SerializedLexState, table.states.len);
    var initialized: usize = 0;
    errdefer {
        for (states[0..initialized]) |state| {
            for (state.transitions) |transition| allocator.free(transition.ranges);
            allocator.free(state.transitions);
        }
        allocator.free(states);
    }

    for (table.states, 0..) |state, index| {
        states[index] = try serializeLexStateAlloc(allocator, state);
        initialized += 1;
    }

    return .{
        .start_state_id = @intCast(table.start_state_id),
        .states = states,
    };
}

fn serializeLexStateAlloc(
    allocator: std.mem.Allocator,
    state: lexer_table.LexState,
) std.mem.Allocator.Error!SerializedLexState {
    const transitions = try allocator.alloc(SerializedLexTransition, state.transitions.len);
    var initialized: usize = 0;
    errdefer {
        for (transitions[0..initialized]) |transition| allocator.free(transition.ranges);
        allocator.free(transitions);
    }

    for (state.transitions, 0..) |transition, index| {
        transitions[index] = try serializeLexTransitionAlloc(allocator, transition);
        initialized += 1;
    }

    return .{
        .accept_symbol = if (state.completion) |completion|
            .{ .terminal = @intCast(completion.variable_index) }
        else if (state.nfa_states.len == 0)
            .{ .end = {} }
        else
            null,
        .eof_target = if (state.eof_target) |target| @intCast(target) else null,
        .transitions = transitions,
    };
}

fn serializeLexTransitionAlloc(
    allocator: std.mem.Allocator,
    transition: lexer_table.LexTransition,
) std.mem.Allocator.Error!SerializedLexTransition {
    const ranges = try allocator.alloc(SerializedCharacterRange, transition.chars.ranges.items.len);
    for (transition.chars.ranges.items, 0..) |range, index| {
        std.debug.assert(range.end > range.start);
        ranges[index] = .{
            .start = range.start,
            .end_inclusive = range.end - 1,
        };
    }
    return .{
        .ranges = ranges,
        .next_state_id = @intCast(transition.next_state_id),
        .skip = transition.is_separator,
    };
}

fn buildLargeCharacterSetsAlloc(
    allocator: std.mem.Allocator,
    expanded: lexer_model.ExpandedLexicalGrammar,
) std.mem.Allocator.Error![]const SerializedLargeCharacterSet {
    var result = std.array_list.Managed(SerializedLargeCharacterSet).init(allocator);
    defer result.deinit();
    errdefer {
        for (result.items) |set| allocator.free(set.ranges);
    }

    for (expanded.variables, 0..) |_, variable_index| {
        var allowed = try lexer_model.TokenIndexSet.initEmpty(allocator, expanded.variables.len);
        defer allowed.deinit(allocator);
        allowed.values[variable_index] = true;

        var table = try lexer_table.buildLexTableForSetWithOptions(allocator, expanded, allowed, .{});
        defer table.deinit();

        for (table.states) |state| {
            var main_chars = lexer_model.CharacterSet.empty();
            defer main_chars.deinit(allocator);

            for (state.transitions) |transition| {
                if (transition.is_separator) {
                    if (transition.chars.ranges.items.len > 8) {
                        try appendLargeCharacterSetIfNew(
                            allocator,
                            &result,
                            null,
                            transition.chars.ranges.items,
                        );
                    }
                } else {
                    try main_chars.addSet(allocator, transition.chars);
                }
            }

            if (main_chars.ranges.items.len > 8) {
                try appendLargeCharacterSetIfNew(
                    allocator,
                    &result,
                    .{ .terminal = @intCast(variable_index) },
                    main_chars.ranges.items,
                );
            }
        }
    }

    return try result.toOwnedSlice();
}

fn appendLargeCharacterSetIfNew(
    allocator: std.mem.Allocator,
    result: *std.array_list.Managed(SerializedLargeCharacterSet),
    symbol: ?syntax_ir.SymbolRef,
    ranges: []const lexer_model.CharacterSet.Range,
) std.mem.Allocator.Error!void {
    const serialized_ranges = try serializeCharacterRangesAlloc(allocator, ranges);
    errdefer allocator.free(serialized_ranges);

    for (result.items) |entry| {
        if (rangeSetsEqual(entry.ranges, serialized_ranges)) {
            allocator.free(serialized_ranges);
            return;
        }
    }

    try result.append(.{
        .symbol = symbol,
        .ranges = serialized_ranges,
    });
}

fn serializeCharacterRangesAlloc(
    allocator: std.mem.Allocator,
    ranges: []const lexer_model.CharacterSet.Range,
) std.mem.Allocator.Error![]const SerializedCharacterRange {
    const result = try allocator.alloc(SerializedCharacterRange, ranges.len);
    for (ranges, 0..) |range, index| {
        result[index] = .{
            .start = range.start,
            .end_inclusive = range.end - 1,
        };
    }
    return result;
}

fn rangeSetsEqual(
    lhs: []const SerializedCharacterRange,
    rhs: []const SerializedCharacterRange,
) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left.start != right.start) return false;
        if (left.end_inclusive != right.end_inclusive) return false;
    }
    return true;
}

/// Serialized lexical grammar plus boundary blockers.
pub const SerializedLexicalGrammar = struct {
    variables: []const SerializedLexicalVariable,
    unsupported_separators: []const UnsupportedSeparator,
    unsupported_externals: []const UnsupportedExternalToken,
    blocked: bool,

    pub fn isReady(self: SerializedLexicalGrammar) bool {
        return !self.blocked;
    }
};

const LexicalMetadata = struct {
    tokenized: bool = false,
    immediate: bool = false,
};

/// Serialize extracted lexical grammar metadata into the local boundary model.
pub fn serializeExtractedLexicalGrammar(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
) SerializeError!SerializedLexicalGrammar {
    const variables = try allocator.alloc(SerializedLexicalVariable, lexical.variables.len);
    for (lexical.variables, 0..) |variable, index| {
        variables[index] = try serializeVariable(prepared.rules, variable);
    }

    const unsupported_separators = try allocator.alloc(UnsupportedSeparator, lexical.separators.len);
    for (lexical.separators, 0..) |rule, index| {
        unsupported_separators[index] = .{ .rule = rule };
    }

    const unsupported_externals = try allocator.alloc(UnsupportedExternalToken, syntax.external_tokens.len);
    for (syntax.external_tokens, 0..) |token, index| {
        unsupported_externals[index] = .{
            .name = token.name,
            .kind = token.kind,
        };
    }

    return .{
        .variables = variables,
        .unsupported_separators = unsupported_separators,
        .unsupported_externals = unsupported_externals,
        .blocked = lexical.separators.len != 0 or syntax.external_tokens.len != 0,
    };
}

fn serializeVariable(
    all_rules: []const ir_rules.Rule,
    variable: lexical_ir.LexicalVariable,
) SerializeError!SerializedLexicalVariable {
    const resolved = resolveLexicalRule(all_rules, variable.rule, .{});
    return .{
        .name = variable.name,
        .kind = variable.kind,
        .form = resolved.form,
        .tokenized = resolved.metadata.tokenized,
        .immediate = resolved.metadata.immediate,
        .implicit_precedence = variable.implicit_precedence,
        .start_state = variable.start_state,
    };
}

const ResolvedLexicalRule = struct {
    form: SerializedLexicalForm,
    metadata: LexicalMetadata,
};

fn resolveLexicalRule(
    all_rules: []const ir_rules.Rule,
    rule_id: ir_rules.RuleId,
    metadata: LexicalMetadata,
) ResolvedLexicalRule {
    return switch (all_rules[rule_id]) {
        .string => |value| .{
            .form = .{ .string = value },
            .metadata = metadata,
        },
        .pattern => |pattern| .{
            .form = .{ .pattern = .{
                .value = pattern.value,
                .flags = pattern.flags,
            } },
            .metadata = metadata,
        },
        .metadata => |wrapped| resolveLexicalRule(
            all_rules,
            wrapped.inner,
            .{
                .tokenized = metadata.tokenized or wrapped.data.token,
                .immediate = metadata.immediate or wrapped.data.immediate_token,
            },
        ),
        else => unreachable,
    };
}

fn parsePreparedFixture(
    allocator: std.mem.Allocator,
    contents: []const u8,
) !grammar_ir.PreparedGrammar {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(allocator, parsed.value);
    return try parse_grammar.parseRawGrammar(allocator, &raw);
}

test "serializeExtractedLexicalGrammar serializes the ready pattern and string lexer boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFixture(arena.allocator(), fixtures.repeatChoiceSeqGrammarJson().contents);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try serializeExtractedLexicalGrammar(
        arena.allocator(),
        prepared,
        extracted.syntax,
        extracted.lexical,
    );

    try std.testing.expect(serialized.isReady());
    try std.testing.expectEqual(@as(usize, 2), serialized.variables.len);
    try std.testing.expectEqualStrings("identifier", serialized.variables[0].name);
    try std.testing.expect(switch (serialized.variables[0].form) {
        .pattern => |pattern| std.mem.eql(u8, pattern.value, "[a-z]+"),
        else => false,
    });
    try std.testing.expectEqualStrings("number_literal", serialized.variables[1].name);
    try std.testing.expect(switch (serialized.variables[1].form) {
        .string => |value| std.mem.eql(u8, value, "42"),
        else => false,
    });
    try std.testing.expectEqual(@as(usize, 0), serialized.unsupported_separators.len);
    try std.testing.expectEqual(@as(usize, 0), serialized.unsupported_externals.len);
}

test "buildLexModesAlloc serializes parse-state lex ids" {
    const states = [_]struct {
        lex_state_id: u32,
    }{
        .{ .lex_state_id = 0 },
        .{ .lex_state_id = 7 },
    };

    const modes = try buildLexModesAlloc(std.testing.allocator, states[0..]);
    defer std.testing.allocator.free(modes);

    try std.testing.expectEqual(@as(usize, 2), modes.len);
    try std.testing.expectEqual(SerializedLexMode{ .lex_state = 0 }, modes[0]);
    try std.testing.expectEqual(SerializedLexMode{ .lex_state = 7 }, modes[1]);
}

test "buildSerializedLexTablesAlloc builds one table per terminal set" {
    const rules = [_]ir_rules.Rule{
        .{ .string = "a" },
        .{ .string = "b" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "letter_a", .kind = .named, .rule = 0 },
            .{ .name = "letter_b", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };
    const terminal_sets = [_][]const bool{
        &.{ true, false },
        &.{ false, true },
        &.{ true, true },
    };

    const tables = try buildSerializedLexTablesAlloc(
        std.testing.allocator,
        rules[0..],
        lexical,
        terminal_sets[0..],
    );
    defer deinitSerializedLexTables(std.testing.allocator, tables);

    try std.testing.expectEqual(@as(usize, 3), tables.len);
    try std.testing.expect(tables[0].states.len > 0);
    try std.testing.expect(tables[0].start_state_id < tables[0].states.len);
    try std.testing.expect(lexTableAcceptsTerminal(tables[0], 0));
    try std.testing.expect(!lexTableAcceptsTerminal(tables[0], 1));
    try std.testing.expect(lexTableAcceptsTerminal(tables[1], 1));
    try std.testing.expect(lexTableAcceptsTerminal(tables[2], 0));
    try std.testing.expect(lexTableAcceptsTerminal(tables[2], 1));
}

test "buildSharedSerializedLexTablesAlloc builds one main table with remapped starts" {
    const rules = [_]ir_rules.Rule{
        .{ .string = "a" },
        .{ .string = "b" },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "letter_a", .kind = .named, .rule = 0 },
            .{ .name = "letter_b", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };
    const terminal_sets = [_][]const bool{
        &.{ true, false },
        &.{ false, true },
        &.{ true, true },
    };

    const tables = try buildSharedSerializedLexTablesAlloc(
        std.testing.allocator,
        rules[0..],
        lexical,
        terminal_sets[0..],
    );
    defer deinitSerializedLexTables(std.testing.allocator, tables);

    try std.testing.expectEqual(@as(usize, 1), tables.len);
    try std.testing.expectEqual(@as(usize, terminal_sets.len), tables[0].lex_state_starts.len);
    for (tables[0].lex_state_starts) |start| {
        try std.testing.expect(start < tables[0].states.len);
    }
    try std.testing.expect(lexTableAcceptsTerminal(tables[0], 0));
    try std.testing.expect(lexTableAcceptsTerminal(tables[0], 1));
}

test "buildSerializedLexTablesAlloc accepts nullable token suffixes" {
    const rules = [_]ir_rules.Rule{
        .{ .pattern = .{ .value = "[1-9]", .flags = null } },
        .{ .pattern = .{ .value = "[0-9]", .flags = null } },
        .blank,
        .{ .choice = &.{ 1, 2 } },
        .{ .seq = &.{ 0, 3 } },
        .{ .metadata = .{
            .inner = 4,
            .data = .{ .token = true },
        } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "number", .kind = .named, .rule = 5 },
        },
        .separators = &.{},
    };
    const terminal_sets = [_][]const bool{&.{true}};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tables = try buildSerializedLexTablesAlloc(
        arena.allocator(),
        rules[0..],
        lexical,
        terminal_sets[0..],
    );

    const start = tables[0].start_state_id;
    var digit_transition_count: usize = 0;
    var accepts_after_first_digit = false;
    for (tables[0].states[start].transitions) |transition| {
        if (!rangeSetContains(transition.ranges, '4')) continue;
        digit_transition_count += 1;
        const target = tables[0].states[transition.next_state_id];
        accepts_after_first_digit = target.accept_symbol != null;
    }

    try std.testing.expectEqual(@as(usize, 1), digit_transition_count);
    try std.testing.expect(accepts_after_first_digit);
}

test "buildSerializedLexTablesAlloc accepts JSON-style integers before optional exponent" {
    const rules = [_]ir_rules.Rule{
        .{ .string = "-" },
        .blank,
        .{ .choice = &.{ 0, 1 } },
        .{ .string = "0" },
        .{ .pattern = .{ .value = "[1-9]", .flags = null } },
        .{ .pattern = .{ .value = "\\d+", .flags = null } },
        .blank,
        .{ .choice = &.{ 5, 6 } },
        .{ .seq = &.{ 4, 7 } },
        .{ .choice = &.{ 3, 8 } },
        .{ .seq = &.{ 2, 9 } },
        .{ .string = "e" },
        .{ .string = "E" },
        .{ .choice = &.{ 11, 12 } },
        .{ .string = "-" },
        .blank,
        .{ .choice = &.{ 14, 15 } },
        .{ .pattern = .{ .value = "\\d+", .flags = null } },
        .{ .seq = &.{ 16, 17 } },
        .{ .seq = &.{ 13, 18 } },
        .blank,
        .{ .choice = &.{ 19, 20 } },
        .{ .seq = &.{ 10, 21 } },
        .{ .metadata = .{
            .inner = 22,
            .data = .{ .token = true },
        } },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "number", .kind = .named, .rule = 23 },
        },
        .separators = &.{},
    };
    const terminal_sets = [_][]const bool{&.{true}};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tables = try buildSerializedLexTablesAlloc(
        arena.allocator(),
        rules[0..],
        lexical,
        terminal_sets[0..],
    );

    const start = tables[0].start_state_id;
    var accepts_after_first_digit = false;
    for (tables[0].states[start].transitions) |transition| {
        if (!rangeSetContains(transition.ranges, '4')) continue;
        const target = tables[0].states[transition.next_state_id];
        accepts_after_first_digit = target.accept_symbol != null;
    }

    try std.testing.expect(accepts_after_first_digit);
}

fn rangeSetContains(ranges: []const SerializedCharacterRange, codepoint: u32) bool {
    for (ranges) |range| {
        if (range.start <= codepoint and codepoint <= range.end_inclusive) return true;
    }
    return false;
}

test "serializeLexTableAlloc preserves EOF targets" {
    const rules = [_]ir_rules.Rule{
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

    var table = try lexer_table.buildLexTableForSetWithOptions(
        std.testing.allocator,
        expanded,
        allowed,
        .{ .eof_valid = true },
    );
    defer table.deinit();

    const serialized = try serializeLexTableAlloc(std.testing.allocator, table);
    defer deinitSerializedLexTable(std.testing.allocator, serialized);

    const start = serialized.states[serialized.start_state_id];
    try std.testing.expect(start.eof_target != null);
    try std.testing.expect(start.eof_target.? < serialized.states.len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .end = {} }, serialized.states[start.eof_target.?].accept_symbol.?);
}

fn lexTableAcceptsTerminal(table: SerializedLexTable, terminal_index: u32) bool {
    for (table.states) |state| {
        if (state.accept_symbol) |symbol| switch (symbol) {
            .terminal => |index| if (index == terminal_index) return true,
            else => {},
        };
    }
    return false;
}

test "serializeExtractedLexicalGrammar keeps token and immediate metadata on lexical rules" {
    const rules = [_]ir_rules.Rule{
        .{
            .metadata = .{
                .inner = 1,
                .data = .{
                    .token = true,
                    .immediate_token = true,
                },
            },
        },
        .{ .pattern = .{ .value = "[a-z]+", .flags = "i" } },
    };

    const variable = lexical_ir.LexicalVariable{
        .name = "identifier",
        .kind = .named,
        .rule = 0,
        .implicit_precedence = 2,
        .start_state = 7,
    };

    const serialized = try serializeVariable(rules[0..], variable);
    try std.testing.expect(serialized.tokenized);
    try std.testing.expect(serialized.immediate);
    try std.testing.expectEqual(@as(i32, 2), serialized.implicit_precedence);
    try std.testing.expectEqual(@as(u32, 7), serialized.start_state);
    try std.testing.expect(switch (serialized.form) {
        .pattern => |pattern| std.mem.eql(u8, pattern.value, "[a-z]+") and std.mem.eql(u8, pattern.flags.?, "i"),
        else => false,
    });
}

test "serializeExtractedLexicalGrammar makes external-token blockers explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFixture(arena.allocator(), fixtures.mixedSemanticsGrammarJson().contents);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try serializeExtractedLexicalGrammar(
        arena.allocator(),
        prepared,
        extracted.syntax,
        extracted.lexical,
    );

    try std.testing.expect(!serialized.isReady());
    try std.testing.expectEqual(@as(usize, 0), serialized.unsupported_separators.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.unsupported_externals.len);
    try std.testing.expectEqualStrings("indent", serialized.unsupported_externals[0].name);
}

test "serializeExtractedLexicalGrammar makes separator blockers explicit" {
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "separator_blocker",
        .variables = &.{},
        .external_tokens = &.{},
        .rules = &.{
            .{ .string = " " },
        },
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{},
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{},
        .separators = &.{0},
    };

    const serialized = try serializeExtractedLexicalGrammar(
        std.testing.allocator,
        prepared,
        syntax,
        lexical,
    );
    defer std.testing.allocator.free(serialized.variables);
    defer std.testing.allocator.free(serialized.unsupported_separators);
    defer std.testing.allocator.free(serialized.unsupported_externals);

    try std.testing.expect(!serialized.isReady());
    try std.testing.expectEqual(@as(usize, 1), serialized.unsupported_separators.len);
    try std.testing.expectEqual(@as(ir_rules.RuleId, 0), serialized.unsupported_separators[0].rule);
    try std.testing.expectEqual(@as(usize, 0), serialized.unsupported_externals.len);
}

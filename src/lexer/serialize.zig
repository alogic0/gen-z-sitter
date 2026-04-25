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
    var expanded = try lexer_model.expandExtractedLexicalGrammar(allocator, all_rules, lexical);
    defer expanded.deinit(allocator);

    const tables = try allocator.alloc(SerializedLexTable, terminal_sets.len);
    var initialized: usize = 0;
    errdefer {
        deinitSerializedLexTables(allocator, tables[0..initialized]);
        allocator.free(tables);
    }

    for (terminal_sets, 0..) |terminal_set, index| {
        var allowed = try tokenIndexSetFromTerminalSet(allocator, expanded.variables.len, terminal_set);
        defer allowed.deinit(allocator);

        var table = try lexer_table.buildLexTableForSet(allocator, expanded, allowed);
        defer table.deinit();

        tables[index] = try serializeLexTableAlloc(allocator, table);
        initialized += 1;
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
        else
            null,
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

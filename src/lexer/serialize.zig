const std = @import("std");
const grammar_ir = @import("../ir/grammar_ir.zig");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const ir_rules = @import("../ir/rules.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const json_loader = @import("../grammar/json_loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const SerializeError = std.mem.Allocator.Error;

pub const SerializedLexicalForm = union(enum) {
    string: []const u8,
    pattern: struct {
        value: []const u8,
        flags: ?[]const u8,
    },
};

pub const SerializedLexicalVariable = struct {
    name: []const u8,
    kind: lexical_ir.VariableKind,
    form: SerializedLexicalForm,
    tokenized: bool,
    immediate: bool,
    implicit_precedence: i32,
    start_state: u32,
};

pub const UnsupportedSeparator = struct {
    rule: ir_rules.RuleId,
};

pub const UnsupportedExternalToken = struct {
    name: []const u8,
    kind: syntax_ir.VariableKind,
};

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

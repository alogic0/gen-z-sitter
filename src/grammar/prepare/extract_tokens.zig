const std = @import("std");
const prepared_ir = @import("../../ir/grammar_ir.zig");
const lexical_ir = @import("../../ir/lexical_grammar.zig");
const syntax_ir = @import("../../ir/syntax_grammar.zig");
const ir_rules = @import("../../ir/rules.zig");
const ir_symbols = @import("../../ir/symbols.zig");
const expand_repeats = @import("expand_repeats.zig");
const fixtures = @import("../../tests/fixtures.zig");
const json_loader = @import("../json_loader.zig");
const parse_grammar = @import("../parse_grammar.zig");

pub const ExtractTokensError = error{
    InvalidConflictSymbol,
    InvalidInlineSymbol,
    InvalidPrecedenceSymbol,
    InvalidSupertypeSymbol,
    InvalidSupertypeStructure,
    InvalidWordToken,
    UnsupportedRuleShape,
    OutOfMemory,
};

pub const ExtractedGrammars = struct {
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
};

pub fn extractTokens(
    allocator: std.mem.Allocator,
    prepared: prepared_ir.PreparedGrammar,
) ExtractTokensError!ExtractedGrammars {
    var extractor = Extractor.init(allocator, prepared);
    return extractor.extract();
}

const Extractor = struct {
    allocator: std.mem.Allocator,
    prepared: prepared_ir.PreparedGrammar,
    lexical_variables: std.array_list.Managed(lexical_ir.LexicalVariable),
    separators: std.array_list.Managed(ir_rules.RuleId),
    auxiliary_variables: std.array_list.Managed(syntax_ir.SyntaxVariable),
    repeat_cache: std.AutoHashMap(RepeatKey, u32),
    promoted_top_level_repeat_variables: std.array_list.Managed(u32),

    fn init(allocator: std.mem.Allocator, prepared: prepared_ir.PreparedGrammar) Extractor {
        return .{
            .allocator = allocator,
            .prepared = prepared,
            .lexical_variables = std.array_list.Managed(lexical_ir.LexicalVariable).init(allocator),
            .separators = std.array_list.Managed(ir_rules.RuleId).init(allocator),
            .auxiliary_variables = std.array_list.Managed(syntax_ir.SyntaxVariable).init(allocator),
            .repeat_cache = std.AutoHashMap(RepeatKey, u32).init(allocator),
            .promoted_top_level_repeat_variables = std.array_list.Managed(u32).init(allocator),
        };
    }

    fn extract(self: *Extractor) ExtractTokensError!ExtractedGrammars {
        const variables = try self.extractVariables();
        const external_tokens = try self.extractExternalTokens();
        const extra_symbols = try self.extractExtraSymbols();
        const expected_conflicts = try self.convertConflictSets();
        const precedence_orderings = try self.convertPrecedenceOrderings();
        const variables_to_inline = try self.extractVariablesToInline();
        const supertype_symbols = try self.extractSupertypeSymbols();
        try self.validateSupertypeStructures(supertype_symbols, variables);
        const word_token = try self.extractWordToken();

        return .{
            .syntax = .{
                .variables = variables,
                .external_tokens = external_tokens,
                .extra_symbols = extra_symbols,
                .expected_conflicts = expected_conflicts,
                .precedence_orderings = precedence_orderings,
                .variables_to_inline = variables_to_inline,
                .supertype_symbols = supertype_symbols,
                .word_token = word_token,
            },
            .lexical = .{
                .variables = try self.lexical_variables.toOwnedSlice(),
                .separators = try self.separators.toOwnedSlice(),
            },
        };
    }

    fn extractExternalTokens(self: *Extractor) ExtractTokensError![]const syntax_ir.ExternalToken {
        var result = std.array_list.Managed(syntax_ir.ExternalToken).init(self.allocator);
        defer result.deinit();

        for (self.prepared.external_tokens) |token| {
            try result.append(.{
                .name = token.name,
                .kind = switch (token.kind) {
                    .named => .named,
                    .hidden => .hidden,
                    .anonymous => .anonymous,
                    .auxiliary => .auxiliary,
                },
            });
        }

        return try result.toOwnedSlice();
    }

    fn extractWordToken(self: *Extractor) ExtractTokensError!?syntax_ir.SymbolRef {
        const word = self.prepared.word_token orelse return null;

        switch (word.kind) {
            .non_terminal => {
                const variable = self.prepared.variables[word.index];
                if (self.findLexicalVariable(variable.rule)) |terminal_index| {
                    return .{ .terminal = terminal_index };
                }
                return error.InvalidWordToken;
            },
            .external => return error.InvalidWordToken,
        }
    }

    fn extractPrecedenceSymbol(self: *Extractor, symbol: ir_symbols.SymbolId) ExtractTokensError!syntax_ir.SymbolRef {
        switch (symbol.kind) {
            .non_terminal => {
                const variable = self.prepared.variables[symbol.index];
                if (self.findLexicalVariable(variable.rule)) |terminal_index| {
                    return .{ .terminal = terminal_index };
                }
                return .{ .non_terminal = symbol.index };
            },
            .external => return error.InvalidPrecedenceSymbol,
        }
    }

    fn extractVariables(self: *Extractor) ExtractTokensError![]const syntax_ir.SyntaxVariable {
        var result = std.array_list.Managed(syntax_ir.SyntaxVariable).init(self.allocator);
        defer result.deinit();

        for (self.prepared.variables, 0..) |variable, index| {
            if (try self.extractPromotedTopLevelRepeatVariable(@intCast(index), variable)) |promoted| {
                try result.append(promoted);
                continue;
            }

            try result.append(.{
                .name = variable.name,
                .kind = switch (variable.kind) {
                    .named => .named,
                    .hidden => .hidden,
                    .anonymous => .anonymous,
                    .auxiliary => .auxiliary,
                },
                .productions = try self.extractProductions(variable.name, variable.rule),
            });
        }

        try result.appendSlice(self.auxiliary_variables.items);
        return try result.toOwnedSlice();
    }

    fn extractPromotedTopLevelRepeatVariable(
        self: *Extractor,
        variable_index: u32,
        variable: prepared_ir.Variable,
    ) ExtractTokensError!?syntax_ir.SyntaxVariable {
        if (variable.kind != .hidden) return null;

        const rule = self.prepared.rules[@intCast(variable.rule)];
        const repeat: TopLevelRepeatInfo = switch (rule) {
            .repeat => |inner| .{ .inner = inner, .at_least_one = false },
            .repeat1 => |inner| .{ .inner = inner, .at_least_one = true },
            else => return null,
        };

        const inner_productions = try self.extractProductions(variable.name, repeat.inner);
        const productions = try expand_repeats.createRepeatProductions(
            self.allocator,
            variable_index,
            inner_productions,
            repeat.at_least_one,
        );
        try self.promoted_top_level_repeat_variables.append(variable_index);

        return .{
            .name = variable.name,
            .kind = .auxiliary,
            .productions = productions,
        };
    }

    fn extractExtraSymbols(self: *Extractor) ExtractTokensError![]const syntax_ir.SymbolRef {
        var result = std.array_list.Managed(syntax_ir.SymbolRef).init(self.allocator);
        defer result.deinit();

        for (self.prepared.extra_rules) |rule_id| {
            const rule = self.prepared.rules[@intCast(rule_id)];
            if (self.findLexicalVariable(rule_id)) |terminal_index| {
                try result.append(.{ .terminal = terminal_index });
                continue;
            }

            switch (rule) {
                .symbol => |symbol| try result.append(try self.extractExtraSymbol(symbol)),
                else => try self.separators.append(rule_id),
            }
        }

        return try result.toOwnedSlice();
    }

    fn extractExtraSymbol(self: *Extractor, symbol: ir_symbols.SymbolId) ExtractTokensError!syntax_ir.SymbolRef {
        switch (symbol.kind) {
            .non_terminal => {
                const variable = self.prepared.variables[symbol.index];
                if (self.findLexicalVariable(variable.rule)) |terminal_index| {
                    return .{ .terminal = terminal_index };
                }
                return .{ .non_terminal = symbol.index };
            },
            .external => return .{ .external = symbol.index },
        }
    }

    fn convertConflictSets(self: *Extractor) ExtractTokensError![]const []const syntax_ir.SymbolRef {
        var result = std.array_list.Managed([]const syntax_ir.SymbolRef).init(self.allocator);
        defer result.deinit();

        for (self.prepared.expected_conflicts) |conflict_set| {
            var converted = std.array_list.Managed(syntax_ir.SymbolRef).init(self.allocator);
            defer converted.deinit();

            for (conflict_set) |symbol| {
                switch (symbol.kind) {
                    .non_terminal => try converted.append(.{ .non_terminal = symbol.index }),
                    .external => return error.InvalidConflictSymbol,
                }
            }

            try result.append(try converted.toOwnedSlice());
        }

        return try result.toOwnedSlice();
    }

    fn convertPrecedenceOrderings(self: *Extractor) ExtractTokensError![]const []const syntax_ir.PrecedenceEntry {
        var result = std.array_list.Managed([]const syntax_ir.PrecedenceEntry).init(self.allocator);
        defer result.deinit();

        for (self.prepared.precedence_orderings) |ordering| {
            var entries = std.array_list.Managed(syntax_ir.PrecedenceEntry).init(self.allocator);
            defer entries.deinit();

            for (ordering) |entry| {
                try entries.append(switch (entry) {
                    .name => |name| .{ .name = name },
                    .symbol => |symbol| .{ .symbol = try self.extractPrecedenceSymbol(symbol) },
                });
            }

            try result.append(try entries.toOwnedSlice());
        }

        return try result.toOwnedSlice();
    }

    fn convertSymbolList(self: *Extractor, symbols: []const ir_symbols.SymbolId) ExtractTokensError![]const syntax_ir.SymbolRef {
        var result = std.array_list.Managed(syntax_ir.SymbolRef).init(self.allocator);
        defer result.deinit();

        for (symbols) |symbol| {
            try result.append(try self.convertSymbol(symbol));
        }

        return try result.toOwnedSlice();
    }

    fn extractVariablesToInline(self: *Extractor) ExtractTokensError![]const syntax_ir.SymbolRef {
        var result = std.array_list.Managed(syntax_ir.SymbolRef).init(self.allocator);
        defer result.deinit();

        for (self.prepared.variables_to_inline) |symbol| {
            if (self.isPromotedTopLevelRepeatSymbol(symbol)) continue;
            switch (symbol.kind) {
                .non_terminal => try result.append(.{ .non_terminal = symbol.index }),
                .external => return error.InvalidInlineSymbol,
            }
        }

        return try result.toOwnedSlice();
    }

    fn extractSupertypeSymbols(self: *Extractor) ExtractTokensError![]const syntax_ir.SymbolRef {
        var result = std.array_list.Managed(syntax_ir.SymbolRef).init(self.allocator);
        defer result.deinit();

        for (self.prepared.supertype_symbols) |symbol| {
            switch (symbol.kind) {
                .non_terminal => try result.append(.{ .non_terminal = symbol.index }),
                .external => return error.InvalidSupertypeSymbol,
            }
        }

        return try result.toOwnedSlice();
    }

    fn validateSupertypeStructures(
        self: *Extractor,
        supertype_symbols: []const syntax_ir.SymbolRef,
        variables: []const syntax_ir.SyntaxVariable,
    ) ExtractTokensError!void {
        _ = self;
        for (supertype_symbols) |symbol| {
            const index = switch (symbol) {
                .non_terminal => |i| i,
                else => return error.InvalidSupertypeSymbol,
            };

            const variable = variables[index];
            for (variable.productions) |production| {
                for (production.steps) |step| {
                    switch (step.symbol) {
                        .external => return error.InvalidSupertypeStructure,
                        .non_terminal, .terminal => {},
                    }
                }
            }
        }
    }

    fn isPromotedTopLevelRepeatSymbol(self: *Extractor, symbol: ir_symbols.SymbolId) bool {
        if (symbol.kind != .non_terminal) return false;
        for (self.promoted_top_level_repeat_variables.items) |promoted| {
            if (promoted == symbol.index) return true;
        }
        return false;
    }

    fn convertSymbol(self: *Extractor, symbol: ir_symbols.SymbolId) ExtractTokensError!syntax_ir.SymbolRef {
        _ = self;
        return switch (symbol.kind) {
            .non_terminal => .{ .non_terminal = symbol.index },
            .external => .{ .external = symbol.index },
        };
    }

    fn extractProductions(self: *Extractor, variable_name: []const u8, rule_id: ir_rules.RuleId) ExtractTokensError![]syntax_ir.Production {
        if (self.tryEnsureLexicalVariable(variable_name, rule_id)) |terminal_index| {
            return try self.singleStepProductions(.{
                .symbol = .{ .terminal = terminal_index },
            });
        }

        const rule = self.prepared.rules[@intCast(rule_id)];
        return switch (rule) {
            .blank => try self.singleProduction(&.{}),
            .symbol => |symbol| try self.singleStepProductions(.{
                .symbol = try self.convertSymbol(symbol),
            }),
            .string, .pattern => unreachable,
            .choice => |members| self.extractChoiceProductions(variable_name, members),
            .seq => |members| self.extractSequenceProductions(variable_name, members),
            .repeat => |inner| self.extractRepeatProductions(variable_name, inner, false),
            .repeat1 => |inner| self.extractRepeatProductions(variable_name, inner, true),
            .metadata => |metadata| self.extractMetadataProductions(variable_name, metadata),
        };
    }

    fn extractRepeatProductions(
        self: *Extractor,
        variable_name: []const u8,
        inner: ir_rules.RuleId,
        at_least_one: bool,
    ) ExtractTokensError![]syntax_ir.Production {
        const repeat_symbol = try self.ensureRepeatAuxiliary(variable_name, inner, at_least_one);
        return try self.singleStepProductions(.{
            .symbol = .{ .non_terminal = repeat_symbol },
        });
    }

    fn extractChoiceProductions(self: *Extractor, variable_name: []const u8, members: []const ir_rules.RuleId) ExtractTokensError![]syntax_ir.Production {
        var result = std.array_list.Managed(syntax_ir.Production).init(self.allocator);
        defer result.deinit();

        for (members) |member| {
            const productions = try self.extractProductions(variable_name, member);
            try result.appendSlice(productions);
        }

        return try result.toOwnedSlice();
    }

    fn extractSequenceProductions(self: *Extractor, variable_name: []const u8, members: []const ir_rules.RuleId) ExtractTokensError![]syntax_ir.Production {
        var current = try self.singleProduction(&.{}); // one empty production

        for (members) |member| {
            const next = try self.extractProductions(variable_name, member);
            current = try self.combineProductionSets(current, next);
        }

        return current;
    }

    fn extractMetadataProductions(
        self: *Extractor,
        variable_name: []const u8,
        metadata: ir_rules.MetadataRule,
    ) ExtractTokensError![]syntax_ir.Production {
        if (metadata.data.token or metadata.data.immediate_token) {
            if (self.tryEnsureLexicalVariable(variable_name, @intCast(metadata.inner))) |terminal_index| {
                const productions = try self.singleStepProductions(.{
                    .symbol = .{ .terminal = terminal_index },
                });
                self.applyMetadataToProductions(productions, metadata.data);
                return productions;
            }
        }

        const productions = try self.extractProductions(variable_name, metadata.inner);
        self.applyMetadataToProductions(productions, metadata.data);
        return productions;
    }

    fn applyMetadataToProductions(self: *Extractor, productions: []syntax_ir.Production, metadata: ir_rules.Metadata) void {
        _ = self;
        for (productions) |*production| {
            if (production.steps.len == 0) continue;
            var step = &production.steps[0];
            if (metadata.field_name) |field_name| step.field_name = field_name;
            if (metadata.alias) |alias| step.alias = alias;
            if (metadata.precedence != .none) step.precedence = metadata.precedence;
            if (metadata.associativity != .none) step.associativity = metadata.associativity;
            if (metadata.reserved_context_name) |context| step.reserved_context_name = context;
            if (metadata.dynamic_precedence != 0) production.dynamic_precedence = metadata.dynamic_precedence;
        }
    }

    fn tryEnsureLexicalVariable(self: *Extractor, preferred_name: []const u8, rule_id: ir_rules.RuleId) ?u32 {
        if (!self.isLexicalRule(rule_id)) return null;

        if (self.findLexicalVariable(rule_id)) |index| return index;

        const name = self.lexicalNameForRule(rule_id, preferred_name);
        const kind = self.lexicalKindForRule(rule_id, preferred_name);
        self.lexical_variables.append(.{
            .name = name,
            .kind = kind,
            .rule = rule_id,
        }) catch return null;
        return @intCast(self.lexical_variables.items.len - 1);
    }

    fn findLexicalVariable(self: *Extractor, rule_id: ir_rules.RuleId) ?u32 {
        for (self.lexical_variables.items, 0..) |variable, i| {
            if (variable.rule == rule_id) return @intCast(i);
        }
        return null;
    }

    fn ensureRepeatAuxiliary(
        self: *Extractor,
        variable_name: []const u8,
        inner: ir_rules.RuleId,
        at_least_one: bool,
    ) ExtractTokensError!u32 {
        const key = RepeatKey{ .rule_id = inner, .at_least_one = at_least_one };
        if (self.repeat_cache.get(key)) |symbol_index| return symbol_index;

        const auxiliary_index = self.auxiliary_variables.items.len;
        const symbol_index: u32 = @intCast(self.prepared.variables.len + auxiliary_index);
        try self.auxiliary_variables.append(.{
            .name = "",
            .kind = .auxiliary,
            .productions = &.{},
        });
        errdefer _ = self.auxiliary_variables.pop();
        try self.repeat_cache.put(key, symbol_index);
        errdefer _ = self.repeat_cache.remove(key);

        const inner_productions = try self.extractProductions(variable_name, inner);
        const expansion = try expand_repeats.createRepeatAuxiliary(
            self.allocator,
            variable_name,
            symbol_index,
            inner_productions,
            at_least_one,
        );
        self.auxiliary_variables.items[auxiliary_index] = expansion.variable;
        return symbol_index;
    }

    fn singleStepProductions(self: *Extractor, step: syntax_ir.ProductionStep) ExtractTokensError![]syntax_ir.Production {
        const steps = try self.allocator.dupe(syntax_ir.ProductionStep, &.{step});
        return try self.singleProduction(steps);
    }

    fn singleProduction(self: *Extractor, steps: []syntax_ir.ProductionStep) ExtractTokensError![]syntax_ir.Production {
        return try self.allocator.dupe(syntax_ir.Production, &.{.{ .steps = steps }});
    }

    fn combineProductionSets(
        self: *Extractor,
        left: []const syntax_ir.Production,
        right: []const syntax_ir.Production,
    ) ExtractTokensError![]syntax_ir.Production {
        var result = std.array_list.Managed(syntax_ir.Production).init(self.allocator);
        defer result.deinit();

        for (left) |lhs| {
            for (right) |rhs| {
                var steps = std.array_list.Managed(syntax_ir.ProductionStep).init(self.allocator);
                defer steps.deinit();
                try steps.appendSlice(lhs.steps);
                try steps.appendSlice(rhs.steps);
                try result.append(.{
                    .steps = try steps.toOwnedSlice(),
                    .dynamic_precedence = lhs.dynamic_precedence + rhs.dynamic_precedence,
                });
            }
        }

        return try result.toOwnedSlice();
    }

    fn isLexicalRule(self: *Extractor, rule_id: ir_rules.RuleId) bool {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string, .pattern => true,
            .metadata => |metadata| (metadata.data.token or metadata.data.immediate_token) and self.isLexicalRule(metadata.inner),
            else => false,
        };
    }

    fn lexicalNameForRule(self: *Extractor, rule_id: ir_rules.RuleId, preferred_name: []const u8) []const u8 {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string => |value| if (shouldUseLiteralLexicalName(preferred_name)) value else preferred_name,
            .pattern => |pattern| if (shouldUseLiteralLexicalName(preferred_name)) pattern.value else preferred_name,
            .metadata => |metadata| self.lexicalNameForRule(metadata.inner, preferred_name),
            else => preferred_name,
        };
    }

    fn lexicalKindForRule(self: *Extractor, rule_id: ir_rules.RuleId, preferred_name: []const u8) lexical_ir.VariableKind {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string, .pattern => if (shouldUseLiteralLexicalName(preferred_name)) .anonymous else .named,
            .metadata => |metadata| self.lexicalKindForRule(metadata.inner, preferred_name),
            else => .named,
        };
    }
};

fn shouldUseLiteralLexicalName(preferred_name: []const u8) bool {
    return std.mem.eql(u8, preferred_name, "source_file") or
        (preferred_name.len > 0 and preferred_name[0] == '_');
}

const RepeatKey = struct {
    rule_id: ir_rules.RuleId,
    at_least_one: bool,
};

const TopLevelRepeatInfo = struct {
    inner: ir_rules.RuleId,
    at_least_one: bool,
};

test "extractTokens splits simple prepared grammar into syntax and lexical parts" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var extract_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer extract_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.validResolvedGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw_grammar);
    const extracted = try extractTokens(extract_arena.allocator(), prepared);

    try std.testing.expectEqual(@as(usize, 3), extracted.syntax.variables.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.external_tokens.len);
    try std.testing.expectEqualStrings("indent", extracted.syntax.external_tokens[0].name);
    try std.testing.expectEqual(syntax_ir.VariableKind.named, extracted.syntax.external_tokens[0].kind);
    try std.testing.expectEqual(@as(usize, 2), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("expr", extracted.lexical.variables[0].name);
    try std.testing.expectEqualStrings("term", extracted.lexical.variables[1].name);
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.separators.len);
    try std.testing.expectEqual(@as(usize, 0), extracted.syntax.extra_symbols.len);
    try std.testing.expect(extracted.syntax.word_token != null);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.word_token.?.terminal);
}

test "extractTokens rewrites precedence symbols to extracted terminals" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "precedence-token-rewrite",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
            .{
                .name = "term",
                .symbol = ir_symbols.SymbolId.nonTerminal(1),
                .kind = .named,
                .rule = 1,
            },
        },
        .external_tokens = &.{},
        .rules = &.{ .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) }, .{ .string = "x" } },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.nonTerminal(1),
                .name = "term",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{&.{
            prepared_ir.PrecedenceEntry{ .symbol = ir_symbols.SymbolId.nonTerminal(1) },
        }},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.precedence_orderings.len);
    switch (extracted.syntax.precedence_orderings[0][0]) {
        .symbol => |symbol| try std.testing.expectEqual(@as(u32, 0), symbol.terminal),
        .name => return error.TestUnexpectedResult,
    }
}

test "extractTokens rewrites symbol extras to extracted terminals" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "extra-token-rewrite",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
            .{
                .name = "space",
                .symbol = ir_symbols.SymbolId.nonTerminal(1),
                .kind = .named,
                .rule = 1,
            },
        },
        .external_tokens = &.{},
        .rules = &.{ .{ .blank = {} }, .{ .string = " " }, .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) } },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.nonTerminal(1),
                .name = "space",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{2},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.extra_symbols.len);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.extra_symbols[0].terminal);
}

test "extractTokens uses literal token names inside hidden wrappers" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var extract_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer extract_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.hiddenWrapperGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw_grammar);
    const extracted = try extractTokens(extract_arena.allocator(), prepared);

    try std.testing.expectEqualStrings("+", extracted.lexical.variables[0].name);
    try std.testing.expectEqual(lexical_ir.VariableKind.anonymous, extracted.lexical.variables[0].kind);
    try std.testing.expectEqualStrings("expr", extracted.lexical.variables[1].name);
    try std.testing.expectEqual(lexical_ir.VariableKind.named, extracted.lexical.variables[1].kind);
    try std.testing.expectEqualStrings("term", extracted.lexical.variables[2].name);
    try std.testing.expectEqual(lexical_ir.VariableKind.named, extracted.lexical.variables[2].kind);
}

test "extractTokens expands repeat rules into auxiliary syntax variables" {
    const repeat_inner = ir_rules.Rule{ .string = "item" };
    const repeat_rule = ir_rules.Rule{ .repeat = 0 };
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "repeaty",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 1,
            },
        },
        .external_tokens = &.{},
        .rules = &.{ repeat_inner, repeat_rule },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 2), extracted.syntax.variables.len);
    try std.testing.expectEqual(@as(usize, 0), extracted.syntax.external_tokens.len);
    try std.testing.expectEqualStrings("source_file", extracted.syntax.variables[0].name);
    try std.testing.expectEqualStrings("source_file_repeat1", extracted.syntax.variables[1].name);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.variables[0].productions[0].steps[0].symbol.non_terminal);
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.variables.len);
}

test "extractTokens carries external token metadata into syntax grammar" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "externals",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
        },
        .external_tokens = &.{
            .{
                .name = "_automatic_semicolon",
                .symbol = ir_symbols.SymbolId.external(0),
                .kind = .hidden,
                .rule = 1,
            },
            .{
                .name = "template_chars",
                .symbol = ir_symbols.SymbolId.external(1),
                .kind = .named,
                .rule = 2,
            },
        },
        .rules = &.{.{ .blank = {} }, .{ .blank = {} }, .{ .blank = {} }},
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.external(0),
                .name = "_automatic_semicolon",
                .named = false,
                .visible = false,
            },
            .{
                .id = ir_symbols.SymbolId.external(1),
                .name = "template_chars",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 2), extracted.syntax.external_tokens.len);
    try std.testing.expectEqualStrings("_automatic_semicolon", extracted.syntax.external_tokens[0].name);
    try std.testing.expectEqual(syntax_ir.VariableKind.hidden, extracted.syntax.external_tokens[0].kind);
    try std.testing.expectEqualStrings("template_chars", extracted.syntax.external_tokens[1].name);
    try std.testing.expectEqual(syntax_ir.VariableKind.named, extracted.syntax.external_tokens[1].kind);
}

test "extractTokens rejects external supertype symbols" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "bad-supertype",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
        },
        .external_tokens = &.{
            .{
                .name = "template_chars",
                .symbol = ir_symbols.SymbolId.external(0),
                .kind = .named,
                .rule = 1,
            },
        },
        .rules = &.{.{ .blank = {} }, .{ .blank = {} }},
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.external(0),
                .name = "template_chars",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{ir_symbols.SymbolId.external(0)},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidSupertypeSymbol, extractTokens(arena.allocator(), prepared));
}

test "extractTokens rejects supertypes that lower to external steps" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "bad-supertype-structure",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
            .{
                .name = "expression",
                .symbol = ir_symbols.SymbolId.nonTerminal(1),
                .kind = .named,
                .rule = 1,
            },
        },
        .external_tokens = &.{
            .{
                .name = "template_chars",
                .symbol = ir_symbols.SymbolId.external(0),
                .kind = .named,
                .rule = 2,
            },
        },
        .rules = &.{ .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) }, .{ .symbol = ir_symbols.SymbolId.external(0) }, .{ .blank = {} } },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.nonTerminal(1),
                .name = "expression",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.external(0),
                .name = "template_chars",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{ir_symbols.SymbolId.nonTerminal(1)},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidSupertypeStructure, extractTokens(arena.allocator(), prepared));
}

test "extractTokens rejects word tokens that do not lower to lexical terminals" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "bad-word-token",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
            .{
                .name = "expression",
                .symbol = ir_symbols.SymbolId.nonTerminal(1),
                .kind = .named,
                .rule = 1,
            },
        },
        .external_tokens = &.{},
        .rules = &.{ .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) }, .{ .blank = {} } },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.nonTerminal(1),
                .name = "expression",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = ir_symbols.SymbolId.nonTerminal(1),
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidWordToken, extractTokens(arena.allocator(), prepared));
}

test "extractTokens rejects external word tokens" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "bad-external-word-token",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
        },
        .external_tokens = &.{
            .{
                .name = "template_chars",
                .symbol = ir_symbols.SymbolId.external(0),
                .kind = .named,
                .rule = 1,
            },
        },
        .rules = &.{ .{ .blank = {} }, .{ .blank = {} } },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.external(0),
                .name = "template_chars",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = ir_symbols.SymbolId.external(0),
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidWordToken, extractTokens(arena.allocator(), prepared));
}

test "extractTokens promotes hidden top-level repeats in place and removes them from inline symbols" {
    const repeat_inner = ir_rules.Rule{ .string = "item" };
    const repeat_rule = ir_rules.Rule{ .repeat = 0 };
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "hidden-repeat",
        .variables = &.{
            .{
                .name = "_items",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .hidden,
                .rule = 1,
            },
        },
        .external_tokens = &.{},
        .rules = &.{ repeat_inner, repeat_rule },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "_items",
                .named = false,
                .visible = false,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{ir_symbols.SymbolId.nonTerminal(0)},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables.len);
    try std.testing.expectEqualStrings("_items", extracted.syntax.variables[0].name);
    try std.testing.expectEqual(syntax_ir.VariableKind.auxiliary, extracted.syntax.variables[0].kind);
    try std.testing.expectEqual(@as(usize, 3), extracted.syntax.variables[0].productions.len);
    try std.testing.expectEqual(@as(usize, 0), extracted.syntax.variables_to_inline.len);
}

test "extractTokens reuses one auxiliary variable for duplicated repeat content" {
    const terminal_rule = ir_rules.Rule{ .string = "item" };
    const repeat_rule = ir_rules.Rule{ .repeat = 0 };
    const seq_one = ir_rules.Rule{ .seq = &.{ 0, 1 } };
    const seq_two = ir_rules.Rule{ .seq = &.{ 0, 1 } };
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "dedup-repeat",
        .variables = &.{
            .{
                .name = "left",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 2,
            },
            .{
                .name = "right",
                .symbol = ir_symbols.SymbolId.nonTerminal(1),
                .kind = .named,
                .rule = 3,
            },
        },
        .external_tokens = &.{},
        .rules = &.{ terminal_rule, repeat_rule, seq_one, seq_two },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "left",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.nonTerminal(1),
                .name = "right",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 3), extracted.syntax.variables.len);
    try std.testing.expectEqualStrings("left_repeat2", extracted.syntax.variables[2].name);
    try std.testing.expectEqual(@as(u32, 2), extracted.syntax.variables[0].productions[0].steps[1].symbol.non_terminal);
    try std.testing.expectEqual(@as(u32, 2), extracted.syntax.variables[1].productions[0].steps[1].symbol.non_terminal);
}

test "extractTokens assigns distinct auxiliary symbols for nested repeats" {
    const item_rule = ir_rules.Rule{ .string = "item" };
    const inner_repeat = ir_rules.Rule{ .repeat = 0 };
    const pair_rule = ir_rules.Rule{ .seq = &.{ 0, 1 } };
    const outer_repeat = ir_rules.Rule{ .repeat = 2 };
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "nested-repeat",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 3,
            },
        },
        .external_tokens = &.{},
        .rules = &.{ item_rule, inner_repeat, pair_rule, outer_repeat },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 3), extracted.syntax.variables.len);
    try std.testing.expectEqualStrings("source_file_repeat1", extracted.syntax.variables[1].name);
    try std.testing.expectEqualStrings("source_file_repeat2", extracted.syntax.variables[2].name);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.variables[0].productions[0].steps[0].symbol.non_terminal);
    try std.testing.expectEqual(@as(u32, 2), extracted.syntax.variables[1].productions[2].steps[1].symbol.non_terminal);
    try std.testing.expectEqual(@as(u32, 2), extracted.syntax.variables[2].productions[1].steps[0].symbol.non_terminal);
}

test "extractTokens rejects external inline symbols" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "bad-inline",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
        },
        .external_tokens = &.{
            .{
                .name = "template_chars",
                .symbol = ir_symbols.SymbolId.external(0),
                .kind = .named,
                .rule = 1,
            },
        },
        .rules = &.{ .{ .blank = {} }, .{ .blank = {} } },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.external(0),
                .name = "template_chars",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{ir_symbols.SymbolId.external(0)},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidInlineSymbol, extractTokens(arena.allocator(), prepared));
}

test "extractTokens rejects external conflict symbols" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "bad-conflict",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
        },
        .external_tokens = &.{
            .{
                .name = "template_chars",
                .symbol = ir_symbols.SymbolId.external(0),
                .kind = .named,
                .rule = 1,
            },
        },
        .rules = &.{ .{ .blank = {} }, .{ .blank = {} } },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.external(0),
                .name = "template_chars",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{&.{ ir_symbols.SymbolId.nonTerminal(0), ir_symbols.SymbolId.external(0) }},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConflictSymbol, extractTokens(arena.allocator(), prepared));
}

test "extractTokens rejects external precedence symbols" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "bad-precedence",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
        },
        .external_tokens = &.{
            .{
                .name = "template_chars",
                .symbol = ir_symbols.SymbolId.external(0),
                .kind = .named,
                .rule = 1,
            },
        },
        .rules = &.{ .{ .blank = {} }, .{ .blank = {} } },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.external(0),
                .name = "template_chars",
                .named = true,
                .visible = true,
            },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{&.{
            prepared_ir.PrecedenceEntry{ .symbol = ir_symbols.SymbolId.external(0) },
        }},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidPrecedenceSymbol, extractTokens(arena.allocator(), prepared));
}

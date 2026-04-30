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
    repeat_cache: std.array_list.Managed(RepeatCacheEntry),
    promoted_top_level_repeat_variables: std.array_list.Managed(u32),
    symbol_replacements: []const SymbolReplacement,

    fn init(allocator: std.mem.Allocator, prepared: prepared_ir.PreparedGrammar) Extractor {
        return .{
            .allocator = allocator,
            .prepared = prepared,
            .lexical_variables = std.array_list.Managed(lexical_ir.LexicalVariable).init(allocator),
            .separators = std.array_list.Managed(ir_rules.RuleId).init(allocator),
            .auxiliary_variables = std.array_list.Managed(syntax_ir.SyntaxVariable).init(allocator),
            .repeat_cache = std.array_list.Managed(RepeatCacheEntry).init(allocator),
            .promoted_top_level_repeat_variables = std.array_list.Managed(u32).init(allocator),
            .symbol_replacements = &.{},
        };
    }

    fn extract(self: *Extractor) ExtractTokensError!ExtractedGrammars {
        const variables = try self.compactExtractedVariables(try self.extractVariables());
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
            if (self.externalTokenCorrespondingInternal(token)) |internal| {
                try result.append(.{
                    .name = self.lexical_variables.items[internal.terminal].name,
                    .kind = convertVariableKind(token.kind),
                    .corresponding_internal_token = internal,
                });
                continue;
            }

            try result.append(.{
                .name = token.name,
                .kind = convertVariableKind(token.kind),
            });
        }

        return try result.toOwnedSlice();
    }

    fn externalTokenCorrespondingInternal(self: *Extractor, token: prepared_ir.ExternalToken) ?syntax_ir.SymbolRef {
        if (self.findLexicalVariable(token.rule)) |terminal_index| {
            return .{ .terminal = terminal_index };
        }
        if (self.findEquivalentLexicalVariable(token.rule, self.lexicalKindForRule(token.rule, externalPreferredName(token.name)))) |terminal_index| {
            return .{ .terminal = terminal_index };
        }

        const rule = self.prepared.rules[@intCast(token.rule)];
        switch (rule) {
            .symbol => |symbol| switch (symbol.kind) {
                .external => return null,
                .non_terminal => {
                    const variable = self.prepared.variables[symbol.index];
                    if (self.findLexicalVariable(variable.rule)) |terminal_index| {
                        return .{ .terminal = terminal_index };
                    }
                    if (self.findEquivalentLexicalVariable(variable.rule, self.lexicalKindForRule(variable.rule, variable.name))) |terminal_index| {
                        return .{ .terminal = terminal_index };
                    }
                    return null;
                },
            },
            else => return null,
        }
    }

    fn extractWordToken(self: *Extractor) ExtractTokensError!?syntax_ir.SymbolRef {
        const word = self.prepared.word_token orelse return null;

        switch (word.kind) {
            .non_terminal => return switch (try self.replacePreparedSymbol(word)) {
                .terminal => |terminal| .{ .terminal = terminal },
                else => error.InvalidWordToken,
            },
            .external => return error.InvalidWordToken,
        }
    }

    fn extractPrecedenceSymbol(self: *Extractor, symbol: ir_symbols.SymbolId) ExtractTokensError!syntax_ir.SymbolRef {
        switch (symbol.kind) {
            .non_terminal => return try self.replacePreparedSymbol(symbol),
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

    fn compactExtractedVariables(
        self: *Extractor,
        variables: []const syntax_ir.SyntaxVariable,
    ) ExtractTokensError![]const syntax_ir.SyntaxVariable {
        const usage_counts = try self.allocator.alloc(usize, self.lexical_variables.items.len);
        @memset(usage_counts, 0);

        for (variables) |variable| {
            for (variable.productions) |production| {
                for (production.steps) |step| {
                    switch (step.symbol) {
                        .terminal => |terminal| {
                            if (terminal < usage_counts.len) usage_counts[terminal] += 1;
                        },
                        else => {},
                    }
                }
            }
        }

        const replacements = try self.allocator.alloc(SymbolReplacement, variables.len);
        var kept = std.array_list.Managed(syntax_ir.SyntaxVariable).init(self.allocator);
        defer kept.deinit();

        for (variables, 0..) |variable, index| {
            if (index > 0) {
                if (singlePlainTerminalProduction(variable)) |terminal| {
                    if (terminal < usage_counts.len and usage_counts[terminal] == 1) {
                        const lexical_variable = &self.lexical_variables.items[terminal];
                        if (lexical_variable.kind == .auxiliary or variable.kind != .hidden) {
                            lexical_variable.name = variable.name;
                            lexical_variable.kind = lexicalKindFromSyntaxKind(variable.kind);
                            replacements[index] = .{ .terminal = terminal };
                            continue;
                        }
                    }
                }
            }

            replacements[index] = .{ .non_terminal = @intCast(kept.items.len) };
            try kept.append(variable);
        }

        self.symbol_replacements = replacements;

        const remapped = try self.allocator.alloc(syntax_ir.SyntaxVariable, kept.items.len);
        for (kept.items, 0..) |variable, index| {
            remapped[index] = variable;
            remapped[index].productions = try self.remapProductions(variable.productions);
        }
        return remapped;
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
            .non_terminal => return try self.replacePreparedSymbol(symbol),
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
                try appendUniqueSymbolRef(&converted, try self.extractConflictSymbol(symbol));
            }
            std.mem.sort(syntax_ir.SymbolRef, converted.items, {}, symbolRefLessThan);

            try result.append(try converted.toOwnedSlice());
        }

        return try result.toOwnedSlice();
    }

    fn extractConflictSymbol(self: *Extractor, symbol: ir_symbols.SymbolId) ExtractTokensError!syntax_ir.SymbolRef {
        switch (symbol.kind) {
            .non_terminal => return try self.replacePreparedSymbol(symbol),
            .external => return error.InvalidConflictSymbol,
        }
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

    fn extractVariablesToInline(self: *Extractor) ExtractTokensError![]const syntax_ir.SymbolRef {
        var result = std.array_list.Managed(syntax_ir.SymbolRef).init(self.allocator);
        defer result.deinit();

        for (self.prepared.variables_to_inline) |symbol| {
            if (self.isPromotedTopLevelRepeatSymbol(symbol)) continue;
            try result.append(try self.extractInlineSymbol(symbol));
        }

        return try result.toOwnedSlice();
    }

    fn extractInlineSymbol(self: *Extractor, symbol: ir_symbols.SymbolId) ExtractTokensError!syntax_ir.SymbolRef {
        switch (symbol.kind) {
            .non_terminal => return try self.replacePreparedSymbol(symbol),
            .external => return error.InvalidInlineSymbol,
        }
    }

    fn extractSupertypeSymbols(self: *Extractor) ExtractTokensError![]const syntax_ir.SymbolRef {
        var result = std.array_list.Managed(syntax_ir.SymbolRef).init(self.allocator);
        defer result.deinit();

        for (self.prepared.supertype_symbols) |symbol| {
            switch (symbol.kind) {
                .non_terminal => switch (try self.replacePreparedSymbol(symbol)) {
                    .non_terminal => |non_terminal| try result.append(.{ .non_terminal = non_terminal }),
                    else => return error.InvalidSupertypeSymbol,
                },
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
        _ = variables;
        for (supertype_symbols) |symbol| {
            switch (symbol) {
                .non_terminal => {},
                else => return error.InvalidSupertypeSymbol,
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
        return self.extractProductionsWithLexicalName(variable_name, rule_id, variable_name, true);
    }

    fn extractNestedProductions(
        self: *Extractor,
        variable_name: []const u8,
        rule_id: ir_rules.RuleId,
        at_end: bool,
    ) ExtractTokensError![]syntax_ir.Production {
        return self.extractProductionsWithLexicalName(variable_name, rule_id, null, at_end);
    }

    fn extractProductionsWithLexicalName(
        self: *Extractor,
        variable_name: []const u8,
        rule_id: ir_rules.RuleId,
        lexical_preferred_name: ?[]const u8,
        at_end: bool,
    ) ExtractTokensError![]syntax_ir.Production {
        const lexical_name = lexical_preferred_name orelse if (self.lexicalRuleHasDirectLiteralName(rule_id)) null else variable_name;
        if (self.tryEnsureLexicalVariable(lexical_name, rule_id, lexical_preferred_name)) |terminal_index| {
            return try self.singleStepProductions(.{
                .symbol = .{ .terminal = terminal_index },
            });
        }

        const rule = self.prepared.rules[@intCast(rule_id)];
        return switch (rule) {
            .blank => try self.singleProduction(&.{}),
            // Direct symbol productions intentionally stay syntax-side. Rewriting them
            // to terminals would collapse alias and visibility boundaries that later
            // node-type computation still needs to observe.
            .symbol => |symbol| try self.singleStepProductions(.{
                .symbol = try self.convertSymbol(symbol),
            }),
            .string, .pattern => unreachable,
            .choice => |members| self.extractChoiceProductions(variable_name, members, at_end),
            .seq => |members| self.extractSequenceProductions(variable_name, members, at_end),
            .repeat => |inner| self.extractRepeatProductions(variable_name, inner, false),
            .repeat1 => |inner| self.extractRepeatProductions(variable_name, inner, true),
            .metadata => |metadata| self.extractMetadataProductions(variable_name, metadata, lexical_preferred_name, at_end),
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

    fn extractChoiceProductions(
        self: *Extractor,
        variable_name: []const u8,
        members: []const ir_rules.RuleId,
        at_end: bool,
    ) ExtractTokensError![]syntax_ir.Production {
        var result = std.array_list.Managed(syntax_ir.Production).init(self.allocator);
        defer result.deinit();

        for (members) |member| {
            const productions = try self.extractNestedProductions(variable_name, member, at_end);
            try result.appendSlice(productions);
        }

        return try result.toOwnedSlice();
    }

    fn extractSequenceProductions(
        self: *Extractor,
        variable_name: []const u8,
        members: []const ir_rules.RuleId,
        at_end: bool,
    ) ExtractTokensError![]syntax_ir.Production {
        var current = try self.singleProduction(&.{}); // one empty production

        for (members, 0..) |member, index| {
            const member_at_end = at_end and index + 1 == members.len;
            const next = try self.extractNestedProductions(variable_name, member, member_at_end);
            current = try self.combineProductionSets(current, next);
        }

        return current;
    }

    fn extractMetadataProductions(
        self: *Extractor,
        variable_name: []const u8,
        metadata: ir_rules.MetadataRule,
        lexical_preferred_name: ?[]const u8,
        at_end: bool,
    ) ExtractTokensError![]syntax_ir.Production {
        if (metadata.data.token or metadata.data.immediate_token) {
            if (self.tryEnsureLexicalVariable(lexical_preferred_name, @intCast(metadata.inner), lexical_preferred_name)) |terminal_index| {
                const productions = try self.singleStepProductions(.{
                    .symbol = .{ .terminal = terminal_index },
                });
                self.applyMetadataToProductions(productions, metadata.data, at_end);
                return productions;
            }
        }

        const productions = try self.extractProductionsWithLexicalName(variable_name, metadata.inner, lexical_preferred_name, at_end);
        self.applyMetadataToProductions(productions, metadata.data, at_end);
        return productions;
    }

    fn applyMetadataToProductions(
        self: *Extractor,
        productions: []syntax_ir.Production,
        metadata: ir_rules.Metadata,
        at_end: bool,
    ) void {
        _ = self;
        for (productions) |*production| {
            if (production.steps.len == 0) continue;
            if (metadata.field_name) |field_name| {
                for (production.steps) |*field_step| {
                    field_step.field_name = field_name;
                }
            }
            var step = &production.steps[0];
            if (metadata.alias) |alias| step.alias = alias;
            if (metadata.reserved_context_name) |context| step.reserved_context_name = context;
            if (metadata.precedence != .none) {
                for (production.steps) |*precedence_step| {
                    if (precedence_step.precedence == .none) precedence_step.precedence = metadata.precedence;
                }
                if (!at_end) production.steps[production.steps.len - 1].precedence = .none;
            }
            if (metadata.associativity != .none) {
                for (production.steps) |*associativity_step| {
                    if (associativity_step.associativity == .none) associativity_step.associativity = metadata.associativity;
                }
                if (!at_end) production.steps[production.steps.len - 1].associativity = .none;
            }
            if (metadata.dynamic_precedence != 0) production.dynamic_precedence = metadata.dynamic_precedence;
        }
    }

    fn tryEnsureLexicalVariable(
        self: *Extractor,
        preferred_name: ?[]const u8,
        rule_id: ir_rules.RuleId,
        lexical_boundary_name: ?[]const u8,
    ) ?u32 {
        if (!self.isLexicalRule(rule_id, lexical_boundary_name)) return null;
        const identity_rule_id = self.lexicalIdentityRule(rule_id);

        if (self.findLexicalVariable(identity_rule_id)) |index| return index;

        const name = self.lexicalNameForRule(identity_rule_id, preferred_name);
        const kind = self.lexicalKindForRule(identity_rule_id, preferred_name);
        if (self.findEquivalentLexicalVariable(identity_rule_id, kind)) |index| return index;
        self.lexical_variables.append(.{
            .name = name,
            .kind = kind,
            .rule = identity_rule_id,
            .source_kind = self.lexicalSourceKindForRule(identity_rule_id),
        }) catch return null;
        return @intCast(self.lexical_variables.items.len - 1);
    }

    fn findLexicalVariable(self: *Extractor, rule_id: ir_rules.RuleId) ?u32 {
        const identity_rule_id = self.lexicalIdentityRule(rule_id);
        for (self.lexical_variables.items, 0..) |variable, i| {
            if (variable.rule == identity_rule_id) return @intCast(i);
        }
        return null;
    }

    fn findEquivalentLexicalVariable(
        self: *Extractor,
        rule_id: ir_rules.RuleId,
        kind: lexical_ir.VariableKind,
    ) ?u32 {
        for (self.lexical_variables.items, 0..) |variable, i| {
            if (variable.kind != kind) continue;
            if (self.lexicalRulesEquivalent(variable.rule, rule_id)) return @intCast(i);
        }
        return null;
    }

    fn lexicalRulesEquivalent(self: *Extractor, lhs_id: ir_rules.RuleId, rhs_id: ir_rules.RuleId) bool {
        const lhs = self.prepared.rules[@intCast(self.lexicalIdentityRule(lhs_id))];
        const rhs = self.prepared.rules[@intCast(self.lexicalIdentityRule(rhs_id))];
        return switch (lhs) {
            .string => |left| switch (rhs) {
                .string => |right| std.mem.eql(u8, left, right),
                else => false,
            },
            .pattern => |left| switch (rhs) {
                .pattern => |right| std.mem.eql(u8, left.value, right.value) and optionalStringsEqual(left.flags, right.flags),
                else => false,
            },
            else => false,
        };
    }

    fn optionalStringsEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
        if (lhs == null or rhs == null) return lhs == null and rhs == null;
        return std.mem.eql(u8, lhs.?, rhs.?);
    }

    fn metadataEql(lhs: ir_rules.Metadata, rhs: ir_rules.Metadata) bool {
        return optionalStringsEqual(lhs.field_name, rhs.field_name) and
            aliasEql(lhs.alias, rhs.alias) and
            precedenceEql(lhs.precedence, rhs.precedence) and
            lhs.associativity == rhs.associativity and
            lhs.dynamic_precedence == rhs.dynamic_precedence and
            lhs.token == rhs.token and
            lhs.immediate_token == rhs.immediate_token and
            optionalStringsEqual(lhs.reserved_context_name, rhs.reserved_context_name);
    }

    fn aliasEql(lhs: ?ir_rules.Alias, rhs: ?ir_rules.Alias) bool {
        if (lhs) |left| {
            const right = rhs orelse return false;
            return left.named == right.named and std.mem.eql(u8, left.value, right.value);
        }
        return rhs == null;
    }

    fn precedenceEql(lhs: ir_rules.PrecedenceValue, rhs: ir_rules.PrecedenceValue) bool {
        return switch (lhs) {
            .none => rhs == .none,
            .integer => |left| switch (rhs) {
                .integer => |right| left == right,
                else => false,
            },
            .name => |left| switch (rhs) {
                .name => |right| std.mem.eql(u8, left, right),
                else => false,
            },
        };
    }

    fn ensureRepeatAuxiliary(
        self: *Extractor,
        variable_name: []const u8,
        inner: ir_rules.RuleId,
        at_least_one: bool,
    ) ExtractTokensError!u32 {
        for (self.repeat_cache.items) |entry| {
            if (entry.at_least_one == at_least_one and self.rulesEquivalent(entry.rule_id, inner)) {
                return entry.symbol_index;
            }
        }

        const auxiliary_index = self.auxiliary_variables.items.len;
        const symbol_index: u32 = @intCast(self.prepared.variables.len + auxiliary_index);
        try self.auxiliary_variables.append(.{
            .name = "",
            .kind = .auxiliary,
            .productions = &.{},
        });
        errdefer _ = self.auxiliary_variables.pop();
        try self.repeat_cache.append(.{
            .rule_id = inner,
            .at_least_one = at_least_one,
            .symbol_index = symbol_index,
        });
        errdefer _ = self.repeat_cache.pop();

        const inner_productions = try self.extractNestedProductions(variable_name, inner, true);
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

    fn rulesEquivalent(self: *Extractor, lhs_id: ir_rules.RuleId, rhs_id: ir_rules.RuleId) bool {
        if (lhs_id == rhs_id) return true;
        const lhs = self.prepared.rules[@intCast(lhs_id)];
        const rhs = self.prepared.rules[@intCast(rhs_id)];
        return switch (lhs) {
            .blank => rhs == .blank,
            .string => |left| switch (rhs) {
                .string => |right| std.mem.eql(u8, left, right),
                else => false,
            },
            .pattern => |left| switch (rhs) {
                .pattern => |right| std.mem.eql(u8, left.value, right.value) and optionalStringsEqual(left.flags, right.flags),
                else => false,
            },
            .symbol => |left| switch (rhs) {
                .symbol => |right| left.kind == right.kind and left.index == right.index,
                else => false,
            },
            .choice => |left| switch (rhs) {
                .choice => |right| self.ruleListsEquivalent(left, right),
                else => false,
            },
            .seq => |left| switch (rhs) {
                .seq => |right| self.ruleListsEquivalent(left, right),
                else => false,
            },
            .repeat => |left| switch (rhs) {
                .repeat => |right| self.rulesEquivalent(left, right),
                else => false,
            },
            .repeat1 => |left| switch (rhs) {
                .repeat1 => |right| self.rulesEquivalent(left, right),
                else => false,
            },
            .metadata => |left| switch (rhs) {
                .metadata => |right| self.rulesEquivalent(left.inner, right.inner) and metadataEql(left.data, right.data),
                else => false,
            },
        };
    }

    fn ruleListsEquivalent(self: *Extractor, lhs: []const ir_rules.RuleId, rhs: []const ir_rules.RuleId) bool {
        if (lhs.len != rhs.len) return false;
        for (lhs, rhs) |left_id, right_id| {
            if (!self.rulesEquivalent(left_id, right_id)) return false;
        }
        return true;
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

    fn remapProductions(
        self: *Extractor,
        productions: []const syntax_ir.Production,
    ) ExtractTokensError![]syntax_ir.Production {
        const remapped = try self.allocator.alloc(syntax_ir.Production, productions.len);
        for (productions, 0..) |production, production_index| {
            remapped[production_index] = production;
            const steps = try self.allocator.alloc(syntax_ir.ProductionStep, production.steps.len);
            for (production.steps, 0..) |step, step_index| {
                steps[step_index] = step;
                steps[step_index].symbol = try self.replaceSyntaxSymbol(step.symbol);
            }
            remapped[production_index].steps = steps;
        }
        return remapped;
    }

    fn replacePreparedSymbol(
        self: *Extractor,
        symbol: ir_symbols.SymbolId,
    ) ExtractTokensError!syntax_ir.SymbolRef {
        return try self.replaceSyntaxSymbol(switch (symbol.kind) {
            .non_terminal => .{ .non_terminal = symbol.index },
            .external => .{ .external = symbol.index },
        });
    }

    fn replaceSyntaxSymbol(
        self: *Extractor,
        symbol: syntax_ir.SymbolRef,
    ) ExtractTokensError!syntax_ir.SymbolRef {
        switch (symbol) {
            .non_terminal => |index| {
                if (index >= self.symbol_replacements.len) return error.UnsupportedRuleShape;
                return switch (self.symbol_replacements[index]) {
                    .non_terminal => |replacement| .{ .non_terminal = replacement },
                    .terminal => |replacement| .{ .terminal = replacement },
                };
            },
            else => return symbol,
        }
    }

    fn isLexicalRule(self: *Extractor, rule_id: ir_rules.RuleId, lexical_boundary_name: ?[]const u8) bool {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string, .pattern => true,
            .blank => false,
            .metadata => |metadata| (metadata.data.token or metadata.data.immediate_token) and self.isTokenContentRule(metadata.inner),
            .seq, .choice => if (lexical_boundary_name) |name|
                !std.mem.eql(u8, name, "source_file") and
                    !isHiddenName(name) and
                    self.isTokenContentRule(rule_id) and
                    self.tokenContentContainsPattern(rule_id) and
                    !self.tokenContentContainsString(rule_id)
            else
                false,
            else => false,
        };
    }

    fn isTokenContentRule(self: *Extractor, rule_id: ir_rules.RuleId) bool {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string, .pattern => true,
            .choice => |members| blk: {
                for (members) |member| {
                    if (!self.isTokenContentRule(member)) break :blk false;
                }
                break :blk true;
            },
            .seq => |members| blk: {
                for (members) |member| {
                    if (!self.isTokenContentRule(member)) break :blk false;
                }
                break :blk true;
            },
            .repeat, .repeat1 => |inner| self.isTokenContentRule(inner),
            .metadata => |metadata| self.isTokenContentRule(metadata.inner),
            .blank => true,
            .symbol => false,
        };
    }

    fn lexicalRuleHasDirectLiteralName(self: *Extractor, rule_id: ir_rules.RuleId) bool {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string, .pattern => true,
            .metadata => |metadata| self.lexicalRuleHasDirectLiteralName(metadata.inner),
            else => false,
        };
    }

    fn tokenContentContainsPattern(self: *Extractor, rule_id: ir_rules.RuleId) bool {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .pattern => true,
            .choice, .seq => |members| blk: {
                for (members) |member| {
                    if (self.tokenContentContainsPattern(member)) break :blk true;
                }
                break :blk false;
            },
            .repeat, .repeat1 => |inner| self.tokenContentContainsPattern(inner),
            .metadata => |metadata| self.tokenContentContainsPattern(metadata.inner),
            else => false,
        };
    }

    fn tokenContentContainsString(self: *Extractor, rule_id: ir_rules.RuleId) bool {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string => true,
            .choice, .seq => |members| blk: {
                for (members) |member| {
                    if (self.tokenContentContainsString(member)) break :blk true;
                }
                break :blk false;
            },
            .repeat, .repeat1 => |inner| self.tokenContentContainsString(inner),
            .metadata => |metadata| self.tokenContentContainsString(metadata.inner),
            else => false,
        };
    }

    fn lexicalNameForRule(self: *Extractor, rule_id: ir_rules.RuleId, preferred_name: ?[]const u8) []const u8 {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string => |value| value,
            .pattern => |pattern| if (preferred_name) |name|
                if (shouldUseLiteralLexicalName(name)) pattern.value else name
            else
                pattern.value,
            .metadata => |metadata| if (metadata.data.token or metadata.data.immediate_token)
                if (metadata.data.alias) |alias| alias.value else self.lexicalNameForRule(metadata.inner, preferred_name)
            else
                self.lexicalNameForRule(metadata.inner, preferred_name),
            else => preferred_name.?,
        };
    }

    fn lexicalKindForRule(self: *Extractor, rule_id: ir_rules.RuleId, preferred_name: ?[]const u8) lexical_ir.VariableKind {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string => .anonymous,
            .pattern => if (preferred_name) |name|
                if (shouldUseLiteralLexicalName(name)) .anonymous else .named
            else
                .anonymous,
            .metadata => |metadata| if (metadata.data.token or metadata.data.immediate_token)
                if (metadata.data.alias) |alias| lexicalKindFromAlias(alias) else self.lexicalKindForRule(metadata.inner, preferred_name)
            else
                self.lexicalKindForRule(metadata.inner, preferred_name),
            else => .named,
        };
    }

    fn lexicalSourceKindForRule(self: *Extractor, rule_id: ir_rules.RuleId) lexical_ir.SourceKind {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .string => .string,
            .pattern => .pattern,
            .metadata => |metadata| if (metadata.data.token or metadata.data.immediate_token)
                .token
            else
                self.lexicalSourceKindForRule(metadata.inner),
            else => .composite,
        };
    }

    fn lexicalIdentityRule(self: *Extractor, rule_id: ir_rules.RuleId) ir_rules.RuleId {
        return switch (self.prepared.rules[@intCast(rule_id)]) {
            .metadata => |metadata| if (metadata.data.token and metadataCanUseInnerTokenIdentity(metadata.data))
                self.lexicalIdentityRule(metadata.inner)
            else
                rule_id,
            else => rule_id,
        };
    }
};

fn metadataCanUseInnerTokenIdentity(metadata: ir_rules.Metadata) bool {
    return metadata.field_name == null and
        metadata.alias == null and
        metadata.precedence == .none and
        metadata.associativity == .none and
        metadata.dynamic_precedence == 0 and
        metadata.token and
        !metadata.immediate_token and
        metadata.reserved_context_name == null;
}

fn externalPreferredName(name: []const u8) ?[]const u8 {
    return if (name.len == 0) null else name;
}

fn convertVariableKind(kind: prepared_ir.VariableKind) syntax_ir.VariableKind {
    return switch (kind) {
        .named => .named,
        .hidden => .hidden,
        .anonymous => .anonymous,
        .auxiliary => .auxiliary,
    };
}

fn shouldUseLiteralLexicalName(preferred_name: []const u8) bool {
    return std.mem.eql(u8, preferred_name, "source_file") or isHiddenName(preferred_name);
}

fn isHiddenName(name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

const RepeatCacheEntry = struct {
    rule_id: ir_rules.RuleId,
    at_least_one: bool,
    symbol_index: u32,
};

const TopLevelRepeatInfo = struct {
    inner: ir_rules.RuleId,
    at_least_one: bool,
};

const SymbolReplacement = union(enum) {
    non_terminal: u32,
    terminal: u32,
};

fn lexicalKindFromSyntaxKind(kind: syntax_ir.VariableKind) lexical_ir.VariableKind {
    return switch (kind) {
        .named => .named,
        .hidden => .hidden,
        .anonymous => .anonymous,
        .auxiliary => .auxiliary,
    };
}

fn lexicalKindFromAlias(alias: ir_rules.Alias) lexical_ir.VariableKind {
    return if (alias.named) .named else .anonymous;
}

fn singlePlainTerminalProduction(variable: syntax_ir.SyntaxVariable) ?u32 {
    if (variable.productions.len != 1) return null;
    const production = variable.productions[0];
    if (production.dynamic_precedence != 0) return null;
    if (production.steps.len != 1) return null;
    const step = production.steps[0];
    if (step.alias != null) return null;
    if (step.field_name != null) return null;
    if (step.field_inherited) return null;
    if (step.precedence != .none) return null;
    if (step.associativity != .none) return null;
    if (step.reserved_context_name != null) return null;
    return switch (step.symbol) {
        .terminal => |terminal| terminal,
        else => null,
    };
}

fn appendUniqueSymbolRef(
    symbols: *std.array_list.Managed(syntax_ir.SymbolRef),
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error!void {
    for (symbols.items) |existing| {
        if (symbolRefEql(existing, symbol)) return;
    }
    try symbols.append(symbol);
}

fn symbolRefEql(left: syntax_ir.SymbolRef, right: syntax_ir.SymbolRef) bool {
    return switch (left) {
        .end => right == .end,
        .non_terminal => |left_index| switch (right) {
            .non_terminal => |right_index| left_index == right_index,
            else => false,
        },
        .terminal => |left_index| switch (right) {
            .terminal => |right_index| left_index == right_index,
            else => false,
        },
        .external => |left_index| switch (right) {
            .external => |right_index| left_index == right_index,
            else => false,
        },
    };
}

fn symbolRefLessThan(_: void, left: syntax_ir.SymbolRef, right: syntax_ir.SymbolRef) bool {
    return symbolRefSortKey(left) < symbolRefSortKey(right);
}

fn symbolRefSortKey(symbol: syntax_ir.SymbolRef) u64 {
    return switch (symbol) {
        .end => 0,
        .terminal => |index| 1_000_000 + index,
        .external => |index| 2_000_000 + index,
        .non_terminal => |index| 3_000_000 + index,
    };
}

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

    try std.testing.expectEqual(@as(usize, 2), extracted.syntax.variables.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.external_tokens.len);
    try std.testing.expectEqualStrings("indent", extracted.syntax.external_tokens[0].name);
    try std.testing.expectEqual(syntax_ir.VariableKind.named, extracted.syntax.external_tokens[0].kind);
    try std.testing.expectEqual(@as(usize, 2), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("x", extracted.lexical.variables[0].name);
    try std.testing.expectEqual(lexical_ir.VariableKind.anonymous, extracted.lexical.variables[0].kind);
    try std.testing.expectEqualStrings("term", extracted.lexical.variables[1].name);
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.separators.len);
    try std.testing.expectEqual(@as(usize, 0), extracted.syntax.extra_symbols.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables_to_inline.len);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.variables_to_inline[0].terminal);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.expected_conflicts.len);
    try std.testing.expectEqual(@as(usize, 2), extracted.syntax.expected_conflicts[0].len);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.expected_conflicts[0][0].terminal);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.expected_conflicts[0][1].non_terminal);
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

test "extractTokens propagates final precedence across multi-step productions" {
    const top_seq = [_]ir_rules.RuleId{ 1, 2 };
    const inner_seq = [_]ir_rules.RuleId{ 5, 6 };
    const outer_seq = [_]ir_rules.RuleId{ 4, 7 };
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "final-precedence",
        .variables = &.{
            .{ .name = "source_file", .symbol = ir_symbols.SymbolId.nonTerminal(0), .kind = .named, .rule = 0 },
            .{ .name = "left", .symbol = ir_symbols.SymbolId.nonTerminal(1), .kind = .named, .rule = 8 },
            .{ .name = "right", .symbol = ir_symbols.SymbolId.nonTerminal(2), .kind = .named, .rule = 8 },
            .{ .name = "tail", .symbol = ir_symbols.SymbolId.nonTerminal(3), .kind = .named, .rule = 8 },
            .{ .name = "wrapped", .symbol = ir_symbols.SymbolId.nonTerminal(4), .kind = .named, .rule = 10 },
        },
        .external_tokens = &.{},
        .rules = &.{
            .{ .metadata = .{ .inner = 3, .data = .{ .precedence = .{ .name = "outer" }, .associativity = .left } } },
            .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) },
            .{ .symbol = ir_symbols.SymbolId.nonTerminal(2) },
            .{ .seq = top_seq[0..] },
            .{ .metadata = .{ .inner = 9, .data = .{ .precedence = .{ .name = "inner" }, .associativity = .right } } },
            .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) },
            .{ .symbol = ir_symbols.SymbolId.nonTerminal(2) },
            .{ .symbol = ir_symbols.SymbolId.nonTerminal(3) },
            .{ .blank = {} },
            .{ .seq = inner_seq[0..] },
            .{ .seq = outer_seq[0..] },
        },
        .symbols = &.{
            .{ .id = ir_symbols.SymbolId.nonTerminal(0), .name = "source_file", .named = true, .visible = true },
            .{ .id = ir_symbols.SymbolId.nonTerminal(1), .name = "left", .named = true, .visible = true },
            .{ .id = ir_symbols.SymbolId.nonTerminal(2), .name = "right", .named = true, .visible = true },
            .{ .id = ir_symbols.SymbolId.nonTerminal(3), .name = "tail", .named = true, .visible = true },
            .{ .id = ir_symbols.SymbolId.nonTerminal(4), .name = "wrapped", .named = true, .visible = true },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{&.{
            prepared_ir.PrecedenceEntry{ .name = "inner" },
            prepared_ir.PrecedenceEntry{ .name = "outer" },
        }},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    const source_steps = extracted.syntax.variables[0].productions[0].steps;
    try std.testing.expectEqual(@as(usize, 2), source_steps.len);
    try std.testing.expectEqualStrings("outer", source_steps[0].precedence.name);
    try std.testing.expectEqualStrings("outer", source_steps[1].precedence.name);
    try std.testing.expectEqual(ir_rules.Assoc.left, source_steps[0].associativity);
    try std.testing.expectEqual(ir_rules.Assoc.left, source_steps[1].associativity);

    const wrapped_steps = extracted.syntax.variables[4].productions[0].steps;
    try std.testing.expectEqual(@as(usize, 3), wrapped_steps.len);
    try std.testing.expectEqualStrings("inner", wrapped_steps[0].precedence.name);
    try std.testing.expect(wrapped_steps[1].precedence == .none);
    try std.testing.expect(wrapped_steps[2].precedence == .none);
    try std.testing.expectEqual(ir_rules.Assoc.right, wrapped_steps[0].associativity);
    try std.testing.expectEqual(ir_rules.Assoc.none, wrapped_steps[1].associativity);
    try std.testing.expectEqual(ir_rules.Assoc.none, wrapped_steps[2].associativity);
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
        .rules = &.{ .{ .blank = {} }, .{ .blank = {} }, .{ .blank = {} } },
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
    try std.testing.expect(extracted.syntax.external_tokens[0].corresponding_internal_token == null);
    try std.testing.expectEqualStrings("template_chars", extracted.syntax.external_tokens[1].name);
    try std.testing.expectEqual(syntax_ir.VariableKind.named, extracted.syntax.external_tokens[1].kind);
    try std.testing.expect(extracted.syntax.external_tokens[1].corresponding_internal_token == null);
}

test "extractTokens records external token corresponding internal terminal" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "external-internal",
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
                .name = "",
                .symbol = ir_symbols.SymbolId.external(0),
                .kind = .anonymous,
                .rule = 2,
            },
        },
        .rules = &.{
            .{ .seq = &.{1} },
            .{ .string = "||" },
            .{ .string = "||" },
        },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.external(0),
                .name = "",
                .named = false,
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
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("||", extracted.lexical.variables[0].name);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.external_tokens.len);
    try std.testing.expectEqualStrings("||", extracted.syntax.external_tokens[0].name);
    try std.testing.expectEqual(syntax_ir.VariableKind.anonymous, extracted.syntax.external_tokens[0].kind);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .terminal = 0 }, extracted.syntax.external_tokens[0].corresponding_internal_token.?);
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
        .supertype_symbols = &.{ir_symbols.SymbolId.external(0)},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidSupertypeSymbol, extractTokens(arena.allocator(), prepared));
}

test "extractTokens allows supertypes that lower to external steps" {
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

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.supertype_symbols.len);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.supertype_symbols[0].non_terminal);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables[1].productions.len);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.variables[1].productions[0].steps[0].symbol.external);
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

test "extractTokens accepts word tokens backed by tokenized composite lexical rules" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "tokenized-composite-word-token",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
            .{
                .name = "identifier",
                .symbol = ir_symbols.SymbolId.nonTerminal(1),
                .kind = .named,
                .rule = 6,
            },
        },
        .external_tokens = &.{},
        .rules = &.{
            .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) },
            .{ .pattern = .{ .value = "[a-zA-Z_]", .flags = null } },
            .{ .pattern = .{ .value = "[0-9]", .flags = null } },
            .{ .choice = &.{ 1, 2 } },
            .{ .repeat = 3 },
            .{ .seq = &.{ 1, 4 } },
            .{ .metadata = .{
                .inner = 5,
                .data = .{
                    .token = true,
                },
            } },
        },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.nonTerminal(1),
                .name = "identifier",
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

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expect(extracted.syntax.word_token != null);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.word_token.?.terminal);
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("identifier", extracted.lexical.variables[0].name);
    try std.testing.expectEqual(@as(u32, 5), extracted.lexical.variables[0].rule);
}

test "extractTokens accepts blank alternatives inside tokenized lexical rules" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "tokenized-optional-tail",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 0,
            },
            .{
                .name = "number",
                .symbol = ir_symbols.SymbolId.nonTerminal(1),
                .kind = .named,
                .rule = 5,
            },
        },
        .external_tokens = &.{},
        .rules = &.{
            .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) },
            .{ .pattern = .{ .value = "[1-9]", .flags = null } },
            .{ .pattern = .{ .value = "[0-9]", .flags = null } },
            .blank,
            .{ .choice = &.{ 2, 3 } },
            .{ .metadata = .{
                .inner = 6,
                .data = .{
                    .token = true,
                },
            } },
            .{ .seq = &.{ 1, 4 } },
        },
        .symbols = &.{
            .{
                .id = ir_symbols.SymbolId.nonTerminal(0),
                .name = "source_file",
                .named = true,
                .visible = true,
            },
            .{
                .id = ir_symbols.SymbolId.nonTerminal(1),
                .name = "number",
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
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("number", extracted.lexical.variables[0].name);
    try std.testing.expectEqual(@as(u32, 6), extracted.lexical.variables[0].rule);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables[0].productions[0].steps.len);
    switch (extracted.syntax.variables[0].productions[0].steps[0].symbol) {
        .terminal => |terminal| try std.testing.expectEqual(@as(u32, 0), terminal),
        else => return error.TestUnexpectedResult,
    }
}

test "extractTokens reuses equivalent literal lexical variables" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "duplicate-literals",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 7,
            },
        },
        .external_tokens = &.{},
        .rules = &.{
            .{ .string = "\"" },
            .{ .string = "\"" },
            .{ .string = "\"" },
            .{ .string = "\"" },
            .{ .string = "content" },
            .{ .seq = &.{ 0, 1 } },
            .{ .seq = &.{ 2, 4, 3 } },
            .{ .choice = &.{ 5, 6 } },
        },
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
    try std.testing.expectEqual(@as(usize, 2), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("\"", extracted.lexical.variables[0].name);
    try std.testing.expectEqualStrings("content", extracted.lexical.variables[1].name);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.variables[0].productions[0].steps[0].symbol.terminal);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.variables[0].productions[0].steps[1].symbol.terminal);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.variables[0].productions[1].steps[0].symbol.terminal);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.variables[0].productions[1].steps[1].symbol.terminal);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.variables[0].productions[1].steps[2].symbol.terminal);
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
    const repeat_rule_one = ir_rules.Rule{ .repeat1 = 0 };
    const repeat_rule_two = ir_rules.Rule{ .repeat1 = 0 };
    const seq_one = ir_rules.Rule{ .seq = &.{ 0, 1 } };
    const seq_two = ir_rules.Rule{ .seq = &.{ 0, 2 } };
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "dedup-repeat",
        .variables = &.{
            .{
                .name = "left",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 3,
            },
            .{
                .name = "right",
                .symbol = ir_symbols.SymbolId.nonTerminal(1),
                .kind = .named,
                .rule = 4,
            },
        },
        .external_tokens = &.{},
        .rules = &.{ terminal_rule, repeat_rule_one, repeat_rule_two, seq_one, seq_two },
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

test "extractTokens keeps deterministic auxiliary naming for mixed repeat choice and sequence shapes" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var extract_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer extract_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.repeatChoiceSeqGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw_grammar = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw_grammar);
    const extracted = try extractTokens(extract_arena.allocator(), prepared);

    try std.testing.expectEqual(@as(usize, 5), extracted.syntax.variables.len);
    try std.testing.expectEqualStrings("source_file", extracted.syntax.variables[0].name);
    try std.testing.expectEqualStrings("_entry", extracted.syntax.variables[1].name);
    try std.testing.expectEqualStrings("source_file_repeat4", extracted.syntax.variables[2].name);
    try std.testing.expectEqualStrings("_entry_repeat5", extracted.syntax.variables[3].name);
    try std.testing.expectEqualStrings("_entry_repeat6", extracted.syntax.variables[4].name);

    try std.testing.expectEqual(@as(u32, 2), extracted.syntax.variables[0].productions[0].steps[0].symbol.non_terminal);
    try std.testing.expectEqual(@as(u32, 3), extracted.syntax.variables[1].productions[0].steps[1].symbol.non_terminal);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables[1].productions[1].steps.len);
    try std.testing.expectEqual(@as(u32, 4), extracted.syntax.variables[1].productions[2].steps[1].symbol.non_terminal);
    try std.testing.expectEqual(@as(u32, 3), extracted.syntax.variables[3].productions[0].steps[1].symbol.non_terminal);
    try std.testing.expectEqual(@as(u32, 4), extracted.syntax.variables[4].productions[0].steps[1].symbol.non_terminal);
}

test "extractTokens rewrites tokenized inline symbols to extracted terminals" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "inline-token-rewrite",
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
        .precedence_orderings = &.{},
        .variables_to_inline = &.{ir_symbols.SymbolId.nonTerminal(1)},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables_to_inline.len);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.variables_to_inline[0].terminal);
}

test "extractTokens replaces direct symbol productions for single-use tokenized rules" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "direct-symbol-boundary",
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
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("term", extracted.lexical.variables[0].name);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.variables[0].productions[0].steps[0].symbol.terminal);
}

test "extractTokens preserves aliases when replacing tokenized symbol productions" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "aliased-symbol-boundary",
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
                .rule = 2,
            },
        },
        .external_tokens = &.{},
        .rules = &.{
            .{ .metadata = .{
                .inner = 1,
                .data = .{
                    .alias = .{ .value = "rhs", .named = true },
                },
            } },
            .{ .symbol = ir_symbols.SymbolId.nonTerminal(1) },
            .{ .string = "x" },
        },
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
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const extracted = try extractTokens(arena.allocator(), prepared);
    try std.testing.expectEqual(@as(usize, 1), extracted.syntax.variables.len);
    const step = extracted.syntax.variables[0].productions[0].steps[0];
    try std.testing.expectEqual(@as(u32, 0), step.symbol.terminal);
    try std.testing.expect(step.alias != null);
    try std.testing.expectEqualStrings("rhs", step.alias.?.value);
}

test "extractTokens uses token aliases as lexical symbol identity" {
    const prepared = prepared_ir.PreparedGrammar{
        .grammar_name = "aliased-token-identity",
        .variables = &.{
            .{
                .name = "source_file",
                .symbol = ir_symbols.SymbolId.nonTerminal(0),
                .kind = .named,
                .rule = 7,
            },
        },
        .external_tokens = &.{},
        .rules = &.{
            .{ .string = "static" },
            .{ .pattern = .{ .value = "\\s+", .flags = null } },
            .{ .string = "get" },
            .{ .pattern = .{ .value = "\\s*\\n", .flags = null } },
            .{ .seq = &.{ 0, 1, 2, 3 } },
            .{ .metadata = .{
                .inner = 4,
                .data = .{
                    .token = true,
                    .alias = .{ .value = "static get", .named = false },
                },
            } },
            .{ .string = "(" },
            .{ .seq = &.{ 5, 6 } },
        },
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
    try std.testing.expectEqual(@as(usize, 2), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("static get", extracted.lexical.variables[0].name);
    try std.testing.expectEqual(lexical_ir.VariableKind.anonymous, extracted.lexical.variables[0].kind);
    try std.testing.expectEqual(lexical_ir.SourceKind.token, extracted.lexical.variables[0].source_kind);
    try std.testing.expectEqual(@as(u32, 0), extracted.syntax.variables[0].productions[0].steps[0].symbol.terminal);
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

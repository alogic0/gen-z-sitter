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

    fn init(allocator: std.mem.Allocator, prepared: prepared_ir.PreparedGrammar) Extractor {
        return .{
            .allocator = allocator,
            .prepared = prepared,
            .lexical_variables = std.array_list.Managed(lexical_ir.LexicalVariable).init(allocator),
            .separators = std.array_list.Managed(ir_rules.RuleId).init(allocator),
            .auxiliary_variables = std.array_list.Managed(syntax_ir.SyntaxVariable).init(allocator),
            .repeat_cache = std.AutoHashMap(RepeatKey, u32).init(allocator),
        };
    }

    fn extract(self: *Extractor) ExtractTokensError!ExtractedGrammars {
        const variables = try self.extractVariables();
        const extra_symbols = try self.extractExtraSymbols();
        const expected_conflicts = try self.convertConflictSets();
        const precedence_orderings = try self.convertPrecedenceOrderings();
        const variables_to_inline = try self.convertSymbolList(self.prepared.variables_to_inline);
        const supertype_symbols = try self.convertSymbolList(self.prepared.supertype_symbols);
        const word_token = if (self.prepared.word_token) |word| try self.convertSymbol(word) else null;

        return .{
            .syntax = .{
                .variables = variables,
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

    fn extractVariables(self: *Extractor) ExtractTokensError![]const syntax_ir.SyntaxVariable {
        var result = std.array_list.Managed(syntax_ir.SyntaxVariable).init(self.allocator);
        defer result.deinit();

        for (self.prepared.variables) |variable| {
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
                .symbol => |symbol| try result.append(try self.convertSymbol(symbol)),
                else => try self.separators.append(rule_id),
            }
        }

        return try result.toOwnedSlice();
    }

    fn convertConflictSets(self: *Extractor) ExtractTokensError![]const []const syntax_ir.SymbolRef {
        var result = std.array_list.Managed([]const syntax_ir.SymbolRef).init(self.allocator);
        defer result.deinit();

        for (self.prepared.expected_conflicts) |conflict_set| {
            try result.append(try self.convertSymbolList(conflict_set));
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
                    .symbol => |symbol| .{ .symbol = try self.convertSymbol(symbol) },
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
        self.lexical_variables.append(.{
            .name = name,
            .kind = .named,
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

        const symbol_index: u32 = @intCast(self.prepared.variables.len + self.auxiliary_variables.items.len);
        const inner_productions = try self.extractProductions(variable_name, inner);
        const expansion = try expand_repeats.createRepeatAuxiliary(
            self.allocator,
            variable_name,
            symbol_index,
            inner_productions,
            at_least_one,
        );
        try self.auxiliary_variables.append(expansion.variable);
        try self.repeat_cache.put(key, symbol_index);
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
            .string => |value| if (std.mem.eql(u8, preferred_name, "source_file")) value else preferred_name,
            .pattern => |pattern| if (std.mem.eql(u8, preferred_name, "source_file")) pattern.value else preferred_name,
            .metadata => |metadata| self.lexicalNameForRule(metadata.inner, preferred_name),
            else => preferred_name,
        };
    }
};

const RepeatKey = struct {
    rule_id: ir_rules.RuleId,
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
    try std.testing.expectEqual(@as(usize, 2), extracted.lexical.variables.len);
    try std.testing.expectEqualStrings("expr", extracted.lexical.variables[0].name);
    try std.testing.expectEqualStrings("term", extracted.lexical.variables[1].name);
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.separators.len);
    try std.testing.expectEqual(@as(usize, 0), extracted.syntax.extra_symbols.len);
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
    try std.testing.expectEqualStrings("source_file", extracted.syntax.variables[0].name);
    try std.testing.expectEqualStrings("source_file_repeat1", extracted.syntax.variables[1].name);
    try std.testing.expectEqual(@as(u32, 1), extracted.syntax.variables[0].productions[0].steps[0].symbol.non_terminal);
    try std.testing.expectEqual(@as(usize, 1), extracted.lexical.variables.len);
}

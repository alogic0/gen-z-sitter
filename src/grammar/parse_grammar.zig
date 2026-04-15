const std = @import("std");
const raw = @import("raw_grammar.zig");
const normalize = @import("normalize.zig");
const ir_symbols = @import("../ir/symbols.zig");
const ir_rules = @import("../ir/rules.zig");
const ir = @import("../ir/grammar_ir.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const ParseGrammarError = error{
    HiddenStartRule,
    UndefinedSymbol,
    UndefinedSupertype,
    UndefinedConflict,
    UndefinedWordToken,
    UndeclaredPrecedence,
    ConflictingPrecedenceOrdering,
    OutOfMemory,
};

pub fn parseRawGrammar(allocator: std.mem.Allocator, grammar: *const raw.RawGrammar) ParseGrammarError!ir.PreparedGrammar {
    var builder = Builder.init(allocator, grammar);
    return builder.build();
}

const Builder = struct {
    allocator: std.mem.Allocator,
    grammar: *const raw.RawGrammar,
    lowered_rules: std.array_list.Managed(ir_rules.Rule),

    fn init(allocator: std.mem.Allocator, grammar: *const raw.RawGrammar) Builder {
        return .{
            .allocator = allocator,
            .grammar = grammar,
            .lowered_rules = std.array_list.Managed(ir_rules.Rule).init(allocator),
        };
    }

    fn build(self: *Builder) ParseGrammarError!ir.PreparedGrammar {
        if (self.grammar.rules.len > 0 and isHidden(self.grammar.rules[0].name)) {
            return error.HiddenStartRule;
        }

        try self.validatePrecedences();

        var symbols = try self.buildSymbols();
        var variables = try self.buildVariables();
        const external_tokens = try self.buildExternalTokens();
        const extra_rules = try self.lowerRuleList(self.grammar.extras);
        const expected_conflicts = try normalize.normalizeConflictSets(self.allocator, try self.resolveConflicts());
        const precedence_orderings = try self.resolvePrecedences();
        const variables_to_inline = try normalize.normalizeSymbolList(self.allocator, try self.resolveInlineRules());
        const supertype_symbols = try normalize.normalizeSymbolList(self.allocator, try self.resolveSupertypes());
        const word_token = try self.resolveWordToken();
        const reserved_word_sets = try normalize.normalizeReservedWordSets(self.allocator, try self.resolveReservedWordSets());

        for (supertype_symbols) |symbol| {
            symbols[self.symbolTableIndex(symbol)].supertype = true;
            if (symbol.kind == .non_terminal) {
                variables[@intCast(symbol.index)].kind = .hidden;
                symbols[self.symbolTableIndex(symbol)].visible = false;
            }
        }

        return .{
            .grammar_name = self.grammar.name,
            .variables = variables,
            .external_tokens = external_tokens,
            .rules = try self.lowered_rules.toOwnedSlice(),
            .symbols = symbols,
            .extra_rules = extra_rules,
            .expected_conflicts = expected_conflicts,
            .precedence_orderings = precedence_orderings,
            .variables_to_inline = variables_to_inline,
            .supertype_symbols = supertype_symbols,
            .word_token = word_token,
            .reserved_word_sets = reserved_word_sets,
        };
    }

    fn validatePrecedences(self: *Builder) ParseGrammarError!void {
        var declared = std.StringHashMap(void).init(self.allocator);
        defer declared.deinit();

        var pairs = std.array_list.Managed(PrecedencePairOrdering).init(self.allocator);
        defer pairs.deinit();

        for (self.grammar.precedences) |ordering| {
            for (ordering) |entry| {
                switch (entry.*) {
                    .string => |name| try declared.put(name, {}),
                    else => {},
                }
            }
            try validatePrecedenceOrderingPairs(&pairs, ordering);
        }

        for (self.grammar.rules) |entry| {
            try self.validateRulePrecedences(entry.rule, &declared);
        }
        for (self.grammar.externals) |entry| {
            try self.validateRulePrecedences(entry, &declared);
        }
        for (self.grammar.extras) |entry| {
            try self.validateRulePrecedences(entry, &declared);
        }
        for (self.grammar.reserved) |reserved_set| {
            for (reserved_set.members) |member| {
                try self.validateRulePrecedences(member, &declared);
            }
        }
    }

    fn validateRulePrecedences(
        self: *Builder,
        rule: *const raw.RawRule,
        declared: *const std.StringHashMap(void),
    ) ParseGrammarError!void {
        switch (rule.*) {
            .alias => |alias| try self.validateRulePrecedences(alias.content, declared),
            .field => |field| try self.validateRulePrecedences(field.content, declared),
            .choice => |members| for (members) |member| try self.validateRulePrecedences(member, declared),
            .seq => |members| for (members) |member| try self.validateRulePrecedences(member, declared),
            .repeat => |inner| try self.validateRulePrecedences(inner, declared),
            .repeat1 => |inner| try self.validateRulePrecedences(inner, declared),
            .prec_dynamic => |prec| try self.validateRulePrecedences(prec.content, declared),
            .prec_left => |prec| {
                try validatePrecedenceValueDeclared(prec.value, declared);
                try self.validateRulePrecedences(prec.content, declared);
            },
            .prec_right => |prec| {
                try validatePrecedenceValueDeclared(prec.value, declared);
                try self.validateRulePrecedences(prec.content, declared);
            },
            .prec => |prec| {
                try validatePrecedenceValueDeclared(prec.value, declared);
                try self.validateRulePrecedences(prec.content, declared);
            },
            .token => |inner| try self.validateRulePrecedences(inner, declared),
            .immediate_token => |inner| try self.validateRulePrecedences(inner, declared),
            .reserved => |reserved| try self.validateRulePrecedences(reserved.content, declared),
            .blank, .string, .pattern, .symbol => {},
        }
    }

    fn buildSymbols(self: *Builder) ParseGrammarError![]ir_symbols.SymbolInfo {
        var result = std.array_list.Managed(ir_symbols.SymbolInfo).init(self.allocator);
        defer result.deinit();

        for (self.grammar.rules, 0..) |entry, i| {
            try result.append(.{
                .id = ir_symbols.SymbolId.nonTerminal(i),
                .name = entry.name,
                .named = !isHidden(entry.name),
                .visible = !isHidden(entry.name),
            });
        }

        for (self.grammar.externals, 0..) |external_rule, i| {
            const external_name = switch (external_rule.*) {
                .symbol => |name| name,
                else => "",
            };
            try result.append(.{
                .id = ir_symbols.SymbolId.external(i),
                .name = external_name,
                .named = external_name.len != 0 and !isHidden(external_name),
                .visible = external_name.len != 0 and !isHidden(external_name),
            });
        }

        return try result.toOwnedSlice();
    }

    fn buildVariables(self: *Builder) ParseGrammarError![]ir.Variable {
        var result = std.array_list.Managed(ir.Variable).init(self.allocator);
        defer result.deinit();

        for (self.grammar.rules, 0..) |entry, i| {
            try result.append(.{
                .name = entry.name,
                .symbol = ir_symbols.SymbolId.nonTerminal(i),
                .kind = variableKindForName(entry.name),
                .rule = try self.lowerRule(entry.rule),
            });
        }

        return try result.toOwnedSlice();
    }

    fn buildExternalTokens(self: *Builder) ParseGrammarError![]const ir.ExternalToken {
        var result = std.array_list.Managed(ir.ExternalToken).init(self.allocator);
        defer result.deinit();

        for (self.grammar.externals, 0..) |external_rule, i| {
            const external_name = switch (external_rule.*) {
                .symbol => |name| name,
                else => "",
            };
            try result.append(.{
                .name = external_name,
                .symbol = ir_symbols.SymbolId.external(i),
                .kind = if (external_name.len == 0) .anonymous else variableKindForName(external_name),
                .rule = try self.lowerRule(external_rule),
            });
        }

        return try result.toOwnedSlice();
    }

    fn resolveConflicts(self: *Builder) ParseGrammarError![]const ir.ConflictSet {
        var result = std.array_list.Managed(ir.ConflictSet).init(self.allocator);
        defer result.deinit();

        for (self.grammar.conflicts) |conflict_set| {
            var members = std.array_list.Managed(ir_symbols.SymbolId).init(self.allocator);
            defer members.deinit();

            for (conflict_set) |name| {
                const symbol = self.resolveName(name) orelse return error.UndefinedConflict;
                try members.append(symbol);
            }

            try result.append(try members.toOwnedSlice());
        }

        return try result.toOwnedSlice();
    }

    fn resolvePrecedences(self: *Builder) ParseGrammarError![]const ir.PrecedenceOrdering {
        var result = std.array_list.Managed(ir.PrecedenceOrdering).init(self.allocator);
        defer result.deinit();

        for (self.grammar.precedences) |ordering| {
            var entries = std.array_list.Managed(ir.PrecedenceEntry).init(self.allocator);
            defer entries.deinit();

            for (ordering) |entry| {
                switch (entry.*) {
                    .string => |value| try entries.append(.{ .name = value }),
                    .symbol => |name| {
                        const symbol = self.resolveName(name) orelse return error.UndefinedSymbol;
                        try entries.append(.{ .symbol = symbol });
                    },
                    else => unreachable,
                }
            }

            try result.append(try entries.toOwnedSlice());
        }

        return try result.toOwnedSlice();
    }

    fn resolveInlineRules(self: *Builder) ParseGrammarError![]const ir_symbols.SymbolId {
        var result = std.array_list.Managed(ir_symbols.SymbolId).init(self.allocator);
        defer result.deinit();

        for (self.grammar.inline_rules) |name| {
            const symbol = self.resolveName(name) orelse continue;
            try appendUniqueSymbol(&result, symbol);
        }

        return try result.toOwnedSlice();
    }

    fn resolveSupertypes(self: *Builder) ParseGrammarError![]const ir_symbols.SymbolId {
        var result = std.array_list.Managed(ir_symbols.SymbolId).init(self.allocator);
        defer result.deinit();

        for (self.grammar.supertypes) |name| {
            const symbol = self.resolveName(name) orelse return error.UndefinedSupertype;
            try appendUniqueSymbol(&result, symbol);
        }

        return try result.toOwnedSlice();
    }

    fn resolveWordToken(self: *Builder) ParseGrammarError!?ir_symbols.SymbolId {
        const name = self.grammar.word orelse return null;
        return self.resolveName(name) orelse error.UndefinedWordToken;
    }

    fn resolveReservedWordSets(self: *Builder) ParseGrammarError![]const ir.ReservedWordSet {
        var result = std.array_list.Managed(ir.ReservedWordSet).init(self.allocator);
        defer result.deinit();

        for (self.grammar.reserved) |reserved_set| {
            var members = std.array_list.Managed(ir_rules.RuleId).init(self.allocator);
            defer members.deinit();

            for (reserved_set.members) |member| {
                try members.append(try self.lowerRule(member));
            }

            try result.append(.{
                .context_name = reserved_set.context_name,
                .members = try members.toOwnedSlice(),
            });
        }

        return try result.toOwnedSlice();
    }

    fn lowerRuleList(self: *Builder, rules: []const *const raw.RawRule) ParseGrammarError![]const ir_rules.RuleId {
        var result = std.array_list.Managed(ir_rules.RuleId).init(self.allocator);
        defer result.deinit();

        for (rules) |rule| {
            try result.append(try self.lowerRule(rule));
        }

        return try result.toOwnedSlice();
    }

    fn lowerRule(self: *Builder, rule: *const raw.RawRule) ParseGrammarError!ir_rules.RuleId {
        return switch (rule.*) {
            .blank => self.appendRule(.blank),
            .string => |value| self.appendRule(.{ .string = value }),
            .pattern => |pattern| self.appendRule(.{ .pattern = .{
                .value = pattern.value,
                .flags = pattern.flags,
            } }),
            .symbol => |name| self.appendRule(.{ .symbol = self.resolveName(name) orelse return error.UndefinedSymbol }),
            .choice => |members| self.appendRule(.{ .choice = try self.lowerRuleList(members) }),
            .seq => |members| self.appendRule(.{ .seq = try self.lowerRuleList(members) }),
            .repeat => |inner| self.appendRule(.{ .repeat = try self.lowerRule(inner) }),
            .repeat1 => |inner| self.appendRule(.{ .repeat1 = try self.lowerRule(inner) }),
            .alias => |alias| self.applyMetadata(try self.lowerRule(alias.content), .{
                .alias = .{
                    .value = alias.value,
                    .named = alias.named,
                },
            }),
            .field => |field| self.applyMetadata(try self.lowerRule(field.content), .{
                .field_name = field.name,
            }),
            .prec_dynamic => |prec| self.applyMetadata(try self.lowerRule(prec.content), .{
                .dynamic_precedence = prec.value,
            }),
            .prec_left => |prec| self.applyMetadata(try self.lowerRule(prec.content), .{
                .precedence = lowerPrecedenceValue(prec.value),
                .associativity = .left,
            }),
            .prec_right => |prec| self.applyMetadata(try self.lowerRule(prec.content), .{
                .precedence = lowerPrecedenceValue(prec.value),
                .associativity = .right,
            }),
            .prec => |prec| self.applyMetadata(try self.lowerRule(prec.content), .{
                .precedence = lowerPrecedenceValue(prec.value),
            }),
            .token => |inner| self.applyMetadata(try self.lowerRule(inner), .{
                .token = true,
            }),
            .immediate_token => |inner| self.applyMetadata(try self.lowerRule(inner), .{
                .token = true,
                .immediate_token = true,
            }),
            .reserved => |reserved| self.applyMetadata(try self.lowerRule(reserved.content), .{
                .reserved_context_name = reserved.context_name,
            }),
        };
    }

    fn applyMetadata(self: *Builder, inner: ir_rules.RuleId, patch: ir_rules.Metadata) ParseGrammarError!ir_rules.RuleId {
        var merged = patch;
        var final_inner = inner;

        if (self.lowered_rules.items[@intCast(inner)] == .metadata) {
            const existing = self.lowered_rules.items[@intCast(inner)].metadata;
            final_inner = existing.inner;
            merged = mergeMetadata(existing.data, patch);
        }

        return self.appendRule(.{
            .metadata = .{
                .inner = final_inner,
                .data = merged,
            },
        });
    }

    fn appendRule(self: *Builder, rule: ir_rules.Rule) ParseGrammarError!ir_rules.RuleId {
        try self.lowered_rules.append(rule);
        return @intCast(self.lowered_rules.items.len - 1);
    }

    fn resolveName(self: *Builder, name: []const u8) ?ir_symbols.SymbolId {
        for (self.grammar.rules, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                return ir_symbols.SymbolId.nonTerminal(i);
            }
        }

        for (self.grammar.externals, 0..) |external_rule, i| {
            switch (external_rule.*) {
                .symbol => |external_name| {
                    if (std.mem.eql(u8, external_name, name)) {
                        return ir_symbols.SymbolId.external(i);
                    }
                },
                else => {},
            }
        }

        return null;
    }

    fn symbolTableIndex(self: *const Builder, symbol: ir_symbols.SymbolId) usize {
        return switch (symbol.kind) {
            .non_terminal => @intCast(symbol.index),
            .external => self.grammar.rules.len + @as(usize, @intCast(symbol.index)),
        };
    }
};

const PrecedencePairOrdering = struct {
    left: OrderingEntry,
    right: OrderingEntry,
    direction: std.math.Order,
};

const OrderingEntry = union(enum) {
    name: []const u8,
    symbol: []const u8,
};

fn variableKindForName(name: []const u8) ir.VariableKind {
    return if (isHidden(name)) .hidden else .named;
}

fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

fn lowerPrecedenceValue(value: raw.RawPrecedenceValue) ir_rules.PrecedenceValue {
    return switch (value) {
        .integer => |v| .{ .integer = v },
        .name => |v| .{ .name = v },
    };
}

fn validatePrecedenceValueDeclared(
    value: raw.RawPrecedenceValue,
    declared: *const std.StringHashMap(void),
) ParseGrammarError!void {
    switch (value) {
        .integer => {},
        .name => |name| {
            if (!declared.contains(name)) {
                return error.UndeclaredPrecedence;
            }
        },
    }
}

fn validatePrecedenceOrderingPairs(
    pairs: *std.array_list.Managed(PrecedencePairOrdering),
    ordering: raw.PrecedenceList,
) ParseGrammarError!void {
    for (ordering, 0..) |entry1_rule, i| {
        const entry1 = try lowerRawPrecedenceEntry(entry1_rule);
        for (ordering[(i + 1)..]) |entry2_rule| {
            const entry2 = try lowerRawPrecedenceEntry(entry2_rule);
            if (precedenceEntryEql(entry1, entry2)) continue;

            var left = entry1;
            var right = entry2;
            var direction = std.math.Order.gt;
            if (precedenceEntryLessThan(right, left)) {
                left = entry2;
                right = entry1;
                direction = .lt;
            }

            for (pairs.items) |existing| {
                if (precedenceEntryEql(existing.left, left) and precedenceEntryEql(existing.right, right)) {
                    if (existing.direction != direction) {
                        return error.ConflictingPrecedenceOrdering;
                    }
                    break;
                }
            } else {
                try pairs.append(.{
                    .left = left,
                    .right = right,
                    .direction = direction,
                });
            }
        }
    }
}

fn lowerRawPrecedenceEntry(entry: *const raw.RawRule) ParseGrammarError!OrderingEntry {
    return switch (entry.*) {
        .string => |value| .{ .name = value },
        .symbol => |name| .{ .symbol = name },
        else => unreachable,
    };
}

fn precedenceEntryLessThan(lhs: OrderingEntry, rhs: OrderingEntry) bool {
    const lhs_tag: u8 = switch (lhs) {
        .name => 0,
        .symbol => 1,
    };
    const rhs_tag: u8 = switch (rhs) {
        .name => 0,
        .symbol => 1,
    };
    if (lhs_tag != rhs_tag) return lhs_tag < rhs_tag;
    return switch (lhs) {
        .name => |lhs_name| switch (rhs) {
            .name => |rhs_name| std.mem.order(u8, lhs_name, rhs_name) == .lt,
            else => unreachable,
        },
        .symbol => |lhs_symbol| switch (rhs) {
            .symbol => |rhs_symbol| std.mem.order(u8, lhs_symbol, rhs_symbol) == .lt,
            else => unreachable,
        },
    };
}

fn precedenceEntryEql(lhs: OrderingEntry, rhs: OrderingEntry) bool {
    return switch (lhs) {
        .name => |lhs_name| switch (rhs) {
            .name => |rhs_name| std.mem.eql(u8, lhs_name, rhs_name),
            else => false,
        },
        .symbol => |lhs_symbol| switch (rhs) {
            .symbol => |rhs_symbol| std.mem.eql(u8, lhs_symbol, rhs_symbol),
            else => false,
        },
    };
}

fn mergeMetadata(existing: ir_rules.Metadata, patch: ir_rules.Metadata) ir_rules.Metadata {
    var merged = existing;
    if (patch.field_name) |field_name| merged.field_name = field_name;
    if (patch.alias) |alias| merged.alias = alias;
    if (patch.precedence != .none) merged.precedence = patch.precedence;
    if (patch.associativity != .none) merged.associativity = patch.associativity;
    if (patch.dynamic_precedence != 0) merged.dynamic_precedence = patch.dynamic_precedence;
    merged.token = merged.token or patch.token;
    merged.immediate_token = merged.immediate_token or patch.immediate_token;
    if (patch.reserved_context_name) |context_name| merged.reserved_context_name = context_name;
    return merged;
}

fn appendUniqueSymbol(list: *std.array_list.Managed(ir_symbols.SymbolId), symbol: ir_symbols.SymbolId) ParseGrammarError!void {
    for (list.items) |existing| {
        if (existing.kind == symbol.kind and existing.index == symbol.index) return;
    }
    try list.append(symbol);
}

test "parseRawGrammar lowers a valid grammar into prepared grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.validResolvedGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parseRawGrammar(parse_arena.allocator(), &raw_grammar);

    try std.testing.expectEqualStrings("basic", prepared.grammar_name);
    try std.testing.expectEqual(@as(usize, 3), prepared.variables.len);
    try std.testing.expectEqual(@as(usize, 1), prepared.external_tokens.len);
    try std.testing.expectEqual(@as(usize, 4), prepared.symbols.len);
    try std.testing.expect(prepared.word_token != null);
    try std.testing.expectEqual(@as(usize, 1), prepared.supertype_symbols.len);
    try std.testing.expectEqual(@as(usize, 1), prepared.variables_to_inline.len);
    try std.testing.expectEqual(@as(usize, 1), prepared.expected_conflicts.len);
    try std.testing.expectEqual(@as(usize, 1), prepared.reserved_word_sets.len);
    try std.testing.expectEqual(ir.VariableKind.hidden, prepared.variables[1].kind);
    try std.testing.expect(!prepared.symbols[1].visible);
}

test "parseRawGrammar rejects undefined symbol references" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.undefinedSymbolGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    try std.testing.expectError(error.UndefinedSymbol, parseRawGrammar(parse_arena.allocator(), &raw_grammar));
}

test "parseRawGrammar rejects hidden start rule" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.hiddenStartGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    try std.testing.expectError(error.HiddenStartRule, parseRawGrammar(parse_arena.allocator(), &raw_grammar));
}

test "parseRawGrammar rejects undeclared named precedence values" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.undeclaredPrecedenceGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    try std.testing.expectError(error.UndeclaredPrecedence, parseRawGrammar(parse_arena.allocator(), &raw_grammar));
}

test "parseRawGrammar rejects conflicting precedence orderings" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.conflictingPrecedenceOrderingGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    try std.testing.expectError(error.ConflictingPrecedenceOrdering, parseRawGrammar(parse_arena.allocator(), &raw_grammar));
}

test "parseRawGrammar prefers internal symbols over duplicate external names" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.duplicateInternalExternalGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parseRawGrammar(parse_arena.allocator(), &raw_grammar);
    const symbol = getTerminalSymbol(prepared, prepared.external_tokens[0].rule);

    try std.testing.expectEqual(ir_symbols.SymbolKind.non_terminal, symbol.kind);
    try std.testing.expectEqual(@as(u32, 2), symbol.index);
}

test "parseRawGrammar merges nested metadata wrappers" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.nestedMetadataGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parseRawGrammar(parse_arena.allocator(), &raw_grammar);
    const metadata = getMetadataRule(prepared, prepared.variables[0].rule);

    try std.testing.expectEqualStrings("lhs", metadata.data.field_name.?);
    try std.testing.expectEqualStrings("renamed", metadata.data.alias.?.value);
    try std.testing.expect(metadata.data.alias.?.named);
    try std.testing.expectEqual(ir_rules.Assoc.left, metadata.data.associativity);
    try std.testing.expectEqual(@as(i32, 7), metadata.data.dynamic_precedence);
    try std.testing.expect(metadata.data.token);
    try std.testing.expect(metadata.data.immediate_token);
    try std.testing.expectEqualStrings("global", metadata.data.reserved_context_name.?);
}

test "parseRawGrammar normalizes semantic lists" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.normalizedListsGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parseRawGrammar(parse_arena.allocator(), &raw_grammar);

    try std.testing.expectEqual(@as(usize, 2), prepared.variables_to_inline.len);
    try std.testing.expectEqual(@as(u32, 1), prepared.variables_to_inline[0].index);
    try std.testing.expectEqual(@as(u32, 2), prepared.variables_to_inline[1].index);

    try std.testing.expectEqual(@as(usize, 2), prepared.supertype_symbols.len);
    try std.testing.expectEqual(@as(u32, 1), prepared.supertype_symbols[0].index);
    try std.testing.expectEqual(@as(u32, 2), prepared.supertype_symbols[1].index);

    try std.testing.expectEqual(@as(usize, 1), prepared.expected_conflicts.len);
    try std.testing.expectEqual(@as(usize, 2), prepared.expected_conflicts[0].len);
    try std.testing.expectEqual(@as(u32, 1), prepared.expected_conflicts[0][0].index);
    try std.testing.expectEqual(@as(u32, 2), prepared.expected_conflicts[0][1].index);

    try std.testing.expectEqual(@as(usize, 1), prepared.reserved_word_sets.len);
    try std.testing.expectEqual(@as(usize, 2), prepared.reserved_word_sets[0].members.len);
}

fn getMetadataRule(prepared: ir.PreparedGrammar, rule_id: ir_rules.RuleId) ir_rules.MetadataRule {
    return switch (prepared.rules[@intCast(rule_id)]) {
        .metadata => |metadata| metadata,
        else => unreachable,
    };
}

fn getTerminalSymbol(prepared: ir.PreparedGrammar, rule_id: ir_rules.RuleId) ir_symbols.SymbolId {
    return switch (prepared.rules[@intCast(rule_id)]) {
        .symbol => |symbol| symbol,
        .metadata => |metadata| getTerminalSymbol(prepared, metadata.inner),
        else => unreachable,
    };
}

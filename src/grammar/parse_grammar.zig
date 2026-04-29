const std = @import("std");
const raw = @import("raw_grammar.zig");
const normalize = @import("normalize.zig");
const ir_symbols = @import("../ir/symbols.zig");
const ir_rules = @import("../ir/rules.zig");
const ir = @import("../ir/grammar_ir.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const SemanticDiagnosticKind = enum {
    hidden_start_rule,
    undefined_symbol,
    undefined_supertype,
    undefined_conflict,
    undefined_word_token,
    undeclared_precedence,
    conflicting_precedence_ordering,
    indirect_recursion,
    out_of_memory,
};

pub const SemanticDiagnostic = struct {
    kind: SemanticDiagnosticKind,
    summary: []const u8,
    note: ?[]const u8 = null,
    symbol_name: ?[]const u8 = null,
    rule_name: ?[]const u8 = null,
    precedence_name: ?[]const u8 = null,
    other_precedence_name: ?[]const u8 = null,
};

pub threadlocal var last_error_diagnostic: ?SemanticDiagnostic = null;

pub const ParseGrammarError = error{
    HiddenStartRule,
    UndefinedSymbol,
    UndefinedSupertype,
    UndefinedConflict,
    UndefinedWordToken,
    UndeclaredPrecedence,
    ConflictingPrecedenceOrdering,
    IndirectRecursion,
    OutOfMemory,
};

pub fn parseRawGrammar(allocator: std.mem.Allocator, grammar: *const raw.RawGrammar) ParseGrammarError!ir.PreparedGrammar {
    last_error_diagnostic = null;
    var builder = Builder.init(allocator, grammar);
    return builder.build();
}

pub fn errorMessage(err: ParseGrammarError) []const u8 {
    return errorDiagnostic(err).summary;
}

pub fn errorNote(err: ParseGrammarError) ?[]const u8 {
    return errorDiagnostic(err).note;
}

pub fn errorDiagnostic(err: ParseGrammarError) SemanticDiagnostic {
    return last_error_diagnostic orelse defaultDiagnostic(err);
}

fn defaultDiagnostic(err: ParseGrammarError) SemanticDiagnostic {
    return switch (err) {
        error.HiddenStartRule => .{
            .kind = .hidden_start_rule,
            .summary = "start rule must be visible",
            .note = "A grammar's start rule must be visible.",
        },
        error.UndefinedSymbol => .{
            .kind = .undefined_symbol,
            .summary = "undefined symbol",
        },
        error.UndefinedSupertype => .{
            .kind = .undefined_supertype,
            .summary = "undefined supertype",
        },
        error.UndefinedConflict => .{
            .kind = .undefined_conflict,
            .summary = "undefined conflict member",
        },
        error.UndefinedWordToken => .{
            .kind = .undefined_word_token,
            .summary = "undefined word token",
        },
        error.UndeclaredPrecedence => .{
            .kind = .undeclared_precedence,
            .summary = "undeclared precedence",
        },
        error.ConflictingPrecedenceOrdering => .{
            .kind = .conflicting_precedence_ordering,
            .summary = "conflicting precedence orderings",
        },
        error.IndirectRecursion => .{
            .kind = .indirect_recursion,
            .summary = "indirect recursion",
        },
        error.OutOfMemory => .{
            .kind = .out_of_memory,
            .summary = "out of memory while lowering grammar",
        },
    };
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
            last_error_diagnostic = .{
                .kind = .hidden_start_rule,
                .summary = "start rule must be visible",
                .note = "A grammar's start rule must be visible.",
                .rule_name = self.grammar.rules[0].name,
            };
            return error.HiddenStartRule;
        }

        try self.validatePrecedences();
        try self.validateIndirectRecursion();

        var symbols = try self.buildSymbols();
        var variables = try self.buildVariables();
        const external_tokens = try self.buildExternalTokens();
        const extra_rules = try self.lowerRuleList(self.grammar.extras);
        const expected_conflicts = try normalize.normalizeConflictSets(self.allocator, try self.resolveConflicts());
        const precedence_orderings = try normalize.normalizePrecedenceOrderings(self.allocator, try self.resolvePrecedences());
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
            .grammar_version = self.grammar.version,
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
            try validatePrecedenceOrderingPairs(self, &pairs, ordering);
        }

        for (self.grammar.rules) |entry| {
            try self.validateRulePrecedences(entry.name, entry.rule, &declared);
        }
        for (self.grammar.externals) |entry| {
            try self.validateRulePrecedences("<external token>", entry, &declared);
        }
        for (self.grammar.extras) |entry| {
            try self.validateRulePrecedences("<extra>", entry, &declared);
        }
        for (self.grammar.reserved) |reserved_set| {
            for (reserved_set.members) |member| {
                try self.validateRulePrecedences(reserved_set.context_name, member, &declared);
            }
        }
    }

    fn validateRulePrecedences(
        self: *Builder,
        rule_name: []const u8,
        rule: *const raw.RawRule,
        declared: *const std.StringHashMap(void),
    ) ParseGrammarError!void {
        switch (rule.*) {
            .alias => |alias| try self.validateRulePrecedences(rule_name, alias.content, declared),
            .field => |field| try self.validateRulePrecedences(rule_name, field.content, declared),
            .choice => |members| for (members) |member| try self.validateRulePrecedences(rule_name, member, declared),
            .seq => |members| for (members) |member| try self.validateRulePrecedences(rule_name, member, declared),
            .repeat => |inner| try self.validateRulePrecedences(rule_name, inner, declared),
            .repeat1 => |inner| try self.validateRulePrecedences(rule_name, inner, declared),
            .prec_dynamic => |prec| try self.validateRulePrecedences(rule_name, prec.content, declared),
            .prec_left => |prec| {
                try self.validatePrecedenceValueDeclared(rule_name, prec.value, declared);
                try self.validateRulePrecedences(rule_name, prec.content, declared);
            },
            .prec_right => |prec| {
                try self.validatePrecedenceValueDeclared(rule_name, prec.value, declared);
                try self.validateRulePrecedences(rule_name, prec.content, declared);
            },
            .prec => |prec| {
                try self.validatePrecedenceValueDeclared(rule_name, prec.value, declared);
                try self.validateRulePrecedences(rule_name, prec.content, declared);
            },
            .token => |inner| try self.validateRulePrecedences(rule_name, inner, declared),
            .immediate_token => |inner| try self.validateRulePrecedences(rule_name, inner, declared),
            .reserved => |reserved| try self.validateRulePrecedences(rule_name, reserved.content, declared),
            .blank, .string, .pattern, .symbol => {},
        }
    }

    fn validateIndirectRecursion(self: *Builder) ParseGrammarError!void {
        for (self.grammar.rules) |entry| {
            var visited = std.StringHashMap(void).init(self.allocator);
            defer visited.deinit();

            var path = std.array_list.Managed([]const u8).init(self.allocator);
            defer path.deinit();

            try self.validateIndirectRecursionFrom(entry.name, entry.name, &visited, &path);
        }
    }

    fn validateIndirectRecursionFrom(
        self: *Builder,
        start_name: []const u8,
        current_name: []const u8,
        visited: *std.StringHashMap(void),
        path: *std.array_list.Managed([]const u8),
    ) ParseGrammarError!void {
        if (pathIndex(path.items, current_name)) |index| {
            return self.failIndirectRecursion(path.items[index..], current_name);
        }
        if (visited.contains(current_name)) return;

        try visited.put(current_name, {});
        try path.append(current_name);
        defer _ = path.pop();

        const entry = self.findRuleEntry(current_name) orelse return;
        var next_symbols = std.array_list.Managed([]const u8).init(self.allocator);
        defer next_symbols.deinit();
        try collectSingleSymbolProductions(&next_symbols, entry.rule);

        for (next_symbols.items) |next_name| {
            if (std.mem.eql(u8, next_name, start_name)) {
                return self.failIndirectRecursion(path.items, next_name);
            }
            if (std.mem.eql(u8, next_name, current_name)) continue;
            try self.validateIndirectRecursionFrom(start_name, next_name, visited, path);
        }
    }

    fn findRuleEntry(self: *const Builder, name: []const u8) ?raw.RawRuleEntry {
        for (self.grammar.rules) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
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

        for (self.grammar.expected_conflicts) |conflict_set| {
            var members = std.array_list.Managed(ir_symbols.SymbolId).init(self.allocator);
            defer members.deinit();

            for (conflict_set) |name| {
                const symbol = self.resolveName(name) orelse return self.failUndefinedConflict(name);
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
            const symbol = self.resolveName(name) orelse return self.failUndefinedSupertype(name);
            try appendUniqueSymbol(&result, symbol);
        }

        return try result.toOwnedSlice();
    }

    fn resolveWordToken(self: *Builder) ParseGrammarError!?ir_symbols.SymbolId {
        const name = self.grammar.word orelse return null;
        return self.resolveName(name) orelse self.failUndefinedWordToken(name);
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
            .symbol => |name| self.appendRule(.{ .symbol = self.resolveName(name) orelse return self.failUndefinedSymbol(name) }),
            .choice => |members| self.appendRule(.{ .choice = try self.lowerRuleList(members) }),
            .seq => |members| self.appendRule(.{ .seq = try self.lowerRuleList(members) }),
            .repeat => |inner| self.lowerZeroOrMoreRepeat(inner),
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

    fn lowerZeroOrMoreRepeat(self: *Builder, inner: *const raw.RawRule) ParseGrammarError!ir_rules.RuleId {
        const lowered_inner = try self.lowerRule(inner);
        const repeat_rule = try self.appendRule(.{ .repeat1 = lowered_inner });
        const blank_rule = try self.appendRule(.blank);
        const members = try self.allocator.alloc(ir_rules.RuleId, 2);
        members[0] = repeat_rule;
        members[1] = blank_rule;
        return self.appendRule(.{ .choice = members });
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

    fn validatePrecedenceValueDeclared(
        self: *Builder,
        rule_name: []const u8,
        value: raw.RawPrecedenceValue,
        declared: *const std.StringHashMap(void),
    ) ParseGrammarError!void {
        switch (value) {
            .integer => {},
            .name => |name| {
                if (!declared.contains(name)) {
                    return self.failUndeclaredPrecedence(name, rule_name);
                }
            },
        }
    }

    fn failUndefinedSymbol(self: *Builder, name: []const u8) ParseGrammarError {
        self.setDiagnostic(.{
            .kind = .undefined_symbol,
            .summary = "undefined symbol",
            .note = self.allocNote("Undefined symbol `{s}`", .{name}, "Undefined symbol"),
            .symbol_name = name,
        });
        return error.UndefinedSymbol;
    }

    fn failUndefinedSupertype(self: *Builder, name: []const u8) ParseGrammarError {
        self.setDiagnostic(.{
            .kind = .undefined_supertype,
            .summary = "undefined supertype",
            .note = self.allocNote(
                "Undefined symbol `{s}` in grammar's supertypes array",
                .{name},
                "Undefined symbol in grammar's supertypes array",
            ),
            .symbol_name = name,
        });
        return error.UndefinedSupertype;
    }

    fn failUndefinedConflict(self: *Builder, name: []const u8) ParseGrammarError {
        self.setDiagnostic(.{
            .kind = .undefined_conflict,
            .summary = "undefined conflict member",
            .note = self.allocNote(
                "Undefined symbol `{s}` in grammar's conflicts array",
                .{name},
                "Undefined symbol in grammar's conflicts array",
            ),
            .symbol_name = name,
        });
        return error.UndefinedConflict;
    }

    fn failUndefinedWordToken(self: *Builder, name: []const u8) ParseGrammarError {
        self.setDiagnostic(.{
            .kind = .undefined_word_token,
            .summary = "undefined word token",
            .note = self.allocNote(
                "Undefined symbol `{s}` as grammar's word token",
                .{name},
                "Undefined symbol as grammar's word token",
            ),
            .symbol_name = name,
        });
        return error.UndefinedWordToken;
    }

    fn failUndeclaredPrecedence(self: *Builder, precedence_name: []const u8, rule_name: []const u8) ParseGrammarError {
        self.setDiagnostic(.{
            .kind = .undeclared_precedence,
            .summary = "undeclared precedence",
            .note = self.allocNote(
                "Undeclared precedence '{s}' in rule '{s}'",
                .{ precedence_name, rule_name },
                "Undeclared precedence used in grammar rule",
            ),
            .rule_name = rule_name,
            .precedence_name = precedence_name,
        });
        return error.UndeclaredPrecedence;
    }

    fn failConflictingPrecedenceOrdering(self: *Builder, left: OrderingEntry, right: OrderingEntry) ParseGrammarError {
        const left_text = left.displayName();
        const right_text = right.displayName();
        self.setDiagnostic(.{
            .kind = .conflicting_precedence_ordering,
            .summary = "conflicting precedence orderings",
            .note = self.allocNote(
                "Conflicting orderings for precedences {s} and {s}",
                .{ left_text, right_text },
                "Conflicting orderings for precedences",
            ),
            .precedence_name = left_text,
            .other_precedence_name = right_text,
        });
        return error.ConflictingPrecedenceOrdering;
    }

    fn failIndirectRecursion(self: *Builder, path: []const []const u8, final_name: []const u8) ParseGrammarError {
        self.setDiagnostic(.{
            .kind = .indirect_recursion,
            .summary = "indirect recursion",
            .note = self.indirectRecursionNote(path, final_name),
            .rule_name = if (path.len == 0) final_name else path[0],
        });
        return error.IndirectRecursion;
    }

    fn indirectRecursionNote(self: *Builder, path: []const []const u8, final_name: []const u8) []const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        out.writer.writeAll("Grammar contains an indirectly recursive rule: ") catch return "Grammar contains an indirectly recursive rule";
        for (path, 0..) |name, index| {
            if (index != 0) out.writer.writeAll(" -> ") catch return "Grammar contains an indirectly recursive rule";
            out.writer.writeAll(name) catch return "Grammar contains an indirectly recursive rule";
        }
        if (path.len != 0) out.writer.writeAll(" -> ") catch return "Grammar contains an indirectly recursive rule";
        out.writer.writeAll(final_name) catch return "Grammar contains an indirectly recursive rule";
        return out.toOwnedSlice() catch "Grammar contains an indirectly recursive rule";
    }

    fn allocNote(self: *Builder, comptime fmt: []const u8, args: anytype, fallback_note: []const u8) []const u8 {
        return std.fmt.allocPrint(self.allocator, fmt, args) catch fallback_note;
    }

    fn setDiagnostic(_: *Builder, diagnostic: SemanticDiagnostic) void {
        last_error_diagnostic = diagnostic;
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

    fn displayName(self: OrderingEntry) []const u8 {
        return switch (self) {
            .name => |value| value,
            .symbol => |value| value,
        };
    }
};

fn variableKindForName(name: []const u8) ir.VariableKind {
    return if (isHidden(name)) .hidden else .named;
}

fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

fn pathIndex(path: []const []const u8, name: []const u8) ?usize {
    for (path, 0..) |entry, index| {
        if (std.mem.eql(u8, entry, name)) return index;
    }
    return null;
}

fn collectSingleSymbolProductions(result: *std.array_list.Managed([]const u8), rule: *const raw.RawRule) ParseGrammarError!void {
    switch (rule.*) {
        .symbol => |name| try appendUniqueString(result, name),
        .choice => |members| for (members) |member| try collectSingleSymbolProductions(result, member),
        .alias => |alias| try collectSingleSymbolProductions(result, alias.content),
        .field => |field| try collectSingleSymbolProductions(result, field.content),
        .prec_dynamic => |prec| try collectSingleSymbolProductions(result, prec.content),
        .prec_left => |prec| try collectSingleSymbolProductions(result, prec.content),
        .prec_right => |prec| try collectSingleSymbolProductions(result, prec.content),
        .prec => |prec| try collectSingleSymbolProductions(result, prec.content),
        .token => |inner| try collectSingleSymbolProductions(result, inner),
        .immediate_token => |inner| try collectSingleSymbolProductions(result, inner),
        .reserved => |reserved| try collectSingleSymbolProductions(result, reserved.content),
        .blank, .string, .pattern, .seq, .repeat, .repeat1 => {},
    }
}

fn appendUniqueString(list: *std.array_list.Managed([]const u8), value: []const u8) ParseGrammarError!void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(value);
}

fn lowerPrecedenceValue(value: raw.RawPrecedenceValue) ir_rules.PrecedenceValue {
    return switch (value) {
        .integer => |v| .{ .integer = v },
        .name => |v| .{ .name = v },
    };
}

fn validatePrecedenceOrderingPairs(
    builder: *Builder,
    pairs: *std.array_list.Managed(PrecedencePairOrdering),
    ordering: raw.PrecedenceList,
) ParseGrammarError!void {
    var normalized = std.array_list.Managed(OrderingEntry).init(builder.allocator);
    defer normalized.deinit();

    for (ordering) |entry_rule| {
        const entry = try lowerRawPrecedenceEntry(entry_rule);
        if (containsOrderingEntry(normalized.items, entry)) continue;
        try normalized.append(entry);
    }

    for (normalized.items, 0..) |entry1, i| {
        for (normalized.items[(i + 1)..]) |entry2| {
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
                        return builder.failConflictingPrecedenceOrdering(left, right);
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

fn containsOrderingEntry(existing: []const OrderingEntry, candidate: OrderingEntry) bool {
    for (existing) |entry| {
        if (precedenceEntryEql(entry, candidate)) return true;
    }
    return false;
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

test "parseRawGrammar rejects indirect recursion through single-symbol productions" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    const contents =
        \\{
        \\  "name": "indirect",
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "middle" },
        \\    "middle": { "type": "CHOICE", "members": [
        \\      { "type": "SYMBOL", "name": "source_file" },
        \\      { "type": "STRING", "value": "ok" }
        \\    ] }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    try std.testing.expectError(error.IndirectRecursion, parseRawGrammar(parse_arena.allocator(), &raw_grammar));
    const diagnostic = errorDiagnostic(error.IndirectRecursion);
    try std.testing.expectEqualStrings("indirect recursion", diagnostic.summary);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.note.?, "source_file -> middle -> source_file") != null);
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
    const diagnostic = errorDiagnostic(error.ConflictingPrecedenceOrdering);
    try std.testing.expectEqualStrings("conflicting precedence orderings", diagnostic.summary);
    try std.testing.expectEqualStrings("Conflicting orderings for precedences a and b", diagnostic.note.?);
    try std.testing.expectEqualStrings("a", diagnostic.precedence_name.?);
    try std.testing.expectEqualStrings("b", diagnostic.other_precedence_name.?);
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

test "parseRawGrammar stores a readable undefined symbol message" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.undefinedSymbolGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    try std.testing.expectError(error.UndefinedSymbol, parseRawGrammar(parse_arena.allocator(), &raw_grammar));
    const diagnostic = errorDiagnostic(error.UndefinedSymbol);
    try std.testing.expectEqualStrings("undefined symbol", diagnostic.summary);
    try std.testing.expectEqualStrings("Undefined symbol `missing`", diagnostic.note.?);
    try std.testing.expectEqualStrings("missing", diagnostic.symbol_name.?);
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

    try std.testing.expectEqual(@as(usize, 1), prepared.precedence_orderings.len);
    try std.testing.expectEqual(@as(usize, 2), prepared.precedence_orderings[0].len);
    try std.testing.expectEqualStrings("a", prepared.precedence_orderings[0][0].name);
    try std.testing.expectEqualStrings("b", prepared.precedence_orderings[0][1].name);

    try std.testing.expectEqual(@as(usize, 1), prepared.reserved_word_sets.len);
    try std.testing.expectEqual(@as(usize, 2), prepared.reserved_word_sets[0].members.len);
}

test "parseRawGrammar lowers expected_conflicts spelling into prepared grammar" {
    const contents =
        \\{
        \\  "name": "expected_conflict_alias",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "BLANK" }
        \\  }
        \\}
    ;
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), contents, .{});
    defer parsed.deinit();

    const raw_grammar = try @import("json_loader.zig").parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parseRawGrammar(parse_arena.allocator(), &raw_grammar);

    try std.testing.expectEqual(@as(usize, 1), prepared.expected_conflicts.len);
    try std.testing.expectEqual(@as(usize, 2), prepared.expected_conflicts[0].len);
    try std.testing.expectEqual(ir_symbols.SymbolKind.non_terminal, prepared.expected_conflicts[0][0].kind);
    try std.testing.expectEqual(ir_symbols.SymbolKind.non_terminal, prepared.expected_conflicts[0][1].kind);
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

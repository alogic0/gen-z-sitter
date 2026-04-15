const std = @import("std");
const alias_ir = @import("../ir/aliases.zig");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const rules = @import("../ir/rules.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const ComputeNodeTypesError = error{
    InvalidSupertype,
    OutOfMemory,
};

pub const NodeType = struct {
    kind: []const u8,
    named: bool,
    root: bool = false,
    extra: bool = false,
    fields: []const Field = &.{},
    children: ?ChildInfo = null,
    subtypes: []const NodeTypeRef = &.{},
};

pub const NodeTypeRef = struct {
    kind: []const u8,
    named: bool,
};

pub const ChildQuantity = struct {
    exists: bool = false,
    required: bool = false,
    multiple: bool = false,

    fn zero() ChildQuantity {
        return .{ .exists = false, .required = false, .multiple = false };
    }

    fn one() ChildQuantity {
        return .{ .exists = true, .required = true, .multiple = false };
    }

    fn fromCount(count: usize) ChildQuantity {
        if (count == 0) return .zero();
        return .{
            .exists = true,
            .required = true,
            .multiple = count > 1,
        };
    }

    fn append(self: *ChildQuantity, other: ChildQuantity) void {
        if (!other.exists) return;
        if (self.exists or other.multiple) self.multiple = true;
        if (other.required) self.required = true;
        self.exists = true;
    }

    fn mergeAlternatives(a: ChildQuantity, b: ChildQuantity) ChildQuantity {
        if (!a.exists) return b;
        if (!b.exists) return .{
            .exists = a.exists,
            .required = false,
            .multiple = a.multiple,
        };
        return .{
            .exists = true,
            .required = a.required and b.required,
            .multiple = a.multiple or b.multiple,
        };
    }
};

pub const ChildInfo = struct {
    quantity: ChildQuantity,
    types: []const NodeTypeRef,
};

pub const Field = struct {
    name: []const u8,
    info: ChildInfo,
};

pub fn computeNodeTypes(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) ComputeNodeTypesError![]const NodeType {
    var summary_context = try SummaryContext.init(allocator, syntax, lexical, defaults);
    var nodes = std.array_list.Managed(NodeType).init(allocator);
    defer nodes.deinit();

    for (syntax.variables, 0..) |variable, index| {
        const symbol: syntax_ir.SymbolRef = .{ .non_terminal = @intCast(index) };
        const summary = try summary_context.get(index);
        const is_supertype = containsSymbolRef(syntax.supertype_symbols, symbol);
        const subtype_refs = if (is_supertype)
            try computeSupertypeRefs(allocator, symbol, summary)
        else
            &.{};

        if (is_supertype) {
            try nodes.append(.{
                .kind = variable.name,
                .named = true,
                .root = index == 0,
                .extra = containsSymbolRef(syntax.extra_symbols, symbol),
                .subtypes = subtype_refs,
            });
            continue;
        }

        if (!isVisibleSyntaxVariable(variable)) continue;

        try nodes.append(.{
            .kind = effectiveNameForSymbol(symbol, syntax, lexical, defaults),
            .named = isNamedSyntaxVariable(variable, defaults.findForSymbol(symbol)),
            .root = index == 0,
            .extra = containsSymbolRef(syntax.extra_symbols, symbol),
            .fields = summary.fields,
            .children = summary.children_without_fields,
            .subtypes = subtype_refs,
        });
    }

    for (lexical.variables, 0..) |variable, index| {
        const symbol: syntax_ir.SymbolRef = .{ .terminal = @intCast(index) };
        if (!isVisibleLexicalVariable(variable, defaults.findForSymbol(symbol))) continue;

        try nodes.append(.{
            .kind = effectiveNameForSymbol(symbol, syntax, lexical, defaults),
            .named = isNamedLexicalVariable(variable, defaults.findForSymbol(symbol)),
            .extra = containsSymbolRef(syntax.extra_symbols, symbol),
        });
    }

    for (syntax.external_tokens, 0..) |token, index| {
        const symbol: syntax_ir.SymbolRef = .{ .external = @intCast(index) };
        if (!isVisibleExternalToken(token, defaults.findForSymbol(symbol))) continue;

        try nodes.append(.{
            .kind = effectiveNameForSymbol(symbol, syntax, lexical, defaults),
            .named = isNamedExternalToken(token, defaults.findForSymbol(symbol)),
            .extra = containsSymbolRef(syntax.extra_symbols, symbol),
        });
    }

    std.mem.sort(NodeType, nodes.items, {}, lessThanNodeType);
    return try mergeDuplicateNodeTypes(allocator, nodes.items);
}

fn computeSupertypeRefs(
    allocator: std.mem.Allocator,
    supertype_symbol: syntax_ir.SymbolRef,
    summary: *const VariableSummary,
) ComputeNodeTypesError![]const NodeTypeRef {
    var refs = std.array_list.Managed(NodeTypeRef).init(allocator);
    defer refs.deinit();

    const supertype_index = switch (supertype_symbol) {
        .non_terminal => |index| index,
        else => return error.InvalidSupertype,
    };

    _ = supertype_index;
    if (summary.has_multi_step_production) return error.InvalidSupertype;
    if (summary.children) |children| {
        for (children.types) |candidate| {
            if (!containsNodeTypeRef(refs.items, candidate)) {
                try refs.append(candidate);
            }
        }
    }

    std.mem.sort(NodeTypeRef, refs.items, {}, lessThanNodeTypeRef);
    return try refs.toOwnedSlice();
}

const FieldAccumulator = struct {
    quantity: ?ChildQuantity = null,
    types: std.array_list.Managed(NodeTypeRef),

    fn init(allocator: std.mem.Allocator) FieldAccumulator {
        return .{
            .types = std.array_list.Managed(NodeTypeRef).init(allocator),
        };
    }
};

const VariableSummary = struct {
    fields: []const Field = &.{},
    children: ?ChildInfo = null,
    children_without_fields: ?ChildInfo = null,
    has_multi_step_production: bool = false,
};

const SummaryState = enum {
    pending,
    visiting,
    done,
};

const SummaryContext = struct {
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
    states: []SummaryState,
    summaries: []VariableSummary,

    fn init(
        allocator: std.mem.Allocator,
        syntax: syntax_ir.SyntaxGrammar,
        lexical: lexical_ir.LexicalGrammar,
        defaults: alias_ir.AliasMap,
    ) ComputeNodeTypesError!SummaryContext {
        const states = try allocator.alloc(SummaryState, syntax.variables.len);
        const summaries = try allocator.alloc(VariableSummary, syntax.variables.len);
        for (states) |*state| state.* = .pending;
        for (summaries) |*summary| summary.* = .{};
        return .{
            .allocator = allocator,
            .syntax = syntax,
            .lexical = lexical,
            .defaults = defaults,
            .states = states,
            .summaries = summaries,
        };
    }

    fn get(self: *SummaryContext, index: usize) ComputeNodeTypesError!*const VariableSummary {
        switch (self.states[index]) {
            .done => return &self.summaries[index],
            .visiting => return &self.summaries[index],
            .pending => {},
        }

        self.states[index] = .visiting;
        self.summaries[index] = .{};

        const variable = self.syntax.variables[index];
        var field_map = std.StringArrayHashMap(FieldAccumulator).init(self.allocator);
        var child_types = std.array_list.Managed(NodeTypeRef).init(self.allocator);
        var children_quantity: ?ChildQuantity = null;
        var child_types_without_fields = std.array_list.Managed(NodeTypeRef).init(self.allocator);
        var children_without_fields_quantity: ?ChildQuantity = null;
        var has_multi_step = false;

        for (variable.productions, 0..) |production, production_index| {
            var production_field_quantities = std.StringArrayHashMap(ChildQuantity).init(self.allocator);
            defer production_field_quantities.deinit();
            var production_children_quantity = ChildQuantity.zero();
            var production_children_without_fields_quantity = ChildQuantity.zero();

            if (production.steps.len > 1) has_multi_step = true;

            for (production.steps) |step| {
                const hidden_index = self.hiddenInheritableIndex(step.symbol);
                if (hidden_index) |child_index| {
                    const child_summary = try self.get(child_index);
                    if (child_summary.has_multi_step_production) has_multi_step = true;

                    if (child_summary.children) |children| {
                        for (children.types) |child_type| {
                            try addNodeTypeRef(&child_types, child_type);
                        }
                        production_children_quantity.append(children.quantity);

                        if (step.field_name) |field_name| {
                            const acc = try getFieldAccumulator(self.allocator, &field_map, field_name, production_index);
                            for (children.types) |child_type| {
                                try addNodeTypeRef(&acc.types, child_type);
                            }
                            const qty = try getProductionFieldQuantity(&production_field_quantities, field_name);
                            qty.append(children.quantity);
                        }
                    }

                    if (step.field_name == null) {
                        if (child_summary.children_without_fields) |children_without_fields| {
                            for (children_without_fields.types) |child_type| {
                                try addNodeTypeRef(&child_types_without_fields, child_type);
                            }
                            production_children_without_fields_quantity.append(children_without_fields.quantity);
                        }
                    }

                    for (child_summary.fields) |child_field| {
                        const acc = try getFieldAccumulator(self.allocator, &field_map, child_field.name, production_index);
                        for (child_field.info.types) |child_type| {
                            try addNodeTypeRef(&acc.types, child_type);
                        }
                        const qty = try getProductionFieldQuantity(&production_field_quantities, child_field.name);
                        qty.append(child_field.info.quantity);
                    }
                    continue;
                }

                if (!isVisibleStep(step, self.syntax, self.lexical, self.defaults)) continue;

                const child_type = NodeTypeRef{
                    .kind = effectiveNameForStep(step, self.syntax, self.lexical, self.defaults),
                    .named = isNamedStep(step, self.syntax, self.lexical, self.defaults),
                };
                try addNodeTypeRef(&child_types, child_type);
                production_children_quantity.append(ChildQuantity.one());

                if (step.field_name) |field_name| {
                    const acc = try getFieldAccumulator(self.allocator, &field_map, field_name, production_index);
                    try addNodeTypeRef(&acc.types, child_type);
                    const qty = try getProductionFieldQuantity(&production_field_quantities, field_name);
                    qty.append(ChildQuantity.one());
                } else if (child_type.named) {
                    try addNodeTypeRef(&child_types_without_fields, child_type);
                    production_children_without_fields_quantity.append(ChildQuantity.one());
                }
            }

            children_quantity = if (children_quantity) |existing|
                ChildQuantity.mergeAlternatives(existing, production_children_quantity)
            else
                production_children_quantity;

            children_without_fields_quantity = if (children_without_fields_quantity) |existing|
                ChildQuantity.mergeAlternatives(existing, production_children_without_fields_quantity)
            else
                production_children_without_fields_quantity;

            var iter = field_map.iterator();
            while (iter.next()) |entry| {
                const qty = production_field_quantities.get(entry.key_ptr.*) orelse ChildQuantity.zero();
                entry.value_ptr.quantity = if (entry.value_ptr.quantity) |existing|
                    ChildQuantity.mergeAlternatives(existing, qty)
                else
                    qty;
            }
        }

        var fields = std.array_list.Managed(Field).init(self.allocator);
        var field_iter = field_map.iterator();
        while (field_iter.next()) |entry| {
            std.mem.sort(NodeTypeRef, entry.value_ptr.types.items, {}, lessThanNodeTypeRef);
            try fields.append(.{
                .name = entry.key_ptr.*,
                .info = .{
                    .quantity = entry.value_ptr.quantity orelse ChildQuantity.zero(),
                    .types = try entry.value_ptr.types.toOwnedSlice(),
                },
            });
        }
        std.mem.sort(Field, fields.items, {}, lessThanField);

        std.mem.sort(NodeTypeRef, child_types.items, {}, lessThanNodeTypeRef);
        std.mem.sort(NodeTypeRef, child_types_without_fields.items, {}, lessThanNodeTypeRef);
        self.summaries[index] = .{
            .fields = try fields.toOwnedSlice(),
            .children = if (children_quantity) |qty|
                if (qty.exists and child_types.items.len > 0)
                    .{
                        .quantity = qty,
                        .types = try child_types.toOwnedSlice(),
                    }
                else
                    null
            else
                null,
            .children_without_fields = if (children_without_fields_quantity) |qty|
                if (qty.exists and child_types_without_fields.items.len > 0)
                    .{
                        .quantity = qty,
                        .types = try child_types_without_fields.toOwnedSlice(),
                    }
                else
                    null
            else
                null,
            .has_multi_step_production = has_multi_step,
        };
        self.states[index] = .done;
        return &self.summaries[index];
    }

    fn hiddenInheritableIndex(self: *SummaryContext, symbol: syntax_ir.SymbolRef) ?usize {
        const index = switch (symbol) {
            .non_terminal => |i| i,
            else => return null,
        };
        if (containsSymbolRef(self.syntax.supertype_symbols, symbol)) return null;
        if (isVisibleSyntaxVariable(self.syntax.variables[index])) return null;
        return index;
    }
};

fn getFieldAccumulator(
    allocator: std.mem.Allocator,
    map: *std.StringArrayHashMap(FieldAccumulator),
    field_name: []const u8,
    prior_production_count: usize,
) ComputeNodeTypesError!*FieldAccumulator {
    const gop = try map.getOrPut(field_name);
    if (!gop.found_existing) {
        gop.value_ptr.* = FieldAccumulator.init(allocator);
        if (prior_production_count > 0) {
            gop.value_ptr.quantity = ChildQuantity.zero();
        }
    }
    return gop.value_ptr;
}

fn getProductionFieldQuantity(
    map: *std.StringArrayHashMap(ChildQuantity),
    field_name: []const u8,
) ComputeNodeTypesError!*ChildQuantity {
    const gop = try map.getOrPut(field_name);
    if (!gop.found_existing) gop.value_ptr.* = ChildQuantity.zero();
    return gop.value_ptr;
}

fn addNodeTypeRef(list: *std.array_list.Managed(NodeTypeRef), candidate: NodeTypeRef) ComputeNodeTypesError!void {
    if (!containsNodeTypeRef(list.items, candidate)) {
        try list.append(candidate);
    }
}

fn mergeDuplicateNodeTypes(
    allocator: std.mem.Allocator,
    nodes: []const NodeType,
) ComputeNodeTypesError![]const NodeType {
    var merged = std.array_list.Managed(NodeType).init(allocator);
    defer merged.deinit();

    for (nodes) |node| {
        if (merged.items.len > 0 and sameNodeTypeKey(merged.items[merged.items.len - 1], node)) {
            merged.items[merged.items.len - 1] = try mergeNodeType(allocator, merged.items[merged.items.len - 1], node);
            continue;
        }
        try merged.append(node);
    }

    return try merged.toOwnedSlice();
}

fn mergeNodeType(
    allocator: std.mem.Allocator,
    left: NodeType,
    right: NodeType,
) ComputeNodeTypesError!NodeType {
    return .{
        .kind = left.kind,
        .named = left.named,
        .root = left.root or right.root,
        .extra = left.extra or right.extra,
        .fields = try mergeFields(allocator, left.fields, right.fields),
        .children = try mergeChildInfo(allocator, left.children, right.children),
        .subtypes = try mergeNodeTypeRefs(allocator, left.subtypes, right.subtypes),
    };
}

fn mergeFields(
    allocator: std.mem.Allocator,
    left: []const Field,
    right: []const Field,
) ComputeNodeTypesError![]const Field {
    if (left.len == 0) return right;
    if (right.len == 0) return left;

    var merged = std.array_list.Managed(Field).init(allocator);
    defer merged.deinit();

    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        if (i == left.len) {
            try merged.append(right[j]);
            j += 1;
            continue;
        }
        if (j == right.len) {
            try merged.append(left[i]);
            i += 1;
            continue;
        }

        const order = std.mem.order(u8, left[i].name, right[j].name);
        switch (order) {
            .lt => {
                try merged.append(left[i]);
                i += 1;
            },
            .gt => {
                try merged.append(right[j]);
                j += 1;
            },
            .eq => {
                try merged.append(.{
                    .name = left[i].name,
                    .info = (try mergeChildInfo(allocator, left[i].info, right[j].info)).?,
                });
                i += 1;
                j += 1;
            },
        }
    }

    return try merged.toOwnedSlice();
}

fn mergeChildInfo(
    allocator: std.mem.Allocator,
    left: ?ChildInfo,
    right: ?ChildInfo,
) ComputeNodeTypesError!?ChildInfo {
    if (left == null) return right;
    if (right == null) return left;

    return .{
        .quantity = ChildQuantity.mergeAlternatives(left.?.quantity, right.?.quantity),
        .types = try mergeNodeTypeRefs(allocator, left.?.types, right.?.types),
    };
}

fn mergeNodeTypeRefs(
    allocator: std.mem.Allocator,
    left: []const NodeTypeRef,
    right: []const NodeTypeRef,
) ComputeNodeTypesError![]const NodeTypeRef {
    if (left.len == 0) return right;
    if (right.len == 0) return left;

    var merged = std.array_list.Managed(NodeTypeRef).init(allocator);
    defer merged.deinit();
    try merged.appendSlice(left);
    for (right) |candidate| {
        try addNodeTypeRef(&merged, candidate);
    }
    std.mem.sort(NodeTypeRef, merged.items, {}, lessThanNodeTypeRef);
    return try merged.toOwnedSlice();
}

fn isVisibleChild(
    symbol: syntax_ir.SymbolRef,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) bool {
    return switch (symbol) {
        .non_terminal => |index| isVisibleSyntaxVariable(syntax.variables[index]),
        .terminal => |index| isVisibleLexicalVariable(lexical.variables[index], defaults.findForSymbol(symbol)),
        .external => |index| isVisibleExternalToken(syntax.external_tokens[index], defaults.findForSymbol(symbol)),
    };
}

fn isVisibleStep(
    step: syntax_ir.ProductionStep,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) bool {
    if (step.alias != null) return true;
    if (defaults.findForSymbol(step.symbol) != null) return true;
    return isVisibleChild(step.symbol, syntax, lexical, defaults);
}

fn effectiveNameForSymbol(
    symbol: syntax_ir.SymbolRef,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) []const u8 {
    if (defaults.findForSymbol(symbol)) |alias| return alias.value;

    return switch (symbol) {
        .non_terminal => |index| syntax.variables[index].name,
        .terminal => |index| lexical.variables[index].name,
        .external => |index| syntax.external_tokens[index].name,
    };
}

fn effectiveNameForStep(
    step: syntax_ir.ProductionStep,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) []const u8 {
    if (step.alias) |alias| return alias.value;
    return effectiveNameForSymbol(step.symbol, syntax, lexical, defaults);
}

fn isNamedSymbol(
    symbol: syntax_ir.SymbolRef,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) bool {
    const alias = defaults.findForSymbol(symbol);
    return switch (symbol) {
        .non_terminal => |index| isNamedSyntaxVariable(syntax.variables[index], alias),
        .terminal => |index| isNamedLexicalVariable(lexical.variables[index], alias),
        .external => |index| isNamedExternalToken(syntax.external_tokens[index], alias),
    };
}

fn isNamedStep(
    step: syntax_ir.ProductionStep,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    defaults: alias_ir.AliasMap,
) bool {
    if (step.alias) |alias| return alias.named;
    return isNamedSymbol(step.symbol, syntax, lexical, defaults);
}

fn isVisibleSyntaxVariable(variable: syntax_ir.SyntaxVariable) bool {
    return switch (variable.kind) {
        .hidden, .auxiliary => false,
        .named, .anonymous => true,
    };
}

fn isNamedSyntaxVariable(variable: syntax_ir.SyntaxVariable, alias: ?rules.Alias) bool {
    if (alias) |a| return a.named;
    return switch (variable.kind) {
        .named => true,
        .anonymous, .hidden, .auxiliary => false,
    };
}

fn isVisibleLexicalVariable(variable: lexical_ir.LexicalVariable, alias: ?rules.Alias) bool {
    if (alias != null) return true;
    return switch (variable.kind) {
        .hidden, .auxiliary => false,
        .named, .anonymous => true,
    };
}

fn isNamedLexicalVariable(variable: lexical_ir.LexicalVariable, alias: ?rules.Alias) bool {
    if (alias) |a| return a.named;
    return switch (variable.kind) {
        .named => true,
        .anonymous, .hidden, .auxiliary => false,
    };
}

fn isVisibleExternalToken(token: syntax_ir.ExternalToken, alias: ?rules.Alias) bool {
    if (alias != null) return true;
    return switch (token.kind) {
        .hidden, .auxiliary => false,
        .named, .anonymous => true,
    };
}

fn isNamedExternalToken(token: syntax_ir.ExternalToken, alias: ?rules.Alias) bool {
    if (alias) |a| return a.named;
    return switch (token.kind) {
        .named => true,
        .anonymous, .hidden, .auxiliary => false,
    };
}

fn containsSymbolRef(haystack: []const syntax_ir.SymbolRef, needle: syntax_ir.SymbolRef) bool {
    for (haystack) |entry| {
        if (symbolRefEql(entry, needle)) return true;
    }
    return false;
}

fn containsNodeTypeRef(haystack: []const NodeTypeRef, needle: NodeTypeRef) bool {
    for (haystack) |entry| {
        if (std.mem.eql(u8, entry.kind, needle.kind) and entry.named == needle.named) return true;
    }
    return false;
}

fn sameNodeTypeKey(a: NodeType, b: NodeType) bool {
    return std.mem.eql(u8, a.kind, b.kind) and a.named == b.named;
}

fn symbolRefEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
        .non_terminal => |index| switch (b) {
            .non_terminal => |other| index == other,
            else => false,
        },
        .terminal => |index| switch (b) {
            .terminal => |other| index == other,
            else => false,
        },
        .external => |index| switch (b) {
            .external => |other| index == other,
            else => false,
        },
    };
}

fn lessThanNodeType(_: void, a: NodeType, b: NodeType) bool {
    const kind_order = std.mem.order(u8, a.kind, b.kind);
    if (kind_order != .eq) return kind_order == .lt;
    return @intFromBool(a.named) < @intFromBool(b.named);
}

fn lessThanNodeTypeRef(_: void, a: NodeTypeRef, b: NodeTypeRef) bool {
    const kind_order = std.mem.order(u8, a.kind, b.kind);
    if (kind_order != .eq) return kind_order == .lt;
    return @intFromBool(a.named) < @intFromBool(b.named);
}

fn lessThanField(_: void, a: Field, b: Field) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

test "computeNodeTypes includes visible syntax and lexical nodes with default aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 0 } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = root_steps[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
            .{ .name = "_hidden", .kind = .hidden, .productions = &.{.{ .steps = &.{} }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{.{ .terminal = 0 }},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "comma", .kind = .anonymous, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
        },
        .separators = &.{},
    };
    const defaults = alias_ir.AliasMap{
        .entries = &.{.{
            .target = .{ .symbol = .{ .terminal = 0 } },
            .alias = .{ .value = ",", .named = false },
        }},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, defaults);
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expectEqualStrings(",", nodes[0].kind);
    try std.testing.expect(!nodes[0].named);
    try std.testing.expect(nodes[0].extra);
    try std.testing.expectEqualStrings("expr", nodes[1].kind);
    try std.testing.expect(nodes[1].named);
    try std.testing.expectEqualStrings("identifier", nodes[2].kind);
    try std.testing.expectEqualStrings("source_file", nodes[3].kind);
    try std.testing.expect(nodes[3].root);
}

test "computeNodeTypes merges duplicate entries with the same effective type name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "expr", .kind = .named, .rule = 0 },
        },
        .separators = &.{},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, .{ .entries = &.{} });
    try std.testing.expectEqual(@as(usize, 2), nodes.len);

    const expr = findNodeByKind(nodes, "expr").?;
    try std.testing.expect(expr.children != null);
    try std.testing.expectEqual(@as(usize, 1), expr.children.?.types.len);
    try std.testing.expectEqualStrings("expr", expr.children.?.types[0].kind);
}

test "computeNodeTypes includes visible external tokens with real names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .external = 1 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
        },
        .external_tokens = &.{
            .{ .name = "_automatic_semicolon", .kind = .hidden },
            .{ .name = "template_chars", .kind = .named },
        },
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{},
        .separators = &.{},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, .{ .entries = &.{} });
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings("source_file", nodes[0].kind);
    try std.testing.expectEqualStrings("template_chars", nodes[1].kind);
    try std.testing.expect(nodes[1].named);
}

test "computeNodeTypes applies default aliases to external tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = &.{} }} },
        },
        .external_tokens = &.{
            .{ .name = "template_chars", .kind = .named },
        },
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{},
        .separators = &.{},
    };
    const defaults = alias_ir.AliasMap{
        .entries = &.{.{
            .target = .{ .symbol = .{ .external = 0 } },
            .alias = .{ .value = "template_chunk", .named = true },
        }},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, defaults);
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings("source_file", nodes[0].kind);
    try std.testing.expectEqualStrings("template_chunk", nodes[1].kind);
    try std.testing.expect(nodes[1].named);
}

test "computeNodeTypes computes visible supertype subtypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var super_prod_a = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var super_prod_b = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 3 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = root_steps[0..] }} },
            .{ .name = "expression", .kind = .named, .productions = &.{.{ .steps = super_prod_a[0..] }, .{ .steps = super_prod_b[0..] }} },
            .{ .name = "binary_expression", .kind = .named, .productions = &.{.{ .steps = &.{} }} },
            .{ .name = "identifier", .kind = .named, .productions = &.{.{ .steps = &.{} }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{.{ .non_terminal = 1 }},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{},
        .separators = &.{},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, .{ .entries = &.{} });
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expectEqualStrings("expression", nodes[1].kind);
    try std.testing.expectEqual(@as(usize, 2), nodes[1].subtypes.len);
    try std.testing.expectEqualStrings("binary_expression", nodes[1].subtypes[0].kind);
    try std.testing.expectEqualStrings("identifier", nodes[1].subtypes[1].kind);
}

test "computeNodeTypes aggregates fields and visible children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var prod1 = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 }, .field_name = "left" },
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .non_terminal = 2 }, .field_name = "right", .alias = .{ .value = "rhs", .named = true } },
    };
    var prod2 = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 }, .field_name = "left" },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };
    var term_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 2 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{ .{ .steps = prod1[0..] }, .{ .steps = prod2[0..] } } },
            .{ .name = "expr", .kind = .named, .productions = &.{ .{ .steps = expr_steps[0..] } } },
            .{ .name = "term", .kind = .named, .productions = &.{ .{ .steps = term_steps[0..] } } },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "+", .kind = .anonymous, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
            .{ .name = "number", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, .{ .entries = &.{} });
    const source = findNodeByKind(nodes, "source_file").?;
    try std.testing.expect(source.children == null);
    try std.testing.expectEqual(@as(usize, 2), source.fields.len);
    try std.testing.expectEqualStrings("left", source.fields[0].name);
    try std.testing.expect(source.fields[0].info.quantity.required);
    try std.testing.expect(!source.fields[0].info.quantity.multiple);
    try std.testing.expectEqualStrings("expr", source.fields[0].info.types[0].kind);
    try std.testing.expectEqualStrings("right", source.fields[1].name);
    try std.testing.expect(!source.fields[1].info.quantity.required);
    try std.testing.expectEqualStrings("rhs", source.fields[1].info.types[0].kind);
}

test "computeNodeTypes inherits fields and children through hidden wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var hidden_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 }, .field_name = "left" },
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .non_terminal = 3 }, .field_name = "right", .alias = .{ .value = "rhs", .named = true } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };
    var term_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 2 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "_pair", .kind = .hidden, .productions = &.{.{ .steps = hidden_steps[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
            .{ .name = "term", .kind = .named, .productions = &.{.{ .steps = term_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "+", .kind = .anonymous, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
            .{ .name = "number", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, .{ .entries = &.{} });
    const source = findNodeByKind(nodes, "source_file").?;
    try std.testing.expect(source.children == null);
    try std.testing.expectEqual(@as(usize, 2), source.fields.len);
    try std.testing.expectEqualStrings("left", source.fields[0].name);
    try std.testing.expectEqualStrings("expr", source.fields[0].info.types[0].kind);
    try std.testing.expectEqualStrings("right", source.fields[1].name);
    try std.testing.expectEqualStrings("rhs", source.fields[1].info.types[0].kind);
}

test "computeNodeTypes emits only named children without fields in children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var prod = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 }, .field_name = "left" },
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };
    var stmt_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 2 } },
    };

    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = prod[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
            .{ .name = "stmt", .kind = .named, .productions = &.{.{ .steps = stmt_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "+", .kind = .anonymous, .rule = 0 },
            .{ .name = "identifier", .kind = .named, .rule = 1 },
            .{ .name = "statement", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    const nodes = try computeNodeTypes(arena.allocator(), syntax, lexical, .{ .entries = &.{} });
    const source = findNodeByKind(nodes, "source_file").?;
    try std.testing.expect(source.children != null);
    try std.testing.expectEqual(@as(usize, 1), source.children.?.types.len);
    try std.testing.expectEqualStrings("stmt", source.children.?.types[0].kind);
    try std.testing.expect(source.children.?.quantity.required);
    try std.testing.expect(!source.children.?.quantity.multiple);
}

fn findNodeByKind(nodes: []const NodeType, kind: []const u8) ?NodeType {
    for (nodes) |node| {
        if (std.mem.eql(u8, node.kind, kind)) return node;
    }
    return null;
}

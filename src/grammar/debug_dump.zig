const std = @import("std");
const ir = @import("../ir/grammar_ir.zig");
const ir_rules = @import("../ir/rules.zig");
const ir_symbols = @import("../ir/symbols.zig");
const fixtures = @import("../tests/fixtures.zig");
const golden = @import("../tests/golden.zig");
const json_loader = @import("json_loader.zig");
const parse_grammar = @import("parse_grammar.zig");

pub fn dumpPreparedGrammar(allocator: std.mem.Allocator, prepared: ir.PreparedGrammar) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try writePreparedGrammar(&out.writer, prepared);
    return try out.toOwnedSlice();
}

pub fn writePreparedGrammar(writer: anytype, prepared: ir.PreparedGrammar) !void {
    try writer.print("grammar: {s}\n", .{prepared.grammar_name});
    try writer.print("symbols: {d}\n", .{prepared.symbols.len});
    for (prepared.symbols, 0..) |symbol, i| {
        try writer.print("  symbol[{d}]: {s} kind=", .{ i, symbolKindName(symbol.id.kind) });
        try writeSymbolId(writer, symbol.id);
        try writer.print(" name=\"{s}\" named={} visible={} supertype={}\n", .{ symbol.name, symbol.named, symbol.visible, symbol.supertype });
    }

    try writer.print("variables: {d}\n", .{prepared.variables.len});
    for (prepared.variables, 0..) |variable, i| {
        try writer.print(
            "  variable[{d}]: name=\"{s}\" kind={s} symbol=",
            .{ i, variable.name, @tagName(variable.kind) },
        );
        try writeSymbolId(writer, variable.symbol);
        try writer.print(" rule={d}\n", .{variable.rule});
    }

    try writer.print("external_tokens: {d}\n", .{prepared.external_tokens.len});
    for (prepared.external_tokens, 0..) |external, i| {
        try writer.print(
            "  external[{d}]: name=\"{s}\" kind={s} symbol=",
            .{ i, external.name, @tagName(external.kind) },
        );
        try writeSymbolId(writer, external.symbol);
        try writer.print(" rule={d}\n", .{external.rule});
    }

    try writeRuleList(writer, "extra_rules", prepared.extra_rules);
    try writeConflictSets(writer, prepared.expected_conflicts);
    try writePrecedenceOrderings(writer, prepared.precedence_orderings);
    try writeSymbolList(writer, "variables_to_inline", prepared.variables_to_inline);
    try writeSymbolList(writer, "supertype_symbols", prepared.supertype_symbols);

    if (prepared.word_token) |word_token| {
        try writer.writeAll("word_token: ");
        try writeSymbolId(writer, word_token);
        try writer.writeByte('\n');
    } else {
        try writer.writeAll("word_token: none\n");
    }

    try writer.print("reserved_word_sets: {d}\n", .{prepared.reserved_word_sets.len});
    for (prepared.reserved_word_sets, 0..) |reserved_set, i| {
        try writer.print("  reserved[{d}]: context=\"{s}\" members=", .{ i, reserved_set.context_name });
        try writeRuleIds(writer, reserved_set.members);
        try writer.writeByte('\n');
    }

    try writer.print("rules: {d}\n", .{prepared.rules.len});
    for (prepared.rules, 0..) |rule, i| {
        try writer.print("  rule[{d}]: ", .{i});
        try writeRule(writer, prepared, rule);
        try writer.writeByte('\n');
    }
}

fn writeRule(writer: anytype, prepared: ir.PreparedGrammar, rule: ir_rules.Rule) !void {
    switch (rule) {
        .blank => try writer.writeAll("blank"),
        .symbol => |symbol| {
            try writer.writeAll("symbol(");
            try writeSymbolId(writer, symbol);
            try writer.writeByte(')');
        },
        .string => |value| try writer.print("string(\"{s}\")", .{value}),
        .pattern => |pattern| {
            try writer.print("pattern(\"{s}\"", .{pattern.value});
            if (pattern.flags) |flags| {
                try writer.print(", flags=\"{s}\"", .{flags});
            }
            try writer.writeByte(')');
        },
        .choice => |members| {
            try writer.writeAll("choice(");
            try writeRuleIds(writer, members);
            try writer.writeByte(')');
        },
        .seq => |members| {
            try writer.writeAll("seq(");
            try writeRuleIds(writer, members);
            try writer.writeByte(')');
        },
        .repeat => |inner| try writer.print("repeat({d})", .{inner}),
        .repeat1 => |inner| try writer.print("repeat1({d})", .{inner}),
        .metadata => |metadata| {
            try writer.print("metadata(inner={d}, ", .{metadata.inner});
            try writeMetadata(writer, prepared, metadata.data);
            try writer.writeByte(')');
        },
    }
}

fn writeMetadata(writer: anytype, prepared: ir.PreparedGrammar, metadata: ir_rules.Metadata) !void {
    _ = prepared;
    var first = true;

    if (metadata.field_name) |field_name| {
        try writeMetadataField(writer, &first, "field", field_name);
    }
    if (metadata.alias) |alias| {
        if (!first) try writer.writeAll(", ");
        try writer.print("alias=\"{s}\"", .{alias.value});
        try writer.print(", alias_named={}", .{alias.named});
        first = false;
    }
    switch (metadata.precedence) {
        .none => {},
        .integer => |value| {
            if (!first) try writer.writeAll(", ");
            try writer.print("precedence={d}", .{value});
            first = false;
        },
        .name => |value| {
            if (!first) try writer.writeAll(", ");
            try writer.print("precedence=\"{s}\"", .{value});
            first = false;
        },
    }
    if (metadata.associativity != .none) {
        if (!first) try writer.writeAll(", ");
        try writer.print("assoc={s}", .{@tagName(metadata.associativity)});
        first = false;
    }
    if (metadata.dynamic_precedence != 0) {
        if (!first) try writer.writeAll(", ");
        try writer.print("dynamic_precedence={d}", .{metadata.dynamic_precedence});
        first = false;
    }
    if (metadata.token) {
        if (!first) try writer.writeAll(", ");
        try writer.writeAll("token=true");
        first = false;
    }
    if (metadata.immediate_token) {
        if (!first) try writer.writeAll(", ");
        try writer.writeAll("immediate_token=true");
        first = false;
    }
    if (metadata.reserved_context_name) |context_name| {
        try writeMetadataField(writer, &first, "reserved", context_name);
    }
    if (first) {
        try writer.writeAll("empty");
    }
}

fn writeMetadataField(writer: anytype, first: *bool, name: []const u8, value: []const u8) !void {
    if (!first.*) try writer.writeAll(", ");
    try writer.print("{s}=\"{s}\"", .{ name, value });
    first.* = false;
}

fn writeRuleList(writer: anytype, label: []const u8, rules: []const ir_rules.RuleId) !void {
    try writer.print("{s}: ", .{label});
    try writeRuleIds(writer, rules);
    try writer.writeByte('\n');
}

fn writeRuleIds(writer: anytype, rules: []const ir_rules.RuleId) !void {
    try writer.writeByte('[');
    for (rules, 0..) |rule_id, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{rule_id});
    }
    try writer.writeByte(']');
}

fn writeConflictSets(writer: anytype, conflict_sets: []const ir.ConflictSet) !void {
    try writer.print("expected_conflicts: {d}\n", .{conflict_sets.len});
    for (conflict_sets, 0..) |conflict_set, i| {
        try writer.print("  conflict[{d}]: ", .{i});
        try writeSymbolIds(writer, conflict_set);
        try writer.writeByte('\n');
    }
}

fn writePrecedenceOrderings(writer: anytype, orderings: []const ir.PrecedenceOrdering) !void {
    try writer.print("precedence_orderings: {d}\n", .{orderings.len});
    for (orderings, 0..) |ordering, i| {
        try writer.print("  precedence[{d}]: [", .{i});
        for (ordering, 0..) |entry, j| {
            if (j != 0) try writer.writeAll(", ");
            switch (entry) {
                .name => |name| try writer.print("\"{s}\"", .{name}),
                .symbol => |symbol| try writeSymbolId(writer, symbol),
            }
        }
        try writer.writeAll("]\n");
    }
}

fn writeSymbolList(writer: anytype, label: []const u8, symbols: []const ir_symbols.SymbolId) !void {
    try writer.print("{s}: ", .{label});
    try writeSymbolIds(writer, symbols);
    try writer.writeByte('\n');
}

fn writeSymbolIds(writer: anytype, symbols: []const ir_symbols.SymbolId) !void {
    try writer.writeByte('[');
    for (symbols, 0..) |symbol, i| {
        if (i != 0) try writer.writeAll(", ");
        try writeSymbolId(writer, symbol);
    }
    try writer.writeByte(']');
}

fn writeSymbolId(writer: anytype, symbol: ir_symbols.SymbolId) !void {
    const prefix: u8 = switch (symbol.kind) {
        .non_terminal => 'n',
        .external => 'e',
    };
    try writer.print("{c}{d}", .{ prefix, symbol.index });
}

fn symbolKindName(kind: ir_symbols.SymbolKind) []const u8 {
    return @tagName(kind);
}

test "dumpPreparedGrammar prints a deterministic summary" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), fixtures.validResolvedGrammarJson().contents, .{});
    defer parsed.deinit();

    const raw_grammar = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw_grammar);
    const dump = try dumpPreparedGrammar(std.testing.allocator, prepared);
    defer std.testing.allocator.free(dump);

    try golden.expectContains(dump, "grammar: basic");
    try golden.expectContains(dump, "symbols: 4");
    try golden.expectContains(dump, "variable[1]: name=\"expr\" kind=hidden symbol=n1");
    try golden.expectContains(dump, "external[0]: name=\"indent\" kind=named symbol=e0");
    try golden.expectContains(dump, "variables_to_inline: [n2]");
    try golden.expectContains(dump, "supertype_symbols: [n1]");
    try golden.expectContains(dump, "word_token: n2");
    try golden.expectContains(dump, "reserved[0]: context=\"global\" members=[10]");
}

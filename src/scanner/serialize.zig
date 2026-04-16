const std = @import("std");
const grammar_ir = @import("../ir/grammar_ir.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const json_loader = @import("../grammar/json_loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const SerializeError = std.mem.Allocator.Error;

pub const SerializedExternalToken = struct {
    index: u32,
    name: []const u8,
    kind: syntax_ir.VariableKind,
};

pub const SerializedExternalUse = struct {
    external_index: u32,
    variable_name: []const u8,
    production_index: usize,
    step_index: usize,
    field_name: ?[]const u8,
};

pub const UseLocation = struct {
    variable_name: []const u8,
    production_index: usize,
    step_index: usize,
};

pub const UnsupportedExternalScannerFeature = union(enum) {
    missing_external_tokens,
    multiple_external_tokens: usize,
    extra_symbols: usize,
    non_leading_external_step: UseLocation,
    multiple_external_steps_in_production: struct {
        variable_name: []const u8,
        production_index: usize,
        count: usize,
    },
};

pub const SerializedExternalScannerBoundary = struct {
    tokens: []const SerializedExternalToken,
    uses: []const SerializedExternalUse,
    unsupported_features: []const UnsupportedExternalScannerFeature,
    blocked: bool,

    pub fn isReady(self: SerializedExternalScannerBoundary) bool {
        return !self.blocked;
    }
};

pub fn serializeExternalScannerBoundary(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
) SerializeError!SerializedExternalScannerBoundary {
    const tokens = try allocator.alloc(SerializedExternalToken, syntax.external_tokens.len);
    for (syntax.external_tokens, 0..) |token, index| {
        tokens[index] = .{
            .index = @intCast(index),
            .name = token.name,
            .kind = token.kind,
        };
    }

    var uses = std.array_list.Managed(SerializedExternalUse).init(allocator);
    defer uses.deinit();
    var unsupported = std.array_list.Managed(UnsupportedExternalScannerFeature).init(allocator);
    defer unsupported.deinit();

    if (syntax.external_tokens.len == 0) {
        try unsupported.append(.missing_external_tokens);
    } else if (syntax.external_tokens.len > 1) {
        try unsupported.append(.{ .multiple_external_tokens = syntax.external_tokens.len });
    }

    for (syntax.variables) |variable| {
        for (variable.productions, 0..) |production, production_index| {
            var external_steps_in_production: usize = 0;
            for (production.steps, 0..) |step, step_index| {
                const external_index = switch (step.symbol) {
                    .external => |index| index,
                    else => continue,
                };

                external_steps_in_production += 1;
                try uses.append(.{
                    .external_index = external_index,
                    .variable_name = variable.name,
                    .production_index = production_index,
                    .step_index = step_index,
                    .field_name = step.field_name,
                });

                const location: UseLocation = .{
                    .variable_name = variable.name,
                    .production_index = production_index,
                    .step_index = step_index,
                };
                if (step_index != 0) {
                    try unsupported.append(.{ .non_leading_external_step = location });
                }
            }

            if (external_steps_in_production > 1) {
                try unsupported.append(.{
                    .multiple_external_steps_in_production = .{
                        .variable_name = variable.name,
                        .production_index = production_index,
                        .count = external_steps_in_production,
                    },
                });
            }
        }
    }

    const unsupported_features = try unsupported.toOwnedSlice();
    return .{
        .tokens = tokens,
        .uses = try uses.toOwnedSlice(),
        .unsupported_features = unsupported_features,
        .blocked = unsupported_features.len != 0,
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

fn hasUnsupportedFeature(
    features: []const UnsupportedExternalScannerFeature,
    comptime tag: std.meta.Tag(UnsupportedExternalScannerFeature),
) bool {
    for (features) |feature| {
        if (feature == tag) return true;
    }
    return false;
}

test "serializeExternalScannerBoundary serializes the hidden external fields ready boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFixture(arena.allocator(), fixtures.hiddenExternalFieldsGrammarJson().contents);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try serializeExternalScannerBoundary(arena.allocator(), extracted.syntax);

    try std.testing.expect(serialized.isReady());
    try std.testing.expectEqual(@as(usize, 1), serialized.tokens.len);
    try std.testing.expectEqualStrings("indent", serialized.tokens[0].name);
    try std.testing.expectEqual(@as(usize, 1), serialized.uses.len);
    try std.testing.expectEqual(@as(u32, 0), serialized.uses[0].external_index);
    try std.testing.expectEqualStrings("_with_indent", serialized.uses[0].variable_name);
    try std.testing.expectEqual(@as(usize, 0), serialized.uses[0].production_index);
    try std.testing.expectEqual(@as(usize, 0), serialized.uses[0].step_index);
    try std.testing.expectEqualStrings("lead", serialized.uses[0].field_name.?);
    try std.testing.expectEqual(@as(usize, 0), serialized.unsupported_features.len);
}

test "serializeExternalScannerBoundary tolerates extras at the first external boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFixture(arena.allocator(), fixtures.mixedSemanticsGrammarJson().contents);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try serializeExternalScannerBoundary(arena.allocator(), extracted.syntax);

    try std.testing.expect(serialized.isReady());
    try std.testing.expectEqual(@as(usize, 1), serialized.tokens.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.uses.len);
    try std.testing.expectEqual(@as(usize, 0), serialized.unsupported_features.len);
}

test "serializeExternalScannerBoundary tolerates aliased external steps at the first boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFixture(arena.allocator(), fixtures.externalCollisionGrammarJson().contents);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try serializeExternalScannerBoundary(arena.allocator(), extracted.syntax);

    try std.testing.expect(serialized.isReady());
    try std.testing.expectEqual(@as(usize, 0), serialized.unsupported_features.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.uses.len);
    try std.testing.expectEqualStrings("statement", serialized.uses[0].variable_name);
}

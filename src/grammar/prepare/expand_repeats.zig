const std = @import("std");
const syntax_ir = @import("../../ir/syntax_grammar.zig");

pub const RepeatExpansion = struct {
    symbol: syntax_ir.SymbolRef,
    variable: syntax_ir.SyntaxVariable,
};

pub fn createRepeatProductions(
    allocator: std.mem.Allocator,
    symbol_index: u32,
    inner_productions: []const syntax_ir.Production,
    at_least_one: bool,
) ![]const syntax_ir.Production {
    var productions = std.array_list.Managed(syntax_ir.Production).init(allocator);
    defer productions.deinit();

    if (!at_least_one) {
        try productions.append(.{ .steps = try allocator.dupe(syntax_ir.ProductionStep, &.{}) });
    }

    try productions.append(.{
        .steps = try allocator.dupe(syntax_ir.ProductionStep, &.{
            .{ .symbol = .{ .non_terminal = symbol_index } },
            .{ .symbol = .{ .non_terminal = symbol_index } },
        }),
    });

    for (inner_productions) |production| {
        const steps = try allocator.dupe(syntax_ir.ProductionStep, production.steps);
        try productions.append(.{
            .steps = steps,
            .dynamic_precedence = production.dynamic_precedence,
        });
    }

    return try productions.toOwnedSlice();
}

fn deinitExpansion(allocator: std.mem.Allocator, expansion: RepeatExpansion) void {
    allocator.free(expansion.variable.name);
    for (expansion.variable.productions) |production| {
        allocator.free(production.steps);
    }
    allocator.free(expansion.variable.productions);
}

pub fn createRepeatAuxiliary(
    allocator: std.mem.Allocator,
    variable_name: []const u8,
    symbol_index: u32,
    inner_productions: []const syntax_ir.Production,
    at_least_one: bool,
) !RepeatExpansion {
    const name = try std.fmt.allocPrint(allocator, "{s}_repeat{d}", .{ variable_name, symbol_index });
    return .{
        .symbol = .{ .non_terminal = symbol_index },
        .variable = .{
            .name = name,
            .kind = .auxiliary,
            .productions = try createRepeatProductions(allocator, symbol_index, inner_productions, at_least_one),
        },
    };
}

test "createRepeatAuxiliary builds zero-or-more auxiliary productions" {
    var inner_steps = [_]syntax_ir.ProductionStep{.{ .symbol = .{ .terminal = 4 } }};
    const inner = [_]syntax_ir.Production{
        .{ .steps = inner_steps[0..] },
    };
    const expansion = try createRepeatAuxiliary(std.testing.allocator, "expr", 7, &inner, false);
    defer deinitExpansion(std.testing.allocator, expansion);

    try std.testing.expectEqual(@as(u32, 7), expansion.symbol.non_terminal);
    try std.testing.expectEqualStrings("expr_repeat7", expansion.variable.name);
    try std.testing.expectEqual(@as(usize, 3), expansion.variable.productions.len);
    try std.testing.expectEqual(@as(usize, 0), expansion.variable.productions[0].steps.len);
}

test "createRepeatAuxiliary builds one-or-more auxiliary productions" {
    var inner_steps = [_]syntax_ir.ProductionStep{.{ .symbol = .{ .terminal = 2 } }};
    const inner = [_]syntax_ir.Production{
        .{ .steps = inner_steps[0..] },
    };
    const expansion = try createRepeatAuxiliary(std.testing.allocator, "expr", 5, &inner, true);
    defer deinitExpansion(std.testing.allocator, expansion);

    try std.testing.expectEqual(@as(usize, 2), expansion.variable.productions.len);
    try std.testing.expectEqual(@as(usize, 2), expansion.variable.productions[0].steps.len);
    try std.testing.expectEqual(@as(u32, 5), expansion.variable.productions[0].steps[0].symbol.non_terminal);
}

test "createRepeatProductions can build in-place repeat expansions" {
    var inner_steps = [_]syntax_ir.ProductionStep{.{ .symbol = .{ .terminal = 9 } }};
    const inner = [_]syntax_ir.Production{
        .{ .steps = inner_steps[0..] },
    };
    const productions = try createRepeatProductions(std.testing.allocator, 3, &inner, false);
    defer {
        for (productions) |production| {
            std.testing.allocator.free(production.steps);
        }
        std.testing.allocator.free(productions);
    }

    try std.testing.expectEqual(@as(usize, 3), productions.len);
    try std.testing.expectEqual(@as(usize, 0), productions[0].steps.len);
    try std.testing.expectEqual(@as(u32, 3), productions[1].steps[0].symbol.non_terminal);
}

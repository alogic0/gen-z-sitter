const std = @import("std");
const rules = @import("rules.zig");
const syntax = @import("syntax_grammar.zig");

pub const AliasTarget = union(enum) {
    symbol: syntax.SymbolRef,
    rule: rules.RuleId,
};

pub const AliasEntry = struct {
    target: AliasTarget,
    alias: rules.Alias,
};

pub const AliasMap = struct {
    entries: []const AliasEntry,

    pub fn findForSymbol(self: AliasMap, symbol: syntax.SymbolRef) ?rules.Alias {
        for (self.entries) |entry| {
            switch (entry.target) {
                .symbol => |candidate| {
                    if (symbolRefEql(candidate, symbol)) {
                        return entry.alias;
                    }
                },
                else => {},
            }
        }
        return null;
    }
};

fn symbolRefEql(a: syntax.SymbolRef, b: syntax.SymbolRef) bool {
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

test "alias map resolves symbol aliases" {
    const map = AliasMap{
        .entries = &.{.{
            .target = .{ .symbol = .{ .non_terminal = 2 } },
            .alias = .{ .value = "expression", .named = true },
        }},
    };

    const alias = map.findForSymbol(.{ .non_terminal = 2 }).?;
    try std.testing.expectEqualStrings("expression", alias.value);
    try std.testing.expect(alias.named);
}

test "alias map returns null for unknown symbol" {
    const map = AliasMap{ .entries = &.{} };
    try std.testing.expect(map.findForSymbol(.{ .non_terminal = 0 }) == null);
}

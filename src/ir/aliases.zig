const std = @import("std");
const symbols = @import("symbols.zig");
const rules = @import("rules.zig");

pub const AliasTarget = union(enum) {
    symbol: symbols.SymbolId,
    rule: rules.RuleId,
};

pub const AliasEntry = struct {
    target: AliasTarget,
    alias: rules.Alias,
};

pub const AliasMap = struct {
    entries: []const AliasEntry,

    pub fn findForSymbol(self: AliasMap, symbol: symbols.SymbolId) ?rules.Alias {
        for (self.entries) |entry| {
            switch (entry.target) {
                .symbol => |candidate| {
                    if (candidate.kind == symbol.kind and candidate.index == symbol.index) {
                        return entry.alias;
                    }
                },
                else => {},
            }
        }
        return null;
    }
};

test "alias map resolves symbol aliases" {
    const map = AliasMap{
        .entries = &.{.{
            .target = .{ .symbol = symbols.SymbolId.nonTerminal(2) },
            .alias = .{ .value = "expression", .named = true },
        }},
    };

    const alias = map.findForSymbol(symbols.SymbolId.nonTerminal(2)).?;
    try std.testing.expectEqualStrings("expression", alias.value);
    try std.testing.expect(alias.named);
}

test "alias map returns null for unknown symbol" {
    const map = AliasMap{ .entries = &.{} };
    try std.testing.expect(map.findForSymbol(symbols.SymbolId.nonTerminal(0)) == null);
}

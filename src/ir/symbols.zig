const std = @import("std");

pub const SymbolKind = enum {
    non_terminal,
    external,
};

pub const SymbolId = struct {
    kind: SymbolKind,
    index: u32,

    pub fn nonTerminal(index: usize) SymbolId {
        return .{ .kind = .non_terminal, .index = @intCast(index) };
    }

    pub fn external(index: usize) SymbolId {
        return .{ .kind = .external, .index = @intCast(index) };
    }
};

pub const SymbolInfo = struct {
    id: SymbolId,
    name: []const u8,
    named: bool,
    visible: bool,
    supertype: bool = false,
};

test "symbol constructors preserve kind and index" {
    const nt = SymbolId.nonTerminal(3);
    const ext = SymbolId.external(5);

    try std.testing.expectEqual(SymbolKind.non_terminal, nt.kind);
    try std.testing.expectEqual(@as(u32, 3), nt.index);
    try std.testing.expectEqual(SymbolKind.external, ext.kind);
    try std.testing.expectEqual(@as(u32, 5), ext.index);
}

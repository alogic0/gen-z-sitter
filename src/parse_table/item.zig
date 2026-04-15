const std = @import("std");
const symbols = @import("../ir/symbols.zig");

pub const ProductionId = u32;

pub const ParseItem = struct {
    production_id: ProductionId,
    step_index: u16,
    lookahead: ?symbols.SymbolId = null,

    pub fn init(production_id: ProductionId, step_index: u16) ParseItem {
        return .{
            .production_id = production_id,
            .step_index = step_index,
            .lookahead = null,
        };
    }

    pub fn withLookahead(production_id: ProductionId, step_index: u16, lookahead: symbols.SymbolId) ParseItem {
        return .{
            .production_id = production_id,
            .step_index = step_index,
            .lookahead = lookahead,
        };
    }

    pub fn eql(a: ParseItem, b: ParseItem) bool {
        return a.production_id == b.production_id and a.step_index == b.step_index and optionalSymbolEql(a.lookahead, b.lookahead);
    }

    pub fn lessThan(_: void, a: ParseItem, b: ParseItem) bool {
        if (a.production_id != b.production_id) return a.production_id < b.production_id;
        if (a.step_index != b.step_index) return a.step_index < b.step_index;
        if (a.lookahead) |left| {
            if (b.lookahead) |right| {
                return symbolLessThan(left, right);
            }
            return false;
        }
        return b.lookahead != null;
    }

    pub fn format(self: ParseItem, writer: anytype) !void {
        try writer.print("#{d}@{d}", .{ self.production_id, self.step_index });
        if (self.lookahead) |lookahead| {
            try writer.print(" ?{s}:{d}", .{ @tagName(lookahead.kind), lookahead.index });
        }
    }
};

fn symbolLessThan(a: symbols.SymbolId, b: symbols.SymbolId) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return a.index < b.index;
}

test "parse items compare deterministically" {
    const a = ParseItem.init(1, 0);
    const b = ParseItem.init(1, 1);
    const c = ParseItem.withLookahead(1, 1, symbols.SymbolId.external(7));

    try std.testing.expect(ParseItem.lessThan({}, a, b));
    try std.testing.expect(ParseItem.lessThan({}, b, c));
    try std.testing.expect(ParseItem.eql(c, ParseItem.withLookahead(1, 1, symbols.SymbolId.external(7))));
}

test "parse item format includes lookahead when present" {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{ParseItem.withLookahead(2, 3, symbols.SymbolId.external(9))});
    try std.testing.expectEqualStrings("#2@3 ?external:9", text);
}

fn optionalSymbolEql(a: ?symbols.SymbolId, b: ?symbols.SymbolId) bool {
    if (a) |left| {
        if (b) |right| {
            return left.kind == right.kind and left.index == right.index;
        }
        return false;
    }
    return b == null;
}

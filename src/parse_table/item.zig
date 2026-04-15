const std = @import("std");
const syntax_ir = @import("../ir/syntax_grammar.zig");

pub const ProductionId = u32;

pub const ParseItem = struct {
    production_id: ProductionId,
    step_index: u16,
    lookahead: ?syntax_ir.SymbolRef = null,

    pub fn init(production_id: ProductionId, step_index: u16) ParseItem {
        return .{
            .production_id = production_id,
            .step_index = step_index,
            .lookahead = null,
        };
    }

    pub fn withLookahead(production_id: ProductionId, step_index: u16, lookahead: syntax_ir.SymbolRef) ParseItem {
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
            switch (lookahead) {
                .non_terminal => |index| try writer.print(" ?non_terminal:{d}", .{index}),
                .terminal => |index| try writer.print(" ?terminal:{d}", .{index}),
                .external => |index| try writer.print(" ?external:{d}", .{index}),
            }
        }
    }
};

fn symbolLessThan(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return symbolSortKey(a) < symbolSortKey(b);
}

test "parse items compare deterministically" {
    const a = ParseItem.init(1, 0);
    const b = ParseItem.init(1, 1);
    const c = ParseItem.withLookahead(1, 1, .{ .external = 7 });

    try std.testing.expect(ParseItem.lessThan({}, a, b));
    try std.testing.expect(ParseItem.lessThan({}, b, c));
    try std.testing.expect(ParseItem.eql(c, ParseItem.withLookahead(1, 1, .{ .external = 7 })));
}

test "parse item format includes lookahead when present" {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{ParseItem.withLookahead(2, 3, .{ .external = 9 })});
    try std.testing.expectEqualStrings("#2@3 ?external:9", text);
}

fn optionalSymbolEql(a: ?syntax_ir.SymbolRef, b: ?syntax_ir.SymbolRef) bool {
    if (a) |left| {
        if (b) |right| {
            return symbolEql(left, right);
        }
        return false;
    }
    return b == null;
}

fn symbolEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
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

fn symbolSortKey(symbol: syntax_ir.SymbolRef) u64 {
    return switch (symbol) {
        .non_terminal => |index| (@as(u64, 0) << 32) | index,
        .terminal => |index| (@as(u64, 1) << 32) | index,
        .external => |index| (@as(u64, 2) << 32) | index,
    };
}

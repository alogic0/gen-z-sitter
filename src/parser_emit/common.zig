const std = @import("std");
const syntax_grammar = @import("../ir/syntax_grammar.zig");
const actions = @import("../parse_table/actions.zig");
const resolution = @import("../parse_table/resolution.zig");

pub fn writeSymbol(writer: anytype, symbol: syntax_grammar.SymbolRef) !void {
    switch (symbol) {
        .non_terminal => |symbol_index| try writer.print("non_terminal:{d}", .{symbol_index}),
        .terminal => |symbol_index| try writer.print("terminal:{d}", .{symbol_index}),
        .external => |symbol_index| try writer.print("external:{d}", .{symbol_index}),
    }
}

pub fn writeQuotedSymbol(writer: anytype, symbol: syntax_grammar.SymbolRef) !void {
    try writer.writeByte('"');
    try writeSymbol(writer, symbol);
    try writer.writeByte('"');
}

pub fn writeActionKind(writer: anytype, action: actions.ParseAction) !void {
    switch (action) {
        .shift => try writer.writeAll("shift"),
        .reduce => try writer.writeAll("reduce"),
        .accept => try writer.writeAll("accept"),
    }
}

pub fn writeActionValue(writer: anytype, action: actions.ParseAction) !void {
    switch (action) {
        .shift => |target| try writer.print("{d}", .{target}),
        .reduce => |production_id| try writer.print("{d}", .{production_id}),
        .accept => try writer.writeByte('0'),
    }
}

pub fn writeActionWithValue(writer: anytype, action: actions.ParseAction) !void {
    try writeActionKind(writer, action);
    switch (action) {
        .accept => {},
        else => {
            try writer.writeByte(' ');
            try writeActionValue(writer, action);
        },
    }
}

pub fn writeUnresolvedReason(writer: anytype, reason: resolution.UnresolvedReason) !void {
    try writer.writeAll(@tagName(reason));
}

test "common emitter helpers format symbols and actions deterministically" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try writeSymbol(buffer.writer(), .{ .external = 2 });
    try buffer.writer().writeByte('\n');
    try writeQuotedSymbol(buffer.writer(), .{ .terminal = 1 });
    try buffer.writer().writeByte('\n');
    try writeActionKind(buffer.writer(), .{ .reduce = 7 });
    try buffer.writer().writeByte('\n');
    try writeActionWithValue(buffer.writer(), .{ .shift = 4 });
    try buffer.writer().writeByte('\n');
    try writeActionWithValue(buffer.writer(), .accept);
    try buffer.writer().writeByte('\n');
    try writeUnresolvedReason(buffer.writer(), .reduce_reduce_deferred);

    try std.testing.expectEqualStrings(
        \\external:2
        \\"terminal:1"
        \\reduce
        \\shift 4
        \\accept
        \\reduce_reduce_deferred
    , buffer.items);
}

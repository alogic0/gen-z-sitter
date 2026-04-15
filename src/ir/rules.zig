const std = @import("std");
const symbols = @import("symbols.zig");

pub const RuleId = u32;

pub const Assoc = enum {
    none,
    left,
    right,
};

pub const PrecedenceValue = union(enum) {
    none,
    integer: i32,
    name: []const u8,
};

pub const Alias = struct {
    value: []const u8,
    named: bool,
};

pub const Pattern = struct {
    value: []const u8,
    flags: ?[]const u8,
};

pub const Metadata = struct {
    field_name: ?[]const u8 = null,
    alias: ?Alias = null,
    precedence: PrecedenceValue = .none,
    associativity: Assoc = .none,
    dynamic_precedence: i32 = 0,
    token: bool = false,
    immediate_token: bool = false,
    reserved_context_name: ?[]const u8 = null,
};

pub const MetadataRule = struct {
    inner: RuleId,
    data: Metadata,
};

pub const Rule = union(enum) {
    blank,
    symbol: symbols.SymbolId,
    string: []const u8,
    pattern: Pattern,
    choice: []const RuleId,
    seq: []const RuleId,
    repeat: RuleId,
    repeat1: RuleId,
    metadata: MetadataRule,
};

test "metadata defaults are inert" {
    const metadata = Metadata{};
    try std.testing.expect(metadata.field_name == null);
    try std.testing.expect(metadata.alias == null);
    try std.testing.expect(metadata.precedence == .none);
    try std.testing.expectEqual(Assoc.none, metadata.associativity);
}

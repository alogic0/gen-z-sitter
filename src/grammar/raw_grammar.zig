const std = @import("std");

pub const RawGrammar = struct {
    name: []const u8,
    version: [3]u8 = .{ 0, 0, 0 },
    rules: []const RawRuleEntry,
    precedences: []const PrecedenceList,
    expected_conflicts: []const ConflictSet,
    externals: []const *const RawRule,
    extras: []const *const RawRule,
    inline_rules: []const []const u8,
    supertypes: []const []const u8,
    word: ?[]const u8,
    reserved: []const RawReservedSet,

    pub fn ruleCount(self: RawGrammar) usize {
        return self.rules.len;
    }
};

pub const RawRuleEntry = struct {
    name: []const u8,
    rule: *const RawRule,
};

pub const PrecedenceList = []const *const RawRule;
pub const ConflictSet = []const []const u8;

pub const RawReservedSet = struct {
    context_name: []const u8,
    members: []const *const RawRule,
};

pub const RawPrecedenceValue = union(enum) {
    integer: i32,
    name: []const u8,
};

pub const RawAlias = struct {
    content: *const RawRule,
    named: bool,
    value: []const u8,
};

pub const RawPattern = struct {
    value: []const u8,
    flags: ?[]const u8,
};

pub const RawField = struct {
    name: []const u8,
    content: *const RawRule,
};

pub const RawPrecDynamic = struct {
    value: i32,
    content: *const RawRule,
};

pub const RawPrec = struct {
    value: RawPrecedenceValue,
    content: *const RawRule,
};

pub const RawReservedRule = struct {
    context_name: []const u8,
    content: *const RawRule,
};

pub const RawRule = union(enum) {
    alias: RawAlias,
    blank,
    string: []const u8,
    pattern: RawPattern,
    symbol: []const u8,
    choice: []const *const RawRule,
    field: RawField,
    seq: []const *const RawRule,
    repeat: *const RawRule,
    repeat1: *const RawRule,
    prec_dynamic: RawPrecDynamic,
    prec_left: RawPrec,
    prec_right: RawPrec,
    prec: RawPrec,
    token: *const RawRule,
    immediate_token: *const RawRule,
    reserved: RawReservedRule,

    pub fn tagName(self: RawRule) []const u8 {
        return switch (self) {
            .alias => "ALIAS",
            .blank => "BLANK",
            .string => "STRING",
            .pattern => "PATTERN",
            .symbol => "SYMBOL",
            .choice => "CHOICE",
            .field => "FIELD",
            .seq => "SEQ",
            .repeat => "REPEAT",
            .repeat1 => "REPEAT1",
            .prec_dynamic => "PREC_DYNAMIC",
            .prec_left => "PREC_LEFT",
            .prec_right => "PREC_RIGHT",
            .prec => "PREC",
            .token => "TOKEN",
            .immediate_token => "IMMEDIATE_TOKEN",
            .reserved => "RESERVED",
        };
    }
};

test "raw grammar holds top-level counts" {
    const blank_rule = RawRule{ .blank = {} };
    const entry = RawRuleEntry{
        .name = "source_file",
        .rule = &blank_rule,
    };
    const grammar = RawGrammar{
        .name = "basic",
        .version = .{ 1, 2, 3 },
        .rules = &.{entry},
        .precedences = &.{},
        .expected_conflicts = &.{},
        .externals = &.{},
        .extras = &.{},
        .inline_rules = &.{},
        .supertypes = &.{},
        .word = null,
        .reserved = &.{},
    };

    try std.testing.expectEqual(@as(usize, 1), grammar.ruleCount());
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, grammar.version);
}

const std = @import("std");
const raw = @import("raw_grammar.zig");

pub const ParseGrammarError = error{
    Deferred,
};

pub fn parseRawGrammar(allocator: std.mem.Allocator, grammar: *const raw.RawGrammar) ParseGrammarError!void {
    _ = allocator;
    _ = grammar;
    return error.Deferred;
}

test "parseRawGrammar is explicitly deferred in Milestone 1" {
    const blank_rule = raw.RawRule{ .blank = {} };
    const grammar = raw.RawGrammar{
        .name = "basic",
        .rules = &.{.{
            .name = "source_file",
            .rule = &blank_rule,
        }},
        .precedences = &.{},
        .conflicts = &.{},
        .externals = &.{},
        .extras = &.{},
        .inline_rules = &.{},
        .supertypes = &.{},
        .word = null,
        .reserved = &.{},
    };

    try std.testing.expectError(error.Deferred, parseRawGrammar(std.testing.allocator, &grammar));
}

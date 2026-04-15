const std = @import("std");
const raw = @import("raw_grammar.zig");

pub const ValidationError = error{
    EmptyName,
    EmptyRules,
    InvalidExtra,
    UnexpectedPrecedenceEntry,
    InvalidReservedWordSet,
};

pub fn validateRawGrammar(grammar: *const raw.RawGrammar) ValidationError!void {
    if (grammar.name.len == 0) {
        return error.EmptyName;
    }
    if (grammar.rules.len == 0) {
        return error.EmptyRules;
    }

    for (grammar.extras) |extra| {
        switch (extra.*) {
            .string => |value| {
                if (value.len == 0) {
                    return error.InvalidExtra;
                }
            },
            else => {},
        }
    }

    for (grammar.precedences) |precedence_list| {
        for (precedence_list) |entry| {
            switch (entry.*) {
                .string, .symbol => {},
                else => return error.UnexpectedPrecedenceEntry,
            }
        }
    }

    _ = grammar.reserved;
}

test "validateRawGrammar rejects empty grammar name" {
    const blank_rule = raw.RawRule{ .blank = {} };
    const grammar = raw.RawGrammar{
        .name = "",
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

    try std.testing.expectError(error.EmptyName, validateRawGrammar(&grammar));
}

test "validateRawGrammar rejects empty string in extras" {
    const blank_rule = raw.RawRule{ .blank = {} };
    const extra_rule = raw.RawRule{ .string = "" };
    const grammar = raw.RawGrammar{
        .name = "basic",
        .rules = &.{.{
            .name = "source_file",
            .rule = &blank_rule,
        }},
        .precedences = &.{},
        .conflicts = &.{},
        .externals = &.{},
        .extras = &.{&extra_rule},
        .inline_rules = &.{},
        .supertypes = &.{},
        .word = null,
        .reserved = &.{},
    };

    try std.testing.expectError(error.InvalidExtra, validateRawGrammar(&grammar));
}

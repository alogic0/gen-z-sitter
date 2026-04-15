const std = @import("std");

pub const Fixture = struct {
    name: []const u8,
    contents: []const u8,
};

pub fn basicGrammarJson() Fixture {
    return .{
        .name = "basic",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {}
            \\}
        ,
    };
}

pub fn validBlankGrammarJson() Fixture {
    return .{
        .name = "valid_blank",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": { "type": "BLANK" }
            \\  }
            \\}
        ,
    };
}

pub fn invalidExtraGrammarJson() Fixture {
    return .{
        .name = "invalid_extra",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": { "type": "BLANK" }
            \\  },
            \\  "extras": [
            \\    { "type": "STRING", "value": "" }
            \\  ]
            \\}
        ,
    };
}

pub fn invalidPrecedenceGrammarJson() Fixture {
    return .{
        .name = "invalid_precedence",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": { "type": "BLANK" }
            \\  },
            \\  "precedences": [
            \\    [
            \\      { "type": "BLANK" }
            \\    ]
            \\  ]
            \\}
        ,
    };
}

pub fn malformedGrammarJson() Fixture {
    return .{
        .name = "malformed",
        .contents = "{",
    };
}

pub fn missingNameGrammarJson() Fixture {
    return .{
        .name = "missing_name",
        .contents =
            \\{
            \\  "rules": {
            \\    "source_file": { "type": "BLANK" }
            \\  }
            \\}
        ,
    };
}

pub fn missingRulesGrammarJson() Fixture {
    return .{
        .name = "missing_rules",
        .contents =
            \\{
            \\  "name": "basic"
            \\}
        ,
    };
}

pub fn emptyNameGrammarJson() Fixture {
    return .{
        .name = "empty_name",
        .contents =
            \\{
            \\  "name": "",
            \\  "rules": {
            \\    "source_file": { "type": "BLANK" }
            \\  }
            \\}
        ,
    };
}

pub fn emptyRulesGrammarJson() Fixture {
    return .{
        .name = "empty_rules",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {}
            \\}
        ,
    };
}

pub fn invalidReservedGrammarJson() Fixture {
    return .{
        .name = "invalid_reserved",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": { "type": "BLANK" }
            \\  },
            \\  "reserved": {
            \\    "global": { "type": "BLANK" }
            \\  }
            \\}
        ,
    };
}

pub fn validResolvedGrammarJson() Fixture {
    return .{
        .name = "valid_resolved",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "expr" }
            \\      ]
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        { "type": "STRING", "value": "x" },
            \\        {
            \\          "type": "FIELD",
            \\          "name": "rhs",
            \\          "content": { "type": "SYMBOL", "name": "term" }
            \\        }
            \\      ]
            \\    },
            \\    "term": {
            \\      "type": "TOKEN",
            \\      "content": { "type": "PATTERN", "value": "[a-z]+" }
            \\    }
            \\  },
            \\  "externals": [
            \\    { "type": "SYMBOL", "name": "indent" }
            \\  ],
            \\  "extras": [
            \\    { "type": "STRING", "value": " " }
            \\  ],
            \\  "inline": ["term", "missing_inline"],
            \\  "supertypes": ["expr"],
            \\  "conflicts": [["expr", "term"]],
            \\  "word": "term",
            \\  "reserved": {
            \\    "global": [
            \\      { "type": "STRING", "value": "for" }
            \\    ]
            \\  }
            \\}
        ,
    };
}

pub fn undefinedSymbolGrammarJson() Fixture {
    return .{
        .name = "undefined_symbol",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "missing"
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn hiddenStartGrammarJson() Fixture {
    return .{
        .name = "hidden_start",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "_source_file": { "type": "BLANK" },
            \\    "expr": { "type": "STRING", "value": "x" }
            \\  }
            \\}
        ,
    };
}

test "basic fixture is non-empty" {
    const fixture = basicGrammarJson();
    try std.testing.expect(fixture.contents.len > 0);
}

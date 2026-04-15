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

pub fn validBlankGrammarJs() Fixture {
    return .{
        .name = "valid_blank_js",
        .contents =
            \\module.exports = {
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": { "type": "BLANK" }
            \\  }
            \\};
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

pub fn validResolvedGrammarJs() Fixture {
    return .{
        .name = "valid_resolved_js",
        .contents =
            \\module.exports = {
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
            \\};
        ,
    };
}

pub fn validResolvedNodeTypesJson() Fixture {
    return .{
        .name = "valid_resolved_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "expr",
            \\    "named": true,
            \\    "subtypes": [
            \\      {
            \\        "type": "expr",
            \\        "named": true
            \\      },
            \\      {
            \\        "type": "term",
            \\        "named": true
            \\      }
            \\    ]
            \\  },
            \\  {
            \\    "type": "term",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "term",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "indent",
            \\    "named": true
            \\  },
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true
            \\  }
            \\]
            \\
        ,
    };
}

pub fn parseTableTinyGrammarJson() Fixture {
    return .{
        .name = "parse_table_tiny",
        .contents =
            \\{
            \\  "name": "parse_table_tiny",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "STRING",
            \\      "value": "x"
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableTinyDump() Fixture {
    return .{
        .name = "parse_table_tiny_dump",
        .contents =
            \\state 0
            \\  items:
            \\    #0@0
            \\    #1@0
            \\    #2@0
            \\  transitions:
            \\    non_terminal:0 -> 1
            \\    non_terminal:1 -> 2
            \\    terminal:0 -> 3
            \\
            \\state 1
            \\  items:
            \\    #0@1
            \\  transitions:
            \\
            \\state 2
            \\  items:
            \\    #1@1
            \\  transitions:
            \\
            \\state 3
            \\  items:
            \\    #2@1
            \\  transitions:
            \\
        ,
    };
}

pub fn parseTableConflictGrammarJson() Fixture {
    return .{
        .name = "parse_table_conflict",
        .contents =
            \\{
            \\  "name": "parse_table_conflict",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "SYMBOL", "name": "expr" },
            \\            { "type": "STRING", "value": "+" },
            \\            { "type": "SYMBOL", "name": "expr" }
            \\          ]
            \\        },
            \\        {
            \\          "type": "STRING",
            \\          "value": "x"
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableConflictDump() Fixture {
    return .{
        .name = "parse_table_conflict_dump",
        .contents =
            \\state 0
            \\  items:
            \\    #0@0
            \\    #1@0
            \\    #2@0
            \\    #2@0 ?terminal:0
            \\    #3@0
            \\    #3@0 ?terminal:0
            \\  transitions:
            \\    non_terminal:0 -> 1
            \\    non_terminal:1 -> 2
            \\    terminal:1 -> 3
            \\
            \\state 1
            \\  items:
            \\    #0@1
            \\  transitions:
            \\
            \\state 2
            \\  items:
            \\    #1@1
            \\    #2@1
            \\    #2@1 ?terminal:0
            \\  transitions:
            \\    terminal:0 -> 4
            \\
            \\state 3
            \\  items:
            \\    #3@1
            \\    #3@1 ?terminal:0
            \\  transitions:
            \\
            \\state 4
            \\  items:
            \\    #2@0
            \\    #2@0 ?terminal:0
            \\    #2@2
            \\    #2@2 ?terminal:0
            \\    #3@0
            \\    #3@0 ?terminal:0
            \\  transitions:
            \\    non_terminal:1 -> 5
            \\    terminal:1 -> 3
            \\
            \\state 5
            \\  items:
            \\    #2@1
            \\    #2@1 ?terminal:0
            \\    #2@3
            \\    #2@3 ?terminal:0
            \\  transitions:
            \\    terminal:0 -> 4
            \\  conflicts:
            \\    shift_reduce on terminal:0
            \\      #2@1
            \\      #2@3
            \\
        ,
    };
}

pub fn parseTableConflictActionDump() Fixture {
    return .{
        .name = "parse_table_conflict_action_dump",
        .contents =
            \\state 0
            \\  items:
            \\    #0@0
            \\    #1@0
            \\    #2@0
            \\    #2@0 ?terminal:0
            \\    #3@0
            \\    #3@0 ?terminal:0
            \\  transitions:
            \\    non_terminal:0 -> 1
            \\    non_terminal:1 -> 2
            \\    terminal:1 -> 3
            \\  actions:
            \\    terminal:1 => shift 3
            \\
            \\state 1
            \\  items:
            \\    #0@1
            \\  transitions:
            \\  actions:
            \\
            \\state 2
            \\  items:
            \\    #1@1
            \\    #2@1
            \\    #2@1 ?terminal:0
            \\  transitions:
            \\    terminal:0 -> 4
            \\  actions:
            \\    terminal:0 => shift 4
            \\
            \\state 3
            \\  items:
            \\    #3@1
            \\    #3@1 ?terminal:0
            \\  transitions:
            \\  actions:
            \\    terminal:0 => reduce 3
            \\
            \\state 4
            \\  items:
            \\    #2@0
            \\    #2@0 ?terminal:0
            \\    #2@2
            \\    #2@2 ?terminal:0
            \\    #3@0
            \\    #3@0 ?terminal:0
            \\  transitions:
            \\    non_terminal:1 -> 5
            \\    terminal:1 -> 3
            \\  actions:
            \\    terminal:1 => shift 3
            \\
            \\state 5
            \\  items:
            \\    #2@1
            \\    #2@1 ?terminal:0
            \\    #2@3
            \\    #2@3 ?terminal:0
            \\  transitions:
            \\    terminal:0 -> 4
            \\  actions:
            \\    terminal:0 => shift 4
            \\    terminal:0 => reduce 2
            \\  conflicts:
            \\    shift_reduce on terminal:0
            \\      #2@1
            \\      #2@3
            \\
        ,
    };
}

pub fn parseTableReduceReduceActionDump() Fixture {
    return .{
        .name = "parse_table_reduce_reduce_action_dump",
        .contents =
            \\state 0
            \\  items:
            \\    #0@0
            \\    #1@0
            \\    #2@0 ?terminal:0
            \\    #3@0 ?terminal:0
            \\    #4@0 ?terminal:0
            \\    #5@0 ?terminal:0
            \\    #6@0 ?terminal:0
            \\  transitions:
            \\    non_terminal:0 -> 1
            \\    non_terminal:1 -> 2
            \\    non_terminal:2 -> 3
            \\    non_terminal:3 -> 4
            \\    non_terminal:4 -> 5
            \\    terminal:1 -> 6
            \\  actions:
            \\    terminal:1 => shift 6
            \\
            \\state 1
            \\  items:
            \\    #0@1
            \\  transitions:
            \\  actions:
            \\
            \\state 2
            \\  items:
            \\    #1@1
            \\  transitions:
            \\    terminal:0 -> 7
            \\  actions:
            \\    terminal:0 => shift 7
            \\
            \\state 3
            \\  items:
            \\    #2@1 ?terminal:0
            \\  transitions:
            \\  actions:
            \\    terminal:0 => reduce 2
            \\
            \\state 4
            \\  items:
            \\    #3@1 ?terminal:0
            \\  transitions:
            \\  actions:
            \\    terminal:0 => reduce 3
            \\
            \\state 5
            \\  items:
            \\    #4@1 ?terminal:0
            \\    #5@1 ?terminal:0
            \\  transitions:
            \\  actions:
            \\    terminal:0 => reduce 4
            \\    terminal:0 => reduce 5
            \\  conflicts:
            \\    reduce_reduce on terminal:0
            \\      #4@1 ?terminal:0
            \\      #5@1 ?terminal:0
            \\
            \\state 6
            \\  items:
            \\    #6@1 ?terminal:0
            \\  transitions:
            \\  actions:
            \\    terminal:0 => reduce 6
            \\
            \\state 7
            \\  items:
            \\    #1@2
            \\  transitions:
            \\  actions:
            \\
        ,
    };
}

pub fn parseTableMetadataActionDump() Fixture {
    return .{
        .name = "parse_table_metadata_action_dump",
        .contents =
            \\state 0
            \\  items:
            \\    #0@0
            \\    #1@0
            \\    #2@0 ?terminal:0
            \\  transitions:
            \\    non_terminal:0 -> 1
            \\    non_terminal:1 -> 2
            \\    terminal:1 -> 3
            \\  actions:
            \\    terminal:1 => shift 3
            \\
            \\state 1
            \\  items:
            \\    #0@1
            \\  transitions:
            \\  actions:
            \\
            \\state 2
            \\  items:
            \\    #1@1
            \\  transitions:
            \\    terminal:0 -> 4
            \\  actions:
            \\    terminal:0 => shift 4
            \\
            \\state 3
            \\  items:
            \\    #2@1 ?terminal:0
            \\  transitions:
            \\  actions:
            \\    terminal:0 => reduce 2
            \\
            \\state 4
            \\  items:
            \\    #1@2
            \\    #2@0
            \\  transitions:
            \\    non_terminal:1 -> 5
            \\    terminal:1 -> 6
            \\  actions:
            \\    terminal:1 => shift 6
            \\
            \\state 5
            \\  items:
            \\    #1@3
            \\  transitions:
            \\  actions:
            \\
            \\state 6
            \\  items:
            \\    #2@1
            \\  transitions:
            \\  actions:
            \\
        ,
    };
}

pub fn parseTableMetadataSerializedDump() Fixture {
    return .{
        .name = "parse_table_metadata_serialized_dump",
        .contents =
            \\serialized_table blocked=false
            \\state 0
            \\  actions:
            \\    terminal:1 => shift 3
            \\  gotos:
            \\    non_terminal:0 -> 1
            \\    non_terminal:1 -> 2
            \\
            \\state 1
            \\  actions:
            \\  gotos:
            \\
            \\state 2
            \\  actions:
            \\    terminal:0 => shift 4
            \\  gotos:
            \\
            \\state 3
            \\  actions:
            \\    terminal:0 => reduce 2
            \\  gotos:
            \\
            \\state 4
            \\  actions:
            \\    terminal:1 => shift 6
            \\  gotos:
            \\    non_terminal:1 -> 5
            \\
            \\state 5
            \\  actions:
            \\  gotos:
            \\
            \\state 6
            \\  actions:
            \\  gotos:
            \\
        ,
    };
}

pub fn parseTableConflictSerializedDump() Fixture {
    return .{
        .name = "parse_table_conflict_serialized_dump",
        .contents =
            \\serialized_table blocked=true
            \\state 0
            \\  actions:
            \\    terminal:1 => shift 3
            \\  gotos:
            \\    non_terminal:0 -> 1
            \\    non_terminal:1 -> 2
            \\
            \\state 1
            \\  actions:
            \\  gotos:
            \\
            \\state 2
            \\  actions:
            \\    terminal:0 => shift 4
            \\  gotos:
            \\
            \\state 3
            \\  actions:
            \\    terminal:0 => reduce 3
            \\  gotos:
            \\
            \\state 4
            \\  actions:
            \\    terminal:1 => shift 3
            \\  gotos:
            \\    non_terminal:1 -> 5
            \\
            \\state 5
            \\  actions:
            \\  gotos:
            \\  unresolved:
            \\    terminal:0 (shift_reduce)
            \\      candidate shift 4
            \\      candidate reduce 2
            \\
        ,
    };
}

pub fn parseTableMetadataEmitterDump() Fixture {
    return .{
        .name = "parse_table_metadata_emitter_dump",
        .contents =
            \\parser_tables blocked=false
            \\state_count=7
            \\state 0 {
            \\  action terminal:1 shift 3
            \\  goto non_terminal:0 1
            \\  goto non_terminal:1 2
            \\}
            \\
            \\state 1 {
            \\}
            \\
            \\state 2 {
            \\  action terminal:0 shift 4
            \\}
            \\
            \\state 3 {
            \\  action terminal:0 reduce 2
            \\}
            \\
            \\state 4 {
            \\  action terminal:1 shift 6
            \\  goto non_terminal:1 5
            \\}
            \\
            \\state 5 {
            \\}
            \\
            \\state 6 {
            \\}
        ,
    };
}

pub fn parseTableConflictEmitterDump() Fixture {
    return .{
        .name = "parse_table_conflict_emitter_dump",
        .contents =
            \\parser_tables blocked=true
            \\state_count=6
            \\state 0 {
            \\  action terminal:1 shift 3
            \\  goto non_terminal:0 1
            \\  goto non_terminal:1 2
            \\}
            \\
            \\state 1 {
            \\}
            \\
            \\state 2 {
            \\  action terminal:0 shift 4
            \\}
            \\
            \\state 3 {
            \\  action terminal:0 reduce 3
            \\}
            \\
            \\state 4 {
            \\  action terminal:1 shift 3
            \\  goto non_terminal:1 5
            \\}
            \\
            \\state 5 {
            \\  unresolved terminal:0 shift_reduce candidates=2
            \\}
        ,
    };
}

pub fn parseTableMetadataCTablesDump() Fixture {
    return .{
        .name = "parse_table_metadata_c_tables_dump",
        .contents =
            \\/* generated parser table skeleton */
            \\#define TS_SERIALIZED_TABLE_BLOCKED false
            \\#define TS_STATE_COUNT 7
            \\
            \\/* state 0 */
            \\static const unsigned TS_STATE_0_ACTION_COUNT = 1;
            \\/* action[0] terminal:1 shift 3 */
            \\static const unsigned TS_STATE_0_GOTO_COUNT = 2;
            \\/* goto[0] non_terminal:0 -> 1 */
            \\/* goto[1] non_terminal:1 -> 2 */
            \\
            \\/* state 1 */
            \\static const unsigned TS_STATE_1_ACTION_COUNT = 0;
            \\static const unsigned TS_STATE_1_GOTO_COUNT = 0;
            \\
            \\/* state 2 */
            \\static const unsigned TS_STATE_2_ACTION_COUNT = 1;
            \\/* action[0] terminal:0 shift 4 */
            \\static const unsigned TS_STATE_2_GOTO_COUNT = 0;
            \\
            \\/* state 3 */
            \\static const unsigned TS_STATE_3_ACTION_COUNT = 1;
            \\/* action[0] terminal:0 reduce 2 */
            \\static const unsigned TS_STATE_3_GOTO_COUNT = 0;
            \\
            \\/* state 4 */
            \\static const unsigned TS_STATE_4_ACTION_COUNT = 1;
            \\/* action[0] terminal:1 shift 6 */
            \\static const unsigned TS_STATE_4_GOTO_COUNT = 1;
            \\/* goto[0] non_terminal:1 -> 5 */
            \\
            \\/* state 5 */
            \\static const unsigned TS_STATE_5_ACTION_COUNT = 0;
            \\static const unsigned TS_STATE_5_GOTO_COUNT = 0;
            \\
            \\/* state 6 */
            \\static const unsigned TS_STATE_6_ACTION_COUNT = 0;
            \\static const unsigned TS_STATE_6_GOTO_COUNT = 0;
            \\
        ,
    };
}

pub fn parseTableConflictCTablesDump() Fixture {
    return .{
        .name = "parse_table_conflict_c_tables_dump",
        .contents =
            \\/* generated parser table skeleton */
            \\#define TS_SERIALIZED_TABLE_BLOCKED true
            \\#define TS_STATE_COUNT 6
            \\
            \\/* state 0 */
            \\static const unsigned TS_STATE_0_ACTION_COUNT = 1;
            \\/* action[0] terminal:1 shift 3 */
            \\static const unsigned TS_STATE_0_GOTO_COUNT = 2;
            \\/* goto[0] non_terminal:0 -> 1 */
            \\/* goto[1] non_terminal:1 -> 2 */
            \\
            \\/* state 1 */
            \\static const unsigned TS_STATE_1_ACTION_COUNT = 0;
            \\static const unsigned TS_STATE_1_GOTO_COUNT = 0;
            \\
            \\/* state 2 */
            \\static const unsigned TS_STATE_2_ACTION_COUNT = 1;
            \\/* action[0] terminal:0 shift 4 */
            \\static const unsigned TS_STATE_2_GOTO_COUNT = 0;
            \\
            \\/* state 3 */
            \\static const unsigned TS_STATE_3_ACTION_COUNT = 1;
            \\/* action[0] terminal:0 reduce 3 */
            \\static const unsigned TS_STATE_3_GOTO_COUNT = 0;
            \\
            \\/* state 4 */
            \\static const unsigned TS_STATE_4_ACTION_COUNT = 1;
            \\/* action[0] terminal:1 shift 3 */
            \\static const unsigned TS_STATE_4_GOTO_COUNT = 1;
            \\/* goto[0] non_terminal:1 -> 5 */
            \\
            \\/* state 5 */
            \\static const unsigned TS_STATE_5_ACTION_COUNT = 0;
            \\static const unsigned TS_STATE_5_GOTO_COUNT = 0;
            \\static const unsigned TS_STATE_5_UNRESOLVED_COUNT = 1;
            \\/* unresolved[0] terminal:0 shift_reduce candidates=2 */
            \\
        ,
    };
}

pub fn parseTableMetadataParserCDump() Fixture {
    return .{
        .name = "parse_table_metadata_parser_c_dump",
        .contents =
            \\/* generated parser.c skeleton */
            \\/* top-level layout: ts_language -> parser/runtime/compatibility */
            \\#include <stdbool.h>
            \\#include <stdint.h>
            \\
            \\#define TS_PARSER_BLOCKED false
            \\#define TS_STATE_COUNT 7
            \\#define TS_SYMBOL_COUNT 4
            \\
            \\#define TS_LANGUAGE_VERSION 15
            \\#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION 13
            \\#define TS_SYMBOL_KIND_NON_TERMINAL 1
            \\#define TS_SYMBOL_KIND_TERMINAL 2
            \\#define TS_SYMBOL_KIND_EXTERNAL 3
            \\#define TS_ACTION_SHIFT 1
            \\#define TS_ACTION_REDUCE 2
            \\#define TS_ACTION_ACCEPT 3
            \\#define TS_UNRESOLVED_SHIFT_REDUCE 1
            \\#define TS_UNRESOLVED_REDUCE_REDUCE_DEFERRED 2
            \\
            \\typedef struct { uint16_t symbol_id; uint16_t kind; uint16_t value; } TSActionEntry;
            \\typedef struct { uint16_t symbol_id; uint16_t state; } TSGotoEntry;
            \\typedef struct { uint16_t symbol_id; uint16_t reason; uint16_t candidates; } TSUnresolvedEntry;
            \\
            \\typedef struct {
            \\  uint16_t id;
            \\  const char *name;
            \\  uint16_t kind;
            \\  bool terminal;
            \\  bool external;
            \\} TSSymbolInfo;
            \\
            \\typedef struct {
            \\  uint16_t language_version;
            \\  uint16_t min_compatible_language_version;
            \\  const char *target;
            \\  const char *layer;
            \\} TSCompatibilityInfo;
            \\
            \\typedef struct {
            \\  const TSActionEntry *actions;
            \\  uint16_t action_count;
            \\  const TSGotoEntry *gotos;
            \\  uint16_t goto_count;
            \\  const TSUnresolvedEntry *unresolved;
            \\  uint16_t unresolved_count;
            \\} TSStateTable;
            \\
            \\typedef struct {
            \\  bool blocked;
            \\  uint16_t symbol_count;
            \\  uint16_t state_count;
            \\  const TSSymbolInfo *symbols;
            \\  const TSStateTable *states;
            \\  const TSCompatibilityInfo *compatibility;
            \\} TSParser;
            \\
            \\typedef struct {
            \\  uint16_t action_count;
            \\  uint16_t goto_count;
            \\  uint16_t unresolved_count;
            \\  bool has_unresolved;
            \\} TSRuntimeStateInfo;
            \\
            \\typedef struct {
            \\  bool blocked;
            \\  bool has_unresolved_states;
            \\  uint16_t state_count;
            \\  const TSParser *parser;
            \\  const TSRuntimeStateInfo *states;
            \\} TSParserRuntime;
            \\
            \\typedef struct {
            \\  const TSParser *parser;
            \\  const TSParserRuntime *runtime;
            \\  const TSCompatibilityInfo *compatibility;
            \\} TSLanguage;
            \\
            \\static bool ts_string_eq(const char *a, const char *b) {
            \\  if (!a || !b) return false;
            \\  while (a[0] != 0 && b[0] != 0) {
            \\    if (a[0] != b[0]) return false;
            \\    a += 1;
            \\    b += 1;
            \\  }
            \\  return a[0] == b[0];
            \\}
            \\
            \\static const TSCompatibilityInfo ts_compatibility = {
            \\  .language_version = 15,
            \\  .min_compatible_language_version = 13,
            \\  .target = "tree-sitter-runtime-surface",
            \\  .layer = "intermediate",
            \\};
            \\
            \\static const TSSymbolInfo ts_symbols[TS_SYMBOL_COUNT] = {
            \\  {
            \\    .id = 0,
            \\    .name = "non_terminal:0",
            \\    .kind = 1,
            \\    .terminal = false,
            \\    .external = false,
            \\  },
            \\  {
            \\    .id = 1,
            \\    .name = "non_terminal:1",
            \\    .kind = 1,
            \\    .terminal = false,
            \\    .external = false,
            \\  },
            \\  {
            \\    .id = 2,
            \\    .name = "terminal:0",
            \\    .kind = 2,
            \\    .terminal = true,
            \\    .external = false,
            \\  },
            \\  {
            \\    .id = 3,
            \\    .name = "terminal:1",
            \\    .kind = 2,
            \\    .terminal = true,
            \\    .external = false,
            \\  },
            \\};
            \\
            \\/* state 0 */
            \\static const TSActionEntry ts_state_0_actions[] = {
            \\  { 3, 1, 3 },
            \\};
            \\static const TSGotoEntry ts_state_0_gotos[] = {
            \\  { 0, 1 },
            \\  { 1, 2 },
            \\};
            \\
            \\/* state 1 */
            \\static const TSActionEntry ts_state_1_actions[] = {
            \\};
            \\static const TSGotoEntry ts_state_1_gotos[] = {
            \\};
            \\
            \\/* state 2 */
            \\static const TSActionEntry ts_state_2_actions[] = {
            \\  { 2, 1, 4 },
            \\};
            \\static const TSGotoEntry ts_state_2_gotos[] = {
            \\};
            \\
            \\/* state 3 */
            \\static const TSActionEntry ts_state_3_actions[] = {
            \\  { 2, 2, 2 },
            \\};
            \\static const TSGotoEntry ts_state_3_gotos[] = {
            \\};
            \\
            \\/* state 4 */
            \\static const TSActionEntry ts_state_4_actions[] = {
            \\  { 3, 1, 6 },
            \\};
            \\static const TSGotoEntry ts_state_4_gotos[] = {
            \\  { 1, 5 },
            \\};
            \\
            \\/* state 5 */
            \\static const TSActionEntry ts_state_5_actions[] = {
            \\};
            \\static const TSGotoEntry ts_state_5_gotos[] = {
            \\};
            \\
            \\/* state 6 */
            \\static const TSActionEntry ts_state_6_actions[] = {
            \\};
            \\static const TSGotoEntry ts_state_6_gotos[] = {
            \\};
            \\static const TSStateTable ts_states[TS_STATE_COUNT] = {
            \\  {
            \\    .actions = ts_state_0_actions,
            \\    .action_count = 1,
            \\    .gotos = ts_state_0_gotos,
            \\    .goto_count = 2,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_1_actions,
            \\    .action_count = 0,
            \\    .gotos = ts_state_1_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_2_actions,
            \\    .action_count = 1,
            \\    .gotos = ts_state_2_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_3_actions,
            \\    .action_count = 1,
            \\    .gotos = ts_state_3_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_4_actions,
            \\    .action_count = 1,
            \\    .gotos = ts_state_4_gotos,
            \\    .goto_count = 1,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_5_actions,
            \\    .action_count = 0,
            \\    .gotos = ts_state_5_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_6_actions,
            \\    .action_count = 0,
            \\    .gotos = ts_state_6_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\};
            \\
            \\static const TSParser ts_parser = {
            \\  .blocked = false,
            \\  .symbol_count = TS_SYMBOL_COUNT,
            \\  .state_count = TS_STATE_COUNT,
            \\  .symbols = ts_symbols,
            \\  .states = ts_states,
            \\  .compatibility = &ts_compatibility,
            \\};
            \\
            \\static const TSRuntimeStateInfo ts_runtime_states[TS_STATE_COUNT] = {
            \\  {
            \\    .action_count = 1,
            \\    .goto_count = 2,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 0,
            \\    .goto_count = 0,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 1,
            \\    .goto_count = 0,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 1,
            \\    .goto_count = 0,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 1,
            \\    .goto_count = 1,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 0,
            \\    .goto_count = 0,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 0,
            \\    .goto_count = 0,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\};
            \\
            \\static const TSParserRuntime ts_runtime = {
            \\  .blocked = false,
            \\  .has_unresolved_states = false,
            \\  .state_count = TS_STATE_COUNT,
            \\  .parser = &ts_parser,
            \\  .states = ts_runtime_states,
            \\};
            \\
            \\static const TSLanguage ts_language = {
            \\  .parser = &ts_parser,
            \\  .runtime = &ts_runtime,
            \\  .compatibility = &ts_compatibility,
            \\};
            \\
            \\const TSLanguage *ts_language_instance(void) {
            \\  return &ts_language;
            \\}
            \\
            \\const TSParser *ts_language_parser(const TSLanguage *language) {
            \\  return language ? language->parser : 0;
            \\}
            \\
            \\const TSParserRuntime *ts_language_runtime(const TSLanguage *language) {
            \\  return language ? language->runtime : 0;
            \\}
            \\
            \\const TSCompatibilityInfo *ts_language_compatibility(const TSLanguage *language) {
            \\  return language ? language->compatibility : 0;
            \\}
            \\
            \\const TSParser *ts_parser_instance(void) {
            \\  return ts_language_parser(ts_language_instance());
            \\}
            \\
            \\const TSCompatibilityInfo *ts_parser_compatibility(void) {
            \\  return ts_language_compatibility(ts_language_instance());
            \\}
            \\
            \\uint16_t ts_parser_language_version(void) {
            \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
            \\  return compatibility ? compatibility->language_version : 0;
            \\}
            \\
            \\uint16_t ts_parser_min_compatible_language_version(void) {
            \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
            \\  return compatibility ? compatibility->min_compatible_language_version : 0;
            \\}
            \\
            \\const char *ts_parser_compatibility_target(void) {
            \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
            \\  return compatibility ? compatibility->target : 0;
            \\}
            \\
            \\const char *ts_parser_compatibility_layer(void) {
            \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
            \\  return compatibility ? compatibility->layer : 0;
            \\}
            \\
            \\const TSParserRuntime *ts_parser_runtime(void) {
            \\  return ts_language_runtime(ts_language_instance());
            \\}
            \\
            \\bool ts_parser_runtime_is_blocked(void) {
            \\  const TSParserRuntime *runtime = ts_parser_runtime();
            \\  return runtime ? runtime->blocked : false;
            \\}
            \\
            \\bool ts_parser_runtime_has_unresolved_states(void) {
            \\  const TSParserRuntime *runtime = ts_parser_runtime();
            \\  return runtime ? runtime->has_unresolved_states : false;
            \\}
            \\
            \\const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id) {
            \\  const TSParserRuntime *runtime = ts_parser_runtime();
            \\  return runtime && state_id < runtime->state_count ? &runtime->states[state_id] : 0;
            \\}
            \\
            \\bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) {
            \\  const TSRuntimeStateInfo *state = ts_parser_runtime_state(state_id);
            \\  return state ? state->has_unresolved : false;
            \\}
            \\
            \\const TSStateTable *ts_parser_state(uint16_t state_id) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser && state_id < parser->state_count ? &parser->states[state_id] : 0;
            \\}
            \\
            \\bool ts_parser_is_blocked(void) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser ? parser->blocked : false;
            \\}
            \\
            \\uint16_t ts_parser_symbol_count(void) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser ? parser->symbol_count : 0;
            \\}
            \\
            \\uint16_t ts_parser_state_count(void) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser ? parser->state_count : 0;
            \\}
            \\
            \\const TSSymbolInfo *ts_parser_symbol(uint16_t symbol_id) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser && symbol_id < parser->symbol_count ? &parser->symbols[symbol_id] : 0;
            \\}
            \\
            \\const char *ts_parser_symbol_name(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->name : 0;
            \\}
            \\
            \\uint16_t ts_parser_symbol_id(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->id : 0;
            \\}
            \\
            \\uint16_t ts_parser_symbol_kind(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->kind : 0;
            \\}
            \\
            \\bool ts_parser_symbol_is_terminal(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->terminal : false;
            \\}
            \\
            \\bool ts_parser_symbol_is_external(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->external : false;
            \\}
            \\
            \\int16_t ts_parser_find_symbol_id(const char *symbol) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  uint16_t i = 0;
            \\  while (parser && i < parser->symbol_count) {
            \\    if (ts_string_eq(parser->symbols[i].name, symbol)) return (int16_t)i;
            \\    i += 1;
            \\  }
            \\  return -1;
            \\}
            \\
            \\const TSActionEntry *ts_parser_actions(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->actions : 0;
            \\}
            \\
            \\uint16_t ts_parser_action_count(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->action_count : 0;
            \\}
            \\
            \\const TSGotoEntry *ts_parser_gotos(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->gotos : 0;
            \\}
            \\
            \\uint16_t ts_parser_goto_count(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->goto_count : 0;
            \\}
            \\
            \\const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->unresolved : 0;
            \\}
            \\
            \\uint16_t ts_parser_unresolved_count(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->unresolved_count : 0;
            \\}
            \\
            \\const TSActionEntry *ts_parser_action_at(uint16_t state_id, uint16_t index) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state && index < state->action_count ? &state->actions[index] : 0;
            \\}
            \\
            \\const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state && index < state->goto_count ? &state->gotos[index] : 0;
            \\}
            \\
            \\const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state && index < state->unresolved_count ? &state->unresolved[index] : 0;
            \\}
            \\
            \\const char *ts_parser_action_symbol(uint16_t state_id, uint16_t index) {
            \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
            \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
            \\}
            \\
            \\const char *ts_parser_action_kind(uint16_t state_id, uint16_t index) {
            \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
            \\  if (!entry) return 0;
            \\  switch (entry->kind) {
            \\    case TS_ACTION_SHIFT: return "shift";
            \\    case TS_ACTION_REDUCE: return "reduce";
            \\    case TS_ACTION_ACCEPT: return "accept";
            \\    default: return 0;
            \\  }
            \\}
            \\
            \\bool ts_parser_action_is_shift(uint16_t state_id, uint16_t index) {
            \\  const char *kind = ts_parser_action_kind(state_id, index);
            \\  return kind && ts_string_eq(kind, "shift");
            \\}
            \\
            \\bool ts_parser_action_is_reduce(uint16_t state_id, uint16_t index) {
            \\  const char *kind = ts_parser_action_kind(state_id, index);
            \\  return kind && ts_string_eq(kind, "reduce");
            \\}
            \\
            \\bool ts_parser_action_is_accept(uint16_t state_id, uint16_t index) {
            \\  const char *kind = ts_parser_action_kind(state_id, index);
            \\  return kind && ts_string_eq(kind, "accept");
            \\}
            \\
            \\uint16_t ts_parser_action_value(uint16_t state_id, uint16_t index) {
            \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
            \\  return entry ? entry->value : 0;
            \\}
            \\
            \\const char *ts_parser_goto_symbol(uint16_t state_id, uint16_t index) {
            \\  const TSGotoEntry *entry = ts_parser_goto_at(state_id, index);
            \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
            \\}
            \\
            \\uint16_t ts_parser_goto_target(uint16_t state_id, uint16_t index) {
            \\  const TSGotoEntry *entry = ts_parser_goto_at(state_id, index);
            \\  return entry ? entry->state : 0;
            \\}
            \\
            \\const char *ts_parser_unresolved_symbol(uint16_t state_id, uint16_t index) {
            \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
            \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
            \\}
            \\
            \\const char *ts_parser_unresolved_reason(uint16_t state_id, uint16_t index) {
            \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
            \\  if (!entry) return 0;
            \\  switch (entry->reason) {
            \\    case TS_UNRESOLVED_SHIFT_REDUCE: return "shift_reduce";
            \\    case TS_UNRESOLVED_REDUCE_REDUCE_DEFERRED: return "reduce_reduce_deferred";
            \\    default: return 0;
            \\  }
            \\}
            \\
            \\uint16_t ts_parser_unresolved_candidates(uint16_t state_id, uint16_t index) {
            \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
            \\  return entry ? entry->candidates : 0;
            \\}
            \\
            \\const TSActionEntry *ts_parser_find_action(uint16_t state_id, const char *symbol) {
            \\  uint16_t count = ts_parser_action_count(state_id);
            \\  uint16_t i = 0;
            \\  while (i < count) {
            \\    const TSActionEntry *entry = ts_parser_action_at(state_id, i);
            \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
            \\    i += 1;
            \\  }
            \\  return 0;
            \\}
            \\
            \\const TSGotoEntry *ts_parser_find_goto(uint16_t state_id, const char *symbol) {
            \\  uint16_t count = ts_parser_goto_count(state_id);
            \\  uint16_t i = 0;
            \\  while (i < count) {
            \\    const TSGotoEntry *entry = ts_parser_goto_at(state_id, i);
            \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
            \\    i += 1;
            \\  }
            \\  return 0;
            \\}
            \\
            \\const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol) {
            \\  uint16_t count = ts_parser_unresolved_count(state_id);
            \\  uint16_t i = 0;
            \\  while (i < count) {
            \\    const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, i);
            \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
            \\    i += 1;
            \\  }
            \\  return 0;
            \\}
            \\
            \\bool ts_parser_has_action(uint16_t state_id, const char *symbol) {
            \\  return ts_parser_find_action(state_id, symbol) != 0;
            \\}
            \\
            \\bool ts_parser_has_goto(uint16_t state_id, const char *symbol) {
            \\  return ts_parser_find_goto(state_id, symbol) != 0;
            \\}
            \\
            \\bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol) {
            \\  return ts_parser_find_unresolved(state_id, symbol) != 0;
            \\}
            \\
        ,
    };
}

pub fn parseTableConflictParserCDump() Fixture {
    return .{
        .name = "parse_table_conflict_parser_c_dump",
        .contents =
            \\/* generated parser.c skeleton */
            \\/* top-level layout: ts_language -> parser/runtime/compatibility */
            \\#include <stdbool.h>
            \\#include <stdint.h>
            \\
            \\#define TS_PARSER_BLOCKED true
            \\#define TS_STATE_COUNT 6
            \\#define TS_SYMBOL_COUNT 4
            \\
            \\#define TS_LANGUAGE_VERSION 15
            \\#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION 13
            \\#define TS_SYMBOL_KIND_NON_TERMINAL 1
            \\#define TS_SYMBOL_KIND_TERMINAL 2
            \\#define TS_SYMBOL_KIND_EXTERNAL 3
            \\#define TS_ACTION_SHIFT 1
            \\#define TS_ACTION_REDUCE 2
            \\#define TS_ACTION_ACCEPT 3
            \\#define TS_UNRESOLVED_SHIFT_REDUCE 1
            \\#define TS_UNRESOLVED_REDUCE_REDUCE_DEFERRED 2
            \\
            \\typedef struct { uint16_t symbol_id; uint16_t kind; uint16_t value; } TSActionEntry;
            \\typedef struct { uint16_t symbol_id; uint16_t state; } TSGotoEntry;
            \\typedef struct { uint16_t symbol_id; uint16_t reason; uint16_t candidates; } TSUnresolvedEntry;
            \\
            \\typedef struct {
            \\  uint16_t id;
            \\  const char *name;
            \\  uint16_t kind;
            \\  bool terminal;
            \\  bool external;
            \\} TSSymbolInfo;
            \\
            \\typedef struct {
            \\  uint16_t language_version;
            \\  uint16_t min_compatible_language_version;
            \\  const char *target;
            \\  const char *layer;
            \\} TSCompatibilityInfo;
            \\
            \\typedef struct {
            \\  const TSActionEntry *actions;
            \\  uint16_t action_count;
            \\  const TSGotoEntry *gotos;
            \\  uint16_t goto_count;
            \\  const TSUnresolvedEntry *unresolved;
            \\  uint16_t unresolved_count;
            \\} TSStateTable;
            \\
            \\typedef struct {
            \\  bool blocked;
            \\  uint16_t symbol_count;
            \\  uint16_t state_count;
            \\  const TSSymbolInfo *symbols;
            \\  const TSStateTable *states;
            \\  const TSCompatibilityInfo *compatibility;
            \\} TSParser;
            \\
            \\typedef struct {
            \\  uint16_t action_count;
            \\  uint16_t goto_count;
            \\  uint16_t unresolved_count;
            \\  bool has_unresolved;
            \\} TSRuntimeStateInfo;
            \\
            \\typedef struct {
            \\  bool blocked;
            \\  bool has_unresolved_states;
            \\  uint16_t state_count;
            \\  const TSParser *parser;
            \\  const TSRuntimeStateInfo *states;
            \\} TSParserRuntime;
            \\
            \\typedef struct {
            \\  const TSParser *parser;
            \\  const TSParserRuntime *runtime;
            \\  const TSCompatibilityInfo *compatibility;
            \\} TSLanguage;
            \\
            \\static bool ts_string_eq(const char *a, const char *b) {
            \\  if (!a || !b) return false;
            \\  while (a[0] != 0 && b[0] != 0) {
            \\    if (a[0] != b[0]) return false;
            \\    a += 1;
            \\    b += 1;
            \\  }
            \\  return a[0] == b[0];
            \\}
            \\
            \\static const TSCompatibilityInfo ts_compatibility = {
            \\  .language_version = 15,
            \\  .min_compatible_language_version = 13,
            \\  .target = "tree-sitter-runtime-surface",
            \\  .layer = "intermediate",
            \\};
            \\
            \\static const TSSymbolInfo ts_symbols[TS_SYMBOL_COUNT] = {
            \\  {
            \\    .id = 0,
            \\    .name = "non_terminal:0",
            \\    .kind = 1,
            \\    .terminal = false,
            \\    .external = false,
            \\  },
            \\  {
            \\    .id = 1,
            \\    .name = "non_terminal:1",
            \\    .kind = 1,
            \\    .terminal = false,
            \\    .external = false,
            \\  },
            \\  {
            \\    .id = 2,
            \\    .name = "terminal:0",
            \\    .kind = 2,
            \\    .terminal = true,
            \\    .external = false,
            \\  },
            \\  {
            \\    .id = 3,
            \\    .name = "terminal:1",
            \\    .kind = 2,
            \\    .terminal = true,
            \\    .external = false,
            \\  },
            \\};
            \\
            \\/* state 0 */
            \\static const TSActionEntry ts_state_0_actions[] = {
            \\  { 3, 1, 3 },
            \\};
            \\static const TSGotoEntry ts_state_0_gotos[] = {
            \\  { 0, 1 },
            \\  { 1, 2 },
            \\};
            \\
            \\/* state 1 */
            \\static const TSActionEntry ts_state_1_actions[] = {
            \\};
            \\static const TSGotoEntry ts_state_1_gotos[] = {
            \\};
            \\
            \\/* state 2 */
            \\static const TSActionEntry ts_state_2_actions[] = {
            \\  { 2, 1, 4 },
            \\};
            \\static const TSGotoEntry ts_state_2_gotos[] = {
            \\};
            \\
            \\/* state 3 */
            \\static const TSActionEntry ts_state_3_actions[] = {
            \\  { 2, 2, 3 },
            \\};
            \\static const TSGotoEntry ts_state_3_gotos[] = {
            \\};
            \\
            \\/* state 4 */
            \\static const TSActionEntry ts_state_4_actions[] = {
            \\  { 3, 1, 3 },
            \\};
            \\static const TSGotoEntry ts_state_4_gotos[] = {
            \\  { 1, 5 },
            \\};
            \\
            \\/* state 5 */
            \\static const TSActionEntry ts_state_5_actions[] = {
            \\};
            \\static const TSGotoEntry ts_state_5_gotos[] = {
            \\};
            \\static const TSUnresolvedEntry ts_state_5_unresolved[] = {
            \\  { 2, 1, 2 },
            \\};
            \\static const TSStateTable ts_states[TS_STATE_COUNT] = {
            \\  {
            \\    .actions = ts_state_0_actions,
            \\    .action_count = 1,
            \\    .gotos = ts_state_0_gotos,
            \\    .goto_count = 2,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_1_actions,
            \\    .action_count = 0,
            \\    .gotos = ts_state_1_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_2_actions,
            \\    .action_count = 1,
            \\    .gotos = ts_state_2_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_3_actions,
            \\    .action_count = 1,
            \\    .gotos = ts_state_3_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_4_actions,
            \\    .action_count = 1,
            \\    .gotos = ts_state_4_gotos,
            \\    .goto_count = 1,
            \\    .unresolved = 0,
            \\    .unresolved_count = 0,
            \\  },
            \\  {
            \\    .actions = ts_state_5_actions,
            \\    .action_count = 0,
            \\    .gotos = ts_state_5_gotos,
            \\    .goto_count = 0,
            \\    .unresolved = ts_state_5_unresolved,
            \\    .unresolved_count = 1,
            \\  },
            \\};
            \\
            \\static const TSParser ts_parser = {
            \\  .blocked = true,
            \\  .symbol_count = TS_SYMBOL_COUNT,
            \\  .state_count = TS_STATE_COUNT,
            \\  .symbols = ts_symbols,
            \\  .states = ts_states,
            \\  .compatibility = &ts_compatibility,
            \\};
            \\
            \\static const TSRuntimeStateInfo ts_runtime_states[TS_STATE_COUNT] = {
            \\  {
            \\    .action_count = 1,
            \\    .goto_count = 2,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 0,
            \\    .goto_count = 0,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 1,
            \\    .goto_count = 0,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 1,
            \\    .goto_count = 0,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 1,
            \\    .goto_count = 1,
            \\    .unresolved_count = 0,
            \\    .has_unresolved = false,
            \\  },
            \\  {
            \\    .action_count = 0,
            \\    .goto_count = 0,
            \\    .unresolved_count = 1,
            \\    .has_unresolved = true,
            \\  },
            \\};
            \\
            \\static const TSParserRuntime ts_runtime = {
            \\  .blocked = true,
            \\  .has_unresolved_states = true,
            \\  .state_count = TS_STATE_COUNT,
            \\  .parser = &ts_parser,
            \\  .states = ts_runtime_states,
            \\};
            \\
            \\static const TSLanguage ts_language = {
            \\  .parser = &ts_parser,
            \\  .runtime = &ts_runtime,
            \\  .compatibility = &ts_compatibility,
            \\};
            \\
            \\const TSLanguage *ts_language_instance(void) {
            \\  return &ts_language;
            \\}
            \\
            \\const TSParser *ts_language_parser(const TSLanguage *language) {
            \\  return language ? language->parser : 0;
            \\}
            \\
            \\const TSParserRuntime *ts_language_runtime(const TSLanguage *language) {
            \\  return language ? language->runtime : 0;
            \\}
            \\
            \\const TSCompatibilityInfo *ts_language_compatibility(const TSLanguage *language) {
            \\  return language ? language->compatibility : 0;
            \\}
            \\
            \\const TSParser *ts_parser_instance(void) {
            \\  return ts_language_parser(ts_language_instance());
            \\}
            \\
            \\const TSCompatibilityInfo *ts_parser_compatibility(void) {
            \\  return ts_language_compatibility(ts_language_instance());
            \\}
            \\
            \\uint16_t ts_parser_language_version(void) {
            \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
            \\  return compatibility ? compatibility->language_version : 0;
            \\}
            \\
            \\uint16_t ts_parser_min_compatible_language_version(void) {
            \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
            \\  return compatibility ? compatibility->min_compatible_language_version : 0;
            \\}
            \\
            \\const char *ts_parser_compatibility_target(void) {
            \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
            \\  return compatibility ? compatibility->target : 0;
            \\}
            \\
            \\const char *ts_parser_compatibility_layer(void) {
            \\  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();
            \\  return compatibility ? compatibility->layer : 0;
            \\}
            \\
            \\const TSParserRuntime *ts_parser_runtime(void) {
            \\  return ts_language_runtime(ts_language_instance());
            \\}
            \\
            \\bool ts_parser_runtime_is_blocked(void) {
            \\  const TSParserRuntime *runtime = ts_parser_runtime();
            \\  return runtime ? runtime->blocked : false;
            \\}
            \\
            \\bool ts_parser_runtime_has_unresolved_states(void) {
            \\  const TSParserRuntime *runtime = ts_parser_runtime();
            \\  return runtime ? runtime->has_unresolved_states : false;
            \\}
            \\
            \\const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id) {
            \\  const TSParserRuntime *runtime = ts_parser_runtime();
            \\  return runtime && state_id < runtime->state_count ? &runtime->states[state_id] : 0;
            \\}
            \\
            \\bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) {
            \\  const TSRuntimeStateInfo *state = ts_parser_runtime_state(state_id);
            \\  return state ? state->has_unresolved : false;
            \\}
            \\
            \\const TSStateTable *ts_parser_state(uint16_t state_id) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser && state_id < parser->state_count ? &parser->states[state_id] : 0;
            \\}
            \\
            \\bool ts_parser_is_blocked(void) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser ? parser->blocked : false;
            \\}
            \\
            \\uint16_t ts_parser_symbol_count(void) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser ? parser->symbol_count : 0;
            \\}
            \\
            \\uint16_t ts_parser_state_count(void) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser ? parser->state_count : 0;
            \\}
            \\
            \\const TSSymbolInfo *ts_parser_symbol(uint16_t symbol_id) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  return parser && symbol_id < parser->symbol_count ? &parser->symbols[symbol_id] : 0;
            \\}
            \\
            \\const char *ts_parser_symbol_name(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->name : 0;
            \\}
            \\
            \\uint16_t ts_parser_symbol_id(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->id : 0;
            \\}
            \\
            \\uint16_t ts_parser_symbol_kind(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->kind : 0;
            \\}
            \\
            \\bool ts_parser_symbol_is_terminal(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->terminal : false;
            \\}
            \\
            \\bool ts_parser_symbol_is_external(uint16_t symbol_id) {
            \\  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);
            \\  return symbol ? symbol->external : false;
            \\}
            \\
            \\int16_t ts_parser_find_symbol_id(const char *symbol) {
            \\  const TSParser *parser = ts_parser_instance();
            \\  uint16_t i = 0;
            \\  while (parser && i < parser->symbol_count) {
            \\    if (ts_string_eq(parser->symbols[i].name, symbol)) return (int16_t)i;
            \\    i += 1;
            \\  }
            \\  return -1;
            \\}
            \\
            \\const TSActionEntry *ts_parser_actions(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->actions : 0;
            \\}
            \\
            \\uint16_t ts_parser_action_count(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->action_count : 0;
            \\}
            \\
            \\const TSGotoEntry *ts_parser_gotos(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->gotos : 0;
            \\}
            \\
            \\uint16_t ts_parser_goto_count(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->goto_count : 0;
            \\}
            \\
            \\const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->unresolved : 0;
            \\}
            \\
            \\uint16_t ts_parser_unresolved_count(uint16_t state_id) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state ? state->unresolved_count : 0;
            \\}
            \\
            \\const TSActionEntry *ts_parser_action_at(uint16_t state_id, uint16_t index) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state && index < state->action_count ? &state->actions[index] : 0;
            \\}
            \\
            \\const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state && index < state->goto_count ? &state->gotos[index] : 0;
            \\}
            \\
            \\const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) {
            \\  const TSStateTable *state = ts_parser_state(state_id);
            \\  return state && index < state->unresolved_count ? &state->unresolved[index] : 0;
            \\}
            \\
            \\const char *ts_parser_action_symbol(uint16_t state_id, uint16_t index) {
            \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
            \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
            \\}
            \\
            \\const char *ts_parser_action_kind(uint16_t state_id, uint16_t index) {
            \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
            \\  if (!entry) return 0;
            \\  switch (entry->kind) {
            \\    case TS_ACTION_SHIFT: return "shift";
            \\    case TS_ACTION_REDUCE: return "reduce";
            \\    case TS_ACTION_ACCEPT: return "accept";
            \\    default: return 0;
            \\  }
            \\}
            \\
            \\bool ts_parser_action_is_shift(uint16_t state_id, uint16_t index) {
            \\  const char *kind = ts_parser_action_kind(state_id, index);
            \\  return kind && ts_string_eq(kind, "shift");
            \\}
            \\
            \\bool ts_parser_action_is_reduce(uint16_t state_id, uint16_t index) {
            \\  const char *kind = ts_parser_action_kind(state_id, index);
            \\  return kind && ts_string_eq(kind, "reduce");
            \\}
            \\
            \\bool ts_parser_action_is_accept(uint16_t state_id, uint16_t index) {
            \\  const char *kind = ts_parser_action_kind(state_id, index);
            \\  return kind && ts_string_eq(kind, "accept");
            \\}
            \\
            \\uint16_t ts_parser_action_value(uint16_t state_id, uint16_t index) {
            \\  const TSActionEntry *entry = ts_parser_action_at(state_id, index);
            \\  return entry ? entry->value : 0;
            \\}
            \\
            \\const char *ts_parser_goto_symbol(uint16_t state_id, uint16_t index) {
            \\  const TSGotoEntry *entry = ts_parser_goto_at(state_id, index);
            \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
            \\}
            \\
            \\uint16_t ts_parser_goto_target(uint16_t state_id, uint16_t index) {
            \\  const TSGotoEntry *entry = ts_parser_goto_at(state_id, index);
            \\  return entry ? entry->state : 0;
            \\}
            \\
            \\const char *ts_parser_unresolved_symbol(uint16_t state_id, uint16_t index) {
            \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
            \\  return entry ? ts_parser_symbol_name(entry->symbol_id) : 0;
            \\}
            \\
            \\const char *ts_parser_unresolved_reason(uint16_t state_id, uint16_t index) {
            \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
            \\  if (!entry) return 0;
            \\  switch (entry->reason) {
            \\    case TS_UNRESOLVED_SHIFT_REDUCE: return "shift_reduce";
            \\    case TS_UNRESOLVED_REDUCE_REDUCE_DEFERRED: return "reduce_reduce_deferred";
            \\    default: return 0;
            \\  }
            \\}
            \\
            \\uint16_t ts_parser_unresolved_candidates(uint16_t state_id, uint16_t index) {
            \\  const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, index);
            \\  return entry ? entry->candidates : 0;
            \\}
            \\
            \\const TSActionEntry *ts_parser_find_action(uint16_t state_id, const char *symbol) {
            \\  uint16_t count = ts_parser_action_count(state_id);
            \\  uint16_t i = 0;
            \\  while (i < count) {
            \\    const TSActionEntry *entry = ts_parser_action_at(state_id, i);
            \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
            \\    i += 1;
            \\  }
            \\  return 0;
            \\}
            \\
            \\const TSGotoEntry *ts_parser_find_goto(uint16_t state_id, const char *symbol) {
            \\  uint16_t count = ts_parser_goto_count(state_id);
            \\  uint16_t i = 0;
            \\  while (i < count) {
            \\    const TSGotoEntry *entry = ts_parser_goto_at(state_id, i);
            \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
            \\    i += 1;
            \\  }
            \\  return 0;
            \\}
            \\
            \\const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol) {
            \\  uint16_t count = ts_parser_unresolved_count(state_id);
            \\  uint16_t i = 0;
            \\  while (i < count) {
            \\    const TSUnresolvedEntry *entry = ts_parser_unresolved_at(state_id, i);
            \\    if (entry && ts_string_eq(ts_parser_symbol_name(entry->symbol_id), symbol)) return entry;
            \\    i += 1;
            \\  }
            \\  return 0;
            \\}
            \\
            \\bool ts_parser_has_action(uint16_t state_id, const char *symbol) {
            \\  return ts_parser_find_action(state_id, symbol) != 0;
            \\}
            \\
            \\bool ts_parser_has_goto(uint16_t state_id, const char *symbol) {
            \\  return ts_parser_find_goto(state_id, symbol) != 0;
            \\}
            \\
            \\bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol) {
            \\  return ts_parser_find_unresolved(state_id, symbol) != 0;
            \\}
            \\
        ,
    };
}

pub fn parseTableConflictActionTableDump() Fixture {
    return .{
        .name = "parse_table_conflict_action_table_dump",
        .contents =
            \\state 0
            \\  actions:
            \\    terminal:1 => shift 3
            \\
            \\state 1
            \\  actions:
            \\
            \\state 2
            \\  actions:
            \\    terminal:0 => shift 4
            \\
            \\state 3
            \\  actions:
            \\    terminal:0 => reduce 3
            \\
            \\state 4
            \\  actions:
            \\    terminal:1 => shift 3
            \\
            \\state 5
            \\  actions:
            \\    terminal:0 => shift 4
            \\    terminal:0 => reduce 2
            \\  conflicts:
            \\    shift_reduce on terminal:0
            \\      #2@1
            \\      #2@3
            \\
        ,
    };
}

pub fn parseTableConflictGroupedActionTableDump() Fixture {
    return .{
        .name = "parse_table_conflict_grouped_action_table_dump",
        .contents =
            \\state 0
            \\  actions:
            \\    terminal:1:
            \\      shift 3
            \\
            \\state 1
            \\  actions:
            \\
            \\state 2
            \\  actions:
            \\    terminal:0:
            \\      shift 4
            \\
            \\state 3
            \\  actions:
            \\    terminal:0:
            \\      reduce 3
            \\
            \\state 4
            \\  actions:
            \\    terminal:1:
            \\      shift 3
            \\
            \\state 5
            \\  actions:
            \\    terminal:0:
            \\      shift 4
            \\      reduce 2
            \\  conflicts:
            \\    shift_reduce on terminal:0
            \\      #2@1
            \\      #2@3
            \\
        ,
    };
}

pub fn parseTableTinyGroupedActionTableDump() Fixture {
    return .{
        .name = "parse_table_tiny_grouped_action_table_dump",
        .contents =
            \\state 0
            \\  actions:
            \\    terminal:0:
            \\      shift 3
            \\
            \\state 1
            \\  actions:
            \\
            \\state 2
            \\  actions:
            \\
            \\state 3
            \\  actions:
            \\
        ,
    };
}

pub fn parseTableReduceReduceGroupedActionTableDump() Fixture {
    return .{
        .name = "parse_table_reduce_reduce_grouped_action_table_dump",
        .contents =
            \\state 0
            \\  actions:
            \\    terminal:1:
            \\      shift 6
            \\
            \\state 1
            \\  actions:
            \\
            \\state 2
            \\  actions:
            \\    terminal:0:
            \\      shift 7
            \\
            \\state 3
            \\  actions:
            \\    terminal:0:
            \\      reduce 2
            \\
            \\state 4
            \\  actions:
            \\    terminal:0:
            \\      reduce 3
            \\
            \\state 5
            \\  actions:
            \\    terminal:0:
            \\      reduce 4
            \\      reduce 5
            \\  conflicts:
            \\    reduce_reduce on terminal:0
            \\      #4@1 ?terminal:0
            \\      #5@1 ?terminal:0
            \\
            \\state 6
            \\  actions:
            \\    terminal:0:
            \\      reduce 6
            \\
            \\state 7
            \\  actions:
            \\
        ,
    };
}

pub fn parseTableReduceReduceActionTableDump() Fixture {
    return .{
        .name = "parse_table_reduce_reduce_action_table_dump",
        .contents =
            \\state 0
            \\  actions:
            \\    terminal:1 => shift 6
            \\
            \\state 1
            \\  actions:
            \\
            \\state 2
            \\  actions:
            \\    terminal:0 => shift 7
            \\
            \\state 3
            \\  actions:
            \\    terminal:0 => reduce 2
            \\
            \\state 4
            \\  actions:
            \\    terminal:0 => reduce 3
            \\
            \\state 5
            \\  actions:
            \\    terminal:0 => reduce 4
            \\    terminal:0 => reduce 5
            \\  conflicts:
            \\    reduce_reduce on terminal:0
            \\      #4@1 ?terminal:0
            \\      #5@1 ?terminal:0
            \\
            \\state 6
            \\  actions:
            \\    terminal:0 => reduce 6
            \\
            \\state 7
            \\  actions:
            \\
        ,
    };
}

pub fn parseTableMetadataGroupedActionTableDump() Fixture {
    return .{
        .name = "parse_table_metadata_grouped_action_table_dump",
        .contents =
            \\state 0
            \\  actions:
            \\    terminal:1:
            \\      shift 3
            \\
            \\state 1
            \\  actions:
            \\
            \\state 2
            \\  actions:
            \\    terminal:0:
            \\      shift 4
            \\
            \\state 3
            \\  actions:
            \\    terminal:0:
            \\      reduce 2
            \\
            \\state 4
            \\  actions:
            \\    terminal:1:
            \\      shift 6
            \\
            \\state 5
            \\  actions:
            \\
            \\state 6
            \\  actions:
            \\
        ,
    };
}

pub fn parseTableMetadataActionTableDump() Fixture {
    return .{
        .name = "parse_table_metadata_action_table_dump",
        .contents =
            \\state 0
            \\  actions:
            \\    terminal:1 => shift 3
            \\
            \\state 1
            \\  actions:
            \\
            \\state 2
            \\  actions:
            \\    terminal:0 => shift 4
            \\
            \\state 3
            \\  actions:
            \\    terminal:0 => reduce 2
            \\
            \\state 4
            \\  actions:
            \\    terminal:1 => shift 6
            \\
            \\state 5
            \\  actions:
            \\
            \\state 6
            \\  actions:
            \\
        ,
    };
}

pub fn parseTableReuseGrammarJson() Fixture {
    return .{
        .name = "parse_table_reuse",
        .contents =
            \\{
            \\  "name": "parse_table_reuse",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "expr" },
            \\        { "type": "SYMBOL", "name": "expr" }
            \\      ]
            \\    },
            \\    "expr": {
            \\      "type": "STRING",
            \\      "value": "x"
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableReduceReduceGrammarJson() Fixture {
    return .{
        .name = "parse_table_reduce_reduce",
        .contents =
            \\{
            \\  "name": "parse_table_reduce_reduce",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "start" },
            \\        { "type": "STRING", "value": "+" }
            \\      ]
            \\    },
            \\    "start": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "lhs" },
            \\        { "type": "SYMBOL", "name": "rhs" }
            \\      ]
            \\    },
            \\    "lhs": {
            \\      "type": "SYMBOL",
            \\      "name": "atom"
            \\    },
            \\    "rhs": {
            \\      "type": "SYMBOL",
            \\      "name": "atom"
            \\    },
            \\    "atom": {
            \\      "type": "STRING",
            \\      "value": "x"
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableMetadataGrammarJson() Fixture {
    return .{
        .name = "parse_table_metadata",
        .contents =
            \\{
            \\  "name": "parse_table_metadata",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        {
            \\          "type": "FIELD",
            \\          "name": "lhs",
            \\          "content": { "type": "SYMBOL", "name": "expr" }
            \\        },
            \\        {
            \\          "type": "PREC_LEFT",
            \\          "value": 1,
            \\          "content": { "type": "STRING", "value": "+" }
            \\        },
            \\        {
            \\          "type": "ALIAS",
            \\          "named": true,
            \\          "value": "rhs",
            \\          "content": { "type": "SYMBOL", "name": "expr" }
            \\        }
            \\      ]
            \\    },
            \\    "expr": {
            \\      "type": "STRING",
            \\      "value": "x"
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTablePrecedenceGrammarJson() Fixture {
    return .{
        .name = "parse_table_precedence",
        .contents =
            \\{
            \\  "name": "parse_table_precedence",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC_LEFT",
            \\          "value": 1,
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "STRING", "value": "+" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "STRING",
            \\          "value": "x"
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableDynamicPrecedenceGrammarJson() Fixture {
    return .{
        .name = "parse_table_dynamic_precedence",
        .contents =
            \\{
            \\  "name": "parse_table_dynamic_precedence",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC_DYNAMIC",
            \\          "value": 1,
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "STRING", "value": "+" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "STRING",
            \\          "value": "x"
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableNegativeDynamicPrecedenceGrammarJson() Fixture {
    return .{
        .name = "parse_table_negative_dynamic_precedence",
        .contents =
            \\{
            \\  "name": "parse_table_negative_dynamic_precedence",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC_DYNAMIC",
            \\          "value": -1,
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "STRING", "value": "+" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "STRING",
            \\          "value": "x"
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableDynamicBeatsNamedPrecedenceGrammarJson() Fixture {
    return .{
        .name = "parse_table_dynamic_beats_named_precedence",
        .contents =
            \\{
            \\  "name": "parse_table_dynamic_beats_named_precedence",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC_DYNAMIC",
            \\          "value": 1,
            \\          "content": {
            \\            "type": "PREC_LEFT",
            \\            "value": "sum",
            \\            "content": {
            \\              "type": "SEQ",
            \\              "members": [
            \\                { "type": "SYMBOL", "name": "expr" },
            \\                { "type": "SYMBOL", "name": "plus" },
            \\                { "type": "SYMBOL", "name": "expr" }
            \\              ]
            \\            }
            \\          }
            \\        },
            \\        {
            \\          "type": "PREC",
            \\          "value": "atom",
            \\          "content": {
            \\            "type": "STRING",
            \\            "value": "x"
            \\          }
            \\        }
            \\      ]
            \\    },
            \\    "plus": {
            \\      "type": "STRING",
            \\      "value": "+"
            \\    }
            \\  },
            \\  "precedences": [
            \\    [
            \\      { "type": "STRING", "value": "sum" },
            \\      { "type": "SYMBOL", "name": "plus" },
            \\      { "type": "STRING", "value": "atom" }
            \\    ]
            \\  ]
            \\}
        ,
    };
}

pub fn parseTableNamedPrecedenceGrammarJson() Fixture {
    return .{
        .name = "parse_table_named_precedence",
        .contents =
            \\{
            \\  "name": "parse_table_named_precedence",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC_LEFT",
            \\          "value": "sum",
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "SYMBOL", "name": "plus" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "PREC",
            \\          "value": "atom",
            \\          "content": {
            \\            "type": "STRING",
            \\            "value": "x"
            \\          }
            \\        }
            \\      ]
            \\    },
            \\    "plus": {
            \\      "type": "STRING",
            \\      "value": "+"
            \\    }
            \\  },
            \\  "precedences": [
            \\    [
            \\      { "type": "STRING", "value": "atom" },
            \\      { "type": "SYMBOL", "name": "plus" },
            \\      { "type": "STRING", "value": "sum" }
            \\    ]
            \\  ]
            \\}
        ,
    };
}

pub fn parseTableNamedPrecedenceShiftGrammarJson() Fixture {
    return .{
        .name = "parse_table_named_precedence_shift",
        .contents =
            \\{
            \\  "name": "parse_table_named_precedence_shift",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC_LEFT",
            \\          "value": "sum",
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "SYMBOL", "name": "plus" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "PREC",
            \\          "value": "atom",
            \\          "content": {
            \\            "type": "STRING",
            \\            "value": "x"
            \\          }
            \\        }
            \\      ]
            \\    },
            \\    "plus": {
            \\      "type": "STRING",
            \\      "value": "+"
            \\    }
            \\  },
            \\  "precedences": [
            \\    [
            \\      { "type": "STRING", "value": "sum" },
            \\      { "type": "SYMBOL", "name": "plus" },
            \\      { "type": "STRING", "value": "atom" }
            \\    ]
            \\  ]
            \\}
        ,
    };
}

pub fn parseTablePrecedenceResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_precedence_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: reduce 2
            \\
        ,
    };
}

pub fn parseTableNamedPrecedenceResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_named_precedence_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:0: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:1: shift 5
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:1: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:0: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: reduce 4
            \\
            \\state 6
            \\  resolved_actions:
            \\    terminal:1: reduce 2
            \\
        ,
    };
}

pub fn parseTableNamedPrecedenceShiftResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_named_precedence_shift_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:0: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:1: shift 5
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:1: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:0: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: reduce 4
            \\
            \\state 6
            \\  resolved_actions:
            \\    terminal:1: shift 5
            \\
        ,
    };
}

pub fn parseTableDynamicPrecedenceResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_dynamic_precedence_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: reduce 2
            \\
        ,
    };
}

pub fn parseTableNegativeDynamicPrecedenceResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_negative_dynamic_precedence_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
        ,
    };
}

pub fn parseTableDynamicBeatsNamedPrecedenceResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_dynamic_beats_named_precedence_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:0: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:1: shift 5
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:1: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:0: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: reduce 4
            \\
            \\state 6
            \\  resolved_actions:
            \\    terminal:1: reduce 2
            \\
        ,
    };
}

pub fn parseTableNegativePrecedenceGrammarJson() Fixture {
    return .{
        .name = "parse_table_negative_precedence",
        .contents =
            \\{
            \\  "name": "parse_table_negative_precedence",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC",
            \\          "value": -1,
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "STRING", "value": "+" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "STRING",
            \\          "value": "x"
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableAssociativityGrammarJson() Fixture {
    return .{
        .name = "parse_table_associativity",
        .contents =
            \\{
            \\  "name": "parse_table_associativity",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC_LEFT",
            \\          "value": 1,
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "STRING", "value": "+" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "PREC",
            \\          "value": 1,
            \\          "content": {
            \\            "type": "STRING",
            \\            "value": "x"
            \\          }
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableNonAssociativeGrammarJson() Fixture {
    return .{
        .name = "parse_table_non_associative",
        .contents =
            \\{
            \\  "name": "parse_table_non_associative",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC",
            \\          "value": 0,
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "STRING", "value": "+" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "PREC",
            \\          "value": 0,
            \\          "content": {
            \\            "type": "STRING",
            \\            "value": "x"
            \\          }
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableNegativePrecedenceResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_negative_precedence_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
        ,
    };
}

pub fn parseTableAssociativityResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_associativity_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: reduce 2
            \\
        ,
    };
}

pub fn parseTableNonAssociativeResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_non_associative_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: unresolved (shift_reduce)
            \\      candidate shift 4
            \\      candidate reduce 2
            \\
        ,
    };
}

pub fn parseTableRightAssociativityGrammarJson() Fixture {
    return .{
        .name = "parse_table_right_associativity",
        .contents =
            \\{
            \\  "name": "parse_table_right_associativity",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "expr"
            \\    },
            \\    "expr": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "PREC_RIGHT",
            \\          "value": 0,
            \\          "content": {
            \\            "type": "SEQ",
            \\            "members": [
            \\              { "type": "SYMBOL", "name": "expr" },
            \\              { "type": "STRING", "value": "+" },
            \\              { "type": "SYMBOL", "name": "expr" }
            \\            ]
            \\          }
            \\        },
            \\        {
            \\          "type": "PREC",
            \\          "value": 0,
            \\          "content": {
            \\            "type": "STRING",
            \\            "value": "x"
            \\          }
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn parseTableRightAssociativityResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_right_associativity_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
        ,
    };
}

pub fn parseTableConflictResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_conflict_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 4
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:1: shift 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: unresolved (shift_reduce)
            \\      candidate shift 4
            \\      candidate reduce 2
            \\
        ,
    };
}

pub fn parseTableReduceReduceResolvedActionDump() Fixture {
    return .{
        .name = "parse_table_reduce_reduce_resolved_action_dump",
        .contents =
            \\state 0
            \\  resolved_actions:
            \\    terminal:1: shift 6
            \\
            \\state 1
            \\  resolved_actions:
            \\
            \\state 2
            \\  resolved_actions:
            \\    terminal:0: shift 7
            \\
            \\state 3
            \\  resolved_actions:
            \\    terminal:0: reduce 2
            \\
            \\state 4
            \\  resolved_actions:
            \\    terminal:0: reduce 3
            \\
            \\state 5
            \\  resolved_actions:
            \\    terminal:0: unresolved (reduce_reduce_deferred)
            \\      candidate reduce 4
            \\      candidate reduce 5
            \\
            \\state 6
            \\  resolved_actions:
            \\    terminal:0: reduce 6
            \\
            \\state 7
            \\  resolved_actions:
            \\
        ,
    };
}

pub fn fieldChildrenGrammarJson() Fixture {
    return .{
        .name = "field_children",
        .contents =
            \\{
            \\  "name": "field_children",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            {
            \\              "type": "FIELD",
            \\              "name": "left",
            \\              "content": { "type": "SYMBOL", "name": "expr" }
            \\            },
            \\            { "type": "STRING", "value": "+" },
            \\            {
            \\              "type": "FIELD",
            \\              "name": "right",
            \\              "content": {
            \\                "type": "ALIAS",
            \\                "named": true,
            \\                "value": "rhs",
            \\                "content": { "type": "SYMBOL", "name": "expr" }
            \\              }
            \\            }
            \\          ]
            \\        },
            \\        {
            \\          "type": "FIELD",
            \\          "name": "left",
            \\          "content": { "type": "SYMBOL", "name": "expr" }
            \\        }
            \\      ]
            \\    },
            \\    "expr": {
            \\      "type": "STRING",
            \\      "value": "x"
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn fieldChildrenNodeTypesJson() Fixture {
    return .{
        .name = "field_children_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "expr",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "fields": {
            \\      "left": {
            \\        "multiple": false,
            \\        "required": true,
            \\        "types": [
            \\          {
            \\            "type": "expr",
            \\            "named": true
            \\          }
            \\        ]
            \\      },
            \\      "right": {
            \\        "multiple": false,
            \\        "required": false,
            \\        "types": [
            \\          {
            \\            "type": "rhs",
            \\            "named": true
            \\          }
            \\        ]
            \\      }
            \\    }
            \\  },
            \\  {
            \\    "type": "+",
            \\    "named": false
            \\  }
            \\]
            \\
        ,
    };
}

pub fn hiddenWrapperGrammarJson() Fixture {
    return .{
        .name = "hidden_wrapper",
        .contents =
            \\{
            \\  "name": "hidden_wrapper",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "_pair"
            \\    },
            \\    "_pair": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        {
            \\          "type": "FIELD",
            \\          "name": "left",
            \\          "content": { "type": "SYMBOL", "name": "expr" }
            \\        },
            \\        { "type": "STRING", "value": "+" },
            \\        {
            \\          "type": "FIELD",
            \\          "name": "right",
            \\          "content": {
            \\            "type": "ALIAS",
            \\            "named": true,
            \\            "value": "rhs",
            \\            "content": { "type": "SYMBOL", "name": "term" }
            \\          }
            \\        }
            \\      ]
            \\    },
            \\    "expr": { "type": "STRING", "value": "x" },
            \\    "term": { "type": "STRING", "value": "y" }
            \\  }
            \\}
        ,
    };
}

pub fn hiddenWrapperNodeTypesJson() Fixture {
    return .{
        .name = "hidden_wrapper_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "expr",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "rhs",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "term",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "fields": {
            \\      "left": {
            \\        "multiple": false,
            \\        "required": true,
            \\        "types": [
            \\          {
            \\            "type": "expr",
            \\            "named": true
            \\          }
            \\        ]
            \\      },
            \\      "right": {
            \\        "multiple": false,
            \\        "required": true,
            \\        "types": [
            \\          {
            \\            "type": "rhs",
            \\            "named": true
            \\          }
            \\        ]
            \\      }
            \\    }
            \\  },
            \\  {
            \\    "type": "+",
            \\    "named": false
            \\  },
            \\  {
            \\    "type": "term",
            \\    "named": true
            \\  }
            \\]
            \\
        ,
    };
}

pub fn mixedSemanticsGrammarJson() Fixture {
    return .{
        .name = "mixed_semantics",
        .contents =
            \\{
            \\  "name": "mixed_semantics",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "_wrapped_expression"
            \\    },
            \\    "_wrapped_expression": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "indent" },
            \\        {
            \\          "type": "FIELD",
            \\          "name": "body",
            \\          "content": {
            \\            "type": "ALIAS",
            \\            "named": true,
            \\            "value": "statement",
            \\            "content": { "type": "SYMBOL", "name": "expression" }
            \\          }
            \\        }
            \\      ]
            \\    },
            \\    "expression": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "identifier" },
            \\        { "type": "SYMBOL", "name": "number_literal" }
            \\      ]
            \\    },
            \\    "identifier": {
            \\      "type": "TOKEN",
            \\      "content": { "type": "PATTERN", "value": "[a-z]+" }
            \\    },
            \\    "number_literal": {
            \\      "type": "STRING",
            \\      "value": "42"
            \\    },
            \\    "space": {
            \\      "type": "STRING",
            \\      "value": " "
            \\    }
            \\  },
            \\  "externals": [
            \\    { "type": "SYMBOL", "name": "indent" }
            \\  ],
            \\  "extras": [
            \\    { "type": "SYMBOL", "name": "space" }
            \\  ],
            \\  "supertypes": ["expression"]
            \\}
        ,
    };
}

pub fn mixedSemanticsNodeTypesJson() Fixture {
    return .{
        .name = "mixed_semantics_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "expression",
            \\    "named": true,
            \\    "subtypes": [
            \\      {
            \\        "type": "identifier",
            \\        "named": true
            \\      },
            \\      {
            \\        "type": "number_literal",
            \\        "named": true
            \\      }
            \\    ]
            \\  },
            \\  {
            \\    "type": "identifier",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "identifier",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "number_literal",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "number_literal",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "fields": {
            \\      "body": {
            \\        "multiple": false,
            \\        "required": true,
            \\        "types": [
            \\          {
            \\            "type": "statement",
            \\            "named": true
            \\          }
            \\        ]
            \\      }
            \\    },
            \\    "children": {
            \\      "multiple": false,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "indent",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "space",
            \\    "named": true,
            \\    "extra": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "space",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "indent",
            \\    "named": true
            \\  }
            \\]
            \\
        ,
    };
}

pub fn mixedSemanticsLexicalDump() Fixture {
    return .{
        .name = "mixed_semantics_lexical_dump",
        .contents =
            \\blocked true
            \\variables 3
            \\variable 0
            \\  name identifier
            \\  kind named
            \\  form pattern [a-z]+
            \\  flags null
            \\  tokenized true
            \\  immediate false
            \\  implicit_precedence 0
            \\  start_state 0
            \\variable 1
            \\  name number_literal
            \\  kind named
            \\  form string 42
            \\  tokenized false
            \\  immediate false
            \\  implicit_precedence 0
            \\  start_state 0
            \\variable 2
            \\  name space
            \\  kind named
            \\  form string  
            \\  tokenized false
            \\  immediate false
            \\  implicit_precedence 0
            \\  start_state 0
            \\unsupported_separators 0
            \\unsupported_externals 1
            \\external 0 indent named
            \\
        ,
    };
}

pub fn repeatChoiceSeqGrammarJson() Fixture {
    return .{
        .name = "repeat_choice_seq",
        .contents =
            \\{
            \\  "name": "repeat_choice_seq",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "REPEAT1",
            \\      "content": { "type": "SYMBOL", "name": "_entry" }
            \\    },
            \\    "_entry": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "SYMBOL", "name": "identifier" },
            \\            {
            \\              "type": "REPEAT",
            \\              "content": { "type": "SYMBOL", "name": "number_literal" }
            \\            }
            \\          ]
            \\        },
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "SYMBOL", "name": "number_literal" },
            \\            {
            \\              "type": "REPEAT1",
            \\              "content": { "type": "SYMBOL", "name": "identifier" }
            \\            }
            \\          ]
            \\        }
            \\      ]
            \\    },
            \\    "identifier": {
            \\      "type": "TOKEN",
            \\      "content": { "type": "PATTERN", "value": "[a-z]+" }
            \\    },
            \\    "number_literal": {
            \\      "type": "STRING",
            \\      "value": "42"
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn repeatChoiceSeqNodeTypesJson() Fixture {
    return .{
        .name = "repeat_choice_seq_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "identifier",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "identifier",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "number_literal",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "number_literal",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "children": {
            \\      "multiple": true,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "identifier",
            \\          "named": true
            \\        },
            \\        {
            \\          "type": "number_literal",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  }
            \\]
            \\
        ,
    };
}

pub fn repeatChoiceSeqLexicalDump() Fixture {
    return .{
        .name = "repeat_choice_seq_lexical_dump",
        .contents =
            \\blocked false
            \\variables 2
            \\variable 0
            \\  name identifier
            \\  kind named
            \\  form pattern [a-z]+
            \\  flags null
            \\  tokenized true
            \\  immediate false
            \\  implicit_precedence 0
            \\  start_state 0
            \\variable 1
            \\  name number_literal
            \\  kind named
            \\  form string 42
            \\  tokenized false
            \\  immediate false
            \\  implicit_precedence 0
            \\  start_state 0
            \\unsupported_separators 0
            \\unsupported_externals 0
            \\
        ,
    };
}

pub fn repeatChoiceSeqValidInput() Fixture {
    return .{
        .name = "repeat_choice_seq_valid_input",
        .contents = "abc42",
    };
}

pub fn repeatChoiceSeqInvalidInput() Fixture {
    return .{
        .name = "repeat_choice_seq_invalid_input",
        .contents = "42",
    };
}

pub fn alternativeFieldsGrammarJson() Fixture {
    return .{
        .name = "alternative_fields",
        .contents =
            \\{
            \\  "name": "alternative_fields",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            {
            \\              "type": "FIELD",
            \\              "name": "left",
            \\              "content": { "type": "SYMBOL", "name": "expr" }
            \\            },
            \\            {
            \\              "type": "FIELD",
            \\              "name": "right",
            \\              "content": { "type": "SYMBOL", "name": "term" }
            \\            }
            \\          ]
            \\        },
            \\        {
            \\          "type": "FIELD",
            \\          "name": "left",
            \\          "content": { "type": "SYMBOL", "name": "expr" }
            \\        }
            \\      ]
            \\    },
            \\    "expr": {
            \\      "type": "TOKEN",
            \\      "content": { "type": "PATTERN", "value": "[a-z]+" }
            \\    },
            \\    "term": {
            \\      "type": "STRING",
            \\      "value": "42"
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn alternativeFieldsNodeTypesJson() Fixture {
    return .{
        .name = "alternative_fields_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "expr",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "fields": {
            \\      "left": {
            \\        "multiple": false,
            \\        "required": true,
            \\        "types": [
            \\          {
            \\            "type": "expr",
            \\            "named": true
            \\          }
            \\        ]
            \\      },
            \\      "right": {
            \\        "multiple": false,
            \\        "required": false,
            \\        "types": [
            \\          {
            \\            "type": "term",
            \\            "named": true
            \\          }
            \\        ]
            \\      }
            \\    }
            \\  },
            \\  {
            \\    "type": "term",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "term",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  }
            \\]
            \\
        ,
    };
}

pub fn hiddenAlternativeFieldsGrammarJson() Fixture {
    return .{
        .name = "hidden_alternative_fields",
        .contents =
            \\{
            \\  "name": "hidden_alternative_fields",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "_pair_both" },
            \\        { "type": "SYMBOL", "name": "_pair_left_only" }
            \\      ]
            \\    },
            \\    "_pair_both": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        {
            \\          "type": "FIELD",
            \\          "name": "left",
            \\          "content": { "type": "SYMBOL", "name": "expr" }
            \\        },
            \\        {
            \\          "type": "FIELD",
            \\          "name": "right",
            \\          "content": {
            \\            "type": "ALIAS",
            \\            "named": true,
            \\            "value": "rhs",
            \\            "content": { "type": "SYMBOL", "name": "term" }
            \\          }
            \\        }
            \\      ]
            \\    },
            \\    "_pair_left_only": {
            \\      "type": "FIELD",
            \\      "name": "left",
            \\      "content": { "type": "SYMBOL", "name": "expr" }
            \\    },
            \\    "expr": { "type": "STRING", "value": "x" },
            \\    "term": { "type": "STRING", "value": "y" }
            \\  }
            \\}
        ,
    };
}

pub fn hiddenAlternativeFieldsNodeTypesJson() Fixture {
    return .{
        .name = "hidden_alternative_fields_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "expr",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "rhs",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "term",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "fields": {
            \\      "left": {
            \\        "multiple": false,
            \\        "required": true,
            \\        "types": [
            \\          {
            \\            "type": "expr",
            \\            "named": true
            \\          }
            \\        ]
            \\      },
            \\      "right": {
            \\        "multiple": false,
            \\        "required": false,
            \\        "types": [
            \\          {
            \\            "type": "rhs",
            \\            "named": true
            \\          }
            \\        ]
            \\      }
            \\    }
            \\  },
            \\  {
            \\    "type": "term",
            \\    "named": true
            \\  }
            \\]
            \\
        ,
    };
}

pub fn hiddenExternalFieldsGrammarJson() Fixture {
    return .{
        .name = "hidden_external_fields",
        .contents =
            \\{
            \\  "name": "hidden_external_fields",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "_with_indent" },
            \\        { "type": "SYMBOL", "name": "_without_indent" }
            \\      ]
            \\    },
            \\    "_with_indent": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        {
            \\          "type": "FIELD",
            \\          "name": "lead",
            \\          "content": { "type": "SYMBOL", "name": "indent" }
            \\        },
            \\        {
            \\          "type": "FIELD",
            \\          "name": "body",
            \\          "content": {
            \\            "type": "ALIAS",
            \\            "named": true,
            \\            "value": "statement",
            \\            "content": { "type": "SYMBOL", "name": "expr" }
            \\          }
            \\        }
            \\      ]
            \\    },
            \\    "_without_indent": {
            \\      "type": "FIELD",
            \\      "name": "body",
            \\      "content": {
            \\        "type": "ALIAS",
            \\        "named": true,
            \\        "value": "statement",
            \\        "content": { "type": "SYMBOL", "name": "expr" }
            \\      }
            \\    },
            \\    "expr": { "type": "STRING", "value": "x" }
            \\  },
            \\  "externals": [
            \\    { "type": "SYMBOL", "name": "indent" }
            \\  ]
            \\}
        ,
    };
}

pub fn hiddenExternalFieldsNodeTypesJson() Fixture {
    return .{
        .name = "hidden_external_fields_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "fields": {
            \\      "body": {
            \\        "multiple": false,
            \\        "required": true,
            \\        "types": [
            \\          {
            \\            "type": "statement",
            \\            "named": true
            \\          }
            \\        ]
            \\      },
            \\      "lead": {
            \\        "multiple": false,
            \\        "required": false,
            \\        "types": [
            \\          {
            \\            "type": "indent",
            \\            "named": true
            \\          }
            \\        ]
            \\      }
            \\    }
            \\  },
            \\  {
            \\    "type": "statement",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "expr",
            \\    "named": true
            \\  },
            \\  {
            \\    "type": "indent",
            \\    "named": true
            \\  }
            \\]
            \\
        ,
    };
}

pub fn extraAliasedBodyGrammarJson() Fixture {
    return .{
        .name = "extra_aliased_body",
        .contents =
            \\{
            \\  "name": "extra_aliased_body",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "space" },
            \\        {
            \\          "type": "FIELD",
            \\          "name": "body",
            \\          "content": {
            \\            "type": "ALIAS",
            \\            "named": true,
            \\            "value": "statement",
            \\            "content": { "type": "SYMBOL", "name": "expr" }
            \\          }
            \\        }
            \\      ]
            \\    },
            \\    "expr": { "type": "STRING", "value": "x" },
            \\    "space": { "type": "STRING", "value": " " }
            \\  },
            \\  "extras": [
            \\    { "type": "SYMBOL", "name": "space" }
            \\  ]
            \\}
        ,
    };
}

pub fn extraAliasedBodyNodeTypesJson() Fixture {
    return .{
        .name = "extra_aliased_body_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "fields": {
            \\      "body": {
            \\        "multiple": false,
            \\        "required": true,
            \\        "types": [
            \\          {
            \\            "type": "statement",
            \\            "named": true
            \\          }
            \\        ]
            \\      }
            \\    },
            \\    "children": {
            \\      "multiple": false,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "space",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "space",
            \\    "named": true,
            \\    "extra": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "space",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "statement",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "expr",
            \\    "named": true
            \\  }
            \\]
            \\
        ,
    };
}

pub fn externalCollisionGrammarJson() Fixture {
    return .{
        .name = "external_collision",
        .contents =
            \\{
            \\  "name": "external_collision",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "statement"
            \\    },
            \\    "statement": {
            \\      "type": "ALIAS",
            \\      "named": true,
            \\      "value": "statement",
            \\      "content": { "type": "SYMBOL", "name": "indent" }
            \\    }
            \\  },
            \\  "externals": [
            \\    { "type": "SYMBOL", "name": "indent" }
            \\  ]
            \\}
        ,
    };
}

pub fn externalCollisionNodeTypesJson() Fixture {
    return .{
        .name = "external_collision_node_types",
        .contents =
            \\[
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "statement",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "statement",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": false,
            \\      "types": [
            \\        {
            \\          "type": "statement",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  }
            \\]
            \\
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

pub fn undeclaredPrecedenceGrammarJson() Fixture {
    return .{
        .name = "undeclared_precedence",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "PREC_LEFT",
            \\      "value": "missing_level",
            \\      "content": { "type": "STRING", "value": "x" }
            \\    }
            \\  },
            \\  "precedences": [
            \\    [
            \\      { "type": "STRING", "value": "declared_level" }
            \\    ]
            \\  ]
            \\}
        ,
    };
}

pub fn duplicateInternalExternalGrammarJson() Fixture {
    return .{
        .name = "duplicate_internal_external",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "x" },
            \\        { "type": "SYMBOL", "name": "y" },
            \\        { "type": "SYMBOL", "name": "z" }
            \\      ]
            \\    },
            \\    "x": { "type": "STRING", "value": "a" },
            \\    "y": { "type": "STRING", "value": "b" }
            \\  },
            \\  "externals": [
            \\    { "type": "SYMBOL", "name": "y" },
            \\    { "type": "SYMBOL", "name": "z" }
            \\  ]
            \\}
        ,
    };
}

pub fn nestedMetadataGrammarJson() Fixture {
    return .{
        .name = "nested_metadata",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "FIELD",
            \\      "name": "lhs",
            \\      "content": {
            \\        "type": "ALIAS",
            \\        "named": true,
            \\        "value": "renamed",
            \\        "content": {
            \\          "type": "PREC_LEFT",
            \\          "value": 3,
            \\          "content": {
            \\            "type": "PREC_DYNAMIC",
            \\            "value": 7,
            \\            "content": {
            \\              "type": "IMMEDIATE_TOKEN",
            \\              "content": {
            \\                "type": "RESERVED",
            \\                "context_name": "global",
            \\                "content": { "type": "STRING", "value": "x" }
            \\              }
            \\            }
            \\          }
            \\        }
            \\      }
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn normalizedListsGrammarJson() Fixture {
    return .{
        .name = "normalized_lists",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "expr" },
            \\        { "type": "SYMBOL", "name": "term" }
            \\      ]
            \\    },
            \\    "expr": { "type": "STRING", "value": "x" },
            \\    "term": { "type": "STRING", "value": "y" }
            \\  },
            \\  "inline": ["term", "expr", "term"],
            \\  "supertypes": ["term", "expr", "term"],
            \\  "conflicts": [
            \\    ["term", "expr", "expr"],
            \\    ["expr", "term"]
            \\  ],
            \\  "precedences": [
            \\    [
            \\      { "type": "STRING", "value": "a" },
            \\      { "type": "STRING", "value": "b" },
            \\      { "type": "STRING", "value": "a" }
            \\    ],
            \\    [
            \\      { "type": "STRING", "value": "a" },
            \\      { "type": "STRING", "value": "b" }
            \\    ]
            \\  ],
            \\  "reserved": {
            \\    "global": [
            \\      { "type": "STRING", "value": "yield" },
            \\      { "type": "STRING", "value": "yield" }
            \\    ]
            \\  }
            \\}
        ,
    };
}

pub fn conflictingPrecedenceOrderingGrammarJson() Fixture {
    return .{
        .name = "conflicting_precedence_ordering",
        .contents =
            \\{
            \\  "name": "basic",
            \\  "rules": {
            \\    "source_file": { "type": "STRING", "value": "x" }
            \\  },
            \\  "precedences": [
            \\    [
            \\      { "type": "STRING", "value": "a" },
            \\      { "type": "STRING", "value": "b" }
            \\    ],
            \\    [
            \\      { "type": "STRING", "value": "b" },
            \\      { "type": "STRING", "value": "a" }
            \\    ]
            \\  ]
            \\}
        ,
    };
}

pub fn behavioralConfigGrammarJson() Fixture {
    return .{
        .name = "behavioral_config",
        .contents =
            \\{
            \\  "name": "behavioral_config",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "value"
            \\    },
            \\    "value": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "object" },
            \\        { "type": "SYMBOL", "name": "array" },
            \\        { "type": "STRING", "value": "id" },
            \\        { "type": "STRING", "value": "0" },
            \\        { "type": "STRING", "value": "true" },
            \\        { "type": "STRING", "value": "false" },
            \\        { "type": "STRING", "value": "null" }
            \\      ]
            \\    },
            \\    "object": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "STRING", "value": "{" },
            \\            { "type": "STRING", "value": "}" }
            \\          ]
            \\        },
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "STRING", "value": "{" },
            \\            { "type": "SYMBOL", "name": "pair" },
            \\            { "type": "STRING", "value": "}" }
            \\          ]
            \\        }
            \\      ]
            \\    },
            \\    "pair": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "STRING", "value": "id" },
            \\        { "type": "STRING", "value": ":" },
            \\        { "type": "SYMBOL", "name": "value" }
            \\      ]
            \\    },
            \\    "array": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "STRING", "value": "[" },
            \\            { "type": "STRING", "value": "]" }
            \\          ]
            \\        },
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "STRING", "value": "[" },
            \\            { "type": "SYMBOL", "name": "value" },
            \\            { "type": "STRING", "value": "]" }
            \\          ]
            \\        }
            \\      ]
            \\    }
            \\  }
            \\}
        ,
    };
}

pub fn behavioralConfigGrammarJs() Fixture {
    return .{
        .name = "behavioral_config_js",
        .contents =
            \\module.exports = {
            \\  "name": "behavioral_config",
            \\  "rules": {
            \\    "source_file": {
            \\      "type": "SYMBOL",
            \\      "name": "value"
            \\    },
            \\    "value": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        { "type": "SYMBOL", "name": "object" },
            \\        { "type": "SYMBOL", "name": "array" },
            \\        { "type": "STRING", "value": "id" },
            \\        { "type": "STRING", "value": "0" },
            \\        { "type": "STRING", "value": "true" },
            \\        { "type": "STRING", "value": "false" },
            \\        { "type": "STRING", "value": "null" }
            \\      ]
            \\    },
            \\    "object": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "STRING", "value": "{" },
            \\            { "type": "STRING", "value": "}" }
            \\          ]
            \\        },
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "STRING", "value": "{" },
            \\            { "type": "SYMBOL", "name": "pair" },
            \\            { "type": "STRING", "value": "}" }
            \\          ]
            \\        }
            \\      ]
            \\    },
            \\    "pair": {
            \\      "type": "SEQ",
            \\      "members": [
            \\        { "type": "STRING", "value": "id" },
            \\        { "type": "STRING", "value": ":" },
            \\        { "type": "SYMBOL", "name": "value" }
            \\      ]
            \\    },
            \\    "array": {
            \\      "type": "CHOICE",
            \\      "members": [
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "STRING", "value": "[" },
            \\            { "type": "STRING", "value": "]" }
            \\          ]
            \\        },
            \\        {
            \\          "type": "SEQ",
            \\          "members": [
            \\            { "type": "STRING", "value": "[" },
            \\            { "type": "SYMBOL", "name": "value" },
            \\            { "type": "STRING", "value": "]" }
            \\          ]
            \\        }
            \\      ]
            \\    }
            \\  }
            \\};
        ,
    };
}

pub fn behavioralConfigValidInput() Fixture {
    return .{
        .name = "behavioral_config_valid_input",
        .contents = "{id:[0]}",
    };
}

pub fn behavioralConfigInvalidInput() Fixture {
    return .{
        .name = "behavioral_config_invalid_input",
        .contents = "{id 0}",
    };
}

test "basic fixture is non-empty" {
    const fixture = basicGrammarJson();
    try std.testing.expect(fixture.contents.len > 0);
}

test "behavioral comparison boundary fixtures are non-empty" {
    try std.testing.expect(behavioralConfigGrammarJson().contents.len > 0);
    try std.testing.expect(behavioralConfigGrammarJs().contents.len > 0);
    try std.testing.expect(behavioralConfigValidInput().contents.len > 0);
    try std.testing.expect(behavioralConfigInvalidInput().contents.len > 0);
}

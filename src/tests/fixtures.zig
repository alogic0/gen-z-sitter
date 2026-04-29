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
        \\        "type": "term",
        \\        "named": true
        \\      },
        \\      {
        \\        "type": "x",
        \\        "named": false
        \\      }
        \\    ]
        \\  },
        \\  {
        \\    "type": "source_file",
        \\    "named": true,
        \\    "root": true,
        \\    "fields": {},
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
        \\    "type": "indent",
        \\    "named": true
        \\  },
        \\  {
        \\    "type": "term",
        \\    "named": true
        \\  },
        \\  {
        \\    "type": "x",
        \\    "named": false
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
        \\    #0@0 [end]
        \\    #1@0 [end]
        \\    #2@0 [end]
        \\  transitions:
        \\    non_terminal:0 -> 1
        \\    non_terminal:1 -> 2
        \\    terminal:0 -> 3
        \\
        \\state 1
        \\  items:
        \\    #0@1 [end]
        \\  transitions:
        \\
        \\state 2
        \\  items:
        \\    #1@1 [end]
        \\  transitions:
        \\
        \\state 3
        \\  items:
        \\    #2@1 [end]
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
        \\    #0@0 [end]
        \\    #1@0 [end]
        \\    #2@0 [terminal:0, end]
        \\    #3@0 [terminal:0, end]
        \\  transitions:
        \\    non_terminal:0 -> 1
        \\    non_terminal:1 -> 2
        \\    terminal:1 -> 3
        \\
        \\state 1
        \\  items:
        \\    #0@1 [end]
        \\  transitions:
        \\
        \\state 2
        \\  items:
        \\    #1@1 [end]
        \\    #2@1 [terminal:0, end]
        \\  transitions:
        \\    terminal:0 -> 4
        \\
        \\state 3
        \\  items:
        \\    #3@1 [terminal:0, end]
        \\  transitions:
        \\
        \\state 4
        \\  items:
        \\    #2@0 [terminal:0, end]
        \\    #2@2 [terminal:0, end]
        \\    #3@0 [terminal:0, end]
        \\  transitions:
        \\    non_terminal:1 -> 5
        \\    terminal:1 -> 3
        \\
        \\state 5
        \\  items:
        \\    #2@1 [terminal:0, end]
        \\    #2@3 [terminal:0, end]
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
        \\    #0@0 [end]
        \\    #1@0 [end]
        \\    #2@0 [terminal:0, end]
        \\    #3@0 [terminal:0, end]
        \\  transitions:
        \\    non_terminal:0 -> 1
        \\    non_terminal:1 -> 2
        \\    terminal:1 -> 3
        \\  actions:
        \\    terminal:1 => shift 3
        \\
        \\state 1
        \\  items:
        \\    #0@1 [end]
        \\  transitions:
        \\  actions:
        \\    end => accept
        \\
        \\state 2
        \\  items:
        \\    #1@1 [end]
        \\    #2@1 [terminal:0, end]
        \\  transitions:
        \\    terminal:0 -> 4
        \\  actions:
        \\    end => reduce 1
        \\    terminal:0 => shift 4
        \\
        \\state 3
        \\  items:
        \\    #3@1 [terminal:0, end]
        \\  transitions:
        \\  actions:
        \\    end => reduce 3
        \\    terminal:0 => reduce 3
        \\
        \\state 4
        \\  items:
        \\    #2@0 [terminal:0, end]
        \\    #2@2 [terminal:0, end]
        \\    #3@0 [terminal:0, end]
        \\  transitions:
        \\    non_terminal:1 -> 5
        \\    terminal:1 -> 3
        \\  actions:
        \\    terminal:1 => shift 3
        \\
        \\state 5
        \\  items:
        \\    #2@1 [terminal:0, end]
        \\    #2@3 [terminal:0, end]
        \\  transitions:
        \\    terminal:0 -> 4
        \\  actions:
        \\    end => reduce 2
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
        \\    #0@0 [end]
        \\    #1@0 [end]
        \\    #2@0 [terminal:0]
        \\    #3@0 [terminal:0]
        \\    #4@0 [terminal:0]
        \\    #5@0 [terminal:0]
        \\    #6@0 [terminal:0]
        \\  transitions:
        \\    non_terminal:0 -> 1
        \\    non_terminal:1 -> 2
        \\    non_terminal:2 -> 3
        \\    non_terminal:3 -> 3
        \\    non_terminal:4 -> 4
        \\    terminal:1 -> 5
        \\  actions:
        \\    terminal:1 => shift 5
        \\
        \\state 1
        \\  items:
        \\    #0@1 [end]
        \\  transitions:
        \\  actions:
        \\    end => accept
        \\
        \\state 2
        \\  items:
        \\    #1@1 [end]
        \\  transitions:
        \\    terminal:0 -> 6
        \\  actions:
        \\    terminal:0 => shift 6
        \\
        \\state 3
        \\  items:
        \\    #2@1 [terminal:0]
        \\  transitions:
        \\  actions:
        \\    terminal:0 => reduce 2
        \\
        \\state 4
        \\  items:
        \\    #4@1 [terminal:0]
        \\    #5@1 [terminal:0]
        \\  transitions:
        \\  actions:
        \\    terminal:0 => reduce 4
        \\    terminal:0 => reduce 5
        \\  conflicts:
        \\    reduce_reduce on terminal:0
        \\      #4@1
        \\      #5@1
        \\
        \\state 5
        \\  items:
        \\    #6@1 [terminal:0]
        \\  transitions:
        \\  actions:
        \\    terminal:0 => reduce 6
        \\
        \\state 6
        \\  items:
        \\    #1@2 [end]
        \\  transitions:
        \\  actions:
        \\    end => reduce 1
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
        \\    #0@0 [end]
        \\    #1@0 [end]
        \\    #2@0 [terminal:0]
        \\  transitions:
        \\    non_terminal:0 -> 1
        \\    non_terminal:1 -> 2
        \\    terminal:1 -> 3
        \\  actions:
        \\    terminal:1 => shift 3
        \\
        \\state 1
        \\  items:
        \\    #0@1 [end]
        \\  transitions:
        \\  actions:
        \\    end => accept
        \\
        \\state 2
        \\  items:
        \\    #1@1 [end]
        \\  transitions:
        \\    terminal:0 -> 4
        \\  actions:
        \\    terminal:0 => shift 4
        \\
        \\state 3
        \\  items:
        \\    #2@1 [terminal:0]
        \\  transitions:
        \\  actions:
        \\    terminal:0 => reduce 2
        \\
        \\state 4
        \\  items:
        \\    #1@2 [end]
        \\    #2@0 [end]
        \\  transitions:
        \\    non_terminal:1 -> 5
        \\    terminal:1 -> 6
        \\  actions:
        \\    terminal:1 => shift 6
        \\
        \\state 5
        \\  items:
        \\    #1@3 [end]
        \\  transitions:
        \\  actions:
        \\    end => reduce 1
        \\
        \\state 6
        \\  items:
        \\    #2@1 [end]
        \\  transitions:
        \\  actions:
        \\    end => reduce 2
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
        \\    end => accept
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
        \\    end => reduce 1
        \\  gotos:
        \\
        \\state 6
        \\  actions:
        \\    end => reduce 2
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
        \\    end => accept
        \\  gotos:
        \\
        \\state 2
        \\  actions:
        \\    end => reduce 1
        \\    terminal:0 => shift 4
        \\  gotos:
        \\
        \\state 3
        \\  actions:
        \\    end => reduce 3
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
        \\    end => reduce 2
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
        \\  action end accept
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
        \\  action end reduce 1
        \\}
        \\
        \\state 6 {
        \\  action end reduce 2
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
        \\  action end accept
        \\}
        \\
        \\state 2 {
        \\  action end reduce 1
        \\  action terminal:0 shift 4
        \\}
        \\
        \\state 3 {
        \\  action end reduce 3
        \\  action terminal:0 reduce 3
        \\}
        \\
        \\state 4 {
        \\  action terminal:1 shift 3
        \\  goto non_terminal:1 5
        \\}
        \\
        \\state 5 {
        \\  action end reduce 2
        \\  unresolved terminal:0 shift_reduce candidates=2
        \\}
        ,
    };
}

pub fn parseTableMetadataParserCDump() Fixture {
    return .{
        .name = "parse_table_metadata_parser_c_dump",
        .contents =
        \\/* generated parser.c */
        \\/* tree-sitter runtime ABI layout */
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\
        \\#define LANGUAGE_VERSION 15
        \\#define MIN_COMPATIBLE_LANGUAGE_VERSION 13
        \\
        \\typedef uint16_t TSStateId;
        \\typedef uint16_t TSSymbol;
        \\typedef uint16_t TSFieldId;
        \\
        \\typedef struct TSLanguage TSLanguage;
        \\
        \\typedef struct {
        \\  uint8_t major_version;
        \\  uint8_t minor_version;
        \\  uint8_t patch_version;
        \\} TSLanguageMetadata;
        \\
        \\typedef struct {
        \\  TSFieldId field_id;
        \\  uint8_t child_index;
        \\  bool inherited;
        \\} TSFieldMapEntry;
        \\
        \\typedef struct {
        \\  uint16_t index;
        \\  uint16_t length;
        \\} TSMapSlice;
        \\
        \\typedef struct {
        \\  bool visible;
        \\  bool named;
        \\  bool supertype;
        \\} TSSymbolMetadata;
        \\
        \\typedef struct TSLexer TSLexer;
        \\struct TSLexer {
        \\  int32_t lookahead;
        \\  TSSymbol result_symbol;
        \\  void (*advance)(TSLexer *, bool);
        \\  void (*mark_end)(TSLexer *);
        \\  uint32_t (*get_column)(TSLexer *);
        \\  bool (*is_at_included_range_start)(const TSLexer *);
        \\  bool (*eof)(const TSLexer *);
        \\  void (*log)(const TSLexer *, const char *, ...);
        \\};
        \\
        \\typedef enum {
        \\  TSParseActionTypeShift,
        \\  TSParseActionTypeReduce,
        \\  TSParseActionTypeAccept,
        \\  TSParseActionTypeRecover,
        \\} TSParseActionType;
        \\
        \\typedef union {
        \\  struct { uint8_t type; TSStateId state; bool extra; bool repetition; } shift;
        \\  struct { uint8_t type; uint8_t child_count; TSSymbol symbol; int16_t dynamic_precedence; uint16_t production_id; } reduce;
        \\  uint8_t type;
        \\} TSParseAction;
        \\
        \\typedef struct {
        \\  uint16_t lex_state;
        \\  uint16_t external_lex_state;
        \\} TSLexMode;
        \\
        \\typedef struct {
        \\  uint16_t lex_state;
        \\  uint16_t external_lex_state;
        \\  uint16_t reserved_word_set_id;
        \\} TSLexerMode;
        \\
        \\typedef union {
        \\  TSParseAction action;
        \\  struct { uint8_t count; bool reusable; } entry;
        \\} TSParseActionEntry;
        \\
        \\typedef struct {
        \\  int32_t start;
        \\  int32_t end;
        \\} TSCharacterRange;
        \\
        \\struct TSLanguage {
        \\  uint32_t abi_version;
        \\  uint32_t symbol_count;
        \\  uint32_t alias_count;
        \\  uint32_t token_count;
        \\  uint32_t external_token_count;
        \\  uint32_t state_count;
        \\  uint32_t large_state_count;
        \\  uint32_t production_id_count;
        \\  uint32_t field_count;
        \\  uint16_t max_alias_sequence_length;
        \\  const uint16_t *parse_table;
        \\  const uint16_t *small_parse_table;
        \\  const uint32_t *small_parse_table_map;
        \\  const TSParseActionEntry *parse_actions;
        \\  const char * const *symbol_names;
        \\  const char * const *field_names;
        \\  const TSMapSlice *field_map_slices;
        \\  const TSFieldMapEntry *field_map_entries;
        \\  const TSSymbolMetadata *symbol_metadata;
        \\  const TSSymbol *public_symbol_map;
        \\  const uint16_t *alias_map;
        \\  const TSSymbol *alias_sequences;
        \\  const TSLexerMode *lex_modes;
        \\  bool (*lex_fn)(TSLexer *, TSStateId);
        \\  bool (*keyword_lex_fn)(TSLexer *, TSStateId);
        \\  TSSymbol keyword_capture_token;
        \\  struct {
        \\    const bool *states;
        \\    const TSSymbol *symbol_map;
        \\    void *(*create)(void);
        \\    void (*destroy)(void *);
        \\    bool (*scan)(void *, TSLexer *, const bool *symbol_whitelist);
        \\    unsigned (*serialize)(void *, char *);
        \\    void (*deserialize)(void *, const char *, unsigned);
        \\  } external_scanner;
        \\  const TSStateId *primary_state_ids;
        \\  const char *name;
        \\  const TSSymbol *reserved_words;
        \\  uint16_t max_reserved_word_set_size;
        \\  uint32_t supertype_count;
        \\  const TSSymbol *supertype_symbols;
        \\  const TSMapSlice *supertype_map_slices;
        \\  const TSSymbol *supertype_map_entries;
        \\  TSLanguageMetadata metadata;
        \\};
        \\
        \\#if defined(__GNUC__) || defined(__clang__)
        \\#define GEN_Z_SITTER_UNUSED_FUNCTION __attribute__((unused))
        \\#else
        \\#define GEN_Z_SITTER_UNUSED_FUNCTION
        \\#endif
        \\static inline bool GEN_Z_SITTER_UNUSED_FUNCTION set_contains(const TSCharacterRange *ranges, uint32_t len, int32_t lookahead) {
        \\  uint32_t index = 0;
        \\  uint32_t size = len - index;
        \\  while (size > 1) {
        \\    uint32_t half_size = size / 2;
        \\    uint32_t mid_index = index + half_size;
        \\    const TSCharacterRange *range = &ranges[mid_index];
        \\    if (lookahead >= range->start && lookahead <= range->end) {
        \\      return true;
        \\    } else if (lookahead > range->end) {
        \\      index = mid_index;
        \\    }
        \\    size -= half_size;
        \\  }
        \\  const TSCharacterRange *range = &ranges[index];
        \\  return lookahead >= range->start && lookahead <= range->end;
        \\}
        \\
        \\#undef GEN_Z_SITTER_UNUSED_FUNCTION
        \\
        \\#define SMALL_STATE(id) ((id) - LARGE_STATE_COUNT)
        \\#define STATE(id) id
        \\#define ACTIONS(id) id
        \\
        \\#ifdef _MSC_VER
        \\#define UNUSED __pragma(warning(suppress : 4101))
        \\#else
        \\#define UNUSED __attribute__((unused))
        \\#endif
        \\#define START_LEXER() \
        \\  bool result = false; \
        \\  bool skip = false; \
        \\  UNUSED \
        \\  bool eof = false; \
        \\  int32_t lookahead; \
        \\  lexer->result_symbol = 0; \
        \\  goto start; \
        \\  next_state: \
        \\  lexer->advance(lexer, skip); \
        \\  start: \
        \\  skip = false; \
        \\  lookahead = lexer->lookahead
        \\#define ADVANCE(state_value) \
        \\  do { state = state_value; goto next_state; } while (0)
        \\#define ADVANCE_MAP(...) \
        \\  do { \
        \\    static const uint16_t map[] = { __VA_ARGS__ }; \
        \\    for (uint32_t i = 0; i < sizeof(map) / sizeof(map[0]); i += 2) { \
        \\      if (map[i] == lookahead) { \
        \\        state = map[i + 1]; \
        \\        goto next_state; \
        \\      } \
        \\    } \
        \\  } while (0)
        \\#define SKIP(state_value) \
        \\  do { skip = true; state = state_value; goto next_state; } while (0)
        \\#define ACCEPT_TOKEN(symbol_value) \
        \\  do { result = true; lexer->result_symbol = symbol_value; lexer->mark_end(lexer); } while (0)
        \\#define END_STATE() return result
        \\
        \\#define GEN_Z_SITTER_RESULT_API_STATUS "temporary generated result API: ts_generated_parse_result and ts_generated_result_tree_string are available when parser.c is emitted with --glr-loop"
        \\#define GEN_Z_SITTER_TREE_API_STATUS "temporary project tree API: generated parse results are not a Tree-sitter-compatible tree ABI"
        \\#define GEN_Z_SITTER_TREE_API_COMPATIBLE 0
        \\#define GEN_Z_SITTER_ERROR_RECOVERY_STATUS "bounded generated GLR recovery is enabled; it is not yet a full tree-sitter runtime recovery implementation"
        \\#define GEN_Z_SITTER_SUPPORT_BOUNDARY_STATUS "local generator evidence only; use gen-z-sitter compat-report and compare-upstream for grammar-specific compatibility"
        \\#define GEN_Z_SITTER_CORPUS_STATUS "corpus comparison is not embedded in parser.c; use compare-upstream to reproduce upstream and runtime evidence"
        \\#define GEN_Z_SITTER_EXTERNAL_SCANNER_STATUS "scanner-free generated parser; no external scanner callbacks are required"
        \\
        \\const char *ts_generated_result_api_status(void) {
        \\  return GEN_Z_SITTER_RESULT_API_STATUS;
        \\}
        \\
        \\const char *ts_generated_tree_api_status(void) {
        \\  return GEN_Z_SITTER_TREE_API_STATUS;
        \\}
        \\
        \\bool ts_generated_tree_api_is_tree_sitter_compatible(void) {
        \\  return GEN_Z_SITTER_TREE_API_COMPATIBLE != 0;
        \\}
        \\
        \\const char *ts_generated_error_recovery_status(void) {
        \\  return GEN_Z_SITTER_ERROR_RECOVERY_STATUS;
        \\}
        \\
        \\const char *ts_generated_support_boundary_status(void) {
        \\  return GEN_Z_SITTER_SUPPORT_BOUNDARY_STATUS;
        \\}
        \\
        \\const char *ts_generated_corpus_status(void) {
        \\  return GEN_Z_SITTER_CORPUS_STATUS;
        \\}
        \\
        \\const char *ts_generated_external_scanner_status(void) {
        \\  return GEN_Z_SITTER_EXTERNAL_SCANNER_STATUS;
        \\}
        \\
        \\#define STATE_COUNT 7
        \\#define LARGE_STATE_COUNT 2
        \\#define SYMBOL_COUNT 6
        \\#define TOKEN_COUNT 3
        \\#define EXTERNAL_TOKEN_COUNT 0
        \\#define PRODUCTION_ID_COUNT 3
        \\#define FIELD_COUNT 1
        \\#define ALIAS_COUNT 1
        \\#define MAX_ALIAS_SEQUENCE_LENGTH 3
        \\#define MAX_RESERVED_WORD_SET_SIZE 0
        \\
        \\static bool ts_lex(TSLexer *lexer, TSStateId state) {
        \\  START_LEXER();
        \\  eof = lexer->eof(lexer);
        \\  switch (state) {
        \\    case 0:
        \\      if (lookahead == 120) ADVANCE(1);
        \\      END_STATE();
        \\    case 1:
        \\      ACCEPT_TOKEN(2);
        \\      END_STATE();
        \\    case 2:
        \\      if (lookahead == 43) ADVANCE(3);
        \\      END_STATE();
        \\    case 3:
        \\      ACCEPT_TOKEN(1);
        \\      END_STATE();
        \\    default:
        \\      return false;
        \\  }
        \\}
        \\
        \\static const char * const ts_symbol_names[SYMBOL_COUNT] = {
        \\  [0] = "end",
        \\  [1] = "terminal:0",
        \\  [2] = "terminal:1",
        \\  [3] = "source_file",
        \\  [4] = "expr",
        \\  [5] = "rhs",
        \\};
        \\
        \\static const TSSymbolMetadata ts_symbol_metadata[SYMBOL_COUNT] = {
        \\  [0] = { .visible = false, .named = false, .supertype = false },
        \\  [1] = { .visible = true, .named = false, .supertype = false },
        \\  [2] = { .visible = true, .named = false, .supertype = false },
        \\  [3] = { .visible = true, .named = true, .supertype = false },
        \\  [4] = { .visible = true, .named = true, .supertype = false },
        \\  [5] = { .visible = true, .named = true, .supertype = false },
        \\};
        \\
        \\static const TSSymbol ts_symbol_map[SYMBOL_COUNT] = {
        \\  [0] = 0,
        \\  [1] = 1,
        \\  [2] = 2,
        \\  [3] = 3,
        \\  [4] = 4,
        \\  [5] = 5,
        \\};
        \\
        \\static const char * const ts_field_names[FIELD_COUNT + 1] = {
        \\  [0] = "",
        \\  [1] = "lhs",
        \\};
        \\
        \\static const TSFieldMapEntry ts_field_map_entries[] = {
        \\  [0] = { .field_id = 1, .child_index = 0, .inherited = false },
        \\};
        \\
        \\static const TSMapSlice ts_field_map_slices[] = {
        \\  [0] = { .index = 0, .length = 0 },
        \\  [1] = { .index = 0, .length = 1 },
        \\  [2] = { .index = 1, .length = 0 },
        \\};
        \\
        \\static const uint16_t ts_non_terminal_alias_map[] = {
        \\  4, 2,
        \\    4,
        \\    5,
        \\  0,
        \\};
        \\static const TSSymbol ts_alias_sequences[][MAX_ALIAS_SEQUENCE_LENGTH > 0 ? MAX_ALIAS_SEQUENCE_LENGTH : 1] = {
        \\  [0] = { 0, 0, 0 },
        \\  [1] = { 0, 0, 5 },
        \\  [2] = { 0, 0, 0 },
        \\};
        \\
        \\static const TSStateId ts_primary_state_ids[STATE_COUNT] = {
        \\  [0] = 0,
        \\  [1] = 1,
        \\  [2] = 2,
        \\  [3] = 3,
        \\  [4] = 4,
        \\  [5] = 5,
        \\  [6] = 3,
        \\};
        \\
        \\static const uint16_t ts_parse_table[LARGE_STATE_COUNT][SYMBOL_COUNT] = {
        \\  [STATE(0)] = {
        \\    [3] = STATE(1),
        \\    [4] = STATE(2),
        \\    [2] = ACTIONS(1),
        \\  },
        \\  [STATE(1)] = {
        \\    [0] = ACTIONS(3),
        \\  },
        \\};
        \\
        \\static const uint16_t ts_small_parse_table[] = {
        \\  [0] = 1,
        \\  ACTIONS(5), 1, 1,
        \\  [4] = 1,
        \\  ACTIONS(7), 1, 1,
        \\  [8] = 2,
        \\  STATE(5), 1, 4,
        \\  ACTIONS(9), 1, 2,
        \\  [15] = 1,
        \\  ACTIONS(11), 1, 0,
        \\  [19] = 1,
        \\  ACTIONS(7), 1, 0,
        \\};
        \\
        \\static const uint32_t ts_small_parse_table_map[] = {
        \\  [SMALL_STATE(2)] = 0,
        \\  [SMALL_STATE(3)] = 4,
        \\  [SMALL_STATE(4)] = 8,
        \\  [SMALL_STATE(5)] = 15,
        \\  [SMALL_STATE(6)] = 19,
        \\};
        \\
        \\static const TSParseActionEntry ts_parse_actions[] = {
        \\  [0] = { .entry = { .count = 0, .reusable = false } },
        \\  [1] = { .entry = { .count = 1, .reusable = true } }, { .action = { .shift = { .type = TSParseActionTypeShift, .state = 3, .extra = false, .repetition = false } } },
        \\  [3] = { .entry = { .count = 1, .reusable = true } }, { .action = { .type = TSParseActionTypeAccept } },
        \\  [5] = { .entry = { .count = 1, .reusable = true } }, { .action = { .shift = { .type = TSParseActionTypeShift, .state = 4, .extra = false, .repetition = false } } },
        \\  [7] = { .entry = { .count = 1, .reusable = true } }, { .action = { .reduce = { .type = TSParseActionTypeReduce, .child_count = 1, .symbol = 4, .dynamic_precedence = 0, .production_id = 2 } } },
        \\  [9] = { .entry = { .count = 1, .reusable = true } }, { .action = { .shift = { .type = TSParseActionTypeShift, .state = 6, .extra = false, .repetition = false } } },
        \\  [11] = { .entry = { .count = 1, .reusable = true } }, { .action = { .reduce = { .type = TSParseActionTypeReduce, .child_count = 3, .symbol = 3, .dynamic_precedence = 0, .production_id = 1 } } },
        \\};
        \\
        \\static const TSLexerMode ts_lex_modes[STATE_COUNT] = {
        \\  [0] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [1] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [2] = { .lex_state = 2, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [3] = { .lex_state = 2, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [4] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [5] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [6] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\};
        \\
        \\static const TSLanguage ts_language = {
        \\  .abi_version = LANGUAGE_VERSION,
        \\  .symbol_count = SYMBOL_COUNT,
        \\  .alias_count = ALIAS_COUNT,
        \\  .token_count = TOKEN_COUNT,
        \\  .external_token_count = EXTERNAL_TOKEN_COUNT,
        \\  .state_count = STATE_COUNT,
        \\  .large_state_count = LARGE_STATE_COUNT,
        \\  .production_id_count = PRODUCTION_ID_COUNT,
        \\  .field_count = FIELD_COUNT,
        \\  .max_alias_sequence_length = MAX_ALIAS_SEQUENCE_LENGTH,
        \\  .parse_table = &ts_parse_table[0][0],
        \\  .small_parse_table = ts_small_parse_table,
        \\  .small_parse_table_map = ts_small_parse_table_map,
        \\  .parse_actions = ts_parse_actions,
        \\  .symbol_names = ts_symbol_names,
        \\  .field_names = ts_field_names,
        \\  .field_map_slices = ts_field_map_slices,
        \\  .field_map_entries = ts_field_map_entries,
        \\  .symbol_metadata = ts_symbol_metadata,
        \\  .public_symbol_map = ts_symbol_map,
        \\  .alias_map = ts_non_terminal_alias_map,
        \\  .alias_sequences = &ts_alias_sequences[0][0],
        \\  .lex_modes = ts_lex_modes,
        \\  .lex_fn = ts_lex,
        \\  .keyword_lex_fn = NULL,
        \\  .keyword_capture_token = 0,
        \\  .primary_state_ids = ts_primary_state_ids,
        \\  .name = "parse_table_metadata",
        \\  .supertype_count = 0,
        \\  .max_reserved_word_set_size = 0,
        \\  .metadata = { .major_version = 0, .minor_version = 0, .patch_version = 0 },
        \\};
        \\
        \\const TSLanguage *tree_sitter_parse_table_metadata(void) {
        \\  return &ts_language;
        \\}
        \\
        \\const TSLanguage *tree_sitter_generated(void) {
        \\  return tree_sitter_parse_table_metadata();
        \\}
        \\
        ,
    };
}

pub fn parseTableConflictParserCDump() Fixture {
    return .{
        .name = "parse_table_conflict_parser_c_dump",
        .contents =
        \\/* generated parser.c */
        \\/* tree-sitter runtime ABI layout */
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\
        \\#include <string.h>
        \\
        \\#define LANGUAGE_VERSION 15
        \\#define MIN_COMPATIBLE_LANGUAGE_VERSION 13
        \\
        \\typedef uint16_t TSStateId;
        \\typedef uint16_t TSSymbol;
        \\typedef uint16_t TSFieldId;
        \\
        \\typedef struct TSLanguage TSLanguage;
        \\
        \\typedef struct {
        \\  uint8_t major_version;
        \\  uint8_t minor_version;
        \\  uint8_t patch_version;
        \\} TSLanguageMetadata;
        \\
        \\typedef struct {
        \\  TSFieldId field_id;
        \\  uint8_t child_index;
        \\  bool inherited;
        \\} TSFieldMapEntry;
        \\
        \\typedef struct {
        \\  uint16_t index;
        \\  uint16_t length;
        \\} TSMapSlice;
        \\
        \\typedef struct {
        \\  bool visible;
        \\  bool named;
        \\  bool supertype;
        \\} TSSymbolMetadata;
        \\
        \\typedef struct TSLexer TSLexer;
        \\struct TSLexer {
        \\  int32_t lookahead;
        \\  TSSymbol result_symbol;
        \\  void (*advance)(TSLexer *, bool);
        \\  void (*mark_end)(TSLexer *);
        \\  uint32_t (*get_column)(TSLexer *);
        \\  bool (*is_at_included_range_start)(const TSLexer *);
        \\  bool (*eof)(const TSLexer *);
        \\  void (*log)(const TSLexer *, const char *, ...);
        \\};
        \\
        \\typedef enum {
        \\  TSParseActionTypeShift,
        \\  TSParseActionTypeReduce,
        \\  TSParseActionTypeAccept,
        \\  TSParseActionTypeRecover,
        \\} TSParseActionType;
        \\
        \\typedef union {
        \\  struct { uint8_t type; TSStateId state; bool extra; bool repetition; } shift;
        \\  struct { uint8_t type; uint8_t child_count; TSSymbol symbol; int16_t dynamic_precedence; uint16_t production_id; } reduce;
        \\  uint8_t type;
        \\} TSParseAction;
        \\
        \\typedef struct {
        \\  uint16_t lex_state;
        \\  uint16_t external_lex_state;
        \\} TSLexMode;
        \\
        \\typedef struct {
        \\  uint16_t lex_state;
        \\  uint16_t external_lex_state;
        \\  uint16_t reserved_word_set_id;
        \\} TSLexerMode;
        \\
        \\typedef union {
        \\  TSParseAction action;
        \\  struct { uint8_t count; bool reusable; } entry;
        \\} TSParseActionEntry;
        \\
        \\typedef struct {
        \\  int32_t start;
        \\  int32_t end;
        \\} TSCharacterRange;
        \\
        \\struct TSLanguage {
        \\  uint32_t abi_version;
        \\  uint32_t symbol_count;
        \\  uint32_t alias_count;
        \\  uint32_t token_count;
        \\  uint32_t external_token_count;
        \\  uint32_t state_count;
        \\  uint32_t large_state_count;
        \\  uint32_t production_id_count;
        \\  uint32_t field_count;
        \\  uint16_t max_alias_sequence_length;
        \\  const uint16_t *parse_table;
        \\  const uint16_t *small_parse_table;
        \\  const uint32_t *small_parse_table_map;
        \\  const TSParseActionEntry *parse_actions;
        \\  const char * const *symbol_names;
        \\  const char * const *field_names;
        \\  const TSMapSlice *field_map_slices;
        \\  const TSFieldMapEntry *field_map_entries;
        \\  const TSSymbolMetadata *symbol_metadata;
        \\  const TSSymbol *public_symbol_map;
        \\  const uint16_t *alias_map;
        \\  const TSSymbol *alias_sequences;
        \\  const TSLexerMode *lex_modes;
        \\  bool (*lex_fn)(TSLexer *, TSStateId);
        \\  bool (*keyword_lex_fn)(TSLexer *, TSStateId);
        \\  TSSymbol keyword_capture_token;
        \\  struct {
        \\    const bool *states;
        \\    const TSSymbol *symbol_map;
        \\    void *(*create)(void);
        \\    void (*destroy)(void *);
        \\    bool (*scan)(void *, TSLexer *, const bool *symbol_whitelist);
        \\    unsigned (*serialize)(void *, char *);
        \\    void (*deserialize)(void *, const char *, unsigned);
        \\  } external_scanner;
        \\  const TSStateId *primary_state_ids;
        \\  const char *name;
        \\  const TSSymbol *reserved_words;
        \\  uint16_t max_reserved_word_set_size;
        \\  uint32_t supertype_count;
        \\  const TSSymbol *supertype_symbols;
        \\  const TSMapSlice *supertype_map_slices;
        \\  const TSSymbol *supertype_map_entries;
        \\  TSLanguageMetadata metadata;
        \\};
        \\
        \\#if defined(__GNUC__) || defined(__clang__)
        \\#define GEN_Z_SITTER_UNUSED_FUNCTION __attribute__((unused))
        \\#else
        \\#define GEN_Z_SITTER_UNUSED_FUNCTION
        \\#endif
        \\static inline bool GEN_Z_SITTER_UNUSED_FUNCTION set_contains(const TSCharacterRange *ranges, uint32_t len, int32_t lookahead) {
        \\  uint32_t index = 0;
        \\  uint32_t size = len - index;
        \\  while (size > 1) {
        \\    uint32_t half_size = size / 2;
        \\    uint32_t mid_index = index + half_size;
        \\    const TSCharacterRange *range = &ranges[mid_index];
        \\    if (lookahead >= range->start && lookahead <= range->end) {
        \\      return true;
        \\    } else if (lookahead > range->end) {
        \\      index = mid_index;
        \\    }
        \\    size -= half_size;
        \\  }
        \\  const TSCharacterRange *range = &ranges[index];
        \\  return lookahead >= range->start && lookahead <= range->end;
        \\}
        \\
        \\#undef GEN_Z_SITTER_UNUSED_FUNCTION
        \\
        \\#define SMALL_STATE(id) ((id) - LARGE_STATE_COUNT)
        \\#define STATE(id) id
        \\#define ACTIONS(id) id
        \\
        \\#ifdef _MSC_VER
        \\#define UNUSED __pragma(warning(suppress : 4101))
        \\#else
        \\#define UNUSED __attribute__((unused))
        \\#endif
        \\#define START_LEXER() \
        \\  bool result = false; \
        \\  bool skip = false; \
        \\  UNUSED \
        \\  bool eof = false; \
        \\  int32_t lookahead; \
        \\  lexer->result_symbol = 0; \
        \\  goto start; \
        \\  next_state: \
        \\  lexer->advance(lexer, skip); \
        \\  start: \
        \\  skip = false; \
        \\  lookahead = lexer->lookahead
        \\#define ADVANCE(state_value) \
        \\  do { state = state_value; goto next_state; } while (0)
        \\#define ADVANCE_MAP(...) \
        \\  do { \
        \\    static const uint16_t map[] = { __VA_ARGS__ }; \
        \\    for (uint32_t i = 0; i < sizeof(map) / sizeof(map[0]); i += 2) { \
        \\      if (map[i] == lookahead) { \
        \\        state = map[i + 1]; \
        \\        goto next_state; \
        \\      } \
        \\    } \
        \\  } while (0)
        \\#define SKIP(state_value) \
        \\  do { skip = true; state = state_value; goto next_state; } while (0)
        \\#define ACCEPT_TOKEN(symbol_value) \
        \\  do { result = true; lexer->result_symbol = symbol_value; lexer->mark_end(lexer); } while (0)
        \\#define END_STATE() return result
        \\
        \\#define GEN_Z_SITTER_RESULT_API_STATUS "temporary generated result API: ts_generated_parse_result and ts_generated_result_tree_string are available when parser.c is emitted with --glr-loop"
        \\#define GEN_Z_SITTER_TREE_API_STATUS "temporary project tree API: generated parse results are not a Tree-sitter-compatible tree ABI"
        \\#define GEN_Z_SITTER_TREE_API_COMPATIBLE 0
        \\#define GEN_Z_SITTER_ERROR_RECOVERY_STATUS "bounded generated GLR recovery is enabled; it is not yet a full tree-sitter runtime recovery implementation"
        \\#define GEN_Z_SITTER_SUPPORT_BOUNDARY_STATUS "local generator evidence only; use gen-z-sitter compat-report and compare-upstream for grammar-specific compatibility"
        \\#define GEN_Z_SITTER_CORPUS_STATUS "corpus comparison is not embedded in parser.c; use compare-upstream to reproduce upstream and runtime evidence"
        \\#define GEN_Z_SITTER_EXTERNAL_SCANNER_STATUS "scanner-free generated parser; no external scanner callbacks are required"
        \\
        \\const char *ts_generated_result_api_status(void) {
        \\  return GEN_Z_SITTER_RESULT_API_STATUS;
        \\}
        \\
        \\const char *ts_generated_tree_api_status(void) {
        \\  return GEN_Z_SITTER_TREE_API_STATUS;
        \\}
        \\
        \\bool ts_generated_tree_api_is_tree_sitter_compatible(void) {
        \\  return GEN_Z_SITTER_TREE_API_COMPATIBLE != 0;
        \\}
        \\
        \\const char *ts_generated_error_recovery_status(void) {
        \\  return GEN_Z_SITTER_ERROR_RECOVERY_STATUS;
        \\}
        \\
        \\const char *ts_generated_support_boundary_status(void) {
        \\  return GEN_Z_SITTER_SUPPORT_BOUNDARY_STATUS;
        \\}
        \\
        \\const char *ts_generated_corpus_status(void) {
        \\  return GEN_Z_SITTER_CORPUS_STATUS;
        \\}
        \\
        \\const char *ts_generated_external_scanner_status(void) {
        \\  return GEN_Z_SITTER_EXTERNAL_SCANNER_STATUS;
        \\}
        \\
        \\typedef struct {
        \\  uint16_t symbol_id;
        \\  uint16_t reason;
        \\  uint16_t action_index;
        \\  uint16_t action_count;
        \\} TSUnresolvedEntry;
        \\
        \\#define STATE_COUNT 6
        \\#define LARGE_STATE_COUNT 2
        \\#define SYMBOL_COUNT 5
        \\#define TOKEN_COUNT 3
        \\#define EXTERNAL_TOKEN_COUNT 0
        \\#define PRODUCTION_ID_COUNT 4
        \\#define FIELD_COUNT 0
        \\#define ALIAS_COUNT 0
        \\#define MAX_ALIAS_SEQUENCE_LENGTH 0
        \\#define MAX_RESERVED_WORD_SET_SIZE 0
        \\
        \\static bool ts_lex(TSLexer *lexer, TSStateId state) {
        \\  START_LEXER();
        \\  eof = lexer->eof(lexer);
        \\  switch (state) {
        \\    case 0:
        \\      if (lookahead == 120) ADVANCE(1);
        \\      END_STATE();
        \\    case 1:
        \\      ACCEPT_TOKEN(2);
        \\      END_STATE();
        \\    case 2:
        \\      if (lookahead == 43) ADVANCE(3);
        \\      END_STATE();
        \\    case 3:
        \\      ACCEPT_TOKEN(1);
        \\      END_STATE();
        \\    default:
        \\      return false;
        \\  }
        \\}
        \\
        \\static const char * const ts_symbol_names[SYMBOL_COUNT] = {
        \\  [0] = "end",
        \\  [1] = "terminal:0",
        \\  [2] = "terminal:1",
        \\  [3] = "source_file",
        \\  [4] = "expr",
        \\};
        \\
        \\static const TSSymbolMetadata ts_symbol_metadata[SYMBOL_COUNT] = {
        \\  [0] = { .visible = false, .named = false, .supertype = false },
        \\  [1] = { .visible = true, .named = false, .supertype = false },
        \\  [2] = { .visible = true, .named = false, .supertype = false },
        \\  [3] = { .visible = true, .named = true, .supertype = false },
        \\  [4] = { .visible = true, .named = true, .supertype = false },
        \\};
        \\
        \\static const TSSymbol ts_symbol_map[SYMBOL_COUNT] = {
        \\  [0] = 0,
        \\  [1] = 1,
        \\  [2] = 2,
        \\  [3] = 3,
        \\  [4] = 4,
        \\};
        \\
        \\static const char * const ts_field_names[FIELD_COUNT + 1] = {
        \\  [0] = "",
        \\};
        \\
        \\static const TSFieldMapEntry ts_field_map_entries[] = {
        \\  { 0 },
        \\};
        \\
        \\static const TSMapSlice ts_field_map_slices[] = {
        \\  [0] = { .index = 0, .length = 0 },
        \\  [1] = { .index = 0, .length = 0 },
        \\  [2] = { .index = 0, .length = 0 },
        \\  [3] = { .index = 0, .length = 0 },
        \\};
        \\
        \\static const uint16_t ts_non_terminal_alias_map[] = {
        \\  0,
        \\};
        \\static const TSSymbol ts_alias_sequences[][MAX_ALIAS_SEQUENCE_LENGTH > 0 ? MAX_ALIAS_SEQUENCE_LENGTH : 1] = {
        \\  [0] = { 0 },
        \\  [1] = { 0 },
        \\  [2] = { 0 },
        \\  [3] = { 0 },
        \\};
        \\
        \\static const TSStateId ts_primary_state_ids[STATE_COUNT] = {
        \\  [0] = 0,
        \\  [1] = 1,
        \\  [2] = 2,
        \\  [3] = 3,
        \\  [4] = 4,
        \\  [5] = 5,
        \\};
        \\
        \\static const uint16_t ts_parse_table[LARGE_STATE_COUNT][SYMBOL_COUNT] = {
        \\  [STATE(0)] = {
        \\    [3] = STATE(1),
        \\    [4] = STATE(2),
        \\    [2] = ACTIONS(1),
        \\  },
        \\  [STATE(1)] = {
        \\    [0] = ACTIONS(3),
        \\  },
        \\};
        \\
        \\static const uint16_t ts_small_parse_table[] = {
        \\  [0] = 2,
        \\  ACTIONS(5), 1, 0,
        \\  ACTIONS(7), 1, 1,
        \\  [7] = 1,
        \\  ACTIONS(9), 2, 0, 1,
        \\  [12] = 2,
        \\  STATE(5), 1, 4,
        \\  ACTIONS(1), 1, 2,
        \\  [19] = 1,
        \\  ACTIONS(11), 1, 0,
        \\};
        \\
        \\static const uint32_t ts_small_parse_table_map[] = {
        \\  [SMALL_STATE(2)] = 0,
        \\  [SMALL_STATE(3)] = 7,
        \\  [SMALL_STATE(4)] = 12,
        \\  [SMALL_STATE(5)] = 19,
        \\};
        \\
        \\static const TSParseActionEntry ts_parse_actions[] = {
        \\  [0] = { .entry = { .count = 0, .reusable = false } },
        \\  [1] = { .entry = { .count = 1, .reusable = true } }, { .action = { .shift = { .type = TSParseActionTypeShift, .state = 3, .extra = false, .repetition = false } } },
        \\  [3] = { .entry = { .count = 1, .reusable = true } }, { .action = { .type = TSParseActionTypeAccept } },
        \\  [5] = { .entry = { .count = 1, .reusable = true } }, { .action = { .reduce = { .type = TSParseActionTypeReduce, .child_count = 1, .symbol = 3, .dynamic_precedence = 0, .production_id = 1 } } },
        \\  [7] = { .entry = { .count = 1, .reusable = true } }, { .action = { .shift = { .type = TSParseActionTypeShift, .state = 4, .extra = false, .repetition = false } } },
        \\  [9] = { .entry = { .count = 1, .reusable = true } }, { .action = { .reduce = { .type = TSParseActionTypeReduce, .child_count = 1, .symbol = 4, .dynamic_precedence = 0, .production_id = 3 } } },
        \\  [11] = { .entry = { .count = 1, .reusable = true } }, { .action = { .reduce = { .type = TSParseActionTypeReduce, .child_count = 3, .symbol = 4, .dynamic_precedence = 0, .production_id = 2 } } },
        \\};
        \\
        \\static const TSUnresolvedEntry ts_state_5_unresolved[] = {
        \\  { .symbol_id = 1, .reason = 1, .action_index = 0, .action_count = 0 },
        \\};
        \\
        \\static const TSLexerMode ts_lex_modes[STATE_COUNT] = {
        \\  [0] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [1] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [2] = { .lex_state = 2, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [3] = { .lex_state = 2, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [4] = { .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\  [5] = { .lex_state = 2, .external_lex_state = 0, .reserved_word_set_id = 0 },
        \\};
        \\
        \\bool ts_parser_runtime_has_unresolved_states(void) {
        \\  return true;
        \\}
        \\
        \\const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id) {
        \\  switch (state_id) {
        \\    case 5: return ts_state_5_unresolved;
        \\    default: return NULL;
        \\  }
        \\}
        \\
        \\uint16_t ts_parser_unresolved_count(uint16_t state_id) {
        \\  switch (state_id) {
        \\    case 5: return 1;
        \\    default: return 0;
        \\  }
        \\}
        \\
        \\bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) {
        \\  return ts_parser_unresolved_count(state_id) != 0;
        \\}
        \\
        \\const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) {
        \\  const TSUnresolvedEntry *entries = ts_parser_unresolved(state_id);
        \\  return entries && index < ts_parser_unresolved_count(state_id) ? &entries[index] : NULL;
        \\}
        \\
        \\const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol) {
        \\  const TSUnresolvedEntry *entries = ts_parser_unresolved(state_id);
        \\  uint16_t count = ts_parser_unresolved_count(state_id);
        \\  for (uint16_t i = 0; i < count; i++) {
        \\    if (strcmp(ts_symbol_names[entries[i].symbol_id], symbol) == 0) return &entries[i];
        \\  }
        \\  return NULL;
        \\}
        \\
        \\bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol) {
        \\  return ts_parser_find_unresolved(state_id, symbol) != NULL;
        \\}
        \\
        \\static const TSLanguage ts_language = {
        \\  .abi_version = LANGUAGE_VERSION,
        \\  .symbol_count = SYMBOL_COUNT,
        \\  .alias_count = ALIAS_COUNT,
        \\  .token_count = TOKEN_COUNT,
        \\  .external_token_count = EXTERNAL_TOKEN_COUNT,
        \\  .state_count = STATE_COUNT,
        \\  .large_state_count = LARGE_STATE_COUNT,
        \\  .production_id_count = PRODUCTION_ID_COUNT,
        \\  .field_count = FIELD_COUNT,
        \\  .max_alias_sequence_length = MAX_ALIAS_SEQUENCE_LENGTH,
        \\  .parse_table = &ts_parse_table[0][0],
        \\  .small_parse_table = ts_small_parse_table,
        \\  .small_parse_table_map = ts_small_parse_table_map,
        \\  .parse_actions = ts_parse_actions,
        \\  .symbol_names = ts_symbol_names,
        \\  .field_names = ts_field_names,
        \\  .field_map_slices = ts_field_map_slices,
        \\  .field_map_entries = ts_field_map_entries,
        \\  .symbol_metadata = ts_symbol_metadata,
        \\  .public_symbol_map = ts_symbol_map,
        \\  .alias_map = ts_non_terminal_alias_map,
        \\  .alias_sequences = &ts_alias_sequences[0][0],
        \\  .lex_modes = ts_lex_modes,
        \\  .lex_fn = ts_lex,
        \\  .keyword_lex_fn = NULL,
        \\  .keyword_capture_token = 0,
        \\  .primary_state_ids = ts_primary_state_ids,
        \\  .name = "parse_table_conflict",
        \\  .supertype_count = 0,
        \\  .max_reserved_word_set_size = 0,
        \\  .metadata = { .major_version = 0, .minor_version = 0, .patch_version = 0 },
        \\};
        \\
        \\const TSLanguage *tree_sitter_parse_table_conflict(void) {
        \\  return &ts_language;
        \\}
        \\
        \\const TSLanguage *tree_sitter_generated(void) {
        \\  return tree_sitter_parse_table_conflict();
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
        \\    end => accept
        \\
        \\state 2
        \\  actions:
        \\    end => reduce 1
        \\    terminal:0 => shift 4
        \\
        \\state 3
        \\  actions:
        \\    end => reduce 3
        \\    terminal:0 => reduce 3
        \\
        \\state 4
        \\  actions:
        \\    terminal:1 => shift 3
        \\
        \\state 5
        \\  actions:
        \\    end => reduce 2
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
        \\    end:
        \\      accept
        \\
        \\state 2
        \\  actions:
        \\    end:
        \\      reduce 1
        \\    terminal:0:
        \\      shift 4
        \\
        \\state 3
        \\  actions:
        \\    end:
        \\      reduce 3
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
        \\    end:
        \\      reduce 2
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
        \\    end:
        \\      accept
        \\
        \\state 2
        \\  actions:
        \\    end:
        \\      reduce 1
        \\
        \\state 3
        \\  actions:
        \\    end:
        \\      reduce 2
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
        \\      shift 5
        \\
        \\state 1
        \\  actions:
        \\    end:
        \\      accept
        \\
        \\state 2
        \\  actions:
        \\    terminal:0:
        \\      shift 6
        \\
        \\state 3
        \\  actions:
        \\    terminal:0:
        \\      reduce 2
        \\
        \\state 4
        \\  actions:
        \\    terminal:0:
        \\      reduce 4
        \\      reduce 5
        \\  conflicts:
        \\    reduce_reduce on terminal:0
        \\      #4@1
        \\      #5@1
        \\
        \\state 5
        \\  actions:
        \\    terminal:0:
        \\      reduce 6
        \\
        \\state 6
        \\  actions:
        \\    end:
        \\      reduce 1
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
        \\    terminal:1 => shift 5
        \\
        \\state 1
        \\  actions:
        \\    end => accept
        \\
        \\state 2
        \\  actions:
        \\    terminal:0 => shift 6
        \\
        \\state 3
        \\  actions:
        \\    terminal:0 => reduce 2
        \\
        \\state 4
        \\  actions:
        \\    terminal:0 => reduce 4
        \\    terminal:0 => reduce 5
        \\  conflicts:
        \\    reduce_reduce on terminal:0
        \\      #4@1
        \\      #5@1
        \\
        \\state 5
        \\  actions:
        \\    terminal:0 => reduce 6
        \\
        \\state 6
        \\  actions:
        \\    end => reduce 1
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
        \\    end:
        \\      accept
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
        \\    end:
        \\      reduce 1
        \\
        \\state 6
        \\  actions:
        \\    end:
        \\      reduce 2
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
        \\    end => accept
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
        \\    end => reduce 1
        \\
        \\state 6
        \\  actions:
        \\    end => reduce 2
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
        \\          "type": "PREC_RIGHT",
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:0: shift 4
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
        \\    terminal:0: reduce 3
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:1: shift 3
        \\
        \\state 5
        \\  resolved_actions:
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:1: shift 5
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
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
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:1: shift 5
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
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
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:0: shift 4
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
        \\    terminal:0: reduce 3
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:1: shift 3
        \\
        \\state 5
        \\  resolved_actions:
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:0: shift 4
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
        \\    terminal:0: reduce 3
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:1: shift 3
        \\
        \\state 5
        \\  resolved_actions:
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:1: shift 5
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
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
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:0: shift 4
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
        \\    terminal:0: reduce 3
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:1: shift 3
        \\
        \\state 5
        \\  resolved_actions:
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:0: shift 4
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
        \\    terminal:0: reduce 3
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:1: shift 3
        \\
        \\state 5
        \\  resolved_actions:
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:0: shift 4
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
        \\    terminal:0: reduce 3
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:1: shift 3
        \\
        \\state 5
        \\  resolved_actions:
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:0: shift 4
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
        \\    terminal:0: reduce 3
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:1: shift 3
        \\
        \\state 5
        \\  resolved_actions:
        \\    end: reduce 2
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
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    end: reduce 1
        \\    terminal:0: shift 4
        \\
        \\state 3
        \\  resolved_actions:
        \\    end: reduce 3
        \\    terminal:0: reduce 3
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:1: shift 3
        \\
        \\state 5
        \\  resolved_actions:
        \\    end: reduce 2
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
        \\    terminal:1: shift 5
        \\
        \\state 1
        \\  resolved_actions:
        \\    end: accept
        \\
        \\state 2
        \\  resolved_actions:
        \\    terminal:0: shift 6
        \\
        \\state 3
        \\  resolved_actions:
        \\    terminal:0: reduce 2
        \\
        \\state 4
        \\  resolved_actions:
        \\    terminal:0: unresolved (reduce_reduce_deferred)
        \\      candidate reduce 4
        \\      candidate reduce 5
        \\
        \\state 5
        \\  resolved_actions:
        \\    terminal:0: reduce 6
        \\
        \\state 6
        \\  resolved_actions:
        \\    end: reduce 1
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
        \\    "type": "rhs",
        \\    "named": true,
        \\    "fields": {},
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
        \\    "type": "expr",
        \\    "named": true
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
        \\    "type": "identifier",
        \\    "named": true
        \\  },
        \\  {
        \\    "type": "indent",
        \\    "named": true
        \\  },
        \\  {
        \\    "type": "number_literal",
        \\    "named": true
        \\  },
        \\  {
        \\    "type": "space",
        \\    "named": true,
        \\    "extra": true
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

pub fn mixedSemanticsExternalScannerDump() Fixture {
    return .{
        .name = "mixed_semantics_external_scanner_dump",
        .contents =
        \\blocked false
        \\tokens 1
        \\token 0 index 0 indent named
        \\uses 1
        \\use 0 external 0 variable _wrapped_expression production 0 step 0 field null
        \\unsupported_features 0
        \\
        ,
    };
}

pub fn mixedSemanticsValidInput() Fixture {
    return .{
        .name = "mixed_semantics_valid_input",
        .contents = "  foo",
    };
}

pub fn mixedSemanticsInvalidInput() Fixture {
    return .{
        .name = "mixed_semantics_invalid_input",
        .contents = "foo",
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
        \\    "type": "source_file",
        \\    "named": true,
        \\    "root": true,
        \\    "fields": {},
        \\    "children": {
        \\      "multiple": true,
        \\      "required": false,
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
        \\  },
        \\  {
        \\    "type": "identifier",
        \\    "named": true
        \\  },
        \\  {
        \\    "type": "number_literal",
        \\    "named": true
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
        \\    "type": "expr",
        \\    "named": true
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
        \\    "type": "rhs",
        \\    "named": true,
        \\    "fields": {},
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
        \\    "type": "expr",
        \\    "named": true
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

pub fn inlineFieldInheritanceGrammarJson() Fixture {
    return .{
        .name = "inline_field_inheritance",
        .contents =
        \\{
        \\  "name": "inline_field_inheritance",
        \\  "inline": ["_pair"],
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "SYMBOL",
        \\      "name": "_pair"
        \\    },
        \\    "_pair": {
        \\      "type": "FIELD",
        \\      "name": "body",
        \\      "content": {
        \\        "type": "SYMBOL",
        \\        "name": "item"
        \\      }
        \\    },
        \\    "item": {
        \\      "type": "STRING",
        \\      "value": "x"
        \\    }
        \\  }
        \\}
        ,
    };
}

pub fn nonTerminalExtraGrammarJson() Fixture {
    return .{
        .name = "non_terminal_extra",
        .contents =
        \\{
        \\  "name": "non_terminal_extra",
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "SEQ",
        \\      "members": [
        \\        { "type": "SYMBOL", "name": "item" },
        \\        { "type": "SYMBOL", "name": "item" }
        \\      ]
        \\    },
        \\    "item": {
        \\      "type": "STRING",
        \\      "value": "x"
        \\    },
        \\    "_gap": {
        \\      "type": "SEQ",
        \\      "members": [
        \\        { "type": "STRING", "value": "[" },
        \\        { "type": "STRING", "value": "]" }
        \\      ]
        \\    },
        \\    "gap_start": {
        \\      "type": "STRING",
        \\      "value": "["
        \\    },
        \\    "gap_end": {
        \\      "type": "STRING",
        \\      "value": "]"
        \\    }
        \\  },
        \\  "extras": [
        \\    { "type": "SYMBOL", "name": "_gap" }
        \\  ]
        \\}
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
        \\    "fields": {},
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

pub fn hiddenExternalFieldsExternalScannerDump() Fixture {
    return .{
        .name = "hidden_external_fields_external_scanner_dump",
        .contents =
        \\blocked false
        \\tokens 1
        \\token 0 index 0 indent named
        \\uses 1
        \\use 0 external 0 variable _with_indent production 0 step 0 field lead
        \\unsupported_features 0
        \\
        ,
    };
}

pub fn hiddenExternalFieldsValidInput() Fixture {
    return .{
        .name = "hidden_external_fields_valid_input",
        .contents = "  x",
    };
}

pub fn hiddenExternalFieldsInvalidInput() Fixture {
    return .{
        .name = "hidden_external_fields_invalid_input",
        .contents = "  y",
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
        \\    "type": "statement",
        \\    "named": true,
        \\    "fields": {},
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
        \\    "type": "space",
        \\    "named": true,
        \\    "extra": true
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
        \\    "fields": {},
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
        \\    "named": true
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

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
            \\    "type": "indent",
            \\    "named": true
            \\  },
            \\  {
            \\    "type": "source_file",
            \\    "named": true,
            \\    "root": true
            \\  },
            \\  {
            \\    "type": "term",
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
            \\  }
            \\]
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
            \\    "type": "+",
            \\    "named": false
            \\  },
            \\  {
            \\    "type": "expr",
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
            \\    },
            \\    "children": {
            \\      "multiple": true,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "+",
            \\          "named": false
            \\        },
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        },
            \\        {
            \\          "type": "rhs",
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
            \\    "type": "+",
            \\    "named": false
            \\  },
            \\  {
            \\    "type": "expr",
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
            \\    },
            \\    "children": {
            \\      "multiple": true,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "+",
            \\          "named": false
            \\        },
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        },
            \\        {
            \\          "type": "rhs",
            \\          "named": true
            \\        }
            \\      ]
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
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "identifier",
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
            \\    "type": "number_literal",
            \\    "named": true,
            \\    "children": {
            \\      "multiple": false,
            \\      "required": true,
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
            \\      "multiple": true,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "indent",
            \\          "named": true
            \\        },
            \\        {
            \\          "type": "statement",
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
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "space",
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
            \\      "required": true,
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
            \\      "required": true,
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
            \\    },
            \\    "children": {
            \\      "multiple": true,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        },
            \\        {
            \\          "type": "term",
            \\          "named": true
            \\        }
            \\      ]
            \\    }
            \\  },
            \\  {
            \\    "type": "term",
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
            \\    },
            \\    "children": {
            \\      "multiple": true,
            \\      "required": true,
            \\      "types": [
            \\        {
            \\          "type": "expr",
            \\          "named": true
            \\        },
            \\        {
            \\          "type": "rhs",
            \\          "named": true
            \\        }
            \\      ]
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

test "basic fixture is non-empty" {
    const fixture = basicGrammarJson();
    try std.testing.expect(fixture.contents.len > 0);
}

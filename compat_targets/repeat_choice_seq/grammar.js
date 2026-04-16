module.exports = {
  "name": "repeat_choice_seq",
  "rules": {
    "source_file": {
      "type": "REPEAT1",
      "content": { "type": "SYMBOL", "name": "_entry" }
    },
    "_entry": {
      "type": "CHOICE",
      "members": [
        {
          "type": "SEQ",
          "members": [
            { "type": "SYMBOL", "name": "identifier" },
            {
              "type": "REPEAT",
              "content": { "type": "SYMBOL", "name": "number_literal" }
            }
          ]
        },
        {
          "type": "SEQ",
          "members": [
            { "type": "SYMBOL", "name": "number_literal" },
            {
              "type": "REPEAT1",
              "content": { "type": "SYMBOL", "name": "identifier" }
            }
          ]
        }
      ]
    },
    "identifier": {
      "type": "TOKEN",
      "content": { "type": "PATTERN", "value": "[a-z]+" }
    },
    "number_literal": {
      "type": "STRING",
      "value": "42"
    }
  }
};

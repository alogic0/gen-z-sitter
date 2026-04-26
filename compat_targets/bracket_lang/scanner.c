#include <stdbool.h>
#include "parser.h"

enum TokenType {
  open_bracket = 0,
  close_bracket = 1,
};

void *tree_sitter_bracket_lang_external_scanner_create(void) { return 0; }

void tree_sitter_bracket_lang_external_scanner_destroy(void *payload) {
  (void)payload;
}

unsigned tree_sitter_bracket_lang_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}

void tree_sitter_bracket_lang_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

bool tree_sitter_bracket_lang_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  (void)payload;
  if (valid_symbols[open_bracket] && lexer->lookahead == '(') {
    lexer->result_symbol = open_bracket;
    lexer->advance(lexer, false);
    lexer->mark_end(lexer);
    return true;
  }
  if (valid_symbols[close_bracket] && lexer->lookahead == ')') {
    lexer->result_symbol = close_bracket;
    lexer->advance(lexer, false);
    lexer->mark_end(lexer);
    return true;
  }
  return false;
}

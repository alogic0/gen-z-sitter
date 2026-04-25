const std = @import("std");

/// ABI language version emitted into generated parser C.
pub const language_version: u16 = 15;

/// Minimum runtime ABI version accepted by the generated parser C.
pub const min_compatible_language_version: u16 = 13;

/// Header comment written at the top of generated parser C.
pub const generated_parser_comment = "/* generated parser.c */\n";

/// Header comment identifying the local runtime ABI layout.
pub const layout_comment = "/* tree-sitter runtime ABI layout */\n";

/// Runtime ABI version pair used by the generated C contract.
pub const RuntimeCompatibilityInfo = struct {
    language_version: u16,
    min_compatible_language_version: u16,
};

/// Return the ABI versions supported by this emitter.
pub fn currentRuntimeCompatibility() RuntimeCompatibilityInfo {
    return .{
        .language_version = language_version,
        .min_compatible_language_version = min_compatible_language_version,
    };
}

/// Write generated C includes and header comments.
pub fn writeContractPrelude(writer: anytype, info: RuntimeCompatibilityInfo) !void {
    _ = info;
    try writer.writeAll(generated_parser_comment);
    try writer.writeAll(layout_comment);
    try writer.writeAll("#include <stdbool.h>\n");
    try writer.writeAll("#include <stdint.h>\n");
    try writer.writeAll("#include <stdlib.h>\n\n");
}

/// Write the self-contained runtime ABI types and constants used by parser C.
pub fn writeContractTypesAndConstants(writer: anytype, info: RuntimeCompatibilityInfo) !void {
    try writer.print("#define LANGUAGE_VERSION {d}\n", .{info.language_version});
    try writer.print("#define MIN_COMPATIBLE_LANGUAGE_VERSION {d}\n\n", .{info.min_compatible_language_version});
    try writer.writeAll("typedef uint16_t TSStateId;\n");
    try writer.writeAll("typedef uint16_t TSSymbol;\n");
    try writer.writeAll("typedef uint16_t TSFieldId;\n\n");
    try writer.writeAll("typedef struct TSLanguage TSLanguage;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  uint8_t major_version;\n");
    try writer.writeAll("  uint8_t minor_version;\n");
    try writer.writeAll("  uint8_t patch_version;\n");
    try writer.writeAll("} TSLanguageMetadata;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  TSFieldId field_id;\n");
    try writer.writeAll("  uint8_t child_index;\n");
    try writer.writeAll("  bool inherited;\n");
    try writer.writeAll("} TSFieldMapEntry;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  uint16_t index;\n");
    try writer.writeAll("  uint16_t length;\n");
    try writer.writeAll("} TSMapSlice;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  bool visible;\n");
    try writer.writeAll("  bool named;\n");
    try writer.writeAll("  bool supertype;\n");
    try writer.writeAll("} TSSymbolMetadata;\n\n");
    try writer.writeAll("typedef struct TSLexer TSLexer;\n");
    try writer.writeAll("struct TSLexer {\n");
    try writer.writeAll("  int32_t lookahead;\n");
    try writer.writeAll("  TSSymbol result_symbol;\n");
    try writer.writeAll("  void (*advance)(TSLexer *, bool);\n");
    try writer.writeAll("  void (*mark_end)(TSLexer *);\n");
    try writer.writeAll("  uint32_t (*get_column)(TSLexer *);\n");
    try writer.writeAll("  bool (*is_at_included_range_start)(const TSLexer *);\n");
    try writer.writeAll("  bool (*eof)(const TSLexer *);\n");
    try writer.writeAll("  void (*log)(const TSLexer *, const char *, ...);\n");
    try writer.writeAll("};\n\n");
    try writer.writeAll("typedef enum {\n");
    try writer.writeAll("  TSParseActionTypeShift,\n");
    try writer.writeAll("  TSParseActionTypeReduce,\n");
    try writer.writeAll("  TSParseActionTypeAccept,\n");
    try writer.writeAll("  TSParseActionTypeRecover,\n");
    try writer.writeAll("} TSParseActionType;\n\n");
    try writer.writeAll("typedef union {\n");
    try writer.writeAll("  struct { uint8_t type; TSStateId state; bool extra; bool repetition; } shift;\n");
    try writer.writeAll("  struct { uint8_t type; uint8_t child_count; TSSymbol symbol; int16_t dynamic_precedence; uint16_t production_id; } reduce;\n");
    try writer.writeAll("  uint8_t type;\n");
    try writer.writeAll("} TSParseAction;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  uint16_t lex_state;\n");
    try writer.writeAll("  uint16_t external_lex_state;\n");
    try writer.writeAll("  uint16_t reserved_word_set_id;\n");
    try writer.writeAll("} TSLexerMode;\n\n");
    try writer.writeAll("typedef union {\n");
    try writer.writeAll("  TSParseAction action;\n");
    try writer.writeAll("  struct { uint8_t count; bool reusable; } entry;\n");
    try writer.writeAll("} TSParseActionEntry;\n\n");
    try writer.writeAll("struct TSLanguage {\n");
    try writer.writeAll("  uint32_t abi_version;\n");
    try writer.writeAll("  uint32_t symbol_count;\n");
    try writer.writeAll("  uint32_t alias_count;\n");
    try writer.writeAll("  uint32_t token_count;\n");
    try writer.writeAll("  uint32_t external_token_count;\n");
    try writer.writeAll("  uint32_t state_count;\n");
    try writer.writeAll("  uint32_t large_state_count;\n");
    try writer.writeAll("  uint32_t production_id_count;\n");
    try writer.writeAll("  uint32_t field_count;\n");
    try writer.writeAll("  uint16_t max_alias_sequence_length;\n");
    try writer.writeAll("  const uint16_t *parse_table;\n");
    try writer.writeAll("  const uint16_t *small_parse_table;\n");
    try writer.writeAll("  const uint32_t *small_parse_table_map;\n");
    try writer.writeAll("  const TSParseActionEntry *parse_actions;\n");
    try writer.writeAll("  const char * const *symbol_names;\n");
    try writer.writeAll("  const char * const *field_names;\n");
    try writer.writeAll("  const TSMapSlice *field_map_slices;\n");
    try writer.writeAll("  const TSFieldMapEntry *field_map_entries;\n");
    try writer.writeAll("  const TSSymbolMetadata *symbol_metadata;\n");
    try writer.writeAll("  const TSSymbol *public_symbol_map;\n");
    try writer.writeAll("  const uint16_t *alias_map;\n");
    try writer.writeAll("  const TSSymbol *alias_sequences;\n");
    try writer.writeAll("  const TSLexerMode *lex_modes;\n");
    try writer.writeAll("  bool (*lex_fn)(TSLexer *, TSStateId);\n");
    try writer.writeAll("  bool (*keyword_lex_fn)(TSLexer *, TSStateId);\n");
    try writer.writeAll("  TSSymbol keyword_capture_token;\n");
    try writer.writeAll("  struct {\n");
    try writer.writeAll("    const bool *states;\n");
    try writer.writeAll("    const TSSymbol *symbol_map;\n");
    try writer.writeAll("    void *(*create)(void);\n");
    try writer.writeAll("    void (*destroy)(void *);\n");
    try writer.writeAll("    bool (*scan)(void *, TSLexer *, const bool *symbol_whitelist);\n");
    try writer.writeAll("    unsigned (*serialize)(void *, char *);\n");
    try writer.writeAll("    void (*deserialize)(void *, const char *, unsigned);\n");
    try writer.writeAll("  } external_scanner;\n");
    try writer.writeAll("  const TSStateId *primary_state_ids;\n");
    try writer.writeAll("  const char *name;\n");
    try writer.writeAll("  const TSSymbol *reserved_words;\n");
    try writer.writeAll("  uint16_t max_reserved_word_set_size;\n");
    try writer.writeAll("  uint32_t supertype_count;\n");
    try writer.writeAll("  const TSSymbol *supertype_symbols;\n");
    try writer.writeAll("  const TSMapSlice *supertype_map_slices;\n");
    try writer.writeAll("  const TSSymbol *supertype_map_entries;\n");
    try writer.writeAll("  TSLanguageMetadata metadata;\n");
    try writer.writeAll("};\n\n");
    try writer.writeAll("#define SMALL_STATE(id) ((id) - LARGE_STATE_COUNT)\n");
    try writer.writeAll("#define STATE(id) id\n");
    try writer.writeAll("#define ACTIONS(id) id\n\n");
    try writeLexerMacros(writer);
}

/// Write the lexer helper macros used by generated `ts_lex` functions.
pub fn writeLexerMacros(writer: anytype) !void {
    try writer.writeAll("#ifdef _MSC_VER\n");
    try writer.writeAll("#define UNUSED __pragma(warning(suppress : 4101))\n");
    try writer.writeAll("#else\n");
    try writer.writeAll("#define UNUSED __attribute__((unused))\n");
    try writer.writeAll("#endif\n");
    try writer.writeAll("#define START_LEXER() \\\n");
    try writer.writeAll("  bool result = false; \\\n");
    try writer.writeAll("  bool skip = false; \\\n");
    try writer.writeAll("  UNUSED \\\n");
    try writer.writeAll("  bool eof = false; \\\n");
    try writer.writeAll("  int32_t lookahead; \\\n");
    try writer.writeAll("  lexer->result_symbol = 0; \\\n");
    try writer.writeAll("  goto start; \\\n");
    try writer.writeAll("  next_state: \\\n");
    try writer.writeAll("  lexer->advance(lexer, skip); \\\n");
    try writer.writeAll("  start: \\\n");
    try writer.writeAll("  skip = false; \\\n");
    try writer.writeAll("  lookahead = lexer->lookahead\n");
    try writer.writeAll("#define ADVANCE(state_value) \\\n");
    try writer.writeAll("  do { state = state_value; goto next_state; } while (0)\n");
    try writer.writeAll("#define ADVANCE_MAP(...) \\\n");
    try writer.writeAll("  do { \\\n");
    try writer.writeAll("    static const uint16_t map[] = { __VA_ARGS__ }; \\\n");
    try writer.writeAll("    for (uint32_t i = 0; i < sizeof(map) / sizeof(map[0]); i += 2) { \\\n");
    try writer.writeAll("      if (map[i] == lookahead) { \\\n");
    try writer.writeAll("        state = map[i + 1]; \\\n");
    try writer.writeAll("        goto next_state; \\\n");
    try writer.writeAll("      } \\\n");
    try writer.writeAll("    } \\\n");
    try writer.writeAll("  } while (0)\n");
    try writer.writeAll("#define SKIP(state_value) \\\n");
    try writer.writeAll("  do { skip = true; state = state_value; goto next_state; } while (0)\n");
    try writer.writeAll("#define ACCEPT_TOKEN(symbol_value) \\\n");
    try writer.writeAll("  do { result = true; lexer->result_symbol = symbol_value; lexer->mark_end(lexer); } while (0)\n");
    try writer.writeAll("#define END_STATE() return result\n\n");
}

test "current runtime compatibility exposes ABI versions" {
    const info = currentRuntimeCompatibility();

    try std.testing.expectEqual(@as(u16, 15), info.language_version);
    try std.testing.expectEqual(@as(u16, 13), info.min_compatible_language_version);
}

test "writeContractPrelude emits the centralized staged compatibility prelude" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try writeContractPrelude(&buffer.writer, currentRuntimeCompatibility());

    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), generated_parser_comment) != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "#include <stdint.h>") != null);
}

test "writeContractTypesAndConstants emits runtime ABI version constants only" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try writeContractTypesAndConstants(&buffer.writer, currentRuntimeCompatibility());

    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "#define LANGUAGE_VERSION 15") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "#define MIN_COMPATIBLE_LANGUAGE_VERSION 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "TSParseActionEntry") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "struct TSLanguage") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "#define START_LEXER()") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "#define ACCEPT_TOKEN(symbol_value)") != null);
}

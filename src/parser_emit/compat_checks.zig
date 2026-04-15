const std = @import("std");

pub const CompatibilityCheckError = error{
    MissingLanguageVersion,
    MissingMinimumCompatibleLanguageVersion,
    MissingSymbolCount,
    MissingSymbolKindConstants,
    MissingActionConstants,
    MissingUnresolvedConstants,
    MissingSymbolStruct,
    MissingSymbolAccessor,
    MissingSymbolNameAccessor,
    MissingSymbolIdAccessor,
    MissingSymbolKindAccessor,
    MissingLanguageStruct,
    MissingLanguageAccessor,
    MissingLanguageParserAccessor,
    MissingLanguageRuntimeAccessor,
    MissingLanguageCompatibilityAccessor,
    MissingCompatibilityTarget,
    MissingCompatibilityLayer,
    MissingCompatibilityStruct,
    MissingCompatibilityAccessor,
    MissingRuntimeAccessor,
    MissingRuntimeStateAccessor,
    MissingRuntimeUnresolvedAccessor,
};

pub fn validateParserCCompatibilitySurface(contents: []const u8) CompatibilityCheckError!void {
    try requireSubstring(contents, "#define TS_LANGUAGE_VERSION ", error.MissingLanguageVersion);
    try requireSubstring(contents, "#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION ", error.MissingMinimumCompatibleLanguageVersion);
    try requireSubstring(contents, "#define TS_SYMBOL_COUNT ", error.MissingSymbolCount);
    try requireSubstring(contents, "#define TS_SYMBOL_KIND_NON_TERMINAL ", error.MissingSymbolKindConstants);
    try requireSubstring(contents, "#define TS_ACTION_SHIFT ", error.MissingActionConstants);
    try requireSubstring(contents, "#define TS_UNRESOLVED_SHIFT_REDUCE ", error.MissingUnresolvedConstants);
    try requireSubstring(contents, "typedef struct {\n  uint16_t id;\n  const char *name;\n  uint16_t kind;\n  bool terminal;\n  bool external;\n} TSSymbolInfo;", error.MissingSymbolStruct);
    try requireSubstring(contents, "typedef struct {\n  uint16_t language_version;\n  uint16_t min_compatible_language_version;\n  const char *target;\n  const char *layer;\n} TSCompatibilityInfo;", error.MissingCompatibilityStruct);
    try requireSubstring(contents, "typedef struct {\n  const TSParser *parser;\n  const TSParserRuntime *runtime;\n  const TSCompatibilityInfo *compatibility;\n} TSLanguage;", error.MissingLanguageStruct);
    try requireSubstring(contents, "const TSSymbolInfo *ts_parser_symbol(uint16_t symbol_id)", error.MissingSymbolAccessor);
    try requireSubstring(contents, "const char *ts_parser_symbol_name(uint16_t symbol_id)", error.MissingSymbolNameAccessor);
    try requireSubstring(contents, "uint16_t ts_parser_symbol_id(uint16_t symbol_id)", error.MissingSymbolIdAccessor);
    try requireSubstring(contents, "uint16_t ts_parser_symbol_kind(uint16_t symbol_id)", error.MissingSymbolKindAccessor);
    try requireSubstring(contents, "const TSLanguage *ts_language_instance(void)", error.MissingLanguageAccessor);
    try requireSubstring(contents, "const TSParser *ts_language_parser(const TSLanguage *language)", error.MissingLanguageParserAccessor);
    try requireSubstring(contents, "const TSParserRuntime *ts_language_runtime(const TSLanguage *language)", error.MissingLanguageRuntimeAccessor);
    try requireSubstring(contents, "const TSCompatibilityInfo *ts_language_compatibility(const TSLanguage *language)", error.MissingLanguageCompatibilityAccessor);
    try requireSubstring(contents, "const TSCompatibilityInfo *ts_parser_compatibility(void)", error.MissingCompatibilityAccessor);
    try requireSubstring(contents, "const char *ts_parser_compatibility_target(void)", error.MissingCompatibilityTarget);
    try requireSubstring(contents, "const char *ts_parser_compatibility_layer(void)", error.MissingCompatibilityLayer);
    try requireSubstring(contents, "const TSParserRuntime *ts_parser_runtime(void)", error.MissingRuntimeAccessor);
    try requireSubstring(contents, "const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id)", error.MissingRuntimeStateAccessor);
    try requireSubstring(contents, "bool ts_parser_runtime_state_has_unresolved(uint16_t state_id)", error.MissingRuntimeUnresolvedAccessor);
}

fn requireSubstring(contents: []const u8, needle: []const u8, err: CompatibilityCheckError) CompatibilityCheckError!void {
    if (std.mem.indexOf(u8, contents, needle) == null) {
        return err;
    }
}

test "validateParserCCompatibilitySurface accepts a compatibility-oriented parser surface" {
    try validateParserCCompatibilitySurface(
        \\#define TS_LANGUAGE_VERSION 15
        \\#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION 13
        \\#define TS_SYMBOL_COUNT 2
        \\#define TS_SYMBOL_KIND_NON_TERMINAL 1
        \\#define TS_ACTION_SHIFT 1
        \\#define TS_UNRESOLVED_SHIFT_REDUCE 1
        \\typedef struct {
        \\  uint16_t id;
        \\  const char *name;
        \\  uint16_t kind;
        \\  bool terminal;
        \\  bool external;
        \\} TSSymbolInfo;
        \\typedef struct {
        \\  uint16_t language_version;
        \\  uint16_t min_compatible_language_version;
        \\  const char *target;
        \\  const char *layer;
        \\} TSCompatibilityInfo;
        \\typedef struct {
        \\  const TSParser *parser;
        \\  const TSParserRuntime *runtime;
        \\  const TSCompatibilityInfo *compatibility;
        \\} TSLanguage;
        \\const TSSymbolInfo *ts_parser_symbol(uint16_t symbol_id) { return 0; }
        \\const char *ts_parser_symbol_name(uint16_t symbol_id) { return 0; }
        \\uint16_t ts_parser_symbol_id(uint16_t symbol_id) { return symbol_id; }
        \\uint16_t ts_parser_symbol_kind(uint16_t symbol_id) { return symbol_id; }
        \\const TSLanguage *ts_language_instance(void) { return 0; }
        \\const TSParser *ts_language_parser(const TSLanguage *language) { return language ? language->parser : 0; }
        \\const TSParserRuntime *ts_language_runtime(const TSLanguage *language) { return language ? language->runtime : 0; }
        \\const TSCompatibilityInfo *ts_language_compatibility(const TSLanguage *language) { return language ? language->compatibility : 0; }
        \\const TSCompatibilityInfo *ts_parser_compatibility(void) { return 0; }
        \\const char *ts_parser_compatibility_target(void) { return 0; }
        \\const char *ts_parser_compatibility_layer(void) { return 0; }
        \\const TSParserRuntime *ts_parser_runtime(void) { return 0; }
        \\const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id) { return 0; }
        \\bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) { return state_id != 0; }
    );
}

test "validateParserCCompatibilitySurface rejects missing compatibility target accessors" {
    try std.testing.expectError(
        error.MissingCompatibilityTarget,
        validateParserCCompatibilitySurface(
            \\#define TS_LANGUAGE_VERSION 15
            \\#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION 13
            \\#define TS_SYMBOL_COUNT 2
            \\#define TS_SYMBOL_KIND_NON_TERMINAL 1
            \\#define TS_ACTION_SHIFT 1
            \\#define TS_UNRESOLVED_SHIFT_REDUCE 1
            \\typedef struct {
            \\  uint16_t id;
            \\  const char *name;
            \\  uint16_t kind;
            \\  bool terminal;
            \\  bool external;
            \\} TSSymbolInfo;
            \\typedef struct {
            \\  uint16_t language_version;
            \\  uint16_t min_compatible_language_version;
            \\  const char *target;
            \\  const char *layer;
            \\} TSCompatibilityInfo;
            \\typedef struct {
            \\  const TSParser *parser;
            \\  const TSParserRuntime *runtime;
            \\  const TSCompatibilityInfo *compatibility;
            \\} TSLanguage;
            \\const TSSymbolInfo *ts_parser_symbol(uint16_t symbol_id) { return 0; }
            \\const char *ts_parser_symbol_name(uint16_t symbol_id) { return 0; }
            \\uint16_t ts_parser_symbol_id(uint16_t symbol_id) { return symbol_id; }
            \\uint16_t ts_parser_symbol_kind(uint16_t symbol_id) { return symbol_id; }
            \\const TSLanguage *ts_language_instance(void) { return 0; }
            \\const TSParser *ts_language_parser(const TSLanguage *language) { return language ? language->parser : 0; }
            \\const TSParserRuntime *ts_language_runtime(const TSLanguage *language) { return language ? language->runtime : 0; }
            \\const TSCompatibilityInfo *ts_language_compatibility(const TSLanguage *language) { return language ? language->compatibility : 0; }
            \\const TSCompatibilityInfo *ts_parser_compatibility(void) { return 0; }
            \\const char *ts_parser_compatibility_layer(void) { return 0; }
            \\const TSParserRuntime *ts_parser_runtime(void) { return 0; }
            \\const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id) { return 0; }
            \\bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) { return state_id != 0; }
        ),
    );
}

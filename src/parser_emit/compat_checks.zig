const std = @import("std");

pub const CompatibilityCheckError = error{
    MissingLanguageVersion,
    MissingMinimumCompatibleLanguageVersion,
    MissingSymbolCount,
    MissingSymbolStruct,
    MissingSymbolAccessor,
    MissingSymbolNameAccessor,
    MissingLanguageStruct,
    MissingLanguageAccessor,
    MissingCompatibilityTarget,
    MissingCompatibilityLayer,
    MissingCompatibilityStruct,
    MissingCompatibilityAccessor,
    MissingRuntimeAccessor,
};

pub fn validateParserCCompatibilitySurface(contents: []const u8) CompatibilityCheckError!void {
    try requireSubstring(contents, "#define TS_LANGUAGE_VERSION ", error.MissingLanguageVersion);
    try requireSubstring(contents, "#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION ", error.MissingMinimumCompatibleLanguageVersion);
    try requireSubstring(contents, "#define TS_SYMBOL_COUNT ", error.MissingSymbolCount);
    try requireSubstring(contents, "typedef struct {\n  const char *name;\n  bool terminal;\n  bool external;\n} TSSymbolInfo;", error.MissingSymbolStruct);
    try requireSubstring(contents, "typedef struct {\n  uint16_t language_version;\n  uint16_t min_compatible_language_version;\n  const char *target;\n  const char *layer;\n} TSCompatibilityInfo;", error.MissingCompatibilityStruct);
    try requireSubstring(contents, "typedef struct {\n  const TSParser *parser;\n  const TSParserRuntime *runtime;\n  const TSCompatibilityInfo *compatibility;\n} TSLanguage;", error.MissingLanguageStruct);
    try requireSubstring(contents, "const TSSymbolInfo *ts_parser_symbol(uint16_t symbol_id)", error.MissingSymbolAccessor);
    try requireSubstring(contents, "const char *ts_parser_symbol_name(uint16_t symbol_id)", error.MissingSymbolNameAccessor);
    try requireSubstring(contents, "const TSLanguage *ts_language_instance(void)", error.MissingLanguageAccessor);
    try requireSubstring(contents, "const TSCompatibilityInfo *ts_parser_compatibility(void)", error.MissingCompatibilityAccessor);
    try requireSubstring(contents, "const char *ts_parser_compatibility_target(void)", error.MissingCompatibilityTarget);
    try requireSubstring(contents, "const char *ts_parser_compatibility_layer(void)", error.MissingCompatibilityLayer);
    try requireSubstring(contents, "const TSParserRuntime *ts_parser_runtime(void)", error.MissingRuntimeAccessor);
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
        \\typedef struct {
        \\  const char *name;
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
        \\const TSLanguage *ts_language_instance(void) { return 0; }
        \\const TSCompatibilityInfo *ts_parser_compatibility(void) { return 0; }
        \\const char *ts_parser_compatibility_target(void) { return 0; }
        \\const char *ts_parser_compatibility_layer(void) { return 0; }
        \\const TSParserRuntime *ts_parser_runtime(void) { return 0; }
    );
}

test "validateParserCCompatibilitySurface rejects missing compatibility target accessors" {
    try std.testing.expectError(
        error.MissingCompatibilityTarget,
        validateParserCCompatibilitySurface(
            \\#define TS_LANGUAGE_VERSION 15
            \\#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION 13
            \\#define TS_SYMBOL_COUNT 2
            \\typedef struct {
            \\  const char *name;
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
            \\const TSLanguage *ts_language_instance(void) { return 0; }
            \\const TSCompatibilityInfo *ts_parser_compatibility(void) { return 0; }
            \\const char *ts_parser_compatibility_layer(void) { return 0; }
            \\const TSParserRuntime *ts_parser_runtime(void) { return 0; }
        ),
    );
}

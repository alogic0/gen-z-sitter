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
    MissingRuntimeBlockedAccessor,
    MissingRuntimeHasUnresolvedAccessor,
    MissingRuntimeStateAccessor,
    MissingRuntimeUnresolvedAccessor,
    MissingParserStateAccessor,
    MissingActionListAccessor,
    MissingActionCountAccessor,
    MissingGotoListAccessor,
    MissingGotoCountAccessor,
    MissingUnresolvedListAccessor,
    MissingUnresolvedCountAccessor,
    MissingActionEntryAccessor,
    MissingGotoEntryAccessor,
    MissingUnresolvedEntryAccessor,
    MissingFindActionAccessor,
    MissingFindGotoAccessor,
    MissingFindUnresolvedAccessor,
    MissingHasActionAccessor,
    MissingHasGotoAccessor,
    MissingHasUnresolvedAccessor,
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
    try requireSubstring(contents, "bool ts_parser_runtime_is_blocked(void)", error.MissingRuntimeBlockedAccessor);
    try requireSubstring(contents, "bool ts_parser_runtime_has_unresolved_states(void)", error.MissingRuntimeHasUnresolvedAccessor);
    try requireSubstring(contents, "const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id)", error.MissingRuntimeStateAccessor);
    try requireSubstring(contents, "bool ts_parser_runtime_state_has_unresolved(uint16_t state_id)", error.MissingRuntimeUnresolvedAccessor);
    try requireSubstring(contents, "const TSStateTable *ts_parser_state(uint16_t state_id)", error.MissingParserStateAccessor);
    try requireSubstring(contents, "const TSActionEntry *ts_parser_actions(uint16_t state_id)", error.MissingActionListAccessor);
    try requireSubstring(contents, "uint16_t ts_parser_action_count(uint16_t state_id)", error.MissingActionCountAccessor);
    try requireSubstring(contents, "const TSGotoEntry *ts_parser_gotos(uint16_t state_id)", error.MissingGotoListAccessor);
    try requireSubstring(contents, "uint16_t ts_parser_goto_count(uint16_t state_id)", error.MissingGotoCountAccessor);
    try requireSubstring(contents, "const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id)", error.MissingUnresolvedListAccessor);
    try requireSubstring(contents, "uint16_t ts_parser_unresolved_count(uint16_t state_id)", error.MissingUnresolvedCountAccessor);
    try requireSubstring(contents, "const TSActionEntry *ts_parser_action_at(uint16_t state_id, uint16_t index)", error.MissingActionEntryAccessor);
    try requireSubstring(contents, "const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index)", error.MissingGotoEntryAccessor);
    try requireSubstring(contents, "const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index)", error.MissingUnresolvedEntryAccessor);
    try requireSubstring(contents, "const TSActionEntry *ts_parser_find_action(uint16_t state_id, const char *symbol)", error.MissingFindActionAccessor);
    try requireSubstring(contents, "const TSGotoEntry *ts_parser_find_goto(uint16_t state_id, const char *symbol)", error.MissingFindGotoAccessor);
    try requireSubstring(contents, "const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol)", error.MissingFindUnresolvedAccessor);
    try requireSubstring(contents, "bool ts_parser_has_action(uint16_t state_id, const char *symbol)", error.MissingHasActionAccessor);
    try requireSubstring(contents, "bool ts_parser_has_goto(uint16_t state_id, const char *symbol)", error.MissingHasGotoAccessor);
    try requireSubstring(contents, "bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol)", error.MissingHasUnresolvedAccessor);
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
        \\bool ts_parser_runtime_is_blocked(void) { return false; }
        \\bool ts_parser_runtime_has_unresolved_states(void) { return false; }
        \\const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id) { return 0; }
        \\bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) { return state_id != 0; }
        \\const TSStateTable *ts_parser_state(uint16_t state_id) { return 0; }
        \\const TSActionEntry *ts_parser_actions(uint16_t state_id) { return 0; }
        \\uint16_t ts_parser_action_count(uint16_t state_id) { return state_id; }
        \\const TSGotoEntry *ts_parser_gotos(uint16_t state_id) { return 0; }
        \\uint16_t ts_parser_goto_count(uint16_t state_id) { return state_id; }
        \\const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id) { return 0; }
        \\uint16_t ts_parser_unresolved_count(uint16_t state_id) { return state_id; }
        \\const TSActionEntry *ts_parser_action_at(uint16_t state_id, uint16_t index) { _ = index; return ts_parser_actions(state_id); }
        \\const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index) { _ = index; return ts_parser_gotos(state_id); }
        \\const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) { _ = index; return ts_parser_unresolved(state_id); }
        \\const TSActionEntry *ts_parser_find_action(uint16_t state_id, const char *symbol) { _ = symbol; return ts_parser_actions(state_id); }
        \\const TSGotoEntry *ts_parser_find_goto(uint16_t state_id, const char *symbol) { _ = symbol; return ts_parser_gotos(state_id); }
        \\const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol) { _ = symbol; return ts_parser_unresolved(state_id); }
        \\bool ts_parser_has_action(uint16_t state_id, const char *symbol) { return ts_parser_find_action(state_id, symbol) != 0; }
        \\bool ts_parser_has_goto(uint16_t state_id, const char *symbol) { return ts_parser_find_goto(state_id, symbol) != 0; }
        \\bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol) { return ts_parser_find_unresolved(state_id, symbol) != 0; }
    );
}

test "validateParserCCompatibilitySurface rejects missing parser state accessors" {
    try std.testing.expectError(
        error.MissingParserStateAccessor,
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
            \\const char *ts_parser_compatibility_target(void) { return 0; }
            \\const char *ts_parser_compatibility_layer(void) { return 0; }
            \\const TSParserRuntime *ts_parser_runtime(void) { return 0; }
            \\bool ts_parser_runtime_is_blocked(void) { return false; }
            \\bool ts_parser_runtime_has_unresolved_states(void) { return false; }
            \\const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id) { return 0; }
            \\bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) { return state_id != 0; }
            \\const TSActionEntry *ts_parser_actions(uint16_t state_id) { return 0; }
            \\uint16_t ts_parser_action_count(uint16_t state_id) { return state_id; }
            \\const TSGotoEntry *ts_parser_gotos(uint16_t state_id) { return 0; }
            \\uint16_t ts_parser_goto_count(uint16_t state_id) { return state_id; }
            \\const TSUnresolvedEntry *ts_parser_unresolved(uint16_t state_id) { return 0; }
            \\uint16_t ts_parser_unresolved_count(uint16_t state_id) { return state_id; }
            \\const TSActionEntry *ts_parser_action_at(uint16_t state_id, uint16_t index) { _ = index; return ts_parser_actions(state_id); }
            \\const TSGotoEntry *ts_parser_goto_at(uint16_t state_id, uint16_t index) { _ = index; return ts_parser_gotos(state_id); }
            \\const TSUnresolvedEntry *ts_parser_unresolved_at(uint16_t state_id, uint16_t index) { _ = index; return ts_parser_unresolved(state_id); }
            \\const TSActionEntry *ts_parser_find_action(uint16_t state_id, const char *symbol) { _ = symbol; return ts_parser_actions(state_id); }
            \\const TSGotoEntry *ts_parser_find_goto(uint16_t state_id, const char *symbol) { _ = symbol; return ts_parser_gotos(state_id); }
            \\const TSUnresolvedEntry *ts_parser_find_unresolved(uint16_t state_id, const char *symbol) { _ = symbol; return ts_parser_unresolved(state_id); }
            \\bool ts_parser_has_action(uint16_t state_id, const char *symbol) { return ts_parser_find_action(state_id, symbol) != 0; }
            \\bool ts_parser_has_goto(uint16_t state_id, const char *symbol) { return ts_parser_find_goto(state_id, symbol) != 0; }
            \\bool ts_parser_has_unresolved(uint16_t state_id, const char *symbol) { return ts_parser_find_unresolved(state_id, symbol) != 0; }
        ),
    );
}

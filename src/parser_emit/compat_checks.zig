const std = @import("std");

pub const CompatibilityCheckError = error{
    MissingLanguageVersion,
    MissingMinimumCompatibleLanguageVersion,
    MissingCompatibilityTarget,
    MissingCompatibilityLayer,
    MissingCompatibilityStruct,
    MissingCompatibilityAccessor,
    MissingRuntimeAccessor,
};

pub fn validateParserCCompatibilitySurface(contents: []const u8) CompatibilityCheckError!void {
    try requireSubstring(contents, "#define TS_LANGUAGE_VERSION ", error.MissingLanguageVersion);
    try requireSubstring(contents, "#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION ", error.MissingMinimumCompatibleLanguageVersion);
    try requireSubstring(contents, "typedef struct {\n  uint16_t language_version;\n  uint16_t min_compatible_language_version;\n  const char *target;\n  const char *layer;\n} TSCompatibilityInfo;", error.MissingCompatibilityStruct);
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
        \\typedef struct {
        \\  uint16_t language_version;
        \\  uint16_t min_compatible_language_version;
        \\  const char *target;
        \\  const char *layer;
        \\} TSCompatibilityInfo;
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
            \\typedef struct {
            \\  uint16_t language_version;
            \\  uint16_t min_compatible_language_version;
            \\  const char *target;
            \\  const char *layer;
            \\} TSCompatibilityInfo;
            \\const TSCompatibilityInfo *ts_parser_compatibility(void) { return 0; }
            \\const char *ts_parser_compatibility_layer(void) { return 0; }
            \\const TSParserRuntime *ts_parser_runtime(void) { return 0; }
        ),
    );
}

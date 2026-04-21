const std = @import("std");

pub const CompatibilityTarget = enum {
    tree_sitter_runtime_surface,
};

pub const CompatibilityLayer = enum {
    intermediate,
};

pub const language_version: u16 = 15;
pub const min_compatible_language_version: u16 = 13;
pub const symbol_kind_non_terminal: u16 = 1;
pub const symbol_kind_terminal: u16 = 2;
pub const symbol_kind_external: u16 = 3;
pub const action_shift: u16 = 1;
pub const action_reduce: u16 = 2;
pub const action_accept: u16 = 3;
pub const unresolved_shift_reduce: u16 = 1;
pub const unresolved_reduce_reduce_deferred: u16 = 2;

pub const generated_parser_comment = "/* generated parser.c skeleton */\n";
pub const layout_comment = "/* top-level layout: ts_language -> parser/runtime/compatibility */\n";

pub fn targetName(target: CompatibilityTarget) []const u8 {
    return switch (target) {
        .tree_sitter_runtime_surface => "tree-sitter-runtime-surface",
    };
}

pub fn layerName(layer: CompatibilityLayer) []const u8 {
    return switch (layer) {
        .intermediate => "intermediate",
    };
}

pub const RuntimeCompatibilityInfo = struct {
    target: CompatibilityTarget,
    layer: CompatibilityLayer,
    language_version: u16,
    min_compatible_language_version: u16,
};

pub fn currentRuntimeCompatibility() RuntimeCompatibilityInfo {
    return .{
        .target = .tree_sitter_runtime_surface,
        .layer = .intermediate,
        .language_version = language_version,
        .min_compatible_language_version = min_compatible_language_version,
    };
}

pub fn writeContractPrelude(writer: anytype, info: RuntimeCompatibilityInfo) !void {
    _ = info;
    try writer.writeAll(generated_parser_comment);
    try writer.writeAll(layout_comment);
    try writer.writeAll("#include <stdbool.h>\n");
    try writer.writeAll("#include <stdint.h>\n\n");
}

pub fn writeContractTypesAndConstants(writer: anytype, info: RuntimeCompatibilityInfo) !void {
    try writer.print("#define TS_LANGUAGE_VERSION {d}\n", .{info.language_version});
    try writer.print("#define TS_MIN_COMPATIBLE_LANGUAGE_VERSION {d}\n", .{info.min_compatible_language_version});
    try writer.print("#define TS_SYMBOL_KIND_NON_TERMINAL {d}\n", .{symbol_kind_non_terminal});
    try writer.print("#define TS_SYMBOL_KIND_TERMINAL {d}\n", .{symbol_kind_terminal});
    try writer.print("#define TS_SYMBOL_KIND_EXTERNAL {d}\n", .{symbol_kind_external});
    try writer.print("#define TS_ACTION_SHIFT {d}\n", .{action_shift});
    try writer.print("#define TS_ACTION_REDUCE {d}\n", .{action_reduce});
    try writer.print("#define TS_ACTION_ACCEPT {d}\n", .{action_accept});
    try writer.print("#define TS_UNRESOLVED_SHIFT_REDUCE {d}\n", .{unresolved_shift_reduce});
    try writer.print("#define TS_UNRESOLVED_REDUCE_REDUCE_DEFERRED {d}\n\n", .{unresolved_reduce_reduce_deferred});
    try writer.writeAll("typedef struct { uint16_t symbol_id; uint16_t kind; uint16_t value; } TSActionEntry;\n");
    try writer.writeAll("typedef struct { uint16_t symbol_id; uint16_t state; } TSGotoEntry;\n");
    try writer.writeAll("typedef struct { uint16_t symbol_id; uint16_t reason; uint16_t candidates; } TSUnresolvedEntry;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  uint16_t id;\n");
    try writer.writeAll("  const char *name;\n");
    try writer.writeAll("  uint16_t kind;\n");
    try writer.writeAll("  bool terminal;\n");
    try writer.writeAll("  bool external;\n");
    try writer.writeAll("} TSSymbolInfo;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  uint16_t language_version;\n");
    try writer.writeAll("  uint16_t min_compatible_language_version;\n");
    try writer.writeAll("  const char *target;\n");
    try writer.writeAll("  const char *layer;\n");
    try writer.writeAll("} TSCompatibilityInfo;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  const TSActionEntry *actions;\n");
    try writer.writeAll("  uint16_t action_count;\n");
    try writer.writeAll("  const TSGotoEntry *gotos;\n");
    try writer.writeAll("  uint16_t goto_count;\n");
    try writer.writeAll("  const TSUnresolvedEntry *unresolved;\n");
    try writer.writeAll("  uint16_t unresolved_count;\n");
    try writer.writeAll("} TSStateTable;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  bool blocked;\n");
    try writer.writeAll("  uint16_t symbol_count;\n");
    try writer.writeAll("  uint16_t state_count;\n");
    try writer.writeAll("  const TSSymbolInfo *symbols;\n");
    try writer.writeAll("  const TSStateTable *states;\n");
    try writer.writeAll("  const TSCompatibilityInfo *compatibility;\n");
    try writer.writeAll("} TSParser;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  uint16_t action_count;\n");
    try writer.writeAll("  uint16_t goto_count;\n");
    try writer.writeAll("  uint16_t unresolved_count;\n");
    try writer.writeAll("  bool has_unresolved;\n");
    try writer.writeAll("} TSRuntimeStateInfo;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  bool blocked;\n");
    try writer.writeAll("  bool has_unresolved_states;\n");
    try writer.writeAll("  uint16_t state_count;\n");
    try writer.writeAll("  const TSParser *parser;\n");
    try writer.writeAll("  const TSRuntimeStateInfo *states;\n");
    try writer.writeAll("} TSParserRuntime;\n\n");
    try writer.writeAll("typedef struct {\n");
    try writer.writeAll("  const TSParser *parser;\n");
    try writer.writeAll("  const TSParserRuntime *runtime;\n");
    try writer.writeAll("  const TSCompatibilityInfo *compatibility;\n");
    try writer.writeAll("} TSLanguage;\n\n");
}

pub fn writeContractAccessors(writer: anytype) !void {
    try writer.writeAll("const TSLanguage *ts_language_instance(void) {\n");
    try writer.writeAll("  return &ts_language;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSParser *ts_language_parser(const TSLanguage *language) {\n");
    try writer.writeAll("  return language ? language->parser : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSParserRuntime *ts_language_runtime(const TSLanguage *language) {\n");
    try writer.writeAll("  return language ? language->runtime : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSCompatibilityInfo *ts_language_compatibility(const TSLanguage *language) {\n");
    try writer.writeAll("  return language ? language->compatibility : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSParser *ts_parser_instance(void) {\n");
    try writer.writeAll("  return ts_language_parser(ts_language_instance());\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSCompatibilityInfo *ts_parser_compatibility(void) {\n");
    try writer.writeAll("  return ts_language_compatibility(ts_language_instance());\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_language_version(void) {\n");
    try writer.writeAll("  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();\n");
    try writer.writeAll("  return compatibility ? compatibility->language_version : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_min_compatible_language_version(void) {\n");
    try writer.writeAll("  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();\n");
    try writer.writeAll("  return compatibility ? compatibility->min_compatible_language_version : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const char *ts_parser_compatibility_target(void) {\n");
    try writer.writeAll("  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();\n");
    try writer.writeAll("  return compatibility ? compatibility->target : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const char *ts_parser_compatibility_layer(void) {\n");
    try writer.writeAll("  const TSCompatibilityInfo *compatibility = ts_parser_compatibility();\n");
    try writer.writeAll("  return compatibility ? compatibility->layer : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSParserRuntime *ts_parser_runtime(void) {\n");
    try writer.writeAll("  return ts_language_runtime(ts_language_instance());\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_runtime_is_blocked(void) {\n");
    try writer.writeAll("  const TSParserRuntime *runtime = ts_parser_runtime();\n");
    try writer.writeAll("  return runtime ? runtime->blocked : false;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_runtime_has_unresolved_states(void) {\n");
    try writer.writeAll("  const TSParserRuntime *runtime = ts_parser_runtime();\n");
    try writer.writeAll("  return runtime ? runtime->has_unresolved_states : false;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSRuntimeStateInfo *ts_parser_runtime_state(uint16_t state_id) {\n");
    try writer.writeAll("  const TSParserRuntime *runtime = ts_parser_runtime();\n");
    try writer.writeAll("  return runtime && state_id < runtime->state_count ? &runtime->states[state_id] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_runtime_state_has_unresolved(uint16_t state_id) {\n");
    try writer.writeAll("  const TSRuntimeStateInfo *state = ts_parser_runtime_state(state_id);\n");
    try writer.writeAll("  return state ? state->has_unresolved : false;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSStateTable *ts_parser_state(uint16_t state_id) {\n");
    try writer.writeAll("  const TSParser *parser = ts_parser_instance();\n");
    try writer.writeAll("  return parser && state_id < parser->state_count ? &parser->states[state_id] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_is_blocked(void) {\n");
    try writer.writeAll("  const TSParser *parser = ts_parser_instance();\n");
    try writer.writeAll("  return parser ? parser->blocked : false;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_symbol_count(void) {\n");
    try writer.writeAll("  const TSParser *parser = ts_parser_instance();\n");
    try writer.writeAll("  return parser ? parser->symbol_count : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_state_count(void) {\n");
    try writer.writeAll("  const TSParser *parser = ts_parser_instance();\n");
    try writer.writeAll("  return parser ? parser->state_count : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const TSSymbolInfo *ts_parser_symbol(uint16_t symbol_id) {\n");
    try writer.writeAll("  const TSParser *parser = ts_parser_instance();\n");
    try writer.writeAll("  return parser && symbol_id < parser->symbol_count ? &parser->symbols[symbol_id] : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("const char *ts_parser_symbol_name(uint16_t symbol_id) {\n");
    try writer.writeAll("  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);\n");
    try writer.writeAll("  return symbol ? symbol->name : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_symbol_id(uint16_t symbol_id) {\n");
    try writer.writeAll("  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);\n");
    try writer.writeAll("  return symbol ? symbol->id : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("uint16_t ts_parser_symbol_kind(uint16_t symbol_id) {\n");
    try writer.writeAll("  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);\n");
    try writer.writeAll("  return symbol ? symbol->kind : 0;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_symbol_is_terminal(uint16_t symbol_id) {\n");
    try writer.writeAll("  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);\n");
    try writer.writeAll("  return symbol ? symbol->terminal : false;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
    try writer.writeAll("bool ts_parser_symbol_is_external(uint16_t symbol_id) {\n");
    try writer.writeAll("  const TSSymbolInfo *symbol = ts_parser_symbol(symbol_id);\n");
    try writer.writeAll("  return symbol ? symbol->external : false;\n");
    try writer.writeAll("}\n");
    try writer.writeAll("\n");
}

test "current runtime compatibility exposes the Milestone 15 target" {
    const info = currentRuntimeCompatibility();

    try std.testing.expectEqual(CompatibilityTarget.tree_sitter_runtime_surface, info.target);
    try std.testing.expectEqual(CompatibilityLayer.intermediate, info.layer);
    try std.testing.expectEqual(@as(u16, 15), info.language_version);
    try std.testing.expectEqual(@as(u16, 13), info.min_compatible_language_version);
    try std.testing.expectEqualStrings("tree-sitter-runtime-surface", targetName(info.target));
    try std.testing.expectEqualStrings("intermediate", layerName(info.layer));
}

test "writeContractPrelude emits the centralized staged compatibility prelude" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try writeContractPrelude(&buffer.writer, currentRuntimeCompatibility());

    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), generated_parser_comment) != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "#include <stdint.h>") != null);
}

test "writeContractTypesAndConstants emits the centralized staged compatibility types and constants" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try writeContractTypesAndConstants(&buffer.writer, currentRuntimeCompatibility());

    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "#define TS_LANGUAGE_VERSION 15") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "#define TS_SYMBOL_KIND_EXTERNAL 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "} TSCompatibilityInfo;") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "} TSLanguage;") != null);
}

test "writeContractAccessors emits the centralized staged compatibility accessors" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try writeContractAccessors(&buffer.writer);

    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "const TSLanguage *ts_language_instance(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "const TSCompatibilityInfo *ts_parser_compatibility(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "const TSParserRuntime *ts_parser_runtime(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.writer.buffered(), "uint16_t ts_parser_symbol_kind(uint16_t symbol_id)") != null);
}

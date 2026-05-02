const std = @import("std");
const actions = @import("actions.zig");
const build = @import("build.zig");
const first = @import("first.zig");
const item = @import("item.zig");
const resolution = @import("resolution.zig");
const state = @import("state.zig");
const grammar_ir = @import("../ir/grammar_ir.zig");
const ir_rules = @import("../ir/rules.zig");
const ir_symbols = @import("../ir/symbols.zig");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const lexer_model = @import("../lexer/model.zig");
const lexer_serialize = @import("../lexer/serialize.zig");
const alias_ir = @import("../ir/aliases.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const runtime_io = @import("../support/runtime_io.zig");

/// Errors produced while converting the parse-table builder output into the
/// runtime-oriented serialized model.
pub const SerializeError = std.mem.Allocator.Error || error{
    ParseActionListTooLarge,
    UnresolvedDecisions,
};

pub const ParseActionListError = std.mem.Allocator.Error || error{
    ParseActionListTooLarge,
};

threadlocal var serialize_env_flags_loaded: bool = false;
threadlocal var serialize_profile_enabled: bool = false;

fn envFlagEnabledRaw(name: []const u8) bool {
    const value = std.process.Environ.getAlloc(runtime_io.environ(), std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

fn shouldProfileSerialize() bool {
    if (!serialize_env_flags_loaded) {
        serialize_profile_enabled = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_PROFILE");
        serialize_env_flags_loaded = true;
    }
    return serialize_profile_enabled;
}

/// Controls whether unresolved parse decisions block serialization.
pub const SerializeMode = enum {
    strict,
    diagnostic,
};

/// A terminal or external-symbol action attached to one serialized state.
pub const SerializedActionEntry = struct {
    symbol: syntax_ir.SymbolRef,
    action: actions.ParseAction,
    candidate_actions: []const actions.ParseAction = &.{},
    extra: bool = false,
    repetition: bool = false,
    recover: bool = false,
    reusable: bool = true,
};

/// A non-terminal transition attached to one serialized state.
pub const SerializedGotoEntry = struct {
    symbol: syntax_ir.SymbolRef,
    state: state.StateId,
};

/// A parse decision that could not be resolved but is preserved for diagnostics.
pub const SerializedUnresolvedEntry = struct {
    symbol: syntax_ir.SymbolRef,
    reason: resolution.UnresolvedReason,
    candidate_actions: []const actions.ParseAction,
};

/// One parser state after build-time decisions have been applied.
pub const SerializedState = struct {
    id: state.StateId,
    core_id: u32 = 0,
    lex_state_id: state.LexStateId = 0,
    actions: []const SerializedActionEntry,
    gotos: []const SerializedGotoEntry,
    unresolved: []const SerializedUnresolvedEntry,
};

/// Alias metadata keyed by production and child position.
pub const SerializedAliasEntry = struct {
    production_id: u32,
    step_index: u32,
    original_symbol: syntax_ir.SymbolRef = .{ .terminal = 0 },
    name: []const u8,
    named: bool,
};

/// Runtime production metadata used by reduce actions and field maps.
pub const SerializedProductionInfo = struct {
    lhs: u32,
    child_count: u8,
    dynamic_precedence: i16,
    production_info_id: ?u16 = null,
};

/// Runtime parse-action tag used by the generated C table.
pub const SerializedParseActionKind = enum {
    shift,
    reduce,
    accept,
    recover,
};

/// Runtime parse action payload, matching the generated ABI model.
pub const SerializedParseAction = struct {
    kind: SerializedParseActionKind,
    state: state.StateId = 0,
    extra: bool = false,
    repetition: bool = false,
    child_count: u8 = 0,
    symbol: syntax_ir.SymbolRef = .{ .terminal = 0 },
    dynamic_precedence: i16 = 0,
    production_id: u16 = 0,
};

const SerializedParseActionContext = struct {
    pub fn hash(_: @This(), value: SerializedParseAction) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashSerializedParseAction(&hasher, value);
        return hasher.final();
    }

    pub fn eql(_: @This(), left: SerializedParseAction, right: SerializedParseAction) bool {
        return serializedParseActionEql(left, right);
    }
};

fn hashSerializedParseAction(hasher: *std.hash.Wyhash, value: SerializedParseAction) void {
    const kind: u8 = @intFromEnum(value.kind);
    hasher.update(std.mem.asBytes(&kind));
    switch (value.kind) {
        .shift => {
            hasher.update(std.mem.asBytes(&value.state));
            hasher.update(std.mem.asBytes(&value.extra));
            hasher.update(std.mem.asBytes(&value.repetition));
        },
        .reduce => {
            hasher.update(std.mem.asBytes(&value.child_count));
            hashSymbolRef(hasher, value.symbol);
            hasher.update(std.mem.asBytes(&value.dynamic_precedence));
            hasher.update(std.mem.asBytes(&value.production_id));
        },
        .accept, .recover => {},
    }
}

const ParseActionListIndexMap = std.HashMap(
    SerializedParseAction,
    u16,
    SerializedParseActionContext,
    std.hash_map.default_max_load_percentage,
);

const ParseActionListSliceKey = struct {
    reusable: bool,
    actions: []const SerializedParseAction,
};

const ParseActionListSliceContext = struct {
    pub fn hash(_: @This(), value: ParseActionListSliceKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&value.reusable));
        for (value.actions) |action| hashSerializedParseAction(&hasher, action);
        return hasher.final();
    }

    pub fn eql(_: @This(), left: ParseActionListSliceKey, right: ParseActionListSliceKey) bool {
        if (left.reusable != right.reusable) return false;
        return serializedParseActionSlicesEql(left.actions, right.actions);
    }
};

const ParseActionListSliceIndexMap = std.HashMap(
    ParseActionListSliceKey,
    u16,
    ParseActionListSliceContext,
    std.hash_map.default_max_load_percentage,
);

/// One deduplicated runtime parse-action list entry.
pub const SerializedParseActionListEntry = struct {
    index: u16,
    reusable: bool,
    actions: []const SerializedParseAction,
};

/// Identifies whether a small parse-table group stores a goto or action value.
pub const SerializedSmallParseValueKind = enum {
    state,
    action,
};

/// Symbols that share the same small parse-table value.
pub const SerializedSmallParseGroup = struct {
    kind: SerializedSmallParseValueKind,
    value: u16,
    symbols: []const syntax_ir.SymbolRef,
};

/// One unique packed small parse-table row.
pub const SerializedSmallParseRow = struct {
    offset: u32,
    groups: []const SerializedSmallParseGroup,
};

/// Deduplicated small parse-table rows plus state-to-row offsets.
pub const SerializedSmallParseTable = struct {
    rows: []const SerializedSmallParseRow = &.{},
    map: []const u32 = &.{},
};

/// Symbol metadata needed by the generated runtime language object.
pub const SerializedSymbolInfo = struct {
    ref: syntax_ir.SymbolRef,
    name: []const u8,
    named: bool,
    visible: bool,
    supertype: bool,
    public_symbol: u16,
};

/// Runtime field name entry. Field id zero is reserved for the empty field.
pub const SerializedFieldName = struct {
    id: u16,
    name: []const u8,
};

/// Field metadata for one production child.
pub const SerializedFieldMapEntry = struct {
    field_id: u16,
    child_index: u8,
    inherited: bool,
};

/// Slice into the field-map entry table for one production.
pub const SerializedFieldMapSlice = struct {
    index: u16,
    length: u16,
};

/// Serialized runtime field map tables.
pub const SerializedFieldMap = struct {
    names: []const SerializedFieldName = &.{},
    entries: []const SerializedFieldMapEntry = &.{},
    slices: []const SerializedFieldMapSlice = &.{},
};

const FieldVisitState = enum { pending, visiting, done };

/// One runtime supertype-map entry before final C symbol-id resolution.
pub const SerializedSupertypeMapEntry = struct {
    symbol: syntax_ir.SymbolRef,
    alias_name: ?[]const u8 = null,
    alias_named: bool = false,
};

/// Slice into the supertype-map entry table for one supertype.
pub const SerializedSupertypeMapSlice = struct {
    supertype: syntax_ir.SymbolRef,
    index: u16,
    length: u16,
};

/// Serialized runtime supertype map tables.
pub const SerializedSupertypeMap = struct {
    symbols: []const syntax_ir.SymbolRef = &.{},
    entries: []const SerializedSupertypeMapEntry = &.{},
    slices: []const SerializedSupertypeMapSlice = &.{},
};

/// Serialized reserved-word table. Set zero is the empty/default set.
pub const SerializedReservedWords = struct {
    sets: []const []const syntax_ir.SymbolRef = &.{},
    max_size: u16 = 0,
};

/// Serialized external scanner symbol/state tables. Symbol order is scanner-local.
pub const SerializedExternalScanner = struct {
    symbols: []const syntax_ir.SymbolRef = &.{},
    states: []const []const bool = &.{},
};

/// Complete parse table model consumed by emitters.
pub const SerializedTable = struct {
    states: []const SerializedState,
    blocked: bool,
    grammar_name: []const u8 = "generated",
    grammar_version: [3]u8 = .{ 0, 0, 0 },
    symbols: []const SerializedSymbolInfo = &.{},
    large_state_count: usize = 0,
    production_id_count: usize = 0,
    productions: []const SerializedProductionInfo = &.{},
    parse_action_list: []const SerializedParseActionListEntry = &.{},
    small_parse_table: SerializedSmallParseTable = .{},
    alias_sequences: []const SerializedAliasEntry = &.{},
    non_terminal_aliases: []const SerializedAliasEntry = &.{},
    field_map: SerializedFieldMap = .{},
    supertype_map: SerializedSupertypeMap = .{},
    lex_modes: []const lexer_serialize.SerializedLexMode = &.{},
    lex_state_terminal_sets: []const []const bool = &.{},
    lex_tables: []const lexer_serialize.SerializedLexTable = &.{},
    keyword_lex_table: ?lexer_serialize.SerializedLexTable = null,
    keyword_unmapped_reserved_word_count: usize = 0,
    primary_state_ids: []const state.StateId = &.{},
    word_token: ?syntax_ir.SymbolRef = null,
    reserved_words: SerializedReservedWords = .{},
    external_scanner: SerializedExternalScanner = .{},

    pub fn isSerializationReady(self: SerializedTable) bool {
        return !self.blocked;
    }
};

pub fn serializeBuildResult(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    mode: SerializeMode,
) SerializeError!SerializedTable {
    return try serializeBuildResultWithOptions(allocator, result, mode, .{});
}

pub const BuildResultSerializeOptions = struct {
    include_unresolved_parse_actions: bool = true,
};

pub const ParseActionTableOptions = struct {
    include_unresolved_parse_actions: bool = true,
};

const ProductionSerialization = struct {
    productions: []const SerializedProductionInfo,
    production_id_count: usize,
    alias_sequences: []const SerializedAliasEntry,
    non_terminal_aliases: []const SerializedAliasEntry,
    field_map: SerializedFieldMap,
};

const ProductionMetadata = struct {
    aliases: []const SerializedAliasEntry,
    fields: []const SerializedFieldMapEntry,
};

const FieldMapRow = struct {
    index: u16,
    fields: []const SerializedFieldMapEntry,
};

pub fn serializeBuildResultWithOptions(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    mode: SerializeMode,
    options: BuildResultSerializeOptions,
) SerializeError!SerializedTable {
    if (mode == .strict) try result.validateBlockingConflictPolicy();

    const snapshot = try result.decisionSnapshotAlloc(allocator);
    defer {
        allocator.free(snapshot.chosen);
        allocator.free(snapshot.unresolved);
    }
    const serialized_states = try allocator.alloc(SerializedState, result.states.len);
    const production_serialization = try buildProductionSerializationAlloc(allocator, result.productions);

    for (result.states, 0..) |parse_state, index| {
        serialized_states[index] = .{
            .id = parse_state.id,
            .core_id = parse_state.core_id,
            .lex_state_id = parse_state.lex_state_id,
            .actions = try collectActionsForState(
                allocator,
                snapshot.chosen,
                snapshot.unresolved,
                parse_state,
                if (index < result.fragile_token_sets.len) result.fragile_token_sets[index] else &.{},
            ),
            .gotos = try collectGotosForState(allocator, parse_state),
            .unresolved = if (mode == .diagnostic)
                try collectUnresolvedForState(allocator, snapshot.unresolved, parse_state.id)
            else
                &.{},
        };
    }

    const blocked = result.hasBlockingUnresolvedDecisions();
    const large_state_count = try computeLargeStateCountAlloc(allocator, serialized_states, production_serialization.productions);
    const parse_action_list = if (options.include_unresolved_parse_actions)
        try buildParseActionListAlloc(allocator, serialized_states, production_serialization.productions)
    else
        try buildRuntimeParseActionListAlloc(allocator, serialized_states, production_serialization.productions);
    const lex_modes = try lexer_serialize.buildLexModesAlloc(allocator, serialized_states);
    const lex_state_terminal_sets = try buildLexStateTerminalSetsAlloc(allocator, result.lex_state_terminal_sets);
    const primary_state_ids = try buildPrimaryStateIdsAlloc(allocator, serialized_states);
    return .{
        .states = serialized_states,
        .blocked = blocked,
        .large_state_count = large_state_count,
        .production_id_count = production_serialization.production_id_count,
        .productions = production_serialization.productions,
        .parse_action_list = parse_action_list,
        .small_parse_table = try buildSmallParseTableAlloc(allocator, serialized_states, large_state_count, parse_action_list, production_serialization.productions),
        .alias_sequences = production_serialization.alias_sequences,
        .non_terminal_aliases = production_serialization.non_terminal_aliases,
        .field_map = production_serialization.field_map,
        .lex_modes = lex_modes,
        .lex_state_terminal_sets = lex_state_terminal_sets,
        .primary_state_ids = primary_state_ids,
    };
}

pub fn attachPreparedMetadataAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    prepared: grammar_ir.PreparedGrammar,
) std.mem.Allocator.Error!SerializedTable {
    const serialized_symbols = try allocator.alloc(SerializedSymbolInfo, prepared.symbols.len);
    for (prepared.symbols, 0..) |symbol, index| {
        serialized_symbols[index] = .{
            .ref = symbolRefFromPreparedSymbol(symbol.id),
            .name = symbol.name,
            .named = symbol.named,
            .visible = symbol.visible,
            .supertype = symbol.supertype,
            .public_symbol = @intCast(index),
        };
    }

    var result = serialized;
    result.grammar_name = prepared.grammar_name;
    result.grammar_version = prepared.grammar_version;
    result.symbols = serialized_symbols;
    result.supertype_map = try buildSupertypeMapAlloc(allocator, prepared);
    result = try attachExternalScannerAlloc(allocator, result, prepared);
    if (prepared.external_tokens.len != 0) {
        result.blocked = true;
    }
    if (prepared.word_token) |word_token| {
        result.word_token = symbolRefFromPreparedSymbol(word_token);
    }
    return result;
}

pub fn attachExtractedMetadataAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    prepared: grammar_ir.PreparedGrammar,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    default_aliases: alias_ir.AliasMap,
) ParseActionListError!SerializedTable {
    const external_symbol_count = countExternalOnlyTokens(syntax.external_tokens);
    const syntax_symbol_count = countSerializedSyntaxVariables(syntax);
    const symbol_count = lexical.variables.len + external_symbol_count + syntax_symbol_count;
    const serialized_symbols = try allocator.alloc(SerializedSymbolInfo, symbol_count);
    var index: usize = 0;

    for (lexical.variables, 0..) |variable, terminal| {
        const symbol_ref = syntax_ir.SymbolRef{ .terminal = @intCast(terminal) };
        serialized_symbols[index] = serializedSymbolInfoWithDefaultAlias(
            symbol_ref,
            variable.name,
            lexicalKindIsNamed(variable.kind),
            lexicalKindIsVisible(variable.kind),
            false,
            @intCast(index),
            default_aliases,
        );
        index += 1;
    }

    for (syntax.external_tokens, 0..) |token, external| {
        if (token.corresponding_internal_token != null) continue;
        const symbol_ref = syntax_ir.SymbolRef{ .external = @intCast(external) };
        serialized_symbols[index] = serializedSymbolInfoWithDefaultAlias(
            symbol_ref,
            token.name,
            syntaxKindIsNamed(token.kind),
            syntaxKindIsVisible(token.kind),
            false,
            @intCast(index),
            default_aliases,
        );
        index += 1;
    }

    for (syntax.variables, 0..) |variable, non_terminal| {
        if (symbolRefIn(syntax.variables_to_inline, .{ .non_terminal = @intCast(non_terminal) })) continue;
        const symbol_ref = syntax_ir.SymbolRef{ .non_terminal = @intCast(non_terminal) };
        serialized_symbols[index] = serializedSymbolInfoWithDefaultAlias(
            symbol_ref,
            variable.name,
            syntaxKindIsNamed(variable.kind),
            syntaxKindIsVisible(variable.kind),
            symbolRefIn(syntax.supertype_symbols, symbol_ref),
            @intCast(index),
            default_aliases,
        );
        index += 1;
    }

    var result = serialized;
    result.grammar_name = prepared.grammar_name;
    result.grammar_version = prepared.grammar_version;
    result.symbols = serialized_symbols;
    result.supertype_map = try buildExtractedSupertypeMapAlloc(allocator, syntax);
    result = try attachExtractedErrorRecoveryStateAlloc(allocator, result, prepared, syntax, lexical);
    result = try attachExtractedExternalScannerAlloc(allocator, result, syntax);
    if (syntax.external_tokens.len != 0) {
        result.blocked = true;
    }
    result.word_token = syntax.word_token;
    return result;
}

fn serializedSymbolInfoWithDefaultAlias(
    symbol_ref: syntax_ir.SymbolRef,
    name: []const u8,
    named: bool,
    visible: bool,
    supertype: bool,
    public_symbol: u16,
    default_aliases: alias_ir.AliasMap,
) SerializedSymbolInfo {
    if (default_aliases.findForSymbol(symbol_ref)) |alias| {
        return .{
            .ref = symbol_ref,
            .name = alias.value,
            .named = alias.named,
            .visible = true,
            .supertype = supertype,
            .public_symbol = public_symbol,
        };
    }

    return .{
        .ref = symbol_ref,
        .name = name,
        .named = named,
        .visible = visible,
        .supertype = supertype,
        .public_symbol = public_symbol,
    };
}

pub fn attachReservedWordsAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
) std.mem.Allocator.Error!SerializedTable {
    var result = serialized;
    result.reserved_words = try buildReservedWordsAlloc(allocator, prepared, lexical);
    return result;
}

fn lexicalKindIsNamed(kind: lexical_ir.VariableKind) bool {
    return switch (kind) {
        .named => true,
        .anonymous, .hidden, .auxiliary => false,
    };
}

fn lexicalKindIsVisible(kind: lexical_ir.VariableKind) bool {
    return switch (kind) {
        .named, .anonymous => true,
        .hidden, .auxiliary => false,
    };
}

fn syntaxKindIsNamed(kind: syntax_ir.VariableKind) bool {
    return switch (kind) {
        .named => true,
        .anonymous, .hidden, .auxiliary => false,
    };
}

fn syntaxKindIsVisible(kind: syntax_ir.VariableKind) bool {
    return switch (kind) {
        .named, .anonymous => true,
        .hidden, .auxiliary => false,
    };
}

fn countExternalOnlyTokens(tokens: []const syntax_ir.ExternalToken) usize {
    var count: usize = 0;
    for (tokens) |token| {
        if (token.corresponding_internal_token == null) count += 1;
    }
    return count;
}

fn countSerializedSyntaxVariables(syntax: syntax_ir.SyntaxGrammar) usize {
    var count: usize = 0;
    for (syntax.variables, 0..) |_, non_terminal| {
        if (symbolRefIn(syntax.variables_to_inline, .{ .non_terminal = @intCast(non_terminal) })) continue;
        count += 1;
    }
    return count;
}

fn attachExtractedErrorRecoveryStateAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    prepared: grammar_ir.PreparedGrammar,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
) ParseActionListError!SerializedTable {
    if (serialized.states.len == 0) return serialized;

    const recover_symbols = buildExtractedErrorRecoverySymbolsAlloc(
        allocator,
        prepared,
        syntax,
        lexical,
        serialized.states,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try buildFallbackErrorRecoverySymbolsAlloc(allocator, syntax, lexical),
    };
    defer allocator.free(recover_symbols);

    var actions_list = std.array_list.Managed(SerializedActionEntry).init(allocator);
    defer actions_list.deinit();
    try actions_list.appendSlice(serialized.states[0].actions);

    for (recover_symbols) |symbol| {
        if (hasSerializedActionForSymbol(actions_list.items, symbol)) continue;
        try actions_list.append(.{
            .symbol = symbol,
            .action = .{ .accept = {} },
            .recover = true,
            .reusable = false,
        });
    }
    std.mem.sort(SerializedActionEntry, actions_list.items, {}, serializedActionEntryLessThan);

    const states = try allocator.alloc(SerializedState, serialized.states.len);
    @memcpy(states, serialized.states);
    states[0] = serialized.states[0];
    states[0].actions = try actions_list.toOwnedSlice();

    var result = serialized;
    result.states = states;
    result.large_state_count = try computeLargeStateCountAlloc(allocator, result.states, result.productions);
    try rebuildParseActionTables(allocator, &result, .{});
    return result;
}

fn buildExtractedErrorRecoverySymbolsAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    states: []const SerializedState,
) (std.mem.Allocator.Error || lexer_model.ExpandError || first.FirstError)![]const syntax_ir.SymbolRef {
    for (lexical.variables) |variable| {
        if (variable.rule >= prepared.rules.len) return error.UnsupportedRule;
    }

    var expanded = try lexer_model.expandExtractedLexicalGrammar(allocator, prepared.rules, lexical);
    defer expanded.deinit(allocator);

    const reserved_words = try buildReservedWordsAlloc(allocator, prepared, lexical);
    defer deinitReservedWords(allocator, reserved_words);
    const reserved_context_names = try reservedWordContextNamesAlloc(allocator, prepared.reserved_word_sets);
    defer allocator.free(reserved_context_names);

    const following_tokens = try lexer_model.computeFollowingTokensWithReservedAlloc(
        allocator,
        syntax,
        expanded.variables.len,
        reserved_words.sets,
        reserved_context_names,
    );
    defer lexer_model.deinitTokenIndexSets(allocator, following_tokens);

    var conflict_map = try lexer_model.buildTokenConflictMapWithFollowingTokensAlloc(
        allocator,
        expanded,
        following_tokens,
    );
    defer conflict_map.deinit(allocator);

    const keyword_tokens = try buildKeywordTerminalSetAlloc(allocator, prepared, lexical);
    defer allocator.free(keyword_tokens);
    const coincident_tokens = try buildSerializedCoincidentTokenIndexAlloc(allocator, states, lexical.variables.len);
    defer allocator.free(coincident_tokens);

    const conflict_free_tokens = try allocator.alloc(bool, lexical.variables.len);
    defer allocator.free(conflict_free_tokens);
    @memset(conflict_free_tokens, false);

    for (0..lexical.variables.len) |left| {
        var conflicts_with_other_tokens = false;
        for (0..lexical.variables.len) |right| {
            if (left == right) continue;
            if (coincidentTokenContains(coincident_tokens, lexical.variables.len, left, right)) continue;
            if (tokenConflictDoesMatchShorterOrLonger(conflict_map, left, right)) {
                conflicts_with_other_tokens = true;
                break;
            }
        }
        conflict_free_tokens[left] = !conflicts_with_other_tokens;
    }

    var symbols = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
    defer symbols.deinit();
    for (0..lexical.variables.len) |index| {
        const symbol = syntax_ir.SymbolRef{ .terminal = @intCast(index) };
        if (!conflict_free_tokens[index] and !keyword_tokens[index] and !symbolRefEql(syntax.word_token orelse .{ .end = {} }, symbol)) {
            var excluded = false;
            for (0..lexical.variables.len) |conflict_free_index| {
                if (!conflict_free_tokens[conflict_free_index]) continue;
                if (coincidentTokenContains(coincident_tokens, lexical.variables.len, index, conflict_free_index)) continue;
                if (tokenConflictDoesConflict(conflict_map, index, conflict_free_index)) {
                    excluded = true;
                    break;
                }
            }
            if (excluded) continue;
        }
        try appendUniqueSymbolRef(&symbols, symbol);
    }

    try appendExternalOnlyRecoverySymbols(&symbols, syntax);
    try appendUniqueSymbolRef(&symbols, .{ .end = {} });
    std.mem.sort(syntax_ir.SymbolRef, symbols.items, {}, symbolRefLessThan);
    return try symbols.toOwnedSlice();
}

fn buildFallbackErrorRecoverySymbolsAlloc(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
) std.mem.Allocator.Error![]const syntax_ir.SymbolRef {
    var symbols = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
    defer symbols.deinit();
    for (0..lexical.variables.len) |index| {
        try appendUniqueSymbolRef(&symbols, .{ .terminal = @intCast(index) });
    }
    try appendExternalOnlyRecoverySymbols(&symbols, syntax);
    try appendUniqueSymbolRef(&symbols, .{ .end = {} });
    std.mem.sort(syntax_ir.SymbolRef, symbols.items, {}, symbolRefLessThan);
    return try symbols.toOwnedSlice();
}

fn appendExternalOnlyRecoverySymbols(
    symbols: *std.array_list.Managed(syntax_ir.SymbolRef),
    syntax: syntax_ir.SyntaxGrammar,
) std.mem.Allocator.Error!void {
    for (syntax.external_tokens, 0..) |external_token, index| {
        if (external_token.corresponding_internal_token != null) continue;
        try appendUniqueSymbolRef(symbols, .{ .external = @intCast(index) });
    }
}

fn reservedWordContextNamesAlloc(
    allocator: std.mem.Allocator,
    reserved_word_sets: []const grammar_ir.ReservedWordSet,
) std.mem.Allocator.Error![]const []const u8 {
    const names = try allocator.alloc([]const u8, reserved_word_sets.len);
    for (reserved_word_sets, 0..) |reserved_set, index| {
        names[index] = reserved_set.context_name;
    }
    return names;
}

fn buildSerializedCoincidentTokenIndexAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    terminal_count: usize,
) std.mem.Allocator.Error![]bool {
    const values = try allocator.alloc(bool, terminal_count * terminal_count);
    @memset(values, false);

    var terminals = std.array_list.Managed(usize).init(allocator);
    defer terminals.deinit();
    for (states) |serialized_state| {
        terminals.clearRetainingCapacity();
        for (serialized_state.actions) |entry| {
            const terminal_index = switch (entry.symbol) {
                .terminal => |index| index,
                else => continue,
            };
            if (terminal_index >= terminal_count) continue;
            var seen = false;
            for (terminals.items) |existing| {
                if (existing == terminal_index) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try terminals.append(terminal_index);
        }

        for (terminals.items, 0..) |left, left_index| {
            for (terminals.items[left_index..]) |right| {
                values[left * terminal_count + right] = true;
                values[right * terminal_count + left] = true;
            }
        }
    }

    return values;
}

fn coincidentTokenContains(values: []const bool, terminal_count: usize, left: usize, right: usize) bool {
    return values[left * terminal_count + right];
}

fn tokenConflictDoesMatchShorterOrLonger(map: lexer_model.TokenConflictMap, left: usize, right: usize) bool {
    const entry = map.status(left, right);
    const reverse = map.status(right, left);
    return (entry.does_match_valid_continuation or entry.does_match_separators) and !reverse.does_match_separators;
}

fn tokenConflictDoesConflict(map: lexer_model.TokenConflictMap, left: usize, right: usize) bool {
    const entry = map.status(left, right);
    return entry.does_match_valid_continuation or entry.does_match_separators or entry.matches_same_string;
}

fn hasSerializedActionForSymbol(entries: []const SerializedActionEntry, symbol: syntax_ir.SymbolRef) bool {
    for (entries) |entry| {
        if (symbolRefEql(entry.symbol, symbol)) return true;
    }
    return false;
}

fn serializedActionEntryLessThan(_: void, left: SerializedActionEntry, right: SerializedActionEntry) bool {
    return symbolRefLessThan({}, left.symbol, right.symbol);
}

pub fn attachReservedWordLexModesAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    parse_states: []const state.ParseState,
) std.mem.Allocator.Error!SerializedTable {
    var result = serialized;
    const lex_modes = try allocator.alloc(lexer_serialize.SerializedLexMode, serialized.lex_modes.len);
    for (serialized.lex_modes, 0..) |mode, index| {
        lex_modes[index] = mode;
        if (index < parse_states.len) {
            lex_modes[index].reserved_word_set_id = parse_states[index].reserved_word_set_id;
        }
    }
    result.lex_modes = lex_modes;
    return result;
}

pub fn attachNonTerminalExtraLexModesAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    parse_states: []const state.ParseState,
    productions: []const build.ProductionInfo,
    extra_symbols: []const syntax_ir.SymbolRef,
) std.mem.Allocator.Error!SerializedTable {
    if (extra_symbols.len == 0) return serialized;

    var result = serialized;
    const lex_modes = try allocator.alloc(lexer_serialize.SerializedLexMode, serialized.lex_modes.len);
    for (serialized.lex_modes, 0..) |mode, index| {
        lex_modes[index] = mode;
        if (index < parse_states.len and isNonTerminalExtraEndState(parse_states[index], productions, extra_symbols)) {
            lex_modes[index].lex_state = std.math.maxInt(u16);
        }
    }
    result.lex_modes = lex_modes;
    return result;
}

pub fn attachExtraShiftMetadataAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    extra_symbols: []const syntax_ir.SymbolRef,
) ParseActionListError!SerializedTable {
    return try attachExtraShiftMetadataWithOptionsAlloc(allocator, serialized, extra_symbols, .{});
}

pub fn attachExtraShiftMetadataWithOptionsAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    extra_symbols: []const syntax_ir.SymbolRef,
    options: ParseActionTableOptions,
) ParseActionListError!SerializedTable {
    if (extra_symbols.len == 0) return serialized;

    const states = try allocator.alloc(SerializedState, serialized.states.len);
    var result = serialized;
    result.states = states;
    result.blocked = serialized.blocked;

    for (serialized.states, 0..) |serialized_state, state_index| {
        const entries = try allocator.alloc(SerializedActionEntry, serialized_state.actions.len);
        for (serialized_state.actions, 0..) |entry, entry_index| {
            entries[entry_index] = entry;
            if (actionEntryHasShift(entry) and symbolRefIn(extra_symbols, entry.symbol)) {
                entries[entry_index].extra = true;
            }
        }
        states[state_index] = serialized_state;
        states[state_index].actions = entries;
    }

    try rebuildParseActionTables(allocator, &result, options);
    return result;
}

pub fn attachRepetitionShiftMetadataAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    parse_states: []const state.ParseState,
    productions: []const build.ProductionInfo,
) ParseActionListError!SerializedTable {
    return try attachRepetitionShiftMetadataWithFirstSetsAlloc(
        allocator,
        serialized,
        parse_states,
        productions,
        null,
    );
}

pub fn attachRepetitionShiftMetadataWithFirstSetsAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    parse_states: []const state.ParseState,
    productions: []const build.ProductionInfo,
    first_sets: ?first.FirstSets,
) ParseActionListError!SerializedTable {
    return try attachRepetitionShiftMetadataWithFirstSetsAndOptionsAlloc(
        allocator,
        serialized,
        parse_states,
        productions,
        first_sets,
        .{},
    );
}

pub fn attachRepetitionShiftMetadataWithFirstSetsAndOptionsAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    parse_states: []const state.ParseState,
    productions: []const build.ProductionInfo,
    first_sets: ?first.FirstSets,
    options: ParseActionTableOptions,
) ParseActionListError!SerializedTable {
    if (!hasRepetitionShift(serialized.states, parse_states, productions, first_sets)) return serialized;

    const states = try allocator.alloc(SerializedState, serialized.states.len);
    var result = serialized;
    result.states = states;

    for (serialized.states, 0..) |serialized_state, state_index| {
        const entries = try allocator.alloc(SerializedActionEntry, serialized_state.actions.len);
        for (serialized_state.actions, 0..) |entry, entry_index| {
            entries[entry_index] = entry;
            if (actionEntryHasShift(entry) and state_index < parse_states.len and
                shiftHasRepeatAuxiliaryConflict(parse_states[state_index], productions, first_sets, entry.symbol))
            {
                entries[entry_index].repetition = true;
            }
        }
        states[state_index] = serialized_state;
        states[state_index].actions = entries;
    }

    try rebuildParseActionTables(allocator, &result, options);
    return result;
}

fn rebuildParseActionTables(
    allocator: std.mem.Allocator,
    serialized: *SerializedTable,
    options: ParseActionTableOptions,
) ParseActionListError!void {
    serialized.parse_action_list = if (options.include_unresolved_parse_actions)
        try buildParseActionListAlloc(allocator, serialized.states, serialized.productions)
    else
        try buildRuntimeParseActionListAlloc(allocator, serialized.states, serialized.productions);
    serialized.small_parse_table = try buildSmallParseTableAlloc(
        allocator,
        serialized.states,
        serialized.large_state_count,
        serialized.parse_action_list,
        serialized.productions,
    );
}

fn attachExternalScannerAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    prepared: grammar_ir.PreparedGrammar,
) std.mem.Allocator.Error!SerializedTable {
    if (prepared.external_tokens.len == 0) return serialized;

    var result = serialized;
    const symbols = try allocator.alloc(syntax_ir.SymbolRef, prepared.external_tokens.len);
    errdefer allocator.free(symbols);
    for (prepared.external_tokens, 0..) |token, index| {
        symbols[index] = symbolRefFromPreparedSymbol(token.symbol);
    }

    const built_states = try buildExternalScannerStatesAlloc(allocator, symbols, serialized.states, &.{});
    errdefer deinitExternalScanner(allocator, .{ .symbols = symbols, .states = built_states.states });
    errdefer allocator.free(built_states.state_ids);
    result.external_scanner = .{
        .symbols = symbols,
        .states = built_states.states,
    };
    result.lex_modes = try buildLexModesWithExternalStatesAlloc(
        allocator,
        serialized.lex_modes,
        built_states.state_ids,
    );
    allocator.free(built_states.state_ids);
    return result;
}

fn attachExtractedExternalScannerAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    syntax: syntax_ir.SyntaxGrammar,
) std.mem.Allocator.Error!SerializedTable {
    if (syntax.external_tokens.len == 0) return serialized;

    var result = serialized;
    const symbols = try allocator.alloc(syntax_ir.SymbolRef, syntax.external_tokens.len);
    errdefer allocator.free(symbols);
    for (symbols, 0..) |*symbol, index| {
        symbol.* = syntax.external_tokens[index].corresponding_internal_token orelse .{ .external = @intCast(index) };
    }

    const built_states = try buildExternalScannerStatesAlloc(allocator, symbols, serialized.states, syntax.extra_symbols);
    errdefer deinitExternalScanner(allocator, .{ .symbols = symbols, .states = built_states.states });
    errdefer allocator.free(built_states.state_ids);
    result.external_scanner = .{
        .symbols = symbols,
        .states = built_states.states,
    };
    result.lex_modes = try buildLexModesWithExternalStatesAlloc(
        allocator,
        serialized.lex_modes,
        built_states.state_ids,
    );
    allocator.free(built_states.state_ids);
    return result;
}

pub fn attachKeywordLexTableAlloc(
    allocator: std.mem.Allocator,
    serialized: SerializedTable,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
) (std.mem.Allocator.Error || lexer_serialize.SerializeError)!SerializedTable {
    if (prepared.word_token == null or prepared.reserved_word_sets.len == 0) return serialized;

    var result = serialized;
    const keyword_lexical = try buildKeywordLexicalGrammarAlloc(allocator, prepared, lexical);
    defer keyword_lexical.deinit(allocator);

    result.keyword_unmapped_reserved_word_count = countUnmappedReservedWords(prepared, keyword_lexical.lexical);

    const terminal_set = try buildKeywordLexTableTerminalSetAlloc(allocator, prepared, keyword_lexical.lexical);
    defer allocator.free(terminal_set);
    var any_terminal = false;
    for (terminal_set) |enabled| {
        if (enabled) {
            any_terminal = true;
            break;
        }
    }
    if (!any_terminal) return result;

    const tables = try lexer_serialize.buildSerializedLexTablesAlloc(
        allocator,
        prepared.rules,
        keyword_lexical.lexical,
        &.{terminal_set},
    );
    defer allocator.free(tables);

    var keyword_table = tables[0];
    lexer_serialize.deinitLargeCharacterSets(allocator, keyword_table.large_character_sets);
    keyword_table.large_character_sets = &.{};
    result.keyword_lex_table = keyword_table;
    return result;
}

pub fn buildParseActionListAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    productions: []const SerializedProductionInfo,
) ParseActionListError![]const SerializedParseActionListEntry {
    return try buildParseActionListWithOptionsAlloc(allocator, states, productions, .{ .include_unresolved = true });
}

pub fn buildRuntimeParseActionListAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    productions: []const SerializedProductionInfo,
) ParseActionListError![]const SerializedParseActionListEntry {
    return try buildParseActionListWithOptionsAlloc(allocator, states, productions, .{ .include_unresolved = false });
}

const ParseActionListBuildOptions = struct {
    include_unresolved: bool = true,
};

fn buildParseActionListWithOptionsAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    productions: []const SerializedProductionInfo,
    options: ParseActionListBuildOptions,
) ParseActionListError![]const SerializedParseActionListEntry {
    var entries = std.array_list.Managed(SerializedParseActionListEntry).init(allocator);
    defer entries.deinit();
    var single_action_indexes = ParseActionListIndexMap.init(allocator);
    defer single_action_indexes.deinit();
    var action_slice_indexes = ParseActionListSliceIndexMap.init(allocator);
    defer action_slice_indexes.deinit();
    var profile = ParseActionListProfile{};

    try entries.append(.{
        .index = 0,
        .reusable = false,
        .actions = &.{},
    });
    try action_slice_indexes.put(.{ .reusable = false, .actions = &.{} }, 0);
    var next_index: usize = 1;

    for (states) |serialized_state| {
        for (serialized_state.actions) |entry| {
            const action_slice = try runtimeActionsFromActionEntryAlloc(allocator, entry, productions);
            const reusable = entry.reusable and actionSliceIsReusable(action_slice);
            const action_key: ParseActionListSliceKey = .{ .reusable = reusable, .actions = action_slice };
            if (reusable) {
                profile.reusable_inputs += 1;
            } else {
                profile.unresolved_inputs += 1;
            }
            if (action_slice.len == 1 and reusable) {
                if (single_action_indexes.contains(action_slice[0])) {
                    profile.single_reusable_duplicates += 1;
                    allocator.free(action_slice);
                    continue;
                }
            } else if (action_slice_indexes.contains(action_key)) {
                if (reusable) {
                    profile.multi_reusable_duplicates += 1;
                } else {
                    profile.unresolved_duplicates += 1;
                }
                allocator.free(action_slice);
                continue;
            }

            const index = checkedParseActionListSpan(next_index, action_slice.len) catch |err| {
                recordParseActionListEntry(&profile, reusable, action_slice.len);
                if (!reusable) {
                    profile.unresolved_unique += 1;
                } else if (action_slice.len == 1) {
                    profile.single_reusable_unique += 1;
                } else {
                    profile.multi_reusable_unique += 1;
                }
                logParseActionListProfile(profile, next_index + action_slice.len + 1);
                allocator.free(action_slice);
                return err;
            };
            next_index += action_slice.len + 1;
            try entries.append(.{
                .index = index,
                .reusable = reusable,
                .actions = action_slice,
            });
            recordParseActionListEntry(&profile, reusable, action_slice.len);
            if (!reusable) {
                profile.unresolved_unique += 1;
            } else if (action_slice.len == 1) {
                profile.single_reusable_unique += 1;
                try single_action_indexes.put(action_slice[0], index);
            } else {
                profile.multi_reusable_unique += 1;
            }
            try action_slice_indexes.put(.{ .reusable = reusable, .actions = action_slice }, index);
        }
        if (!options.include_unresolved) continue;

        for (serialized_state.unresolved) |entry| {
            const action_slice = try runtimeActionsFromParseActionSliceAlloc(allocator, entry.candidate_actions, productions);
            const action_key: ParseActionListSliceKey = .{ .reusable = false, .actions = action_slice };
            profile.unresolved_inputs += 1;
            if (action_slice_indexes.contains(action_key)) {
                profile.unresolved_duplicates += 1;
                allocator.free(action_slice);
                continue;
            }

            const index = checkedParseActionListSpan(next_index, action_slice.len) catch |err| {
                recordParseActionListEntry(&profile, false, action_slice.len);
                profile.unresolved_unique += 1;
                logParseActionListProfile(profile, next_index + action_slice.len + 1);
                allocator.free(action_slice);
                return err;
            };
            next_index += action_slice.len + 1;
            try entries.append(.{
                .index = index,
                .reusable = false,
                .actions = action_slice,
            });
            recordParseActionListEntry(&profile, false, action_slice.len);
            profile.unresolved_unique += 1;
            try action_slice_indexes.put(.{ .reusable = false, .actions = action_slice }, index);
        }
    }

    logParseActionListProfile(profile, next_index);
    return try entries.toOwnedSlice();
}

fn actionSliceIsReusable(actions_slice: []const SerializedParseAction) bool {
    for (actions_slice) |action| {
        if (action.kind == .recover) return false;
    }
    return true;
}

const ParseActionListProfile = struct {
    reusable_inputs: usize = 0,
    unresolved_inputs: usize = 0,
    single_reusable_unique: usize = 0,
    single_reusable_duplicates: usize = 0,
    multi_reusable_unique: usize = 0,
    multi_reusable_duplicates: usize = 0,
    unresolved_unique: usize = 0,
    unresolved_duplicates: usize = 0,
    reusable_flat_width: usize = 0,
    unresolved_flat_width: usize = 0,
    max_actions_per_entry: usize = 0,
};

fn recordParseActionListEntry(profile: *ParseActionListProfile, reusable: bool, action_count: usize) void {
    if (reusable) {
        profile.reusable_flat_width += action_count + 1;
    } else {
        profile.unresolved_flat_width += action_count + 1;
    }
    profile.max_actions_per_entry = @max(profile.max_actions_per_entry, action_count);
}

fn logParseActionListProfile(profile: ParseActionListProfile, next_index: usize) void {
    if (!shouldProfileSerialize()) return;
    const capacity = std.math.maxInt(u16) + 1;
    const runtime_entries = profile.single_reusable_unique + profile.multi_reusable_unique + 1;
    const runtime_flat_width = profile.reusable_flat_width + 1;
    const runtime_headroom = capacity -| runtime_flat_width;
    const diagnostic_overflow_only = next_index > capacity and runtime_flat_width <= capacity;
    std.debug.print(
        "[parse_table_profile] parse_action_list entries={d} flat_width={d} capacity={d} runtime_entries={d} runtime_flat_width={d} runtime_headroom={d} diagnostic_overflow_only={} reusable_inputs={d} unresolved_inputs={d} single_unique={d} single_dupes={d} multi_unique={d} multi_dupes={d} unresolved_unique={d} unresolved_dupes={d} reusable_flat_width={d} unresolved_flat_width={d} max_actions_per_entry={d}\n",
        .{
            profile.single_reusable_unique + profile.multi_reusable_unique + profile.unresolved_unique + 1,
            next_index,
            capacity,
            runtime_entries,
            runtime_flat_width,
            runtime_headroom,
            diagnostic_overflow_only,
            profile.reusable_inputs,
            profile.unresolved_inputs,
            profile.single_reusable_unique,
            profile.single_reusable_duplicates,
            profile.multi_reusable_unique,
            profile.multi_reusable_duplicates,
            profile.unresolved_unique,
            profile.unresolved_duplicates,
            profile.reusable_flat_width,
            profile.unresolved_flat_width + 1,
            profile.max_actions_per_entry,
        },
    );
}

fn checkedParseActionListSpan(index: usize, action_count: usize) ParseActionListError!u16 {
    if (index > std.math.maxInt(u16) or action_count > std.math.maxInt(u16) - index) {
        return error.ParseActionListTooLarge;
    }
    return @intCast(index);
}

pub fn deinitParseActionList(
    allocator: std.mem.Allocator,
    entries: []const SerializedParseActionListEntry,
) void {
    for (entries) |entry| {
        if (entry.actions.len > 0) allocator.free(entry.actions);
    }
    allocator.free(entries);
}

pub fn buildSmallParseTableAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    large_state_count: usize,
    parse_action_list: []const SerializedParseActionListEntry,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error!SerializedSmallParseTable {
    if (large_state_count >= states.len) return .{};

    var unique_rows = std.array_list.Managed(SerializedSmallParseRow).init(allocator);
    defer unique_rows.deinit();
    var action_indexes = try buildSingleParseActionIndexMapAlloc(allocator, parse_action_list);
    defer action_indexes.deinit();

    const map = try allocator.alloc(u32, states.len - large_state_count);
    var next_offset: u32 = 0;

    for (states[large_state_count..], 0..) |serialized_state, small_index| {
        const groups = try buildSmallParseGroupsAlloc(allocator, serialized_state, parse_action_list, &action_indexes, productions);
        map[small_index] = next_offset;
        try unique_rows.append(.{
            .offset = next_offset,
            .groups = groups,
        });
        next_offset += packedSmallParseRowLength(groups);
    }

    return .{
        .rows = try unique_rows.toOwnedSlice(),
        .map = map,
    };
}

pub fn deinitSmallParseTable(allocator: std.mem.Allocator, table: SerializedSmallParseTable) void {
    for (table.rows) |row| {
        deinitSmallParseGroups(allocator, row.groups);
    }
    allocator.free(table.rows);
    allocator.free(table.map);
}

pub fn deinitFieldMap(allocator: std.mem.Allocator, field_map: SerializedFieldMap) void {
    allocator.free(field_map.names);
    allocator.free(field_map.entries);
    allocator.free(field_map.slices);
}

pub fn deinitSupertypeMap(allocator: std.mem.Allocator, supertype_map: SerializedSupertypeMap) void {
    allocator.free(supertype_map.symbols);
    allocator.free(supertype_map.entries);
    allocator.free(supertype_map.slices);
}

pub fn deinitReservedWords(allocator: std.mem.Allocator, reserved_words: SerializedReservedWords) void {
    for (reserved_words.sets) |set| allocator.free(set);
    allocator.free(reserved_words.sets);
}

pub fn deinitExternalScanner(allocator: std.mem.Allocator, external_scanner: SerializedExternalScanner) void {
    allocator.free(external_scanner.symbols);
    for (external_scanner.states) |state_set| allocator.free(state_set);
    allocator.free(external_scanner.states);
}

pub fn deinitLexStateTerminalSets(
    allocator: std.mem.Allocator,
    terminal_sets: []const []const bool,
) void {
    for (terminal_sets) |terminal_set| allocator.free(terminal_set);
    allocator.free(terminal_sets);
}

pub fn buildLexStateTerminalSetsAlloc(
    allocator: std.mem.Allocator,
    terminal_sets: []const []const bool,
) std.mem.Allocator.Error![]const []const bool {
    const serialized = try allocator.alloc([]const bool, terminal_sets.len);
    var initialized: usize = 0;
    errdefer {
        for (serialized[0..initialized]) |terminal_set| allocator.free(terminal_set);
        allocator.free(serialized);
    }

    for (terminal_sets, 0..) |terminal_set, index| {
        serialized[index] = try allocator.dupe(bool, terminal_set);
        initialized += 1;
    }
    return serialized;
}

pub fn buildPrimaryStateIdsAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
) std.mem.Allocator.Error![]const state.StateId {
    const ids = try allocator.alloc(state.StateId, states.len);
    for (states, 0..) |serialized_state, index| {
        var primary = serialized_state.id;
        for (states[0..index]) |previous_state| {
            if (previous_state.core_id == serialized_state.core_id) {
                primary = previous_state.id;
                break;
            }
        }
        ids[index] = primary;
    }
    return ids;
}

pub fn computeLargeStateCountAlloc(
    allocator: std.mem.Allocator,
    states: []const SerializedState,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error!usize {
    var symbols = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
    defer symbols.deinit();

    for (states) |serialized_state| {
        for (serialized_state.actions) |entry| {
            try appendUniqueSymbolRef(&symbols, entry.symbol);
            if (entry.candidate_actions.len > 1) {
                for (entry.candidate_actions) |candidate| {
                    const production_id = switch (candidate) {
                        .reduce => |id| id,
                        .shift, .shift_extra, .accept => continue,
                    };
                    if (production_id < productions.len) {
                        try appendUniqueSymbolRef(&symbols, .{ .non_terminal = productions[production_id].lhs });
                    }
                }
                continue;
            }
            switch (entry.action) {
                .reduce => |production_id| {
                    if (production_id < productions.len) {
                        try appendUniqueSymbolRef(&symbols, .{ .non_terminal = productions[production_id].lhs });
                    }
                },
                .shift, .shift_extra, .accept => {},
            }
        }
        for (serialized_state.gotos) |entry| {
            try appendUniqueSymbolRef(&symbols, entry.symbol);
        }
    }

    const threshold = @min(@as(usize, 64), symbols.items.len / 2);
    var count: usize = 0;
    for (states, 0..) |serialized_state, index| {
        if (index <= 1 or serialized_state.actions.len + serialized_state.gotos.len > threshold) {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

fn buildSmallParseGroupsAlloc(
    allocator: std.mem.Allocator,
    serialized_state: SerializedState,
    parse_action_list: []const SerializedParseActionListEntry,
    single_action_indexes: *const ParseActionListIndexMap,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error![]const SerializedSmallParseGroup {
    var groups = std.array_list.Managed(SerializedSmallParseGroup).init(allocator);
    defer groups.deinit();

    for (serialized_state.gotos) |entry| {
        try appendSmallParseSymbol(allocator, &groups, .state, @intCast(entry.state), entry.symbol);
    }
    for (serialized_state.actions) |entry| {
        const action_index = parseActionListIndexForActionEntryWithMap(
            parse_action_list,
            single_action_indexes,
            entry,
            productions,
        ) orelse 0;
        try appendSmallParseSymbol(allocator, &groups, .action, action_index, entry.symbol);
    }

    for (groups.items) |*group| {
        std.mem.sort(syntax_ir.SymbolRef, @constCast(group.symbols), {}, symbolRefLessThan);
    }
    std.mem.sort(SerializedSmallParseGroup, groups.items, {}, smallParseGroupLessThan);

    return try groups.toOwnedSlice();
}

fn buildSingleParseActionIndexMapAlloc(
    allocator: std.mem.Allocator,
    entries: []const SerializedParseActionListEntry,
) std.mem.Allocator.Error!ParseActionListIndexMap {
    var indexes = ParseActionListIndexMap.init(allocator);
    for (entries) |entry| {
        if (entry.actions.len != 1) continue;
        try indexes.put(entry.actions[0], entry.index);
    }
    return indexes;
}

fn appendSmallParseSymbol(
    allocator: std.mem.Allocator,
    groups: *std.array_list.Managed(SerializedSmallParseGroup),
    kind: SerializedSmallParseValueKind,
    value: u16,
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error!void {
    for (groups.items) |*group| {
        if (group.kind == kind and group.value == value) {
            group.symbols = try appendSymbolToOwnedSlice(allocator, group.symbols, symbol);
            return;
        }
    }

    const symbols = try allocator.alloc(syntax_ir.SymbolRef, 1);
    symbols[0] = symbol;
    try groups.append(.{
        .kind = kind,
        .value = value,
        .symbols = symbols,
    });
}

fn appendSymbolToOwnedSlice(
    allocator: std.mem.Allocator,
    symbols: []const syntax_ir.SymbolRef,
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error![]const syntax_ir.SymbolRef {
    const updated = try allocator.alloc(syntax_ir.SymbolRef, symbols.len + 1);
    @memcpy(updated[0..symbols.len], symbols);
    updated[symbols.len] = symbol;
    allocator.free(symbols);
    return updated;
}

fn findSmallParseRow(rows: []const SerializedSmallParseRow, groups: []const SerializedSmallParseGroup) ?usize {
    for (rows, 0..) |row, index| {
        if (smallParseGroupsEql(row.groups, groups)) return index;
    }
    return null;
}

fn smallParseGroupsEql(left: []const SerializedSmallParseGroup, right: []const SerializedSmallParseGroup) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_group, right_group| {
        if (left_group.kind != right_group.kind or left_group.value != right_group.value) return false;
        if (left_group.symbols.len != right_group.symbols.len) return false;
        for (left_group.symbols, right_group.symbols) |left_symbol, right_symbol| {
            if (!symbolRefEql(left_symbol, right_symbol)) return false;
        }
    }
    return true;
}

fn packedSmallParseRowLength(groups: []const SerializedSmallParseGroup) u32 {
    var len: u32 = 1;
    for (groups) |group| {
        len += 2 + @as(u32, @intCast(group.symbols.len));
    }
    return len;
}

fn deinitSmallParseGroups(allocator: std.mem.Allocator, groups: []const SerializedSmallParseGroup) void {
    for (groups) |group| {
        allocator.free(group.symbols);
    }
    allocator.free(groups);
}

fn smallParseGroupLessThan(_: void, left: SerializedSmallParseGroup, right: SerializedSmallParseGroup) bool {
    if (left.symbols.len != right.symbols.len) return left.symbols.len < right.symbols.len;
    if (left.kind != right.kind) return @intFromEnum(left.kind) < @intFromEnum(right.kind);
    if (left.value != right.value) return left.value < right.value;
    if (left.symbols.len == 0 or right.symbols.len == 0) return left.symbols.len < right.symbols.len;
    return symbolRefLessThan({}, left.symbols[0], right.symbols[0]);
}

pub fn parseActionListIndexForParseAction(
    entries: []const SerializedParseActionListEntry,
    action: actions.ParseAction,
    productions: []const SerializedProductionInfo,
) ?u16 {
    return parseActionListIndexForRuntimeAction(entries, runtimeActionFromParseAction(action, productions));
}

pub fn parseActionListIndexForActionEntry(
    entries: []const SerializedParseActionListEntry,
    entry: SerializedActionEntry,
    productions: []const SerializedProductionInfo,
) ?u16 {
    const expected_reusable = actionEntryIsReusable(entry, productions);
    for (entries) |candidate| {
        if (candidate.reusable != expected_reusable) continue;
        if (runtimeActionSlicesEql(candidate.actions, entry, productions)) return candidate.index;
    }
    return null;
}

pub fn parseActionListIndexForUnresolvedEntry(
    entries: []const SerializedParseActionListEntry,
    entry: SerializedUnresolvedEntry,
    productions: []const SerializedProductionInfo,
) ?u16 {
    for (entries) |candidate| {
        if (candidate.reusable) continue;
        if (runtimeActionSliceEqlParseActions(candidate.actions, entry.candidate_actions, productions)) return candidate.index;
    }
    return null;
}

fn parseActionListIndexForActionEntryWithMap(
    entries: []const SerializedParseActionListEntry,
    single_action_indexes: *const ParseActionListIndexMap,
    entry: SerializedActionEntry,
    productions: []const SerializedProductionInfo,
) ?u16 {
    if (entry.candidate_actions.len <= 1) {
        const runtime_action = runtimeActionFromActionEntry(entry, productions);
        if (entry.reusable and runtime_action.kind != .recover) {
            if (single_action_indexes.get(runtime_action)) |index| return index;
        }
    }
    return parseActionListIndexForActionEntry(entries, entry, productions);
}

pub fn runtimeActionFromActionEntry(
    entry: SerializedActionEntry,
    productions: []const SerializedProductionInfo,
) SerializedParseAction {
    if (entry.recover) {
        return .{ .kind = .recover };
    }
    var runtime_action = runtimeActionFromParseAction(entry.action, productions);
    switch (entry.action) {
        .shift => if (runtime_action.kind == .shift) {
            runtime_action.extra = entry.extra;
            runtime_action.repetition = entry.repetition;
        },
        else => {},
    }
    return runtime_action;
}

fn runtimeActionsFromActionEntryAlloc(
    allocator: std.mem.Allocator,
    entry: SerializedActionEntry,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error![]const SerializedParseAction {
    if (entry.candidate_actions.len <= 1) {
        const action_slice = try allocator.alloc(SerializedParseAction, 1);
        action_slice[0] = runtimeActionFromActionEntry(entry, productions);
        return action_slice;
    }

    const action_slice = try allocator.alloc(SerializedParseAction, entry.candidate_actions.len);
    var index: usize = 0;
    for (entry.candidate_actions) |candidate| {
        if (candidate == .shift) continue;
        action_slice[index] = runtimeActionFromCandidateAction(entry, candidate, productions);
        index += 1;
    }
    for (entry.candidate_actions) |candidate| {
        if (candidate != .shift) continue;
        action_slice[index] = runtimeActionFromCandidateAction(entry, candidate, productions);
        index += 1;
    }
    return action_slice[0..index];
}

fn runtimeActionFromCandidateAction(
    entry: SerializedActionEntry,
    action: actions.ParseAction,
    productions: []const SerializedProductionInfo,
) SerializedParseAction {
    var runtime_action = runtimeActionFromParseAction(action, productions);
    switch (action) {
        .shift => if (runtime_action.kind == .shift) {
            runtime_action.extra = entry.extra;
            runtime_action.repetition = entry.repetition;
        },
        else => {},
    }
    return runtime_action;
}

fn runtimeActionsFromParseActionSliceAlloc(
    allocator: std.mem.Allocator,
    values: []const actions.ParseAction,
    productions: []const SerializedProductionInfo,
) std.mem.Allocator.Error![]const SerializedParseAction {
    const action_slice = try allocator.alloc(SerializedParseAction, values.len);
    for (values, 0..) |value, index| {
        action_slice[index] = runtimeActionFromParseAction(value, productions);
    }
    return action_slice;
}

fn runtimeActionSlicesEql(
    actions_slice: []const SerializedParseAction,
    entry: SerializedActionEntry,
    productions: []const SerializedProductionInfo,
) bool {
    if (entry.candidate_actions.len <= 1) {
        return actions_slice.len == 1 and runtimeActionEql(actions_slice[0], runtimeActionFromActionEntry(entry, productions));
    }

    var cursor: usize = 0;
    for (entry.candidate_actions) |candidate| {
        if (candidate == .shift) continue;
        if (cursor >= actions_slice.len) return false;
        if (!runtimeActionEql(actions_slice[cursor], runtimeActionFromCandidateAction(entry, candidate, productions))) return false;
        cursor += 1;
    }
    for (entry.candidate_actions) |candidate| {
        if (candidate != .shift) continue;
        if (cursor >= actions_slice.len) return false;
        const expected = runtimeActionFromCandidateAction(entry, candidate, productions);
        if (!runtimeActionEql(actions_slice[cursor], expected)) return false;
        cursor += 1;
    }
    return cursor == actions_slice.len;
}

fn actionEntryIsReusable(
    entry: SerializedActionEntry,
    productions: []const SerializedProductionInfo,
) bool {
    if (entry.candidate_actions.len <= 1) {
        return entry.reusable and runtimeActionFromActionEntry(entry, productions).kind != .recover;
    }
    if (!entry.reusable) return false;
    for (entry.candidate_actions) |candidate| {
        if (runtimeActionFromCandidateAction(entry, candidate, productions).kind == .recover) return false;
    }
    return true;
}

fn runtimeActionSliceEqlParseActions(
    actions_slice: []const SerializedParseAction,
    values: []const actions.ParseAction,
    productions: []const SerializedProductionInfo,
) bool {
    if (actions_slice.len != values.len) return false;
    for (actions_slice, values) |serialized_action, value| {
        if (!runtimeActionEql(serialized_action, runtimeActionFromParseAction(value, productions))) return false;
    }
    return true;
}

fn actionEntryHasShift(entry: SerializedActionEntry) bool {
    if (entry.candidate_actions.len > 1) {
        for (entry.candidate_actions) |candidate| {
            if (candidate == .shift) return true;
        }
        return false;
    }
    return entry.action == .shift;
}

pub fn runtimeActionFromParseAction(
    action: actions.ParseAction,
    productions: []const SerializedProductionInfo,
) SerializedParseAction {
    return switch (action) {
        .shift => |state_id| .{
            .kind = .shift,
            .state = state_id,
        },
        .shift_extra => .{
            .kind = .shift,
            .extra = true,
        },
        .reduce => |production_id| blk: {
            const production = if (production_id < productions.len)
                productions[production_id]
            else
                SerializedProductionInfo{ .lhs = 0, .child_count = 0, .dynamic_precedence = 0 };
            break :blk .{
                .kind = .reduce,
                .child_count = production.child_count,
                .symbol = .{ .non_terminal = production.lhs },
                .dynamic_precedence = production.dynamic_precedence,
                .production_id = production.production_info_id orelse @intCast(@min(production_id, std.math.maxInt(u16))),
            };
        },
        .accept => .{
            .kind = .accept,
        },
    };
}

fn parseActionListIndexForRuntimeAction(
    entries: []const SerializedParseActionListEntry,
    action: SerializedParseAction,
) ?u16 {
    for (entries) |entry| {
        if (!entry.reusable) continue;
        if (entry.actions.len != 1) continue;
        if (serializedParseActionEql(entry.actions[0], action)) return entry.index;
    }
    return null;
}

fn parseActionListIndexForRuntimeActionSlice(
    entries: []const SerializedParseActionListEntry,
    action_slice: []const SerializedParseAction,
) ?u16 {
    for (entries) |entry| {
        if (!entry.reusable) continue;
        if (serializedParseActionSlicesEql(entry.actions, action_slice)) return entry.index;
    }
    return null;
}

fn parseActionListEntryByIndex(
    entries: []const SerializedParseActionListEntry,
    index: u16,
) ?SerializedParseActionListEntry {
    for (entries) |entry| {
        if (entry.index == index) return entry;
    }
    return null;
}

fn serializedParseActionSlicesEql(left: []const SerializedParseAction, right: []const SerializedParseAction) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_action, right_action| {
        if (!serializedParseActionEql(left_action, right_action)) return false;
    }
    return true;
}

fn serializedParseActionEql(left: SerializedParseAction, right: SerializedParseAction) bool {
    if (left.kind != right.kind) return false;
    return switch (left.kind) {
        .shift => left.state == right.state and
            left.extra == right.extra and
            left.repetition == right.repetition,
        .reduce => left.child_count == right.child_count and
            symbolRefEql(left.symbol, right.symbol) and
            left.dynamic_precedence == right.dynamic_precedence and
            left.production_id == right.production_id,
        .accept, .recover => true,
    };
}

fn hashSymbolRef(hasher: *std.hash.Wyhash, symbol: syntax_ir.SymbolRef) void {
    const tag: u8 = switch (symbol) {
        .non_terminal => 0,
        .terminal => 1,
        .external => 2,
        .end => 3,
    };
    hasher.update(std.mem.asBytes(&tag));
    switch (symbol) {
        .non_terminal => |index| hasher.update(std.mem.asBytes(&index)),
        .terminal => |index| hasher.update(std.mem.asBytes(&index)),
        .external => |index| hasher.update(std.mem.asBytes(&index)),
        .end => {},
    }
}

fn appendUniqueSymbolRef(
    symbols: *std.array_list.Managed(syntax_ir.SymbolRef),
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error!void {
    for (symbols.items) |existing| {
        if (symbolRefEql(existing, symbol)) return;
    }
    try symbols.append(symbol);
}

fn buildProductionSerializationAlloc(
    allocator: std.mem.Allocator,
    productions: []const build.ProductionInfo,
) std.mem.Allocator.Error!ProductionSerialization {
    return try buildProductionSerializationForUsedAlloc(allocator, productions, null);
}

fn buildProductionSerializationForUsedAlloc(
    allocator: std.mem.Allocator,
    productions: []const build.ProductionInfo,
    maybe_used_productions: ?[]const bool,
) std.mem.Allocator.Error!ProductionSerialization {
    const raw_infos = try allocator.alloc(SerializedProductionInfo, productions.len);
    var metadata = std.ArrayListUnmanaged(ProductionMetadata).empty;
    defer {
        for (metadata.items) |entry| {
            allocator.free(entry.aliases);
            allocator.free(entry.fields);
        }
        metadata.deinit(allocator);
    }

    var field_names = std.array_list.Managed(SerializedFieldName).init(allocator);
    defer field_names.deinit();
    var non_terminal_aliases = std.ArrayListUnmanaged(SerializedAliasEntry).empty;

    const variable_fields = try buildInheritedFieldNamesAlloc(allocator, productions);
    defer {
        for (variable_fields) |fields| allocator.free(fields);
        allocator.free(variable_fields);
    }
    try populateSortedProductionFieldNamesAlloc(allocator, &field_names, productions, variable_fields);

    for (productions, 0..) |production, production_id| {
        const requested_for_metadata = if (maybe_used_productions) |used_productions|
            production_id < used_productions.len and used_productions[production_id]
        else
            true;
        const production_is_used = requested_for_metadata and production.production_metadata_eligible;
        if (!production_is_used) {
            raw_infos[production_id] = .{
                .lhs = production.lhs,
                .child_count = @intCast(@min(production.steps.len, std.math.maxInt(u8))),
                .dynamic_precedence = @intCast(std.math.clamp(production.dynamic_precedence, std.math.minInt(i16), std.math.maxInt(i16))),
            };
            continue;
        }

        const current = try buildProductionMetadataAlloc(allocator, productions, variable_fields, &field_names, production);
        errdefer {
            allocator.free(current.aliases);
            allocator.free(current.fields);
        }
        for (current.aliases) |alias| {
            try non_terminal_aliases.append(allocator, alias);
        }

        const production_info_id = if (findProductionMetadata(metadata.items, current)) |existing| blk: {
            allocator.free(current.aliases);
            allocator.free(current.fields);
            break :blk existing;
        } else blk: {
            const new_id = metadata.items.len;
            try metadata.append(allocator, current);
            break :blk new_id;
        };

        raw_infos[production_id] = .{
            .lhs = production.lhs,
            .child_count = @intCast(@min(production.steps.len, std.math.maxInt(u8))),
            .dynamic_precedence = @intCast(std.math.clamp(production.dynamic_precedence, std.math.minInt(i16), std.math.maxInt(i16))),
            .production_info_id = @intCast(@min(production_info_id, std.math.maxInt(u16))),
        };
    }

    for (productions, 0..) |production, production_id| {
        if (raw_infos[production_id].production_info_id != null) continue;
        const requested_for_metadata = if (maybe_used_productions) |used_productions|
            production_id < used_productions.len and used_productions[production_id]
        else
            true;
        if (!requested_for_metadata) continue;

        const current = try buildProductionMetadataAlloc(allocator, productions, variable_fields, &field_names, production);
        defer {
            allocator.free(current.aliases);
            allocator.free(current.fields);
        }
        if (findProductionMetadata(metadata.items, current)) |existing| {
            raw_infos[production_id].production_info_id = @intCast(@min(existing, std.math.maxInt(u16)));
        }
    }

    var aliases = std.ArrayListUnmanaged(SerializedAliasEntry).empty;
    for (metadata.items, 0..) |entry, production_info_id| {
        for (entry.aliases) |alias| {
            try aliases.append(allocator, .{
                .production_id = @intCast(production_info_id),
                .step_index = alias.step_index,
                .original_symbol = alias.original_symbol,
                .name = alias.name,
                .named = alias.named,
            });
        }
    }

    var field_entries = std.array_list.Managed(SerializedFieldMapEntry).init(allocator);
    defer field_entries.deinit();
    var field_slices = std.ArrayListUnmanaged(SerializedFieldMapSlice).empty;
    var field_rows = std.ArrayListUnmanaged(FieldMapRow).empty;
    defer {
        field_slices.deinit(allocator);
        field_rows.deinit(allocator);
    }

    for (metadata.items) |entry| {
        if (entry.fields.len == 0) {
            try field_slices.append(allocator, .{ .index = 0, .length = 0 });
            continue;
        }
        if (findFieldMapRow(field_rows.items, entry.fields)) |row| {
            try field_slices.append(allocator, .{
                .index = row.index,
                .length = @intCast(@min(entry.fields.len, std.math.maxInt(u16))),
            });
            continue;
        }

        const start = field_entries.items.len;
        try field_entries.appendSlice(entry.fields);
        const row = FieldMapRow{
            .index = @intCast(@min(start, std.math.maxInt(u16))),
            .fields = entry.fields,
        };
        try field_rows.append(allocator, row);
        try field_slices.append(allocator, .{
            .index = row.index,
            .length = @intCast(@min(entry.fields.len, std.math.maxInt(u16))),
        });
    }

    return .{
        .productions = raw_infos,
        .production_id_count = metadata.items.len,
        .alias_sequences = try aliases.toOwnedSlice(allocator),
        .non_terminal_aliases = try non_terminal_aliases.toOwnedSlice(allocator),
        .field_map = .{
            .names = try field_names.toOwnedSlice(),
            .entries = try field_entries.toOwnedSlice(),
            .slices = try field_slices.toOwnedSlice(allocator),
        },
    };
}

fn buildProductionMetadataAlloc(
    allocator: std.mem.Allocator,
    productions: []const build.ProductionInfo,
    variable_fields: []const []const []const u8,
    field_names: *std.array_list.Managed(SerializedFieldName),
    production: build.ProductionInfo,
) std.mem.Allocator.Error!ProductionMetadata {
    var aliases = std.ArrayListUnmanaged(SerializedAliasEntry).empty;
    errdefer aliases.deinit(allocator);
    var fields = std.array_list.Managed(SerializedFieldMapEntry).init(allocator);
    defer fields.deinit();

    for (production.steps, 0..) |step, step_index| {
        if (step.alias) |alias| {
            try aliases.append(allocator, .{
                .production_id = 0,
                .step_index = @intCast(step_index),
                .original_symbol = step.symbol,
                .name = alias.value,
                .named = alias.named,
            });
        }

        const child_index: u8 = @intCast(@min(step_index, std.math.maxInt(u8)));
        if (step.field_name) |field_name| {
            try appendFieldMapEntry(field_names, &fields, field_name, child_index, false);
        }
        switch (step.symbol) {
            .non_terminal => |variable_index| {
                if (variable_index >= variable_fields.len) continue;
                if (variableIsVisible(productions, variable_index)) continue;
                for (variable_fields[variable_index]) |field_name| {
                    try appendFieldMapEntry(field_names, &fields, field_name, child_index, true);
                }
            },
            else => {},
        }
    }

    std.mem.sort(SerializedFieldMapEntry, fields.items, {}, fieldMapEntryLessThan);
    const alias_slice = try aliases.toOwnedSlice(allocator);
    errdefer allocator.free(alias_slice);

    return .{
        .aliases = alias_slice,
        .fields = try fields.toOwnedSlice(),
    };
}

fn populateSortedProductionFieldNamesAlloc(
    allocator: std.mem.Allocator,
    field_names: *std.array_list.Managed(SerializedFieldName),
    productions: []const build.ProductionInfo,
    variable_fields: []const []const []const u8,
) std.mem.Allocator.Error!void {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    defer names.deinit(allocator);

    for (productions) |production| {
        for (production.steps) |step| {
            if (step.field_name) |field_name| try appendUniqueFieldNameSlice(allocator, &names, field_name);
            switch (step.symbol) {
                .non_terminal => |variable_index| {
                    if (variable_index >= variable_fields.len) continue;
                    if (variableIsVisible(productions, variable_index)) continue;
                    for (variable_fields[variable_index]) |field_name| {
                        try appendUniqueFieldNameSlice(allocator, &names, field_name);
                    }
                },
                else => {},
            }
        }
    }

    std.mem.sort([]const u8, names.items, {}, stringSliceLessThan);
    for (names.items, 0..) |name, index| {
        try field_names.append(.{
            .id = @intCast(@min(index + 1, std.math.maxInt(u16))),
            .name = name,
        });
    }
}

fn appendUniqueFieldNameSlice(
    allocator: std.mem.Allocator,
    names: *std.ArrayListUnmanaged([]const u8),
    field_name: []const u8,
) std.mem.Allocator.Error!void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, field_name)) return;
    }
    try names.append(allocator, field_name);
}

fn stringSliceLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn findProductionMetadata(entries: []const ProductionMetadata, candidate: ProductionMetadata) ?usize {
    for (entries, 0..) |entry, index| {
        if (productionMetadataEql(entry, candidate)) return index;
    }
    return null;
}

fn productionMetadataEql(left: ProductionMetadata, right: ProductionMetadata) bool {
    return aliasEntrySlicesEql(left.aliases, right.aliases) and fieldMapEntrySlicesEql(left.fields, right.fields);
}

fn aliasEntrySlicesEql(left: []const SerializedAliasEntry, right: []const SerializedAliasEntry) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (left_entry.step_index != right_entry.step_index) return false;
        if (left_entry.named != right_entry.named) return false;
        if (!std.mem.eql(u8, left_entry.name, right_entry.name)) return false;
    }
    return true;
}

fn fieldMapEntrySlicesEql(left: []const SerializedFieldMapEntry, right: []const SerializedFieldMapEntry) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (left_entry.field_id != right_entry.field_id) return false;
        if (left_entry.child_index != right_entry.child_index) return false;
        if (left_entry.inherited != right_entry.inherited) return false;
    }
    return true;
}

fn findFieldMapRow(rows: []const FieldMapRow, fields: []const SerializedFieldMapEntry) ?FieldMapRow {
    for (rows) |row| {
        if (fieldMapEntrySlicesEql(row.fields, fields)) return row;
    }
    return null;
}

fn fieldMapEntryLessThan(_: void, left: SerializedFieldMapEntry, right: SerializedFieldMapEntry) bool {
    if (left.field_id != right.field_id) return left.field_id < right.field_id;
    if (left.child_index != right.child_index) return left.child_index < right.child_index;
    return @intFromBool(left.inherited) < @intFromBool(right.inherited);
}

fn buildFieldMapAlloc(
    allocator: std.mem.Allocator,
    productions: []const build.ProductionInfo,
) std.mem.Allocator.Error!SerializedFieldMap {
    var names = std.array_list.Managed(SerializedFieldName).init(allocator);
    defer names.deinit();
    var entries = std.array_list.Managed(SerializedFieldMapEntry).init(allocator);
    defer entries.deinit();
    const variable_fields = try buildInheritedFieldNamesAlloc(allocator, productions);
    defer {
        for (variable_fields) |fields| allocator.free(fields);
        allocator.free(variable_fields);
    }

    const slices = try allocator.alloc(SerializedFieldMapSlice, productions.len);
    for (productions, 0..) |production, production_id| {
        const start = entries.items.len;
        for (production.steps, 0..) |step, step_index| {
            const child_index: u8 = @intCast(@min(step_index, std.math.maxInt(u8)));
            if (step.field_name) |field_name| {
                try appendFieldMapEntry(&names, &entries, field_name, child_index, step.field_inherited);
            }
            switch (step.symbol) {
                .non_terminal => |variable_index| {
                    if (variable_index >= variable_fields.len) continue;
                    if (variableIsVisible(productions, variable_index)) continue;
                    for (variable_fields[variable_index]) |field_name| {
                        try appendFieldMapEntry(&names, &entries, field_name, child_index, true);
                    }
                },
                else => {},
            }
        }
        slices[production_id] = .{
            .index = @intCast(@min(start, std.math.maxInt(u16))),
            .length = @intCast(@min(entries.items.len - start, std.math.maxInt(u16))),
        };
    }

    return .{
        .names = try names.toOwnedSlice(),
        .entries = try entries.toOwnedSlice(),
        .slices = slices,
    };
}

fn appendFieldMapEntry(
    names: *std.array_list.Managed(SerializedFieldName),
    entries: *std.array_list.Managed(SerializedFieldMapEntry),
    field_name: []const u8,
    child_index: u8,
    inherited: bool,
) std.mem.Allocator.Error!void {
    const field_id = try internFieldName(names, field_name);
    try entries.append(.{
        .field_id = field_id,
        .child_index = child_index,
        .inherited = inherited,
    });
}

fn buildInheritedFieldNamesAlloc(
    allocator: std.mem.Allocator,
    productions: []const build.ProductionInfo,
) std.mem.Allocator.Error![]const []const []const u8 {
    const variable_count = variableCount(productions);
    const fields = try allocator.alloc([]const []const u8, variable_count);
    errdefer allocator.free(fields);
    for (fields) |*entry| entry.* = &.{};

    const states = try allocator.alloc(FieldVisitState, variable_count);
    defer allocator.free(states);
    @memset(states, .pending);

    for (0..variable_count) |variable_index| {
        try collectInheritedFieldNamesForVariable(allocator, productions, fields, states, @intCast(variable_index));
    }

    return fields;
}

fn collectInheritedFieldNamesForVariable(
    allocator: std.mem.Allocator,
    productions: []const build.ProductionInfo,
    fields: [][]const []const u8,
    states: []FieldVisitState,
    variable_index: u32,
) std.mem.Allocator.Error!void {
    const index: usize = @intCast(variable_index);
    switch (states[index]) {
        .done, .visiting => return,
        .pending => {},
    }

    states[index] = .visiting;
    var names = std.array_list.Managed([]const u8).init(allocator);
    defer names.deinit();

    for (productions) |production| {
        if (production.augmented or production.lhs != variable_index) continue;
        for (production.steps) |step| {
            if (step.field_name) |field_name| {
                if (!step.field_inherited) try appendUniqueFieldName(&names, field_name);
            }
            switch (step.symbol) {
                .non_terminal => |child_index| {
                    if (child_index >= fields.len) continue;
                    if (variableIsVisible(productions, child_index)) continue;
                    try collectInheritedFieldNamesForVariable(allocator, productions, fields, states, child_index);
                    for (fields[child_index]) |field_name| {
                        try appendUniqueFieldName(&names, field_name);
                    }
                },
                else => {},
            }
        }
    }

    fields[index] = try names.toOwnedSlice();
    states[index] = .done;
}

fn appendUniqueFieldName(
    names: *std.array_list.Managed([]const u8),
    field_name: []const u8,
) std.mem.Allocator.Error!void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, field_name)) return;
    }
    try names.append(field_name);
}

fn variableCount(productions: []const build.ProductionInfo) usize {
    var count: usize = 0;
    for (productions) |production| {
        if (production.augmented) continue;
        const index: usize = @intCast(production.lhs);
        count = @max(count, index + 1);
    }
    return count;
}

fn variableIsVisible(productions: []const build.ProductionInfo, variable_index: u32) bool {
    for (productions) |production| {
        if (production.augmented or production.lhs != variable_index) continue;
        return production.lhs_kind == .named or production.lhs_kind == .anonymous;
    }
    return true;
}

fn internFieldName(
    names: *std.array_list.Managed(SerializedFieldName),
    name: []const u8,
) std.mem.Allocator.Error!u16 {
    for (names.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.id;
    }

    const id: u16 = @intCast(names.items.len + 1);
    try names.append(.{
        .id = id,
        .name = name,
    });
    return id;
}

fn buildSupertypeMapAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) std.mem.Allocator.Error!SerializedSupertypeMap {
    var symbols = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
    defer symbols.deinit();
    var entries = std.array_list.Managed(SerializedSupertypeMapEntry).init(allocator);
    defer entries.deinit();

    const slices = try allocator.alloc(SerializedSupertypeMapSlice, prepared.supertype_symbols.len);
    for (prepared.supertype_symbols, 0..) |prepared_symbol, slice_index| {
        const supertype = symbolRefFromPreparedSymbol(prepared_symbol);
        try symbols.append(supertype);
        const start = entries.items.len;
        switch (prepared_symbol.kind) {
            .non_terminal => {
                if (prepared_symbol.index < prepared.variables.len) {
                    const rule_id = prepared.variables[prepared_symbol.index].rule;
                    try collectSupertypeEntriesFromRule(allocator, &entries, prepared.rules, rule_id, null);
                }
            },
            .external => {},
        }
        std.mem.sort(SerializedSupertypeMapEntry, entries.items[start..], {}, supertypeEntryLessThan);
        slices[slice_index] = .{
            .supertype = supertype,
            .index = @intCast(@min(start, std.math.maxInt(u16))),
            .length = @intCast(@min(entries.items.len - start, std.math.maxInt(u16))),
        };
    }

    std.mem.sort(syntax_ir.SymbolRef, symbols.items, {}, symbolRefLessThan);
    std.mem.sort(SerializedSupertypeMapSlice, slices, {}, supertypeSliceLessThan);
    return .{
        .symbols = try symbols.toOwnedSlice(),
        .entries = try entries.toOwnedSlice(),
        .slices = slices,
    };
}

fn buildExtractedSupertypeMapAlloc(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
) std.mem.Allocator.Error!SerializedSupertypeMap {
    var symbols = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
    defer symbols.deinit();
    var entries = std.array_list.Managed(SerializedSupertypeMapEntry).init(allocator);
    defer entries.deinit();

    const slices = try allocator.alloc(SerializedSupertypeMapSlice, syntax.supertype_symbols.len);
    for (syntax.supertype_symbols, 0..) |supertype, slice_index| {
        try symbols.append(supertype);
        const start = entries.items.len;
        switch (supertype) {
            .non_terminal => |index| {
                if (index < syntax.variables.len) {
                    try collectSupertypeEntriesFromProductions(&entries, syntax.variables[index].productions, syntax.variables_to_inline);
                }
            },
            else => {},
        }
        std.mem.sort(SerializedSupertypeMapEntry, entries.items[start..], {}, supertypeEntryLessThan);
        slices[slice_index] = .{
            .supertype = supertype,
            .index = @intCast(@min(start, std.math.maxInt(u16))),
            .length = @intCast(@min(entries.items.len - start, std.math.maxInt(u16))),
        };
    }

    std.mem.sort(syntax_ir.SymbolRef, symbols.items, {}, symbolRefLessThan);
    std.mem.sort(SerializedSupertypeMapSlice, slices, {}, supertypeSliceLessThan);
    return .{
        .symbols = try symbols.toOwnedSlice(),
        .entries = try entries.toOwnedSlice(),
        .slices = slices,
    };
}

const PendingSupertypeAlias = struct {
    name: []const u8,
    named: bool,
};

fn collectSupertypeEntriesFromRule(
    allocator: std.mem.Allocator,
    entries: *std.array_list.Managed(SerializedSupertypeMapEntry),
    rules: []const ir_rules.Rule,
    rule_id: ir_rules.RuleId,
    alias: ?PendingSupertypeAlias,
) std.mem.Allocator.Error!void {
    switch (rules[rule_id]) {
        .symbol => |symbol| try appendUniqueSupertypeEntry(entries, .{
            .symbol = symbolRefFromPreparedSymbol(symbol),
            .alias_name = if (alias) |value| value.name else null,
            .alias_named = if (alias) |value| value.named else false,
        }),
        .choice => |members| for (members) |member| {
            try collectSupertypeEntriesFromRule(allocator, entries, rules, member, alias);
        },
        .seq => |members| {
            if (members.len == 1) {
                try collectSupertypeEntriesFromRule(allocator, entries, rules, members[0], alias);
            }
        },
        .metadata => |metadata| {
            const next_alias = if (metadata.data.alias) |value|
                PendingSupertypeAlias{ .name = value.value, .named = value.named }
            else
                alias;
            try collectSupertypeEntriesFromRule(allocator, entries, rules, metadata.inner, next_alias);
        },
        else => {},
    }
}

fn collectSupertypeEntriesFromProductions(
    entries: *std.array_list.Managed(SerializedSupertypeMapEntry),
    productions: []const syntax_ir.Production,
    variables_to_inline: []const syntax_ir.SymbolRef,
) std.mem.Allocator.Error!void {
    for (productions) |production| {
        if (production.steps.len != 1) continue;
        const step = production.steps[0];
        if (symbolRefIn(variables_to_inline, step.symbol)) continue;
        try appendUniqueSupertypeEntry(entries, .{
            .symbol = step.symbol,
            .alias_name = if (step.alias) |alias| alias.value else null,
            .alias_named = if (step.alias) |alias| alias.named else false,
        });
    }
}

fn appendUniqueSupertypeEntry(
    entries: *std.array_list.Managed(SerializedSupertypeMapEntry),
    entry: SerializedSupertypeMapEntry,
) std.mem.Allocator.Error!void {
    for (entries.items) |existing| {
        if (supertypeEntryEql(existing, entry)) return;
    }
    try entries.append(entry);
}

fn supertypeEntryEql(left: SerializedSupertypeMapEntry, right: SerializedSupertypeMapEntry) bool {
    if (!symbolRefEql(left.symbol, right.symbol)) return false;
    if (left.alias_named != right.alias_named) return false;
    if (left.alias_name == null or right.alias_name == null) return left.alias_name == null and right.alias_name == null;
    return std.mem.eql(u8, left.alias_name.?, right.alias_name.?);
}

fn supertypeEntryLessThan(_: void, left: SerializedSupertypeMapEntry, right: SerializedSupertypeMapEntry) bool {
    const left_symbol_key = symbolSortKey(left.symbol);
    const right_symbol_key = symbolSortKey(right.symbol);
    if (left_symbol_key != right_symbol_key) return left_symbol_key < right_symbol_key;
    const left_key = if (left.alias_name) |name| name else "";
    const right_key = if (right.alias_name) |name| name else "";
    if (!std.mem.eql(u8, left_key, right_key)) return std.mem.lessThan(u8, left_key, right_key);
    if (left.alias_named != right.alias_named) return left.alias_named and !right.alias_named;
    return symbolSortKey(left.symbol) < symbolSortKey(right.symbol);
}

fn supertypeSliceLessThan(_: void, left: SerializedSupertypeMapSlice, right: SerializedSupertypeMapSlice) bool {
    return symbolSortKey(left.supertype) < symbolSortKey(right.supertype);
}

pub fn buildReservedWordsAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
) std.mem.Allocator.Error!SerializedReservedWords {
    const keyword_lexical = try buildKeywordLexicalGrammarAlloc(allocator, prepared, lexical);
    defer keyword_lexical.deinit(allocator);

    const sets = try allocator.alloc([]const syntax_ir.SymbolRef, prepared.reserved_word_sets.len + 1);
    var initialized: usize = 0;
    errdefer {
        for (sets[0..initialized]) |set| allocator.free(set);
        allocator.free(sets);
    }

    sets[0] = try allocator.alloc(syntax_ir.SymbolRef, 0);
    initialized += 1;
    var max_size: usize = 0;

    for (prepared.reserved_word_sets, 0..) |reserved_set, index| {
        var members = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
        defer members.deinit();

        for (reserved_set.members) |member_rule| {
            if (keywordTerminalRefForRule(prepared, keyword_lexical.lexical, member_rule)) |symbol| {
                try appendUniqueSymbolRef(&members, symbol);
            }
        }
        std.mem.sort(syntax_ir.SymbolRef, members.items, {}, symbolRefLessThan);
        sets[index + 1] = try members.toOwnedSlice();
        initialized += 1;
        max_size = @max(max_size, sets[index + 1].len);
    }

    return .{
        .sets = sets,
        .max_size = @intCast(@min(max_size, std.math.maxInt(u16))),
    };
}

fn terminalRefForLexicalRule(
    lexical: lexical_ir.LexicalGrammar,
    rule_id: ir_rules.RuleId,
) ?syntax_ir.SymbolRef {
    for (lexical.variables, 0..) |variable, index| {
        if (variable.rule == rule_id) return .{ .terminal = @intCast(index) };
    }
    return null;
}

const KeywordLexicalGrammar = struct {
    lexical: lexical_ir.LexicalGrammar,
    owned_variables: []const lexical_ir.LexicalVariable = &.{},

    fn deinit(self: KeywordLexicalGrammar, allocator: std.mem.Allocator) void {
        allocator.free(self.owned_variables);
    }
};

fn buildKeywordLexicalGrammarAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
) std.mem.Allocator.Error!KeywordLexicalGrammar {
    var additions = std.array_list.Managed(lexical_ir.LexicalVariable).init(allocator);
    defer additions.deinit();

    for (prepared.reserved_word_sets) |reserved_set| {
        for (reserved_set.members) |member_rule| {
            if (keywordTerminalRefForRuleWithAdditions(prepared, lexical, additions.items, member_rule) != null) continue;
            const literal = directStringRuleValue(prepared.rules, member_rule) orelse continue;
            try additions.append(.{
                .name = literal,
                .kind = .anonymous,
                .rule = member_rule,
                .source_kind = .string,
            });
        }
    }

    if (additions.items.len == 0) {
        return .{ .lexical = lexical };
    }

    const variables = try allocator.alloc(lexical_ir.LexicalVariable, lexical.variables.len + additions.items.len);
    @memcpy(variables[0..lexical.variables.len], lexical.variables);
    @memcpy(variables[lexical.variables.len..], additions.items);
    return .{
        .lexical = .{
            .variables = variables,
            .separators = lexical.separators,
        },
        .owned_variables = variables,
    };
}

fn keywordTerminalRefForRule(
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    rule_id: ir_rules.RuleId,
) ?syntax_ir.SymbolRef {
    if (terminalRefForLexicalRule(lexical, rule_id)) |symbol| return symbol;
    const literal = directStringRuleValue(prepared.rules, rule_id) orelse return null;
    for (lexical.variables, 0..) |variable, index| {
        const variable_literal = directStringRuleValue(prepared.rules, variable.rule) orelse continue;
        if (std.mem.eql(u8, literal, variable_literal)) return .{ .terminal = @intCast(index) };
    }
    return null;
}

fn keywordTerminalRefForRuleWithAdditions(
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    additions: []const lexical_ir.LexicalVariable,
    rule_id: ir_rules.RuleId,
) ?syntax_ir.SymbolRef {
    if (keywordTerminalRefForRule(prepared, lexical, rule_id)) |symbol| return symbol;
    const literal = directStringRuleValue(prepared.rules, rule_id) orelse return null;
    for (additions, 0..) |variable, index| {
        const variable_literal = directStringRuleValue(prepared.rules, variable.rule) orelse continue;
        if (std.mem.eql(u8, literal, variable_literal)) {
            return .{ .terminal = @intCast(lexical.variables.len + index) };
        }
    }
    return null;
}

fn directStringRuleValue(rules: []const ir_rules.Rule, rule_id: ir_rules.RuleId) ?[]const u8 {
    if (rule_id >= rules.len) return null;
    return switch (rules[@intCast(rule_id)]) {
        .string => |value| value,
        .metadata => |metadata| directStringRuleValue(rules, metadata.inner),
        else => null,
    };
}

fn hasRepetitionShift(
    serialized_states: []const SerializedState,
    parse_states: []const state.ParseState,
    productions: []const build.ProductionInfo,
    first_sets: ?first.FirstSets,
) bool {
    for (serialized_states, 0..) |serialized_state, state_index| {
        if (state_index >= parse_states.len) return false;
        for (serialized_state.actions) |entry| {
            if (entry.action == .shift and
                shiftHasRepeatAuxiliaryConflict(parse_states[state_index], productions, first_sets, entry.symbol))
            {
                return true;
            }
        }
    }
    return false;
}

fn shiftHasRepeatAuxiliaryConflict(
    parse_state: state.ParseState,
    productions: []const build.ProductionInfo,
    first_sets: ?first.FirstSets,
    symbol: syntax_ir.SymbolRef,
) bool {
    if (resolution.hasSameAuxiliaryRepeatConflictWithFirstSets(productions, parse_state, first_sets, symbol)) return true;

    var repeat_lhs: ?u32 = null;
    var saw_conflict = false;

    for (parse_state.items) |entry| {
        if (!item.containsLookahead(entry.lookaheads, symbol)) continue;
        if (entry.item.production_id >= productions.len) continue;
        const production = productions[entry.item.production_id];
        if (entry.item.step_index != production.steps.len) continue;

        if (!production.lhs_is_repeat_auxiliary) return false;
        if (repeat_lhs) |lhs| {
            if (lhs != production.lhs) return false;
        } else {
            repeat_lhs = production.lhs;
        }
        saw_conflict = true;
    }

    return saw_conflict;
}

fn buildKeywordTerminalSetAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
) std.mem.Allocator.Error![]bool {
    const terminal_set = try allocator.alloc(bool, lexical.variables.len);
    @memset(terminal_set, false);
    for (prepared.reserved_word_sets) |reserved_set| {
        for (reserved_set.members) |member_rule| {
            if (keywordTerminalRefForRule(prepared, lexical, member_rule)) |symbol| switch (symbol) {
                .terminal => |index| {
                    if (index < terminal_set.len) terminal_set[index] = true;
                },
                else => {},
            };
        }
    }
    return terminal_set;
}

fn buildKeywordLexTableTerminalSetAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
) std.mem.Allocator.Error![]bool {
    const terminal_set = try buildKeywordTerminalSetAlloc(allocator, prepared, lexical);
    errdefer allocator.free(terminal_set);

    for (lexical.variables, 0..) |variable, index| {
        if (variable.source_kind != .string) continue;
        const literal = directStringRuleValue(prepared.rules, variable.rule) orelse continue;
        if (!literalCanBeKeyword(literal)) continue;
        terminal_set[index] = true;
    }

    return terminal_set;
}

fn literalCanBeKeyword(literal: []const u8) bool {
    if (literal.len == 0) return false;
    for (literal, 0..) |byte, index| {
        const valid = std.ascii.isAlphabetic(byte) or byte == '_' or
            (index > 0 and std.ascii.isDigit(byte));
        if (!valid) return false;
    }
    return true;
}

fn countUnmappedReservedWords(
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
) usize {
    var count: usize = 0;
    for (prepared.reserved_word_sets) |reserved_set| {
        for (reserved_set.members) |member_rule| {
            if (keywordTerminalRefForRule(prepared, lexical, member_rule) == null) count += 1;
        }
    }
    return count;
}

const BuiltExternalScannerStates = struct {
    states: []const []const bool,
    state_ids: []const u16,
};

fn buildExternalScannerStatesAlloc(
    allocator: std.mem.Allocator,
    symbols: []const syntax_ir.SymbolRef,
    states: []const SerializedState,
    extra_symbols: []const syntax_ir.SymbolRef,
) std.mem.Allocator.Error!BuiltExternalScannerStates {
    var unique_states = std.array_list.Managed([]const bool).init(allocator);
    defer unique_states.deinit();
    const state_ids = try allocator.alloc(u16, states.len);
    errdefer allocator.free(state_ids);

    const empty_set = try allocator.alloc(bool, symbols.len);
    @memset(empty_set, false);
    try unique_states.append(empty_set);

    for (states, 0..) |serialized_state, state_index| {
        const set = try allocator.alloc(bool, symbols.len);
        @memset(set, false);
        for (serialized_state.actions) |entry| {
            const symbol_index = externalScannerSymbolIndex(symbols, entry.symbol) orelse continue;
            set[symbol_index] = true;
        }
        for (extra_symbols) |extra_symbol| {
            const symbol_index = externalScannerSymbolIndex(symbols, extra_symbol) orelse continue;
            set[symbol_index] = true;
        }

        if (findBoolSet(unique_states.items, set)) |existing_index| {
            allocator.free(set);
            state_ids[state_index] = @intCast(existing_index);
            continue;
        }

        state_ids[state_index] = @intCast(unique_states.items.len);
        try unique_states.append(set);
    }

    return .{
        .states = try unique_states.toOwnedSlice(),
        .state_ids = state_ids,
    };
}

fn buildLexModesWithExternalStatesAlloc(
    allocator: std.mem.Allocator,
    lex_modes: []const lexer_serialize.SerializedLexMode,
    external_state_ids: []const u16,
) std.mem.Allocator.Error![]const lexer_serialize.SerializedLexMode {
    const result = try allocator.alloc(lexer_serialize.SerializedLexMode, lex_modes.len);
    for (lex_modes, 0..) |mode, index| {
        result[index] = mode;
        if (index < external_state_ids.len) {
            result[index].external_lex_state = external_state_ids[index];
        }
    }
    return result;
}

fn externalScannerSymbolIndex(symbols: []const syntax_ir.SymbolRef, symbol: syntax_ir.SymbolRef) ?usize {
    for (symbols, 0..) |candidate, index| {
        if (symbolRefEql(candidate, symbol)) return index;
    }
    switch (symbol) {
        .external => |index| {
            if (index < symbols.len) return index;
        },
        else => {},
    }
    return null;
}

fn symbolRefIn(symbols: []const syntax_ir.SymbolRef, symbol: syntax_ir.SymbolRef) bool {
    return for (symbols) |candidate| {
        if (symbolRefEql(candidate, symbol)) break true;
    } else false;
}

fn isNonTerminalExtraEndState(
    parse_state: state.ParseState,
    productions: []const build.ProductionInfo,
    extra_symbols: []const syntax_ir.SymbolRef,
) bool {
    for (parse_state.items) |entry| {
        if (!item.containsLookahead(entry.lookaheads, .{ .end = {} })) continue;
        if (entry.item.production_id >= productions.len) continue;
        const production = productions[entry.item.production_id];
        if (entry.item.step_index != production.steps.len) continue;
        if (symbolRefIn(extra_symbols, .{ .non_terminal = production.lhs })) return true;
    }
    return false;
}

fn findBoolSet(sets: []const []const bool, target: []const bool) ?usize {
    for (sets, 0..) |set, index| {
        if (std.mem.eql(bool, set, target)) return index;
    }
    return null;
}

fn symbolRefFromPreparedSymbol(symbol: ir_symbols.SymbolId) syntax_ir.SymbolRef {
    return switch (symbol.kind) {
        .non_terminal => .{ .non_terminal = symbol.index },
        .external => .{ .external = symbol.index },
    };
}

fn symbolRefLessThan(_: void, left: syntax_ir.SymbolRef, right: syntax_ir.SymbolRef) bool {
    return symbolSortKey(left) < symbolSortKey(right);
}

fn symbolSortKey(symbol: syntax_ir.SymbolRef) u64 {
    return switch (symbol) {
        .end => 0,
        .non_terminal => |index| (@as(u64, 1) << 32) | index,
        .terminal => |index| (@as(u64, 2) << 32) | index,
        .external => |index| (@as(u64, 3) << 32) | index,
    };
}

fn collectActionsForState(
    allocator: std.mem.Allocator,
    chosen: []const resolution.ChosenDecisionRef,
    unresolved: []const resolution.UnresolvedDecisionRef,
    parse_state: state.ParseState,
    fragile_tokens: []const bool,
) std.mem.Allocator.Error![]const SerializedActionEntry {
    var count: usize = 0;
    for (chosen) |entry| {
        if (entry.state_id == parse_state.id) count += 1;
    }
    for (unresolved) |entry| {
        if (entry.state_id == parse_state.id and unresolvedReasonIsExpected(entry.reason)) count += 1;
    }

    const entries = try allocator.alloc(SerializedActionEntry, count);
    var index: usize = 0;
    for (chosen) |entry| {
        if (entry.state_id != parse_state.id) continue;
        entries[index] = .{
            .symbol = entry.symbol,
            .action = entry.action,
            .candidate_actions = entry.candidate_actions,
            .extra = shiftActionIsExtra(parse_state.transitions, entry.symbol, entry.action),
            .reusable = serializedActionEntryIsReusable(entry.symbol, fragile_tokens),
        };
        index += 1;
    }
    for (unresolved) |entry| {
        if (entry.state_id != parse_state.id or !unresolvedReasonIsExpected(entry.reason)) continue;
        const action = preferredActionForExpectedConflict(entry.candidate_actions) orelse continue;
        entries[index] = .{
            .symbol = entry.symbol,
            .action = action,
            .candidate_actions = entry.candidate_actions,
            .extra = shiftCandidateIsExtra(parse_state.transitions, entry.symbol, entry.candidate_actions),
            .reusable = serializedActionEntryIsReusable(entry.symbol, fragile_tokens),
        };
        index += 1;
    }
    return entries;
}

fn serializedActionEntryIsReusable(symbol: syntax_ir.SymbolRef, fragile_tokens: []const bool) bool {
    const terminal = switch (symbol) {
        .terminal => |index| index,
        .end, .non_terminal, .external => return true,
    };
    return terminal >= fragile_tokens.len or !fragile_tokens[terminal];
}

fn unresolvedReasonIsExpected(reason: resolution.UnresolvedReason) bool {
    return reason == .auxiliary_repeat or
        reason == .shift_reduce_expected or
        reason == .reduce_reduce_expected;
}

fn preferredActionForExpectedConflict(candidate_actions: []const actions.ParseAction) ?actions.ParseAction {
    for (candidate_actions) |candidate| {
        if (candidate == .shift) return candidate;
    }
    if (candidate_actions.len == 0) return null;
    return candidate_actions[0];
}

fn shiftCandidateIsExtra(
    transitions: []const state.Transition,
    symbol: syntax_ir.SymbolRef,
    candidate_actions: []const actions.ParseAction,
) bool {
    for (candidate_actions) |candidate| {
        if (shiftActionIsExtra(transitions, symbol, candidate)) return true;
    }
    return false;
}

fn shiftActionIsExtra(
    transitions: []const state.Transition,
    symbol: syntax_ir.SymbolRef,
    action: actions.ParseAction,
) bool {
    const target = switch (action) {
        .shift => |state_id| state_id,
        else => return false,
    };
    for (transitions) |transition| {
        if (transition.state == target and transition.extra and symbolRefEql(transition.symbol, symbol)) return true;
    }
    return false;
}

fn collectGotosForState(
    allocator: std.mem.Allocator,
    parse_state: state.ParseState,
) std.mem.Allocator.Error![]const SerializedGotoEntry {
    var count: usize = 0;
    for (parse_state.transitions) |transition| {
        switch (transition.symbol) {
            .non_terminal => count += 1,
            .end, .terminal, .external => {},
        }
    }

    const entries = try allocator.alloc(SerializedGotoEntry, count);
    var index: usize = 0;
    for (parse_state.transitions) |transition| {
        switch (transition.symbol) {
            .non_terminal => {
                entries[index] = .{
                    .symbol = transition.symbol,
                    .state = transition.state,
                };
                index += 1;
            },
            .end, .terminal, .external => {},
        }
    }
    return entries;
}

fn collectUnresolvedForState(
    allocator: std.mem.Allocator,
    unresolved: []const resolution.UnresolvedDecisionRef,
    state_id: state.StateId,
) std.mem.Allocator.Error![]const SerializedUnresolvedEntry {
    var count: usize = 0;
    for (unresolved) |entry| {
        if (entry.state_id == state_id) count += 1;
    }

    const entries = try allocator.alloc(SerializedUnresolvedEntry, count);
    var index: usize = 0;
    for (unresolved) |entry| {
        if (entry.state_id != state_id) continue;
        entries[index] = .{
            .symbol = entry.symbol,
            .reason = entry.reason,
            .candidate_actions = entry.candidate_actions,
        };
        index += 1;
    }
    return entries;
}

fn symbolRefEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
        .end => switch (b) {
            .end => true,
            else => false,
        },
        .non_terminal => |index| switch (b) {
            .non_terminal => |other| index == other,
            else => false,
        },
        .terminal => |index| switch (b) {
            .terminal => |other| index == other,
            else => false,
        },
        .external => |index| switch (b) {
            .external => |other| index == other,
            else => false,
        },
    };
}

fn runtimeActionEql(a: SerializedParseAction, b: SerializedParseAction) bool {
    return a.kind == b.kind and
        a.state == b.state and
        a.extra == b.extra and
        a.repetition == b.repetition and
        a.child_count == b.child_count and
        symbolRefEql(a.symbol, b.symbol) and
        a.dynamic_precedence == b.dynamic_precedence and
        a.production_id == b.production_id;
}

test "attachPreparedMetadataAlloc adds grammar and symbol metadata" {
    const allocator = std.testing.allocator;
    const prepared_symbols = [_]ir_symbols.SymbolInfo{
        .{
            .id = .{ .kind = .non_terminal, .index = 0 },
            .name = "source_file",
            .named = true,
            .visible = true,
            .supertype = true,
        },
        .{
            .id = .{ .kind = .external, .index = 1 },
            .name = "external_token",
            .named = false,
            .visible = false,
            .supertype = false,
        },
    };
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "metadata_fixture",
        .variables = &.{},
        .external_tokens = &.{},
        .rules = &.{},
        .symbols = prepared_symbols[0..],
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = .{ .kind = .external, .index = 1 },
        .reserved_word_sets = &.{},
    };

    const serialized = try attachPreparedMetadataAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
    }, prepared);
    defer allocator.free(serialized.symbols);
    defer deinitSupertypeMap(allocator, serialized.supertype_map);
    defer deinitExternalScanner(allocator, serialized.external_scanner);

    try std.testing.expectEqualStrings("metadata_fixture", serialized.grammar_name);
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, serialized.grammar_version);
    try std.testing.expectEqual(@as(usize, 2), serialized.symbols.len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .non_terminal = 0 }, serialized.symbols[0].ref);
    try std.testing.expectEqualStrings("source_file", serialized.symbols[0].name);
    try std.testing.expect(serialized.symbols[0].named);
    try std.testing.expect(serialized.symbols[0].visible);
    try std.testing.expect(serialized.symbols[0].supertype);
    try std.testing.expectEqual(@as(u16, 0), serialized.symbols[0].public_symbol);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .external = 1 }, serialized.symbols[1].ref);
    try std.testing.expectEqualStrings("external_token", serialized.symbols[1].name);
    try std.testing.expect(!serialized.symbols[1].named);
    try std.testing.expect(!serialized.symbols[1].visible);
    try std.testing.expect(!serialized.symbols[1].supertype);
    try std.testing.expectEqual(@as(u16, 1), serialized.symbols[1].public_symbol);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .external = 1 }, serialized.word_token.?);
}

test "attachPreparedMetadataAlloc carries semantic grammar version" {
    const allocator = std.testing.allocator;
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "versioned_fixture",
        .grammar_version = .{ 2, 3, 4 },
        .variables = &.{},
        .external_tokens = &.{},
        .rules = &.{},
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    const serialized = try attachPreparedMetadataAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
    }, prepared);
    defer allocator.free(serialized.symbols);
    defer deinitSupertypeMap(allocator, serialized.supertype_map);
    defer deinitExternalScanner(allocator, serialized.external_scanner);

    try std.testing.expectEqual([3]u8{ 2, 3, 4 }, serialized.grammar_version);
}

test "attachPreparedMetadataAlloc blocks grammars that declare external tokens" {
    const allocator = std.testing.allocator;
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "external_blocker",
        .variables = &.{},
        .external_tokens = &.{
            .{
                .name = "indent",
                .symbol = .{ .kind = .external, .index = 0 },
                .kind = .named,
                .rule = 0,
            },
        },
        .rules = &.{},
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    const serialized = try attachPreparedMetadataAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
    }, prepared);
    defer allocator.free(serialized.symbols);
    defer deinitSupertypeMap(allocator, serialized.supertype_map);
    defer deinitExternalScanner(allocator, serialized.external_scanner);

    try std.testing.expect(!serialized.isSerializationReady());
    try std.testing.expectEqual(@as(usize, 1), serialized.external_scanner.symbols.len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .external = 0 }, serialized.external_scanner.symbols[0]);
}

test "attachPreparedMetadataAlloc derives external scanner state sets from actions" {
    const allocator = std.testing.allocator;
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "external_states",
        .variables = &.{},
        .external_tokens = &.{
            .{ .name = "OPEN", .symbol = .{ .kind = .external, .index = 0 }, .kind = .named, .rule = 0 },
            .{ .name = "CLOSE", .symbol = .{ .kind = .external, .index = 1 }, .kind = .named, .rule = 1 },
            .{ .name = "ERROR_SENTINEL", .symbol = .{ .kind = .external, .index = 2 }, .kind = .named, .rule = 2 },
        },
        .rules = &.{},
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0 },
        .{ .lex_state = 1 },
        .{ .lex_state = 2 },
    };
    const serialized = try attachPreparedMetadataAlloc(allocator, .{
        .states = &[_]SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
            .{
                .id = 1,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 2 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
            .{
                .id = 2,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 2 } },
                    .{ .symbol = .{ .external = 1 }, .action = .{ .shift = 0 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
        .blocked = false,
        .lex_modes = lex_modes[0..],
    }, prepared);
    defer allocator.free(serialized.symbols);
    defer allocator.free(serialized.lex_modes);
    defer deinitSupertypeMap(allocator, serialized.supertype_map);
    defer deinitExternalScanner(allocator, serialized.external_scanner);

    try std.testing.expectEqual(@as(usize, 3), serialized.external_scanner.symbols.len);
    try std.testing.expectEqual(@as(usize, 3), serialized.external_scanner.states.len);
    try std.testing.expect(!serialized.external_scanner.states[0][0]);
    try std.testing.expect(!serialized.external_scanner.states[0][1]);
    try std.testing.expect(!serialized.external_scanner.states[0][2]);
    try std.testing.expect(serialized.external_scanner.states[1][0]);
    try std.testing.expect(!serialized.external_scanner.states[1][1]);
    try std.testing.expect(!serialized.external_scanner.states[1][2]);
    try std.testing.expect(serialized.external_scanner.states[2][0]);
    try std.testing.expect(serialized.external_scanner.states[2][1]);
    try std.testing.expect(!serialized.external_scanner.states[2][2]);
    try std.testing.expectEqual(@as(u16, 0), serialized.lex_modes[0].external_lex_state);
    try std.testing.expectEqual(@as(u16, 1), serialized.lex_modes[1].external_lex_state);
    try std.testing.expectEqual(@as(u16, 2), serialized.lex_modes[2].external_lex_state);
}

test "attachPreparedMetadataAlloc reserves all-false external scanner state zero" {
    const allocator = std.testing.allocator;
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "external_starts",
        .variables = &.{},
        .external_tokens = &.{
            .{ .name = "OPEN", .symbol = .{ .kind = .external, .index = 0 }, .kind = .named, .rule = 0 },
            .{ .name = "CLOSE", .symbol = .{ .kind = .external, .index = 1 }, .kind = .named, .rule = 1 },
        },
        .rules = &.{},
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0 },
        .{ .lex_state = 0 },
    };
    const serialized = try attachPreparedMetadataAlloc(allocator, .{
        .states = &[_]SerializedState{
            .{
                .id = 0,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 1 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
            .{
                .id = 1,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .external = 1 }, .action = .{ .shift = 2 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
        .blocked = false,
        .lex_modes = lex_modes[0..],
    }, prepared);
    defer allocator.free(serialized.symbols);
    defer allocator.free(serialized.lex_modes);
    defer deinitSupertypeMap(allocator, serialized.supertype_map);
    defer deinitExternalScanner(allocator, serialized.external_scanner);

    try std.testing.expectEqual(@as(usize, 3), serialized.external_scanner.states.len);
    try std.testing.expect(!serialized.external_scanner.states[0][0]);
    try std.testing.expect(!serialized.external_scanner.states[0][1]);
    try std.testing.expect(serialized.external_scanner.states[1][0]);
    try std.testing.expect(!serialized.external_scanner.states[1][1]);
    try std.testing.expect(!serialized.external_scanner.states[2][0]);
    try std.testing.expect(serialized.external_scanner.states[2][1]);
    try std.testing.expectEqual(@as(u16, 1), serialized.lex_modes[0].external_lex_state);
    try std.testing.expectEqual(@as(u16, 2), serialized.lex_modes[1].external_lex_state);
}

test "attachExtractedMetadataAlloc marks external extras valid for scanner states" {
    const allocator = std.testing.allocator;
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "external_extra_states",
        .variables = &.{},
        .external_tokens = &.{},
        .rules = &.{},
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };
    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{},
        .external_tokens = &.{
            .{ .name = "html_comment", .kind = .named },
            .{ .name = "PIPE_PIPE", .kind = .anonymous, .corresponding_internal_token = .{ .terminal = 0 } },
        },
        .extra_symbols = &.{
            .{ .external = 0 },
            .{ .external = 1 },
        },
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "||", .kind = .anonymous, .rule = 0 },
        },
        .separators = &.{},
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0 },
    };

    const serialized = try attachExtractedMetadataAlloc(allocator, .{
        .states = &[_]SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
        .blocked = false,
        .lex_modes = lex_modes[0..],
    }, prepared, syntax, lexical, .{ .entries = &.{} });
    const recovery_actions = serialized.states[0].actions;
    defer allocator.free(serialized.symbols);
    defer allocator.free(recovery_actions);
    defer allocator.free(serialized.states);
    defer deinitParseActionList(allocator, serialized.parse_action_list);
    defer deinitSmallParseTable(allocator, serialized.small_parse_table);
    defer allocator.free(serialized.lex_modes);
    defer deinitSupertypeMap(allocator, serialized.supertype_map);
    defer deinitExternalScanner(allocator, serialized.external_scanner);

    try std.testing.expect(!serialized.isSerializationReady());
    try std.testing.expectEqual(@as(usize, 2), serialized.external_scanner.symbols.len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .external = 0 }, serialized.external_scanner.symbols[0]);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .terminal = 0 }, serialized.external_scanner.symbols[1]);
    try std.testing.expectEqual(@as(usize, 2), serialized.external_scanner.states.len);
    try std.testing.expect(!serialized.external_scanner.states[0][0]);
    try std.testing.expect(!serialized.external_scanner.states[0][1]);
    try std.testing.expect(serialized.external_scanner.states[1][0]);
    try std.testing.expect(serialized.external_scanner.states[1][1]);
    try std.testing.expectEqual(@as(u16, 1), serialized.lex_modes[0].external_lex_state);
}

test "attachExtractedMetadataAlloc gives state zero a recovery external scanner row" {
    const allocator = std.testing.allocator;
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "external_recovery_state",
        .variables = &.{},
        .external_tokens = &.{},
        .rules = &.{},
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };
    const syntax = syntax_ir.SyntaxGrammar{
        .variables = &.{},
        .external_tokens = &.{
            .{ .name = "_automatic_semicolon", .kind = .hidden },
        },
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{},
        .separators = &.{},
    };
    const lex_modes = [_]lexer_serialize.SerializedLexMode{
        .{ .lex_state = 0 },
    };

    const serialized = try attachExtractedMetadataAlloc(allocator, .{
        .states = &[_]SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
        .blocked = false,
        .lex_modes = lex_modes[0..],
    }, prepared, syntax, lexical, .{ .entries = &.{} });
    const recovery_actions = serialized.states[0].actions;
    defer allocator.free(serialized.symbols);
    defer allocator.free(recovery_actions);
    defer allocator.free(serialized.states);
    defer deinitParseActionList(allocator, serialized.parse_action_list);
    defer deinitSmallParseTable(allocator, serialized.small_parse_table);
    defer allocator.free(serialized.lex_modes);
    defer deinitSupertypeMap(allocator, serialized.supertype_map);
    defer deinitExternalScanner(allocator, serialized.external_scanner);

    try std.testing.expectEqual(@as(usize, 2), serialized.external_scanner.states.len);
    try std.testing.expect(!serialized.external_scanner.states[0][0]);
    try std.testing.expect(serialized.external_scanner.states[1][0]);
    try std.testing.expectEqual(@as(u16, 1), serialized.lex_modes[0].external_lex_state);
    try std.testing.expectEqual(@as(usize, 2), recovery_actions.len);
    try std.testing.expect(hasSerializedActionForSymbol(recovery_actions, .{ .end = {} }));
    try std.testing.expect(hasSerializedActionForSymbol(recovery_actions, .{ .external = 0 }));
}

test "attachExtraShiftMetadataAlloc marks terminal extra shifts" {
    const allocator = std.testing.allocator;
    const serialized = try attachExtraShiftMetadataAlloc(allocator, .{
        .states = &[_]SerializedState{
            .{
                .id = 0,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
                    .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 2 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
        .blocked = false,
        .productions = &.{},
        .large_state_count = 0,
    }, &[_]syntax_ir.SymbolRef{.{ .terminal = 0 }});
    defer {
        for (serialized.states) |state_value| allocator.free(state_value.actions);
        allocator.free(serialized.states);
        deinitParseActionList(allocator, serialized.parse_action_list);
        deinitSmallParseTable(allocator, serialized.small_parse_table);
    }

    try std.testing.expect(!serialized.blocked);
    try std.testing.expect(serialized.states[0].actions[0].extra);
    try std.testing.expect(!serialized.states[0].actions[1].extra);
    try std.testing.expectEqual(SerializedParseActionKind.shift, serialized.parse_action_list[1].actions[0].kind);
    try std.testing.expect(serialized.parse_action_list[1].actions[0].extra);
    try std.testing.expect(!serialized.parse_action_list[2].actions[0].extra);
}

test "attachExtraShiftMetadataAlloc preserves non-terminal extra readiness" {
    const allocator = std.testing.allocator;
    const serialized = try attachExtraShiftMetadataAlloc(allocator, .{
        .states = &[_]SerializedState{
            .{ .id = 0, .actions = &.{}, .gotos = &.{}, .unresolved = &.{} },
        },
        .blocked = false,
        .productions = &.{},
        .large_state_count = 1,
    }, &[_]syntax_ir.SymbolRef{.{ .non_terminal = 0 }});
    defer {
        for (serialized.states) |state_value| allocator.free(state_value.actions);
        allocator.free(serialized.states);
        deinitParseActionList(allocator, serialized.parse_action_list);
    }

    try std.testing.expect(!serialized.blocked);
}

test "serializeBuildResult preserves non-terminal extra start shifts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };
    var extra_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "_gap", .kind = .hidden, .productions = &.{.{ .steps = extra_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{.{ .non_terminal = 1 }},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try build.buildStatesWithOptions(arena.allocator(), grammar, .{
        .non_terminal_extra_symbols = &.{.{ .non_terminal = 1 }},
    });
    const serialized = try serializeBuildResult(arena.allocator(), result, .strict);

    var saw_extra_shift = false;
    for (serialized.states) |serialized_state| {
        if (serialized_state.id != 0) continue;
        for (serialized_state.actions) |entry| {
            if (symbolRefEql(entry.symbol, .{ .terminal = 0 }) and entry.extra and switch (entry.action) {
                .shift => true,
                else => false,
            }) {
                saw_extra_shift = true;
            }
        }
    }
    try std.testing.expect(saw_extra_shift);
    try std.testing.expect(!serialized.blocked);
}

test "attachRepetitionShiftMetadataAlloc marks repeat auxiliary conflicts" {
    const allocator = std.testing.allocator;
    const repeat_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 1, .steps = repeat_steps[0..], .lhs_is_repeat_auxiliary = true },
    };
    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 0, .step_index = 1 }, .{ .terminal = 0 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = parse_items[0..], .transitions = &.{} },
    };

    const serialized = try attachRepetitionShiftMetadataAlloc(allocator, .{
        .states = &[_]SerializedState{
            .{
                .id = 0,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
        .blocked = false,
        .productions = &.{},
        .large_state_count = 0,
    }, parse_states[0..], productions[0..]);
    defer {
        for (serialized.states) |state_value| allocator.free(state_value.actions);
        allocator.free(serialized.states);
        deinitParseActionList(allocator, serialized.parse_action_list);
        deinitSmallParseTable(allocator, serialized.small_parse_table);
    }

    try std.testing.expect(serialized.states[0].actions[0].repetition);
    try std.testing.expect(serialized.parse_action_list[1].actions[0].repetition);
}

test "attachRepetitionShiftMetadataAlloc leaves non-repeat conflicts unmarked" {
    const allocator = std.testing.allocator;
    const repeat_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 1, .steps = repeat_steps[0..], .lhs_is_repeat_auxiliary = false },
    };
    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 0, .step_index = 1 }, .{ .terminal = 0 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = parse_items[0..], .transitions = &.{} },
    };
    const source = SerializedTable{
        .states = &[_]SerializedState{
            .{
                .id = 0,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
        .blocked = false,
    };

    const serialized = try attachRepetitionShiftMetadataAlloc(allocator, source, parse_states[0..], productions[0..]);

    try std.testing.expectEqual(source.states.ptr, serialized.states.ptr);
    try std.testing.expect(!serialized.states[0].actions[0].repetition);
}

test "attachRepetitionShiftMetadataAlloc marks same auxiliary repeat conflicts" {
    const allocator = std.testing.allocator;
    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .terminal = 0 } },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 1, .lhs_kind = .auxiliary, .steps = reduce_steps[0..], .lhs_is_repeat_auxiliary = false },
        .{ .lhs = 1, .lhs_kind = .auxiliary, .steps = shift_steps[0..], .lhs_is_repeat_auxiliary = false },
    };
    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 0, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = parse_items[0..], .transitions = &.{} },
    };

    const serialized = try attachRepetitionShiftMetadataAlloc(allocator, .{
        .states = &[_]SerializedState{
            .{
                .id = 0,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
        .blocked = false,
        .productions = &[_]SerializedProductionInfo{
            .{ .lhs = 1, .child_count = 1, .dynamic_precedence = 0 },
            .{ .lhs = 1, .child_count = 2, .dynamic_precedence = 0 },
        },
        .large_state_count = 0,
    }, parse_states[0..], productions[0..]);
    defer {
        for (serialized.states) |state_value| allocator.free(state_value.actions);
        allocator.free(serialized.states);
        deinitParseActionList(allocator, serialized.parse_action_list);
        deinitSmallParseTable(allocator, serialized.small_parse_table);
    }

    try std.testing.expect(serialized.states[0].actions[0].repetition);
    try std.testing.expect(serialized.parse_action_list[1].actions[0].repetition);
}

test "attachRepetitionShiftMetadataAlloc leaves same non-auxiliary conflicts unmarked" {
    const allocator = std.testing.allocator;
    const reduce_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const shift_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .terminal = 0 } },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 1, .lhs_kind = .named, .steps = reduce_steps[0..], .lhs_is_repeat_auxiliary = false },
        .{ .lhs = 1, .lhs_kind = .named, .steps = shift_steps[0..], .lhs_is_repeat_auxiliary = false },
    };
    var parse_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 0, .step_index = 1 }, .{ .terminal = 0 }),
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, .{ .production_id = 1, .step_index = 1 }),
    };
    defer for (parse_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = parse_items[0..], .transitions = &.{} },
    };
    const source = SerializedTable{
        .states = &[_]SerializedState{
            .{
                .id = 0,
                .actions = &[_]SerializedActionEntry{
                    .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 2 } },
                },
                .gotos = &.{},
                .unresolved = &.{},
            },
        },
        .blocked = false,
    };

    const serialized = try attachRepetitionShiftMetadataAlloc(allocator, source, parse_states[0..], productions[0..]);

    try std.testing.expectEqual(source.states.ptr, serialized.states.ptr);
    try std.testing.expect(!serialized.states[0].actions[0].repetition);
}

test "attachPreparedMetadataAlloc serializes supertype map entries" {
    const allocator = std.testing.allocator;
    const rules = [_]ir_rules.Rule{
        .{ .choice = &.{ 1, 2, 3 } },
        .{ .symbol = .{ .kind = .non_terminal, .index = 2 } },
        .{ .metadata = .{
            .inner = 1,
            .data = .{ .alias = .{ .value = "identifier_alias", .named = true } },
        } },
        .{ .seq = &.{4} },
        .{ .symbol = .{ .kind = .non_terminal, .index = 3 } },
    };
    const variables = [_]grammar_ir.Variable{
        .{ .name = "source_file", .symbol = .{ .kind = .non_terminal, .index = 0 }, .kind = .named, .rule = 4 },
        .{ .name = "expression", .symbol = .{ .kind = .non_terminal, .index = 1 }, .kind = .named, .rule = 0 },
        .{ .name = "identifier", .symbol = .{ .kind = .non_terminal, .index = 2 }, .kind = .named, .rule = 4 },
        .{ .name = "number", .symbol = .{ .kind = .non_terminal, .index = 3 }, .kind = .named, .rule = 4 },
    };
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "supertype_fixture",
        .variables = variables[0..],
        .external_tokens = &.{},
        .rules = rules[0..],
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{.{ .kind = .non_terminal, .index = 1 }},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    const serialized = try attachPreparedMetadataAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
    }, prepared);
    defer allocator.free(serialized.symbols);
    defer deinitSupertypeMap(allocator, serialized.supertype_map);

    try std.testing.expectEqual(@as(usize, 1), serialized.supertype_map.symbols.len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .non_terminal = 1 }, serialized.supertype_map.symbols[0]);
    try std.testing.expectEqual(@as(usize, 1), serialized.supertype_map.slices.len);
    try std.testing.expectEqual(@as(u16, 0), serialized.supertype_map.slices[0].index);
    try std.testing.expectEqual(@as(u16, 3), serialized.supertype_map.slices[0].length);
    try std.testing.expectEqual(@as(usize, 3), serialized.supertype_map.entries.len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .non_terminal = 2 }, serialized.supertype_map.entries[0].symbol);
    try std.testing.expectEqualStrings("identifier_alias", serialized.supertype_map.entries[1].alias_name.?);
    try std.testing.expect(serialized.supertype_map.entries[1].alias_named);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .non_terminal = 3 }, serialized.supertype_map.entries[2].symbol);
}

test "attachReservedWordsAlloc serializes reserved word sets from lexical terminals" {
    const allocator = std.testing.allocator;
    const rules = [_]ir_rules.Rule{
        .{ .string = "if" },
        .{ .string = "else" },
        .{ .string = "identifier" },
    };
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "reserved_fixture",
        .variables = &.{},
        .external_tokens = &.{},
        .rules = rules[0..],
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{
            .{ .context_name = "default", .members = &.{ 1, 0, 0 } },
        },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "if", .kind = .anonymous, .rule = 0 },
            .{ .name = "else", .kind = .anonymous, .rule = 1 },
            .{ .name = "identifier", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    const serialized = try attachReservedWordsAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
    }, prepared, lexical);
    defer deinitReservedWords(allocator, serialized.reserved_words);

    try std.testing.expectEqual(@as(usize, 2), serialized.reserved_words.sets.len);
    try std.testing.expectEqual(@as(u16, 2), serialized.reserved_words.max_size);
    try std.testing.expectEqual(@as(usize, 0), serialized.reserved_words.sets[0].len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .terminal = 0 }, serialized.reserved_words.sets[1][0]);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .terminal = 1 }, serialized.reserved_words.sets[1][1]);
}

test "attachReservedWordLexModesAlloc serializes reserved word set ids" {
    const allocator = std.testing.allocator;
    var items = [_]@import("item.zig").ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 0, 0, .{ .production_id = 0, .step_index = 0 }),
    };
    defer for (items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .reserved_word_set_id = 2, .items = items[0..], .transitions = &.{} },
        .{ .id = 1, .items = &.{}, .transitions = &.{} },
    };
    const serialized = try attachReservedWordLexModesAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
        .lex_modes = &[_]lexer_serialize.SerializedLexMode{
            .{ .lex_state = 0 },
            .{ .lex_state = 1 },
        },
    }, parse_states[0..]);
    defer allocator.free(serialized.lex_modes);

    try std.testing.expectEqual(@as(u16, 2), serialized.lex_modes[0].reserved_word_set_id);
    try std.testing.expectEqual(@as(u16, 0), serialized.lex_modes[1].reserved_word_set_id);
}

test "attachNonTerminalExtraLexModesAlloc marks extra end states with sentinel lex state" {
    const allocator = std.testing.allocator;
    const production_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 1, .steps = production_steps[0..] },
    };
    var extra_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(allocator, 1, 0, .{ .production_id = 0, .step_index = 1 }, .{ .end = {} }),
    };
    defer for (extra_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const normal_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 0, 0, .{ .production_id = 0, .step_index = 0 }),
    };
    defer for (normal_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = normal_items[0..], .transitions = &.{} },
        .{ .id = 1, .items = extra_items[0..], .transitions = &.{} },
    };

    const serialized = try attachNonTerminalExtraLexModesAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
        .lex_modes = &[_]lexer_serialize.SerializedLexMode{
            .{ .lex_state = 0 },
            .{ .lex_state = 1 },
        },
    }, parse_states[0..], productions[0..], &[_]syntax_ir.SymbolRef{.{ .non_terminal = 1 }});
    defer allocator.free(serialized.lex_modes);

    try std.testing.expectEqual(@as(u16, 0), serialized.lex_modes[0].lex_state);
    try std.testing.expectEqual(std.math.maxInt(u16), serialized.lex_modes[1].lex_state);
}

test "attachKeywordLexTableAlloc builds keyword table from reserved words" {
    const allocator = std.testing.allocator;
    const rules = [_]ir_rules.Rule{
        .{ .string = "if" },
        .{ .string = "else" },
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
    };
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "keyword_fixture",
        .variables = &.{},
        .external_tokens = &.{},
        .rules = rules[0..],
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = .{ .kind = .non_terminal, .index = 0 },
        .reserved_word_sets = &.{
            .{ .context_name = "default", .members = &.{ 0, 1 } },
        },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "if", .kind = .anonymous, .rule = 0 },
            .{ .name = "else", .kind = .anonymous, .rule = 1 },
            .{ .name = "identifier", .kind = .named, .rule = 2 },
        },
        .separators = &.{},
    };

    const serialized = try attachKeywordLexTableAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
    }, prepared, lexical);
    defer if (serialized.keyword_lex_table) |keyword_lex_table| {
        lexer_serialize.deinitSerializedLexTable(allocator, keyword_lex_table);
    };

    try std.testing.expect(serialized.keyword_lex_table != null);
    const keyword_lex_table = serialized.keyword_lex_table.?;
    try std.testing.expect(keyword_lex_table.states.len > 0);
    try std.testing.expectEqual(@as(usize, 0), serialized.keyword_unmapped_reserved_word_count);
    try std.testing.expect(lexTableAcceptsSymbol(keyword_lex_table, .{ .terminal = 0 }));
    try std.testing.expect(lexTableAcceptsSymbol(keyword_lex_table, .{ .terminal = 1 }));
    try std.testing.expect(!lexTableAcceptsSymbol(keyword_lex_table, .{ .terminal = 2 }));
}

test "attachKeywordLexTableAlloc builds keyword table from reserved string-only rules" {
    const allocator = std.testing.allocator;
    const rules = [_]ir_rules.Rule{
        .{ .string = "if" },
        .{ .pattern = .{ .value = "[a-z]+", .flags = null } },
    };
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "keyword_string_fixture",
        .variables = &.{},
        .external_tokens = &.{},
        .rules = rules[0..],
        .symbols = &.{},
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = .{ .kind = .non_terminal, .index = 0 },
        .reserved_word_sets = &.{
            .{ .context_name = "default", .members = &.{0} },
        },
    };
    const lexical = lexical_ir.LexicalGrammar{
        .variables = &.{
            .{ .name = "identifier", .kind = .named, .rule = 1, .source_kind = .pattern },
        },
        .separators = &.{},
    };

    const with_reserved_words = try attachReservedWordsAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
    }, prepared, lexical);
    defer deinitReservedWords(allocator, with_reserved_words.reserved_words);

    const serialized = try attachKeywordLexTableAlloc(allocator, .{
        .states = &.{},
        .blocked = false,
    }, prepared, lexical);
    defer if (serialized.keyword_lex_table) |keyword_lex_table| {
        lexer_serialize.deinitSerializedLexTable(allocator, keyword_lex_table);
    };

    try std.testing.expectEqual(@as(usize, 2), with_reserved_words.reserved_words.sets.len);
    try std.testing.expectEqual(@as(usize, 1), with_reserved_words.reserved_words.sets[1].len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .terminal = 1 }, with_reserved_words.reserved_words.sets[1][0]);
    try std.testing.expect(serialized.keyword_lex_table != null);
    try std.testing.expectEqual(@as(usize, 0), serialized.keyword_unmapped_reserved_word_count);
    try std.testing.expect(lexTableAcceptsSymbol(serialized.keyword_lex_table.?, .{ .terminal = 1 }));
}

fn lexTableAcceptsSymbol(
    lex_table: lexer_serialize.SerializedLexTable,
    symbol: syntax_ir.SymbolRef,
) bool {
    for (lex_table.states) |lex_state| {
        if (lex_state.accept_symbol) |accept_symbol| {
            if (symbolRefEql(accept_symbol, symbol)) return true;
        }
    }
    return false;
}

test "buildFieldMapAlloc serializes distinct field names and production slices" {
    const allocator = std.testing.allocator;
    const first_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 }, .field_name = "left" },
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .non_terminal = 2 }, .field_name = "right" },
    };
    const second_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 3 }, .field_name = "left" },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 0, .steps = first_steps[0..] },
        .{ .lhs = 1, .steps = second_steps[0..] },
    };

    const field_map = try buildFieldMapAlloc(allocator, productions[0..]);
    defer deinitFieldMap(allocator, field_map);

    try std.testing.expectEqual(@as(usize, 2), field_map.names.len);
    try std.testing.expectEqual(@as(u16, 1), field_map.names[0].id);
    try std.testing.expectEqualStrings("left", field_map.names[0].name);
    try std.testing.expectEqual(@as(u16, 2), field_map.names[1].id);
    try std.testing.expectEqualStrings("right", field_map.names[1].name);
    try std.testing.expectEqual(@as(usize, 3), field_map.entries.len);
    try std.testing.expectEqual(SerializedFieldMapEntry{ .field_id = 1, .child_index = 0, .inherited = false }, field_map.entries[0]);
    try std.testing.expectEqual(SerializedFieldMapEntry{ .field_id = 2, .child_index = 2, .inherited = false }, field_map.entries[1]);
    try std.testing.expectEqual(SerializedFieldMapEntry{ .field_id = 1, .child_index = 0, .inherited = false }, field_map.entries[2]);
    try std.testing.expectEqual(SerializedFieldMapSlice{ .index = 0, .length = 2 }, field_map.slices[0]);
    try std.testing.expectEqual(SerializedFieldMapSlice{ .index = 2, .length = 1 }, field_map.slices[1]);
}

test "buildFieldMapAlloc marks fields inherited from hidden child variables" {
    const allocator = std.testing.allocator;
    const parent_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    const hidden_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 }, .field_name = "inner" },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 0, .lhs_kind = .named, .steps = parent_steps[0..] },
        .{ .lhs = 1, .lhs_kind = .hidden, .steps = hidden_steps[0..] },
    };

    const field_map = try buildFieldMapAlloc(allocator, productions[0..]);
    defer deinitFieldMap(allocator, field_map);

    try std.testing.expectEqual(@as(usize, 1), field_map.names.len);
    try std.testing.expectEqualStrings("inner", field_map.names[0].name);
    try std.testing.expectEqual(@as(usize, 2), field_map.entries.len);
    try std.testing.expectEqual(SerializedFieldMapEntry{ .field_id = 1, .child_index = 0, .inherited = true }, field_map.entries[0]);
    try std.testing.expectEqual(SerializedFieldMapEntry{ .field_id = 1, .child_index = 0, .inherited = false }, field_map.entries[1]);
    try std.testing.expectEqual(SerializedFieldMapSlice{ .index = 0, .length = 1 }, field_map.slices[0]);
    try std.testing.expectEqual(SerializedFieldMapSlice{ .index = 1, .length = 1 }, field_map.slices[1]);
}

test "buildProductionSerializationAlloc interns production ids separately from reduce payloads" {
    const allocator = std.testing.allocator;
    const first_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const second_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
        .{ .symbol = .{ .terminal = 2 } },
    };
    const field_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 3 }, .field_name = "name" },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 10, .steps = first_steps[0..] },
        .{ .lhs = 11, .steps = second_steps[0..] },
        .{ .lhs = 12, .steps = field_steps[0..] },
    };

    const serialized = try buildProductionSerializationAlloc(allocator, productions[0..]);
    defer allocator.free(serialized.productions);
    defer allocator.free(serialized.alias_sequences);
    defer allocator.free(serialized.non_terminal_aliases);
    defer deinitFieldMap(allocator, serialized.field_map);

    try std.testing.expectEqual(@as(usize, 2), serialized.production_id_count);
    try std.testing.expectEqual(@as(?u16, 0), serialized.productions[0].production_info_id);
    try std.testing.expectEqual(@as(?u16, 0), serialized.productions[1].production_info_id);
    try std.testing.expectEqual(@as(?u16, 1), serialized.productions[2].production_info_id);

    const first_reduce = runtimeActionFromParseAction(.{ .reduce = 0 }, serialized.productions);
    const second_reduce = runtimeActionFromParseAction(.{ .reduce = 1 }, serialized.productions);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .non_terminal = 10 }, first_reduce.symbol);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .non_terminal = 11 }, second_reduce.symbol);
    try std.testing.expectEqual(@as(u8, 1), first_reduce.child_count);
    try std.testing.expectEqual(@as(u8, 2), second_reduce.child_count);
    try std.testing.expectEqual(@as(u16, 0), first_reduce.production_id);
    try std.testing.expectEqual(@as(u16, 0), second_reduce.production_id);

    try std.testing.expectEqual(@as(usize, 2), serialized.field_map.slices.len);
    try std.testing.expectEqual(SerializedFieldMapSlice{ .index = 0, .length = 0 }, serialized.field_map.slices[0]);
    try std.testing.expectEqual(SerializedFieldMapSlice{ .index = 0, .length = 1 }, serialized.field_map.slices[1]);
}

test "buildProductionSerializationAlloc skips inline-shadowed raw production metadata" {
    const allocator = std.testing.allocator;
    const raw_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    const inlined_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 }, .field_name = "parameters" },
    };
    const productions = [_]build.ProductionInfo{
        .{
            .lhs = 0,
            .lhs_kind = .named,
            .steps = raw_steps[0..],
            .production_metadata_eligible = false,
        },
        .{
            .lhs = 0,
            .lhs_kind = .named,
            .steps = inlined_steps[0..],
            .production_metadata_eligible = true,
        },
    };

    const serialized = try buildProductionSerializationAlloc(allocator, productions[0..]);
    defer allocator.free(serialized.productions);
    defer allocator.free(serialized.alias_sequences);
    defer allocator.free(serialized.non_terminal_aliases);
    defer deinitFieldMap(allocator, serialized.field_map);

    try std.testing.expectEqual(@as(usize, 1), serialized.production_id_count);
    try std.testing.expect(serialized.productions[0].production_info_id == null);
    try std.testing.expectEqual(@as(?u16, 0), serialized.productions[1].production_info_id);
    try std.testing.expectEqual(@as(usize, 1), serialized.field_map.slices.len);
    try std.testing.expectEqual(SerializedFieldMapSlice{ .index = 0, .length = 1 }, serialized.field_map.slices[0]);
    try std.testing.expectEqual(SerializedFieldMapEntry{ .field_id = 1, .child_index = 0, .inherited = false }, serialized.field_map.entries[0]);
}

test "buildProductionSerializationAlloc reuses existing metadata for ineligible productions" {
    const allocator = std.testing.allocator;
    const raw_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const empty_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
        .{ .symbol = .{ .terminal = 2 } },
    };
    const productions = [_]build.ProductionInfo{
        .{
            .lhs = 0,
            .lhs_kind = .named,
            .steps = raw_steps[0..],
            .production_metadata_eligible = false,
        },
        .{
            .lhs = 1,
            .lhs_kind = .named,
            .steps = empty_steps[0..],
            .production_metadata_eligible = true,
        },
    };

    const serialized = try buildProductionSerializationAlloc(allocator, productions[0..]);
    defer allocator.free(serialized.productions);
    defer allocator.free(serialized.alias_sequences);
    defer allocator.free(serialized.non_terminal_aliases);
    defer deinitFieldMap(allocator, serialized.field_map);

    try std.testing.expectEqual(@as(usize, 1), serialized.production_id_count);
    try std.testing.expectEqual(@as(?u16, 0), serialized.productions[0].production_info_id);
    try std.testing.expectEqual(@as(?u16, 0), serialized.productions[1].production_info_id);

    const raw_reduce = runtimeActionFromParseAction(.{ .reduce = 0 }, serialized.productions);
    try std.testing.expectEqual(@as(u16, 0), raw_reduce.production_id);
}

test "serializeBuildResult rejects blocked snapshots in strict mode" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 2,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 9 },
            },
            .conflicts = &.{},
        },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{
                            .{ .shift = 4 },
                            .{ .reduce = 2 },
                        },
                        .decision = .{ .unresolved = .shift_reduce },
                    },
                },
            },
        },
    };

    const result = build.BuildResult{
        .productions = &.{},
        .precedence_orderings = &.{},
        .states = parse_states[0..],
        .lex_state_count = 1,
        .actions = .{ .states = &.{} },
        .resolved_actions = resolved_actions,
    };

    try std.testing.expectError(
        error.UnresolvedDecisions,
        serializeBuildResult(allocator, result, .strict),
    );
}

test "serializeBuildResult accepts expected reduce reduce snapshots in strict mode" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 2,
            .items = &.{},
            .transitions = &.{},
            .conflicts = &.{},
        },
    };

    const productions = [_]build.ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
        .{ .lhs = 1, .steps = &.{} },
        .{ .lhs = 2, .steps = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{
                            .{ .reduce = 1 },
                            .{ .reduce = 2 },
                        },
                        .decision = .{ .unresolved = .reduce_reduce_expected },
                    },
                },
            },
        },
    };

    const result = build.BuildResult{
        .productions = productions[0..],
        .precedence_orderings = &.{},
        .states = parse_states[0..],
        .lex_state_count = 1,
        .actions = .{ .states = &.{} },
        .resolved_actions = resolved_actions,
    };

    const serialized = try serializeBuildResult(allocator, result, .strict);
    defer allocator.free(serialized.states);
    defer deinitSmallParseTable(allocator, serialized.small_parse_table);
    defer deinitParseActionList(allocator, serialized.parse_action_list);
    defer deinitFieldMap(allocator, serialized.field_map);
    defer allocator.free(serialized.lex_modes);
    defer deinitLexStateTerminalSets(allocator, serialized.lex_state_terminal_sets);
    defer allocator.free(serialized.primary_state_ids);
    defer allocator.free(serialized.productions);
    defer allocator.free(serialized.alias_sequences);
    defer allocator.free(serialized.non_terminal_aliases);
    defer allocator.free(serialized.states[0].gotos);
    defer allocator.free(serialized.states[0].actions);

    try std.testing.expect(serialized.isSerializationReady());
    try std.testing.expectEqual(@as(usize, 0), serialized.states[0].unresolved.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.states[0].actions.len);
    try std.testing.expectEqual(@as(usize, 2), serialized.states[0].actions[0].candidate_actions.len);
    try std.testing.expect(
        parseActionListIndexForActionEntry(
            serialized.parse_action_list,
            serialized.states[0].actions[0],
            serialized.productions,
        ) != null,
    );
}

test "serializeBuildResult emits expected shift reduce conflicts as runtime actions" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 2,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .terminal = 0 }, .state = 4 },
            },
            .conflicts = &.{},
        },
    };

    const productions = [_]build.ProductionInfo{
        .{ .lhs = 0, .steps = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{
                            .{ .shift = 4 },
                            .{ .reduce = 0 },
                        },
                        .decision = .{ .unresolved = .shift_reduce_expected },
                    },
                },
            },
        },
    };

    const result = build.BuildResult{
        .productions = productions[0..],
        .precedence_orderings = &.{},
        .states = parse_states[0..],
        .lex_state_count = 1,
        .actions = .{ .states = &.{} },
        .resolved_actions = resolved_actions,
    };

    const serialized = try serializeBuildResultWithOptions(
        allocator,
        result,
        .strict,
        .{ .include_unresolved_parse_actions = false },
    );
    defer allocator.free(serialized.states);
    defer deinitSmallParseTable(allocator, serialized.small_parse_table);
    defer deinitParseActionList(allocator, serialized.parse_action_list);
    defer deinitFieldMap(allocator, serialized.field_map);
    defer allocator.free(serialized.lex_modes);
    defer deinitLexStateTerminalSets(allocator, serialized.lex_state_terminal_sets);
    defer allocator.free(serialized.primary_state_ids);
    defer allocator.free(serialized.productions);
    defer allocator.free(serialized.alias_sequences);
    defer allocator.free(serialized.non_terminal_aliases);
    defer allocator.free(serialized.states[0].gotos);
    defer allocator.free(serialized.states[0].actions);

    try std.testing.expect(serialized.isSerializationReady());
    try std.testing.expectEqual(@as(usize, 0), serialized.states[0].unresolved.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.states[0].actions.len);
    const action_index = parseActionListIndexForActionEntry(
        serialized.parse_action_list,
        serialized.states[0].actions[0],
        serialized.productions,
    ).?;
    const entry = parseActionListEntryByIndex(serialized.parse_action_list, action_index).?;
    try std.testing.expectEqual(@as(usize, 2), entry.actions.len);
    try std.testing.expectEqual(SerializedParseActionKind.reduce, entry.actions[0].kind);
    try std.testing.expectEqual(SerializedParseActionKind.shift, entry.actions[1].kind);
    try std.testing.expect(!entry.actions[1].repetition);
}

test "serializeBuildResult keeps blocked snapshots in diagnostic mode" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 2,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 9 },
            },
            .conflicts = &.{},
        },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{
                            .{ .shift = 4 },
                            .{ .reduce = 2 },
                        },
                        .decision = .{ .unresolved = .shift_reduce },
                    },
                },
            },
        },
    };

    const result = build.BuildResult{
        .productions = &.{},
        .precedence_orderings = &.{},
        .states = parse_states[0..],
        .lex_state_count = 1,
        .actions = .{ .states = &.{} },
        .resolved_actions = resolved_actions,
    };

    const serialized = try serializeBuildResult(allocator, result, .diagnostic);
    defer allocator.free(serialized.states);
    defer deinitSmallParseTable(allocator, serialized.small_parse_table);
    defer deinitParseActionList(allocator, serialized.parse_action_list);
    defer deinitFieldMap(allocator, serialized.field_map);
    defer allocator.free(serialized.lex_modes);
    defer deinitLexStateTerminalSets(allocator, serialized.lex_state_terminal_sets);
    defer allocator.free(serialized.primary_state_ids);
    defer allocator.free(serialized.states[0].unresolved);
    defer allocator.free(serialized.states[0].gotos);
    defer allocator.free(serialized.states[0].actions);

    try std.testing.expect(!serialized.isSerializationReady());
    try std.testing.expectEqual(@as(usize, 1), serialized.states.len);
    try std.testing.expectEqual(@as(usize, 0), serialized.states[0].actions.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.states[0].gotos.len);
    try std.testing.expectEqual(@as(usize, 1), serialized.states[0].unresolved.len);
    try std.testing.expectEqual(resolution.UnresolvedReason.shift_reduce, serialized.states[0].unresolved[0].reason);
}

test "serializeBuildResult preserves EOF accept actions without adding lexical terminals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try build.buildStates(arena.allocator(), grammar);
    const serialized = try serializeBuildResult(arena.allocator(), result, .strict);

    var saw_end_accept = false;
    for (serialized.states) |serialized_state| {
        for (serialized_state.actions) |entry| {
            if (symbolRefEql(entry.symbol, .{ .end = {} }) and entry.action == .accept) {
                saw_end_accept = true;
            }
        }
    }
    for (serialized.lex_state_terminal_sets) |terminal_set| {
        try std.testing.expect(terminal_set.len <= 1);
    }

    try std.testing.expect(saw_end_accept);
}

test "buildParseActionListAlloc deduplicates runtime actions" {
    const allocator = std.testing.allocator;
    const productions = [_]SerializedProductionInfo{
        .{ .lhs = 2, .child_count = 3, .dynamic_precedence = 4 },
    };
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
                .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 7 } },
                .{ .symbol = .{ .terminal = 2 }, .action = .{ .reduce = 0 } },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
    };

    const list = try buildParseActionListAlloc(allocator, states[0..], productions[0..]);
    defer deinitParseActionList(allocator, list);

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(u16, 0), list[0].index);
    try std.testing.expectEqual(@as(u16, 1), list[1].index);
    try std.testing.expectEqual(@as(u16, 3), list[2].index);
    try std.testing.expectEqual(@as(u16, 1), parseActionListIndexForParseAction(list, .{ .shift = 7 }, productions[0..]).?);
    try std.testing.expectEqual(@as(u16, 3), parseActionListIndexForParseAction(list, .{ .reduce = 0 }, productions[0..]).?);
    try std.testing.expectEqual(SerializedParseActionKind.reduce, list[2].actions[0].kind);
    try std.testing.expectEqual(@as(u8, 3), list[2].actions[0].child_count);
    try std.testing.expectEqual(@as(i16, 4), list[2].actions[0].dynamic_precedence);
    try std.testing.expectEqual(@as(u32, 2), list[2].actions[0].symbol.non_terminal);
}

test "buildRuntimeParseActionListAlloc omits unresolved candidates" {
    const allocator = std.testing.allocator;
    const productions = [_]SerializedProductionInfo{
        .{ .lhs = 2, .child_count = 1, .dynamic_precedence = 0 },
    };
    const unresolved_candidates = [_]actions.ParseAction{
        .{ .shift = 9 },
        .{ .reduce = 0 },
    };
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 7 } },
            },
            .gotos = &.{},
            .unresolved = &[_]SerializedUnresolvedEntry{
                .{
                    .symbol = .{ .terminal = 1 },
                    .reason = .multiple_candidates,
                    .candidate_actions = unresolved_candidates[0..],
                },
            },
        },
    };

    const diagnostic_list = try buildParseActionListAlloc(allocator, states[0..], productions[0..]);
    defer deinitParseActionList(allocator, diagnostic_list);
    const runtime_list = try buildRuntimeParseActionListAlloc(allocator, states[0..], productions[0..]);
    defer deinitParseActionList(allocator, runtime_list);

    try std.testing.expectEqual(@as(usize, 3), diagnostic_list.len);
    try std.testing.expectEqual(@as(usize, 2), runtime_list.len);
    try std.testing.expect(parseActionListIndexForUnresolvedEntry(runtime_list, states[0].unresolved[0], productions[0..]) == null);
    try std.testing.expect(parseActionListIndexForParseAction(runtime_list, .{ .shift = 7 }, productions[0..]) != null);
}

test "buildParseActionListAlloc keeps reductions before repetition shifts" {
    const allocator = std.testing.allocator;
    const productions = [_]SerializedProductionInfo{
        .{ .lhs = 1, .child_count = 1, .dynamic_precedence = 0 },
    };
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{
                    .symbol = .{ .terminal = 0 },
                    .action = .{ .shift = 7 },
                    .candidate_actions = &[_]actions.ParseAction{
                        .{ .shift = 7 },
                        .{ .reduce = 0 },
                    },
                    .repetition = true,
                },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
    };

    const list = try buildParseActionListAlloc(allocator, states[0..], productions[0..]);
    defer deinitParseActionList(allocator, list);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(usize, 2), list[1].actions.len);
    try std.testing.expectEqual(SerializedParseActionKind.reduce, list[1].actions[0].kind);
    try std.testing.expectEqual(SerializedParseActionKind.shift, list[1].actions[1].kind);
    try std.testing.expect(list[1].actions[1].repetition);
    try std.testing.expectEqual(
        list[1].index,
        parseActionListIndexForActionEntry(list, states[0].actions[0], productions[0..]).?,
    );
}

test "buildParseActionListAlloc keeps reductions before expected conflict shifts" {
    const allocator = std.testing.allocator;
    const productions = [_]SerializedProductionInfo{
        .{ .lhs = 1, .child_count = 1, .dynamic_precedence = 0 },
    };
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{
                    .symbol = .{ .terminal = 0 },
                    .action = .{ .shift = 7 },
                    .candidate_actions = &[_]actions.ParseAction{
                        .{ .shift = 7 },
                        .{ .reduce = 0 },
                    },
                },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
    };

    const list = try buildRuntimeParseActionListAlloc(allocator, states[0..], productions[0..]);
    defer deinitParseActionList(allocator, list);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(usize, 2), list[1].actions.len);
    try std.testing.expectEqual(SerializedParseActionKind.reduce, list[1].actions[0].kind);
    try std.testing.expectEqual(SerializedParseActionKind.shift, list[1].actions[1].kind);
    try std.testing.expect(!list[1].actions[1].repetition);
    try std.testing.expectEqual(
        list[1].index,
        parseActionListIndexForActionEntry(list, states[0].actions[0], productions[0..]).?,
    );
}

test "buildParseActionListAlloc indexes rows by flattened action width" {
    const allocator = std.testing.allocator;
    const productions = [_]SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    };
    const candidates = [_]actions.ParseAction{
        .{ .shift = 2 },
        .{ .shift = 3 },
    };
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .external = 0 }, .action = .{ .shift = 1 } },
            },
            .gotos = &.{},
            .unresolved = &[_]SerializedUnresolvedEntry{
                .{
                    .symbol = .{ .external = 1 },
                    .reason = .shift_reduce_expected,
                    .candidate_actions = candidates[0..],
                },
            },
        },
        .{
            .id = 1,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .external = 2 }, .action = .{ .shift = 4 } },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
    };

    const list = try buildParseActionListAlloc(allocator, states[0..], productions[0..]);
    defer deinitParseActionList(allocator, list);

    try std.testing.expectEqual(@as(u16, 1), list[1].index);
    try std.testing.expectEqual(@as(u16, 3), list[2].index);
    try std.testing.expectEqual(@as(usize, 2), list[2].actions.len);
    try std.testing.expectEqual(@as(u16, 6), list[3].index);
    try std.testing.expectEqual(
        @as(u16, 3),
        parseActionListIndexForUnresolvedEntry(list, states[0].unresolved[0], productions[0..]).?,
    );
}

test "buildRuntimeParseActionListAlloc excludes unresolved diagnostic actions" {
    const allocator = std.testing.allocator;
    const productions = [_]SerializedProductionInfo{
        .{ .lhs = 0, .child_count = 1, .dynamic_precedence = 0 },
    };
    const candidates = [_]actions.ParseAction{
        .{ .shift = 2 },
        .{ .reduce = 0 },
    };
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
            },
            .gotos = &.{},
            .unresolved = &[_]SerializedUnresolvedEntry{
                .{
                    .symbol = .{ .terminal = 1 },
                    .reason = .shift_reduce,
                    .candidate_actions = candidates[0..],
                },
            },
        },
    };

    const list = try buildRuntimeParseActionListAlloc(allocator, states[0..], productions[0..]);
    defer deinitParseActionList(allocator, list);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(u16, 1), parseActionListIndexForParseAction(list, .{ .shift = 1 }, productions[0..]).?);
    try std.testing.expect(parseActionListIndexForUnresolvedEntry(list, states[0].unresolved[0], productions[0..]) == null);
}

test "computeLargeStateCountAlloc follows tree-sitter threshold prefix rule" {
    const allocator = std.testing.allocator;
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 1,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 2,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 3,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 1 } },
            },
            .gotos = &.{},
            .unresolved = &.{},
        },
    };

    try std.testing.expectEqual(
        @as(usize, 2),
        try computeLargeStateCountAlloc(allocator, states[0..], &.{}),
    );
}

test "buildPrimaryStateIdsAlloc maps states to first matching core id" {
    const allocator = std.testing.allocator;
    const states = [_]SerializedState{
        .{
            .id = 0,
            .core_id = 11,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 1,
            .core_id = 22,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 2,
            .core_id = 11,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 3,
            .core_id = 22,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
    };

    const ids = try buildPrimaryStateIdsAlloc(allocator, states[0..]);
    defer allocator.free(ids);

    try std.testing.expectEqual(@as(state.StateId, 0), ids[0]);
    try std.testing.expectEqual(@as(state.StateId, 1), ids[1]);
    try std.testing.expectEqual(@as(state.StateId, 0), ids[2]);
    try std.testing.expectEqual(@as(state.StateId, 1), ids[3]);
}

test "buildLexStateTerminalSetsAlloc preserves lex-state terminal sets by id" {
    const allocator = std.testing.allocator;
    const source = [_][]const bool{
        &.{ true, false, true },
        &.{ false, true, false },
    };

    const terminal_sets = try buildLexStateTerminalSetsAlloc(allocator, source[0..]);
    defer deinitLexStateTerminalSets(allocator, terminal_sets);

    try std.testing.expectEqual(@as(usize, 2), terminal_sets.len);
    try std.testing.expectEqualSlices(bool, source[0], terminal_sets[0]);
    try std.testing.expectEqualSlices(bool, source[1], terminal_sets[1]);
}

test "buildProductionSerializationAlloc records original alias step symbols" {
    const allocator = std.testing.allocator;
    const aliased_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 7 },
            .alias = .{ .value = "aliased_child", .named = true },
        },
    };
    const productions = [_]build.ProductionInfo{
        .{ .lhs = 0, .steps = aliased_steps[0..] },
    };

    const serialized = try buildProductionSerializationAlloc(allocator, productions[0..]);
    defer allocator.free(serialized.productions);
    defer allocator.free(serialized.alias_sequences);
    defer allocator.free(serialized.non_terminal_aliases);
    defer deinitFieldMap(allocator, serialized.field_map);

    try std.testing.expectEqual(@as(usize, 1), serialized.alias_sequences.len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .non_terminal = 7 }, serialized.alias_sequences[0].original_symbol);
    try std.testing.expectEqual(@as(usize, 1), serialized.non_terminal_aliases.len);
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .non_terminal = 7 }, serialized.non_terminal_aliases[0].original_symbol);
}

test "buildSmallParseTableAlloc groups values and keeps one row per small state" {
    const allocator = std.testing.allocator;
    const states = [_]SerializedState{
        .{
            .id = 0,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 1,
            .actions = &.{},
            .gotos = &.{},
            .unresolved = &.{},
        },
        .{
            .id = 2,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 9 } },
                .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 9 } },
            },
            .gotos = &[_]SerializedGotoEntry{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 4 },
            },
            .unresolved = &.{},
        },
        .{
            .id = 3,
            .actions = &[_]SerializedActionEntry{
                .{ .symbol = .{ .terminal = 0 }, .action = .{ .shift = 9 } },
                .{ .symbol = .{ .terminal = 1 }, .action = .{ .shift = 9 } },
            },
            .gotos = &[_]SerializedGotoEntry{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 4 },
            },
            .unresolved = &.{},
        },
    };
    const actions_list = try buildParseActionListAlloc(allocator, states[0..], &.{});
    defer deinitParseActionList(allocator, actions_list);

    const table = try buildSmallParseTableAlloc(allocator, states[0..], 2, actions_list, &.{});
    defer deinitSmallParseTable(allocator, table);

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(usize, 2), table.map.len);
    try std.testing.expectEqual(@as(u32, 0), table.map[0]);
    try std.testing.expectEqual(packedSmallParseRowLength(table.rows[0].groups), table.map[1]);
    try std.testing.expectEqual(@as(usize, 2), table.rows[0].groups.len);
    try std.testing.expectEqual(SerializedSmallParseValueKind.state, table.rows[0].groups[0].kind);
    try std.testing.expectEqual(@as(u16, 4), table.rows[0].groups[0].value);
    try std.testing.expectEqual(@as(usize, 1), table.rows[0].groups[0].symbols.len);
    try std.testing.expectEqual(SerializedSmallParseValueKind.action, table.rows[0].groups[1].kind);
    try std.testing.expectEqual(@as(usize, 2), table.rows[0].groups[1].symbols.len);
    try std.testing.expectEqual(table.rows[0].groups.len, table.rows[1].groups.len);
}

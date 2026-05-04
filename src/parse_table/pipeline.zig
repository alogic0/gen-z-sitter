const std = @import("std");
const alias_ir = @import("../ir/aliases.zig");
const grammar_ir = @import("../ir/grammar_ir.zig");
const ir_rules = @import("../ir/rules.zig");
const ir_symbols = @import("../ir/symbols.zig");
const actions = @import("actions.zig");
const debug_dump = @import("debug_dump.zig");
const build = @import("build.zig");
const first = @import("first.zig");
const resolution = @import("resolution.zig");
const serialize = @import("serialize.zig");
const parser_tables_emit = @import("../parser_emit/parser_tables.zig");
const parser_c_emit = @import("../parser_emit/parser_c.zig");
const compat_checks = @import("../parser_emit/compat_checks.zig");
const process_support = @import("../support/process.zig");
const state = @import("state.zig");
const extract_default_aliases = @import("../grammar/prepare/extract_default_aliases.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const flatten_grammar = @import("../grammar/prepare/flatten_grammar.zig");
const lexer_model = @import("../lexer/model.zig");
const lexer_serialize = @import("../lexer/serialize.zig");
const fixtures = @import("../tests/fixtures.zig");
const grammar_loader = @import("../grammar/loader.zig");
const json_loader = @import("../grammar/json_loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const emit_optimize = @import("../parser_emit/optimize.zig");
const runtime_io = @import("../support/runtime_io.zig");

threadlocal var scoped_progress_enabled: bool = false;
threadlocal var pipeline_env_flags_loaded: bool = false;
threadlocal var pipeline_env_flags: PipelineEnvFlags = .{};

const PipelineEnvFlags = struct {
    progress: bool = false,
    global_progress: bool = false,
    profile: bool = false,
    has_target_filter: bool = false,
};

fn envFlagEnabledRaw(name: []const u8) bool {
    const value = std.process.Environ.getAlloc(runtime_io.environ(), std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

fn hasProgressTargetFilterRaw() bool {
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        "GEN_Z_SITTER_PARSE_TABLE_TARGET_FILTER",
    ) catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len != 0;
}

fn ensurePipelineEnvFlags() void {
    if (pipeline_env_flags_loaded) return;
    pipeline_env_flags = .{
        .progress = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_PROGRESS"),
        .global_progress = envFlagEnabledRaw("GEN_Z_SITTER_PROGRESS"),
        .profile = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_PROFILE"),
        .has_target_filter = hasProgressTargetFilterRaw(),
    };
    pipeline_env_flags_loaded = true;
}

fn hasProgressTargetFilter() bool {
    ensurePipelineEnvFlags();
    return pipeline_env_flags.has_target_filter;
}

pub fn setScopedProgressEnabled(enabled: bool) void {
    scoped_progress_enabled = enabled;
}

fn shouldLogPipelineProgress() bool {
    ensurePipelineEnvFlags();
    const requested =
        pipeline_env_flags.progress or
        pipeline_env_flags.global_progress;
    if (!requested) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn shouldProfilePipeline() bool {
    ensurePipelineEnvFlags();
    if (!pipeline_env_flags.profile) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn logPipelineStart(step: []const u8) void {
    std.debug.print("[parse_table_pipeline] start {s}\n", .{step});
}

fn logPipelineDone(step: []const u8) void {
    std.debug.print("[parse_table_pipeline] done  {s}\n", .{step});
}

fn maybeStartTimer(enabled: bool) bool {
    return enabled;
}

fn maybeLogPipelineDone(step: []const u8, enabled: bool) void {
    if (enabled) logPipelineDone(step);
}

fn logPipelineSummary(comptime format: []const u8, args: anytype) void {
    std.debug.print("[parse_table_pipeline] " ++ format ++ "\n", args);
}

fn profileTimer(enabled: bool) ?std.Io.Timestamp {
    if (!enabled) return null;
    return std.Io.Timestamp.now(runtime_io.get(), .awake);
}

fn logProfileDone(step: []const u8, timer: ?std.Io.Timestamp) void {
    const start = timer orelse return;
    const elapsed_ms = @as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake)).nanoseconds)) /
        @as(f64, std.time.ns_per_ms);
    std.debug.print("[parse_table_pipeline_profile] stage={s} elapsed_ms={d:.2}\n", .{ step, elapsed_ms });
}

pub const PipelineError =
    extract_tokens.ExtractTokensError ||
    flatten_grammar.FlattenGrammarError ||
    lexer_model.ExpandError ||
    build.BuildError ||
    serialize.SerializeError ||
    lexer_serialize.SerializeError ||
    parser_tables_emit.EmitError ||
    parser_c_emit.EmitError ||
    debug_dump.DebugDumpError ||
    std.json.ParseError(std.json.Scanner) ||
    std.mem.Allocator.Error ||
    error{ UnknownRule, UnusedExpectedConflict };

pub const ExpectedConflictReport = struct {
    unused_expected_conflict_indexes: []const usize,

    pub fn hasUnusedExpectedConflicts(self: ExpectedConflictReport) bool {
        return self.unused_expected_conflict_indexes.len != 0;
    }
};

pub fn validateExpectedConflictReport(report: ExpectedConflictReport) error{UnusedExpectedConflict}!void {
    if (report.hasUnusedExpectedConflicts()) return error.UnusedExpectedConflict;
}

pub fn validateResolvedConflictPolicy(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
) (std.mem.Allocator.Error || error{ UnresolvedDecisions, UnusedExpectedConflict })!void {
    try result.validateBlockingConflictPolicy();
    const report = try expectedConflictReportFromBuildResultAlloc(allocator, result);
    try validateExpectedConflictReport(report);
}

pub fn generateStateDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const default_aliases = try extract_default_aliases.extractDefaultAliases(allocator, extracted.syntax, extracted.lexical);
    const flattened = try flatten_grammar.flattenGrammar(allocator, default_aliases.syntax);
    const result = try build.buildStates(allocator, flattened);
    return try debug_dump.dumpStatesAlloc(allocator, result.states);
}

pub fn buildStatesFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError!build.BuildResult {
    return try buildStatesFromPreparedWithOptions(allocator, prepared, .{});
}

pub fn buildStatesFromPreparedStrictExpectedConflicts(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError!build.BuildResult {
    const result = try buildStatesFromPrepared(allocator, prepared);
    try validateResolvedConflictPolicy(allocator, result);
    return result;
}

pub fn buildStatesFromPreparedWithOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    build_options: build.BuildOptions,
) PipelineError!build.BuildResult {
    const progress_log = shouldLogPipelineProgress();
    const profile_log = shouldProfilePipeline();

    var timer = maybeStartTimer(progress_log);
    var stage_profile_timer = profileTimer(profile_log);
    if (progress_log) logPipelineStart("extract_tokens");
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    logProfileDone("extract_tokens", stage_profile_timer);
    if (progress_log) maybeLogPipelineDone("extract_tokens", timer);

    timer = maybeStartTimer(progress_log);
    stage_profile_timer = profileTimer(profile_log);
    if (progress_log) logPipelineStart("flatten_grammar");
    const default_aliases = try extract_default_aliases.extractDefaultAliases(allocator, extracted.syntax, extracted.lexical);
    const flattened = try flatten_grammar.flattenGrammar(allocator, default_aliases.syntax);
    const simple_alias_symbols = try simpleAliasSymbolsAlloc(allocator, default_aliases.defaults);
    const reserved_words = try serialize.buildReservedWordsAlloc(allocator, prepared, extracted.lexical);
    logProfileDone("flatten_grammar", stage_profile_timer);
    if (progress_log) maybeLogPipelineDone("flatten_grammar", timer);

    timer = maybeStartTimer(progress_log);
    stage_profile_timer = profileTimer(profile_log);
    if (progress_log) logPipelineStart("build_states");
    var effective_build_options = build_options;
    effective_build_options.reserved_word_context_names = try reservedWordContextNamesAlloc(allocator, prepared.reserved_word_sets);
    effective_build_options.non_terminal_extra_symbols = try nonTerminalExtraSymbolsAlloc(allocator, flattened.extra_symbols);
    effective_build_options.terminal_extra_symbols = try terminalExtraSymbolsAlloc(allocator, flattened.extra_symbols);
    effective_build_options.simple_alias_symbols = simple_alias_symbols;
    effective_build_options.reserved_word_sets = reserved_words.sets;
    effective_build_options.state_zero_error_recovery = true;
    var owned_lex_conflicts: ?build.LexStateTerminalConflictMap = null;
    defer if (owned_lex_conflicts) |conflicts| {
        allocator.free(conflicts.match_shorter_or_longer);
        allocator.free(conflicts.conflict_or_prefixes);
        allocator.free(conflicts.overlaps);
        allocator.free(conflicts.merge_overlaps);
        allocator.free(conflicts.keyword_tokens);
        allocator.free(conflicts.external_internal_tokens);
        allocator.free(conflicts.conflicts);
        allocator.free(conflicts.terminal_names);
    };
    if (effective_build_options.lex_state_terminal_conflicts == null) {
        owned_lex_conflicts = lexStateTerminalConflictMapAlloc(
            allocator,
            prepared.rules,
            flattened,
            extracted.lexical,
            reserved_words.sets,
            effective_build_options.reserved_word_context_names,
        ) catch |err| switch (err) {
            error.UnsupportedRule, error.UnsupportedPattern => null,
            else => return err,
        };
        if (owned_lex_conflicts) |conflicts| {
            effective_build_options.lex_state_terminal_conflicts = conflicts;
        }
    }
    defer allocator.free(effective_build_options.non_terminal_extra_symbols);
    defer allocator.free(effective_build_options.terminal_extra_symbols);
    defer allocator.free(effective_build_options.reserved_word_context_names);
    defer allocator.free(simple_alias_symbols);
    defer serialize.deinitReservedWords(allocator, reserved_words);
    const result = try build.buildStatesWithOptions(allocator, flattened, effective_build_options);
    if (effective_build_options.strict_expected_conflicts) {
        try validateResolvedConflictPolicy(allocator, result);
    }
    logProfileDone("build_states", stage_profile_timer);
    if (progress_log) {
        maybeLogPipelineDone("build_states", timer);
        logPipelineSummary(
            "build_states summary states={d} unresolved_decisions={} serialization_ready={}",
            .{ result.states.len, result.hasUnresolvedDecisions(), result.isSerializationReady() },
        );
    }
    return result;
}

pub fn expectedConflictReportFromPreparedAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError!ExpectedConflictReport {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try expectedConflictReportFromBuildResultAlloc(allocator, result);
}

pub fn expectedConflictReportFromBuildResultAlloc(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
) std.mem.Allocator.Error!ExpectedConflictReport {
    return .{
        .unused_expected_conflict_indexes = try result.unusedExpectedConflictIndexesAlloc(allocator),
    };
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

fn nonTerminalExtraSymbolsAlloc(
    allocator: std.mem.Allocator,
    extra_symbols: []const @import("../ir/syntax_grammar.zig").SymbolRef,
) std.mem.Allocator.Error![]const @import("../ir/syntax_grammar.zig").SymbolRef {
    var symbols = std.array_list.Managed(@import("../ir/syntax_grammar.zig").SymbolRef).init(allocator);
    defer symbols.deinit();
    for (extra_symbols) |symbol| {
        if (symbol == .non_terminal) try symbols.append(symbol);
    }
    return try symbols.toOwnedSlice();
}

fn terminalExtraSymbolsAlloc(
    allocator: std.mem.Allocator,
    extra_symbols: []const @import("../ir/syntax_grammar.zig").SymbolRef,
) std.mem.Allocator.Error![]const @import("../ir/syntax_grammar.zig").SymbolRef {
    var symbols = std.array_list.Managed(@import("../ir/syntax_grammar.zig").SymbolRef).init(allocator);
    defer symbols.deinit();
    for (extra_symbols) |symbol| {
        switch (symbol) {
            .terminal, .external => try symbols.append(symbol),
            .end, .non_terminal => {},
        }
    }
    return try symbols.toOwnedSlice();
}

fn simpleAliasSymbolsAlloc(
    allocator: std.mem.Allocator,
    aliases: alias_ir.AliasMap,
) std.mem.Allocator.Error![]const @import("../ir/syntax_grammar.zig").SymbolRef {
    var symbols = std.array_list.Managed(@import("../ir/syntax_grammar.zig").SymbolRef).init(allocator);
    defer symbols.deinit();
    for (aliases.entries) |entry| {
        switch (entry.target) {
            .symbol => |symbol| try symbols.append(symbol),
            else => {},
        }
    }
    return try symbols.toOwnedSlice();
}

fn lexStateTerminalConflictMapAlloc(
    allocator: std.mem.Allocator,
    all_rules: []const ir_rules.Rule,
    syntax: @import("../ir/syntax_grammar.zig").SyntaxGrammar,
    lexical: @import("../ir/lexical_grammar.zig").LexicalGrammar,
    reserved_word_sets: []const []const @import("../ir/syntax_grammar.zig").SymbolRef,
    reserved_word_context_names: []const []const u8,
) (lexer_model.ExpandError || std.mem.Allocator.Error || first.FirstError)!build.LexStateTerminalConflictMap {
    var expanded = try lexer_model.expandExtractedLexicalGrammar(allocator, all_rules, lexical);
    defer expanded.deinit(allocator);

    const following_tokens = try lexer_model.computeFollowingTokensWithReservedAlloc(
        allocator,
        syntax,
        expanded.variables.len,
        reserved_word_sets,
        reserved_word_context_names,
    );
    defer lexer_model.deinitTokenIndexSets(allocator, following_tokens);

    var conflict_map = try lexer_model.buildTokenConflictMapWithFollowingTokensAlloc(
        allocator,
        expanded,
        following_tokens,
    );
    defer conflict_map.deinit(allocator);

    const terminal_count = expanded.variables.len;
    const conflicts = try allocator.alloc(bool, terminal_count * terminal_count);
    errdefer allocator.free(conflicts);
    @memset(conflicts, false);
    const match_shorter_or_longer = try allocator.alloc(bool, terminal_count * terminal_count);
    errdefer allocator.free(match_shorter_or_longer);
    @memset(match_shorter_or_longer, false);
    const conflict_or_prefixes = try allocator.alloc(bool, terminal_count * terminal_count);
    errdefer allocator.free(conflict_or_prefixes);
    @memset(conflict_or_prefixes, false);
    const overlaps = try allocator.alloc(bool, terminal_count * terminal_count);
    errdefer allocator.free(overlaps);
    @memset(overlaps, false);
    const merge_overlaps = try allocator.alloc(bool, terminal_count * terminal_count);
    errdefer allocator.free(merge_overlaps);
    @memset(merge_overlaps, false);
    const keyword_tokens = try allocator.alloc(bool, terminal_count);
    errdefer allocator.free(keyword_tokens);
    @memset(keyword_tokens, false);
    const external_internal_tokens = try allocator.alloc(bool, terminal_count);
    errdefer allocator.free(external_internal_tokens);
    @memset(external_internal_tokens, false);
    const terminal_names = try allocator.alloc([]const u8, terminal_count);
    errdefer allocator.free(terminal_names);
    for (expanded.variables, 0..) |variable, index| terminal_names[index] = variable.name;

    const word_token = build.minimizeWordToken(syntax);
    const word_terminal = switch (word_token orelse .end) {
        .terminal => |index| index,
        else => null,
    };
    if (word_terminal) |word_index| {
        for (expanded.variables, 0..) |_, index| {
            if (index >= lexical.variables.len) continue;
            if (lexical.variables[index].source_kind != .string) continue;
            const left_status = conflict_map.status(index, word_index);
            keyword_tokens[index] = tokenStatusMarksKeyword(left_status);
        }
    }

    for (syntax.external_tokens) |external| {
        const internal = external.corresponding_internal_token orelse continue;
        switch (internal) {
            .terminal => |index| {
                if (index < terminal_count) external_internal_tokens[index] = true;
            },
            else => {},
        }
    }

    for (0..terminal_count) |left| {
        for (0..terminal_count) |right| {
            if (left == right) continue;
            const status = conflict_map.status(left, right);
            const reverse = conflict_map.status(right, left);
            conflicts[left * terminal_count + right] =
                status.does_match_valid_continuation or
                status.does_match_separators or
                status.matches_same_string;
            match_shorter_or_longer[left * terminal_count + right] =
                (status.does_match_valid_continuation or status.does_match_separators) and
                !reverse.does_match_separators;
            conflict_or_prefixes[left * terminal_count + right] =
                status.does_match_valid_continuation or
                status.does_match_separators or
                status.matches_same_string or
                status.matches_prefix;
            overlaps[left * terminal_count + right] =
                status.does_match_separators or
                status.matches_prefix or
                status.matches_same_string or
                status.does_match_continuation;
            merge_overlaps[left * terminal_count + right] =
                status.does_match_separators or
                status.matches_prefix or
                status.matches_same_string or
                status.does_match_continuation;
        }
    }

    return .{
        .terminal_count = terminal_count,
        .conflicts = conflicts,
        .match_shorter_or_longer = match_shorter_or_longer,
        .conflict_or_prefixes = conflict_or_prefixes,
        .overlaps = overlaps,
        .merge_overlaps = merge_overlaps,
        .keyword_tokens = keyword_tokens,
        .external_internal_tokens = external_internal_tokens,
        .terminal_names = terminal_names,
    };
}

fn tokenStatusMarksKeyword(status: lexer_model.TokenConflictStatus) bool {
    return status.matches_same_string and !status.matches_different_string;
}

pub fn generateStateActionDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try debug_dump.dumpStatesWithActionsAlloc(allocator, result.states, result.actions);
}

pub fn generateStateActionDumpForRuleFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    rule_name: []const u8,
) PipelineError![]const u8 {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const default_aliases = try extract_default_aliases.extractDefaultAliases(allocator, extracted.syntax, extracted.lexical);
    const flattened = try flatten_grammar.flattenGrammar(allocator, default_aliases.syntax);
    const result = try build.buildStates(allocator, flattened);

    const matching_variables = try allocator.alloc(bool, flattened.variables.len);
    defer allocator.free(matching_variables);
    @memset(matching_variables, false);

    var found_rule = false;
    for (flattened.variables, 0..) |variable, index| {
        if (std.mem.eql(u8, variable.name, rule_name)) {
            matching_variables[index] = true;
            found_rule = true;
        }
    }
    if (!found_rule) return error.UnknownRule;

    var selected = std.array_list.Managed(state.ParseState).init(allocator);
    defer selected.deinit();
    for (result.states) |parse_state| {
        if (stateReferencesAnyVariable(parse_state, result.productions, matching_variables)) {
            try selected.append(parse_state);
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("rule {s}\n", .{rule_name});
    if (selected.items.len == 0) {
        try out.writer.writeAll("  states: []\n");
    } else {
        try out.writer.writeByte('\n');
        try debug_dump.writeStatesWithActions(&out.writer, selected.items, result.actions);
        try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

fn stateReferencesAnyVariable(
    parse_state: state.ParseState,
    productions: []const build.ProductionInfo,
    matching_variables: []const bool,
) bool {
    for (parse_state.items) |entry| {
        const production_id: usize = @intCast(entry.item.production_id);
        if (production_id >= productions.len) continue;
        const lhs = productions[production_id].lhs;
        if (lhs < matching_variables.len and matching_variables[lhs]) return true;
    }
    return false;
}

pub fn generateActionTableDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try debug_dump.dumpActionTableAlloc(allocator, result.states, result.actions);
}

pub fn generateGroupedActionTableDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try debug_dump.dumpGroupedActionTableAlloc(allocator, result.states, result.actions);
}

pub fn generateResolvedActionTableDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    return try debug_dump.dumpResolvedActionTableAlloc(allocator, result.resolved_actions);
}

pub fn generateSerializedTableDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    const serialized = try serializePreparedBuildResultAlloc(allocator, prepared, result, mode, true);
    return try debug_dump.dumpSerializedTableAlloc(allocator, serialized);
}

pub fn generateParserTableEmitterDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError![]const u8 {
    return try generateParserTableEmitterDumpFromPreparedWithOptions(allocator, prepared, mode, .{});
}

pub fn generateParserTableEmitterDumpFromPreparedWithOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
    options: emit_optimize.Options,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    const serialized = try serializePreparedBuildResultAlloc(allocator, prepared, result, mode, true);
    return try parser_tables_emit.emitSerializedTableAllocWithOptions(allocator, serialized, options);
}

pub fn generateParserCEmitterDumpFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError![]const u8 {
    return try generateParserCEmitterDumpFromPreparedWithOptions(allocator, prepared, mode, .{});
}

pub fn generateParserCEmitterDumpFromPreparedWithOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
    options: emit_optimize.Options,
) PipelineError![]const u8 {
    const result = try buildStatesFromPrepared(allocator, prepared);
    const serialized = try serializePreparedBuildResultAlloc(allocator, prepared, result, mode, true);
    return try parser_c_emit.emitParserCAllocWithOptions(allocator, serialized, options);
}

pub fn generateParserCEmitterDumpFromGrammarPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: serialize.SerializeMode,
    options: emit_optimize.Options,
) (PipelineError || grammar_loader.LoaderError || parse_grammar.ParseGrammarError)![]const u8 {
    var loaded = try grammar_loader.loadGrammarFile(allocator, path);
    defer loaded.deinit();
    const prepared = try parse_grammar.parseRawGrammar(allocator, &loaded.json.grammar);
    return try generateParserCEmitterDumpFromPreparedWithOptions(allocator, prepared, mode, options);
}

pub fn serializeTableFromGrammarPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: serialize.SerializeMode,
) (PipelineError || grammar_loader.LoaderError || parse_grammar.ParseGrammarError)!serialize.SerializedTable {
    var loaded = try grammar_loader.loadGrammarFile(allocator, path);
    defer loaded.deinit();
    const prepared = try parse_grammar.parseRawGrammar(allocator, &loaded.json.grammar);
    return try serializeTableFromPrepared(allocator, prepared, mode);
}

pub fn serializeRuntimeTableFromGrammarPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: serialize.SerializeMode,
) (PipelineError || grammar_loader.LoaderError || parse_grammar.ParseGrammarError)!serialize.SerializedTable {
    return try serializeRuntimeTableFromGrammarPathMaybeProfile(allocator, path, mode, .{}, null);
}

pub fn serializeRuntimeTableFromGrammarPathWithProfile(
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: serialize.SerializeMode,
    profile_label: []const u8,
) (PipelineError || grammar_loader.LoaderError || parse_grammar.ParseGrammarError)!serialize.SerializedTable {
    return try serializeRuntimeTableFromGrammarPathMaybeProfile(allocator, path, mode, .{}, profile_label);
}

pub fn serializeRuntimeTableFromGrammarPathWithBuildOptions(
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: serialize.SerializeMode,
    build_options: build.BuildOptions,
) (PipelineError || grammar_loader.LoaderError || parse_grammar.ParseGrammarError)!serialize.SerializedTable {
    return try serializeRuntimeTableFromGrammarPathMaybeProfile(allocator, path, mode, build_options, null);
}

pub fn serializeRuntimeTableFromGrammarPathWithBuildOptionsProfile(
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: serialize.SerializeMode,
    build_options: build.BuildOptions,
    profile_label: []const u8,
) (PipelineError || grammar_loader.LoaderError || parse_grammar.ParseGrammarError)!serialize.SerializedTable {
    return try serializeRuntimeTableFromGrammarPathMaybeProfile(allocator, path, mode, build_options, profile_label);
}

fn serializeRuntimeTableFromGrammarPathMaybeProfile(
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: serialize.SerializeMode,
    build_options: build.BuildOptions,
    profile_label: ?[]const u8,
) (PipelineError || grammar_loader.LoaderError || parse_grammar.ParseGrammarError)!serialize.SerializedTable {
    const total_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);

    const load_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    var loaded = try grammar_loader.loadGrammarFile(allocator, path);
    defer loaded.deinit();
    logRuntimeProfile(profile_label, "load", load_timer);

    const prepare_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const prepared = try parse_grammar.parseRawGrammar(allocator, &loaded.json.grammar);
    logRuntimeProfile(profile_label, "prepare", prepare_timer);

    const serialize_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    var serialized = try serializeTableFromPreparedWithBuildOptions(allocator, prepared, mode, build_options);
    logRuntimeProfile(profile_label, "serialize_parse_table", serialize_timer);

    const extract_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    logRuntimeProfile(profile_label, "extract_tokens", extract_timer);

    const eof_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const eof_valids = try eofValidLexStatesAlloc(allocator, serialized);
    logRuntimeProfile(profile_label, "eof_valids", eof_timer);

    const lex_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const runtime_lex_terminal_sets = try serialize.buildKeywordCaptureLexTerminalSetsAlloc(
        allocator,
        serialized.lex_state_terminal_sets,
        prepared,
        extracted.lexical,
        extracted.syntax.word_token,
    );
    defer serialize.deinitLexStateTerminalSets(allocator, runtime_lex_terminal_sets);
    serialized.lex_tables = try lexer_serialize.buildSharedSerializedLexTablesWithEofAlloc(
        allocator,
        prepared.rules,
        extracted.lexical,
        runtime_lex_terminal_sets,
        eof_valids,
    );
    logRuntimeProfile(profile_label, "build_lex_tables", lex_timer);
    logRuntimeProfile(profile_label, "total_runtime_serialize", total_timer);
    return serialized;
}

fn logRuntimeProfile(profile_label: ?[]const u8, stage: []const u8, start: std.Io.Timestamp) void {
    const label = profile_label orelse return;
    const duration = start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake));
    const elapsed_ms = @as(f64, @floatFromInt(duration.nanoseconds)) / @as(f64, std.time.ns_per_ms);
    std.debug.print("[runtime-serialize-profile] {s} {s}_ms={d:.2}\n", .{ label, stage, elapsed_ms });
}

fn eofValidLexStatesAlloc(
    allocator: std.mem.Allocator,
    serialized: serialize.SerializedTable,
) std.mem.Allocator.Error![]const bool {
    const values = try allocator.alloc(bool, serialized.lex_state_terminal_sets.len);
    @memset(values, false);
    for (serialized.states) |state_value| {
        if (state_value.lex_state_id >= values.len) continue;
        for (state_value.actions) |entry| {
            if (entry.symbol == .end) {
                values[state_value.lex_state_id] = true;
                break;
            }
        }
    }
    return values;
}

pub fn serializeTableFromPrepared(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
) PipelineError!serialize.SerializedTable {
    return try serializeTableFromPreparedWithBuildOptions(allocator, prepared, mode, .{});
}

pub fn serializeTableFromPreparedWithBuildOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    mode: serialize.SerializeMode,
    build_options: build.BuildOptions,
) PipelineError!serialize.SerializedTable {
    const progress_log = shouldLogPipelineProgress();
    const profile_log = shouldProfilePipeline();
    const result = try buildStatesFromPreparedWithOptions(allocator, prepared, build_options);
    const timer = maybeStartTimer(progress_log);
    const stage_profile_timer = profileTimer(profile_log);
    if (progress_log) logPipelineStart("serialize_build_result");
    const serialized = try serializePreparedBuildResultAlloc(allocator, prepared, result, mode, build_options.include_unresolved_parse_actions);
    logProfileDone("serialize_build_result", stage_profile_timer);
    if (progress_log) {
        maybeLogPipelineDone("serialize_build_result", timer);
        logPipelineSummary(
            "serialize_build_result summary mode={s} serialized_states={d} blocked={}",
            .{ @tagName(mode), serialized.states.len, serialized.blocked },
        );
    }
    return serialized;
}

fn serializePreparedBuildResultAlloc(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    result: build.BuildResult,
    mode: serialize.SerializeMode,
    include_unresolved_parse_actions: bool,
) PipelineError!serialize.SerializedTable {
    const profile_log = shouldProfilePipeline();
    var stage_profile_timer = profileTimer(profile_log);
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    logProfileDone("serialize.extract_tokens", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    const default_aliases = try extract_default_aliases.extractDefaultAliases(allocator, extracted.syntax, extracted.lexical);
    logProfileDone("serialize.extract_default_aliases", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    const flattened = try flatten_grammar.flattenGrammar(allocator, default_aliases.syntax);
    logProfileDone("serialize.flatten_grammar", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    const first_sets = try first.computeFirstSets(allocator, flattened);
    logProfileDone("serialize.compute_first_sets", stage_profile_timer);

    stage_profile_timer = profileTimer(profile_log);
    var serialized = try serialize.attachExtractedMetadataAlloc(
        allocator,
        try serialize.serializeBuildResultWithOptions(allocator, result, mode, .{
            .include_unresolved_parse_actions = include_unresolved_parse_actions,
        }),
        prepared,
        extracted.syntax,
        extracted.lexical,
        default_aliases.defaults,
    );
    logProfileDone("serialize.build_result_and_metadata", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    serialized = try serialize.attachExtraShiftMetadataWithOptionsAlloc(
        allocator,
        serialized,
        extracted.syntax.extra_symbols,
        .{ .include_unresolved_parse_actions = include_unresolved_parse_actions },
    );
    logProfileDone("serialize.extra_shift_metadata", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    serialized = try serialize.attachRepetitionShiftMetadataWithFirstSetsAndOptionsAlloc(
        allocator,
        serialized,
        result.states,
        result.productions,
        first_sets,
        .{
            .include_unresolved_parse_actions = include_unresolved_parse_actions,
            .external_internal_tokens = result.external_internal_tokens,
        },
    );
    logProfileDone("serialize.repetition_shift_metadata", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    serialized = try serialize.attachReservedWordsAlloc(
        allocator,
        serialized,
        prepared,
        extracted.lexical,
    );
    logProfileDone("serialize.reserved_words", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    serialized = try serialize.attachReservedWordLexModesAlloc(
        allocator,
        serialized,
        result.states,
    );
    logProfileDone("serialize.reserved_word_lex_modes", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    serialized = try serialize.attachNonTerminalExtraLexModesAlloc(
        allocator,
        serialized,
        result.states,
        result.productions,
        extracted.syntax.extra_symbols,
    );
    logProfileDone("serialize.non_terminal_extra_lex_modes", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    serialized = try serialize.attachKeywordLexTableAlloc(
        allocator,
        serialized,
        prepared,
        extracted.lexical,
    );
    logProfileDone("serialize.keyword_lex_table", stage_profile_timer);
    stage_profile_timer = profileTimer(profile_log);
    const lex_terminal_sets = try serialize.buildKeywordCaptureLexTerminalSetsAlloc(
        allocator,
        serialized.lex_state_terminal_sets,
        prepared,
        extracted.lexical,
        extracted.syntax.word_token,
    );
    defer serialize.deinitLexStateTerminalSets(allocator, lex_terminal_sets);
    serialized.lex_tables = try lexer_serialize.buildSharedSerializedLexTablesAlloc(
        allocator,
        prepared.rules,
        extracted.lexical,
        lex_terminal_sets,
    );
    logProfileDone("serialize.lex_tables", stage_profile_timer);
    return serialized;
}

fn writeModuleExportsJsonFile(dir: std.Io.Dir, sub_path: []const u8, json_contents: []const u8) !void {
    const js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{json_contents});
    defer std.testing.allocator.free(js);
    try dir.writeFile(std.testing.io, .{
        .sub_path = sub_path,
        .data = js,
    });
}

fn expectParserCDumpCompiles(contents: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "parser.c",
        .data = contents,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "parser.c", std.testing.allocator);
    defer std.testing.allocator.free(source_path);

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    const object_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "parser.o" });
    defer std.testing.allocator.free(object_path);

    var result = try process_support.runCapture(
        std.testing.allocator,
        &.{ "zig", "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-c", source_path, "-o", object_path },
    );
    defer result.deinit(std.testing.allocator);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("zig cc stderr:\n{s}\n", .{result.stderr});
                try std.testing.expectEqual(@as(u8, 0), code);
            }
        },
        else => return error.UnexpectedCompilerTermination,
    }
}

test "generateStateDumpFromPrepared matches the tiny parser-state golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableTinyGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableTinyDump().contents, dump);
}

test "generateStateActionDumpFromPrepared matches the tiny parser-state action golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableTinyGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(
        \\state 0
        \\  items:
        \\  transitions:
        \\  actions:
        \\
        \\state 1
        \\  items:
        \\    #1@0 [end]
        \\    #0@0 [end]
        \\  transitions:
        \\    terminal:0 -> 2
        \\    non_terminal:0 -> 3
        \\  actions:
        \\    terminal:0 => shift 2
        \\
        \\state 2
        \\  items:
        \\    #1@1 [end]
        \\  transitions:
        \\  actions:
        \\    end => reduce 1
        \\
        \\state 3
        \\  items:
        \\    #0@1 [end]
        \\  transitions:
        \\  actions:
        \\    end => accept
        \\
    , dump);
}

test "generateStateActionDumpForRuleFromPrepared filters parser-state actions by rule name" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.validResolvedGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpForRuleFromPrepared(pipeline_arena.allocator(), prepared, "expr");

    try std.testing.expect(std.mem.startsWith(u8, dump, "rule expr\n\nstate "));
    try std.testing.expect(std.mem.containsAtLeast(u8, dump, 1, "actions:\n"));
    try std.testing.expectError(
        error.UnknownRule,
        generateStateActionDumpForRuleFromPrepared(pipeline_arena.allocator(), prepared, "missing_rule"),
    );
}

test "buildStatesFromPrepared reports a focused shift/reduce conflict fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    var saw_shift_reduce = false;
    for (result.states) |parse_state| {
        for (parse_state.conflicts) |conflict| {
            if (conflict.kind == .shift_reduce) {
                saw_shift_reduce = true;
                try std.testing.expect(conflict.symbol != null);
            }
        }
    }

    try std.testing.expect(saw_shift_reduce);
}

test "generateStateDumpFromPrepared matches the conflict parser-state golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableConflictDump().contents, dump);
}

test "generateStateActionDumpFromPrepared matches the conflict parser-state action golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableConflictActionDump().contents, dump);
}

test "generateActionTableDumpFromPrepared matches the conflict action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableConflictActionTableDump().contents, dump);
}

test "generateGroupedActionTableDumpFromPrepared matches the conflict grouped action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateGroupedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableConflictGroupedActionTableDump().contents, dump);
}

test "generateGroupedActionTableDumpFromPrepared matches the tiny grouped action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableTinyGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateGroupedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableTinyGroupedActionTableDump().contents, dump);
}

test "generateGroupedActionTableDumpFromPrepared matches the reduce/reduce grouped action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateGroupedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableReduceReduceGroupedActionTableDump().contents, dump);
}

test "generateActionTableDumpFromPrepared matches the reduce/reduce action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableReduceReduceActionTableDump().contents, dump);
}

test "generateActionTableDumpFromPrepared matches the metadata-rich action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataActionTableDump().contents, dump);
}

test "generateGroupedActionTableDumpFromPrepared matches the metadata-rich grouped action-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateGroupedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataGroupedActionTableDump().contents, dump);
}

test "generateStateActionDumpFromPrepared matches the reduce/reduce parser-state action golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableReduceReduceActionDump().contents, dump);
}

test "buildStatesFromPrepared reuses identical advanced states deterministically" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqual(@as(state.StateId, 2), result.states[1].transitions[0].state);
    try std.testing.expectEqual(result.states[1].transitions[0].state, result.states[4].transitions[0].state);
}

test "buildStatesFromPrepared reports a focused reduce/reduce conflict fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    var saw_reduce_reduce = false;
    for (result.states) |parse_state| {
        for (parse_state.conflicts) |conflict| {
            if (conflict.kind == .reduce_reduce) {
                saw_reduce_reduce = true;
                try std.testing.expect(conflict.symbol != null);
                try std.testing.expectEqual(@as(u32, 0), conflict.symbol.?.terminal);
                try std.testing.expectEqual(@as(usize, 2), conflict.items.len);
            }
        }
    }

    try std.testing.expect(saw_reduce_reduce);
}

test "buildStatesFromPrepared supports metadata-rich grammar through the real preparation path" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqual(@as(usize, 6), result.states.len);
    try std.testing.expect(result.states[1].transitions.len >= 2);
    try std.testing.expectEqual(result.states.len, result.resolved_actions.states.len);
    try std.testing.expect(result.resolved_actions.groupsForState(result.states[1].id).len > 0);
    try std.testing.expect(result.isSerializationReady());
    try std.testing.expect(!result.hasUnresolvedDecisions());
    const chosen = try result.chosenDecisionsAlloc(pipeline_arena.allocator());
    try std.testing.expect(chosen.len > 0);
    const snapshot = try result.decisionSnapshotAlloc(pipeline_arena.allocator());
    try std.testing.expect(snapshot.isSerializationReady());
    try std.testing.expect(snapshot.unresolved.len == 0);
    try std.testing.expect(snapshot.chosen.len > 0);
}

test "resolveActionTableSkeleton leaves the first precedence-sensitive grammar unresolved" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTablePrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);
    const raw_actions = try actions.buildActionTable(pipeline_arena.allocator(), result.productions, result.states);
    const grouped = try actions.groupActionTable(pipeline_arena.allocator(), raw_actions);
    const resolved = try resolution.resolveActionTableSkeleton(pipeline_arena.allocator(), grouped);

    var saw_unresolved = false;
    for (result.states) |parse_state| {
        for (parse_state.conflicts) |conflict| {
            if (conflict.kind != .shift_reduce) continue;
            if (conflict.symbol == null) continue;

            const decision = resolved.decisionFor(parse_state.id, conflict.symbol.?) orelse continue;
            try std.testing.expectEqual(
                resolution.UnresolvedReason.shift_reduce,
                switch (decision) {
                    .chosen => unreachable,
                    .unresolved => |reason| reason,
                },
            );
            try std.testing.expect(
                resolved.candidateActionsFor(parse_state.id, conflict.symbol.?).len >= 2,
            );
            saw_unresolved = true;
        }
    }

    try std.testing.expect(saw_unresolved);
}

test "generateResolvedActionTableDumpFromPrepared chooses reduce for the first precedence-sensitive grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTablePrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTablePrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared chooses reduce for the first named-precedence grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNamedPrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNamedPrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared chooses shift for the second named-precedence grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNamedPrecedenceShiftGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNamedPrecedenceShiftResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared leaves positive dynamic-precedence conflicts unresolved" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableDynamicPrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableDynamicPrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared leaves negative dynamic-precedence conflicts unresolved" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNegativeDynamicPrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNegativeDynamicPrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared lets dynamic precedence outrank named precedence" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableDynamicBeatsNamedPrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableDynamicBeatsNamedPrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared chooses shift for the first negative-precedence grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNegativePrecedenceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNegativePrecedenceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared keeps unresolved conflict groups explicit" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expect(!result.isSerializationReady());
    try std.testing.expect(result.hasUnresolvedDecisions());
    const unresolved = try result.unresolvedDecisionsAlloc(pipeline_arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), unresolved.len);
    try std.testing.expectEqual(resolution.UnresolvedReason.shift_reduce, unresolved[0].reason);
    const snapshot = try result.decisionSnapshotAlloc(pipeline_arena.allocator());
    try std.testing.expect(!snapshot.isSerializationReady());
    try std.testing.expect(snapshot.unresolved.len == 1);
    try std.testing.expectEqualStrings(fixtures.parseTableConflictResolvedActionDump().contents, dump);
}

test "buildStatesFromPrepared serializes metadata-rich grammar in strict mode" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);
    const serialized = try serialize.serializeBuildResult(
        pipeline_arena.allocator(),
        result,
        .strict,
    );

    try std.testing.expect(serialized.isSerializationReady());
    try std.testing.expect(serialized.states.len > 0);
}

test "buildStatesFromPrepared rejects unresolved conflict grammar in strict serialization mode" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectError(
        error.UnresolvedDecisions,
        serialize.serializeBuildResult(pipeline_arena.allocator(), result, .strict),
    );
}

test "validateResolvedConflictPolicy rejects blocking shift reduce conflicts" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expect(result.hasBlockingUnresolvedDecisions());
    try std.testing.expectError(
        error.UnresolvedDecisions,
        validateResolvedConflictPolicy(pipeline_arena.allocator(), result),
    );
}

test "expectedConflictReportFromPrepared reports unused expected conflicts" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const contents =
        \\{
        \\  "name": "unused_expected_conflict",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const report = try expectedConflictReportFromPreparedAlloc(pipeline_arena.allocator(), prepared);

    try std.testing.expect(report.hasUnusedExpectedConflicts());
    try std.testing.expectEqual(@as(usize, 1), report.unused_expected_conflict_indexes.len);
    try std.testing.expectEqual(@as(usize, 0), report.unused_expected_conflict_indexes[0]);
}

test "buildStatesFromPreparedStrictExpectedConflicts rejects unused expected conflicts" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const contents =
        \\{
        \\  "name": "strict_unused_expected_conflict",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);

    const default_result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);
    try std.testing.expect(default_result.states.len > 0);
    try std.testing.expectError(
        error.UnusedExpectedConflict,
        buildStatesFromPreparedStrictExpectedConflicts(pipeline_arena.allocator(), prepared),
    );
}

test "buildStatesFromPreparedWithOptions rejects unused expected conflicts when strict flag is set" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const contents =
        \\{
        \\  "name": "strict_option_unused_expected_conflict",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);

    const default_result = try buildStatesFromPreparedWithOptions(
        pipeline_arena.allocator(),
        prepared,
        .{},
    );
    try std.testing.expect(default_result.states.len > 0);

    try std.testing.expectError(
        error.UnusedExpectedConflict,
        buildStatesFromPreparedWithOptions(
            pipeline_arena.allocator(),
            prepared,
            .{ .strict_expected_conflicts = true },
        ),
    );
}

test "validateResolvedConflictPolicy allows expected reduce reduce conflicts" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const contents =
        \\{
        \\  "name": "expected_reduce_reduce",
        \\  "expected_conflicts": [["lhs", "rhs"]],
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "SEQ",
        \\      "members": [
        \\        { "type": "SYMBOL", "name": "start" },
        \\        { "type": "STRING", "value": "+" }
        \\      ]
        \\    },
        \\    "start": {
        \\      "type": "CHOICE",
        \\      "members": [
        \\        { "type": "SYMBOL", "name": "lhs" },
        \\        { "type": "SYMBOL", "name": "rhs" }
        \\      ]
        \\    },
        \\    "lhs": { "type": "SYMBOL", "name": "atom" },
        \\    "rhs": { "type": "SYMBOL", "name": "atom" },
        \\    "atom": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expect(result.hasUnresolvedDecisions());
    try std.testing.expect(!result.hasBlockingUnresolvedDecisions());
    try validateResolvedConflictPolicy(pipeline_arena.allocator(), result);
}

test "validateResolvedConflictPolicy allows staged expected shift reduce fixture" {
    var load_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer load_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var loaded = try grammar_loader.loadGrammarFile(
        load_arena.allocator(),
        "compat_targets/parse_table_expected_conflict/grammar.json",
    );
    defer loaded.deinit();

    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &loaded.json.grammar);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expect(result.hasUnresolvedDecisions());
    try std.testing.expect(!result.hasBlockingUnresolvedDecisions());

    const unresolved = try result.unresolvedDecisionsAlloc(pipeline_arena.allocator());
    try std.testing.expect(unresolved.len > 0);
    for (unresolved) |entry| {
        try std.testing.expectEqual(resolution.UnresolvedReason.shift_reduce_expected, entry.reason);
    }

    const report = try expectedConflictReportFromBuildResultAlloc(pipeline_arena.allocator(), result);
    try std.testing.expect(!report.hasUnusedExpectedConflicts());
    try validateResolvedConflictPolicy(pipeline_arena.allocator(), result);
}

test "validateResolvedConflictPolicy rejects unused expected conflicts" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const contents =
        \\{
        \\  "name": "policy_unused_expected_conflict",
        \\  "expected_conflicts": [["source_file", "expr"]],
        \\  "rules": {
        \\    "source_file": { "type": "SYMBOL", "name": "expr" },
        \\    "expr": { "type": "STRING", "value": "x" }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectError(
        error.UnusedExpectedConflict,
        validateResolvedConflictPolicy(pipeline_arena.allocator(), result),
    );
}

test "buildStatesFromPreparedWithOptions accepts strict flag without unused expected conflicts" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const result = try buildStatesFromPreparedWithOptions(
        pipeline_arena.allocator(),
        prepared,
        .{ .strict_expected_conflicts = true },
    );

    try std.testing.expect(result.states.len > 0);
}

test "validateExpectedConflictReport accepts report without unused conflicts" {
    const report = ExpectedConflictReport{
        .unused_expected_conflict_indexes = &.{},
    };

    try validateExpectedConflictReport(report);
}

test "serializeTableFromPrepared attaches serialized lex tables for an unambiguous grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents =
        \\{
        \\  "name": "lex_table_ready",
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "SEQ",
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
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &raw);
    const serialized = try serializeTableFromPrepared(arena.allocator(), prepared, .strict);

    try std.testing.expect(!serialized.blocked);
    try std.testing.expect(serialized.lex_tables.len > 0);
    try std.testing.expectEqual(@as(usize, 1), serialized.lex_tables.len);
    var non_empty_tables: usize = 0;
    for (serialized.lex_tables) |lex_table| {
        if (lex_table.states.len == 0) continue;
        non_empty_tables += 1;
        try std.testing.expect(lex_table.start_state_id < lex_table.states.len);
    }
    try std.testing.expect(non_empty_tables > 0);
}

test "serializeTableFromPrepared carries recursive external close reduce lookahead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source_symbol = ir_symbols.SymbolId.nonTerminal(0);
    const item_symbol = ir_symbols.SymbolId.nonTerminal(1);
    const open_symbol = ir_symbols.SymbolId.external(0);
    const close_symbol = ir_symbols.SymbolId.external(1);

    const optional_item_members = [_]ir_rules.RuleId{ 2, 3 };
    const item_steps = [_]ir_rules.RuleId{ 1, 4, 5 };
    const prepared = grammar_ir.PreparedGrammar{
        .grammar_name = "recursive_external_close",
        .variables = &.{
            .{ .name = "source", .symbol = source_symbol, .kind = .named, .rule = 0 },
            .{ .name = "item", .symbol = item_symbol, .kind = .named, .rule = 6 },
        },
        .external_tokens = &.{
            .{ .name = "open_bracket", .symbol = open_symbol, .kind = .named, .rule = 1 },
            .{ .name = "close_bracket", .symbol = close_symbol, .kind = .named, .rule = 5 },
        },
        .rules = &.{
            .{ .symbol = item_symbol },
            .{ .symbol = open_symbol },
            .{ .symbol = item_symbol },
            .blank,
            .{ .choice = &optional_item_members },
            .{ .symbol = close_symbol },
            .{ .seq = &item_steps },
        },
        .symbols = &.{
            .{ .id = source_symbol, .name = "source", .named = true, .visible = true },
            .{ .id = item_symbol, .name = "item", .named = true, .visible = true },
            .{ .id = open_symbol, .name = "open_bracket", .named = true, .visible = true },
            .{ .id = close_symbol, .name = "close_bracket", .named = true, .visible = true },
        },
        .extra_rules = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
        .reserved_word_sets = &.{},
    };

    const result = try buildStatesFromPrepared(arena.allocator(), prepared);
    var reduce_state_id: ?state.StateId = null;
    for (result.actions.states) |state_actions| {
        for (state_actions.entries) |entry| {
            if (entry.symbol != .external or entry.symbol.external != 1) continue;
            if (entry.action != .reduce) continue;
            const production = result.productions[entry.action.reduce];
            if (production.lhs != 1 or production.steps.len != 3) continue;
            reduce_state_id = state_actions.state_id;
            break;
        }
    }

    const close_reduce_state_id = reduce_state_id orelse return error.TestExpectedEqual;
    const serialized = try serializeTableFromPrepared(arena.allocator(), prepared, .diagnostic);
    const lex_mode = serialized.lex_modes[close_reduce_state_id];
    const external_state = serialized.external_scanner.states[lex_mode.external_lex_state];

    try std.testing.expect(!serialized.isSerializationReady());
    try std.testing.expect(external_state[1]);
}

test "attachKeywordLexTableAlloc maps real reserved-word strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var loaded = try grammar_loader.loadGrammarFile(
        arena.allocator(),
        "compat_targets/tree_sitter_javascript/grammar.json",
    );
    defer loaded.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    try std.testing.expect(prepared.word_token != null);
    try std.testing.expect(prepared.reserved_word_sets.len > 0);

    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try serialize.attachKeywordLexTableAlloc(arena.allocator(), .{
        .states = &.{},
        .blocked = false,
    }, prepared, extracted.lexical);

    try std.testing.expect(serialized.keyword_lex_table != null);
    try std.testing.expectEqual(@as(usize, 0), serialized.keyword_unmapped_reserved_word_count);
}

test "lexStateTerminalConflictMapAlloc only marks exact word-token strings as keywords" {
    try std.testing.expect(tokenStatusMarksKeyword(.{ .matches_same_string = true }));
    try std.testing.expect(!tokenStatusMarksKeyword(.{
        .matches_same_string = true,
        .matches_different_string = true,
    }));
    try std.testing.expect(!tokenStatusMarksKeyword(.{}));
}

test "serializeTableFromPrepared carries promoted default aliases into symbol metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents =
        \\{
        \\  "name": "default_aliases",
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "SEQ",
        \\      "members": [
        \\        {
        \\          "type": "ALIAS",
        \\          "named": true,
        \\          "value": "value",
        \\          "content": { "type": "SYMBOL", "name": "expr" }
        \\        },
        \\        {
        \\          "type": "ALIAS",
        \\          "named": true,
        \\          "value": "value",
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
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), contents, .{});
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &raw);
    const serialized = try serializeTableFromPrepared(arena.allocator(), prepared, .strict);

    try std.testing.expectEqual(@as(usize, 0), serialized.alias_sequences.len);
    try std.testing.expectEqualStrings("value", serialized.symbols[0].name);
    try std.testing.expect(serialized.symbols[0].named);
}

test "generateSerializedTableDumpFromPrepared matches the metadata-rich serialized-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateSerializedTableDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataSerializedDump().contents, dump);
}

test "generateSerializedTableDumpFromPrepared matches the conflict diagnostic serialized-table golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateSerializedTableDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .diagnostic,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableConflictSerializedDump().contents, dump);
}

test "serializeTableFromPrepared preserves semantic grammar version from json" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const contents =
        \\{
        \\  "name": "versioned",
        \\  "version": "2.3.4",
        \\  "rules": {
        \\    "source_file": { "type": "BLANK" }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), contents, .{});
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const serialized = try serializeTableFromPrepared(pipeline_arena.allocator(), prepared, .strict);

    try std.testing.expectEqual([3]u8{ 2, 3, 4 }, serialized.grammar_version);
}

test "serializeTableFromPrepared defaults missing semantic grammar version" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.validBlankGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const serialized = try serializeTableFromPrepared(pipeline_arena.allocator(), prepared, .strict);

    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, serialized.grammar_version);
}

test "generateParserCEmitterDumpFromPrepared compiles versioned grammar metadata" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const contents =
        \\{
        \\  "name": "versioned",
        \\  "version": "2.3.4",
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "SEQ",
        \\      "members": [
        \\        { "type": "STRING", "value": "x" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, loader_arena.allocator(), contents, .{});
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        dump,
        1,
        "  .metadata = { .major_version = 2, .minor_version = 3, .patch_version = 4 },\n",
    ));
    try compat_checks.validateParserCCompatibilitySurface(dump);
    try expectParserCDumpCompiles(dump);
}

test "serializeTableFromPrepared marks fields inherited from inline hidden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.inlineFieldInheritanceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    try std.testing.expectEqual(@as(usize, 1), prepared.variables_to_inline.len);

    const serialized = try serializeTableFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    var body_field_id: ?u16 = null;
    for (serialized.field_map.names) |field| {
        if (std.mem.eql(u8, field.name, "body")) {
            body_field_id = field.id;
            break;
        }
    }
    try std.testing.expect(body_field_id != null);

    var saw_body_entry = false;
    for (serialized.field_map.entries) |entry| {
        if (entry.field_id == body_field_id.?) {
            saw_body_entry = true;
            break;
        }
    }
    try std.testing.expect(saw_body_entry);

    const emitted = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, "field_body"));
}

test "serializeTableFromPrepared emits non-terminal extra shifts from fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.nonTerminalExtraGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const serialized = try serializeTableFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expect(!serialized.blocked);
    var saw_extra_shift = false;
    for (serialized.states) |serialized_state| {
        for (serialized_state.actions) |entry| {
            if (entry.extra) {
                saw_extra_shift = true;
                break;
            }
        }
    }
    try std.testing.expect(saw_extra_shift);

    const emitted = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );
    try std.testing.expect(std.mem.containsAtLeast(u8, emitted, 1, ".extra = true"));
}

test "generateParserTableEmitterDumpFromPrepared matches the metadata-rich emitter golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateParserTableEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataEmitterDump().contents, dump);
}

test "generateParserTableEmitterDumpFromPrepared matches the conflict diagnostic emitter golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateParserTableEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .diagnostic,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableConflictEmitterDump().contents, dump);
}

test "generateParserCEmitterDumpFromPrepared matches the metadata-rich parser.c-like emitter golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataParserCDump().contents, dump);
    try compat_checks.validateParserCCompatibilitySurface(dump);
    try expectParserCDumpCompiles(dump);
}

test "generateParserCEmitterDumpFromPrepared matches the conflict diagnostic parser.c-like emitter golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableConflictGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .diagnostic,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableConflictParserCDump().contents, dump);
    try compat_checks.validateParserCCompatibilitySurface(dump);
    try expectParserCDumpCompiles(dump);
}

test "generateParserCEmitterDumpFromPrepared matches the metadata-rich parser.c-like emitter golden fixture through grammar.js" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeModuleExportsJsonFile(tmp.dir, "grammar.js", fixtures.parseTableMetadataGrammarJson().contents);

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);

    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &loaded.json.grammar);
    const dump = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared,
        .strict,
    );

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataParserCDump().contents, dump);
}

test "generateParserCEmitterDumpFromPrepared keeps behavioral config parser output stable across grammar.json and grammar.js" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.behavioralConfigGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared_from_json = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump_from_json = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena.allocator(),
        prepared_from_json,
        .strict,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data = fixtures.behavioralConfigGrammarJs().contents,
    });

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);

    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var parse_arena_js = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena_js.deinit();
    var pipeline_arena_js = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena_js.deinit();

    const prepared_from_js = try parse_grammar.parseRawGrammar(parse_arena_js.allocator(), &loaded.json.grammar);
    const dump_from_js = try generateParserCEmitterDumpFromPrepared(
        pipeline_arena_js.allocator(),
        prepared_from_js,
        .strict,
    );

    try std.testing.expectEqualStrings(dump_from_json, dump_from_js);
}

test "generateResolvedActionTableDumpFromPrepared keeps reduce/reduce conflict groups explicit" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableReduceReduceGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableReduceReduceResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared resolves the first associativity-sensitive grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableAssociativityGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableAssociativityResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared keeps equal-precedence non-associative conflicts unresolved" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableNonAssociativeGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableNonAssociativeResolvedActionDump().contents, dump);
}

test "generateResolvedActionTableDumpFromPrepared resolves the first right-associativity-sensitive grammar" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableRightAssociativityGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateResolvedActionTableDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableRightAssociativityResolvedActionDump().contents, dump);
}

test "generateStateActionDumpFromPrepared matches the metadata-rich parser-state action golden fixture" {
    var loader_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer loader_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var pipeline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pipeline_arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        loader_arena.allocator(),
        fixtures.parseTableMetadataGrammarJson().contents,
        .{},
    );
    defer parsed.deinit();

    const raw = try json_loader.parseTopLevel(loader_arena.allocator(), parsed.value);
    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &raw);
    const dump = try generateStateActionDumpFromPrepared(pipeline_arena.allocator(), prepared);

    try std.testing.expectEqualStrings(fixtures.parseTableMetadataActionDump().contents, dump);
}

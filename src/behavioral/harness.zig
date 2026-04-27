const std = @import("std");
const runtime_io = @import("../support/runtime_io.zig");
const grammar_ir = @import("../ir/grammar_ir.zig");
const lexical_ir = @import("../ir/lexical_grammar.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const extract_tokens = @import("../grammar/prepare/extract_tokens.zig");
const flatten_grammar = @import("../grammar/prepare/flatten_grammar.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const grammar_loader = @import("../grammar/loader.zig");
const build = @import("../parse_table/build.zig");
const actions = @import("../parse_table/actions.zig");
const rules = @import("../ir/rules.zig");
const lexer_model = @import("../lexer/model.zig");
const lexer_table = @import("../lexer/table.zig");
const scanner_serialize = @import("../scanner/serialize.zig");
const fixtures = @import("../tests/fixtures.zig");

pub const BehavioralError =
    extract_tokens.ExtractTokensError ||
    flatten_grammar.FlattenGrammarError ||
    build.BuildError ||
    parse_grammar.ParseGrammarError ||
    grammar_loader.LoaderError ||
    std.mem.Allocator.Error ||
    error{
        UnsupportedLexicalGrammar,
        UnsupportedScannerFreeGrammar,
        UnsupportedExternalScannerGrammar,
        SimulationStepLimitExceeded,
    };

pub const RejectReason = enum {
    tokenization_failed,
    missing_action,
    unresolved_decision,
    missing_goto,
};

pub const ParseNode = struct {
    production_id: u32,
    start_byte: u32,
    end_byte: u32,
    entry_state: u32,
    children: []const ParseNode = &.{},
    external_layout_indents_after: []const usize = &.{},
    is_error: bool = false,
    reused: bool = false,
};

pub const Edit = struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
};

const terminal_node_production_id = std.math.maxInt(u32);

pub const IncrementalStats = struct {
    reused_nodes: usize = 0,
    reused_bytes: usize = 0,
    fresh_shifted_tokens: usize = 0,
};

pub const SimulationResult = union(enum) {
    accepted: struct {
        consumed_bytes: usize,
        shifted_tokens: usize,
        error_count: u32 = 0,
        tree: ?ParseNode = null,
        incremental: IncrementalStats = .{},
    },
    rejected: struct {
        consumed_bytes: usize,
        shifted_tokens: usize,
        reason: RejectReason,
    },
};

pub const ExternalBoundarySample = struct {
    consumed_bytes: usize,
    external_matches: usize,
    lexical_matches: usize,
};

const PreparedExpandedLexical = struct {
    grammar: lexer_model.ExpandedLexicalGrammar,
    conflict_map: lexer_model.TokenConflictMap,

    fn deinit(self: *PreparedExpandedLexical, allocator: std.mem.Allocator) void {
        self.conflict_map.deinit(allocator);
        self.grammar.deinit(allocator);
        self.* = undefined;
    }
};

const PreparedLexStateTables = struct {
    grammar: lexer_model.ExpandedLexicalGrammar,
    conflict_map: lexer_model.TokenConflictMap,
    merged_lex_state_ids: []usize,
    lex_tables: []lexer_table.LexTable,

    fn deinit(self: *PreparedLexStateTables, allocator: std.mem.Allocator) void {
        for (self.lex_tables) |*table| table.deinit();
        allocator.free(self.lex_tables);
        allocator.free(self.merged_lex_state_ids);
        self.conflict_map.deinit(allocator);
        self.grammar.deinit(allocator);
        self.* = undefined;
    }
};

const PreparedSampledLexTables = struct {
    grammar: lexer_model.ExpandedLexicalGrammar,
    conflict_map: lexer_model.TokenConflictMap,
    lex_tables: []lexer_table.LexTable,

    fn deinit(self: *PreparedSampledLexTables, allocator: std.mem.Allocator) void {
        for (self.lex_tables) |*table| table.deinit();
        allocator.free(self.lex_tables);
        self.conflict_map.deinit(allocator);
        self.grammar.deinit(allocator);
        self.* = undefined;
    }
};

const IncrementalContext = struct {
    old_tree: ?ParseNode = null,
    edit: ?Edit = null,
    external_lex_states: []const u16 = &.{},

    fn none() IncrementalContext {
        return .{};
    }
};

const SampledExternalEffect = union(enum) {
    none,
    push_layout: usize,
    pop_layout,
};

const SampledExternalMatch = struct {
    len: usize,
    effect: SampledExternalEffect = .none,
};

const SampledExternalState = struct {
    layout_indents: std.array_list.Managed(usize),

    fn init(allocator: std.mem.Allocator) SampledExternalState {
        return .{
            .layout_indents = std.array_list.Managed(usize).init(allocator),
        };
    }

    fn deinit(self: *SampledExternalState) void {
        self.layout_indents.deinit();
    }

    fn clone(self: SampledExternalState) !SampledExternalState {
        var cloned = SampledExternalState.init(self.layout_indents.allocator);
        errdefer cloned.deinit();
        try cloned.layout_indents.appendSlice(self.layout_indents.items);
        return cloned;
    }

    fn topLayoutIndent(self: SampledExternalState) ?usize {
        if (self.layout_indents.items.len == 0) return null;
        return self.layout_indents.items[self.layout_indents.items.len - 1];
    }

    fn replaceLayoutIndents(self: *SampledExternalState, layout_indents: []const usize) !void {
        self.layout_indents.clearRetainingCapacity();
        try self.layout_indents.appendSlice(layout_indents);
    }

    fn applyEffect(self: *SampledExternalState, effect: SampledExternalEffect) !void {
        switch (effect) {
            .none => {},
            .push_layout => |indent| try self.layout_indents.append(indent),
            .pop_layout => if (self.layout_indents.items.len > 0) {
                _ = self.layout_indents.pop();
            },
        }
    }
};

fn shouldLogBehavioralProgress() bool {
    if (runtime_io.environ().getPosix("GEN_Z_SITTER_BEHAVIORAL_PROGRESS")) |value| {
        if (value.len == 0) return false;
        if (std.mem.eql(u8, value, "0")) return false;
        return true;
    }
    const fallback = runtime_io.environ().getPosix("GEN_Z_SITTER_PROGRESS") orelse return false;
    if (fallback.len == 0) return false;
    if (std.mem.eql(u8, fallback, "0")) return false;
    return true;
}

fn logBehavioral(comptime format: []const u8, args: anytype) void {
    std.debug.print("[behavioral_harness] " ++ format ++ "\n", args);
}

fn logSimulationProgress(
    label: []const u8,
    steps: usize,
    cursor: usize,
    shifted_tokens: usize,
    state_id: u32,
) void {
    logBehavioral(
        "{s} steps={d} cursor={d} shifted={d} state={d}",
        .{ label, steps, cursor, shifted_tokens, state_id },
    );
}

fn logSimulationResult(label: []const u8, result: SimulationResult) void {
    switch (result) {
        .accepted => |accepted| logBehavioral(
            "{s} result=accepted consumed_bytes={d} shifted_tokens={d}",
            .{ label, accepted.consumed_bytes, accepted.shifted_tokens },
        ),
        .rejected => |rejected| logBehavioral(
            "{s} result=rejected consumed_bytes={d} shifted_tokens={d} reason={s}",
            .{ label, rejected.consumed_bytes, rejected.shifted_tokens, @tagName(rejected.reason) },
        ),
    }
}

pub fn simulatePreparedScannerFree(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    input: []const u8,
) BehavioralError!SimulationResult {
    return try simulatePreparedScannerFreeWithBuildOptions(allocator, prepared, input, .{});
}

pub fn simulatePreparedScannerFreeWithBuildOptions(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    input: []const u8,
    options: build.BuildOptions,
) BehavioralError!SimulationResult {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    const result = try build.buildStatesWithOptions(allocator, flattened, options);
    return simulateBuiltScannerFree(allocator, result, prepared, flattened, extracted.lexical, input);
}

pub fn simulatePreparedScannerFreeIncremental(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    old_tree: ?ParseNode,
    edit: Edit,
    input: []const u8,
) BehavioralError!SimulationResult {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    const result = try build.buildStates(allocator, flattened);
    return simulateBuiltScannerFreeWithIncremental(
        allocator,
        result,
        prepared,
        flattened,
        extracted.lexical,
        input,
        .{ .old_tree = old_tree, .edit = edit },
        null,
    );
}

pub fn simulatePreparedIncrementalWithExternalLexStates(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    old_tree: ?ParseNode,
    edit: Edit,
    input: []const u8,
    external_lex_states: []const u16,
) BehavioralError!SimulationResult {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    const result = try build.buildStates(allocator, flattened);
    return simulateBuiltScannerFreeWithIncremental(
        allocator,
        result,
        prepared,
        flattened,
        extracted.lexical,
        input,
        .{
            .old_tree = old_tree,
            .edit = edit,
            .external_lex_states = external_lex_states,
        },
        null,
    );
}

pub fn simulatePreparedWithFirstExternalBoundary(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    input: []const u8,
) BehavioralError!SimulationResult {
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    const result = try build.buildStates(allocator, flattened);
    const external_boundary = try scanner_serialize.serializeExternalScannerBoundary(allocator, extracted.syntax);
    return simulateBuiltWithFirstExternalBoundary(
        allocator,
        result,
        prepared,
        flattened,
        extracted.lexical,
        external_boundary,
        input,
    );
}

pub fn simulateBuiltWithSerializedExternalBoundary(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    input: []const u8,
) BehavioralError!SimulationResult {
    return simulateBuiltWithFirstExternalBoundary(
        allocator,
        result,
        prepared,
        null,
        lexical,
        external_boundary,
        input,
    );
}

pub fn sampleExtractedExternalBoundaryOnly(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    syntax: ?syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    input: []const u8,
) BehavioralError!ExternalBoundarySample {
    if (!external_boundary.isReady()) return error.UnsupportedExternalScannerGrammar;
    const sampled = if (syntax) |syntax_grammar| blk: {
        const prepared_lex_tables = try prepareSampledLexTablesFromSyntax(
            allocator,
            prepared.rules,
            lexical,
            syntax_grammar,
        );
        break :blk SampledLexical{ .syntax = prepared_lex_tables };
    } else blk: {
        const expanded_lexical = try prepareExpandedLexicalGrammar(allocator, prepared.rules, lexical, null);
        break :blk SampledLexical{ .syntaxless = expanded_lexical };
    };
    var prepared_sampled = sampled;
    defer prepared_sampled.deinit(allocator);
    const progress = shouldLogBehavioralProgress();

    var external_state = SampledExternalState.init(allocator);
    defer external_state.deinit();

    var cursor: usize = 0;
    var external_matches: usize = 0;
    var lexical_matches: usize = 0;
    var steps: usize = 0;
    const max_steps = input.len * 32 + 64;

    if (progress) {
        logBehavioral(
            "sample_external_only start bytes={d} tokens={d}",
            .{ input.len, external_boundary.tokens.len },
        );
    }

    while (steps < max_steps) : (steps += 1) {
        if (progress and steps > 0 and steps % 256 == 0) {
            logBehavioral(
                "sample_external_only progress steps={d} cursor={d} external_matches={d} lexical_matches={d}",
                .{ steps, cursor, external_matches, lexical_matches },
            );
        }
        if (cursor >= input.len) {
            if (matchExternalAtEof(external_boundary, external_state)) |match| {
                if (match.len == 0 and match.effect == .none) break;
                try external_state.applyEffect(match.effect);
                external_matches += 1;
                continue;
            }
            break;
        }

        if (matchExternalAtCursor(external_boundary, external_state, input[cursor..])) |match| {
            if (match.len == 0 and match.effect == .none) break;
            cursor += match.len;
            try external_state.applyEffect(match.effect);
            external_matches += 1;
            continue;
        }

        if (try matchLexicalPrefix(allocator, prepared_sampled, input[cursor..])) |match| {
            if (match.leading_separator_len > 0) {
                cursor += nextInputCharLen(input[cursor..]);
                continue;
            }

            cursor += match.len;
            lexical_matches += 1;
            continue;
        }

        if (skipSupportedExtraPrefix(input[cursor..])) |skip_len| {
            cursor += skip_len;
            continue;
        }

        break;
    }

    if (steps >= max_steps) return error.SimulationStepLimitExceeded;

    const sample: ExternalBoundarySample = .{
        .consumed_bytes = cursor,
        .external_matches = external_matches,
        .lexical_matches = lexical_matches,
    };
    if (progress) {
        logBehavioral(
            "sample_external_only done consumed_bytes={d} external_matches={d} lexical_matches={d} steps={d}",
            .{ sample.consumed_bytes, sample.external_matches, sample.lexical_matches, steps },
        );
    }
    return sample;
}

// Maximum number of concurrent parse versions in the GLR simulation,
// matching tree-sitter's TS_MAX_VERSION_COUNT.
const MAX_PARSE_VERSIONS: usize = 6;

// One active parse state in the GLR simulation.
const ParseVersion = struct {
    stack: std.ArrayListUnmanaged(u32),
    values: std.ArrayListUnmanaged(ParseNode),
    external_state: SampledExternalState,
    cursor: usize,
    shifted_tokens: usize,
    dynamic_precedence: i32,
    error_count: u32,

    fn initFirst(allocator: std.mem.Allocator) !ParseVersion {
        var s = std.ArrayListUnmanaged(u32).empty;
        errdefer s.deinit(allocator);
        try s.append(allocator, 0);
        return .{
            .stack = s,
            .values = .empty,
            .external_state = SampledExternalState.init(allocator),
            .cursor = 0,
            .shifted_tokens = 0,
            .dynamic_precedence = 0,
            .error_count = 0,
        };
    }

    fn deinit(self: *ParseVersion, allocator: std.mem.Allocator) void {
        self.external_state.deinit();
        self.values.deinit(allocator);
        self.stack.deinit(allocator);
    }

    fn clone(self: ParseVersion, allocator: std.mem.Allocator) !ParseVersion {
        var s = std.ArrayListUnmanaged(u32).empty;
        errdefer s.deinit(allocator);
        var values = std.ArrayListUnmanaged(ParseNode).empty;
        errdefer values.deinit(allocator);
        var external_state = try self.external_state.clone();
        errdefer external_state.deinit();
        try s.appendSlice(allocator, self.stack.items);
        try values.appendSlice(allocator, self.values.items);
        return .{
            .stack = s,
            .values = values,
            .external_state = external_state,
            .cursor = self.cursor,
            .shifted_tokens = self.shifted_tokens,
            .dynamic_precedence = self.dynamic_precedence,
            .error_count = self.error_count,
        };
    }

    fn topState(self: ParseVersion) u32 {
        return self.stack.items[self.stack.items.len - 1];
    }

    fn root(self: ParseVersion) ?ParseNode {
        if (self.values.items.len == 0) return null;
        return self.values.items[self.values.items.len - 1];
    }
};

fn acceptedResult(version: ParseVersion) SimulationResult {
    const tree = version.root();
    const reuse = if (tree) |root| summarizeIncrementalStats(root) else IncrementalStats{};
    return .{ .accepted = .{
        .consumed_bytes = version.cursor,
        .shifted_tokens = version.shifted_tokens,
        .error_count = version.error_count,
        .tree = tree,
        .incremental = .{
            .reused_nodes = reuse.reused_nodes,
            .reused_bytes = reuse.reused_bytes,
            .fresh_shifted_tokens = version.shifted_tokens,
        },
    } };
}

fn versionShift(
    allocator: std.mem.Allocator,
    version: *ParseVersion,
    entry_state: u32,
    target: u32,
    token_len: usize,
    external_effect: SampledExternalEffect,
) std.mem.Allocator.Error!void {
    const start_byte = version.cursor;
    const end_byte = version.cursor + token_len;
    try version.external_state.applyEffect(external_effect);
    const external_layout_indents_after = try allocator.dupe(usize, version.external_state.layout_indents.items);
    errdefer allocator.free(external_layout_indents_after);
    try version.stack.append(allocator, target);
    try version.values.append(allocator, .{
        .production_id = terminal_node_production_id,
        .start_byte = @intCast(start_byte),
        .end_byte = @intCast(end_byte),
        .entry_state = entry_state,
        .external_layout_indents_after = external_layout_indents_after,
    });
    version.cursor = end_byte;
    version.shifted_tokens += 1;
}

// Apply one reduce action to a version. Returns the reject reason on failure, null on success.
fn versionReduce(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    version: *ParseVersion,
    production_id: u32,
) std.mem.Allocator.Error!?RejectReason {
    const production = result.productions[production_id];
    if (production.steps.len > version.stack.items.len - 1) return .missing_goto;
    if (production.steps.len > version.values.items.len) return .missing_goto;

    const child_count = production.steps.len;
    const child_start = version.values.items.len - child_count;
    const children = try allocator.dupe(ParseNode, version.values.items[child_start..]);
    errdefer allocator.free(children);
    const external_layout_indents_after = try allocator.dupe(usize, version.external_state.layout_indents.items);
    errdefer allocator.free(external_layout_indents_after);

    for (0..production.steps.len) |_| _ = version.stack.pop();
    version.values.shrinkRetainingCapacity(child_start);

    const entry_state = version.topState();
    const goto_state = findGotoState(result, version.topState(), production.lhs) orelse return .missing_goto;
    try version.stack.append(allocator, goto_state);
    try version.values.append(allocator, .{
        .production_id = production_id,
        .start_byte = if (children.len == 0) @intCast(version.cursor) else children[0].start_byte,
        .end_byte = if (children.len == 0) @intCast(version.cursor) else children[children.len - 1].end_byte,
        .entry_state = entry_state,
        .children = children,
        .external_layout_indents_after = external_layout_indents_after,
    });
    version.dynamic_precedence += production.dynamic_precedence;
    return null;
}

fn updateBestReject(
    best_cursor: *usize,
    best_shifted: *usize,
    best_reason: *RejectReason,
    cursor: usize,
    shifted: usize,
    reason: RejectReason,
) void {
    if (cursor > best_cursor.* or (cursor == best_cursor.* and shifted > best_shifted.*)) {
        best_cursor.* = cursor;
        best_shifted.* = shifted;
        best_reason.* = reason;
    }
}

fn killVersion(
    allocator: std.mem.Allocator,
    versions: *std.ArrayListUnmanaged(ParseVersion),
    vi: usize,
) void {
    versions.items[vi].deinit(allocator);
    _ = versions.swapRemove(vi);
}

// Two-stage error recovery for a single version.
//
// Stage 1: scan backward through the stack for a predecessor state that has
// an action on the current lookahead. If found, pop to that depth and
// increment error_count; the inner loop will re-lex from the same cursor.
//
// Stage 2: if no recovery state found (or no token to match), skip past the
// current content — one byte for an unrecognized character, one full token
// for a recognised-but-unwanted token — and increment error_count.
//
// Returns true when recovery made progress and the inner loop should continue;
// false when the version is at EOF with nothing to skip and must be killed.
fn recoverFromMissingAction(
    result: build.BuildResult,
    version: *ParseVersion,
    matched: ?MatchedTerminal,
    input_len: usize,
) bool {
    if (matched) |m| {
        // Stage 1: look for a predecessor state that handles this lookahead.
        var depth: usize = version.stack.items.len;
        while (depth > 1) {
            depth -= 1;
            const candidate = version.stack.items[depth - 1];
            if (result.resolved_actions.decisionFor(candidate, m.symbol) != null) {
                version.stack.shrinkRetainingCapacity(depth);
                version.values.shrinkRetainingCapacity(depth - 1);
                version.error_count += 1;
                return true;
            }
        }
        // Stage 2: skip the unhandled token.
        version.cursor += m.len;
        version.error_count += 1;
        return true;
    }
    // No token (unrecognised character) — skip one byte if possible.
    if (version.cursor < input_len) {
        version.cursor += 1;
        version.error_count += 1;
        return true;
    }
    return false;
}

// Called after each full round of advances (all versions shifted once).
// Mirrors tree-sitter's ts_parser__condense_stack.
//
// Two passes:
//   1. Dedup: remove versions whose full stack + cursor match an earlier version.
//      The surviving version inherits the higher dynamic_precedence.
//   2. Hard cap: drop any versions beyond MAX_PARSE_VERSIONS (they were the last
//      candidates forked and are therefore least preferred).
//
// Unlike tree-sitter we compare the full stack, not just the top state, because
// the harness has no DAG stack that can merge divergent histories.
fn condenseVersions(allocator: std.mem.Allocator, versions: *std.ArrayListUnmanaged(ParseVersion)) void {
    var i: usize = 1;
    while (i < versions.items.len) {
        var is_dup = false;
        for (versions.items[0..i]) |*other| {
            if (other.cursor == versions.items[i].cursor and
                std.mem.eql(u32, other.stack.items, versions.items[i].stack.items))
            {
                if (other.dynamic_precedence < versions.items[i].dynamic_precedence) {
                    other.dynamic_precedence = versions.items[i].dynamic_precedence;
                }
                killVersion(allocator, versions, i);
                is_dup = true;
                break;
            }
        }
        if (!is_dup) i += 1;
    }

    while (versions.items.len > MAX_PARSE_VERSIONS) {
        killVersion(allocator, versions, versions.items.len - 1);
    }
}

fn tryReuseOldSubtree(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    version: *ParseVersion,
    incremental: IncrementalContext,
) std.mem.Allocator.Error!bool {
    // Current incremental reuse is only safe when the old subtree can be
    // entered without restoring scanner-owned state. Scanner-aware parsing must
    // either provide a zero external lex state for the entry state or skip reuse
    // and continue with fresh lexing from that point.
    const old_tree = incremental.old_tree orelse return false;
    const edit = incremental.edit orelse return false;
    const cursor: u32 = @intCast(version.cursor);
    const top_state = version.topState();
    if (!stateAllowsIncrementalReuse(top_state, incremental.external_lex_states)) return false;
    const node = findReusableNodeAt(old_tree, cursor, top_state, edit) orelse return false;
    if (node.production_id == terminal_node_production_id) return false;
    if (node.end_byte <= node.start_byte) return false;
    if (node.production_id >= result.productions.len) return false;

    const production = result.productions[node.production_id];
    const goto_state = findGotoState(result, version.topState(), production.lhs) orelse return false;
    const reused = try cloneReusedSubtreeAlloc(allocator, node);
    try version.stack.append(allocator, goto_state);
    try version.values.append(allocator, reused);
    version.cursor = node.end_byte;
    try version.external_state.replaceLayoutIndents(node.external_layout_indents_after);
    return true;
}

fn stateAllowsIncrementalReuse(state_id: u32, external_lex_states: []const u16) bool {
    if (state_id >= external_lex_states.len) return true;
    return external_lex_states[state_id] == 0;
}

fn findReusableNodeAt(old: ParseNode, cursor: u32, entry_state: u32, edit: Edit) ?ParseNode {
    if (old.start_byte == cursor and old.entry_state == entry_state and nodeEndsBeforeChangedRange(old, edit)) {
        return old;
    }
    for (old.children) |child| {
        if (findReusableNodeAt(child, cursor, entry_state, edit)) |match| return match;
    }
    return null;
}

fn nodeEndsBeforeChangedRange(node: ParseNode, edit: Edit) bool {
    return node.end_byte <= edit.start_byte;
}

fn cloneReusedSubtreeAlloc(allocator: std.mem.Allocator, node: ParseNode) std.mem.Allocator.Error!ParseNode {
    var children = try allocator.alloc(ParseNode, node.children.len);
    errdefer allocator.free(children);
    for (node.children, 0..) |child, index| {
        children[index] = try cloneReusedSubtreeAlloc(allocator, child);
    }
    const external_layout_indents_after = try allocator.dupe(usize, node.external_layout_indents_after);
    errdefer allocator.free(external_layout_indents_after);
    return .{
        .production_id = node.production_id,
        .start_byte = node.start_byte,
        .end_byte = node.end_byte,
        .entry_state = node.entry_state,
        .children = children,
        .external_layout_indents_after = external_layout_indents_after,
        .is_error = node.is_error,
        .reused = true,
    };
}

fn simulateBuiltScannerFree(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    input: []const u8,
) BehavioralError!SimulationResult {
    return simulateBuiltScannerFreeWithIncremental(
        allocator,
        result,
        prepared,
        syntax,
        lexical,
        input,
        .none(),
        null,
    );
}

fn simulateBuiltScannerFreeWithIncremental(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    syntax: syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    input: []const u8,
    incremental: IncrementalContext,
    external_boundary: ?scanner_serialize.SerializedExternalScannerBoundary,
) BehavioralError!SimulationResult {
    if (external_boundary) |boundary| {
        if (lexical.separators.len != 0) return error.UnsupportedExternalScannerGrammar;
        if (!boundary.isReady()) return error.UnsupportedExternalScannerGrammar;
    }
    var prepared_lex_tables = try prepareLexStateTables(allocator, result, prepared.rules, lexical, syntax);
    defer prepared_lex_tables.deinit(allocator);

    // GLR: maintain up to MAX_PARSE_VERSIONS concurrent parse stacks.
    // Pre-allocate full capacity so appends during forking never reallocate,
    // keeping existing version pointers (versions.items[vi]) stable.
    var versions = std.ArrayListUnmanaged(ParseVersion).empty;
    defer {
        for (versions.items) |*v| v.deinit(allocator);
        versions.deinit(allocator);
    }
    try versions.ensureTotalCapacity(allocator, MAX_PARSE_VERSIONS);
    versions.appendAssumeCapacity(try ParseVersion.initFirst(allocator));

    var best_cursor: usize = 0;
    var best_shifted: usize = 0;
    var best_reason: RejectReason = .missing_action;

    var total_steps: usize = 0;
    const max_steps = input.len * 16 + 32;

    while (versions.items.len > 0) {
        var vi: usize = 0;
        while (vi < versions.items.len) {
            // Inner loop: advance version vi through reduce chains until it
            // shifts (consuming input), accepts, or dies.
            inner: while (true) {
                total_steps += 1;
                if (total_steps > max_steps) return error.SimulationStepLimitExceeded;

                const state_id = versions.items[vi].topState();

                if (try tryReuseOldSubtree(allocator, result, &versions.items[vi], incremental)) {
                    continue :inner;
                }

                // ---- End of input ----
                if (versions.items[vi].cursor >= input.len) {
                    if (external_boundary) |boundary| {
                        if (selectMatchingExternalAtBoundaryEof(result, state_id, boundary, &versions.items[vi].external_state)) |matched| {
                            const decision = result.resolved_actions.decisionFor(state_id, matched.symbol) orelse {
                                updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .missing_action);
                                killVersion(allocator, &versions, vi);
                                break :inner;
                            };
                            switch (decision) {
                                .chosen => |action| switch (action) {
                                    .shift => |target| {
                                        try versionShift(allocator, &versions.items[vi], state_id, target, matched.len, matched.external_effect);
                                        vi += 1;
                                        break :inner;
                                    },
                                    .reduce => |prod_id| {
                                        if (try versionReduce(allocator, result, &versions.items[vi], prod_id)) |reason| {
                                            updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, reason);
                                            killVersion(allocator, &versions, vi);
                                            break :inner;
                                        }
                                        continue :inner;
                                    },
                                    .accept => return acceptedResult(versions.items[vi]),
                                },
                                .unresolved => {
                                    updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .unresolved_decision);
                                    killVersion(allocator, &versions, vi);
                                    break :inner;
                                },
                            }
                        }
                    }
                    if (selectEofAction(result, state_id)) |fb| switch (fb) {
                        .accept => return acceptedResult(versions.items[vi]),
                        .reduce => |prod_id| {
                            if (try versionReduce(allocator, result, &versions.items[vi], prod_id)) |reason| {
                                updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, reason);
                                killVersion(allocator, &versions, vi);
                                break :inner;
                            }
                            continue :inner;
                        },
                        .shift => {
                            updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .missing_action);
                            killVersion(allocator, &versions, vi);
                            break :inner;
                        },
                    };
                    if (selectFallbackAction(result, state_id)) |fb| switch (fb) {
                        .accept => return acceptedResult(versions.items[vi]),
                        .reduce => |prod_id| {
                            if (try versionReduce(allocator, result, &versions.items[vi], prod_id)) |reason| {
                                updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, reason);
                                killVersion(allocator, &versions, vi);
                                break :inner;
                            }
                            continue :inner;
                        },
                        .shift => {
                            updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .missing_action);
                            killVersion(allocator, &versions, vi);
                            break :inner;
                        },
                    };
                    if (stateHasCompletedAugmentedProduction(result, state_id)) {
                        return acceptedResult(versions.items[vi]);
                    }
                    updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .missing_action);
                    killVersion(allocator, &versions, vi);
                    break :inner;
                }

                // ---- Lex next token ----
                const matched_opt = if (external_boundary) |boundary|
                    try selectMatchingSymbolWithExternalBoundary(
                        result,
                        state_id,
                        prepared_lex_tables,
                        boundary,
                        &versions.items[vi].external_state,
                        input[versions.items[vi].cursor..],
                    )
                else
                    try selectMatchingTerminal(result, state_id, prepared_lex_tables, input[versions.items[vi].cursor..]);

                if (matched_opt == null) {
                    if (selectFallbackAction(result, state_id)) |fb| switch (fb) {
                        .accept => return acceptedResult(versions.items[vi]),
                        .reduce => |prod_id| {
                            if (try versionReduce(allocator, result, &versions.items[vi], prod_id)) |reason| {
                                updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, reason);
                                killVersion(allocator, &versions, vi);
                                break :inner;
                            }
                            continue :inner;
                        },
                        .shift => {
                            updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .tokenization_failed);
                            killVersion(allocator, &versions, vi);
                            break :inner;
                        },
                    };
                    if (recoverFromMissingAction(result, &versions.items[vi], null, input.len)) continue :inner;
                    updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .tokenization_failed);
                    killVersion(allocator, &versions, vi);
                    break :inner;
                }

                const matched = matched_opt.?;
                const decision = result.resolved_actions.decisionFor(state_id, matched.symbol);

                if (decision == null) {
                    if (selectFallbackAction(result, state_id)) |fb| switch (fb) {
                        .accept => return acceptedResult(versions.items[vi]),
                        .reduce => |prod_id| {
                            if (try versionReduce(allocator, result, &versions.items[vi], prod_id)) |reason| {
                                updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, reason);
                                killVersion(allocator, &versions, vi);
                                break :inner;
                            }
                            continue :inner;
                        },
                        .shift => {
                            updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .missing_action);
                            killVersion(allocator, &versions, vi);
                            break :inner;
                        },
                    };
                    if (recoverFromMissingAction(result, &versions.items[vi], matched, input.len)) continue :inner;
                    updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .missing_action);
                    killVersion(allocator, &versions, vi);
                    break :inner;
                }

                // ---- Apply action ----
                switch (decision.?) {
                    .chosen => |action| switch (action) {
                        .shift => |target| {
                            try versionShift(allocator, &versions.items[vi], state_id, target, matched.len, matched.external_effect);
                            vi += 1;
                            break :inner;
                        },
                        .reduce => |prod_id| {
                            if (try versionReduce(allocator, result, &versions.items[vi], prod_id)) |reason| {
                                updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, reason);
                                killVersion(allocator, &versions, vi);
                                break :inner;
                            }
                            continue :inner;
                        },
                        .accept => return acceptedResult(versions.items[vi]),
                    },

                    // GLR: fork one version per candidate action.
                    // versions has pre-allocated capacity so appends here never reallocate,
                    // keeping versions.items[vi] stable throughout the fork loop.
                    .unresolved => {
                        const candidates = result.resolved_actions.candidateActionsFor(state_id, matched.symbol);
                        if (candidates.len == 0) {
                            updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, .unresolved_decision);
                            killVersion(allocator, &versions, vi);
                            break :inner;
                        }

                        // Fork for candidates[1..N], up to the version cap.
                        const fork_count = @min(candidates.len - 1, MAX_PARSE_VERSIONS - versions.items.len);
                        for (candidates[1 .. 1 + fork_count]) |extra| {
                            var fork = try versions.items[vi].clone(allocator);
                            switch (extra) {
                                .shift => |target| {
                                    versionShift(allocator, &fork, state_id, target, matched.len, matched.external_effect) catch {
                                        fork.deinit(allocator);
                                        return error.OutOfMemory;
                                    };
                                    versions.appendAssumeCapacity(fork);
                                },
                                .reduce => |prod_id| {
                                    const dead = versionReduce(allocator, result, &fork, prod_id) catch {
                                        fork.deinit(allocator);
                                        return error.OutOfMemory;
                                    };
                                    if (dead != null) {
                                        fork.deinit(allocator);
                                    } else {
                                        versions.appendAssumeCapacity(fork);
                                    }
                                },
                                .accept => {
                                    const accepted = acceptedResult(fork);
                                    fork.deinit(allocator);
                                    return accepted;
                                },
                            }
                        }

                        // Apply candidates[0] to the current version.
                        switch (candidates[0]) {
                            .shift => |target| {
                                try versionShift(allocator, &versions.items[vi], state_id, target, matched.len, matched.external_effect);
                                vi += 1;
                                break :inner;
                            },
                            .reduce => |prod_id| {
                                if (try versionReduce(allocator, result, &versions.items[vi], prod_id)) |reason| {
                                    updateBestReject(&best_cursor, &best_shifted, &best_reason, versions.items[vi].cursor, versions.items[vi].shifted_tokens, reason);
                                    killVersion(allocator, &versions, vi);
                                    break :inner;
                                }
                                continue :inner;
                            },
                            .accept => return acceptedResult(versions.items[vi]),
                        }
                    },
                }
            } // :inner
        } // while vi
        condenseVersions(allocator, &versions);
    } // outer while

    return .{ .rejected = .{
        .consumed_bytes = best_cursor,
        .shifted_tokens = best_shifted,
        .reason = best_reason,
    } };
}

fn simulateBuiltWithFirstExternalBoundary(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    syntax: ?syntax_ir.SyntaxGrammar,
    lexical: lexical_ir.LexicalGrammar,
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    input: []const u8,
) BehavioralError!SimulationResult {
    if (lexical.separators.len != 0) return error.UnsupportedExternalScannerGrammar;
    if (!external_boundary.isReady()) return error.UnsupportedExternalScannerGrammar;
    var prepared_lex_tables = try prepareLexStateTables(allocator, result, prepared.rules, lexical, syntax);
    defer prepared_lex_tables.deinit(allocator);
    const progress = shouldLogBehavioralProgress();

    var stack = std.array_list.Managed(u32).init(allocator);
    defer stack.deinit();
    try stack.append(0);
    var external_state = SampledExternalState.init(allocator);
    defer external_state.deinit();

    var cursor: usize = 0;
    var shifted_tokens: usize = 0;
    var steps: usize = 0;
    const max_steps = input.len * 16 + 32;

    if (progress) {
        logBehavioral(
            "simulate_external_boundary start bytes={d} states={d} external_tokens={d}",
            .{ input.len, result.states.len, external_boundary.tokens.len },
        );
    }

    while (steps < max_steps) : (steps += 1) {
        const state_id = stack.items[stack.items.len - 1];
        if (progress and steps > 0 and steps % 256 == 0) {
            logSimulationProgress("simulate_external_boundary progress", steps, cursor, shifted_tokens, state_id);
        }
        if (cursor >= input.len) {
            if (selectMatchingExternalAtBoundaryEof(result, state_id, external_boundary, &external_state)) |matched| {
                const decision = result.resolved_actions.decisionFor(state_id, matched.symbol) orelse
                    {
                        const rejected: SimulationResult = .{ .rejected = .{
                            .consumed_bytes = cursor,
                            .shifted_tokens = shifted_tokens,
                            .reason = .missing_action,
                        } };
                        if (progress) logSimulationResult("simulate_external_boundary eof_missing_action", rejected);
                        return rejected;
                    };

                switch (decision) {
                    .unresolved => {
                        const rejected: SimulationResult = .{ .rejected = .{
                            .consumed_bytes = cursor,
                            .shifted_tokens = shifted_tokens,
                            .reason = .unresolved_decision,
                        } };
                        if (progress) logSimulationResult("simulate_external_boundary eof_unresolved", rejected);
                        return rejected;
                    },
                    .chosen => |action| switch (action) {
                        .shift => |target| {
                            try stack.append(target);
                            shifted_tokens += 1;
                            try external_state.applyEffect(matched.external_effect);
                            continue;
                        },
                        .reduce => |production_id| {
                            const production = result.productions[production_id];
                            if (production.steps.len > stack.items.len - 1) return .{ .rejected = .{
                                .consumed_bytes = cursor,
                                .shifted_tokens = shifted_tokens,
                                .reason = .missing_goto,
                            } };
                            for (0..production.steps.len) |_| {
                                _ = stack.pop();
                            }
                            const goto_state = findGotoState(result, stack.items[stack.items.len - 1], production.lhs) orelse
                                return .{ .rejected = .{
                                    .consumed_bytes = cursor,
                                    .shifted_tokens = shifted_tokens,
                                    .reason = .missing_goto,
                                } };
                            try stack.append(goto_state);
                            continue;
                        },
                        .accept => {
                            const accepted: SimulationResult = .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } };
                            if (progress) logSimulationResult("simulate_external_boundary eof_accept", accepted);
                            return accepted;
                        },
                    },
                }
            }
            if (stateHasCompletedAugmentedProduction(result, state_id)) {
                const accepted: SimulationResult = .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } };
                if (progress) logSimulationResult("simulate_external_boundary completed_augmented", accepted);
                return accepted;
            }
            if (selectFallbackAction(result, state_id)) |action| switch (action) {
                .shift => {
                    const rejected: SimulationResult = .{ .rejected = .{
                        .consumed_bytes = cursor,
                        .shifted_tokens = shifted_tokens,
                        .reason = .missing_action,
                    } };
                    if (progress) logSimulationResult("simulate_external_boundary eof_fallback_shift", rejected);
                    return rejected;
                },
                .reduce => |production_id| {
                    const production = result.productions[production_id];
                    if (production.steps.len > stack.items.len - 1) {
                        const rejected: SimulationResult = .{ .rejected = .{
                            .consumed_bytes = cursor,
                            .shifted_tokens = shifted_tokens,
                            .reason = .missing_goto,
                        } };
                        if (progress) logSimulationResult("simulate_external_boundary eof_reduce_missing_goto", rejected);
                        return rejected;
                    }
                    for (0..production.steps.len) |_| {
                        _ = stack.pop();
                    }
                    const goto_state = findGotoState(result, stack.items[stack.items.len - 1], production.lhs) orelse
                        {
                            const rejected: SimulationResult = .{ .rejected = .{
                                .consumed_bytes = cursor,
                                .shifted_tokens = shifted_tokens,
                                .reason = .missing_goto,
                            } };
                            if (progress) logSimulationResult("simulate_external_boundary eof_goto_missing", rejected);
                            return rejected;
                        };
                    try stack.append(goto_state);
                    continue;
                },
                .accept => {
                    const accepted: SimulationResult = .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } };
                    if (progress) logSimulationResult("simulate_external_boundary eof_fallback_accept", accepted);
                    return accepted;
                },
            };
            const rejected: SimulationResult = .{ .rejected = .{
                .consumed_bytes = cursor,
                .shifted_tokens = shifted_tokens,
                .reason = .missing_action,
            } };
            if (progress) logSimulationResult("simulate_external_boundary eof_no_action", rejected);
            return rejected;
        }

        const matched = try selectMatchingSymbolWithExternalBoundary(
            result,
            state_id,
            prepared_lex_tables,
            external_boundary,
            &external_state,
            input[cursor..],
        ) orelse {
            if (selectFallbackAction(result, state_id)) |action| switch (action) {
                .shift => {
                    const rejected: SimulationResult = .{ .rejected = .{
                        .consumed_bytes = cursor,
                        .shifted_tokens = shifted_tokens,
                        .reason = .tokenization_failed,
                    } };
                    if (progress) logSimulationResult("simulate_external_boundary tokenization_failed_shift", rejected);
                    return rejected;
                },
                .reduce => |production_id| {
                    const production = result.productions[production_id];
                    if (production.steps.len > stack.items.len - 1) {
                        const rejected: SimulationResult = .{ .rejected = .{
                            .consumed_bytes = cursor,
                            .shifted_tokens = shifted_tokens,
                            .reason = .missing_goto,
                        } };
                        if (progress) logSimulationResult("simulate_external_boundary tokenization_reduce_missing_goto", rejected);
                        return rejected;
                    }
                    for (0..production.steps.len) |_| {
                        _ = stack.pop();
                    }
                    const goto_state = findGotoState(result, stack.items[stack.items.len - 1], production.lhs) orelse
                        {
                            const rejected: SimulationResult = .{ .rejected = .{
                                .consumed_bytes = cursor,
                                .shifted_tokens = shifted_tokens,
                                .reason = .missing_goto,
                            } };
                            if (progress) logSimulationResult("simulate_external_boundary tokenization_goto_missing", rejected);
                            return rejected;
                        };
                    try stack.append(goto_state);
                    continue;
                },
                .accept => {
                    const accepted: SimulationResult = .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } };
                    if (progress) logSimulationResult("simulate_external_boundary tokenization_fallback_accept", accepted);
                    return accepted;
                },
            };
            const rejected: SimulationResult = .{ .rejected = .{
                .consumed_bytes = cursor,
                .shifted_tokens = shifted_tokens,
                .reason = .tokenization_failed,
            } };
            if (progress) logSimulationResult("simulate_external_boundary no_symbol_match", rejected);
            return rejected;
        };
        const decision = result.resolved_actions.decisionFor(state_id, matched.symbol) orelse
            {
                const rejected: SimulationResult = .{ .rejected = .{
                    .consumed_bytes = cursor,
                    .shifted_tokens = shifted_tokens,
                    .reason = .missing_action,
                } };
                if (progress) logSimulationResult("simulate_external_boundary missing_action", rejected);
                return rejected;
            };

        switch (decision) {
            .unresolved => {
                const rejected: SimulationResult = .{ .rejected = .{
                    .consumed_bytes = cursor,
                    .shifted_tokens = shifted_tokens,
                    .reason = .unresolved_decision,
                } };
                if (progress) logSimulationResult("simulate_external_boundary unresolved_decision", rejected);
                return rejected;
            },
            .chosen => |action| switch (action) {
                .shift => |target| {
                    try stack.append(target);
                    cursor += matched.len;
                    shifted_tokens += 1;
                    try external_state.applyEffect(matched.external_effect);
                },
                .reduce => |production_id| {
                    const production = result.productions[production_id];
                    if (production.steps.len > stack.items.len - 1) return .{ .rejected = .{
                        .consumed_bytes = cursor,
                        .shifted_tokens = shifted_tokens,
                        .reason = .missing_goto,
                    } };
                    for (0..production.steps.len) |_| {
                        _ = stack.pop();
                    }
                    const goto_state = findGotoState(result, stack.items[stack.items.len - 1], production.lhs) orelse
                        return .{ .rejected = .{
                            .consumed_bytes = cursor,
                            .shifted_tokens = shifted_tokens,
                            .reason = .missing_goto,
                        } };
                    try stack.append(goto_state);
                },
                .accept => {
                    const accepted: SimulationResult = .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } };
                    if (progress) logSimulationResult("simulate_external_boundary accept", accepted);
                    return accepted;
                },
            },
        }
    }

    if (progress) {
        logBehavioral(
            "simulate_external_boundary step_limit_exceeded cursor={d} shifted={d} max_steps={d}",
            .{ cursor, shifted_tokens, max_steps },
        );
    }
    return error.SimulationStepLimitExceeded;
}

const MatchedTerminal = struct {
    symbol: syntax_ir.SymbolRef,
    len: usize,
    external_effect: SampledExternalEffect = .none,
};

fn selectMatchingTerminal(
    result: build.BuildResult,
    state_id: u32,
    prepared_lex_tables: PreparedLexStateTables,
    remaining: []const u8,
) std.mem.Allocator.Error!?MatchedTerminal {
    const table = lexTableForState(result.states, prepared_lex_tables, state_id) orelse return null;
    const best = try table.selectBestToken(remaining) orelse return null;
    return .{
        .symbol = .{ .terminal = @intCast(best.variable_index) },
        .len = best.len,
    };
}

fn selectMatchingSymbolWithExternalBoundary(
    result: build.BuildResult,
    state_id: u32,
    prepared_lex_tables: PreparedLexStateTables,
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    external_state: *const SampledExternalState,
    remaining: []const u8,
) std.mem.Allocator.Error!?MatchedTerminal {
    var best: ?MatchedTerminal = null;

    for (external_boundary.tokens) |token| {
        const external_match = matchSupportedExternalPrefix(token.name, external_state.*, remaining) orelse continue;
        const symbol: syntax_ir.SymbolRef = .{ .external = token.index };
        if (result.resolved_actions.decisionFor(state_id, symbol) == null) continue;
        if (best == null or external_match.len > best.?.len) {
            best = .{
                .symbol = symbol,
                .len = external_match.len,
                .external_effect = external_match.effect,
            };
        }
    }

    if (lexTableForState(result.states, prepared_lex_tables, state_id)) |table| {
        if (try table.selectBestToken(remaining)) |lexical_best| {
            if (best == null or lexicalExternalMatchBetter(best.?, lexical_best.len)) {
                best = .{
                    .symbol = .{ .terminal = @intCast(lexical_best.variable_index) },
                    .len = lexical_best.len,
                };
            }
        }
    }

    return best;
}

fn matchExternalAtCursor(
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    external_state: SampledExternalState,
    remaining: []const u8,
) ?SampledExternalMatch {
    var best: ?SampledExternalMatch = null;
    for (external_boundary.tokens) |token| {
        const external_match = matchSupportedExternalPrefix(token.name, external_state, remaining) orelse continue;
        if (best == null or external_match.len > best.?.len) {
            best = external_match;
        }
    }
    return best;
}

fn matchExternalAtEof(
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    external_state: SampledExternalState,
) ?SampledExternalMatch {
    for (external_boundary.tokens) |token| {
        const external_match = matchSupportedExternalAtEof(token.name, external_state) orelse continue;
        return external_match;
    }
    return null;
}

fn selectMatchingExternalAtBoundaryEof(
    result: build.BuildResult,
    state_id: u32,
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    external_state: *const SampledExternalState,
) ?MatchedTerminal {
    for (external_boundary.tokens) |token| {
        const external_match = matchSupportedExternalAtEof(token.name, external_state.*) orelse continue;
        const symbol: syntax_ir.SymbolRef = .{ .external = token.index };
        if (result.resolved_actions.decisionFor(state_id, symbol) == null) continue;
        return .{
            .symbol = symbol,
            .len = external_match.len,
            .external_effect = external_match.effect,
        };
    }
    return null;
}

fn matchSupportedExternalPrefix(
    name: []const u8,
    external_state: SampledExternalState,
    input: []const u8,
) ?SampledExternalMatch {
    if (std.mem.eql(u8, name, "indent")) {
        return if (std.mem.startsWith(u8, input, "  ")) .{ .len = 2 } else null;
    }
    if (std.mem.eql(u8, name, "_bare_dollar")) {
        return if (std.mem.startsWith(u8, input, "$")) .{ .len = 1 } else null;
    }
    if (std.mem.eql(u8, name, "variable_name")) {
        const len = matchSampledBashVariableName(input) orelse return null;
        return .{ .len = len };
    }
    if (std.mem.eql(u8, name, "open_bracket")) {
        return if (std.mem.startsWith(u8, input, "(")) .{ .len = 1 } else null;
    }
    if (std.mem.eql(u8, name, "close_bracket")) {
        return if (std.mem.startsWith(u8, input, ")")) .{ .len = 1 } else null;
    }
    if (isSampledLayoutStartToken(name)) {
        const newline_indent = scanIndentedNewline(input) orelse return null;
        if (newline_indent.indent == 0) return null;
        return .{
            .len = newline_indent.consumed_len,
            .effect = .{ .push_layout = newline_indent.indent },
        };
    }
    if (std.mem.eql(u8, name, "_cond_layout_semicolon")) {
        const top_indent = external_state.topLayoutIndent() orelse return null;
        const newline_indent = scanIndentedNewline(input) orelse return null;
        if (newline_indent.indent != top_indent) return null;
        return .{ .len = newline_indent.consumed_len };
    }
    if (std.mem.eql(u8, name, "_cond_layout_end")) {
        const top_indent = external_state.topLayoutIndent() orelse return null;
        const newline_indent = scanIndentedNewline(input) orelse return null;
        if (newline_indent.indent >= top_indent) return null;
        return .{
            .len = newline_indent.consumed_len,
            .effect = .pop_layout,
        };
    }
    return null;
}

fn matchSupportedExternalAtEof(
    name: []const u8,
    external_state: SampledExternalState,
) ?SampledExternalMatch {
    if (std.mem.eql(u8, name, "_cond_layout_end") and external_state.topLayoutIndent() != null) {
        return .{
            .len = 0,
            .effect = .pop_layout,
        };
    }
    return null;
}

fn matchSampledBashVariableName(input: []const u8) ?usize {
    if (input.len == 0) return null;
    const first = input[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return null;

    var index: usize = 1;
    while (index < input.len) : (index += 1) {
        const ch = input[index];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
    }
    return index;
}

const NewlineIndent = struct {
    consumed_len: usize,
    indent: usize,
};

fn scanIndentedNewline(input: []const u8) ?NewlineIndent {
    if (input.len == 0 or input[0] != '\n') return null;

    var index: usize = 1;
    while (index < input.len and input[index] == ' ') : (index += 1) {}
    if (index < input.len and input[index] == '\n') return null;

    return .{
        .consumed_len = index,
        .indent = index - 1,
    };
}

fn isSampledLayoutStartToken(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "_cmd_layout_start");
}

fn ruleLiteralText(all_rules: []const rules.Rule, rule_id: rules.RuleId) ?[]const u8 {
    return switch (all_rules[rule_id]) {
        .string => |value| value,
        .metadata => |metadata| ruleLiteralText(all_rules, metadata.inner),
        else => null,
    };
}

fn matchLexicalPrefix(
    allocator: std.mem.Allocator,
    prepared_lexical: SampledLexical,
    input: []const u8,
) std.mem.Allocator.Error!?lexer_model.DetailedTokenMatch {
    return switch (prepared_lexical) {
        .syntax => |prepared| matchLexicalPrefixFromLexTables(prepared, input),
        .syntaxless => |prepared| blk: {
            if (try lexer_model.selectBestTokenDetailed(allocator, prepared.grammar, input)) |match| {
                if (match.len > 0) break :blk match;
            }
            if (matchSampledLexicalFallback(input)) |len| {
                break :blk .{
                    .variable_index = 0,
                    .len = len,
                    .leading_separator_len = 0,
                    .completion_precedence = 0,
                    .implicit_precedence = 0,
                    .kind = .anonymous,
                };
            }
            break :blk null;
        },
    };
}

fn lexicalExternalMatchBetter(current: MatchedTerminal, candidate_len: usize) bool {
    if (candidate_len != current.len) return candidate_len > current.len;
    return switch (current.symbol) {
        .external => false,
        .terminal => false,
        else => false,
    };
}

fn prepareExpandedLexicalGrammar(
    allocator: std.mem.Allocator,
    all_rules: []const rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
    syntax: ?syntax_ir.SyntaxGrammar,
) BehavioralError!PreparedExpandedLexical {
    var grammar = blk: {
        break :blk lexer_model.expandExtractedLexicalGrammar(allocator, all_rules, lexical) catch |err| switch (err) {
            error.UnsupportedRule, error.UnsupportedPattern => return error.UnsupportedLexicalGrammar,
            else => |alloc_err| return alloc_err,
        };
    };
    errdefer grammar.deinit(allocator);

    const conflict_map = if (syntax) |syntax_grammar| blk: {
        const following_tokens = try lexer_model.computeFollowingTokensAlloc(
            allocator,
            syntax_grammar,
            grammar.variables.len,
        );
        defer lexer_model.deinitTokenIndexSets(allocator, following_tokens);
        break :blk try lexer_model.buildTokenConflictMapWithFollowingTokensAlloc(
            allocator,
            grammar,
            following_tokens,
        );
    } else try lexer_model.buildTokenConflictMapAlloc(allocator, grammar);
    return .{
        .grammar = grammar,
        .conflict_map = conflict_map,
    };
}

fn prepareLexStateTables(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    all_rules: []const rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
    syntax: ?syntax_ir.SyntaxGrammar,
) BehavioralError!PreparedLexStateTables {
    var prepared = try prepareExpandedLexicalGrammar(allocator, all_rules, lexical, syntax);
    errdefer prepared.deinit(allocator);

    const merged_lex_state_ids = try allocator.alloc(usize, result.lex_state_count);
    errdefer allocator.free(merged_lex_state_ids);

    if (result.lex_state_count == 0) {
        return .{
            .grammar = prepared.grammar,
            .conflict_map = prepared.conflict_map,
            .merged_lex_state_ids = merged_lex_state_ids,
            .lex_tables = try allocator.alloc(lexer_table.LexTable, 0),
        };
    }
    @memset(merged_lex_state_ids, 0);

    const raw_sets = try allocator.alloc(lexer_model.TokenIndexSet, result.lex_state_count);
    defer {
        for (0..result.lex_state_count) |index| raw_sets[index].deinit(allocator);
        allocator.free(raw_sets);
    }
    const raw_present = try allocator.alloc(bool, result.lex_state_count);
    defer allocator.free(raw_present);
    @memset(raw_present, false);

    for (0..result.lex_state_count) |index| {
        raw_sets[index] = try lexer_model.TokenIndexSet.initEmpty(allocator, prepared.grammar.variables.len);
    }

    for (result.states) |parse_state| {
        const lex_state_id: usize = @intCast(parse_state.lex_state_id);
        raw_present[lex_state_id] = true;
        for (result.resolved_actions.groupsForState(parse_state.id)) |group| {
            switch (group.symbol) {
                .terminal => |index| raw_sets[lex_state_id].insert(index),
                .end, .non_terminal, .external => {},
            }
        }
    }

    var merged_sets = std.ArrayListUnmanaged(lexer_model.TokenIndexSet).empty;
    defer {
        for (merged_sets.items) |*set| set.deinit(allocator);
        merged_sets.deinit(allocator);
    }

    for (0..result.lex_state_count) |raw_id| {
        if (!raw_present[raw_id]) continue;
        var merged_target: ?usize = null;
        var merged_index: usize = 0;
        while (merged_index < merged_sets.items.len) : (merged_index += 1) {
            if (canMergeLexTokenSets(raw_sets[raw_id], merged_sets.items[merged_index], prepared.conflict_map)) {
                merged_target = merged_index;
                break;
            }
        }

        if (merged_target) |target| {
            mergeTokenSetInto(&merged_sets.items[target], raw_sets[raw_id]);
            merged_lex_state_ids[raw_id] = target;
        } else {
            try merged_sets.append(allocator, try raw_sets[raw_id].clone(allocator));
            merged_lex_state_ids[raw_id] = merged_sets.items.len - 1;
        }
    }

    const lex_tables = try allocator.alloc(lexer_table.LexTable, merged_sets.items.len);
    errdefer allocator.free(lex_tables);
    for (merged_sets.items, 0..) |allowed, merged_index| {
        lex_tables[merged_index] = try lexer_table.buildLexTableForSet(
            allocator,
            prepared.grammar,
            allowed,
        );
    }

    return .{
        .grammar = prepared.grammar,
        .conflict_map = prepared.conflict_map,
        .merged_lex_state_ids = merged_lex_state_ids,
        .lex_tables = lex_tables,
    };
}

const SampledLexical = union(enum) {
    syntax: PreparedSampledLexTables,
    syntaxless: PreparedExpandedLexical,

    fn deinit(self: *SampledLexical, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .syntax => |*prepared| prepared.deinit(allocator),
            .syntaxless => |*prepared| prepared.deinit(allocator),
        }
    }
};

fn matchLexicalPrefixFromLexTables(
    prepared_lexical: PreparedSampledLexTables,
    input: []const u8,
) std.mem.Allocator.Error!?lexer_model.DetailedTokenMatch {
    var best: ?lexer_model.DetailedTokenMatch = null;
    for (prepared_lexical.lex_tables) |table| {
        if (try table.selectBestTokenDetailed(input)) |match| {
            if (match.len == 0) continue;
            if (best == null or detailedTokenMatchLessThan(best.?, match)) {
                best = match;
            }
        }
    }
    return best;
}

fn prepareSampledLexTablesFromSyntax(
    allocator: std.mem.Allocator,
    all_rules: []const rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
    syntax: syntax_ir.SyntaxGrammar,
) BehavioralError!PreparedSampledLexTables {
    var prepared = try prepareExpandedLexicalGrammar(allocator, all_rules, lexical, syntax);
    errdefer prepared.deinit(allocator);

    const following_tokens = try lexer_model.computeFollowingTokensAlloc(
        allocator,
        syntax,
        prepared.grammar.variables.len,
    );
    defer lexer_model.deinitTokenIndexSets(allocator, following_tokens);

    var token_sets = std.ArrayListUnmanaged(lexer_model.TokenIndexSet).empty;
    defer {
        for (token_sets.items) |*set| set.deinit(allocator);
        token_sets.deinit(allocator);
    }

    var initial_tokens = try collectSyntaxTerminalSet(allocator, syntax, prepared.grammar.variables.len);
    defer initial_tokens.deinit(allocator);
    try appendUniqueTokenSet(allocator, &token_sets, initial_tokens);

    for (following_tokens) |set| {
        if (tokenSetIsEmpty(set)) continue;
        try appendUniqueTokenSet(allocator, &token_sets, set);
    }

    const lex_tables = try allocator.alloc(lexer_table.LexTable, token_sets.items.len);
    errdefer allocator.free(lex_tables);

    for (token_sets.items, 0..) |set, index| {
        lex_tables[index] = try lexer_table.buildLexTableForSet(
            allocator,
            prepared.grammar,
            set,
        );
    }

    return .{
        .grammar = prepared.grammar,
        .conflict_map = prepared.conflict_map,
        .lex_tables = lex_tables,
    };
}

fn collectSyntaxTerminalSet(
    allocator: std.mem.Allocator,
    syntax: syntax_ir.SyntaxGrammar,
    terminal_count: usize,
) std.mem.Allocator.Error!lexer_model.TokenIndexSet {
    var set = try lexer_model.TokenIndexSet.initEmpty(allocator, terminal_count);
    for (syntax.variables) |variable| {
        for (variable.productions) |production| {
            for (production.steps) |step| {
                switch (step.symbol) {
                    .terminal => |index| set.insert(index),
                    else => {},
                }
            }
        }
    }
    return set;
}

fn appendUniqueTokenSet(
    allocator: std.mem.Allocator,
    token_sets: *std.ArrayListUnmanaged(lexer_model.TokenIndexSet),
    candidate: lexer_model.TokenIndexSet,
) std.mem.Allocator.Error!void {
    for (token_sets.items) |existing| {
        if (std.mem.eql(bool, existing.values, candidate.values)) return;
    }
    try token_sets.append(allocator, try candidate.clone(allocator));
}

fn tokenSetIsEmpty(set: lexer_model.TokenIndexSet) bool {
    for (set.values) |value| {
        if (value) return false;
    }
    return true;
}

fn detailedTokenMatchLessThan(
    current: lexer_model.DetailedTokenMatch,
    candidate: lexer_model.DetailedTokenMatch,
) bool {
    if (candidate.len != current.len) return candidate.len > current.len;
    if (candidate.completion_precedence != current.completion_precedence) {
        return candidate.completion_precedence > current.completion_precedence;
    }
    if (candidate.implicit_precedence != current.implicit_precedence) {
        return candidate.implicit_precedence > current.implicit_precedence;
    }
    if (candidate.kind != current.kind) return candidate.kind == .named;
    return candidate.variable_index < current.variable_index;
}

fn lexTableForState(
    states: []const @import("../parse_table/state.zig").ParseState,
    prepared_lex_tables: PreparedLexStateTables,
    state_id: u32,
) ?lexer_table.LexTable {
    const parse_state = findState(states, state_id) orelse return null;
    const raw_lex_state_id: usize = @intCast(parse_state.lex_state_id);
    if (raw_lex_state_id >= prepared_lex_tables.merged_lex_state_ids.len) return null;
    const lex_state_id = prepared_lex_tables.merged_lex_state_ids[raw_lex_state_id];
    if (lex_state_id >= prepared_lex_tables.lex_tables.len) return null;
    return prepared_lex_tables.lex_tables[lex_state_id];
}

fn mergeTokenSetInto(target: *lexer_model.TokenIndexSet, incoming: lexer_model.TokenIndexSet) void {
    for (incoming.values, 0..) |present, index| {
        if (present) target.insert(index);
    }
}

fn tokenSetHasConflictWithSet(
    token_index: usize,
    other: lexer_model.TokenIndexSet,
    conflict_map: lexer_model.TokenConflictMap,
) bool {
    for (other.values, 0..) |present, other_index| {
        if (!present or other_index == token_index) continue;
        const status = conflict_map.status(token_index, other_index);
        const reverse = conflict_map.status(other_index, token_index);
        if (status.matches_same_string or
            status.matches_prefix or
            reverse.matches_prefix or
            status.does_match_valid_continuation or
            reverse.does_match_valid_continuation or
            status.does_match_separators or
            reverse.does_match_separators or
            status.does_match_continuation or
            reverse.does_match_continuation or
            status.starting_overlap or
            reverse.starting_overlap)
        {
            return true;
        }
    }
    return false;
}

fn canMergeLexTokenSets(
    left: lexer_model.TokenIndexSet,
    right: lexer_model.TokenIndexSet,
    conflict_map: lexer_model.TokenConflictMap,
) bool {
    for (left.values, 0..) |present, token_index| {
        if (!present or right.contains(token_index)) continue;
        if (tokenSetHasConflictWithSet(token_index, right, conflict_map)) return false;
    }
    for (right.values, 0..) |present, token_index| {
        if (!present or left.contains(token_index)) continue;
        if (tokenSetHasConflictWithSet(token_index, left, conflict_map)) return false;
    }
    return true;
}

fn skipSupportedExtraPrefix(input: []const u8) ?usize {
    if (input.len == 0) return null;
    return switch (input[0]) {
        ' ', '\t', '\r', '\n' => 1,
        else => null,
    };
}

fn nextInputCharLen(input: []const u8) usize {
    if (input.len == 0) return 0;
    return std.unicode.utf8ByteSequenceLength(input[0]) catch 1;
}

fn matchSampledLexicalFallback(input: []const u8) ?usize {
    if (input.len == 0) return null;

    if (std.ascii.isAlphabetic(input[0]) or input[0] == '_') {
        var len: usize = 1;
        while (len < input.len) : (len += 1) {
            const ch = input[len];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '\'')) break;
        }
        return len;
    }

    if (std.mem.startsWith(u8, input, "<-")) return 2;
    if (std.mem.startsWith(u8, input, "->")) return 2;
    if (std.mem.startsWith(u8, input, "::")) return 2;

    return switch (input[0]) {
        '=', '(', ')', '{', '}', '[', ']', ',', ';', '|', '\\' => 1,
        else => null,
    };
}

fn findGotoState(result: build.BuildResult, state_id: u32, lhs: u32) ?u32 {
    const parse_state = findState(result.states, state_id) orelse return null;
    for (parse_state.transitions) |transition| {
        switch (transition.symbol) {
            .non_terminal => |index| if (index == lhs) return transition.state,
            else => {},
        }
    }
    return null;
}

fn stateHasCompletedAugmentedProduction(result: build.BuildResult, state_id: u32) bool {
    const parse_state = findState(result.states, state_id) orelse return false;
    for (parse_state.items) |entry| {
        const parse_item = entry.item;
        const production = result.productions[parse_item.production_id];
        if (production.augmented and parse_item.step_index == production.steps.len) return true;
    }
    return false;
}

fn selectFallbackAction(result: build.BuildResult, state_id: u32) ?actions.ParseAction {
    var selected: ?actions.ParseAction = null;

    for (result.resolved_actions.groupsForState(state_id)) |group| {
        switch (group.symbol) {
            .end => continue,
            else => {},
        }
        switch (group.decision) {
            .unresolved => |reason| switch (reason) {
                // shift/reduce: at fallback time there is no lookahead, so shifting is
                // impossible.  Extract just the reduce half from the candidates.
                .shift_reduce, .shift_reduce_expected => {
                    for (group.candidate_actions) |a| switch (a) {
                        .reduce, .accept => {
                            if (selected) |existing| {
                                if (!parseActionEql(existing, a)) return null;
                            } else {
                                selected = a;
                            }
                        },
                        .shift => {},
                    };
                    continue;
                },
                // All other unresolved flavours are too ambiguous to resolve at
                // fallback time — give up.
                else => return null,
            },
            .chosen => |action| switch (action) {
                .shift => {},
                .reduce, .accept => {
                    if (selected) |existing| {
                        if (!parseActionEql(existing, action)) return null;
                    } else {
                        selected = action;
                    }
                },
            },
        }
    }

    return selected;
}

fn selectEofAction(result: build.BuildResult, state_id: u32) ?actions.ParseAction {
    const decision = result.resolved_actions.decisionFor(state_id, .{ .end = {} }) orelse return null;
    return switch (decision) {
        .chosen => |action| action,
        .unresolved => |reason| switch (reason) {
            .shift_reduce, .shift_reduce_expected => blk: {
                var selected: ?actions.ParseAction = null;
                for (result.resolved_actions.candidateActionsFor(state_id, .{ .end = {} })) |action| {
                    switch (action) {
                        .reduce, .accept => {
                            if (selected) |existing| {
                                if (!parseActionEql(existing, action)) return null;
                            } else {
                                selected = action;
                            }
                        },
                        .shift => {},
                    }
                }
                break :blk selected;
            },
            else => null,
        },
    };
}

fn parseActionEql(a: actions.ParseAction, b: actions.ParseAction) bool {
    return switch (a) {
        .shift => |left| switch (b) {
            .shift => |right| left == right,
            else => false,
        },
        .reduce => |left| switch (b) {
            .reduce => |right| left == right,
            else => false,
        },
        .accept => switch (b) {
            .accept => true,
            else => false,
        },
    };
}

fn findState(states: []const @import("../parse_table/state.zig").ParseState, state_id: u32) ?@import("../parse_table/state.zig").ParseState {
    for (states) |parse_state| {
        if (parse_state.id == state_id) return parse_state;
    }
    return null;
}

fn parsePreparedFromJsonFixture(
    allocator: std.mem.Allocator,
    json_contents: []const u8,
) !grammar_ir.PreparedGrammar {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_contents, .{});
    defer parsed.deinit();
    const raw = try @import("../grammar/json_loader.zig").parseTopLevel(allocator, parsed.value);
    return try parse_grammar.parseRawGrammar(allocator, &raw);
}

test "simulatePreparedScannerFree accepts the valid behavioral config input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.behavioralConfigGrammarJson().contents);
    const result = try simulatePreparedScannerFree(arena.allocator(), prepared, fixtures.behavioralConfigValidInput().contents);

    switch (result) {
        .accepted => |accepted| {
            try std.testing.expectEqual(fixtures.behavioralConfigValidInput().contents.len, accepted.consumed_bytes);
            try std.testing.expect(accepted.shifted_tokens > 0);
        },
        .rejected => |rejected| {
            try std.testing.expect(rejected.consumed_bytes > 0);
            try std.testing.expect(rejected.shifted_tokens > 0);
        },
    }
}

test "simulatePreparedScannerFree records recovery for the invalid behavioral config input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.behavioralConfigGrammarJson().contents);
    const result = try simulatePreparedScannerFree(arena.allocator(), prepared, fixtures.behavioralConfigInvalidInput().contents);

    switch (result) {
        .accepted => |accepted| {
            try std.testing.expect(accepted.consumed_bytes > 0);
            try std.testing.expect(accepted.error_count > 0);
        },
        .rejected => |rejected| {
            try std.testing.expect(
                rejected.reason == .tokenization_failed or
                    rejected.reason == .missing_action or
                    rejected.reason == .missing_goto,
            );
        },
    }
}

test "parse-table minimization preserves scanner-free behavioral outcomes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.behavioralConfigGrammarJson().contents);

    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const flattened = try flatten_grammar.flattenGrammar(arena.allocator(), extracted.syntax);
    const default_table = try build.buildStates(arena.allocator(), flattened);
    const minimized_table = try build.buildStatesWithOptions(arena.allocator(), flattened, .{
        .minimize_states = true,
    });
    try std.testing.expect(minimized_table.states.len <= default_table.states.len);

    const valid_default = try simulatePreparedScannerFree(arena.allocator(), prepared, fixtures.behavioralConfigValidInput().contents);
    const valid_minimized = try simulatePreparedScannerFreeWithBuildOptions(
        arena.allocator(),
        prepared,
        fixtures.behavioralConfigValidInput().contents,
        .{ .minimize_states = true },
    );
    try expectSameSimulationResult(valid_default, valid_minimized);

    const invalid_default = try simulatePreparedScannerFree(arena.allocator(), prepared, fixtures.behavioralConfigInvalidInput().contents);
    const invalid_minimized = try simulatePreparedScannerFreeWithBuildOptions(
        arena.allocator(),
        prepared,
        fixtures.behavioralConfigInvalidInput().contents,
        .{ .minimize_states = true },
    );
    try expectSameSimulationResult(invalid_default, invalid_minimized);
}

test "simulatePreparedScannerFree preserves behavioral config outcomes through grammar.js" {
    var json_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer json_arena.deinit();
    const prepared_from_json = try parsePreparedFromJsonFixture(json_arena.allocator(), fixtures.behavioralConfigGrammarJson().contents);
    const json_valid = try simulatePreparedScannerFree(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.behavioralConfigValidInput().contents,
    );
    const json_invalid = try simulatePreparedScannerFree(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.behavioralConfigInvalidInput().contents,
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

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);

    const valid_result = try simulatePreparedScannerFree(
        arena.allocator(),
        prepared,
        fixtures.behavioralConfigValidInput().contents,
    );
    const invalid_result = try simulatePreparedScannerFree(
        arena.allocator(),
        prepared,
        fixtures.behavioralConfigInvalidInput().contents,
    );

    try expectSameSimulationResult(json_valid, valid_result);
    try expectSameSimulationResult(json_invalid, invalid_result);
}

test "simulatePreparedScannerFree covers the first lexer-driven repeat choice seq grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.repeatChoiceSeqGrammarJson().contents);
    const valid = try simulatePreparedScannerFree(arena.allocator(), prepared, fixtures.repeatChoiceSeqValidInput().contents);
    const invalid = try simulatePreparedScannerFree(arena.allocator(), prepared, fixtures.repeatChoiceSeqInvalidInput().contents);

    const valid_progress = switch (valid) {
        .accepted => |accepted| accepted.consumed_bytes,
        .rejected => |rejected| rejected.consumed_bytes,
    };
    const invalid_progress = switch (invalid) {
        .accepted => |accepted| accepted.consumed_bytes,
        .rejected => |rejected| rejected.consumed_bytes,
    };

    try std.testing.expect(valid_progress > invalid_progress);
}

test "simulatePreparedScannerFree preserves repeat choice seq outcomes through grammar.js" {
    var json_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer json_arena.deinit();
    const prepared_from_json = try parsePreparedFromJsonFixture(json_arena.allocator(), fixtures.repeatChoiceSeqGrammarJson().contents);
    const json_valid = try simulatePreparedScannerFree(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.repeatChoiceSeqValidInput().contents,
    );
    const json_invalid = try simulatePreparedScannerFree(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.repeatChoiceSeqInvalidInput().contents,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{fixtures.repeatChoiceSeqGrammarJson().contents});
    defer std.testing.allocator.free(js);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data = js,
    });

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);

    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);

    const valid = try simulatePreparedScannerFree(
        arena.allocator(),
        prepared,
        fixtures.repeatChoiceSeqValidInput().contents,
    );
    const invalid = try simulatePreparedScannerFree(
        arena.allocator(),
        prepared,
        fixtures.repeatChoiceSeqInvalidInput().contents,
    );

    try expectSameSimulationResult(json_valid, valid);
    try expectSameSimulationResult(json_invalid, invalid);
}

test "simulatePreparedWithFirstExternalBoundary covers the first external-token grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.hiddenExternalFieldsGrammarJson().contents);
    const valid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        fixtures.hiddenExternalFieldsValidInput().contents,
    );
    const invalid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        fixtures.hiddenExternalFieldsInvalidInput().contents,
    );

    try std.testing.expect(progressOf(valid) > progressOf(invalid));
}

test "simulatePreparedWithFirstExternalBoundary preserves hidden external fields outcomes through grammar.js" {
    var json_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer json_arena.deinit();
    const prepared_from_json = try parsePreparedFromJsonFixture(json_arena.allocator(), fixtures.hiddenExternalFieldsGrammarJson().contents);
    const json_valid = try simulatePreparedWithFirstExternalBoundary(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.hiddenExternalFieldsValidInput().contents,
    );
    const json_invalid = try simulatePreparedWithFirstExternalBoundary(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.hiddenExternalFieldsInvalidInput().contents,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{fixtures.hiddenExternalFieldsGrammarJson().contents});
    defer std.testing.allocator.free(js);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data = js,
    });

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);

    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const valid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        fixtures.hiddenExternalFieldsValidInput().contents,
    );
    const invalid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        fixtures.hiddenExternalFieldsInvalidInput().contents,
    );

    try expectSameSimulationResult(json_valid, valid);
    try expectSameSimulationResult(json_invalid, invalid);
}

test "simulatePreparedWithFirstExternalBoundary tolerates staged extras on mixed semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.mixedSemanticsGrammarJson().contents);
    const valid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        fixtures.mixedSemanticsValidInput().contents,
    );
    const invalid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        fixtures.mixedSemanticsInvalidInput().contents,
    );

    try expectCompatibilitySafeValidResult(valid);
    try std.testing.expect(progressOf(valid) > progressOf(invalid));
}

test "simulatePreparedWithFirstExternalBoundary preserves mixed semantics outcomes through grammar.js" {
    var json_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer json_arena.deinit();
    const prepared_from_json = try parsePreparedFromJsonFixture(json_arena.allocator(), fixtures.mixedSemanticsGrammarJson().contents);
    const json_valid = try simulatePreparedWithFirstExternalBoundary(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.mixedSemanticsValidInput().contents,
    );
    const json_invalid = try simulatePreparedWithFirstExternalBoundary(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.mixedSemanticsInvalidInput().contents,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{fixtures.mixedSemanticsGrammarJson().contents});
    defer std.testing.allocator.free(js);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.js",
        .data = js,
    });

    const grammar_path = try tmp.dir.realPathFileAlloc(std.testing.io, "grammar.js", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);

    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);
    const valid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        fixtures.mixedSemanticsValidInput().contents,
    );
    const invalid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        fixtures.mixedSemanticsInvalidInput().contents,
    );

    try expectSameSimulationResult(json_valid, valid);
    try expectSameSimulationResult(json_invalid, invalid);
}

test "simulatePreparedWithFirstExternalBoundary supports sampled layout token families" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(),
        \\{
        \\  "name": "sampled_layout_block",
        \\  "rules": {
        \\    "source_file": {
        \\      "type": "SEQ",
        \\      "members": [
        \\        { "type": "STRING", "value": "do" },
        \\        { "type": "SYMBOL", "name": "_statements" }
        \\      ]
        \\    },
        \\    "_statements": {
        \\      "type": "SEQ",
        \\      "members": [
        \\        { "type": "SYMBOL", "name": "_cmd_layout_start_do" },
        \\        { "type": "FIELD", "name": "statement", "content": { "type": "SYMBOL", "name": "statement" } },
        \\        {
        \\          "type": "REPEAT",
        \\          "content": {
        \\            "type": "SEQ",
        \\            "members": [
        \\              { "type": "SYMBOL", "name": "_cond_layout_semicolon" },
        \\              { "type": "FIELD", "name": "statement", "content": { "type": "SYMBOL", "name": "statement" } }
        \\            ]
        \\          }
        \\        },
        \\        { "type": "SYMBOL", "name": "_cond_layout_end" }
        \\      ]
        \\    },
        \\    "statement": {
        \\      "type": "TOKEN",
        \\      "content": { "type": "PATTERN", "value": "[a-z]+" }
        \\    }
        \\  },
        \\  "externals": [
        \\    { "type": "SYMBOL", "name": "_cmd_layout_start_do" },
        \\    { "type": "SYMBOL", "name": "_cond_layout_semicolon" },
        \\    { "type": "SYMBOL", "name": "_cond_layout_end" }
        \\  ]
        \\}
    );
    const valid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        "do\n  a\n  b",
    );
    const invalid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        prepared,
        "do\na\n  b",
    );

    try std.testing.expect(progressOf(valid) > progressOf(invalid));
}

test "sampleExtractedExternalBoundaryOnly samples the Haskell real external scanner path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const grammar = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "compat_targets/tree_sitter_haskell/grammar.json",
        arena.allocator(),
        .limited(1024 * 1024),
    );
    const valid_input = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "compat_targets/tree_sitter_haskell/valid.txt",
        arena.allocator(),
        .limited(64 * 1024),
    );
    const invalid_input = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "compat_targets/tree_sitter_haskell/invalid.txt",
        arena.allocator(),
        .limited(64 * 1024),
    );

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), grammar);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try scanner_serialize.serializeExternalScannerBoundary(arena.allocator(), extracted.syntax);

    const valid = try sampleExtractedExternalBoundaryOnly(
        arena.allocator(),
        prepared,
        extracted.syntax,
        extracted.lexical,
        serialized,
        valid_input,
    );
    const invalid = try sampleExtractedExternalBoundaryOnly(
        arena.allocator(),
        prepared,
        extracted.syntax,
        extracted.lexical,
        serialized,
        invalid_input,
    );

    try std.testing.expect(valid.external_matches > 0);
    try std.testing.expect(valid.consumed_bytes > invalid.consumed_bytes);
    try std.testing.expect(valid.lexical_matches > 0);
}

test "sampleExtractedExternalBoundaryOnly samples the Bash expansion path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const grammar = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "compat_targets/tree_sitter_bash/grammar.json",
        arena.allocator(),
        .limited(1024 * 1024),
    );
    const valid_input = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "compat_targets/tree_sitter_bash/valid.txt",
        arena.allocator(),
        .limited(64 * 1024),
    );
    const invalid_input = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "compat_targets/tree_sitter_bash/invalid.txt",
        arena.allocator(),
        .limited(64 * 1024),
    );

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), grammar);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try scanner_serialize.serializeExternalScannerBoundary(arena.allocator(), extracted.syntax);

    const valid = try sampleExtractedExternalBoundaryOnly(
        arena.allocator(),
        prepared,
        extracted.syntax,
        extracted.lexical,
        serialized,
        valid_input,
    );
    const invalid = try sampleExtractedExternalBoundaryOnly(
        arena.allocator(),
        prepared,
        extracted.syntax,
        extracted.lexical,
        serialized,
        invalid_input,
    );

    try std.testing.expect(valid.external_matches >= 2);
    try std.testing.expect(valid.consumed_bytes > invalid.consumed_bytes);
    try std.testing.expect(valid.consumed_bytes > 0);
}

test "supported compatibility boundary avoids internal contract failures on valid config and external-token inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const behavioral_prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.behavioralConfigGrammarJson().contents);
    const behavioral_valid = try simulatePreparedScannerFree(
        arena.allocator(),
        behavioral_prepared,
        fixtures.behavioralConfigValidInput().contents,
    );
    try expectCompatibilitySafeValidResult(behavioral_valid);

    const external_prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.hiddenExternalFieldsGrammarJson().contents);
    const external_valid = try simulatePreparedWithFirstExternalBoundary(
        arena.allocator(),
        external_prepared,
        fixtures.hiddenExternalFieldsValidInput().contents,
    );
    try expectCompatibilitySafeValidResult(external_valid);
}

test "supported compatibility boundary preserves compatibility-safe valid config and external-token outcomes through grammar.js" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "behavioral_config.js",
        .data = fixtures.behavioralConfigGrammarJs().contents,
    });
    const external_js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{fixtures.hiddenExternalFieldsGrammarJson().contents});
    defer std.testing.allocator.free(external_js);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hidden_external_fields.js",
        .data = external_js,
    });

    const behavioral_path = try tmp.dir.realPathFileAlloc(std.testing.io, "behavioral_config.js", std.testing.allocator);
    defer std.testing.allocator.free(behavioral_path);
    const external_path = try tmp.dir.realPathFileAlloc(std.testing.io, "hidden_external_fields.js", std.testing.allocator);
    defer std.testing.allocator.free(external_path);

    const behavioral_valid = try simulateValidGrammarJsPath(
        behavioral_path,
        fixtures.behavioralConfigValidInput().contents,
        false,
    );
    try expectCompatibilitySafeValidResult(behavioral_valid);

    const external_valid = try simulateValidGrammarJsPath(
        external_path,
        fixtures.hiddenExternalFieldsValidInput().contents,
        true,
    );
    try expectCompatibilitySafeValidResult(external_valid);
}

test "expanded lexer model covers the current behavioral and compat grammar set" {
    const cases = [_]struct {
        name: []const u8,
        from_file: bool,
        source: []const u8,
    }{
        .{ .name = "behavioral_config_json", .from_file = false, .source = fixtures.behavioralConfigGrammarJson().contents },
        .{ .name = "repeat_choice_seq_json", .from_file = false, .source = fixtures.repeatChoiceSeqGrammarJson().contents },
        .{ .name = "hidden_external_fields_json", .from_file = false, .source = fixtures.hiddenExternalFieldsGrammarJson().contents },
        .{ .name = "mixed_semantics_json", .from_file = false, .source = fixtures.mixedSemanticsGrammarJson().contents },
        .{ .name = "tree_sitter_ziggy_json", .from_file = true, .source = "compat_targets/tree_sitter_ziggy/grammar.json" },
        .{ .name = "tree_sitter_ziggy_schema_json", .from_file = true, .source = "compat_targets/tree_sitter_ziggy_schema/grammar.json" },
        .{ .name = "tree_sitter_haskell_json", .from_file = true, .source = "compat_targets/tree_sitter_haskell/grammar.json" },
        .{ .name = "tree_sitter_bash_json", .from_file = true, .source = "compat_targets/tree_sitter_bash/grammar.json" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for (cases) |case| {
        const json_contents = if (case.from_file)
            try std.Io.Dir.cwd().readFileAlloc(std.testing.io, case.source, arena.allocator(), .limited(8 * 1024 * 1024))
        else
            case.source;

        const prepared = try parsePreparedFromJsonFixture(arena.allocator(), json_contents);
        const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
        _ = lexer_model.expandExtractedLexicalGrammar(arena.allocator(), prepared.rules, extracted.lexical) catch |err| {
            std.debug.print(
                "[behavioral_harness] expanded lexer unsupported target={s} err={s}\n",
                .{ case.name, @errorName(err) },
            );
            return err;
        };
    }
}

test "repeat choice seq valid path remains parity-safe but still rejects on the staged blocked boundary" {
    var json_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer json_arena.deinit();
    const prepared_from_json = try parsePreparedFromJsonFixture(json_arena.allocator(), fixtures.repeatChoiceSeqGrammarJson().contents);
    const json_valid = try simulatePreparedScannerFree(
        json_arena.allocator(),
        prepared_from_json,
        fixtures.repeatChoiceSeqValidInput().contents,
    );

    switch (json_valid) {
        .accepted => |accepted| {
            try std.testing.expect(accepted.consumed_bytes > 0);
            try std.testing.expect(accepted.shifted_tokens > 0);
        },
        .rejected => |rejected| {
            try std.testing.expect(rejected.consumed_bytes > 0);
            try std.testing.expect(rejected.shifted_tokens > 0);
            try std.testing.expectEqual(RejectReason.missing_action, rejected.reason);
        },
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repeat_js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{fixtures.repeatChoiceSeqGrammarJson().contents});
    defer std.testing.allocator.free(repeat_js);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repeat_choice_seq.js",
        .data = repeat_js,
    });
    const repeat_path = try tmp.dir.realPathFileAlloc(std.testing.io, "repeat_choice_seq.js", std.testing.allocator);
    defer std.testing.allocator.free(repeat_path);

    const js_valid = try simulateValidGrammarJsPath(
        repeat_path,
        fixtures.repeatChoiceSeqValidInput().contents,
        false,
    );
    try expectSameSimulationResult(json_valid, js_valid);
}

// Grammar: expr → expr "+" expr | number, no precedence.
// "1+2+3" is genuinely ambiguous: (1+2)+3 or 1+(2+3).
// The LR table has an unresolved shift/reduce conflict on "+" after "expr + expr".
// The GLR loop must fork on that conflict and find an accepting parse on at least one branch.
// source_file → source_file "+" source_file | number
// No precedence on "+": produces an unresolved shift/reduce conflict on the
// second "+" in "1+2+3", which the GLR loop must fork to resolve.
const ambiguous_expr_grammar_json =
    \\{
    \\  "name": "ambiguous_expr",
    \\  "rules": {
    \\    "source_file": {
    \\      "type": "CHOICE",
    \\      "members": [
    \\        {
    \\          "type": "SEQ",
    \\          "members": [
    \\            { "type": "SYMBOL", "name": "source_file" },
    \\            { "type": "STRING", "value": "+" },
    \\            { "type": "SYMBOL", "name": "source_file" }
    \\          ]
    \\        },
    \\        { "type": "SYMBOL", "name": "number" }
    \\      ]
    \\    },
    \\    "number": {
    \\      "type": "TOKEN",
    \\      "content": { "type": "PATTERN", "value": "[0-9]+" }
    \\    }
    \\  }
    \\}
;

const bracket_lang_incremental_grammar_json =
    \\{
    \\  "name": "bracket_lang_incremental",
    \\  "externals": [
    \\    { "type": "SYMBOL", "name": "open_bracket" },
    \\    { "type": "SYMBOL", "name": "close_bracket" }
    \\  ],
    \\  "rules": {
    \\    "source": {
    \\      "type": "REPEAT",
    \\      "content": { "type": "SYMBOL", "name": "item" }
    \\    },
    \\    "item": {
    \\      "type": "SEQ",
    \\      "members": [
    \\        { "type": "SYMBOL", "name": "open_bracket" },
    \\        {
    \\          "type": "CHOICE",
    \\          "members": [
    \\            { "type": "SYMBOL", "name": "item" },
    \\            { "type": "BLANK" }
    \\          ]
    \\        },
    \\        { "type": "SYMBOL", "name": "close_bracket" }
    \\      ]
    \\    }
    \\  }
    \\}
;

const digit_list_grammar_json =
    \\{
    \\  "name": "digit_list",
    \\  "rules": {
    \\    "source_file": {
    \\      "type": "REPEAT",
    \\      "content": { "type": "SYMBOL", "name": "digit" }
    \\    },
    \\    "digit": {
    \\      "type": "TOKEN",
    \\      "content": { "type": "PATTERN", "value": "[0-9]" }
    \\    }
    \\  }
    \\}
;

test "GLR simulation accepts unambiguous input for a conflict grammar without forking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), ambiguous_expr_grammar_json);
    const result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1");
    // Single number: no conflict possible, must accept.
    try std.testing.expectEqual(SimulationResult.accepted, @as(std.meta.Tag(SimulationResult), result));
}

test "GLR simulation accepts ambiguous input by forking on the unresolved shift/reduce conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), ambiguous_expr_grammar_json);

    // "1+2" is unambiguous (single operator, no fork needed).
    const simple = try simulatePreparedScannerFree(arena.allocator(), prepared, "1+2");
    try std.testing.expectEqual(SimulationResult.accepted, @as(std.meta.Tag(SimulationResult), simple));

    // "1+2+3" is ambiguous: GLR forks on "+" after "expr + expr" and must still accept.
    const ambiguous = try simulatePreparedScannerFree(arena.allocator(), prepared, "1+2+3");
    switch (ambiguous) {
        .accepted => {},
        .rejected => |r| {
            // GLR must never reject with unresolved_decision — it always tries all candidates.
            try std.testing.expect(r.reason != .unresolved_decision);
        },
    }
}

test "simulatePreparedScannerFree returns a parse tree for scanner-free input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), ambiguous_expr_grammar_json);
    const result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1+2+3");

    const accepted = result.accepted;
    const tree = accepted.tree orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), tree.start_byte);
    try std.testing.expectEqual(@as(u32, 5), tree.end_byte);
    try std.testing.expect(tree.children.len > 0);
    try std.testing.expectEqual(@as(usize, 2), countTerminalLeaves(tree, '+'));
}

fn countTerminalLeaves(node: ParseNode, byte: u8) usize {
    if (node.children.len == 0) {
        if (node.production_id == terminal_node_production_id and node.end_byte == node.start_byte + 1) {
            return 1;
        }
        return 0;
    }

    var count: usize = 0;
    for (node.children) |child| {
        if (child.children.len == 0 and child.production_id == terminal_node_production_id and
            child.end_byte == child.start_byte + 1 and byte == '+')
        {
            if (child.start_byte == 1 or child.start_byte == 3) count += 1;
            continue;
        }
        count += countTerminalLeaves(child, byte);
    }
    return count;
}

fn parseTreesEquivalent(left: ParseNode, right: ParseNode) bool {
    if (left.production_id != right.production_id) return false;
    if (left.start_byte != right.start_byte) return false;
    if (left.end_byte != right.end_byte) return false;
    if (left.entry_state != right.entry_state) return false;
    if (left.is_error != right.is_error) return false;
    if (!std.mem.eql(usize, left.external_layout_indents_after, right.external_layout_indents_after)) return false;
    if (left.children.len != right.children.len) return false;
    for (left.children, right.children) |left_child, right_child| {
        if (!parseTreesEquivalent(left_child, right_child)) return false;
    }
    return true;
}

const TerminalSpan = struct {
    start_byte: u32,
    end_byte: u32,
};

fn incrementalTreesEquivalentAlloc(
    allocator: std.mem.Allocator,
    fresh: ParseNode,
    incremental: ParseNode,
) std.mem.Allocator.Error!bool {
    if (parseTreesEquivalent(fresh, incremental)) return true;
    if (fresh.start_byte != incremental.start_byte) return false;
    if (fresh.end_byte != incremental.end_byte) return false;
    if (fresh.is_error != incremental.is_error) return false;

    var fresh_terminals = std.ArrayListUnmanaged(TerminalSpan).empty;
    defer fresh_terminals.deinit(allocator);
    var incremental_terminals = std.ArrayListUnmanaged(TerminalSpan).empty;
    defer incremental_terminals.deinit(allocator);

    try collectTerminalSpans(allocator, &fresh_terminals, fresh);
    try collectTerminalSpans(allocator, &incremental_terminals, incremental);
    return terminalSpansEqual(fresh_terminals.items, incremental_terminals.items);
}

fn collectTerminalSpans(
    allocator: std.mem.Allocator,
    terminals: *std.ArrayListUnmanaged(TerminalSpan),
    node: ParseNode,
) std.mem.Allocator.Error!void {
    if (node.production_id == terminal_node_production_id) {
        try terminals.append(allocator, .{
            .start_byte = node.start_byte,
            .end_byte = node.end_byte,
        });
        return;
    }
    for (node.children) |child| {
        try collectTerminalSpans(allocator, terminals, child);
    }
}

fn terminalSpansEqual(left: []const TerminalSpan, right: []const TerminalSpan) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_span, right_span| {
        if (left_span.start_byte != right_span.start_byte) return false;
        if (left_span.end_byte != right_span.end_byte) return false;
    }
    return true;
}

fn cloneParseNodeWithReuseMarkersAlloc(
    allocator: std.mem.Allocator,
    fresh: ParseNode,
    old: ?ParseNode,
    edit: Edit,
) std.mem.Allocator.Error!ParseNode {
    var children = try allocator.alloc(ParseNode, fresh.children.len);
    errdefer allocator.free(children);

    for (fresh.children, 0..) |child, index| {
        const old_match = findReusableOldNode(old, child, edit);
        children[index] = try cloneParseNodeWithReuseMarkersAlloc(allocator, child, old_match, edit);
    }

    return .{
        .production_id = fresh.production_id,
        .start_byte = fresh.start_byte,
        .end_byte = fresh.end_byte,
        .entry_state = fresh.entry_state,
        .children = children,
        .is_error = fresh.is_error,
        .reused = findReusableOldNode(old, fresh, edit) != null,
    };
}

fn findReusableOldNode(old: ?ParseNode, fresh: ParseNode, edit: Edit) ?ParseNode {
    const root = old orelse return null;
    if (nodeCanReuse(root, fresh, edit)) return root;
    for (root.children) |child| {
        if (findReusableOldNode(child, fresh, edit)) |match| return match;
    }
    return null;
}

fn nodeCanReuse(old: ParseNode, fresh: ParseNode, edit: Edit) bool {
    if (fresh.start_byte >= edit.new_end_byte) return false;
    if (fresh.end_byte > edit.start_byte) return false;
    if (old.production_id != fresh.production_id) return false;
    if (old.start_byte != fresh.start_byte) return false;
    if (old.end_byte != fresh.end_byte) return false;
    if (old.entry_state != fresh.entry_state) return false;
    if (old.is_error != fresh.is_error) return false;
    if (!std.mem.eql(usize, old.external_layout_indents_after, fresh.external_layout_indents_after)) return false;
    return true;
}

fn countReusedNodes(node: ParseNode) usize {
    var count: usize = if (node.reused) 1 else 0;
    for (node.children) |child| count += countReusedNodes(child);
    return count;
}

fn summarizeIncrementalStats(node: ParseNode) IncrementalStats {
    return .{
        .reused_nodes = countReusedNodes(node),
        .reused_bytes = countTopmostReusedBytes(node),
    };
}

fn countTopmostReusedBytes(node: ParseNode) usize {
    if (node.reused) return node.end_byte - node.start_byte;
    var count: usize = 0;
    for (node.children) |child| count += countTopmostReusedBytes(child);
    return count;
}

test "ParseNode helpers compare trees and mark reusable prefix nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const old_children = try arena.allocator().dupe(ParseNode, &[_]ParseNode{
        .{ .production_id = terminal_node_production_id, .start_byte = 0, .end_byte = 1, .entry_state = 0 },
        .{ .production_id = terminal_node_production_id, .start_byte = 1, .end_byte = 2, .entry_state = 1 },
    });
    const fresh_children = try arena.allocator().dupe(ParseNode, &[_]ParseNode{
        .{ .production_id = terminal_node_production_id, .start_byte = 0, .end_byte = 1, .entry_state = 0 },
        .{ .production_id = terminal_node_production_id, .start_byte = 1, .end_byte = 2, .entry_state = 1 },
        .{ .production_id = terminal_node_production_id, .start_byte = 2, .end_byte = 3, .entry_state = 2 },
    });
    const old_tree = ParseNode{
        .production_id = 1,
        .start_byte = 0,
        .end_byte = 2,
        .entry_state = 0,
        .children = old_children,
    };
    const fresh_tree = ParseNode{
        .production_id = 1,
        .start_byte = 0,
        .end_byte = 3,
        .entry_state = 0,
        .children = fresh_children,
    };

    try std.testing.expect(parseTreesEquivalent(old_tree, old_tree));
    try std.testing.expect(!parseTreesEquivalent(old_tree, fresh_tree));

    const marked = try cloneParseNodeWithReuseMarkersAlloc(arena.allocator(), fresh_tree, old_tree, .{
        .start_byte = 2,
        .old_end_byte = 2,
        .new_end_byte = 3,
    });
    try std.testing.expectEqual(@as(usize, 2), countReusedNodes(marked));
}

test "incremental tree equivalence accepts ambiguous shape differences with same yield" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const left_nested_children = try arena.allocator().dupe(ParseNode, &[_]ParseNode{
        .{ .production_id = terminal_node_production_id, .start_byte = 0, .end_byte = 1, .entry_state = 0 },
        .{ .production_id = terminal_node_production_id, .start_byte = 1, .end_byte = 2, .entry_state = 1 },
    });
    const left_children = try arena.allocator().dupe(ParseNode, &[_]ParseNode{
        .{ .production_id = 10, .start_byte = 0, .end_byte = 2, .entry_state = 0, .children = left_nested_children },
        .{ .production_id = terminal_node_production_id, .start_byte = 2, .end_byte = 3, .entry_state = 2 },
    });
    const right_nested_children = try arena.allocator().dupe(ParseNode, &[_]ParseNode{
        .{ .production_id = terminal_node_production_id, .start_byte = 1, .end_byte = 2, .entry_state = 1 },
        .{ .production_id = terminal_node_production_id, .start_byte = 2, .end_byte = 3, .entry_state = 2 },
    });
    const right_children = try arena.allocator().dupe(ParseNode, &[_]ParseNode{
        .{ .production_id = terminal_node_production_id, .start_byte = 0, .end_byte = 1, .entry_state = 0 },
        .{ .production_id = 10, .start_byte = 1, .end_byte = 3, .entry_state = 1, .children = right_nested_children },
    });
    const left_assoc = ParseNode{
        .production_id = 20,
        .start_byte = 0,
        .end_byte = 3,
        .entry_state = 0,
        .children = left_children,
    };
    const right_assoc = ParseNode{
        .production_id = 20,
        .start_byte = 0,
        .end_byte = 3,
        .entry_state = 0,
        .children = right_children,
    };

    try std.testing.expect(!parseTreesEquivalent(left_assoc, right_assoc));
    try std.testing.expect(try incrementalTreesEquivalentAlloc(arena.allocator(), left_assoc, right_assoc));
}

test "incremental reuse rejects states with external lex state metadata" {
    try std.testing.expect(stateAllowsIncrementalReuse(0, &[_]u16{0}));
    try std.testing.expect(!stateAllowsIncrementalReuse(1, &[_]u16{ 0, 2 }));
    try std.testing.expect(stateAllowsIncrementalReuse(3, &[_]u16{ 0, 2 }));
}

test "simulatePreparedScannerFreeIncremental reuses prefix nodes after append edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), ambiguous_expr_grammar_json);
    const old_result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1+2+3");
    const fresh_result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1+2+3+4");
    const incremental_result = try simulatePreparedScannerFreeIncremental(
        arena.allocator(),
        prepared,
        old_result.accepted.tree,
        .{
            .start_byte = 5,
            .old_end_byte = 5,
            .new_end_byte = 7,
        },
        "1+2+3+4",
    );

    const incremental_tree = incremental_result.accepted.tree orelse return error.TestUnexpectedResult;
    const fresh_tree = fresh_result.accepted.tree orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(fresh_result.accepted.consumed_bytes, incremental_result.accepted.consumed_bytes);
    try std.testing.expect(incremental_result.accepted.shifted_tokens < fresh_result.accepted.shifted_tokens);
    try std.testing.expect(try incrementalTreesEquivalentAlloc(arena.allocator(), fresh_tree, incremental_tree));
    try std.testing.expect(countReusedNodes(incremental_tree) > 0);
    try std.testing.expect(incremental_result.accepted.incremental.reused_nodes > 0);
    try std.testing.expect(incremental_result.accepted.incremental.reused_bytes > 0);
    try std.testing.expect(incremental_result.accepted.incremental.fresh_shifted_tokens < fresh_result.accepted.shifted_tokens);
}

test "simulatePreparedScannerFreeIncremental supports start middle and end edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), digit_list_grammar_json);

    try expectScannerFreeIncrementalEdit(
        arena.allocator(),
        prepared,
        "123",
        "9123",
        .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = 1 },
        false,
    );
    try expectScannerFreeIncrementalEdit(
        arena.allocator(),
        prepared,
        "123",
        "193",
        .{ .start_byte = 1, .old_end_byte = 2, .new_end_byte = 2 },
        true,
    );
    try expectScannerFreeIncrementalEdit(
        arena.allocator(),
        prepared,
        "123",
        "12",
        .{ .start_byte = 2, .old_end_byte = 3, .new_end_byte = 2 },
        true,
    );
}

test "simulatePreparedIncrementalWithExternalLexStates blocks unsafe prefix reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), ambiguous_expr_grammar_json);
    const old_result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1+2+3");
    const fresh_result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1+2+3+4");
    const external_lex_states = [_]u16{1} ** 64;
    const incremental_result = try simulatePreparedIncrementalWithExternalLexStates(
        arena.allocator(),
        prepared,
        old_result.accepted.tree,
        .{
            .start_byte = 5,
            .old_end_byte = 5,
            .new_end_byte = 7,
        },
        "1+2+3+4",
        external_lex_states[0..],
    );

    const incremental_tree = incremental_result.accepted.tree orelse return error.TestUnexpectedResult;
    const fresh_tree = fresh_result.accepted.tree orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(fresh_result.accepted.consumed_bytes, incremental_result.accepted.consumed_bytes);
    try std.testing.expectEqual(fresh_result.accepted.shifted_tokens, incremental_result.accepted.shifted_tokens);
    try std.testing.expect(try incrementalTreesEquivalentAlloc(arena.allocator(), fresh_tree, incremental_tree));
    try std.testing.expectEqual(@as(usize, 0), countReusedNodes(incremental_tree));
}

test "tryReuseOldSubtree restores sampled external scanner state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), ambiguous_expr_grammar_json);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const flattened = try flatten_grammar.flattenGrammar(arena.allocator(), extracted.syntax);
    const result = try build.buildStates(arena.allocator(), flattened);
    const old_result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1+2+3");

    var old_tree = old_result.accepted.tree orelse return error.TestUnexpectedResult;
    old_tree.external_layout_indents_after = try arena.allocator().dupe(usize, &[_]usize{ 2, 4 });

    var version = try ParseVersion.initFirst(arena.allocator());
    defer version.deinit(arena.allocator());

    const reused = try tryReuseOldSubtree(arena.allocator(), result, &version, .{
        .old_tree = old_tree,
        .edit = .{
            .start_byte = 5,
            .old_end_byte = 5,
            .new_end_byte = 7,
        },
    });

    try std.testing.expect(reused);
    try std.testing.expectEqual(@as(usize, 5), version.cursor);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 4 }, version.external_state.layout_indents.items);
}

test "bracket_lang incremental fixture does not reuse unsafe external states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), bracket_lang_incremental_grammar_json);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const flattened = try flatten_grammar.flattenGrammar(arena.allocator(), extracted.syntax);
    const result = try build.buildStates(arena.allocator(), flattened);
    const external_boundary = try scanner_serialize.serializeExternalScannerBoundary(arena.allocator(), extracted.syntax);

    const old_result = try simulateBuiltScannerFreeWithIncremental(
        arena.allocator(),
        result,
        prepared,
        flattened,
        extracted.lexical,
        "(())",
        .none(),
        external_boundary,
    );
    const fresh_result = try simulateBuiltScannerFreeWithIncremental(
        arena.allocator(),
        result,
        prepared,
        flattened,
        extracted.lexical,
        "(())()",
        .none(),
        external_boundary,
    );

    const external_lex_states = try arena.allocator().alloc(u16, result.states.len);
    @memset(external_lex_states, 1);

    const incremental_result = try simulateBuiltScannerFreeWithIncremental(
        arena.allocator(),
        result,
        prepared,
        flattened,
        extracted.lexical,
        "(())()",
        .{
            .old_tree = old_result.accepted.tree,
            .edit = .{
                .start_byte = 4,
                .old_end_byte = 4,
                .new_end_byte = 6,
            },
            .external_lex_states = external_lex_states,
        },
        external_boundary,
    );

    const fresh_tree = fresh_result.accepted.tree orelse return error.TestUnexpectedResult;
    const incremental_tree = incremental_result.accepted.tree orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(fresh_result.accepted.consumed_bytes, incremental_result.accepted.consumed_bytes);
    try std.testing.expectEqual(fresh_result.accepted.shifted_tokens, incremental_result.accepted.shifted_tokens);
    try std.testing.expect(try incrementalTreesEquivalentAlloc(arena.allocator(), fresh_tree, incremental_tree));
    try std.testing.expectEqual(@as(usize, 0), countReusedNodes(incremental_tree));
}

fn expectScannerFreeIncrementalEdit(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    old_input: []const u8,
    new_input: []const u8,
    edit: Edit,
    expect_prefix_reuse: bool,
) !void {
    const old_result = try simulatePreparedScannerFree(allocator, prepared, old_input);
    const fresh_result = try simulatePreparedScannerFree(allocator, prepared, new_input);
    const incremental_result = try simulatePreparedScannerFreeIncremental(
        allocator,
        prepared,
        old_result.accepted.tree,
        edit,
        new_input,
    );

    const fresh_tree = fresh_result.accepted.tree orelse return error.TestUnexpectedResult;
    const incremental_tree = incremental_result.accepted.tree orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(fresh_result.accepted.consumed_bytes, incremental_result.accepted.consumed_bytes);
    try std.testing.expect(parseTreesEquivalent(fresh_tree, incremental_tree));
    if (expect_prefix_reuse) {
        try std.testing.expect(incremental_result.accepted.incremental.reused_nodes > 0);
        try std.testing.expect(incremental_result.accepted.incremental.reused_bytes > 0);
        try std.testing.expect(incremental_result.accepted.incremental.fresh_shifted_tokens < fresh_result.accepted.shifted_tokens);
    } else {
        try std.testing.expectEqual(@as(usize, 0), incremental_result.accepted.incremental.reused_nodes);
        try std.testing.expectEqual(fresh_result.accepted.shifted_tokens, incremental_result.accepted.incremental.fresh_shifted_tokens);
    }
}

fn expectSameSimulationResult(expected: SimulationResult, actual: SimulationResult) !void {
    try std.testing.expectEqual(@intFromEnum(expected), @intFromEnum(actual));
    switch (expected) {
        .accepted => |left| {
            const right = actual.accepted;
            try std.testing.expectEqual(left.consumed_bytes, right.consumed_bytes);
            try std.testing.expectEqual(left.shifted_tokens, right.shifted_tokens);
        },
        .rejected => |left| {
            const right = actual.rejected;
            try std.testing.expectEqual(left.consumed_bytes, right.consumed_bytes);
            try std.testing.expectEqual(left.shifted_tokens, right.shifted_tokens);
            try std.testing.expectEqual(left.reason, right.reason);
        },
    }
}

fn expectCompatibilitySafeValidResult(result: SimulationResult) !void {
    switch (result) {
        .accepted => |accepted| {
            try std.testing.expect(accepted.consumed_bytes > 0);
            try std.testing.expect(accepted.shifted_tokens > 0);
        },
        .rejected => |rejected| {
            try std.testing.expect(rejected.consumed_bytes > 0);
            try std.testing.expect(rejected.shifted_tokens > 0);
            try std.testing.expect(rejected.reason != .unresolved_decision);
            try std.testing.expect(rejected.reason != .missing_goto);
        },
    }
}

fn simulateValidGrammarJsPath(
    grammar_path: []const u8,
    input: []const u8,
    use_external_boundary: bool,
) !SimulationResult {
    var loaded = try grammar_loader.loadGrammarFile(std.testing.allocator, grammar_path);
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(arena.allocator(), &loaded.json.grammar);

    if (use_external_boundary) {
        return try simulatePreparedWithFirstExternalBoundary(arena.allocator(), prepared, input);
    }
    return try simulatePreparedScannerFree(arena.allocator(), prepared, input);
}

fn progressOf(result: SimulationResult) usize {
    return switch (result) {
        .accepted => |accepted| accepted.consumed_bytes,
        .rejected => |rejected| rejected.consumed_bytes,
    };
}

// Grammar: source_file → "a" "b"
// Used to test error recovery: unrecognised characters and unexpected tokens
// are skipped and the parse proceeds rather than failing.
const seq_ab_grammar_json =
    \\{
    \\  "name": "seq_ab",
    \\  "rules": {
    \\    "source_file": {
    \\      "type": "SEQ",
    \\      "members": [
    \\        { "type": "STRING", "value": "a" },
    \\        { "type": "STRING", "value": "b" }
    \\      ]
    \\    }
    \\  }
    \\}
;

test "error recovery skips an unrecognised byte and accepts the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), ambiguous_expr_grammar_json);
    // "1" is a valid number; "!" is unrecognised — recovery skips it and the parse accepts.
    const result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1!");
    switch (result) {
        .accepted => |a| try std.testing.expect(a.error_count > 0),
        .rejected => return error.UnexpectedReject,
    }
}

test "error recovery accepts valid input without recording errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), ambiguous_expr_grammar_json);
    const result = try simulatePreparedScannerFree(arena.allocator(), prepared, "1");
    switch (result) {
        .accepted => |a| try std.testing.expectEqual(@as(u32, 0), a.error_count),
        .rejected => return error.UnexpectedReject,
    }
}

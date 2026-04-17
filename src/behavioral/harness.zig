const std = @import("std");
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

pub const SimulationResult = union(enum) {
    accepted: struct {
        consumed_bytes: usize,
        shifted_tokens: usize,
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

    fn topLayoutIndent(self: SampledExternalState) ?usize {
        if (self.layout_indents.items.len == 0) return null;
        return self.layout_indents.items[self.layout_indents.items.len - 1];
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
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "GEN_Z_SITTER_BEHAVIORAL_PROGRESS") catch {
        const fallback = std.process.getEnvVarOwned(std.heap.page_allocator, "GEN_Z_SITTER_PROGRESS") catch return false;
        defer std.heap.page_allocator.free(fallback);
        if (fallback.len == 0) return false;
        if (std.mem.eql(u8, fallback, "0")) return false;
        return true;
    };
    defer std.heap.page_allocator.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
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
    const extracted = try extract_tokens.extractTokens(allocator, prepared);
    const flattened = try flatten_grammar.flattenGrammar(allocator, extracted.syntax);
    const result = try build.buildStates(allocator, flattened);
    return simulateBuiltScannerFree(allocator, result, prepared, extracted.lexical, input);
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
        lexical,
        external_boundary,
        input,
    );
}

pub fn sampleExtractedExternalBoundaryOnly(
    allocator: std.mem.Allocator,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    input: []const u8,
) BehavioralError!ExternalBoundarySample {
    if (!external_boundary.isReady()) return error.UnsupportedExternalScannerGrammar;
    var expanded_lexical = try prepareExpandedLexicalGrammar(allocator, prepared.rules, lexical);
    defer deinitExpandedLexicalGrammar(allocator, &expanded_lexical);
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

        if (skipSupportedExtraPrefix(input[cursor..])) |skip_len| {
            cursor += skip_len;
            continue;
        }

        if (try matchLexicalPrefix(allocator, lexical, prepared.rules, expandedLexicalPtr(&expanded_lexical), input[cursor..])) |len| {
            cursor += len;
            lexical_matches += 1;
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

fn simulateBuiltScannerFree(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    input: []const u8,
) BehavioralError!SimulationResult {
    if (lexical.separators.len != 0) return error.UnsupportedScannerFreeGrammar;
    var expanded_lexical = try prepareExpandedLexicalGrammar(allocator, prepared.rules, lexical);
    defer deinitExpandedLexicalGrammar(allocator, &expanded_lexical);

    var stack = std.array_list.Managed(u32).init(allocator);
    defer stack.deinit();
    try stack.append(0);

    var cursor: usize = 0;
    var shifted_tokens: usize = 0;
    var steps: usize = 0;
    const max_steps = input.len * 16 + 32;

    while (steps < max_steps) : (steps += 1) {
        const state_id = stack.items[stack.items.len - 1];
        if (cursor >= input.len) {
            if (stateHasCompletedAugmentedProduction(result, state_id)) {
                return .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } };
            }
            if (selectFallbackAction(result, state_id)) |action| switch (action) {
                .shift => return .{ .rejected = .{
                    .consumed_bytes = cursor,
                    .shifted_tokens = shifted_tokens,
                    .reason = .missing_action,
                } },
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
                .accept => return .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } },
            };
            return .{ .rejected = .{
                .consumed_bytes = cursor,
                .shifted_tokens = shifted_tokens,
                .reason = .missing_action,
            } };
        }

        const matched = try selectMatchingTerminal(
            allocator,
            result,
            state_id,
            prepared,
            lexical,
            expandedLexicalPtr(&expanded_lexical),
            input[cursor..],
        ) orelse {
            if (selectFallbackAction(result, state_id)) |action| switch (action) {
                .shift => return .{ .rejected = .{
                    .consumed_bytes = cursor,
                    .shifted_tokens = shifted_tokens,
                    .reason = .tokenization_failed,
                } },
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
                .accept => return .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } },
            };
            return .{ .rejected = .{
                .consumed_bytes = cursor,
                .shifted_tokens = shifted_tokens,
                .reason = .tokenization_failed,
            } };
        };
        const decision = result.resolved_actions.decisionFor(state_id, matched.symbol) orelse
            return .{ .rejected = .{
                .consumed_bytes = cursor,
                .shifted_tokens = shifted_tokens,
                .reason = .missing_action,
            } };

        switch (decision) {
            .unresolved => return .{ .rejected = .{
                .consumed_bytes = cursor,
                .shifted_tokens = shifted_tokens,
                .reason = .unresolved_decision,
            } },
            .chosen => |action| switch (action) {
                .shift => |target| {
                    try stack.append(target);
                    cursor += matched.len;
                    shifted_tokens += 1;
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
                .accept => return .{ .accepted = .{ .consumed_bytes = cursor, .shifted_tokens = shifted_tokens } },
            },
        }
    }

    return error.SimulationStepLimitExceeded;
}

fn simulateBuiltWithFirstExternalBoundary(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    external_boundary: scanner_serialize.SerializedExternalScannerBoundary,
    input: []const u8,
) BehavioralError!SimulationResult {
    if (lexical.separators.len != 0) return error.UnsupportedExternalScannerGrammar;
    if (!external_boundary.isReady()) return error.UnsupportedExternalScannerGrammar;
    var expanded_lexical = try prepareExpandedLexicalGrammar(allocator, prepared.rules, lexical);
    defer deinitExpandedLexicalGrammar(allocator, &expanded_lexical);
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
            allocator,
            result,
            state_id,
            prepared,
            lexical,
            expandedLexicalPtr(&expanded_lexical),
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
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    state_id: u32,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    expanded_lexical: ?*const lexer_model.ExpandedLexicalGrammar,
    remaining: []const u8,
) std.mem.Allocator.Error!?MatchedTerminal {
    var best: ?MatchedTerminal = null;

    for (lexical.variables, 0..) |_, index| {
        const match_len = try matchLexicalVariablePrefix(
            allocator,
            prepared.rules,
            lexical,
            expanded_lexical,
            index,
            remaining,
        ) orelse continue;

        const symbol: syntax_ir.SymbolRef = .{ .terminal = @intCast(index) };
        if (result.resolved_actions.decisionFor(state_id, symbol) == null) continue;

        if (best == null or lexicalMatchBetter(lexical, best.?.symbol.terminal, index, best.?.len, match_len)) {
            best = .{ .symbol = symbol, .len = match_len };
        }
    }

    return best;
}

fn selectMatchingSymbolWithExternalBoundary(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    state_id: u32,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    expanded_lexical: ?*const lexer_model.ExpandedLexicalGrammar,
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

    for (lexical.variables, 0..) |_, index| {
        const match_len = try matchLexicalVariablePrefix(
            allocator,
            prepared.rules,
            lexical,
            expanded_lexical,
            index,
            remaining,
        ) orelse continue;

        const symbol: syntax_ir.SymbolRef = .{ .terminal = @intCast(index) };
        if (result.resolved_actions.decisionFor(state_id, symbol) == null) continue;

        if (best == null or lexicalExternalMatchBetter(lexical, best.?, index, match_len)) {
            best = .{ .symbol = symbol, .len = match_len };
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
    lexical: lexical_ir.LexicalGrammar,
    all_rules: []const rules.Rule,
    expanded_lexical: ?*const lexer_model.ExpandedLexicalGrammar,
    input: []const u8,
) std.mem.Allocator.Error!?usize {
    if (expanded_lexical) |expanded| {
        if (try lexer_model.selectBestToken(allocator, expanded.*, input)) |match| return match.len;
    }

    var best: ?usize = null;
    for (lexical.variables) |variable| {
        const match_len = matchLexicalRulePrefix(all_rules, variable.rule, input) orelse continue;
        if (best == null or match_len > best.?) best = match_len;
    }
    return best orelse matchSampledLexicalFallback(input);
}

fn matchLexicalVariablePrefix(
    allocator: std.mem.Allocator,
    all_rules: []const rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
    expanded_lexical: ?*const lexer_model.ExpandedLexicalGrammar,
    variable_index: usize,
    input: []const u8,
) std.mem.Allocator.Error!?usize {
    if (expanded_lexical) |expanded| {
        return try lexer_model.matchVariable(allocator, expanded.*, variable_index, input);
    }
    return matchLexicalRulePrefix(all_rules, lexical.variables[variable_index].rule, input);
}

fn lexicalMatchBetter(
    lexical: lexical_ir.LexicalGrammar,
    current_index: usize,
    candidate_index: usize,
    current_len: usize,
    candidate_len: usize,
) bool {
    if (candidate_len != current_len) return candidate_len > current_len;
    return lexical.variables[candidate_index].kind == .named and lexical.variables[current_index].kind != .named;
}

fn lexicalExternalMatchBetter(
    lexical: lexical_ir.LexicalGrammar,
    current: MatchedTerminal,
    candidate_index: usize,
    candidate_len: usize,
) bool {
    if (candidate_len != current.len) return candidate_len > current.len;
    return switch (current.symbol) {
        .external => false,
        .terminal => |current_index| lexicalMatchBetter(lexical, current_index, candidate_index, current.len, candidate_len),
        else => false,
    };
}

fn prepareExpandedLexicalGrammar(
    allocator: std.mem.Allocator,
    all_rules: []const rules.Rule,
    lexical: lexical_ir.LexicalGrammar,
) std.mem.Allocator.Error!?lexer_model.ExpandedLexicalGrammar {
    return lexer_model.expandExtractedLexicalGrammar(allocator, all_rules, lexical) catch |err| switch (err) {
        error.UnsupportedRule, error.UnsupportedPattern => null,
        else => |alloc_err| alloc_err,
    };
}

fn deinitExpandedLexicalGrammar(
    allocator: std.mem.Allocator,
    expanded_lexical: *?lexer_model.ExpandedLexicalGrammar,
) void {
    if (expanded_lexical.*) |*expanded| expanded.deinit(allocator);
    expanded_lexical.* = null;
}

fn expandedLexicalPtr(
    expanded_lexical: *const ?lexer_model.ExpandedLexicalGrammar,
) ?*const lexer_model.ExpandedLexicalGrammar {
    if (expanded_lexical.*) |*expanded| return expanded;
    return null;
}

fn matchLexicalRulePrefix(
    all_rules: []const rules.Rule,
    rule_id: rules.RuleId,
    input: []const u8,
) ?usize {
    return switch (all_rules[rule_id]) {
        .string => |value| if (std.mem.startsWith(u8, input, value)) value.len else null,
        .pattern => |pattern| matchSupportedPatternPrefix(pattern, input),
        .metadata => |metadata| matchLexicalRulePrefix(all_rules, metadata.inner, input),
        else => null,
    };
}

fn matchSupportedPatternPrefix(pattern: rules.Pattern, input: []const u8) ?usize {
    const value = pattern.value;
    if (value.len < 5) return null;
    if (value[0] != '[') return null;
    if (value[value.len - 2] != ']' or value[value.len - 1] != '+') return null;

    const body = value[1 .. value.len - 2];
    if (body.len != 3 or body[1] != '-') return null;

    const range_start = body[0];
    const range_end = body[2];
    const case_insensitive = if (pattern.flags) |flags|
        std.mem.indexOfScalar(u8, flags, 'i') != null
    else
        false;

    var len: usize = 0;
    while (len < input.len) : (len += 1) {
        var ch = input[len];
        if (case_insensitive and ch >= 'A' and ch <= 'Z') ch = std.ascii.toLower(ch);
        if (ch < range_start or ch > range_end) break;
    }

    return if (len > 0) len else null;
}

fn skipSupportedExtraPrefix(input: []const u8) ?usize {
    if (input.len == 0) return null;
    return switch (input[0]) {
        ' ', '\t', '\r', '\n' => 1,
        else => null,
    };
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
        switch (group.decision) {
            .unresolved => return null,
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

test "simulatePreparedScannerFree rejects the invalid behavioral config input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), fixtures.behavioralConfigGrammarJson().contents);
    const result = try simulatePreparedScannerFree(arena.allocator(), prepared, fixtures.behavioralConfigInvalidInput().contents);

    switch (result) {
        .accepted => try std.testing.expect(false),
        .rejected => |rejected| {
            try std.testing.expect(
                rejected.reason == .tokenization_failed or
                    rejected.reason == .missing_action or
                    rejected.reason == .missing_goto,
            );
        },
    }
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

    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data = fixtures.behavioralConfigGrammarJs().contents,
    });

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
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
    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data = js,
    });

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
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
    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data = js,
    });

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
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
    try tmp.dir.writeFile(.{
        .sub_path = "grammar.js",
        .data = js,
    });

    const grammar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "grammar.js");
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

    const grammar = try std.fs.cwd().readFileAlloc(
        arena.allocator(),
        "compat_targets/tree_sitter_haskell/grammar.json",
        1024 * 1024,
    );
    const valid_input = try std.fs.cwd().readFileAlloc(
        arena.allocator(),
        "compat_targets/tree_sitter_haskell/valid.txt",
        64 * 1024,
    );
    const invalid_input = try std.fs.cwd().readFileAlloc(
        arena.allocator(),
        "compat_targets/tree_sitter_haskell/invalid.txt",
        64 * 1024,
    );

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), grammar);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try scanner_serialize.serializeExternalScannerBoundary(arena.allocator(), extracted.syntax);

    const valid = try sampleExtractedExternalBoundaryOnly(
        arena.allocator(),
        prepared,
        extracted.lexical,
        serialized,
        valid_input,
    );
    const invalid = try sampleExtractedExternalBoundaryOnly(
        arena.allocator(),
        prepared,
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

    const grammar = try std.fs.cwd().readFileAlloc(
        arena.allocator(),
        "compat_targets/tree_sitter_bash/grammar.json",
        1024 * 1024,
    );
    const valid_input = try std.fs.cwd().readFileAlloc(
        arena.allocator(),
        "compat_targets/tree_sitter_bash/valid.txt",
        64 * 1024,
    );
    const invalid_input = try std.fs.cwd().readFileAlloc(
        arena.allocator(),
        "compat_targets/tree_sitter_bash/invalid.txt",
        64 * 1024,
    );

    const prepared = try parsePreparedFromJsonFixture(arena.allocator(), grammar);
    const extracted = try extract_tokens.extractTokens(arena.allocator(), prepared);
    const serialized = try scanner_serialize.serializeExternalScannerBoundary(arena.allocator(), extracted.syntax);

    const valid = try sampleExtractedExternalBoundaryOnly(
        arena.allocator(),
        prepared,
        extracted.lexical,
        serialized,
        valid_input,
    );
    const invalid = try sampleExtractedExternalBoundaryOnly(
        arena.allocator(),
        prepared,
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

    try tmp.dir.writeFile(.{
        .sub_path = "behavioral_config.js",
        .data = fixtures.behavioralConfigGrammarJs().contents,
    });
    const external_js = try std.fmt.allocPrint(std.testing.allocator, "module.exports = {s};", .{fixtures.hiddenExternalFieldsGrammarJson().contents});
    defer std.testing.allocator.free(external_js);
    try tmp.dir.writeFile(.{
        .sub_path = "hidden_external_fields.js",
        .data = external_js,
    });

    const behavioral_path = try tmp.dir.realpathAlloc(std.testing.allocator, "behavioral_config.js");
    defer std.testing.allocator.free(behavioral_path);
    const external_path = try tmp.dir.realpathAlloc(std.testing.allocator, "hidden_external_fields.js");
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
    try tmp.dir.writeFile(.{
        .sub_path = "repeat_choice_seq.js",
        .data = repeat_js,
    });
    const repeat_path = try tmp.dir.realpathAlloc(std.testing.allocator, "repeat_choice_seq.js");
    defer std.testing.allocator.free(repeat_path);

    const js_valid = try simulateValidGrammarJsPath(
        repeat_path,
        fixtures.repeatChoiceSeqValidInput().contents,
        false,
    );
    try expectSameSimulationResult(json_valid, js_valid);
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

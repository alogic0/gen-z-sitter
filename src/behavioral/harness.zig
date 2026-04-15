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

fn simulateBuiltScannerFree(
    allocator: std.mem.Allocator,
    result: build.BuildResult,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    input: []const u8,
) BehavioralError!SimulationResult {
    if (lexical.separators.len != 0) return error.UnsupportedScannerFreeGrammar;

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

        const matched = selectMatchingTerminal(result, state_id, prepared, lexical, input[cursor..]) orelse {
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

const MatchedTerminal = struct {
    symbol: syntax_ir.SymbolRef,
    len: usize,
};

fn selectMatchingTerminal(
    result: build.BuildResult,
    state_id: u32,
    prepared: grammar_ir.PreparedGrammar,
    lexical: lexical_ir.LexicalGrammar,
    remaining: []const u8,
) ?MatchedTerminal {
    var best: ?MatchedTerminal = null;

    for (lexical.variables, 0..) |variable, index| {
        const literal = ruleLiteralText(prepared.rules, variable.rule) orelse return null;
        if (literal.len == 0) continue;
        if (!std.mem.startsWith(u8, remaining, literal)) continue;

        const symbol: syntax_ir.SymbolRef = .{ .terminal = @intCast(index) };
        if (result.resolved_actions.decisionFor(state_id, symbol) == null) continue;

        if (best == null or literal.len > best.?.len) {
            best = .{ .symbol = symbol, .len = literal.len };
        }
    }

    return best;
}

fn ruleLiteralText(all_rules: []const rules.Rule, rule_id: rules.RuleId) ?[]const u8 {
    return switch (all_rules[rule_id]) {
        .string => |value| value,
        .metadata => |metadata| ruleLiteralText(all_rules, metadata.inner),
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
    for (parse_state.items) |parse_item| {
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

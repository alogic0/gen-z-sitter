const std = @import("std");
const actions = @import("actions.zig");
const item = @import("item.zig");
const resolution = @import("resolution.zig");
const state = @import("state.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const runtime_io = @import("../support/runtime_io.zig");

pub const MinimizeResult = struct {
    states: []state.ParseState,
    resolved_actions: resolution.ResolvedActionTable,
    merged_count: usize,

    pub fn deinit(self: MinimizeResult, allocator: std.mem.Allocator) void {
        for (self.states) |parse_state| allocator.free(parse_state.transitions);
        allocator.free(self.states);
        for (self.resolved_actions.states) |resolved_state| {
            for (resolved_state.groups) |group| {
                if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
            }
            if (resolved_state.groups.len != 0) allocator.free(resolved_state.groups);
        }
        allocator.free(self.resolved_actions.states);
    }
};

pub const TerminalConflictMap = struct {
    terminal_count: usize,
    conflicts: []const bool,
    keyword_tokens: []const bool = &.{},
    external_internal_tokens: []const bool = &.{},
    reserved_word_sets: []const []const syntax_ir.SymbolRef = &.{},
    terminal_names: []const []const u8 = &.{},

    pub fn conflictsWith(self: TerminalConflictMap, left: usize, right: usize) bool {
        if (left >= self.terminal_count or right >= self.terminal_count) return true;
        return self.conflicts[left * self.terminal_count + right];
    }

    pub fn isKeyword(self: TerminalConflictMap, token: usize) bool {
        return token < self.keyword_tokens.len and self.keyword_tokens[token];
    }

    pub fn isExternalInternal(self: TerminalConflictMap, token: usize) bool {
        return token < self.external_internal_tokens.len and self.external_internal_tokens[token];
    }

    pub fn tokenName(self: TerminalConflictMap, token: usize) []const u8 {
        if (token < self.terminal_names.len) return self.terminal_names[token];
        return "";
    }
};

pub const UnitReductionProduction = struct {
    lhs: u32,
    child_count: u16,
    dynamic_precedence: i32 = 0,
    metadata_empty: bool,
    production_info_id: ?u16 = null,
};

pub const UnitReductionSymbol = struct {
    kind: syntax_ir.VariableKind,
    simple_alias: bool = false,
    supertype: bool = false,
    extra: bool = false,
    aliased: bool = false,
};

pub const UnitReductionOptions = struct {
    productions: []const UnitReductionProduction,
    symbols: []const UnitReductionSymbol,
};

const UnitReductionRejectStats = struct {
    candidates: usize = 0,
    empty_action_groups: usize = 0,
    shift: usize = 0,
    accept: usize = 0,
    non_unit_reduce: usize = 0,
    non_empty_metadata: usize = 0,
    filtered_symbol: usize = 0,
    multiple_symbols: usize = 0,
    no_unit_symbol: usize = 0,
};

const ReorderStateContext = struct {
    states: []const state.ParseState,
    resolved: resolution.ResolvedActionTable,
};

const MinimizeTraceStats = struct {
    external_token: usize = 0,
    internal_external_token: usize = 0,
    token_conflict: usize = 0,
    action_count: usize = 0,
    unequal_action: usize = 0,
    shift_repetition: usize = 0,
    action_successor: usize = 0,
    successor_shift: usize = 0,
    successor_nonterminal: usize = 0,
};

fn traceMinimizerEnabled() bool {
    return envFlagEnabled("GEN_Z_SITTER_MINIMIZER_TRACE");
}

fn ignoreTokenConflictsForMinimizer() bool {
    return envFlagEnabled("GEN_Z_SITTER_MINIMIZER_IGNORE_TOKEN_CONFLICTS");
}

fn traceTokenConflictsEnabled() bool {
    return envFlagEnabled("GEN_Z_SITTER_MINIMIZER_TOKEN_TRACE");
}

fn relaxUnitReductionForDiagnostics() bool {
    return envFlagEnabled("GEN_Z_SITTER_MINIMIZER_RELAX_UNIT_REDUCTION");
}

fn envFlagEnabled(name: []const u8) bool {
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        name,
    ) catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

const token_trace_max = 256;

threadlocal var token_trace_counts: [token_trace_max * token_trace_max]u64 = [_]u64{0} ** (token_trace_max * token_trace_max);
threadlocal var token_trace_total: u64 = 0;
threadlocal var token_trace_active: bool = false;
threadlocal var token_ignore_pairs: [token_trace_max * token_trace_max]bool = [_]bool{false} ** (token_trace_max * token_trace_max);
threadlocal var token_ignore_pairs_active: bool = false;
threadlocal var successor_ignore_tokens: [token_trace_max]bool = [_]bool{false} ** token_trace_max;
threadlocal var successor_ignore_tokens_active: bool = false;
threadlocal var minimize_trace_stats: MinimizeTraceStats = .{};
threadlocal var minimize_trace_stats_active: bool = false;
threadlocal var successor_trace_counts: [token_trace_max]u64 = [_]u64{0} ** token_trace_max;
threadlocal var successor_detail_token: ?usize = null;
threadlocal var successor_detail_remaining: usize = 0;
threadlocal var state_detail_id: ?state.StateId = null;
threadlocal var state_detail_remaining: usize = 0;
threadlocal var action_detail_remaining: usize = 0;
threadlocal var conflict_pair_detail_remaining: usize = 0;
const max_trace_pairs = 16;
threadlocal var pair_detail_pairs: [max_trace_pairs]struct { left: state.StateId, right: state.StateId } = undefined;
threadlocal var pair_detail_count: usize = 0;
threadlocal var pair_detail_remaining: usize = 0;
threadlocal var reference_detail_targets: [max_trace_pairs]state.StateId = undefined;
threadlocal var reference_detail_count: usize = 0;

fn resetMinimizeTraceStats() void {
    minimize_trace_stats = .{};
    @memset(&successor_trace_counts, 0);
}

fn recordMinimizeTraceStat(comptime field_name: []const u8) void {
    if (!minimize_trace_stats_active) return;
    @field(minimize_trace_stats, field_name) += 1;
}

fn recordSuccessorTraceSymbol(symbol: syntax_ir.SymbolRef) void {
    if (!minimize_trace_stats_active) return;
    const terminal = switch (symbol) {
        .terminal => |idx| idx,
        else => return,
    };
    if (terminal >= token_trace_max) return;
    successor_trace_counts[terminal] += 1;
}

fn printMinimizeTraceStats(conflict_map: ?TerminalConflictMap) void {
    std.debug.print(
        "[minimize] split_reasons external_token={d} internal_external_token={d} token_conflict={d} action_count={d} unequal_action={d} shift_repetition={d} action_successor={d} successor_shift={d} successor_nonterminal={d}\n",
        .{
            minimize_trace_stats.external_token,
            minimize_trace_stats.internal_external_token,
            minimize_trace_stats.token_conflict,
            minimize_trace_stats.action_count,
            minimize_trace_stats.unequal_action,
            minimize_trace_stats.shift_repetition,
            minimize_trace_stats.action_successor,
            minimize_trace_stats.successor_shift,
            minimize_trace_stats.successor_nonterminal,
        },
    );
    const map = conflict_map orelse return;
    std.debug.print("[minimize] successor_terminal_top:\n", .{});
    var emitted: usize = 0;
    while (emitted < 20) : (emitted += 1) {
        var best_count: u64 = 0;
        var best_token: usize = 0;
        for (0..@min(map.terminal_count, token_trace_max)) |token| {
            const count = successor_trace_counts[token];
            if (count <= best_count) continue;
            best_count = count;
            best_token = token;
        }
        if (best_count == 0) break;
        std.debug.print(
            "  {d}: {d}({s}) count={d}\n",
            .{ emitted + 1, best_token, map.tokenName(best_token), best_count },
        );
        successor_trace_counts[best_token] = 0;
    }
}

fn resetTokenConflictTrace() void {
    @memset(&token_trace_counts, 0);
    token_trace_total = 0;
}

fn tokenConflictTraceActive() bool {
    return token_trace_active;
}

fn loadIgnoredTokenConflictPairs() void {
    @memset(&token_ignore_pairs, false);
    token_ignore_pairs_active = false;
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        "GEN_Z_SITTER_MINIMIZER_IGNORE_TOKEN_PAIRS",
    ) catch return;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return;

    var pair_iter = std.mem.splitScalar(u8, value, ',');
    while (pair_iter.next()) |pair_text| {
        const separator = std.mem.indexOfScalar(u8, pair_text, ':') orelse continue;
        const left = std.fmt.parseUnsigned(usize, pair_text[0..separator], 10) catch continue;
        const right = std.fmt.parseUnsigned(usize, pair_text[separator + 1 ..], 10) catch continue;
        if (left >= token_trace_max or right >= token_trace_max) continue;
        token_ignore_pairs[left * token_trace_max + right] = true;
        token_ignore_pairs_active = true;
    }
}

fn loadIgnoredSuccessorTokens() void {
    @memset(&successor_ignore_tokens, false);
    successor_ignore_tokens_active = false;
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        "GEN_Z_SITTER_MINIMIZER_IGNORE_SUCCESSOR_TERMINALS",
    ) catch return;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return;

    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |token_text| {
        const token = std.fmt.parseUnsigned(usize, token_text, 10) catch continue;
        if (token >= token_trace_max) continue;
        successor_ignore_tokens[token] = true;
        successor_ignore_tokens_active = true;
    }
}

fn loadSuccessorDetailTrace() void {
    successor_detail_token = null;
    successor_detail_remaining = 0;
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        "GEN_Z_SITTER_MINIMIZER_TRACE_SUCCESSOR",
    ) catch return;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return;

    successor_detail_token = std.fmt.parseUnsigned(usize, value, 10) catch null;
    successor_detail_remaining = if (successor_detail_token != null) 32 else 0;
}

fn loadStateDetailTrace() void {
    state_detail_id = null;
    state_detail_remaining = 0;
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        "GEN_Z_SITTER_MINIMIZER_TRACE_STATE",
    ) catch return;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return;

    state_detail_id = std.fmt.parseUnsigned(state.StateId, value, 10) catch null;
    state_detail_remaining = if (state_detail_id != null) 64 else 0;
}

fn loadActionDetailTrace() void {
    action_detail_remaining = 0;
    if (!envFlagEnabled("GEN_Z_SITTER_MINIMIZER_TRACE_ACTION_DIFFS")) return;
    action_detail_remaining = 32;
}

fn loadConflictPairTrace() void {
    conflict_pair_detail_remaining = 0;
    if (!envFlagEnabled("GEN_Z_SITTER_MINIMIZER_TRACE_CONFLICT_PAIRS")) return;
    conflict_pair_detail_remaining = 5000;
}

fn loadPairDetailTrace() void {
    pair_detail_count = 0;
    pair_detail_remaining = 0;
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        "GEN_Z_SITTER_MINIMIZER_TRACE_PAIR",
    ) catch return;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return;

    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |pair_text| {
        if (pair_detail_count >= pair_detail_pairs.len) break;
        const separator = std.mem.indexOfScalar(u8, pair_text, ':') orelse continue;
        const left = std.fmt.parseUnsigned(state.StateId, pair_text[0..separator], 10) catch continue;
        const right = std.fmt.parseUnsigned(state.StateId, pair_text[separator + 1 ..], 10) catch continue;
        pair_detail_pairs[pair_detail_count] = .{ .left = left, .right = right };
        pair_detail_count += 1;
    }
    if (pair_detail_count != 0) pair_detail_remaining = 128;
}

fn loadReferenceDetailTrace() void {
    reference_detail_count = 0;
    const value = std.process.Environ.getAlloc(
        runtime_io.environ(),
        std.heap.page_allocator,
        "GEN_Z_SITTER_MINIMIZER_TRACE_REFERENCES",
    ) catch return;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return;

    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |target_text| {
        if (reference_detail_count >= reference_detail_targets.len) break;
        const target = std.fmt.parseUnsigned(state.StateId, target_text, 10) catch continue;
        reference_detail_targets[reference_detail_count] = target;
        reference_detail_count += 1;
    }
}

fn traceReferenceTargetMatches(target: state.StateId) bool {
    for (reference_detail_targets[0..reference_detail_count]) |candidate| {
        if (candidate == target) return true;
    }
    return false;
}

fn ignoredTokenConflictPair(left: usize, right: usize) bool {
    if (!token_ignore_pairs_active) return false;
    if (left >= token_trace_max or right >= token_trace_max) return false;
    return token_ignore_pairs[left * token_trace_max + right];
}

fn ignoredSuccessorSymbol(symbol: syntax_ir.SymbolRef) bool {
    if (!successor_ignore_tokens_active) return false;
    const terminal = switch (symbol) {
        .terminal => |idx| idx,
        else => return false,
    };
    if (terminal >= token_trace_max) return false;
    return successor_ignore_tokens[terminal];
}

fn traceSuccessorDetail(
    kind: []const u8,
    left_state_id: ?state.StateId,
    right_state_id: ?state.StateId,
    symbol: syntax_ir.SymbolRef,
    left_target: state.StateId,
    right_target: state.StateId,
    group_of: []const u32,
) void {
    if (successor_detail_remaining == 0) return;
    const token = switch (symbol) {
        .terminal => |idx| idx,
        else => return,
    };
    if (successor_detail_token != null and successor_detail_token.? != token) return;
    successor_detail_remaining -= 1;
    std.debug.print(
        "[minimize-successor] kind={s} token={d} left_state={?d} right_state={?d} left_target={d} right_target={d} left_group={d} right_group={d}\n",
        .{
            kind,
            token,
            left_state_id,
            right_state_id,
            left_target,
            right_target,
            groupOfState(group_of, left_target),
            groupOfState(group_of, right_target),
        },
    );
}

fn traceStateConflictDetail(
    reason: []const u8,
    left_state_id: state.StateId,
    right_state_id: state.StateId,
    symbol: syntax_ir.SymbolRef,
    left_target: ?state.StateId,
    right_target: ?state.StateId,
    group_of: []const u32,
) void {
    var should_trace = false;
    if (state_detail_remaining != 0) {
        if (state_detail_id) |traced| {
            if (left_state_id == traced or right_state_id == traced) {
                state_detail_remaining -= 1;
                should_trace = true;
            }
        }
    }
    if (!should_trace and pair_detail_remaining != 0 and tracePairMatches(left_state_id, right_state_id)) {
        pair_detail_remaining -= 1;
        should_trace = true;
    }
    if (!should_trace) return;
    const left_group = if (left_target) |target| groupOfState(group_of, target) else null;
    const right_group = if (right_target) |target| groupOfState(group_of, target) else null;
    std.debug.print(
        "[minimize-state] reason={s} left_state={d} right_state={d} symbol={s}:{d} left_target={?d} right_target={?d} left_group={?d} right_group={?d}\n",
        .{
            reason,
            left_state_id,
            right_state_id,
            @tagName(symbol),
            switch (symbol) {
                .end => 0,
                .terminal => |idx| idx,
                .external => |idx| idx,
                .non_terminal => |idx| idx,
            },
            left_target,
            right_target,
            left_group,
            right_group,
        },
    );
}

fn tracePairMatches(left_state_id: state.StateId, right_state_id: state.StateId) bool {
    for (pair_detail_pairs[0..pair_detail_count]) |pair| {
        if ((pair.left == left_state_id and pair.right == right_state_id) or
            (pair.left == right_state_id and pair.right == left_state_id))
        {
            return true;
        }
    }
    return false;
}

fn traceConflictPair(left_state_id: state.StateId, right_state_id: state.StateId) void {
    if (conflict_pair_detail_remaining == 0) return;
    conflict_pair_detail_remaining -= 1;
    std.debug.print("[minimize-conflict-pair] left_state={d} right_state={d}\n", .{ left_state_id, right_state_id });
}

fn traceActionGroupDiff(
    reason: []const u8,
    left_state_id: state.StateId,
    right_state_id: state.StateId,
    left: resolution.ResolvedActionGroup,
    right: resolution.ResolvedActionGroup,
    reduce_productions: ?[]const UnitReductionProduction,
    group_of: []const u32,
) void {
    if (action_detail_remaining != 0) {
        action_detail_remaining -= 1;
    } else if (pair_detail_remaining != 0 and tracePairMatches(left_state_id, right_state_id)) {
        pair_detail_remaining -= 1;
    } else {
        return;
    }
    std.debug.print(
        "[minimize-action] reason={s} left_state={d} right_state={d} symbol={s}:{d} left_decision={s} right_decision={s} left_candidates={d} right_candidates={d}\n",
        .{
            reason,
            left_state_id,
            right_state_id,
            @tagName(left.symbol),
            switch (left.symbol) {
                .end => 0,
                .terminal => |idx| idx,
                .external => |idx| idx,
                .non_terminal => |idx| idx,
            },
            @tagName(left.decision),
            @tagName(right.decision),
            left.candidate_actions.len,
            right.candidate_actions.len,
        },
    );
    traceActionGroupActions("left", left, reduce_productions, group_of);
    traceActionGroupActions("right", right, reduce_productions, group_of);
}

fn traceActionGroupActions(
    label: []const u8,
    group: resolution.ResolvedActionGroup,
    reduce_productions: ?[]const UnitReductionProduction,
    group_of: []const u32,
) void {
    switch (group.decision) {
        .chosen => |action| {
            std.debug.print("  {s} chosen:", .{label});
            traceActionInline(action, reduce_productions, group_of);
        },
        .unresolved => |reason| {
            std.debug.print("  {s} unresolved={s}\n", .{ label, @tagName(reason) });
            for (group.candidate_actions, 0..) |action, index| {
                std.debug.print("  {s} candidate[{d}]:", .{ label, index });
                traceActionInline(action, reduce_productions, group_of);
            }
        },
    }
}

fn traceActionInline(
    action: actions.ParseAction,
    reduce_productions: ?[]const UnitReductionProduction,
    group_of: []const u32,
) void {
    switch (action) {
        .shift => |target| std.debug.print(" shift target={d} group={d}\n", .{ target, groupOfState(group_of, target) }),
        .shift_extra => std.debug.print(" shift_extra\n", .{}),
        .accept => std.debug.print(" accept\n", .{}),
        .reduce => |production_id| {
            std.debug.print(" reduce production={d}", .{production_id});
            if (reduce_productions) |productions| {
                if (production_id < productions.len) {
                    const info = productions[production_id];
                    std.debug.print(
                        " lhs={d} child_count={d} dynamic_precedence={d} metadata_empty={} production_info_id={?d}",
                        .{ info.lhs, info.child_count, info.dynamic_precedence, info.metadata_empty, info.production_info_id },
                    );
                }
            }
            std.debug.print("\n", .{});
        },
    }
}

fn recordTokenConflictTrace(left: usize, right: usize) void {
    token_trace_total += 1;
    if (left >= token_trace_max or right >= token_trace_max) return;
    token_trace_counts[left * token_trace_max + right] += 1;
}

fn printTokenConflictTrace(conflict_map: ?TerminalConflictMap) void {
    const map = conflict_map orelse {
        std.debug.print("[minimize-token-trace] total=0 no terminal conflict map\n", .{});
        return;
    };
    std.debug.print("[minimize-token-trace] total={d} top_pairs:\n", .{token_trace_total});
    var emitted: usize = 0;
    while (emitted < 20) : (emitted += 1) {
        var best_count: u64 = 0;
        var best_left: usize = 0;
        var best_right: usize = 0;
        for (0..@min(map.terminal_count, token_trace_max)) |left| {
            for (0..@min(map.terminal_count, token_trace_max)) |right| {
                const count = token_trace_counts[left * token_trace_max + right];
                if (count <= best_count) continue;
                best_count = count;
                best_left = left;
                best_right = right;
            }
        }
        if (best_count == 0) break;
        std.debug.print(
            "  {d}: {d}({s}) vs {d}({s}) count={d}\n",
            .{
                emitted + 1,
                best_left,
                map.tokenName(best_left),
                best_right,
                map.tokenName(best_right),
                best_count,
            },
        );
        token_trace_counts[best_left * token_trace_max + best_right] = 0;
    }
}

pub fn minimizeAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
) std.mem.Allocator.Error!MinimizeResult {
    return try minimizeAllocWithOptions(
        allocator,
        states_in,
        resolved_in,
        terminal_conflicts,
        word_token,
        null,
    );
}

pub fn minimizeAllocWithOptions(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
    unit_reductions: ?UnitReductionOptions,
) std.mem.Allocator.Error!MinimizeResult {
    const n = states_in.len;
    if (n == 0) {
        return .{
            .states = try allocator.alloc(state.ParseState, 0),
            .resolved_actions = .{ .states = try allocator.alloc(resolution.ResolvedStateActions, 0) },
            .merged_count = 0,
        };
    }

    var max_id: state.StateId = 0;
    var max_core_id: u32 = 0;
    for (states_in) |s| if (s.id > max_id) {
        max_id = s.id;
    };
    for (states_in) |s| if (s.core_id > max_core_id) {
        max_core_id = s.core_id;
    };

    const id_to_idx = try allocator.alloc(usize, max_id + 1);
    defer allocator.free(id_to_idx);
    @memset(id_to_idx, std.math.maxInt(usize));
    for (states_in, 0..) |s, idx| id_to_idx[s.id] = idx;

    var groups = std.array_list.Managed([]usize).init(allocator);
    defer {
        for (groups.items) |group| allocator.free(group);
        groups.deinit();
    }
    const grouped_by_core = try allocator.alloc(std.array_list.Managed(usize), max_core_id + 1);
    defer {
        for (grouped_by_core) |*group| group.deinit();
        allocator.free(grouped_by_core);
    }
    for (grouped_by_core) |*group| group.* = std.array_list.Managed(usize).init(allocator);
    for (states_in, 0..) |s, idx| {
        try grouped_by_core[s.core_id].append(idx);
    }
    for (grouped_by_core) |group| {
        if (group.items.len == 0) continue;
        try groups.append(try allocator.dupe(usize, group.items));
    }
    const trace_minimizer = traceMinimizerEnabled();
    const trace_token_conflicts = traceTokenConflictsEnabled();
    const effective_terminal_conflicts = if (ignoreTokenConflictsForMinimizer()) null else terminal_conflicts;
    token_trace_active = trace_token_conflicts;
    minimize_trace_stats_active = trace_minimizer;
    loadIgnoredTokenConflictPairs();
    loadIgnoredSuccessorTokens();
    loadSuccessorDetailTrace();
    loadStateDetailTrace();
    loadActionDetailTrace();
    loadConflictPairTrace();
    loadPairDetailTrace();
    loadReferenceDetailTrace();
    defer {
        token_trace_active = false;
        minimize_trace_stats_active = false;
        token_ignore_pairs_active = false;
        successor_ignore_tokens_active = false;
        successor_detail_token = null;
        successor_detail_remaining = 0;
        state_detail_id = null;
        state_detail_remaining = 0;
        action_detail_remaining = 0;
        conflict_pair_detail_remaining = 0;
        pair_detail_count = 0;
        pair_detail_remaining = 0;
        reference_detail_count = 0;
    }
    if (trace_minimizer) resetMinimizeTraceStats();
    if (trace_token_conflicts) resetTokenConflictTrace();
    if (trace_minimizer) {
        std.debug.print("[minimize] initial core groups={d} states={d}\n", .{ groups.items.len, states_in.len });
    }

    const group_of = try allocator.alloc(u32, max_id + 1);
    defer allocator.free(group_of);
    refreshGroupIds(states_in, groups.items, group_of);

    const conflict_changed = try splitConflictGroups(
        allocator,
        states_in,
        resolved_in,
        effective_terminal_conflicts,
        word_token,
        unit_reductions,
        &groups,
        group_of,
    );
    if (trace_minimizer) {
        std.debug.print("[minimize] after conflicts changed={} groups={d}\n", .{ conflict_changed, groups.items.len });
        printMinimizeTraceStats(effective_terminal_conflicts);
    }
    if (trace_token_conflicts) printTokenConflictTrace(effective_terminal_conflicts);
    var successor_iteration: usize = 0;
    while (try splitSuccessorGroups(
        allocator,
        states_in,
        resolved_in,
        &groups,
        group_of,
    )) {
        successor_iteration += 1;
        if (trace_minimizer) {
            std.debug.print("[minimize] after successor iteration {d} groups={d}\n", .{ successor_iteration, groups.items.len });
        }
    }
    if (trace_minimizer) {
        std.debug.print("[minimize] final compatible groups={d} successor_iterations={d}\n", .{ groups.items.len, successor_iteration });
        printMinimizeTraceStats(effective_terminal_conflicts);
    }

    if (groups.items.len > 1) {
        moveGroupContainingState(states_in, groups.items, 0, 0);
        moveGroupContainingState(states_in, groups.items, 1, 1);
        refreshGroupIds(states_in, groups.items, group_of);
    }

    const id_remap = try allocator.alloc(state.StateId, max_id + 1);
    defer allocator.free(id_remap);
    @memset(id_remap, std.math.maxInt(state.StateId));
    for (groups.items, 0..) |group, new_id| {
        for (group) |state_index| {
            id_remap[states_in[state_index].id] = @intCast(new_id);
        }
    }

    const out_states = try allocator.alloc(state.ParseState, groups.items.len);
    for (groups.items, 0..) |group, new_id| {
        const base = states_in[group[0]];
        var transitions = std.array_list.Managed(state.Transition).init(allocator);
        for (group) |state_index| {
            for (states_in[state_index].transitions) |transition| {
                try appendOrReplaceMergedTransition(&transitions, .{
                    .symbol = transition.symbol,
                    .state = id_remap[transition.state],
                    .extra = transition.extra,
                });
            }
        }
        const reserved_word_set_id = try mergedReservedWordSetIdForGroupAlloc(
            allocator,
            group,
            states_in,
            resolved_in,
            terminal_conflicts,
        );

        out_states[new_id] = .{
            .id = @intCast(new_id),
            .core_id = base.core_id,
            .lex_state_id = base.lex_state_id,
            .reserved_word_set_id = reserved_word_set_id,
            .items = base.items,
            .transitions = try transitions.toOwnedSlice(),
            .conflicts = base.conflicts,
            .auxiliary_symbols = base.auxiliary_symbols,
        };
    }

    const out_resolved = try allocator.alloc(resolution.ResolvedStateActions, groups.items.len);
    for (groups.items, 0..) |group, new_id| {
        var action_groups = std.array_list.Managed(resolution.ResolvedActionGroup).init(allocator);
        for (group) |state_index| {
            const old_state_id = states_in[state_index].id;
            for (resolved_in.groupsForState(old_state_id)) |action_group| {
                const remapped = try remapResolvedActionGroup(allocator, action_group, id_remap);
                if (findResolvedGroupIndex(action_groups.items, remapped.symbol)) |existing_index| {
                    freeResolvedActionGroup(allocator, action_groups.items[existing_index]);
                    action_groups.items[existing_index] = remapped;
                } else {
                    try action_groups.append(remapped);
                }
            }
        }

        out_resolved[new_id] = .{
            .state_id = @intCast(new_id),
            .groups = try action_groups.toOwnedSlice(),
        };
    }

    var final_states = out_states;
    var final_resolved = resolution.ResolvedActionTable{ .states = out_resolved };
    if (unit_reductions) |options| {
        const reduced = try removeUnitReductionsAndUnusedAlloc(
            allocator,
            final_states,
            final_resolved,
            options,
        );
        deinitOwnedStateSlices(allocator, final_states);
        allocator.free(final_states);
        deinitOwnedResolvedTable(allocator, final_resolved);
        final_states = reduced.states;
        final_resolved = reduced.resolved_actions;
    }

    return .{
        .states = final_states,
        .resolved_actions = final_resolved,
        .merged_count = n - final_states.len,
    };
}

pub fn compactUnitReductionsAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
    options: UnitReductionOptions,
) std.mem.Allocator.Error!MinimizeResult {
    return try removeUnitReductionsAndUnusedAlloc(allocator, states_in, resolved_in, options);
}

fn deinitOwnedStateSlices(allocator: std.mem.Allocator, states: []const state.ParseState) void {
    for (states) |parse_state| {
        if (parse_state.transitions.len != 0) allocator.free(parse_state.transitions);
    }
}

fn deinitOwnedResolvedTable(allocator: std.mem.Allocator, resolved: resolution.ResolvedActionTable) void {
    for (resolved.states) |resolved_state| {
        for (resolved_state.groups) |group| {
            if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
        }
        if (resolved_state.groups.len != 0) allocator.free(resolved_state.groups);
    }
    if (resolved.states.len != 0) allocator.free(resolved.states);
}

fn removeUnitReductionsAndUnusedAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
    options: UnitReductionOptions,
) std.mem.Allocator.Error!MinimizeResult {
    const unit_symbols = try unitReductionSymbolsByStateAlloc(allocator, states_in, resolved_in, options);
    defer allocator.free(unit_symbols);
    if (traceMinimizerEnabled()) {
        var count: usize = 0;
        for (unit_symbols) |unit_symbol| {
            if (unit_symbol != null) count += 1;
        }
        std.debug.print("[minimize] unit_reduction candidates={d} states={d}\n", .{ count, states_in.len });
        if (envFlagEnabled("GEN_Z_SITTER_MINIMIZER_TRACE_UNIT_STATES")) {
            std.debug.print("[minimize-unit-states]", .{});
            for (unit_symbols, 0..) |unit_symbol, state_id| {
                if (unit_symbol != null) std.debug.print(" {d}", .{state_id});
            }
            std.debug.print("\n", .{});
        }
    }

    const rewritten_states = try rewriteUnitReductionReferencesAlloc(allocator, states_in, resolved_in, unit_symbols);
    errdefer {
        deinitOwnedStateSlices(allocator, rewritten_states.states);
        allocator.free(rewritten_states.states);
        deinitOwnedResolvedTable(allocator, rewritten_states.resolved_actions);
    }

    const compacted = try removeUnusedStatesAlloc(
        allocator,
        rewritten_states.states,
        rewritten_states.resolved_actions,
    );
    if (traceMinimizerEnabled()) {
        std.debug.print(
            "[minimize] unit_reduction compacted states={d} removed={d}\n",
            .{ compacted.states.len, states_in.len - compacted.states.len },
        );
    }
    deinitOwnedStateSlices(allocator, rewritten_states.states);
    allocator.free(rewritten_states.states);
    deinitOwnedResolvedTable(allocator, rewritten_states.resolved_actions);
    errdefer {
        deinitOwnedStateSlices(allocator, compacted.states);
        allocator.free(compacted.states);
        deinitOwnedResolvedTable(allocator, compacted.resolved_actions);
    }

    const reordered = try reorderStatesByDescendingSizeAlloc(
        allocator,
        compacted.states,
        compacted.resolved_actions,
    );
    deinitOwnedStateSlices(allocator, compacted.states);
    allocator.free(compacted.states);
    deinitOwnedResolvedTable(allocator, compacted.resolved_actions);
    return reordered;
}

fn unitReductionSymbolsByStateAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved: resolution.ResolvedActionTable,
    options: UnitReductionOptions,
) std.mem.Allocator.Error![]?syntax_ir.SymbolRef {
    var max_id: state.StateId = 0;
    for (states_in) |parse_state| max_id = @max(max_id, parse_state.id);

    const result = try allocator.alloc(?syntax_ir.SymbolRef, max_id + 1);
    @memset(result, null);

    var reject_stats = UnitReductionRejectStats{};
    for (states_in) |parse_state| {
        var only_unit_reductions = true;
        var unit_symbol: ?syntax_ir.SymbolRef = null;

        for (resolved.groupsForState(parse_state.id)) |group| {
            if (group.symbol == .non_terminal) continue;
            const action_count: usize = switch (group.decision) {
                .chosen => 1,
                .unresolved => group.candidate_actions.len,
            };
            if (action_count == 0) {
                reject_stats.empty_action_groups += 1;
                only_unit_reductions = false;
                break;
            }

            var action_index: usize = 0;
            while (action_index < action_count) : (action_index += 1) {
                const action = switch (group.decision) {
                    .chosen => |chosen| chosen,
                    .unresolved => group.candidate_actions[action_index],
                };

                switch (action) {
                    .shift_extra => continue,
                    .shift => {
                        reject_stats.shift += 1;
                        only_unit_reductions = false;
                    },
                    .accept => {
                        reject_stats.accept += 1;
                        only_unit_reductions = false;
                    },
                    .reduce => |production_id| {
                        const symbol = unitReductionSymbolForProductionWithStats(options, production_id, &reject_stats) orelse {
                            only_unit_reductions = false;
                            break;
                        };
                        if (unit_symbol) |existing| {
                            if (!symbolRefEql(existing, symbol)) {
                                reject_stats.multiple_symbols += 1;
                                only_unit_reductions = false;
                                break;
                            }
                        } else {
                            unit_symbol = symbol;
                        }
                    },
                }
                if (!only_unit_reductions) break;
            }
            if (!only_unit_reductions) break;
        }

        if (only_unit_reductions) {
            if (unit_symbol) |symbol| {
                result[parse_state.id] = symbol;
                reject_stats.candidates += 1;
            } else {
                reject_stats.no_unit_symbol += 1;
            }
        }
    }

    if (traceMinimizerEnabled()) {
        std.debug.print(
            "[minimize] unit_reduction reject candidates={d} empty_actions={d} shift={d} accept={d} non_unit_reduce={d} non_empty_metadata={d} filtered_symbol={d} multiple_symbols={d} no_unit_symbol={d}\n",
            .{
                reject_stats.candidates,
                reject_stats.empty_action_groups,
                reject_stats.shift,
                reject_stats.accept,
                reject_stats.non_unit_reduce,
                reject_stats.non_empty_metadata,
                reject_stats.filtered_symbol,
                reject_stats.multiple_symbols,
                reject_stats.no_unit_symbol,
            },
        );
    }

    return result;
}

fn unitReductionSymbolForProduction(
    options: UnitReductionOptions,
    production_id: item.ProductionId,
) ?syntax_ir.SymbolRef {
    return unitReductionSymbolForProductionWithStats(options, production_id, null);
}

fn unitReductionSymbolForProductionWithStats(
    options: UnitReductionOptions,
    production_id: item.ProductionId,
    reject_stats: ?*UnitReductionRejectStats,
) ?syntax_ir.SymbolRef {
    if (production_id >= options.productions.len) return null;
    const production = options.productions[production_id];
    if (production.child_count != 1) {
        if (reject_stats) |stats| stats.non_unit_reduce += 1;
        return null;
    }
    if (relaxUnitReductionForDiagnostics()) return .{ .non_terminal = production.lhs };
    if (production.production_info_id) |production_info_id| {
        if (production_info_id != 0) {
            if (reject_stats) |stats| stats.non_empty_metadata += 1;
            return null;
        }
    } else if (!production.metadata_empty) {
        if (reject_stats) |stats| stats.non_empty_metadata += 1;
        return null;
    }
    if (production.lhs >= options.symbols.len) {
        if (reject_stats) |stats| stats.filtered_symbol += 1;
        return null;
    }

    const symbol_info = options.symbols[production.lhs];
    if (symbol_info.kind == .named or
        symbol_info.simple_alias or
        symbol_info.supertype or
        symbol_info.extra or
        symbol_info.aliased)
    {
        if (reject_stats) |stats| stats.filtered_symbol += 1;
        return null;
    }
    return .{ .non_terminal = production.lhs };
}

fn rewriteUnitReductionReferencesAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
    unit_symbols: []const ?syntax_ir.SymbolRef,
) std.mem.Allocator.Error!MinimizeResult {
    const states = try allocator.alloc(state.ParseState, states_in.len);
    var states_initialized: usize = 0;
    errdefer {
        for (states[0..states_initialized]) |parse_state| {
            if (parse_state.transitions.len != 0) allocator.free(parse_state.transitions);
        }
        allocator.free(states);
    }

    for (states_in, 0..) |parse_state, index| {
        states[index] = parse_state;
        states[index].transitions = try allocator.dupe(state.Transition, parse_state.transitions);
        states_initialized += 1;
    }

    const resolved_states = try allocator.alloc(resolution.ResolvedStateActions, resolved_in.states.len);
    var resolved_initialized: usize = 0;
    errdefer {
        for (resolved_states[0..resolved_initialized]) |resolved_state| {
            for (resolved_state.groups) |group| {
                if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
            }
            if (resolved_state.groups.len != 0) allocator.free(resolved_state.groups);
        }
        allocator.free(resolved_states);
    }
    for (resolved_in.states, 0..) |resolved_state, index| {
        resolved_states[index] = .{
            .state_id = resolved_state.state_id,
            .groups = try cloneResolvedGroups(allocator, resolved_state.groups),
        };
        resolved_initialized += 1;
    }

    for (states) |*parse_state| {
        const groups = groupsForMutableState(resolved_states, parse_state.id);
        var changed = true;
        while (changed) {
            changed = false;
            for (@constCast(parse_state.transitions)) |*transition| {
                const replacement = unitReductionReplacement(parse_state.transitions, transition.state, unit_symbols) orelse continue;
                if (replacement == transition.state) continue;
                transition.state = replacement;
                changed = true;
            }
            for (groups) |*group| {
                if (rewriteGroupUnitReductionReferences(parse_state.transitions, group, unit_symbols)) {
                    changed = true;
                }
            }
        }
    }

    return .{
        .states = states,
        .resolved_actions = .{ .states = resolved_states },
        .merged_count = 0,
    };
}

fn groupsForMutableState(
    resolved_states: []resolution.ResolvedStateActions,
    state_id: state.StateId,
) []resolution.ResolvedActionGroup {
    for (resolved_states) |*resolved_state| {
        if (resolved_state.state_id == state_id) return @constCast(resolved_state.groups);
    }
    return &.{};
}

fn cloneResolvedGroups(
    allocator: std.mem.Allocator,
    groups: []const resolution.ResolvedActionGroup,
) std.mem.Allocator.Error![]const resolution.ResolvedActionGroup {
    if (groups.len == 0) return &.{};
    const cloned = try allocator.alloc(resolution.ResolvedActionGroup, groups.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |group| {
            if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
        }
        allocator.free(cloned);
    }
    for (groups, 0..) |group, index| {
        cloned[index] = group;
        cloned[index].candidate_actions = if (group.candidate_actions.len == 0)
            &.{}
        else
            try allocator.dupe(actions.ParseAction, group.candidate_actions);
        initialized += 1;
    }
    return cloned;
}

fn unitReductionReplacement(
    transitions: []const state.Transition,
    target: state.StateId,
    unit_symbols: []const ?syntax_ir.SymbolRef,
) ?state.StateId {
    if (target >= unit_symbols.len) return null;
    const unit_symbol = unit_symbols[target] orelse return null;
    const goto = findTransition(transitions, unit_symbol) orelse return null;
    return goto.state;
}

fn rewriteGroupUnitReductionReferences(
    transitions: []const state.Transition,
    group: *resolution.ResolvedActionGroup,
    unit_symbols: []const ?syntax_ir.SymbolRef,
) bool {
    var changed = false;
    switch (group.decision) {
        .chosen => |action| {
            var mutable_action = action;
            if (rewriteActionUnitReductionReference(transitions, &mutable_action, unit_symbols)) {
                group.decision = .{ .chosen = mutable_action };
                changed = true;
            }
        },
        .unresolved => {
            const candidates = @constCast(group.candidate_actions);
            for (candidates) |*candidate| {
                changed = rewriteActionUnitReductionReference(transitions, candidate, unit_symbols) or changed;
            }
        },
    }
    return changed;
}

fn rewriteActionUnitReductionReference(
    transitions: []const state.Transition,
    action: *actions.ParseAction,
    unit_symbols: []const ?syntax_ir.SymbolRef,
) bool {
    switch (action.*) {
        .shift => |target| {
            const replacement = unitReductionReplacement(transitions, target, unit_symbols) orelse return false;
            if (replacement == target) return false;
            action.* = .{ .shift = replacement };
            return true;
        },
        else => return false,
    }
}

fn removeUnusedStatesAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
) std.mem.Allocator.Error!MinimizeResult {
    if (states_in.len == 0) {
        return .{
            .states = try allocator.alloc(state.ParseState, 0),
            .resolved_actions = .{ .states = try allocator.alloc(resolution.ResolvedStateActions, 0) },
            .merged_count = 0,
        };
    }

    var max_id: state.StateId = 0;
    for (states_in) |parse_state| max_id = @max(max_id, parse_state.id);

    const used = try allocator.alloc(bool, max_id + 1);
    defer allocator.free(used);
    @memset(used, false);
    if (used.len != 0) used[0] = true;
    if (used.len > 1) used[1] = true;

    for (states_in) |parse_state| {
        for (parse_state.transitions) |transition| {
            if (transition.symbol != .non_terminal) continue;
            if (transition.state < used.len) {
                if (traceReferenceTargetMatches(transition.state)) {
                    std.debug.print(
                        "[minimize-reference] owner={d} kind=transition symbol={s}:{d} target={d}\n",
                        .{
                            parse_state.id,
                            @tagName(transition.symbol),
                            switch (transition.symbol) {
                                .end => 0,
                                .terminal => |idx| idx,
                                .external => |idx| idx,
                                .non_terminal => |idx| idx,
                            },
                            transition.state,
                        },
                    );
                }
                used[transition.state] = true;
            }
        }
        for (resolved_in.groupsForState(parse_state.id)) |group| {
            markActionGroupReferences(parse_state.id, group, used);
        }
    }

    const id_remap = try allocator.alloc(state.StateId, max_id + 1);
    defer allocator.free(id_remap);
    @memset(id_remap, std.math.maxInt(state.StateId));
    var used_count: usize = 0;
    for (states_in) |parse_state| {
        if (parse_state.id >= used.len or !used[parse_state.id]) continue;
        id_remap[parse_state.id] = @intCast(used_count);
        used_count += 1;
    }
    if (traceMinimizerEnabled() and envFlagEnabled("GEN_Z_SITTER_MINIMIZER_TRACE_UNUSED_STATES")) {
        std.debug.print("[minimize-unused-states]", .{});
        for (states_in) |parse_state| {
            if (parse_state.id < used.len and !used[parse_state.id]) {
                std.debug.print(" {d}", .{parse_state.id});
            }
        }
        std.debug.print("\n", .{});
    }

    const states = try allocator.alloc(state.ParseState, used_count);
    var states_initialized: usize = 0;
    errdefer {
        for (states[0..states_initialized]) |parse_state| {
            if (parse_state.transitions.len != 0) allocator.free(parse_state.transitions);
        }
        allocator.free(states);
    }

    const resolved_states = try allocator.alloc(resolution.ResolvedStateActions, used_count);
    var resolved_initialized: usize = 0;
    errdefer {
        for (resolved_states[0..resolved_initialized]) |resolved_state| {
            for (resolved_state.groups) |group| {
                if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
            }
            if (resolved_state.groups.len != 0) allocator.free(resolved_state.groups);
        }
        allocator.free(resolved_states);
    }

    var out_index: usize = 0;
    for (states_in) |parse_state| {
        if (parse_state.id >= used.len or !used[parse_state.id]) continue;
        states[out_index] = parse_state;
        states[out_index].id = @intCast(out_index);
        states[out_index].transitions = try remapTransitionsAlloc(allocator, parse_state.transitions, id_remap);
        states_initialized += 1;

        const source_groups = resolved_in.groupsForState(parse_state.id);
        var groups = std.array_list.Managed(resolution.ResolvedActionGroup).init(allocator);
        defer groups.deinit();
        errdefer {
            for (groups.items) |group| {
                if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
            }
        }
        for (source_groups) |group| {
            try groups.append(try remapResolvedActionGroup(allocator, group, id_remap));
        }
        resolved_states[out_index] = .{
            .state_id = @intCast(out_index),
            .groups = try groups.toOwnedSlice(),
        };
        resolved_initialized += 1;
        out_index += 1;
    }

    return .{
        .states = states,
        .resolved_actions = .{ .states = resolved_states },
        .merged_count = states_in.len - used_count,
    };
}

fn reorderStatesByDescendingSizeAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
) std.mem.Allocator.Error!MinimizeResult {
    if (states_in.len == 0) {
        return .{
            .states = try allocator.alloc(state.ParseState, 0),
            .resolved_actions = .{ .states = try allocator.alloc(resolution.ResolvedStateActions, 0) },
            .merged_count = 0,
        };
    }

    var max_id: state.StateId = 0;
    for (states_in) |parse_state| max_id = @max(max_id, parse_state.id);

    const id_to_idx = try allocator.alloc(usize, max_id + 1);
    defer allocator.free(id_to_idx);
    @memset(id_to_idx, std.math.maxInt(usize));
    for (states_in, 0..) |parse_state, index| {
        if (parse_state.id < id_to_idx.len) id_to_idx[parse_state.id] = index;
    }

    const old_ids_by_new_id = try allocator.alloc(usize, states_in.len);
    defer allocator.free(old_ids_by_new_id);
    for (old_ids_by_new_id, 0..) |*old_id, index| old_id.* = index;
    std.mem.sort(usize, old_ids_by_new_id, ReorderStateContext{
        .states = states_in,
        .resolved = resolved_in,
    }, lessThanReorderedState);

    const id_remap = try allocator.alloc(state.StateId, max_id + 1);
    defer allocator.free(id_remap);
    @memset(id_remap, std.math.maxInt(state.StateId));
    for (old_ids_by_new_id, 0..) |old_index, new_id| {
        const old_state_id = states_in[old_index].id;
        if (old_state_id < id_remap.len) id_remap[old_state_id] = @intCast(new_id);
    }

    const states = try allocator.alloc(state.ParseState, states_in.len);
    var states_initialized: usize = 0;
    errdefer {
        for (states[0..states_initialized]) |parse_state| {
            if (parse_state.transitions.len != 0) allocator.free(parse_state.transitions);
        }
        allocator.free(states);
    }

    const resolved_states = try allocator.alloc(resolution.ResolvedStateActions, states_in.len);
    var resolved_initialized: usize = 0;
    errdefer {
        for (resolved_states[0..resolved_initialized]) |resolved_state| {
            for (resolved_state.groups) |group| {
                if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
            }
            if (resolved_state.groups.len != 0) allocator.free(resolved_state.groups);
        }
        allocator.free(resolved_states);
    }

    for (old_ids_by_new_id, 0..) |old_index, new_id| {
        const parse_state = states_in[old_index];
        states[new_id] = parse_state;
        states[new_id].id = @intCast(new_id);
        states[new_id].transitions = try remapTransitionsAlloc(allocator, parse_state.transitions, id_remap);
        states_initialized += 1;

        const source_groups = resolved_in.groupsForState(parse_state.id);
        var groups = std.array_list.Managed(resolution.ResolvedActionGroup).init(allocator);
        defer groups.deinit();
        errdefer {
            for (groups.items) |group| {
                if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
            }
        }
        for (source_groups) |group| {
            try groups.append(try remapResolvedActionGroup(allocator, group, id_remap));
        }
        resolved_states[new_id] = .{
            .state_id = @intCast(new_id),
            .groups = try groups.toOwnedSlice(),
        };
        resolved_initialized += 1;
    }

    return .{
        .states = states,
        .resolved_actions = .{ .states = resolved_states },
        .merged_count = 0,
    };
}

fn lessThanReorderedState(
    context: ReorderStateContext,
    left_index: usize,
    right_index: usize,
) bool {
    const left_id = context.states[left_index].id;
    const right_id = context.states[right_index].id;
    if (left_id <= 1 or right_id <= 1) {
        if (left_id <= 1 and right_id <= 1) return left_id < right_id;
        return left_id <= 1;
    }

    const left_size = parseStateEntryCount(context.states[left_index], context.resolved);
    const right_size = parseStateEntryCount(context.states[right_index], context.resolved);
    if (left_size != right_size) return left_size > right_size;
    return false;
}

fn parseStateEntryCount(parse_state: state.ParseState, resolved: resolution.ResolvedActionTable) usize {
    var terminal_count: usize = 0;
    for (resolved.groupsForState(parse_state.id)) |group| {
        if (group.symbol != .non_terminal) terminal_count += 1;
    }
    var nonterminal_count: usize = 0;
    for (parse_state.transitions) |transition| {
        if (transition.symbol == .non_terminal) nonterminal_count += 1;
    }
    return terminal_count + nonterminal_count;
}

fn markActionGroupReferences(owner_state: state.StateId, group: resolution.ResolvedActionGroup, used: []bool) void {
    switch (group.decision) {
        .chosen => |action| markActionReference(owner_state, group.symbol, action, used),
        .unresolved => {
            for (group.candidate_actions) |action| markActionReference(owner_state, group.symbol, action, used);
        },
    }
}

fn markActionReference(owner_state: state.StateId, symbol: syntax_ir.SymbolRef, action: actions.ParseAction, used: []bool) void {
    switch (action) {
        .shift => |target| if (target < used.len) {
            if (traceReferenceTargetMatches(target)) {
                std.debug.print(
                    "[minimize-reference] owner={d} kind=action symbol={s}:{d} target={d}\n",
                    .{
                        owner_state,
                        @tagName(symbol),
                        switch (symbol) {
                            .end => 0,
                            .terminal => |idx| idx,
                            .external => |idx| idx,
                            .non_terminal => |idx| idx,
                        },
                        target,
                    },
                );
            }
            used[target] = true;
        },
        else => {},
    }
}

fn remapTransitionsAlloc(
    allocator: std.mem.Allocator,
    transitions: []const state.Transition,
    id_remap: []const state.StateId,
) std.mem.Allocator.Error![]const state.Transition {
    if (transitions.len == 0) return &.{};
    var result = std.array_list.Managed(state.Transition).init(allocator);
    defer result.deinit();
    for (transitions) |transition| {
        if (transition.state >= id_remap.len) continue;
        const mapped = id_remap[transition.state];
        if (mapped == std.math.maxInt(state.StateId)) continue;
        try appendMergedTransition(&result, .{
            .symbol = transition.symbol,
            .state = mapped,
            .extra = transition.extra,
        });
    }
    return try result.toOwnedSlice();
}

fn refreshGroupIds(
    states_in: []const state.ParseState,
    groups: []const []const usize,
    group_of: []u32,
) void {
    @memset(group_of, std.math.maxInt(u32));
    for (groups, 0..) |group, group_index| {
        for (group) |state_index| {
            group_of[states_in[state_index].id] = @intCast(group_index);
        }
    }
}

fn moveGroupContainingState(
    states_in: []const state.ParseState,
    groups: [][]usize,
    state_id: state.StateId,
    target_index: usize,
) void {
    if (target_index >= groups.len) return;
    for (groups, 0..) |group, index| {
        for (group) |state_index| {
            if (states_in[state_index].id != state_id) continue;
            if (state_id != 0 and groupContainsState(states_in, group, 0)) return;
            if (index != target_index) std.mem.swap([]usize, &groups[target_index], &groups[index]);
            return;
        }
    }
}

fn groupContainsState(states_in: []const state.ParseState, group: []const usize, state_id: state.StateId) bool {
    for (group) |state_index| {
        if (states_in[state_index].id == state_id) return true;
    }
    return false;
}

fn splitConflictGroups(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved: resolution.ResolvedActionTable,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
    unit_reductions: ?UnitReductionOptions,
    groups: *std.array_list.Managed([]usize),
    group_of: []u32,
) std.mem.Allocator.Error!bool {
    var is_split = try allocator.alloc(bool, states_in.len);
    defer allocator.free(is_split);
    @memset(is_split, false);

    var changed = false;
    var group_index: usize = 0;
    while (group_index < groups.items.len) : (group_index += 1) {
        const group = groups.items[group_index];
        if (group.len <= 1) continue;

        var split_state_indices = std.array_list.Managed(usize).init(allocator);
        defer split_state_indices.deinit();

        var i: usize = 0;
        while (i < group.len) : (i += 1) {
            const left_index = group[i];
            if (is_split[left_index]) continue;

            var j = i + 1;
            while (j < group.len) : (j += 1) {
                const right_index = group[j];
                if (is_split[right_index]) continue;
                if (statesConflict(
                    states_in[left_index],
                    states_in[right_index],
                    resolved,
                    terminal_conflicts,
                    word_token,
                    unit_reductions,
                    group_of,
                )) {
                    try split_state_indices.append(right_index);
                    is_split[right_index] = true;
                }
            }
        }

        if (split_state_indices.items.len == 0) continue;
        changed = true;
        try splitGroupAlloc(allocator, states_in, groups, group_index, split_state_indices.items, is_split, group_of);
    }

    return changed;
}

fn splitSuccessorGroups(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    resolved: resolution.ResolvedActionTable,
    groups: *std.array_list.Managed([]usize),
    group_of: []u32,
) std.mem.Allocator.Error!bool {
    var is_split = try allocator.alloc(bool, states_in.len);
    defer allocator.free(is_split);
    @memset(is_split, false);

    var changed = false;
    var group_index: usize = 0;
    while (group_index < groups.items.len) : (group_index += 1) {
        const group = groups.items[group_index];
        if (group.len <= 1) continue;

        var split_state_indices = std.array_list.Managed(usize).init(allocator);
        defer split_state_indices.deinit();

        var i: usize = 0;
        while (i < group.len) : (i += 1) {
            const left_index = group[i];
            if (is_split[left_index]) continue;

            var j = i + 1;
            while (j < group.len) : (j += 1) {
                const right_index = group[j];
                if (is_split[right_index]) continue;
                if (successorsDiffer(
                    states_in[left_index],
                    states_in[right_index],
                    resolved,
                    group_of,
                )) {
                    try split_state_indices.append(right_index);
                    is_split[right_index] = true;
                }
            }
        }

        if (split_state_indices.items.len == 0) continue;
        changed = true;
        try splitGroupAlloc(allocator, states_in, groups, group_index, split_state_indices.items, is_split, group_of);
    }

    return changed;
}

fn splitGroupAlloc(
    allocator: std.mem.Allocator,
    states_in: []const state.ParseState,
    groups: *std.array_list.Managed([]usize),
    group_index: usize,
    split_state_indices: []const usize,
    is_split: []bool,
    group_of: []u32,
) std.mem.Allocator.Error!void {
    const group = groups.items[group_index];
    const retained = try allocator.alloc(usize, group.len - split_state_indices.len);
    errdefer allocator.free(retained);

    var retained_index: usize = 0;
    for (group) |state_index| {
        if (is_split[state_index]) continue;
        retained[retained_index] = state_index;
        retained_index += 1;
    }

    const split_slice = try allocator.dupe(usize, split_state_indices);
    errdefer allocator.free(split_slice);

    const new_group_id: u32 = @intCast(groups.items.len);
    for (split_slice) |state_index| {
        const state_id = states_in[state_index].id;
        if (state_id < group_of.len) group_of[state_id] = new_group_id;
        is_split[state_index] = false;
    }

    allocator.free(groups.items[group_index]);
    groups.items[group_index] = retained;
    try groups.append(split_slice);
}

fn statesConflict(
    left: state.ParseState,
    right: state.ParseState,
    resolved: resolution.ResolvedActionTable,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
    unit_reductions: ?UnitReductionOptions,
    group_of: []const u32,
) bool {
    const left_groups = resolved.groupsForState(left.id);
    const right_groups = resolved.groupsForState(right.id);
    for (left_groups) |left_group| {
        if (left_group.symbol == .non_terminal) continue;
        if (findResolvedGroup(right_groups, left_group.symbol)) |right_group| {
            if (entriesConflict(left.id, right.id, left_group, right_group, if (unit_reductions) |options| options.productions else null, group_of)) {
                traceConflictPair(left.id, right.id);
                return true;
            }
        } else if (tokenConflicts(left.id, right.id, left_group, right, right_groups, terminal_conflicts, word_token, unit_reductions)) {
            traceConflictPair(left.id, right.id);
            return true;
        }
    }
    for (right_groups) |right_group| {
        if (right_group.symbol == .non_terminal) continue;
        if (findResolvedGroup(left_groups, right_group.symbol) != null) continue;
        if (tokenConflicts(right.id, left.id, right_group, left, left_groups, terminal_conflicts, word_token, unit_reductions)) {
            traceConflictPair(left.id, right.id);
            return true;
        }
    }
    return false;
}

fn tokenConflicts(
    new_state_id: state.StateId,
    other_state_id: state.StateId,
    new_group: resolution.ResolvedActionGroup,
    other_state: state.ParseState,
    other_groups: []const resolution.ResolvedActionGroup,
    terminal_conflicts: ?TerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
    unit_reductions: ?UnitReductionOptions,
) bool {
    const new_token = new_group.symbol;
    switch (new_token) {
        .end => {
            if (endGroupIsNonTerminalExtraSentinel(new_group, unit_reductions)) {
                traceStateConflictDetail("nonterminal_extra_end", new_state_id, other_state_id, new_token, null, null, &.{});
                recordMinimizeTraceStat("token_conflict");
                return true;
            }
            return false;
        },
        .external => {
            traceStateConflictDetail("external_token", new_state_id, other_state_id, new_token, null, null, &.{});
            recordMinimizeTraceStat("external_token");
            return true;
        },
        .non_terminal => return false,
        .terminal => |left| {
            const conflict_map = terminal_conflicts orelse return false;
            if (reservedWordSetContains(
                conflict_map.reserved_word_sets,
                other_state.reserved_word_set_id,
                .{ .terminal = left },
            )) {
                return false;
            }
            if (conflict_map.isExternalInternal(left)) {
                traceStateConflictDetail("internal_external_token", new_state_id, other_state_id, new_token, null, null, &.{});
                recordMinimizeTraceStat("internal_external_token");
                return true;
            }
            for (other_groups) |group| {
                switch (group.symbol) {
                    .terminal => |right| {
                        const left_is_word = symbolRefEql(.{ .terminal = left }, word_token orelse .end);
                        const right_is_word = symbolRefEql(.{ .terminal = right }, word_token orelse .end);
                        if ((left_is_word and conflict_map.isKeyword(right)) or
                            (right_is_word and conflict_map.isKeyword(left)))
                        {
                            continue;
                        }
                        if (conflict_map.conflictsWith(left, right)) {
                            if (ignoredTokenConflictPair(left, right)) continue;
                            if (tokenConflictTraceActive()) recordTokenConflictTrace(left, right);
                            traceStateConflictDetail("token_conflict", new_state_id, other_state_id, new_token, null, null, &.{});
                            recordMinimizeTraceStat("token_conflict");
                            return true;
                        }
                    },
                    .external => {},
                    else => {},
                }
            }
            return false;
        },
    }
}

fn reservedWordSetContains(
    reserved_word_sets: []const []const syntax_ir.SymbolRef,
    set_id: u16,
    token: syntax_ir.SymbolRef,
) bool {
    if (set_id >= reserved_word_sets.len) return false;
    for (reserved_word_sets[set_id]) |reserved_token| {
        if (symbolRefEql(reserved_token, token)) return true;
    }
    return false;
}

fn endGroupIsNonTerminalExtraSentinel(
    group: resolution.ResolvedActionGroup,
    maybe_options: ?UnitReductionOptions,
) bool {
    const options = maybe_options orelse return false;
    const candidate_actions = switch (group.decision) {
        .chosen => |action| blk: {
            if (group.candidate_actions.len != 0) break :blk group.candidate_actions;
            return actionIsExtraReduce(action, options);
        },
        .unresolved => group.candidate_actions,
    };
    if (candidate_actions.len == 0) return false;
    var saw_reduce = false;
    for (candidate_actions) |candidate| {
        if (!actionIsExtraReduce(candidate, options)) return false;
        saw_reduce = true;
    }
    return saw_reduce;
}

fn actionIsExtraReduce(action: actions.ParseAction, options: UnitReductionOptions) bool {
    const production_id = switch (action) {
        .reduce => |id| id,
        else => return false,
    };
    if (production_id >= options.productions.len) return false;
    const lhs = options.productions[production_id].lhs;
    if (lhs >= options.symbols.len) return false;
    return options.symbols[lhs].extra;
}

fn entriesConflict(
    left_state_id: state.StateId,
    right_state_id: state.StateId,
    left: resolution.ResolvedActionGroup,
    right: resolution.ResolvedActionGroup,
    reduce_productions: ?[]const UnitReductionProduction,
    group_of: []const u32,
) bool {
    if (shiftRepetitionDiffers(left, right)) {
        traceStateConflictDetail("shift_repetition", left_state_id, right_state_id, left.symbol, null, null, group_of);
        recordMinimizeTraceStat("shift_repetition");
        return true;
    }

    var left_single: [1]actions.ParseAction = undefined;
    var right_single: [1]actions.ParseAction = undefined;
    const left_actions = effectiveActions(left, &left_single);
    const right_actions = effectiveActions(right, &right_single);
    if (actionListsEquivalent(left.symbol, left_actions, right_actions, reduce_productions, group_of)) return false;

    traceActionGroupDiff("decision", left_state_id, right_state_id, left, right, reduce_productions, group_of);
    traceStateConflictDetail(
        "decision",
        left_state_id,
        right_state_id,
        left.symbol,
        firstShiftTarget(left_actions),
        firstShiftTarget(right_actions),
        group_of,
    );
    return true;
}

fn effectiveActions(
    group: resolution.ResolvedActionGroup,
    single_buffer: *[1]actions.ParseAction,
) []const actions.ParseAction {
    return switch (group.decision) {
        .chosen => |action| blk: {
            single_buffer[0] = action;
            break :blk single_buffer[0..1];
        },
        .unresolved => group.candidate_actions,
    };
}

fn shiftRepetitionDiffers(left: resolution.ResolvedActionGroup, right: resolution.ResolvedActionGroup) bool {
    if (!groupHasShiftAction(left) or !groupHasShiftAction(right)) return false;
    return left.shift_is_repetition != right.shift_is_repetition;
}

fn groupHasShiftAction(group: resolution.ResolvedActionGroup) bool {
    switch (group.decision) {
        .chosen => |action| return action == .shift,
        .unresolved => {},
    }
    for (group.candidate_actions) |candidate| {
        if (candidate == .shift) return true;
    }
    return false;
}

fn successorsDiffer(
    left: state.ParseState,
    right: state.ParseState,
    resolved: resolution.ResolvedActionTable,
    group_of: []const u32,
) bool {
    const left_groups = resolved.groupsForState(left.id);
    const right_groups = resolved.groupsForState(right.id);
    for (left_groups) |left_group| {
        const left_target = successorShiftTarget(left_group) orelse continue;
        const right_group = findResolvedGroup(right_groups, left_group.symbol) orelse continue;
        const right_target = successorShiftTarget(right_group) orelse continue;
        if (groupOfState(group_of, left_target) != groupOfState(group_of, right_target)) {
            if (ignoredSuccessorSymbol(left_group.symbol)) continue;
            traceSuccessorDetail(
                "shift",
                left.id,
                right.id,
                left_group.symbol,
                left_target,
                right_target,
                group_of,
            );
            recordMinimizeTraceStat("successor_shift");
            recordSuccessorTraceSymbol(left_group.symbol);
            return true;
        }
    }

    for (left.transitions) |left_transition| {
        if (left_transition.symbol != .non_terminal) continue;
        const right_transition = findTransition(right.transitions, left_transition.symbol) orelse continue;
        if (left_transition.extra != right_transition.extra) {
            recordMinimizeTraceStat("successor_nonterminal");
            return true;
        }
        if (left_transition.extra) continue;
        if (groupOfState(group_of, left_transition.state) != groupOfState(group_of, right_transition.state)) {
            recordMinimizeTraceStat("successor_nonterminal");
            return true;
        }
    }
    return false;
}

fn actionsEquivalent(
    symbol: syntax_ir.SymbolRef,
    left: @import("actions.zig").ParseAction,
    right: @import("actions.zig").ParseAction,
    reduce_productions: ?[]const UnitReductionProduction,
    group_of: []const u32,
) bool {
    return switch (left) {
        .shift_extra => switch (right) {
            .shift_extra => true,
            else => blk: {
                recordMinimizeTraceStat("unequal_action");
                break :blk false;
            },
        },
        .shift => |left_state| switch (right) {
            .shift => |right_state| if (groupOfState(group_of, left_state) == groupOfState(group_of, right_state)) true else blk: {
                if (ignoredSuccessorSymbol(symbol)) break :blk true;
                traceSuccessorDetail("action", null, null, symbol, left_state, right_state, group_of);
                recordMinimizeTraceStat("action_successor");
                recordSuccessorTraceSymbol(symbol);
                break :blk false;
            },
            else => blk: {
                recordMinimizeTraceStat("unequal_action");
                break :blk false;
            },
        },
        .reduce => |left_production| switch (right) {
            .reduce => |right_production| if (reduceActionsEquivalent(left_production, right_production, reduce_productions)) true else blk: {
                recordMinimizeTraceStat("unequal_action");
                break :blk false;
            },
            else => blk: {
                recordMinimizeTraceStat("unequal_action");
                break :blk false;
            },
        },
        .accept => switch (right) {
            .accept => true,
            else => blk: {
                recordMinimizeTraceStat("unequal_action");
                break :blk false;
            },
        },
    };
}

fn reduceActionsEquivalent(
    left: item.ProductionId,
    right: item.ProductionId,
    maybe_productions: ?[]const UnitReductionProduction,
) bool {
    if (left == right) return true;
    const productions = maybe_productions orelse return false;
    if (left >= productions.len or right >= productions.len) return false;

    const left_info = productions[left];
    const right_info = productions[right];
    if (left_info.lhs != right_info.lhs) return false;
    if (left_info.child_count != right_info.child_count) return false;
    if (left_info.dynamic_precedence != right_info.dynamic_precedence) return false;
    if (left_info.production_info_id) |left_id| {
        return if (right_info.production_info_id) |right_id| left_id == right_id else false;
    }
    return false;
}

fn actionListsEquivalent(
    symbol: syntax_ir.SymbolRef,
    left: []const @import("actions.zig").ParseAction,
    right: []const @import("actions.zig").ParseAction,
    reduce_productions: ?[]const UnitReductionProduction,
    group_of: []const u32,
) bool {
    if (left.len != right.len) {
        recordMinimizeTraceStat("action_count");
        return false;
    }
    for (left, right) |left_action, right_action| {
        if (!actionsEquivalent(symbol, left_action, right_action, reduce_productions, group_of)) return false;
    }
    return true;
}

fn groupOfState(group_of: []const u32, state_id: state.StateId) u32 {
    if (state_id >= group_of.len) return std.math.maxInt(u32);
    return group_of[state_id];
}

fn chosenShiftTarget(group: resolution.ResolvedActionGroup) ?state.StateId {
    return switch (group.decision) {
        .chosen => |action| switch (action) {
            .shift => |target| target,
            else => null,
        },
        .unresolved => null,
    };
}

fn successorShiftTarget(group: resolution.ResolvedActionGroup) ?state.StateId {
    switch (group.decision) {
        .chosen => return chosenShiftTarget(group),
        .unresolved => return lastActionShiftTarget(group.candidate_actions),
    }
}

fn lastActionShiftTarget(candidate_actions: []const actions.ParseAction) ?state.StateId {
    if (candidate_actions.len == 0) return null;
    return switch (candidate_actions[candidate_actions.len - 1]) {
        .shift => |target| target,
        else => null,
    };
}

fn firstShiftTarget(candidate_actions: []const actions.ParseAction) ?state.StateId {
    for (candidate_actions) |candidate| {
        switch (candidate) {
            .shift => |target| return target,
            else => {},
        }
    }
    return null;
}

fn findResolvedGroup(
    groups: []const resolution.ResolvedActionGroup,
    symbol: syntax_ir.SymbolRef,
) ?resolution.ResolvedActionGroup {
    for (groups) |group| {
        if (symbolRefEql(group.symbol, symbol)) return group;
    }
    return null;
}

fn findResolvedGroupIndex(
    groups: []const resolution.ResolvedActionGroup,
    symbol: syntax_ir.SymbolRef,
) ?usize {
    for (groups, 0..) |group, index| {
        if (symbolRefEql(group.symbol, symbol)) return index;
    }
    return null;
}

fn findTransition(
    transitions: []const state.Transition,
    symbol: syntax_ir.SymbolRef,
) ?state.Transition {
    for (transitions) |transition| {
        if (symbolRefEql(transition.symbol, symbol)) return transition;
    }
    return null;
}

fn appendMergedTransition(
    transitions: *std.array_list.Managed(state.Transition),
    new_transition: state.Transition,
) !void {
    for (transitions.items) |existing| {
        if (symbolRefEql(existing.symbol, new_transition.symbol) and existing.extra == new_transition.extra) return;
    }
    try transitions.append(new_transition);
}

fn appendOrReplaceMergedTransition(
    transitions: *std.array_list.Managed(state.Transition),
    new_transition: state.Transition,
) !void {
    for (transitions.items) |*existing| {
        if (symbolRefEql(existing.symbol, new_transition.symbol)) {
            existing.* = new_transition;
            return;
        }
    }
    try transitions.append(new_transition);
}

fn freeResolvedActionGroup(allocator: std.mem.Allocator, group: resolution.ResolvedActionGroup) void {
    if (group.candidate_actions.len != 0) allocator.free(group.candidate_actions);
}

fn mergedReservedWordSetIdForGroupAlloc(
    allocator: std.mem.Allocator,
    group: []const usize,
    states_in: []const state.ParseState,
    resolved_in: resolution.ResolvedActionTable,
    terminal_conflicts: ?TerminalConflictMap,
) std.mem.Allocator.Error!u16 {
    const conflict_map = terminal_conflicts orelse return states_in[group[0]].reserved_word_set_id;
    if (conflict_map.reserved_word_sets.len == 0 or conflict_map.terminal_count == 0) {
        return states_in[group[0]].reserved_word_set_id;
    }

    const reserved_tokens = try allocator.alloc(bool, conflict_map.terminal_count);
    defer allocator.free(reserved_tokens);
    @memset(reserved_tokens, false);

    for (group) |state_index| {
        const reserved_word_set_id = states_in[state_index].reserved_word_set_id;
        if (reserved_word_set_id < conflict_map.reserved_word_sets.len) {
            for (conflict_map.reserved_word_sets[reserved_word_set_id]) |symbol| {
                switch (symbol) {
                    .terminal => |terminal| {
                        if (terminal < reserved_tokens.len) reserved_tokens[terminal] = true;
                    },
                    .end, .external, .non_terminal => {},
                }
            }
        }
    }

    for (group) |state_index| {
        const state_id = states_in[state_index].id;
        for (resolved_in.groupsForState(state_id)) |action_group| {
            switch (action_group.symbol) {
                .terminal => |terminal| {
                    if (terminal < reserved_tokens.len) reserved_tokens[terminal] = false;
                },
                .end, .external, .non_terminal => {},
            }
        }
    }

    return reservedWordSetIdForTokenSet(conflict_map.reserved_word_sets, reserved_tokens) orelse
        states_in[group[0]].reserved_word_set_id;
}

fn reservedWordSetIdForTokenSet(
    reserved_word_sets: []const []const syntax_ir.SymbolRef,
    token_set: []const bool,
) ?u16 {
    for (reserved_word_sets, 0..) |reserved_word_set, set_id| {
        if (reservedWordSetMatchesTokenSet(reserved_word_set, token_set)) return @intCast(set_id);
    }
    return null;
}

fn reservedWordSetMatchesTokenSet(
    reserved_word_set: []const syntax_ir.SymbolRef,
    token_set: []const bool,
) bool {
    var matched_count: usize = 0;
    for (reserved_word_set) |symbol| {
        const terminal = switch (symbol) {
            .terminal => |index| index,
            .end, .external, .non_terminal => return false,
        };
        if (terminal >= token_set.len or !token_set[terminal]) return false;
        matched_count += 1;
    }

    var token_count: usize = 0;
    for (token_set) |is_reserved| {
        if (is_reserved) token_count += 1;
    }
    return matched_count == token_count;
}

fn remapResolvedActionGroup(
    allocator: std.mem.Allocator,
    group: resolution.ResolvedActionGroup,
    id_remap: []const state.StateId,
) !resolution.ResolvedActionGroup {
    return .{
        .symbol = group.symbol,
        .candidate_actions = try remapActionsAlloc(allocator, group.candidate_actions, id_remap),
        .decision = switch (group.decision) {
            .chosen => |action| .{ .chosen = remapAction(action, id_remap) },
            .unresolved => group.decision,
        },
        .shift_is_repetition = group.shift_is_repetition,
    };
}

fn remapActionsAlloc(
    allocator: std.mem.Allocator,
    source: []const @import("actions.zig").ParseAction,
    id_remap: []const state.StateId,
) ![]const @import("actions.zig").ParseAction {
    if (source.len == 0) return &.{};
    const result = try allocator.alloc(@import("actions.zig").ParseAction, source.len);
    for (source, 0..) |action, index| {
        result[index] = remapAction(action, id_remap);
    }
    return result;
}

fn remapAction(
    action: @import("actions.zig").ParseAction,
    id_remap: []const state.StateId,
) @import("actions.zig").ParseAction {
    return switch (action) {
        .shift => |target| .{ .shift = if (target < id_remap.len) id_remap[target] else target },
        else => action,
    };
}

fn symbolRefEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
        .end => b == .end,
        .terminal => |left| switch (b) {
            .terminal => |right| left == right,
            else => false,
        },
        .external => |left| switch (b) {
            .external => |right| left == right,
            else => false,
        },
        .non_terminal => |left| switch (b) {
            .non_terminal => |right| left == right,
            else => false,
        },
    };
}

test "minimizeAlloc removes hidden unit reduction states" {
    const allocator = std.testing.allocator;

    const transitions0 = [_]state.Transition{
        .{ .symbol = .{ .terminal = 0 }, .state = 2 },
        .{ .symbol = .{ .non_terminal = 0 }, .state = 3 },
    };
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = transitions0[0..] },
        .{ .id = 1, .core_id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 2, .core_id = 2, .items = &.{}, .transitions = &.{} },
        .{ .id = 3, .core_id = 3, .items = &.{}, .transitions = &.{} },
    };

    const state0_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .terminal = 0 },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .shift = 2 } },
    }};
    const state1_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .end = {} },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .accept = {} } },
    }};
    const state2_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .end = {} },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .reduce = 0 } },
    }};
    const state3_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .end = {} },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .accept = {} } },
    }};
    const resolved_states = [_]resolution.ResolvedStateActions{
        .{ .state_id = 0, .groups = state0_groups[0..] },
        .{ .state_id = 1, .groups = state1_groups[0..] },
        .{ .state_id = 2, .groups = state2_groups[0..] },
        .{ .state_id = 3, .groups = state3_groups[0..] },
    };

    const unit_productions = [_]UnitReductionProduction{.{
        .lhs = 0,
        .child_count = 1,
        .metadata_empty = true,
        .production_info_id = 0,
    }};
    const unit_symbols = [_]UnitReductionSymbol{.{
        .kind = .hidden,
    }};

    const result = try minimizeAllocWithOptions(
        allocator,
        parse_states[0..],
        .{ .states = resolved_states[0..] },
        null,
        null,
        .{
            .productions = unit_productions[0..],
            .symbols = unit_symbols[0..],
        },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.states.len);
    const shift_group = result.resolved_actions.groupsForState(0)[0];
    try std.testing.expectEqual(actions.ParseAction{ .shift = 2 }, shift_group.chosenAction().?);
    try std.testing.expectEqual(@as(state.StateId, 2), result.states[0].transitions[0].state);
    try std.testing.expectEqual(@as(state.StateId, 2), result.states[0].transitions[1].state);
}

test "minimizeAlloc ignores diagnostic candidates for chosen actions" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .items = &.{}, .transitions = &.{} },
    };

    const state0_candidates = [_]actions.ParseAction{
        .{ .reduce = 0 },
        .{ .reduce = 1 },
    };
    const state0_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .terminal = 0 },
        .candidate_actions = state0_candidates[0..],
        .decision = .{ .chosen = .{ .reduce = 0 } },
    }};
    const state1_candidates = [_]actions.ParseAction{.{ .reduce = 0 }};
    const state1_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .terminal = 0 },
        .candidate_actions = state1_candidates[0..],
        .decision = .{ .chosen = .{ .reduce = 0 } },
    }};
    const resolved_states = [_]resolution.ResolvedStateActions{
        .{ .state_id = 0, .groups = state0_groups[0..] },
        .{ .state_id = 1, .groups = state1_groups[0..] },
    };

    const result = try minimizeAlloc(
        allocator,
        parse_states[0..],
        .{ .states = resolved_states[0..] },
        null,
        null,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
}

test "minimizeAlloc does not keep states only referenced by chosen diagnostic candidates" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 2, .core_id = 2, .items = &.{}, .transitions = &.{} },
    };

    const state0_candidates = [_]actions.ParseAction{
        .{ .shift = 2 },
        .{ .reduce = 0 },
    };
    const state0_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .terminal = 0 },
        .candidate_actions = state0_candidates[0..],
        .decision = .{ .chosen = .{ .reduce = 0 } },
    }};
    const state1_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .end = {} },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .accept = {} } },
    }};
    const state2_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .end = {} },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .accept = {} } },
    }};
    const resolved_states = [_]resolution.ResolvedStateActions{
        .{ .state_id = 0, .groups = state0_groups[0..] },
        .{ .state_id = 1, .groups = state1_groups[0..] },
        .{ .state_id = 2, .groups = state2_groups[0..] },
    };

    const result = try minimizeAllocWithOptions(
        allocator,
        parse_states[0..],
        .{ .states = resolved_states[0..] },
        null,
        null,
        .{
            .productions = &.{},
            .symbols = &.{},
        },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(state.StateId, 0), result.states[0].id);
    try std.testing.expectEqual(@as(state.StateId, 1), result.states[1].id);
}

test "minimizeAlloc compares emitted production ids for empty reduce metadata" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .items = &.{}, .transitions = &.{} },
    };

    const state0_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .terminal = 0 },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .reduce = 0 } },
    }};
    const state1_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .terminal = 0 },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .reduce = 1 } },
    }};
    const resolved_states = [_]resolution.ResolvedStateActions{
        .{ .state_id = 0, .groups = state0_groups[0..] },
        .{ .state_id = 1, .groups = state1_groups[0..] },
    };

    const reduce_productions = [_]UnitReductionProduction{
        .{ .lhs = 2, .child_count = 2, .metadata_empty = true },
        .{ .lhs = 2, .child_count = 2, .metadata_empty = true },
    };

    const result = try minimizeAllocWithOptions(
        allocator,
        parse_states[0..],
        .{ .states = resolved_states[0..] },
        null,
        null,
        .{
            .productions = reduce_productions[0..],
            .symbols = &.{},
        },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc compares compact production info ids for non-empty reduce metadata" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .items = &.{}, .transitions = &.{} },
    };

    const state0_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .terminal = 0 },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .reduce = 0 } },
    }};
    const state1_groups = [_]resolution.ResolvedActionGroup{.{
        .symbol = .{ .terminal = 0 },
        .candidate_actions = &.{},
        .decision = .{ .chosen = .{ .reduce = 1 } },
    }};
    const resolved_states = [_]resolution.ResolvedStateActions{
        .{ .state_id = 0, .groups = state0_groups[0..] },
        .{ .state_id = 1, .groups = state1_groups[0..] },
    };

    const reduce_productions = [_]UnitReductionProduction{
        .{ .lhs = 2, .child_count = 2, .metadata_empty = false, .production_info_id = 7 },
        .{ .lhs = 2, .child_count = 2, .metadata_empty = false, .production_info_id = 7 },
    };

    const result = try minimizeAllocWithOptions(
        allocator,
        parse_states[0..],
        .{ .states = resolved_states[0..] },
        null,
        null,
        .{
            .productions = reduce_productions[0..],
            .symbols = &.{},
        },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
}

fn buildSig(
    alloc: std.mem.Allocator,
    s: state.ParseState,
    resolved: resolution.ResolvedActionTable,
    class_of: []const u32,
    id_to_idx: []const usize,
) std.mem.Allocator.Error![]const u8 {
    const Entry = struct {
        sym_tag: u8,
        sym_idx: u32,
        kind: u8,
        value: u32,
    };

    var entries = std.array_list.Managed(Entry).init(alloc);
    try entries.append(.{
        .sym_tag = 253,
        .sym_idx = s.lex_state_id,
        .kind = 255,
        .value = s.lex_state_id,
    });
    try entries.append(.{
        .sym_tag = 255,
        .sym_idx = s.reserved_word_set_id,
        .kind = 255,
        .value = s.reserved_word_set_id,
    });

    for (resolved.groupsForState(s.id)) |group| {
        const sym_tag: u8 = switch (group.symbol) {
            .end => 0,
            .terminal => 1,
            .external => 2,
            .non_terminal => continue,
        };
        const sym_idx: u32 = switch (group.symbol) {
            .end => 0,
            .terminal => |idx| idx,
            .external => |idx| idx,
            .non_terminal => |idx| idx,
        };
        const kind: u8 = switch (group.decision) {
            .chosen => |action| switch (action) {
                .shift => 0,
                .reduce => 1,
                .accept => 2,
            },
            .unresolved => 3,
        };
        const value: u32 = switch (group.decision) {
            .chosen => |action| switch (action) {
                .shift => |target| class_of[id_to_idx[target]],
                .reduce => |prod| prod,
                .accept => 0,
            },
            .unresolved => |reason| @intFromEnum(reason),
        };
        try entries.append(.{ .sym_tag = sym_tag, .sym_idx = sym_idx, .kind = kind, .value = value });
    }

    for (s.transitions) |t| {
        switch (t.symbol) {
            .non_terminal => |idx| {
                try entries.append(.{
                    .sym_tag = 0,
                    .sym_idx = idx,
                    .kind = if (t.extra) 5 else 4,
                    .value = class_of[id_to_idx[t.state]],
                });
            },
            .terminal => |idx| if (t.extra) {
                try entries.append(.{
                    .sym_tag = 1,
                    .sym_idx = idx,
                    .kind = 5,
                    .value = class_of[id_to_idx[t.state]],
                });
            },
            .external => |idx| if (t.extra) {
                try entries.append(.{
                    .sym_tag = 2,
                    .sym_idx = idx,
                    .kind = 5,
                    .value = class_of[id_to_idx[t.state]],
                });
            },
            else => {},
        }
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.sym_tag != b.sym_tag) return a.sym_tag < b.sym_tag;
            if (a.sym_idx != b.sym_idx) return a.sym_idx < b.sym_idx;
            if (a.kind != b.kind) return a.kind < b.kind;
            return a.value < b.value;
        }
    }.lt);

    const bytes = try alloc.alloc(u8, entries.items.len * 10);
    var pos: usize = 0;
    for (entries.items) |e| {
        bytes[pos] = e.sym_tag;
        pos += 1;
        std.mem.writeInt(u32, bytes[pos..][0..4], e.sym_idx, .little);
        pos += 4;
        bytes[pos] = e.kind;
        pos += 1;
        std.mem.writeInt(u32, bytes[pos..][0..4], e.value, .little);
        pos += 4;
    }
    return bytes;
}

test "minimizeAlloc returns empty result for empty input" {
    const result = try minimizeAlloc(
        std.testing.allocator,
        &.{},
        .{ .states = &.{} },
        null,
        null,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc merges two identical states" {
    // States: 0 has two non-terminal gotos (to 1 and 2); 3 is an accept state.
    // States 1 and 2 both shift terminal:0 to state 3 and reduce terminal:1 to prod:1.
    // After minimization, states 1 and 2 should merge into state 1 (lower id).
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 0,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 1 },
                .{ .symbol = .{ .non_terminal = 1 }, .state = 2 },
                .{ .symbol = .{ .terminal = 0 }, .state = 3 },
            },
        },
        .{
            .id = 1,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .terminal = 0 }, .state = 3 },
            },
        },
        .{
            .id = 2,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .terminal = 0 }, .state = 3 },
            },
        },
        .{
            .id = 3,
            .items = &.{},
            .transitions = &.{},
        },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .shift = 3 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .shift = 3 } },
                    },
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 1 } },
                    },
                },
            },
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .shift = 3 } },
                    },
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 1 } },
                    },
                },
            },
            .{
                .state_id = 3,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .accept = {} } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 2), result.merged_count);

    // State 0's non-terminal goto to former state 2 should now point to canonical state 1
    var found_state_0 = false;
    for (result.states) |s| {
        if (s.id != 0) continue;
        found_state_0 = true;
        try std.testing.expectEqual(@as(usize, 3), s.transitions.len);
        for (s.transitions) |t| {
            switch (t.symbol) {
                .non_terminal => |idx| {
                    _ = idx;
                    try std.testing.expect(t.state < result.states.len);
                },
                .end => {},
                .terminal => {},
                .external => {},
            }
        }
    }
    try std.testing.expect(found_state_0);

    // State 2 should not be present in the output
    for (result.states) |s| {
        try std.testing.expect(s.id != 2);
    }
}

test "minimizeAlloc keeps distinct states separate" {
    const allocator = std.testing.allocator;

    // Two states with different actions should not be merged
    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 1 } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc keeps states with different item cores separate" {
    const allocator = std.testing.allocator;

    var left_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, item.ParseItem.init(0, 1)),
    };
    defer for (left_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    var right_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, 1, 0, item.ParseItem.init(1, 1)),
    };
    defer for (right_items) |entry| item.freeSymbolSet(allocator, entry.lookaheads);

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = left_items[0..], .transitions = &.{} },
        .{ .id = 1, .core_id = 1, .items = right_items[0..], .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc merges states before lex mode assignment" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .lex_state_id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .lex_state_id = 2, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
    try std.testing.expectEqual(@as(state.LexStateId, 1), result.states[0].lex_state_id);
}

test "minimizeAlloc merges compatible reserved-word states" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 0,
            .reserved_word_set_id = 1,
            .items = &.{},
            .transitions = &.{},
        },
        .{
            .id = 1,
            .reserved_word_set_id = 2,
            .items = &.{},
            .transitions = &.{},
        },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
    try std.testing.expectEqual(@as(u16, 1), result.states[0].reserved_word_set_id);
}

test "minimizeAlloc keeps external-internal terminal states separate" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const conflicts = [_]bool{ false, false, false, false };
    const external_internal_tokens = [_]bool{ true, false };
    const result = try minimizeAlloc(
        allocator,
        parse_states[0..],
        resolved_actions,
        .{
            .terminal_count = 2,
            .conflicts = conflicts[0..],
            .external_internal_tokens = external_internal_tokens[0..],
        },
        null,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc allows internal terminals when both states already allow same external token" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                    .{
                        .symbol = .{ .external = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                    .{
                        .symbol = .{ .external = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const conflicts = [_]bool{ false, false, false, false };
    const result = try minimizeAlloc(
        allocator,
        parse_states[0..],
        resolved_actions,
        .{
            .terminal_count = 2,
            .conflicts = conflicts[0..],
        },
        null,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
}

test "minimizeAlloc ignores non-terminal extra target differences" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{
            .id = 0,
            .core_id = 0,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 2, .extra = true },
            },
        },
        .{
            .id = 1,
            .core_id = 0,
            .items = &.{},
            .transitions = &[_]state.Transition{
                .{ .symbol = .{ .non_terminal = 0 }, .state = 3, .extra = true },
            },
        },
        .{ .id = 2, .core_id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 3, .core_id = 2, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{ .state_id = 2, .groups = &.{} },
            .{ .state_id = 3, .groups = &.{} },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
}

test "minimizeAlloc compares unresolved action lists instead of diagnostic reasons" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .items = &.{}, .transitions = &.{} },
    };
    const candidates = [_]actions.ParseAction{
        .{ .reduce = 0 },
        .{ .reduce = 1 },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = candidates[0..],
                        .decision = .{ .unresolved = .reduce_reduce_expected },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = candidates[0..],
                        .decision = .{ .unresolved = .reduce_reduce_deferred },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
}

test "minimizeAlloc propagates unresolved shift successors during successor partitioning" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 2, .core_id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 3, .core_id = 1, .items = &.{}, .transitions = &.{} },
    };

    const state0_candidates = [_]actions.ParseAction{
        .{ .reduce = 0 },
        .{ .shift = 2 },
    };
    const state1_candidates = [_]actions.ParseAction{
        .{ .reduce = 0 },
        .{ .shift = 3 },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{.{
                    .symbol = .{ .terminal = 0 },
                    .candidate_actions = state0_candidates[0..],
                    .decision = .{ .unresolved = .shift_reduce_expected },
                }},
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{.{
                    .symbol = .{ .terminal = 0 },
                    .candidate_actions = state1_candidates[0..],
                    .decision = .{ .unresolved = .shift_reduce_expected },
                }},
            },
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{.{
                    .symbol = .{ .terminal = 1 },
                    .candidate_actions = &.{},
                    .decision = .{ .chosen = .{ .reduce = 1 } },
                }},
            },
            .{
                .state_id = 3,
                .groups = &[_]resolution.ResolvedActionGroup{.{
                    .symbol = .{ .terminal = 1 },
                    .candidate_actions = &.{},
                    .decision = .{ .chosen = .{ .reduce = 2 } },
                }},
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc permits reserved word terminals across lexical conflicts" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .reserved_word_set_id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .reserved_word_set_id = 2, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .reduce = 0 } },
                    },
                },
            },
        },
    };

    const conflicts = [_]bool{
        false, true,
        true,  false,
    };
    const empty_reserved: [0]syntax_ir.SymbolRef = .{};
    const state0_reserved = [_]syntax_ir.SymbolRef{.{ .terminal = 1 }};
    const state1_reserved = [_]syntax_ir.SymbolRef{.{ .terminal = 0 }};
    const reserved_word_sets = [_][]const syntax_ir.SymbolRef{
        empty_reserved[0..],
        state0_reserved[0..],
        state1_reserved[0..],
    };

    const result = try minimizeAlloc(
        allocator,
        parse_states[0..],
        resolved_actions,
        .{
            .terminal_count = 2,
            .conflicts = conflicts[0..],
            .reserved_word_sets = reserved_word_sets[0..],
        },
        null,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.states.len);
    try std.testing.expectEqual(@as(usize, 1), result.merged_count);
}

test "minimizeAlloc keeps repetition and non-repetition shifts separate" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 2, .core_id = 1, .items = &.{}, .transitions = &.{} },
    };

    const shift_action = [_]@import("actions.zig").ParseAction{.{ .shift = 2 }};
    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = shift_action[0..],
                        .decision = .{ .chosen = .{ .shift = 2 } },
                        .shift_is_repetition = true,
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = shift_action[0..],
                        .decision = .{ .chosen = .{ .shift = 2 } },
                        .shift_is_repetition = false,
                    },
                },
            },
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &.{},
                        .decision = .{ .chosen = .{ .accept = {} } },
                    },
                },
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

test "minimizeAlloc keeps unresolved repetition and non-repetition shifts separate" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .core_id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 2, .core_id = 1, .items = &.{}, .transitions = &.{} },
    };

    const candidates = [_]@import("actions.zig").ParseAction{
        .{ .reduce = 0 },
        .{ .shift = 2 },
    };
    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{.{
                    .symbol = .{ .terminal = 0 },
                    .candidate_actions = candidates[0..],
                    .decision = .{ .unresolved = .auxiliary_repeat },
                    .shift_is_repetition = true,
                }},
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{.{
                    .symbol = .{ .terminal = 0 },
                    .candidate_actions = candidates[0..],
                    .decision = .{ .unresolved = .shift_reduce_expected },
                    .shift_is_repetition = false,
                }},
            },
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{.{
                    .symbol = .{ .terminal = 0 },
                    .candidate_actions = &.{},
                    .decision = .{ .chosen = .{ .accept = {} } },
                }},
            },
        },
    };

    const result = try minimizeAlloc(allocator, parse_states[0..], resolved_actions, null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.states.len);
    try std.testing.expectEqual(@as(usize, 0), result.merged_count);
}

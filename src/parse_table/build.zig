const std = @import("std");
const actions = @import("actions.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const first = @import("first.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const conflicts = @import("conflicts.zig");
const resolution = @import("resolution.zig");
const rules = @import("../ir/rules.zig");

fn envFlagEnabled(name: []const u8) bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

fn shouldLogBuildProgress() bool {
    if (envFlagEnabled("GEN_Z_SITTER_PARSE_TABLE_BUILD_PROGRESS")) return true;
    if (envFlagEnabled("GEN_Z_SITTER_PARSE_TABLE_PROGRESS")) return true;
    if (envFlagEnabled("GEN_Z_SITTER_PROGRESS")) return true;
    return false;
}

fn shouldLogBuildContexts() bool {
    return envFlagEnabled("GEN_Z_SITTER_PARSE_TABLE_CONTEXT_LOG");
}

fn logBuildStart(step: []const u8) void {
    std.debug.print("[parse_table_build] start {s}\n", .{step});
}

fn logBuildDone(step: []const u8, timer: *std.time.Timer) void {
    const elapsed_ms = @as(f64, @floatFromInt(timer.read())) / @as(f64, std.time.ns_per_ms);
    std.debug.print("[parse_table_build] done  {s} ({d:.2} ms)\n", .{ step, elapsed_ms });
}

fn maybeStartTimer(enabled: bool) ?std.time.Timer {
    if (!enabled) return null;
    return std.time.Timer.start() catch null;
}

fn maybeLogBuildDone(step: []const u8, timer: ?*std.time.Timer) void {
    if (timer) |value| logBuildDone(step, value);
}

fn logBuildSummary(comptime format: []const u8, args: anytype) void {
    std.debug.print("[parse_table_build] " ++ format ++ "\n", args);
}

fn countPresent(values: []const bool) usize {
    var count: usize = 0;
    for (values) |present| {
        if (present) count += 1;
    }
    return count;
}

fn optionalSymbolRefFormat(value: ?syntax_ir.SymbolRef, writer: anytype) !void {
    if (value) |symbol| {
        switch (symbol) {
            .non_terminal => |index| try writer.print("non_terminal:{d}", .{index}),
            .terminal => |index| try writer.print("terminal:{d}", .{index}),
            .external => |index| try writer.print("external:{d}", .{index}),
        }
    } else {
        try writer.writeAll("none");
    }
}

fn optionalSymbolRefText(buf: []u8, value: ?syntax_ir.SymbolRef) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    optionalSymbolRefFormat(value, stream.writer()) catch return "format_error";
    return stream.getWritten();
}

const AppendStats = struct {
    changed: bool,
    added: usize,
    duplicate_checks: usize,
    duplicate_hits: usize,
};

const ClosureExpansionCacheEntry = struct {
    non_terminal: u32,
    propagated_first: first.SymbolSet,
    inherited_lookahead: ?syntax_ir.SymbolRef,
    generated_items: []const item.ParseItem,
};

fn variableCountFromProductions(productions: []const ProductionInfo) usize {
    var max_lhs: usize = 0;
    var saw_any = false;
    for (productions) |production| {
        if (production.augmented) continue;
        saw_any = true;
        const lhs: usize = @intCast(production.lhs);
        if (lhs > max_lhs) max_lhs = lhs;
    }
    return if (saw_any) max_lhs + 1 else 0;
}

fn productionCountsFromProductions(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    variable_count: usize,
) ![]usize {
    const counts = try allocator.alloc(usize, variable_count);
    @memset(counts, 0);
    for (productions) |production| {
        if (production.augmented) continue;
        counts[production.lhs] += 1;
    }
    return counts;
}

fn logTopClosureContributors(
    variables: []const syntax_ir.SyntaxVariable,
    production_counts: []const usize,
    expansion_visits: []const usize,
    added_items: []const usize,
    duplicate_hits: []const usize,
    cache_hits: []const usize,
    cache_misses: []const usize,
    unique_lookaheads: []const usize,
    unique_first_sets: []const usize,
) void {
    var top_indices = [_]?usize{null} ** 5;

    var slot: usize = 0;
    while (slot < top_indices.len) : (slot += 1) {
        var best_index: ?usize = null;
        var best_added: usize = 0;
        for (added_items, 0..) |added, index| {
            if (added == 0) continue;
            var already_selected = false;
            for (top_indices[0..slot]) |selected| {
                if (selected == null) continue;
                if (selected.? == index) {
                    already_selected = true;
                    break;
                }
            }
            if (already_selected) continue;
            if (best_index == null or added > best_added) {
                best_index = index;
                best_added = added;
            }
        }
        if (best_index) |index| {
            top_indices[slot] = index;
        } else break;
    }

    for (top_indices, 0..) |maybe_index, idx| {
        if (maybe_index == null) break;
        const index = maybe_index.?;
        const variable_name = if (index < variables.len) variables[index].name else "<unknown>";
        logBuildSummary(
            "closure contributor rank={d} non_terminal={d} name={s} productions={d} visits={d} contexts={d} cache_hits={d} unique_lookaheads={d} unique_first_sets={d} added={d} duplicate_hits={d}",
            .{
                idx + 1,
                index,
                variable_name,
                if (index < production_counts.len) production_counts[index] else 0,
                expansion_visits[index],
                if (index < cache_misses.len) cache_misses[index] else 0,
                if (index < cache_hits.len) cache_hits[index] else 0,
                if (index < unique_lookaheads.len) unique_lookaheads[index] else 0,
                if (index < unique_first_sets.len) unique_first_sets[index] else 0,
                added_items[index],
                duplicate_hits[index],
            },
        );
    }
}

fn cloneSymbolSet(allocator: std.mem.Allocator, set: first.SymbolSet) !first.SymbolSet {
    const terminals = try allocator.dupe(bool, set.terminals);
    const externals = try allocator.dupe(bool, set.externals);
    return .{
        .terminals = terminals,
        .externals = externals,
        .includes_epsilon = set.includes_epsilon,
    };
}

fn optionalSymbolRefEql(a: ?syntax_ir.SymbolRef, b: ?syntax_ir.SymbolRef) bool {
    if (a) |left| {
        if (b) |right| return symbolRefEql(left, right);
        return false;
    }
    return b == null;
}

fn findClosureExpansionCache(
    entries: []const ClosureExpansionCacheEntry,
    non_terminal: u32,
    propagated_first: first.SymbolSet,
    inherited_lookahead: ?syntax_ir.SymbolRef,
) ?[]const item.ParseItem {
    for (entries) |entry| {
        if (entry.non_terminal != non_terminal) continue;
        if (!optionalSymbolRefEql(entry.inherited_lookahead, inherited_lookahead)) continue;
        if (!first.SymbolSet.eql(entry.propagated_first, propagated_first)) continue;
        return entry.generated_items;
    }
    return null;
}

fn countDistinctLookaheadsForNonTerminal(
    entries: []const ClosureExpansionCacheEntry,
    non_terminal: u32,
) usize {
    var count: usize = 0;
    for (entries, 0..) |entry, index| {
        if (entry.non_terminal != non_terminal) continue;
        var already_seen = false;
        for (entries[0..index]) |prior| {
            if (prior.non_terminal != non_terminal) continue;
            if (optionalSymbolRefEql(prior.inherited_lookahead, entry.inherited_lookahead)) {
                already_seen = true;
                break;
            }
        }
        if (!already_seen) count += 1;
    }
    return count;
}

fn countDistinctFirstSetsForNonTerminal(
    entries: []const ClosureExpansionCacheEntry,
    non_terminal: u32,
) usize {
    var count: usize = 0;
    for (entries, 0..) |entry, index| {
        if (entry.non_terminal != non_terminal) continue;
        var already_seen = false;
        for (entries[0..index]) |prior| {
            if (prior.non_terminal != non_terminal) continue;
            if (first.SymbolSet.eql(prior.propagated_first, entry.propagated_first)) {
                already_seen = true;
                break;
            }
        }
        if (!already_seen) count += 1;
    }
    return count;
}

fn buildClosureExpansionItemsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    non_terminal: u32,
    propagated_first: first.SymbolSet,
    inherited_lookahead: ?syntax_ir.SymbolRef,
    options: BuildOptions,
) ![]const item.ParseItem {
    var generated = std.array_list.Managed(item.ParseItem).init(allocator);
    defer generated.deinit();

    for (productions, 0..) |candidate, production_index| {
        if (candidate.augmented) continue;
        if (candidate.lhs != non_terminal) continue;
        try appendGeneratedItems(
            &generated,
            @intCast(production_index),
            propagated_first,
            inherited_lookahead,
            options,
        );
    }

    return try generated.toOwnedSlice();
}

fn appendGeneratedItems(
    generated: *std.array_list.Managed(item.ParseItem),
    production_id: item.ProductionId,
    propagated_first: first.SymbolSet,
    inherited_lookahead: ?syntax_ir.SymbolRef,
    options: BuildOptions,
) !void {
    if (options.closure_lookahead_mode == .none) {
        const has_any_signal = propagated_first.includes_epsilon or
            countPresent(propagated_first.terminals) > 0 or
            countPresent(propagated_first.externals) > 0;
        if (has_any_signal) {
            try generated.append(item.ParseItem.init(production_id, 0));
        }
        return;
    }

    for (propagated_first.terminals, 0..) |present, index| {
        if (!present) continue;
        try generated.append(item.ParseItem.withLookahead(production_id, 0, .{ .terminal = @intCast(index) }));
    }

    for (propagated_first.externals, 0..) |present, index| {
        if (!present) continue;
        try generated.append(item.ParseItem.withLookahead(production_id, 0, .{ .external = @intCast(index) }));
    }

    if (propagated_first.includes_epsilon) {
        try generated.append(if (inherited_lookahead) |lookahead|
            item.ParseItem.withLookahead(production_id, 0, lookahead)
        else
            item.ParseItem.init(production_id, 0));
    }
}

pub const BuildError = error{
    UnsupportedFeature,
    OutOfMemory,
};

pub const ClosureLookaheadMode = enum {
    full,
    none,
};

pub const BuildOptions = struct {
    closure_lookahead_mode: ClosureLookaheadMode = .full,
};

pub const ProductionInfo = struct {
    lhs: u32,
    steps: []const syntax_ir.ProductionStep,
    lhs_is_repeat_auxiliary: bool = false,
    augmented: bool = false,
    dynamic_precedence: i32 = 0,
};

pub const BuildResult = struct {
    productions: []const ProductionInfo,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    states: []const state.ParseState,
    actions: actions.ActionTable,
    resolved_actions: resolution.ResolvedActionTable,

    pub fn hasUnresolvedDecisions(self: BuildResult) bool {
        return self.resolved_actions.hasUnresolvedDecisions();
    }

    pub fn isSerializationReady(self: BuildResult) bool {
        return self.resolved_actions.isSerializationReady();
    }

    pub fn unresolvedDecisionsAlloc(
        self: BuildResult,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const resolution.UnresolvedDecisionRef {
        return self.resolved_actions.unresolvedDecisionsAlloc(allocator);
    }

    pub fn chosenDecisionsAlloc(
        self: BuildResult,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const resolution.ChosenDecisionRef {
        return self.resolved_actions.chosenDecisionsAlloc(allocator);
    }

    pub fn decisionSnapshotAlloc(
        self: BuildResult,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!resolution.DecisionSnapshot {
        return self.resolved_actions.snapshotAlloc(allocator);
    }
};

pub fn buildStates(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
) BuildError!BuildResult {
    return try buildStatesWithOptions(allocator, grammar, .{});
}

pub fn buildStatesWithOptions(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
    options: BuildOptions,
) BuildError!BuildResult {
    const progress_log = shouldLogBuildProgress();
    try validateSupportedSubset(grammar);

    var timer = maybeStartTimer(progress_log);
    if (progress_log) logBuildStart("compute_first_sets");
    const first_sets = try first.computeFirstSets(allocator, grammar);
    if (progress_log) maybeLogBuildDone("compute_first_sets", if (timer) |*value| value else null);

    timer = maybeStartTimer(progress_log);
    if (progress_log) logBuildStart("collect_productions");
    const productions = try collectProductions(allocator, grammar);
    if (progress_log) {
        maybeLogBuildDone("collect_productions", if (timer) |*value| value else null);
        logBuildSummary("collect_productions summary productions={d}", .{productions.len});
    }

    timer = maybeStartTimer(progress_log);
    if (progress_log) logBuildStart("construct_states");
    const constructed = try constructStates(allocator, grammar.variables, productions, first_sets, options);
    if (progress_log) {
        maybeLogBuildDone("construct_states", if (timer) |*value| value else null);
        logBuildSummary(
            "construct_states summary states={d} action_states={d}",
            .{ constructed.states.len, constructed.actions.states.len },
        );
    }

    timer = maybeStartTimer(progress_log);
    if (progress_log) logBuildStart("group_action_table");
    const grouped_actions = try actions.groupActionTable(allocator, constructed.actions);
    if (progress_log) maybeLogBuildDone("group_action_table", if (timer) |*value| value else null);

    timer = maybeStartTimer(progress_log);
    if (progress_log) logBuildStart("resolve_action_table");
    const resolved_actions = try resolution.resolveActionTableWithContext(
        allocator,
        productions,
        grammar.precedence_orderings,
        constructed.states,
        grouped_actions,
    );
    if (progress_log) {
        maybeLogBuildDone("resolve_action_table", if (timer) |*value| value else null);
        logBuildSummary(
            "resolve_action_table summary unresolved_decisions={} serialization_ready={}",
            .{ resolved_actions.hasUnresolvedDecisions(), resolved_actions.isSerializationReady() },
        );
    }
    return .{
        .productions = productions,
        .precedence_orderings = grammar.precedence_orderings,
        .states = constructed.states,
        .actions = constructed.actions,
        .resolved_actions = resolved_actions,
    };
}

const ConstructedStates = struct {
    states: []const state.ParseState,
    actions: actions.ActionTable,
};

fn validateSupportedSubset(grammar: syntax_ir.SyntaxGrammar) BuildError!void {
    _ = grammar;
}

fn collectProductions(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
) BuildError![]const ProductionInfo {
    var productions = std.array_list.Managed(ProductionInfo).init(allocator);
    defer productions.deinit();

    const augmented_steps = try allocator.alloc(syntax_ir.ProductionStep, 1);
    augmented_steps[0] = .{ .symbol = .{ .non_terminal = 0 } };
    try productions.append(.{
        .lhs = std.math.maxInt(u32),
        .steps = augmented_steps,
        .augmented = true,
    });

    for (grammar.variables, 0..) |variable, variable_index| {
        for (variable.productions) |production| {
            try productions.append(.{
                .lhs = @intCast(variable_index),
                .steps = production.steps,
                .lhs_is_repeat_auxiliary = variable.kind == .auxiliary and std.mem.indexOf(u8, variable.name, "_repeat") != null,
                .dynamic_precedence = production.dynamic_precedence,
            });
        }
    }

    return try productions.toOwnedSlice();
}

fn constructStates(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    options: BuildOptions,
) BuildError!ConstructedStates {
    const progress_log = shouldLogBuildProgress();
    var states = std.array_list.Managed(state.ParseState).init(allocator);
    defer states.deinit();
    var action_states = std.array_list.Managed(actions.StateActions).init(allocator);
    defer action_states.deinit();

    var start_timer = maybeStartTimer(progress_log);
    if (progress_log) logBuildStart("construct_states.initial_closure");
    const start_items = try closure(allocator, variables, productions, first_sets, &[_]item.ParseItem{item.ParseItem.init(0, 0)}, options);
    if (progress_log) {
        maybeLogBuildDone("construct_states.initial_closure", if (start_timer) |*value| value else null);
        logBuildSummary("construct_states initial_closure items={d}", .{start_items.len});
    }
    try states.append(.{
        .id = 0,
        .items = start_items,
        .transitions = &.{},
        .conflicts = &.{},
    });

    var next_state_index: usize = 0;
    var next_progress_report: usize = 10;
    while (next_state_index < states.items.len) : (next_state_index += 1) {
        if (progress_log and (next_state_index < 5 or next_state_index + 1 == next_progress_report)) {
            logBuildSummary(
                "construct_states entering state_index={d} state_id={d} items={d} discovered={d}",
                .{
                    next_state_index,
                    states.items[next_state_index].id,
                    states.items[next_state_index].items.len,
                    states.items.len,
                },
            );
        }
        const transitions = try collectTransitionsForState(allocator, variables, productions, first_sets, &states, states.items[next_state_index].items, options);
        const mutable_states = states.items;
        mutable_states[next_state_index].transitions = transitions;

        const state_actions = try actions.buildActionsForState(allocator, productions, mutable_states[next_state_index]);
        const detected_conflicts = try conflicts.detectConflictsFromActions(
            allocator,
            mutable_states[next_state_index],
            state_actions,
        );
        mutable_states[next_state_index].conflicts = detected_conflicts;
        try action_states.append(.{
            .state_id = mutable_states[next_state_index].id,
            .entries = state_actions,
        });

        if (progress_log and next_state_index + 1 >= next_progress_report) {
            logBuildSummary(
                "construct_states progress processed={d} discovered={d}",
                .{ next_state_index + 1, states.items.len },
            );
            next_progress_report += if (next_progress_report < 100) 10 else 100;
        }
    }

    state.sortStates(states.items);
    return .{
        .states = try states.toOwnedSlice(),
        .actions = .{
            .states = try action_states.toOwnedSlice(),
        },
    };
}

fn collectTransitionsForState(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    states: *std.array_list.Managed(state.ParseState),
    state_items: []const item.ParseItem,
    options: BuildOptions,
) BuildError![]const state.Transition {
    var transitions = std.array_list.Managed(state.Transition).init(allocator);
    defer transitions.deinit();

    for (state_items) |parse_item| {
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) continue;
        const symbol = production.steps[parse_item.step_index].symbol;
        if (containsTransition(transitions.items, symbol)) continue;

        const advanced_items = try gotoItems(allocator, variables, productions, first_sets, state_items, symbol, options);
        if (findState(states.items, advanced_items)) |existing| {
            try transitions.append(.{ .symbol = symbol, .state = existing.id });
            continue;
        }

        const new_id: state.StateId = @intCast(states.items.len);
        try states.append(.{
            .id = new_id,
            .items = advanced_items,
            .transitions = &.{},
            .conflicts = &.{},
        });
        try transitions.append(.{ .symbol = symbol, .state = new_id });
    }

    state.sortTransitions(transitions.items);
    return try transitions.toOwnedSlice();
}

test "buildStates records LR(0)-style conflicts for an ambiguous expression grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var recursive_expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 1 } },
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var literal_expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{
                .name = "expr",
                .kind = .named,
                .productions = &.{
                    .{ .steps = recursive_expr_steps[0..] },
                    .{ .steps = literal_expr_steps[0..] },
                },
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try buildStates(arena.allocator(), grammar);

    var saw_shift_reduce = false;
    var saw_reduce_reduce = false;
    for (result.states) |parse_state| {
        for (parse_state.conflicts) |conflict| {
            switch (conflict.kind) {
                .shift_reduce => saw_shift_reduce = true,
                .reduce_reduce => saw_reduce_reduce = true,
            }
        }
    }

    try std.testing.expect(saw_shift_reduce);
    try std.testing.expect(!saw_reduce_reduce);
    try std.testing.expect(result.actions.entriesForState(0).len > 0);
}

fn closure(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    seed_items: []const item.ParseItem,
    options: BuildOptions,
) BuildError![]const item.ParseItem {
    const progress_log = shouldLogBuildProgress();
    const context_log = shouldLogBuildContexts();
    const variable_count = variableCountFromProductions(productions);
    var items = std.array_list.Managed(item.ParseItem).init(allocator);
    defer items.deinit();
    var expansion_cache = std.array_list.Managed(ClosureExpansionCacheEntry).init(allocator);
    defer expansion_cache.deinit();
    try items.appendSlice(seed_items);
    state.sortItems(items.items);

    var expansion_visits: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(expansion_visits);
    var production_counts: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(production_counts);
    var added_items: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(added_items);
    var duplicate_hits: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(duplicate_hits);
    var cache_hits: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(cache_hits);
    var cache_misses: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(cache_misses);
    var unique_lookaheads: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(unique_lookaheads);
    var unique_first_sets: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(unique_first_sets);
    var next_added_report: []usize = &.{};
    defer if (progress_log and variable_count > 0) allocator.free(next_added_report);
    if (progress_log and variable_count > 0) {
        expansion_visits = try allocator.alloc(usize, variable_count);
        production_counts = try productionCountsFromProductions(allocator, productions, variable_count);
        added_items = try allocator.alloc(usize, variable_count);
        duplicate_hits = try allocator.alloc(usize, variable_count);
        cache_hits = try allocator.alloc(usize, variable_count);
        cache_misses = try allocator.alloc(usize, variable_count);
        unique_lookaheads = try allocator.alloc(usize, variable_count);
        unique_first_sets = try allocator.alloc(usize, variable_count);
        next_added_report = try allocator.alloc(usize, variable_count);
        @memset(expansion_visits, 0);
        @memset(added_items, 0);
        @memset(duplicate_hits, 0);
        @memset(cache_hits, 0);
        @memset(cache_misses, 0);
        @memset(unique_lookaheads, 0);
        @memset(unique_first_sets, 0);
        @memset(next_added_report, 250);
    }

    if (progress_log) {
        logBuildSummary("closure start seed_items={d}", .{seed_items.len});
    }

    var changed = true;
    var round: usize = 0;
    while (changed) {
        round += 1;
        changed = false;
        const round_start_len = items.items.len;
        if (progress_log) {
            logBuildSummary("closure round={d} start items={d}", .{ round, round_start_len });
        }
        var cursor: usize = 0;
        while (cursor < items.items.len) : (cursor += 1) {
            if (progress_log and (cursor < 5 or (cursor + 1) % 100 == 0)) {
                logBuildSummary(
                    "closure round={d} cursor={d}/{d}",
                    .{ round, cursor + 1, items.items.len },
                );
            }
            const parse_item = items.items[cursor];
            const production = productions[parse_item.production_id];
            if (parse_item.step_index >= production.steps.len) continue;
            switch (production.steps[parse_item.step_index].symbol) {
                .non_terminal => |non_terminal| {
                    if (progress_log and non_terminal < expansion_visits.len) {
                        expansion_visits[non_terminal] += 1;
                    }
                    const suffix = production.steps[parse_item.step_index + 1 ..];
                    const suffix_first = try first_sets.firstOfSequence(allocator, suffix);
                    const generated_items = if (findClosureExpansionCache(
                        expansion_cache.items,
                        non_terminal,
                        suffix_first,
                        parse_item.lookahead,
                    )) |cached| blk: {
                        if (progress_log and non_terminal < cache_hits.len) {
                            cache_hits[non_terminal] += 1;
                        }
                        break :blk cached;
                    } else blk: {
                        if (progress_log and non_terminal < cache_misses.len) {
                            cache_misses[non_terminal] += 1;
                        }
                        const generated = try buildClosureExpansionItemsAlloc(
                            allocator,
                            productions,
                            non_terminal,
                            suffix_first,
                            parse_item.lookahead,
                            options,
                        );
                        try expansion_cache.append(.{
                            .non_terminal = non_terminal,
                            .propagated_first = try cloneSymbolSet(allocator, suffix_first),
                            .inherited_lookahead = parse_item.lookahead,
                            .generated_items = generated,
                        });
                        if (progress_log and non_terminal < unique_lookaheads.len) {
                            unique_lookaheads[non_terminal] = countDistinctLookaheadsForNonTerminal(
                                expansion_cache.items,
                                non_terminal,
                            );
                            unique_first_sets[non_terminal] = countDistinctFirstSetsForNonTerminal(
                                expansion_cache.items,
                                non_terminal,
                            );
                            if (context_log and (cache_misses[non_terminal] <= 3 or cache_misses[non_terminal] % 25 == 0)) {
                                var lookahead_buf: [64]u8 = undefined;
                                const lookahead_text = optionalSymbolRefText(&lookahead_buf, parse_item.lookahead);
                                std.debug.print(
                                    "[parse_table_build] closure context non_terminal={d} name={s} contexts={d} unique_lookaheads={d} unique_first_sets={d} lookahead={s} first(terminals={d}, externals={d}, epsilon={})\n",
                                    .{
                                        non_terminal,
                                        if (non_terminal < variables.len) variables[non_terminal].name else "<unknown>",
                                        cache_misses[non_terminal],
                                        unique_lookaheads[non_terminal],
                                        unique_first_sets[non_terminal],
                                        lookahead_text,
                                        countPresent(suffix_first.terminals),
                                        countPresent(suffix_first.externals),
                                        suffix_first.includes_epsilon,
                                    },
                                );
                            }
                        }
                        break :blk generated;
                    };

                    const append_stats = try appendGeneratedItemsToClosure(&items, generated_items);
                    if (progress_log and non_terminal < added_items.len) {
                        added_items[non_terminal] += append_stats.added;
                        duplicate_hits[non_terminal] += append_stats.duplicate_hits;
                        if (added_items[non_terminal] >= next_added_report[non_terminal]) {
                            logBuildSummary(
                                "closure hot non_terminal={d} name={s} productions={d} visits={d} contexts={d} cache_hits={d} unique_lookaheads={d} unique_first_sets={d} added={d} duplicate_hits={d}",
                                .{
                                    non_terminal,
                                    if (non_terminal < variables.len) variables[non_terminal].name else "<unknown>",
                                    if (non_terminal < production_counts.len) production_counts[non_terminal] else 0,
                                    expansion_visits[non_terminal],
                                    if (non_terminal < cache_misses.len) cache_misses[non_terminal] else 0,
                                    if (non_terminal < cache_hits.len) cache_hits[non_terminal] else 0,
                                    if (non_terminal < unique_lookaheads.len) unique_lookaheads[non_terminal] else 0,
                                    if (non_terminal < unique_first_sets.len) unique_first_sets[non_terminal] else 0,
                                    added_items[non_terminal],
                                    duplicate_hits[non_terminal],
                                },
                            );
                            next_added_report[non_terminal] += 250;
                        }
                    }
                    if (append_stats.changed) {
                        changed = true;
                    }
                },
                else => {},
            }
        }
        state.sortItems(items.items);
        if (progress_log) {
            logBuildSummary(
                "closure round={d} done items={d} added={d} changed={}",
                .{ round, items.items.len, items.items.len - round_start_len, changed },
            );
            if (round == 1 or items.items.len - round_start_len > 0) {
                logTopClosureContributors(
                    variables,
                    production_counts,
                    expansion_visits,
                    added_items,
                    duplicate_hits,
                    cache_hits,
                    cache_misses,
                    unique_lookaheads,
                    unique_first_sets,
                );
            }
        }
    }

    if (progress_log) {
        logBuildSummary("closure complete rounds={d} items={d}", .{ round, items.items.len });
    }

    return try items.toOwnedSlice();
}

fn gotoItems(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    state_items: []const item.ParseItem,
    symbol: syntax_ir.SymbolRef,
    options: BuildOptions,
) BuildError![]const item.ParseItem {
    var advanced = std.array_list.Managed(item.ParseItem).init(allocator);
    defer advanced.deinit();

    for (state_items) |parse_item| {
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) continue;
        if (!symbolRefEql(production.steps[parse_item.step_index].symbol, symbol)) continue;
        try advanced.append(.{
            .production_id = parse_item.production_id,
            .step_index = parse_item.step_index + 1,
            .lookahead = parse_item.lookahead,
        });
    }

    return try closure(allocator, variables, productions, first_sets, advanced.items, options);
}

fn appendGeneratedItemsToClosure(
    items: *std.array_list.Managed(item.ParseItem),
    generated_items: []const item.ParseItem,
) BuildError!AppendStats {
    var stats = AppendStats{
        .changed = false,
        .added = 0,
        .duplicate_checks = 0,
        .duplicate_hits = 0,
    };

    for (generated_items) |new_item| {
        const duplicate = containsItem(items.items, new_item);
        stats.duplicate_checks += 1;
        if (duplicate) {
            stats.duplicate_hits += 1;
        } else {
            try items.append(new_item);
            stats.changed = true;
            stats.added += 1;
        }
    }

    return stats;
}

fn containsItem(items: []const item.ParseItem, candidate: item.ParseItem) bool {
    for (items) |entry| {
        if (item.ParseItem.eql(entry, candidate)) return true;
    }
    return false;
}

fn containsTransition(transitions: []const state.Transition, symbol: syntax_ir.SymbolRef) bool {
    for (transitions) |entry| {
        if (symbolRefEql(entry.symbol, symbol)) return true;
    }
    return false;
}

fn findState(states: []const state.ParseState, candidate_items: []const item.ParseItem) ?state.ParseState {
    for (states) |parse_state| {
        if (itemsEql(parse_state.items, candidate_items)) return parse_state;
    }
    return null;
}

fn itemsEql(left: []const item.ParseItem, right: []const item.ParseItem) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!item.ParseItem.eql(a, b)) return false;
    }
    return true;
}

fn symbolRefEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
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

test "buildStates constructs deterministic LR(0)-style states for a tiny grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try buildStates(arena.allocator(), grammar);
    try std.testing.expectEqual(@as(usize, 3), result.productions.len);
    try std.testing.expectEqual(@as(usize, 4), result.states.len);
    try std.testing.expectEqual(@as(state.StateId, 0), result.states[0].id);
    try std.testing.expectEqual(@as(usize, 3), result.states[0].items.len);
    try std.testing.expectEqual(@as(usize, 3), result.states[0].transitions.len);
}

test "buildStates propagates terminal lookaheads through nullable suffix closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 1 } },
    };
    var start_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "start", .kind = .named, .productions = &.{.{ .steps = start_steps[0..] }} },
            .{ .name = "expr", .kind = .named, .productions = &.{.{ .steps = expr_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try buildStates(arena.allocator(), grammar);

    var saw_start_with_terminal_lookahead = false;
    var saw_expr_with_terminal_lookahead = false;
    for (result.states[0].items) |parse_item| {
        if (parse_item.production_id == 2 and hasTerminalLookahead(parse_item, 1)) {
            saw_start_with_terminal_lookahead = true;
        }
        if (parse_item.production_id == 3 and hasTerminalLookahead(parse_item, 1)) {
            saw_expr_with_terminal_lookahead = true;
        }
    }

    try std.testing.expect(saw_start_with_terminal_lookahead);
    try std.testing.expect(saw_expr_with_terminal_lookahead);
}

fn hasTerminalLookahead(parse_item: item.ParseItem, terminal_index: u32) bool {
    if (parse_item.lookahead) |lookahead| {
        return switch (lookahead) {
            .terminal => |index| index == terminal_index,
            else => false,
        };
    }
    return false;
}

test "buildStates allows inert step metadata in the current supported subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .terminal = 0 },
            .alias = .{ .value = "token", .named = true },
            .field_name = "lhs",
            .precedence = .{ .integer = 1 },
            .associativity = .left,
            .reserved_context_name = "global",
        },
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

    const result = try buildStates(arena.allocator(), grammar);

    try std.testing.expectEqual(@as(usize, 3), result.states.len);
    try std.testing.expectEqual(@as(state.StateId, 2), result.states[0].transitions[1].state);
}

test "buildStates accepts dynamic precedence metadata in the current supported subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{
                .name = "source_file",
                .kind = .named,
                .productions = &.{.{ .steps = source_steps[0..], .dynamic_precedence = 1 }},
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try buildStates(arena.allocator(), grammar);
    try std.testing.expect(result.states.len > 0);
}

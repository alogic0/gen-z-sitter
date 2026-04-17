const std = @import("std");
const actions = @import("actions.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const first = @import("first.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const conflicts = @import("conflicts.zig");
const resolution = @import("resolution.zig");
const rules = @import("../ir/rules.zig");

threadlocal var scoped_progress_enabled: bool = false;
threadlocal var current_transition_context: ?TransitionContext = null;

fn testLog(name: []const u8) void {
    std.debug.print("[parse_table/build] {s}\n", .{name});
}

const TransitionContext = struct {
    source_state_id: state.StateId,
    symbol: syntax_ir.SymbolRef,
};

fn envFlagEnabled(name: []const u8) bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return true;
}

fn hasProgressTargetFilter() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "GEN_Z_SITTER_PARSE_TABLE_TARGET_FILTER") catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len != 0;
}

pub fn setScopedProgressEnabled(enabled: bool) void {
    scoped_progress_enabled = enabled;
}

fn shouldLogBuildProgress() bool {
    const requested =
        envFlagEnabled("GEN_Z_SITTER_PARSE_TABLE_BUILD_PROGRESS") or
        envFlagEnabled("GEN_Z_SITTER_PARSE_TABLE_PROGRESS") or
        envFlagEnabled("GEN_Z_SITTER_PROGRESS");
    if (!requested) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn shouldLogBuildContexts() bool {
    if (!envFlagEnabled("GEN_Z_SITTER_PARSE_TABLE_CONTEXT_LOG")) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
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

fn singleLookahead(lookaheads: first.SymbolSet) ?syntax_ir.SymbolRef {
    var found: ?syntax_ir.SymbolRef = null;
    for (lookaheads.terminals, 0..) |present, index| {
        if (!present) continue;
        if (found != null) return null;
        found = .{ .terminal = @intCast(index) };
    }
    for (lookaheads.externals, 0..) |present, index| {
        if (!present) continue;
        if (found != null) return null;
        found = .{ .external = @intCast(index) };
    }
    return found;
}

fn symbolDisplayText(
    buf: []u8,
    variables: []const syntax_ir.SyntaxVariable,
    symbol: syntax_ir.SymbolRef,
) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    switch (symbol) {
        .non_terminal => |index| {
            const name = if (index < variables.len) variables[index].name else "<unknown>";
            stream.writer().print("non_terminal:{d}({s})", .{ index, name }) catch return "format_error";
        },
        .terminal => |index| {
            const name = if (index < variables.len) variables[index].name else "<unknown>";
            stream.writer().print("terminal:{d}({s})", .{ index, name }) catch return "format_error";
        },
        .external => |index| {
            stream.writer().print("external:{d}", .{index}) catch return "format_error";
        },
    }
    return stream.getWritten();
}

fn setCurrentTransitionContext(context: ?TransitionContext) void {
    current_transition_context = context;
}

const AppendStats = struct {
    changed: bool,
    added: usize,
    duplicate_checks: usize,
    duplicate_hits: usize,
};

const ParseItemCoreContext = struct {
    pub fn hash(_: @This(), value: item.ParseItem) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&value.production_id));
        hasher.update(std.mem.asBytes(&value.step_index));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: item.ParseItem, b: item.ParseItem) bool {
        return item.ParseItem.eql(a, b);
    }
};

const ParseItemContext = struct {
    pub fn hash(_: @This(), value: item.ParseItemSetEntry) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&value.item.production_id));
        hasher.update(std.mem.asBytes(&value.item.step_index));
        hasher.update(std.mem.sliceAsBytes(value.lookaheads.terminals));
        hasher.update(std.mem.sliceAsBytes(value.lookaheads.externals));
        hasher.update(std.mem.asBytes(&value.lookaheads.includes_epsilon));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: item.ParseItemSetEntry, b: item.ParseItemSetEntry) bool {
        return item.ParseItemSetEntry.eql(a, b);
    }
};

const ParseItemSet = std.HashMap(item.ParseItemSetEntry, void, ParseItemContext, std.hash_map.default_max_load_percentage);

const SymbolRefContext = struct {
    pub fn hash(_: @This(), value: syntax_ir.SymbolRef) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag: u8 = switch (value) {
            .non_terminal => 0,
            .terminal => 1,
            .external => 2,
        };
        hasher.update(std.mem.asBytes(&tag));
        switch (value) {
            .non_terminal => |index| hasher.update(std.mem.asBytes(&index)),
            .terminal => |index| hasher.update(std.mem.asBytes(&index)),
            .external => |index| hasher.update(std.mem.asBytes(&index)),
        }
        return hasher.final();
    }

    pub fn eql(_: @This(), a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
        return symbolRefEql(a, b);
    }
};

const ParseItemSliceContext = struct {
    pub fn hash(_: @This(), values: []const item.ParseItemSetEntry) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (values) |value| {
            hasher.update(std.mem.asBytes(&value.item.production_id));
            hasher.update(std.mem.asBytes(&value.item.step_index));
            hasher.update(std.mem.sliceAsBytes(value.lookaheads.terminals));
            hasher.update(std.mem.sliceAsBytes(value.lookaheads.externals));
            hasher.update(std.mem.asBytes(&value.lookaheads.includes_epsilon));
        }
        return hasher.final();
    }

    pub fn eql(_: @This(), a: []const item.ParseItemSetEntry, b: []const item.ParseItemSetEntry) bool {
        return itemsEql(a, b);
    }
};

const StateIdByItemSet = std.HashMap([]const item.ParseItemSetEntry, state.StateId, ParseItemSliceContext, std.hash_map.default_max_load_percentage);
const ClosedItemsBySeed = std.HashMap([]const item.ParseItemSetEntry, []const item.ParseItemSetEntry, ParseItemSliceContext, std.hash_map.default_max_load_percentage);
const SymbolIndexMap = std.HashMap(syntax_ir.SymbolRef, usize, SymbolRefContext, std.hash_map.default_max_load_percentage);
const SuccessorItemIndexMap = std.HashMap(item.ParseItem, usize, ParseItemCoreContext, std.hash_map.default_max_load_percentage);

const SuccessorGroup = struct {
    symbol: syntax_ir.SymbolRef,
    items: std.array_list.Managed(item.ParseItemSetEntry),
    item_indexes: SuccessorItemIndexMap,

    fn init(allocator: std.mem.Allocator, symbol: syntax_ir.SymbolRef) SuccessorGroup {
        return .{
            .symbol = symbol,
            .items = std.array_list.Managed(item.ParseItemSetEntry).init(allocator),
            .item_indexes = SuccessorItemIndexMap.init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        self.items.deinit();
        self.item_indexes.deinit();
    }
};

const ClosureExpansionCacheEntry = struct {
    non_terminal: u32,
    closure_lookahead_mode: ClosureLookaheadMode,
    propagated_first: first.SymbolSet,
    inherited_lookahead: ?syntax_ir.SymbolRef,
    generated_items: []const item.ParseItemSetEntry,
};

const ClosureResultCacheEntry = struct {
    seed_items: []const item.ParseItemSetEntry,
    closed_items: []const item.ParseItemSetEntry,
};

const FollowSetInfo = struct {
    lookaheads: first.SymbolSet,
    propagates_lookahead: bool,
};

const TransitiveClosureAddition = struct {
    production_id: item.ProductionId,
    info: FollowSetInfo,
};

const ParseItemSetBuilder = struct {
    allocator: std.mem.Allocator,
    additions_per_non_terminal: [][]const TransitiveClosureAddition,

    fn init(
        allocator: std.mem.Allocator,
        productions: []const ProductionInfo,
        first_sets: first.FirstSets,
    ) !@This() {
        const variable_count = variableCountFromProductions(productions);
        const additions_per_non_terminal = try allocator.alloc([]const TransitiveClosureAddition, variable_count);
        errdefer allocator.free(additions_per_non_terminal);

        for (0..variable_count) |non_terminal| {
            additions_per_non_terminal[non_terminal] = try computeTransitiveClosureAdditionsAlloc(
                allocator,
                productions,
                first_sets,
                @intCast(non_terminal),
            );
        }

        return .{
            .allocator = allocator,
            .additions_per_non_terminal = additions_per_non_terminal,
        };
    }

    fn deinit(self: *@This()) void {
        for (self.additions_per_non_terminal) |items| {
            for (items) |addition| {
                freeSymbolSet(self.allocator, addition.info.lookaheads);
            }
            self.allocator.free(items);
        }
        self.allocator.free(self.additions_per_non_terminal);
    }

    fn additionsForNonTerminal(self: @This(), non_terminal: u32) []const TransitiveClosureAddition {
        return self.additions_per_non_terminal[non_terminal];
    }
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
    if (current_transition_context) |context| {
        var symbol_buf: [128]u8 = undefined;
        const symbol_text = symbolDisplayText(&symbol_buf, variables, context.symbol);
        logBuildSummary(
            "closure contributor context source_state={d} symbol={s}",
            .{ context.source_state_id, symbol_text },
        );
    }

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

fn initEmptySymbolSet(allocator: std.mem.Allocator, terminals_len: usize, externals_len: usize) !first.SymbolSet {
    const terminals = try allocator.alloc(bool, terminals_len);
    errdefer allocator.free(terminals);
    const externals = try allocator.alloc(bool, externals_len);
    errdefer allocator.free(externals);
    @memset(terminals, false);
    @memset(externals, false);
    return .{
        .terminals = terminals,
        .externals = externals,
        .includes_epsilon = false,
    };
}

fn freeSymbolSet(allocator: std.mem.Allocator, set: first.SymbolSet) void {
    allocator.free(set.terminals);
    allocator.free(set.externals);
}

fn mergeSymbolSetLookaheads(target: *first.SymbolSet, incoming: first.SymbolSet) bool {
    var changed = false;
    for (incoming.terminals, 0..) |present, index| {
        if (present and !target.terminals[index]) {
            target.terminals[index] = true;
            changed = true;
        }
    }
    for (incoming.externals, 0..) |present, index| {
        if (present and !target.externals[index]) {
            target.externals[index] = true;
            changed = true;
        }
    }
    return changed;
}

fn addSymbolToSet(target: *first.SymbolSet, symbol: syntax_ir.SymbolRef) void {
    switch (symbol) {
        .terminal => |index| target.terminals[index] = true,
        .external => |index| target.externals[index] = true,
        .non_terminal => {},
    }
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
    closure_lookahead_mode: ClosureLookaheadMode,
    propagated_first: first.SymbolSet,
    inherited_lookahead: ?syntax_ir.SymbolRef,
) ?[]const item.ParseItemSetEntry {
    for (entries) |entry| {
        if (entry.non_terminal != non_terminal) continue;
        if (entry.closure_lookahead_mode != closure_lookahead_mode) continue;
        if (!optionalSymbolRefEql(entry.inherited_lookahead, inherited_lookahead)) continue;
        if (!first.SymbolSet.eql(entry.propagated_first, propagated_first)) continue;
        return entry.generated_items;
    }
    return null;
}

const ClosurePressureTrigger = struct {
    reason: []const u8,
    current_value: usize,
    threshold: usize,
};

fn closurePressureTrigger(
    options: BuildOptions,
    item_count: usize,
    duplicate_hit_count: usize,
    context_count: usize,
) ?ClosurePressureTrigger {
    if (options.closure_pressure_mode != .thresholded_lr0) return null;
    if (!options.closure_pressure_thresholds.enabled()) return null;

    if (options.closure_pressure_thresholds.max_closure_items != 0 and
        item_count >= options.closure_pressure_thresholds.max_closure_items)
    {
        return .{
            .reason = "max_closure_items",
            .current_value = item_count,
            .threshold = options.closure_pressure_thresholds.max_closure_items,
        };
    }

    if (options.closure_pressure_thresholds.max_duplicate_hits != 0 and
        duplicate_hit_count >= options.closure_pressure_thresholds.max_duplicate_hits)
    {
        return .{
            .reason = "max_duplicate_hits",
            .current_value = duplicate_hit_count,
            .threshold = options.closure_pressure_thresholds.max_duplicate_hits,
        };
    }

    if (options.closure_pressure_thresholds.max_contexts_per_non_terminal != 0 and
        context_count >= options.closure_pressure_thresholds.max_contexts_per_non_terminal)
    {
        return .{
            .reason = "max_contexts_per_non_terminal",
            .current_value = context_count,
            .threshold = options.closure_pressure_thresholds.max_contexts_per_non_terminal,
        };
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

const FollowWorkEntry = struct {
    non_terminal: u32,
    lookaheads: first.SymbolSet,
    propagates_lookahead: bool,
};

fn findFollowInfoIndex(items: []const ?FollowSetInfo, non_terminal: u32) ?usize {
    if (non_terminal >= items.len) return null;
    return if (items[non_terminal] != null) non_terminal else null;
}

fn mergeFollowInfo(
    allocator: std.mem.Allocator,
    target: *?FollowSetInfo,
    incoming: FollowWorkEntry,
) !bool {
    if (target.* == null) {
        target.* = .{
            .lookaheads = try cloneSymbolSet(allocator, incoming.lookaheads),
            .propagates_lookahead = incoming.propagates_lookahead,
        };
        return true;
    }

    var changed = false;
    changed = mergeSymbolSetLookaheads(&target.*.?.lookaheads, incoming.lookaheads) or changed;
    if (incoming.propagates_lookahead and !target.*.?.propagates_lookahead) {
        target.*.?.propagates_lookahead = true;
        changed = true;
    }
    return changed;
}

fn computeTransitiveClosureAdditionsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    root_non_terminal: u32,
) ![]const TransitiveClosureAddition {
    const variable_count = variableCountFromProductions(productions);
    var infos = try allocator.alloc(?FollowSetInfo, variable_count);
    defer {
        for (infos) |maybe_info| {
            if (maybe_info) |info| freeSymbolSet(allocator, info.lookaheads);
        }
        allocator.free(infos);
    }
    @memset(infos, null);

    var stack = std.array_list.Managed(FollowWorkEntry).init(allocator);
    defer {
        for (stack.items) |entry| {
            freeSymbolSet(allocator, entry.lookaheads);
        }
        stack.deinit();
    }

    try stack.append(.{
        .non_terminal = root_non_terminal,
        .lookaheads = try initEmptySymbolSet(allocator, first_sets.terminals_len, first_sets.externals_len),
        .propagates_lookahead = true,
    });

    while (stack.items.len > 0) {
        const entry = stack.pop().?;
        const changed = try mergeFollowInfo(allocator, &infos[entry.non_terminal], entry);
        freeSymbolSet(allocator, entry.lookaheads);
        if (!changed) continue;

        for (productions) |production| {
            if (production.augmented) continue;
            if (production.lhs != entry.non_terminal) continue;
            if (production.steps.len == 0) continue;

            switch (production.steps[0].symbol) {
                .non_terminal => |next_non_terminal| {
                    const remainder = production.steps[1..];
                    var propagated = try if (remainder.len == 0)
                        cloneSymbolSet(allocator, infos[entry.non_terminal].?.lookaheads)
                    else
                        first_sets.firstOfSequence(allocator, remainder);
                    var propagates = false;
                    if (remainder.len == 0) {
                        propagates = infos[entry.non_terminal].?.propagates_lookahead;
                    } else if (propagated.includes_epsilon) {
                        propagates = infos[entry.non_terminal].?.propagates_lookahead;
                        propagated.includes_epsilon = false;
                        _ = mergeSymbolSetLookaheads(&propagated, infos[entry.non_terminal].?.lookaheads);
                    }
                    try stack.append(.{
                        .non_terminal = next_non_terminal,
                        .lookaheads = propagated,
                        .propagates_lookahead = propagates,
                    });
                },
                else => {},
            }
        }
    }

    var additions = std.array_list.Managed(TransitiveClosureAddition).init(allocator);
    defer additions.deinit();

    for (infos, 0..) |maybe_info, non_terminal| {
        const info = maybe_info orelse continue;
        for (productions, 0..) |production, production_id| {
            if (production.augmented) continue;
            if (production.lhs != non_terminal) continue;
            try additions.append(.{
                .production_id = @intCast(production_id),
                .info = .{
                    .lookaheads = try cloneSymbolSet(allocator, info.lookaheads),
                    .propagates_lookahead = info.propagates_lookahead,
                },
            });
        }
    }

    return try additions.toOwnedSlice();
}

fn buildClosureExpansionItemsAlloc(
    allocator: std.mem.Allocator,
    item_set_builder: ParseItemSetBuilder,
    first_sets: first.FirstSets,
    non_terminal: u32,
    inherited_lookahead: ?syntax_ir.SymbolRef,
    options: BuildOptions,
) ![]const item.ParseItemSetEntry {
    var generated = std.array_list.Managed(item.ParseItemSetEntry).init(allocator);
    defer generated.deinit();

    for (item_set_builder.additionsForNonTerminal(non_terminal)) |addition| {
        var effective_follow = try cloneSymbolSet(allocator, addition.info.lookaheads);
        defer freeSymbolSet(allocator, effective_follow);
        effective_follow.includes_epsilon = addition.info.propagates_lookahead;
        try appendGeneratedItems(
            allocator,
            &generated,
            addition.production_id,
            effective_follow,
            inherited_lookahead,
            first_sets,
            options,
        );
    }

    return try generated.toOwnedSlice();
}

fn appendGeneratedItems(
    allocator: std.mem.Allocator,
    generated: *std.array_list.Managed(item.ParseItemSetEntry),
    production_id: item.ProductionId,
    propagated_first: first.SymbolSet,
    inherited_lookahead: ?syntax_ir.SymbolRef,
    first_sets: first.FirstSets,
    options: BuildOptions,
) !void {
    if (options.closure_lookahead_mode == .none) {
        const has_any_signal = propagated_first.includes_epsilon or
            countPresent(propagated_first.terminals) > 0 or
            countPresent(propagated_first.externals) > 0;
        if (has_any_signal) {
            try generated.append(try item.ParseItemSetEntry.initEmpty(
                allocator,
                first_sets.terminals_len,
                first_sets.externals_len,
                item.ParseItem.init(production_id, 0),
            ));
        }
        return;
    }

    for (propagated_first.terminals, 0..) |present, index| {
        if (!present) continue;
        try generated.append(try item.ParseItemSetEntry.withLookahead(
            allocator,
            first_sets.terminals_len,
            first_sets.externals_len,
            item.ParseItem.init(production_id, 0),
            .{ .terminal = @intCast(index) },
        ));
    }

    for (propagated_first.externals, 0..) |present, index| {
        if (!present) continue;
        try generated.append(try item.ParseItemSetEntry.withLookahead(
            allocator,
            first_sets.terminals_len,
            first_sets.externals_len,
            item.ParseItem.init(production_id, 0),
            .{ .external = @intCast(index) },
        ));
    }

    if (propagated_first.includes_epsilon) {
        try generated.append(try item.ParseItemSetEntry.withOptionalLookahead(
            allocator,
            first_sets.terminals_len,
            first_sets.externals_len,
            item.ParseItem.init(production_id, 0),
            inherited_lookahead,
        ));
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

pub const ClosurePressureMode = enum {
    none,
    thresholded_lr0,
};

pub const ClosurePressureThresholds = struct {
    max_closure_items: usize = 0,
    max_duplicate_hits: usize = 0,
    max_contexts_per_non_terminal: usize = 0,

    pub fn enabled(self: @This()) bool {
        return self.max_closure_items != 0 or
            self.max_duplicate_hits != 0 or
            self.max_contexts_per_non_terminal != 0;
    }
};

pub const CoarseTransitionSpec = struct {
    source_state_id: state.StateId,
    symbol: syntax_ir.SymbolRef,
};

pub const BuildOptions = struct {
    closure_lookahead_mode: ClosureLookaheadMode = .full,
    closure_pressure_mode: ClosurePressureMode = .none,
    closure_pressure_thresholds: ClosurePressureThresholds = .{},
    coarse_transitions: []const CoarseTransitionSpec = &.{},
};

fn shouldUseCoarseTransition(options: BuildOptions, source_state_id: state.StateId, symbol: syntax_ir.SymbolRef) bool {
    for (options.coarse_transitions) |spec| {
        if (spec.source_state_id != source_state_id) continue;
        if (!symbolRefEql(spec.symbol, symbol)) continue;
        return true;
    }
    return false;
}

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
    std.debug.print("[parse_table/build] buildStatesWithOptions enter\n", .{});
    try validateSupportedSubset(grammar);

    var timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/build] stage compute_first_sets\n", .{});
    if (progress_log) logBuildStart("compute_first_sets");
    const first_sets = try first.computeFirstSets(allocator, grammar);
    if (progress_log) maybeLogBuildDone("compute_first_sets", if (timer) |*value| value else null);

    timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/build] stage collect_productions\n", .{});
    if (progress_log) logBuildStart("collect_productions");
    const productions = try collectProductions(allocator, grammar);
    if (progress_log) {
        maybeLogBuildDone("collect_productions", if (timer) |*value| value else null);
        logBuildSummary("collect_productions summary productions={d}", .{productions.len});
    }

    var item_set_builder = try ParseItemSetBuilder.init(allocator, productions, first_sets);
    defer item_set_builder.deinit();

    timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/build] stage construct_states\n", .{});
    if (progress_log) logBuildStart("construct_states");
    const constructed = try constructStates(allocator, grammar.variables, productions, first_sets, item_set_builder, options);
    if (progress_log) {
        maybeLogBuildDone("construct_states", if (timer) |*value| value else null);
        logBuildSummary(
            "construct_states summary states={d} action_states={d}",
            .{ constructed.states.len, constructed.actions.states.len },
        );
    }

    timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/build] stage group_action_table\n", .{});
    if (progress_log) logBuildStart("group_action_table");
    const grouped_actions = try actions.groupActionTable(allocator, constructed.actions);
    if (progress_log) maybeLogBuildDone("group_action_table", if (timer) |*value| value else null);

    timer = maybeStartTimer(progress_log);
    std.debug.print("[parse_table/build] stage resolve_action_table\n", .{});
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

const TransitionBuildStats = struct {
    transition_count: usize = 0,
    new_state_count: usize = 0,
    reused_state_count: usize = 0,
    largest_new_state_items: usize = 0,
    largest_new_state_symbol: ?syntax_ir.SymbolRef = null,
    largest_reused_state_items: usize = 0,
    largest_reused_state_symbol: ?syntax_ir.SymbolRef = null,
};

const SuccessorDiagnostic = struct {
    source_state_id: state.StateId,
    symbol: syntax_ir.SymbolRef,
    item_count: usize,
    reused: bool,
};

fn findClosureResultCache(
    entries: []const ClosureResultCacheEntry,
    seed_items: []const item.ParseItemSetEntry,
) ?[]const item.ParseItemSetEntry {
    for (entries) |entry| {
        if (itemsEql(entry.seed_items, seed_items)) return entry.closed_items;
    }
    return null;
}

fn countDistinctSeedCores(entries: []const ClosureResultCacheEntry, seed_items: []const item.ParseItemSetEntry) usize {
    var count: usize = 0;
    for (entries, 0..) |entry, index| {
        if (!sameSeedCore(entry.seed_items, seed_items)) continue;
        var already_seen = false;
        var previous: usize = 0;
        while (previous < index) : (previous += 1) {
            if (!sameSeedCore(entries[previous].seed_items, seed_items)) continue;
            already_seen = true;
            break;
        }
        if (!already_seen) count += 1;
    }
    return count;
}

fn sameSeedCore(left: []const item.ParseItemSetEntry, right: []const item.ParseItemSetEntry) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.item.production_id != b.item.production_id) return false;
        if (a.item.step_index != b.item.step_index) return false;
    }
    return true;
}

fn logSuccessorDiagnostic(label: []const u8, variables: []const syntax_ir.SyntaxVariable, diagnostic: SuccessorDiagnostic) void {
    var symbol_buf: [128]u8 = undefined;
    const symbol_text = symbolDisplayText(&symbol_buf, variables, diagnostic.symbol);
    logBuildSummary(
        "{s} source_state={d} symbol={s} items={d} reused={}",
        .{ label, diagnostic.source_state_id, symbol_text, diagnostic.item_count, diagnostic.reused },
    );
}

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

test "ParseItemSetBuilder precomputes transitive closure additions with propagated follow sets" {
    testLog("ParseItemSetBuilder precomputes transitive closure additions with propagated follow sets");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var a_to_b_c_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .terminal = 2 } },
    };
    var a_to_d_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    var b_to_e_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{
                .name = "A",
                .kind = .named,
                .productions = &.{
                    .{ .steps = a_to_b_c_steps[0..] },
                    .{ .steps = a_to_d_steps[0..] },
                },
            },
            .{
                .name = "B",
                .kind = .named,
                .productions = &.{
                    .{ .steps = b_to_e_steps[0..] },
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

    const first_sets = try first.computeFirstSets(arena.allocator(), grammar);
    const productions = try collectProductions(arena.allocator(), grammar);
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets);
    defer item_set_builder.deinit();

    const additions = item_set_builder.additionsForNonTerminal(1);
    try std.testing.expectEqual(@as(usize, 3), additions.len);

    var saw_a_to_b_c = false;
    var saw_a_to_d = false;
    var saw_b_to_e = false;

    for (additions) |addition| {
        switch (addition.production_id) {
            2 => {
                saw_a_to_b_c = true;
                try std.testing.expect(addition.info.propagates_lookahead);
                try std.testing.expect(!addition.info.lookaheads.containsTerminal(2));
            },
            3 => {
                saw_a_to_d = true;
                try std.testing.expect(addition.info.propagates_lookahead);
                try std.testing.expect(!addition.info.lookaheads.containsTerminal(2));
            },
            4 => {
                saw_b_to_e = true;
                try std.testing.expect(!addition.info.propagates_lookahead);
                try std.testing.expect(addition.info.lookaheads.containsTerminal(2));
            },
            else => return error.UnexpectedProductionId,
        }
    }

    try std.testing.expect(saw_a_to_b_c);
    try std.testing.expect(saw_a_to_d);
    try std.testing.expect(saw_b_to_e);
}

test "closure uses precomputed transitive additions to expand leading recursive items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var a_to_b_c_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .terminal = 2 } },
    };
    var a_to_d_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    var b_to_e_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{
                .name = "A",
                .kind = .named,
                .productions = &.{
                    .{ .steps = a_to_b_c_steps[0..] },
                    .{ .steps = a_to_d_steps[0..] },
                },
            },
            .{
                .name = "B",
                .kind = .named,
                .productions = &.{
                    .{ .steps = b_to_e_steps[0..] },
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

    const first_sets = try first.computeFirstSets(arena.allocator(), grammar);
    const productions = try collectProductions(arena.allocator(), grammar);
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets);
    defer item_set_builder.deinit();

    const seed = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(arena.allocator(), first_sets.terminals_len, first_sets.externals_len, item.ParseItem.init(1, 0), .{ .terminal = 0 }),
    };
    const items = try closure(
        arena.allocator(),
        grammar.variables,
        productions,
        first_sets,
        item_set_builder,
        seed[0..],
        .{},
    );

    try std.testing.expect(findParseItem(items, item.ParseItem.init(1, 0), .{ .terminal = 0 }) != null);
    try std.testing.expect(findParseItem(items, item.ParseItem.init(2, 0), .{ .terminal = 0 }) != null);
    try std.testing.expect(findParseItem(items, item.ParseItem.init(3, 0), .{ .terminal = 0 }) != null);
    try std.testing.expect(findParseItem(items, item.ParseItem.init(4, 0), .{ .terminal = 2 }) != null);
}

fn findParseItem(items: []const item.ParseItemSetEntry, needle: item.ParseItem, lookahead: syntax_ir.SymbolRef) ?usize {
    for (items, 0..) |candidate, index| {
        if (item.ParseItem.eql(candidate.item, needle) and item.containsLookahead(candidate.lookaheads, lookahead)) return index;
    }
    return null;
}

fn constructStates(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    item_set_builder: ParseItemSetBuilder,
    options: BuildOptions,
) BuildError!ConstructedStates {
    const progress_log = shouldLogBuildProgress();
    std.debug.print("[parse_table/build] constructStates enter\n", .{});
    var states = std.array_list.Managed(state.ParseState).init(allocator);
    defer states.deinit();
    var state_ids_by_item_set = StateIdByItemSet.init(allocator);
    defer state_ids_by_item_set.deinit();
    var action_states = std.array_list.Managed(actions.StateActions).init(allocator);
    defer action_states.deinit();
    var closure_result_cache = std.array_list.Managed(ClosureResultCacheEntry).init(allocator);
    defer closure_result_cache.deinit();
    var closed_items_by_seed = ClosedItemsBySeed.init(allocator);
    defer closed_items_by_seed.deinit();
    var closure_cache_hits: usize = 0;
    var closure_cache_misses: usize = 0;
    var closure_cache_core_match_misses: usize = 0;
    var largest_new_successor: ?SuccessorDiagnostic = null;
    var largest_reused_successor: ?SuccessorDiagnostic = null;

    var start_timer = maybeStartTimer(progress_log);
    if (progress_log) logBuildStart("construct_states.initial_closure");
    const start_seed = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(allocator, first_sets.terminals_len, first_sets.externals_len, item.ParseItem.init(0, 0)),
    };
    const start_items = try closure(allocator, variables, productions, first_sets, item_set_builder, start_seed[0..], options);
    std.debug.print("[parse_table/build] constructStates initial_closure_done items={d}\n", .{start_items.len});
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
    try state_ids_by_item_set.put(start_items, 0);

    var next_state_index: usize = 0;
    var next_progress_report: usize = 10;
    while (next_state_index < states.items.len) : (next_state_index += 1) {
        if (next_state_index < 5 or (next_state_index + 1) % 100 == 0) {
            std.debug.print(
                "[parse_table/build] constructStates state_begin index={d} state_id={d} items={d} discovered={d}\n",
                .{
                    next_state_index,
                    states.items[next_state_index].id,
                    states.items[next_state_index].items.len,
                    states.items.len,
                },
            );
        }
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
        var transition_stats = TransitionBuildStats{};
        const transitions = try collectTransitionsForState(
            allocator,
            variables,
            productions,
            first_sets,
            item_set_builder,
            &states,
            &state_ids_by_item_set,
            &closure_result_cache,
            &closed_items_by_seed,
            &closure_cache_hits,
            &closure_cache_misses,
            &closure_cache_core_match_misses,
            states.items[next_state_index].items,
            states.items[next_state_index].id,
            &largest_new_successor,
            &largest_reused_successor,
            &transition_stats,
            options,
        );
        if (next_state_index < 5 or (next_state_index + 1) % 100 == 0) {
            std.debug.print(
                "[parse_table/build] constructStates state_after_transitions index={d} transitions={d} discovered={d}\n",
                .{ next_state_index, transitions.len, states.items.len },
            );
        }
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
        if (next_state_index < 5 or (next_state_index + 1) % 100 == 0) {
            std.debug.print(
                "[parse_table/build] constructStates state_done index={d} conflicts={d} action_entries={d} discovered={d}\n",
                .{ next_state_index, detected_conflicts.len, state_actions.len, states.items.len },
            );
        }

        if (progress_log and next_state_index + 1 >= next_progress_report) {
            logBuildSummary(
                "construct_states progress processed={d} discovered={d} closure_cache_hits={d} closure_cache_misses={d} core_match_misses={d}",
                .{ next_state_index + 1, states.items.len, closure_cache_hits, closure_cache_misses, closure_cache_core_match_misses },
            );
            next_progress_report += if (next_progress_report < 100) 10 else 100;
        }

        if (progress_log and (transition_stats.new_state_count > 0 or transition_stats.transition_count >= 16)) {
            var largest_new_symbol_buf: [64]u8 = undefined;
            var largest_reused_symbol_buf: [64]u8 = undefined;
            const largest_new_symbol = optionalSymbolRefText(&largest_new_symbol_buf, transition_stats.largest_new_state_symbol);
            const largest_reused_symbol = optionalSymbolRefText(&largest_reused_symbol_buf, transition_stats.largest_reused_state_symbol);
            logBuildSummary(
                "construct_states state_id={d} transitions={d} new_states={d} reused_states={d} largest_new_items={d} largest_new_symbol={s} largest_reused_items={d} largest_reused_symbol={s}",
                .{
                    mutable_states[next_state_index].id,
                    transition_stats.transition_count,
                    transition_stats.new_state_count,
                    transition_stats.reused_state_count,
                    transition_stats.largest_new_state_items,
                    largest_new_symbol,
                    transition_stats.largest_reused_state_items,
                    largest_reused_symbol,
                },
            );
        }
    }

    state.sortStates(states.items);
    std.debug.print("[parse_table/build] constructStates complete states={d}\n", .{states.items.len});
    if (progress_log) {
        logBuildSummary(
            "construct_states closure_cache summary hits={d} misses={d} core_match_misses={d} entries={d}",
            .{ closure_cache_hits, closure_cache_misses, closure_cache_core_match_misses, closure_result_cache.items.len },
        );
        if (largest_new_successor) |diagnostic| {
            logSuccessorDiagnostic("construct_states largest_new_successor", variables, diagnostic);
        }
        if (largest_reused_successor) |diagnostic| {
            logSuccessorDiagnostic("construct_states largest_reused_successor", variables, diagnostic);
        }
    }
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
    item_set_builder: ParseItemSetBuilder,
    states: *std.array_list.Managed(state.ParseState),
    state_ids_by_item_set: *StateIdByItemSet,
    closure_result_cache: *std.array_list.Managed(ClosureResultCacheEntry),
    closed_items_by_seed: *ClosedItemsBySeed,
    closure_cache_hits: *usize,
    closure_cache_misses: *usize,
    closure_cache_core_match_misses: *usize,
    state_items: []const item.ParseItemSetEntry,
    source_state_id: state.StateId,
    largest_new_successor: *?SuccessorDiagnostic,
    largest_reused_successor: *?SuccessorDiagnostic,
    stats: *TransitionBuildStats,
    options: BuildOptions,
) BuildError![]const state.Transition {
    var transitions = std.array_list.Managed(state.Transition).init(allocator);
    defer transitions.deinit();
    var successor_group_indexes = SymbolIndexMap.init(allocator);
    defer successor_group_indexes.deinit();
    var successor_groups = std.array_list.Managed(SuccessorGroup).init(allocator);
    defer {
        for (successor_groups.items) |*group| group.deinit();
        successor_groups.deinit();
    }

    for (state_items) |entry| {
        const parse_item = entry.item;
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) continue;
        const symbol = production.steps[parse_item.step_index].symbol;
        const group_index = blk: {
            const result = try successor_group_indexes.getOrPut(symbol);
            if (result.found_existing) break :blk result.value_ptr.*;
            const new_index = successor_groups.items.len;
            try successor_groups.append(SuccessorGroup.init(allocator, symbol));
            result.value_ptr.* = @intCast(new_index);
            break :blk new_index;
        };

        const successor_entry = item.ParseItemSetEntry{
            .item = .{
                .production_id = parse_item.production_id,
                .step_index = parse_item.step_index + 1,
            },
            .lookaheads = try cloneSymbolSet(allocator, entry.lookaheads),
        };

        const group = &successor_groups.items[group_index];
        const item_index = try group.item_indexes.getOrPut(successor_entry.item);
        if (item_index.found_existing) {
            _ = mergeSymbolSetLookaheads(&group.items.items[item_index.value_ptr.*].lookaheads, successor_entry.lookaheads);
            freeSymbolSet(allocator, successor_entry.lookaheads);
        } else {
            item_index.value_ptr.* = group.items.items.len;
            try group.items.append(successor_entry);
        }
    }

    for (successor_groups.items) |*group| {
        const symbol = group.symbol;
        state.sortItems(group.items.items);

        const advanced_items = blk: {
            const prior_transition_context = current_transition_context;
            setCurrentTransitionContext(.{
                .source_state_id = source_state_id,
                .symbol = symbol,
            });
            defer setCurrentTransitionContext(prior_transition_context);
            var transition_options = options;
            if (shouldUseCoarseTransition(options, source_state_id, symbol)) {
                transition_options.closure_lookahead_mode = .none;
                if (shouldLogBuildProgress()) {
                    var symbol_buf: [128]u8 = undefined;
                    const symbol_text = symbolDisplayText(&symbol_buf, variables, symbol);
                    logBuildSummary(
                        "construct_states applying coarse_transition source_state={d} symbol={s}",
                        .{ source_state_id, symbol_text },
                    );
                }
            }
            break :blk try gotoItems(
                allocator,
                variables,
                productions,
                first_sets,
                item_set_builder,
                closure_result_cache,
                closed_items_by_seed,
                closure_cache_hits,
                closure_cache_misses,
                closure_cache_core_match_misses,
                group.items.items,
                transition_options,
            );
        };
        stats.transition_count += 1;
        if (state_ids_by_item_set.get(advanced_items)) |existing_id| {
            stats.reused_state_count += 1;
            if (advanced_items.len > stats.largest_reused_state_items) {
                stats.largest_reused_state_items = advanced_items.len;
                stats.largest_reused_state_symbol = symbol;
            }
            if (largest_reused_successor.* == null or advanced_items.len > largest_reused_successor.*.?.item_count) {
                largest_reused_successor.* = .{
                    .source_state_id = source_state_id,
                    .symbol = symbol,
                    .item_count = advanced_items.len,
                    .reused = true,
                };
                if (shouldLogBuildProgress()) {
                    logSuccessorDiagnostic("construct_states update largest_reused_successor", variables, largest_reused_successor.*.?);
                }
            }
            try transitions.append(.{ .symbol = symbol, .state = existing_id });
            continue;
        }

        const new_id: state.StateId = @intCast(states.items.len);
        stats.new_state_count += 1;
        if (advanced_items.len > stats.largest_new_state_items) {
            stats.largest_new_state_items = advanced_items.len;
            stats.largest_new_state_symbol = symbol;
        }
        if (largest_new_successor.* == null or advanced_items.len > largest_new_successor.*.?.item_count) {
            largest_new_successor.* = .{
                .source_state_id = source_state_id,
                .symbol = symbol,
                .item_count = advanced_items.len,
                .reused = false,
            };
            if (shouldLogBuildProgress()) {
                logSuccessorDiagnostic("construct_states update largest_new_successor", variables, largest_new_successor.*.?);
            }
        }
        try states.append(.{
            .id = new_id,
            .items = advanced_items,
            .transitions = &.{},
            .conflicts = &.{},
        });
        try state_ids_by_item_set.put(advanced_items, new_id);
        try transitions.append(.{ .symbol = symbol, .state = new_id });
    }

    state.sortTransitions(transitions.items);
    return try transitions.toOwnedSlice();
}

test "buildStates records LR(0)-style conflicts for an ambiguous expression grammar" {
    testLog("buildStates records LR(0)-style conflicts for an ambiguous expression grammar");
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
    item_set_builder: ParseItemSetBuilder,
    seed_items: []const item.ParseItemSetEntry,
    options: BuildOptions,
) BuildError![]const item.ParseItemSetEntry {
    const progress_log = shouldLogBuildProgress();
    const context_log = shouldLogBuildContexts();
    const variable_count = variableCountFromProductions(productions);
    var effective_closure_lookahead_mode = options.closure_lookahead_mode;
    var pressure_triggered = false;
    var items = std.array_list.Managed(item.ParseItemSetEntry).init(allocator);
    defer items.deinit();
    var expansion_cache = std.array_list.Managed(ClosureExpansionCacheEntry).init(allocator);
    defer expansion_cache.deinit();
    try items.appendSlice(seed_items);
    state.sortItems(items.items);
    var item_set = ParseItemSet.init(allocator);
    defer item_set.deinit();
    for (items.items) |existing_item| {
        try item_set.put(existing_item, {});
    }

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
            const parse_entry = items.items[cursor];
            const parse_item = parse_entry.item;
            const inherited_lookahead = singleLookahead(parse_entry.lookaheads);
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
                        effective_closure_lookahead_mode,
                        suffix_first,
                        inherited_lookahead,
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
                            item_set_builder,
                            first_sets,
                            non_terminal,
                            inherited_lookahead,
                            .{
                                .closure_lookahead_mode = effective_closure_lookahead_mode,
                            },
                        );
                        try expansion_cache.append(.{
                            .non_terminal = non_terminal,
                            .closure_lookahead_mode = effective_closure_lookahead_mode,
                            .propagated_first = try cloneSymbolSet(allocator, suffix_first),
                            .inherited_lookahead = inherited_lookahead,
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
                                const lookahead_text = optionalSymbolRefText(&lookahead_buf, inherited_lookahead);
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

                    const append_timer = maybeStartTimer(progress_log);
                    const append_stats = try appendGeneratedItemsToClosure(&items, &item_set, generated_items);
                    if (append_timer) |timer_snapshot| {
                        var timer_value = timer_snapshot;
                        const append_ns = timer_value.read();
                        if (append_ns >= 100 * std.time.ns_per_ms) {
                            const append_ms = @as(f64, @floatFromInt(append_ns)) / @as(f64, std.time.ns_per_ms);
                            logBuildSummary(
                                "closure slow_append non_terminal={d} name={s} generated_items={d} existing_items={d} added={d} duplicate_checks={d} duplicate_hits={d} ({d:.2} ms)",
                                .{
                                    non_terminal,
                                    if (non_terminal < variables.len) variables[non_terminal].name else "<unknown>",
                                    generated_items.len,
                                    items.items.len,
                                    append_stats.added,
                                    append_stats.duplicate_checks,
                                    append_stats.duplicate_hits,
                                    append_ms,
                                },
                            );
                        }
                    }
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
                    if (!pressure_triggered and effective_closure_lookahead_mode == .full) {
                        const context_count = if (non_terminal < cache_misses.len) cache_misses[non_terminal] else 0;
                        const duplicate_hit_count = if (non_terminal < duplicate_hits.len) duplicate_hits[non_terminal] else 0;
                        if (closurePressureTrigger(options, items.items.len, duplicate_hit_count, context_count)) |trigger| {
                            effective_closure_lookahead_mode = .none;
                            pressure_triggered = true;
                            if (progress_log) {
                                logBuildSummary(
                                    "closure pressure_trigger round={d} cursor={d}/{d} non_terminal={d} name={s} reason={s} value={d} threshold={d} items={d}",
                                    .{
                                        round,
                                        cursor + 1,
                                        items.items.len,
                                        non_terminal,
                                        if (non_terminal < variables.len) variables[non_terminal].name else "<unknown>",
                                        trigger.reason,
                                        trigger.current_value,
                                        trigger.threshold,
                                        items.items.len,
                                    },
                                );
                            }
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
        logBuildSummary(
            "closure complete rounds={d} items={d} closure_lookahead_mode={s}",
            .{
                round,
                items.items.len,
                if (effective_closure_lookahead_mode == .full) "full" else "none",
            },
        );
    }

    return try items.toOwnedSlice();
}

fn gotoItems(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    item_set_builder: ParseItemSetBuilder,
    closure_result_cache: *std.array_list.Managed(ClosureResultCacheEntry),
    closed_items_by_seed: *ClosedItemsBySeed,
    closure_cache_hits: *usize,
    closure_cache_misses: *usize,
    closure_cache_core_match_misses: *usize,
    seed_items: []const item.ParseItemSetEntry,
    options: BuildOptions,
) BuildError![]const item.ParseItemSetEntry {
    if (closed_items_by_seed.get(seed_items)) |cached| {
        closure_cache_hits.* += 1;
        return cached;
    }

    closure_cache_misses.* += 1;
    if (countDistinctSeedCores(closure_result_cache.items, seed_items) > 0) {
        closure_cache_core_match_misses.* += 1;
        if (shouldLogBuildProgress() and seed_items.len >= 12) {
            logBuildSummary(
                "closure_result_cache core_miss seed_items={d} cache_entries={d} core_match_misses={d}",
                .{ seed_items.len, closure_result_cache.items.len, closure_cache_core_match_misses.* },
            );
        }
    }

    const seed_copy = try allocator.dupe(item.ParseItemSetEntry, seed_items);
    const closed_items = try closure(allocator, variables, productions, first_sets, item_set_builder, seed_items, options);
    try closure_result_cache.append(.{
        .seed_items = seed_copy,
        .closed_items = closed_items,
    });
    try closed_items_by_seed.put(seed_copy, closed_items);
    return closed_items;
}

fn appendGeneratedItemsToClosure(
    items: *std.array_list.Managed(item.ParseItemSetEntry),
    item_set: *ParseItemSet,
    generated_items: []const item.ParseItemSetEntry,
) BuildError!AppendStats {
    var stats = AppendStats{
        .changed = false,
        .added = 0,
        .duplicate_checks = 0,
        .duplicate_hits = 0,
    };

    for (generated_items) |new_item| {
        const duplicate = item_set.contains(new_item);
        stats.duplicate_checks += 1;
        if (duplicate) {
            stats.duplicate_hits += 1;
        } else {
            try items.append(new_item);
            try item_set.put(new_item, {});
            stats.changed = true;
            stats.added += 1;
        }
    }

    return stats;
}

fn containsTransition(transitions: []const state.Transition, symbol: syntax_ir.SymbolRef) bool {
    for (transitions) |entry| {
        if (symbolRefEql(entry.symbol, symbol)) return true;
    }
    return false;
}

fn findState(states: []const state.ParseState, candidate_items: []const item.ParseItemSetEntry) ?state.ParseState {
    for (states) |parse_state| {
        if (itemsEql(parse_state.items, candidate_items)) return parse_state;
    }
    return null;
}

fn itemsEql(left: []const item.ParseItemSetEntry, right: []const item.ParseItemSetEntry) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!item.ParseItemSetEntry.eql(a, b)) return false;
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
    testLog("buildStates constructs deterministic LR(0)-style states for a tiny grammar");
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
    testLog("buildStates propagates terminal lookaheads through nullable suffix closure");
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
        if (parse_item.item.production_id == 2 and hasTerminalLookahead(parse_item, 1)) {
            saw_start_with_terminal_lookahead = true;
        }
        if (parse_item.item.production_id == 3 and hasTerminalLookahead(parse_item, 1)) {
            saw_expr_with_terminal_lookahead = true;
        }
    }

    try std.testing.expect(saw_start_with_terminal_lookahead);
    try std.testing.expect(saw_expr_with_terminal_lookahead);
}

fn hasTerminalLookahead(parse_item: item.ParseItemSetEntry, terminal_index: u32) bool {
    return item.containsLookahead(parse_item.lookaheads, .{ .terminal = terminal_index });
}

test "buildStates allows inert step metadata in the current supported subset" {
    testLog("buildStates allows inert step metadata in the current supported subset");
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
    testLog("buildStates accepts dynamic precedence metadata in the current supported subset");
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

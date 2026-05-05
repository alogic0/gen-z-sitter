const std = @import("std");
const actions = @import("actions.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const first = @import("first.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const conflicts = @import("conflicts.zig");
const resolution = @import("resolution.zig");
const conflict_resolution = @import("conflict_resolution.zig");
const minimize = @import("minimize.zig");
const rules = @import("../ir/rules.zig");
const runtime_io = @import("../support/runtime_io.zig");
const process_inlines = @import("process_inlines.zig");

threadlocal var scoped_progress_enabled: bool = false;
threadlocal var current_transition_context: ?TransitionContext = null;
threadlocal var construct_profile_enabled: bool = false;
threadlocal var construct_profile: ConstructProfile = .{};
threadlocal var build_env_flags_loaded: bool = false;
threadlocal var build_env_flags: BuildEnvFlags = .{};

const TransitionContext = struct {
    source_state_id: state.StateId,
    symbol: syntax_ir.SymbolRef,
};

pub const ConstructProfile = struct {
    states_processed: usize = 0,
    successor_groups: usize = 0,
    successor_seed_items: usize = 0,
    successor_group_new: usize = 0,
    successor_item_appends: usize = 0,
    successor_item_merges: usize = 0,
    transition_slices: usize = 0,
    transition_slice_items: usize = 0,
    transition_slice_bytes: usize = 0,
    extra_transition_slices: usize = 0,
    extra_transition_slice_items: usize = 0,
    extra_transition_slice_bytes: usize = 0,
    state_intern_calls: usize = 0,
    state_intern_reused: usize = 0,
    state_intern_new: usize = 0,
    state_items_stored: usize = 0,
    closure_cache_hits: usize = 0,
    closure_cache_misses: usize = 0,
    closure_seed_dupes: usize = 0,
    closure_seed_items: usize = 0,
    closure_seed_bytes: usize = 0,
    closure_runs: usize = 0,
    closure_items_stored: usize = 0,
    closure_items_returned: usize = 0,
    closure_expansion_cache_hits: usize = 0,
    closure_expansion_cache_misses: usize = 0,
    closure_expansion_cache_scanned: usize = 0,
    closure_expansion_cache_entries: usize = 0,
    closure_append_added: usize = 0,
    closure_append_duplicate_checks: usize = 0,
    closure_append_duplicate_hits: usize = 0,
    closure_append_ns: u64 = 0,
    successor_seed_cache_hits: usize = 0,
    successor_seed_cache_misses: usize = 0,
    successor_seed_cache_entries: usize = 0,
    item_set_hash_calls: usize = 0,
    item_set_hash_entries: usize = 0,
    item_set_eql_calls: usize = 0,
    item_set_eql_entries: usize = 0,
    symbol_set_init_empty_count: usize = 0,
    symbol_set_clone_count: usize = 0,
    symbol_set_free_count: usize = 0,
    symbol_set_alloc_bytes: usize = 0,
    symbol_set_free_bytes: usize = 0,
    collect_transitions_ns: u64 = 0,
    extra_transitions_ns: u64 = 0,
    reserved_word_ns: u64 = 0,
    build_actions_ns: u64 = 0,
    detect_conflicts_ns: u64 = 0,
};

const BuildEnvFlags = struct {
    trace_top_comment: bool = false,
    build_progress: bool = false,
    progress: bool = false,
    global_progress: bool = false,
    context_log: bool = false,
    lex_state_merge_trace: bool = false,
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

fn envUsizeRaw(name: []const u8, default_value: usize) usize {
    const value = std.process.Environ.getAlloc(runtime_io.environ(), std.heap.page_allocator, name) catch return default_value;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return default_value;
    return std.fmt.parseUnsigned(usize, value, 10) catch default_value;
}

fn ensureBuildEnvFlags() void {
    if (build_env_flags_loaded) return;
    build_env_flags = .{
        .trace_top_comment = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_TRACE_TOP_COMMENT"),
        .build_progress = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_BUILD_PROGRESS"),
        .progress = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_PROGRESS"),
        .global_progress = envFlagEnabledRaw("GEN_Z_SITTER_PROGRESS"),
        .context_log = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_CONTEXT_LOG"),
        .lex_state_merge_trace = envFlagEnabledRaw("GEN_Z_SITTER_LEX_STATE_MERGE_TRACE"),
        .profile = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_PROFILE"),
        .has_target_filter = hasProgressTargetFilterRaw(),
    };
    build_env_flags_loaded = true;
}

fn hasProgressTargetFilter() bool {
    ensureBuildEnvFlags();
    return build_env_flags.has_target_filter;
}

pub fn setScopedProgressEnabled(enabled: bool) void {
    scoped_progress_enabled = enabled;
}

fn shouldTraceHotspot() bool {
    ensureBuildEnvFlags();
    if (!build_env_flags.trace_top_comment) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn shouldLogBuildProgress() bool {
    ensureBuildEnvFlags();
    const requested =
        build_env_flags.build_progress or
        build_env_flags.progress or
        build_env_flags.global_progress;
    if (!requested) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn shouldLogBuildContexts() bool {
    ensureBuildEnvFlags();
    if (!build_env_flags.context_log) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn shouldTraceLexStateMerges() bool {
    ensureBuildEnvFlags();
    if (!build_env_flags.lex_state_merge_trace) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn shouldProfileBuild() bool {
    ensureBuildEnvFlags();
    if (!build_env_flags.profile) return false;
    if (hasProgressTargetFilter() and !scoped_progress_enabled) return false;
    return true;
}

fn logBuildStart(step: []const u8) void {
    std.debug.print("[parse_table_build] start {s}\n", .{step});
}

fn logBuildDone(step: []const u8) void {
    std.debug.print("[parse_table_build] done  {s}\n", .{step});
}

fn maybeStartTimer(enabled: bool) bool {
    return enabled;
}

fn maybeLogBuildDone(step: []const u8, enabled: bool) void {
    if (enabled) logBuildDone(step);
}

fn logBuildSummary(comptime format: []const u8, args: anytype) void {
    std.debug.print("[parse_table_build] " ++ format ++ "\n", args);
}

fn profileTimer(enabled: bool) ?std.Io.Timestamp {
    if (!enabled) return null;
    return std.Io.Timestamp.now(runtime_io.get(), .awake);
}

fn logProfileDone(step: []const u8, timer: ?std.Io.Timestamp) void {
    const start = timer orelse return;
    const elapsed_ms = @as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake)).nanoseconds)) /
        @as(f64, std.time.ns_per_ms);
    std.debug.print("[parse_table_profile] stage={s} elapsed_ms={d:.2}\n", .{ step, elapsed_ms });
}

fn addProfileDuration(accumulator: *u64, timer: ?std.Io.Timestamp) void {
    const start = timer orelse return;
    const duration = start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake));
    accumulator.* += @intCast(duration.nanoseconds);
}

fn logSymbolSetProfile() void {
    const profile = item.symbolSetProfile();
    std.debug.print(
        "[parse_table_profile] symbol_sets init_empty={d} clone={d} free={d} bit_alloc_mb={d:.2} bit_free_mb={d:.2}\n",
        .{
            profile.init_empty_count,
            profile.clone_count,
            profile.free_count,
            @as(f64, @floatFromInt(profile.bool_alloc_bytes)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(profile.bool_free_bytes)) / (1024.0 * 1024.0),
        },
    );
}

fn resetConstructProfile() void {
    construct_profile = .{};
}

fn logConstructProfile() void {
    const profile = construct_profile;
    std.debug.print(
        "[parse_table_profile] construct states={d} successor_groups={d} seed_items={d} intern_calls={d} intern_new={d} intern_reused={d} closure_hits={d} closure_misses={d} closure_items_returned={d}\n",
        .{
            profile.states_processed,
            profile.successor_groups,
            profile.successor_seed_items,
            profile.state_intern_calls,
            profile.state_intern_new,
            profile.state_intern_reused,
            profile.closure_cache_hits,
            profile.closure_cache_misses,
            profile.closure_items_returned,
        },
    );
    std.debug.print(
        "[parse_table_profile] construct_alloc successor_group_new={d} successor_appends={d} successor_merges={d} transition_slices={d} transition_items={d} transition_mb={d:.2} extra_transition_slices={d} extra_transition_items={d} extra_transition_mb={d:.2}\n",
        .{
            profile.successor_group_new,
            profile.successor_item_appends,
            profile.successor_item_merges,
            profile.transition_slices,
            profile.transition_slice_items,
            @as(f64, @floatFromInt(profile.transition_slice_bytes)) / (1024.0 * 1024.0),
            profile.extra_transition_slices,
            profile.extra_transition_slice_items,
            @as(f64, @floatFromInt(profile.extra_transition_slice_bytes)) / (1024.0 * 1024.0),
        },
    );
    std.debug.print(
        "[parse_table_profile] closure_alloc seed_dupes={d} seed_items={d} seed_mb={d:.2} closure_runs={d} closure_items_stored={d} state_items_stored={d}\n",
        .{
            profile.closure_seed_dupes,
            profile.closure_seed_items,
            @as(f64, @floatFromInt(profile.closure_seed_bytes)) / (1024.0 * 1024.0),
            profile.closure_runs,
            profile.closure_items_stored,
            profile.state_items_stored,
        },
    );
    std.debug.print(
        "[parse_table_profile] closure_expansion cache_hits={d} cache_misses={d} scanned={d} entries={d} append_added={d} append_checks={d} append_hits={d} append_ms={d:.2}\n",
        .{
            profile.closure_expansion_cache_hits,
            profile.closure_expansion_cache_misses,
            profile.closure_expansion_cache_scanned,
            profile.closure_expansion_cache_entries,
            profile.closure_append_added,
            profile.closure_append_duplicate_checks,
            profile.closure_append_duplicate_hits,
            @as(f64, @floatFromInt(profile.closure_append_ns)) / @as(f64, std.time.ns_per_ms),
        },
    );
    std.debug.print(
        "[parse_table_profile] successor_seed_cache hits={d} misses={d} entries={d}\n",
        .{
            profile.successor_seed_cache_hits,
            profile.successor_seed_cache_misses,
            profile.successor_seed_cache_entries,
        },
    );
    std.debug.print(
        "[parse_table_profile] item_set_hash hash_calls={d} hash_entries={d} eql_calls={d} eql_entries={d}\n",
        .{
            profile.item_set_hash_calls,
            profile.item_set_hash_entries,
            profile.item_set_eql_calls,
            profile.item_set_eql_entries,
        },
    );
    std.debug.print(
        "[parse_table_profile] construct_time collect_ms={d:.2} extra_ms={d:.2} reserved_ms={d:.2} actions_ms={d:.2} conflicts_ms={d:.2}\n",
        .{
            @as(f64, @floatFromInt(profile.collect_transitions_ns)) / @as(f64, std.time.ns_per_ms),
            @as(f64, @floatFromInt(profile.extra_transitions_ns)) / @as(f64, std.time.ns_per_ms),
            @as(f64, @floatFromInt(profile.reserved_word_ns)) / @as(f64, std.time.ns_per_ms),
            @as(f64, @floatFromInt(profile.build_actions_ns)) / @as(f64, std.time.ns_per_ms),
            @as(f64, @floatFromInt(profile.detect_conflicts_ns)) / @as(f64, std.time.ns_per_ms),
        },
    );
}

fn countPresent(values: first.SymbolBits) usize {
    return values.count();
}

fn optionalSymbolRefFormat(value: ?syntax_ir.SymbolRef, writer: anytype) !void {
    if (value) |symbol| {
        switch (symbol) {
            .end => try writer.writeAll("end"),
            .non_terminal => |index| try writer.print("non_terminal:{d}", .{index}),
            .terminal => |index| try writer.print("terminal:{d}", .{index}),
            .external => |index| try writer.print("external:{d}", .{index}),
        }
    } else {
        try writer.writeAll("none");
    }
}

fn optionalSymbolRefText(buf: []u8, value: ?syntax_ir.SymbolRef) []const u8 {
    if (value) |symbol| {
        return switch (symbol) {
            .end => "end",
            .non_terminal => |index| std.fmt.bufPrint(buf, "non_terminal:{d}", .{index}) catch "format_error",
            .terminal => |index| std.fmt.bufPrint(buf, "terminal:{d}", .{index}) catch "format_error",
            .external => |index| std.fmt.bufPrint(buf, "external:{d}", .{index}) catch "format_error",
        };
    }
    return "none";
}

fn symbolDisplayText(
    buf: []u8,
    variables: []const syntax_ir.SyntaxVariable,
    symbol: syntax_ir.SymbolRef,
) []const u8 {
    switch (symbol) {
        .end => return "end",
        .non_terminal => |index| {
            const name = if (index < variables.len) variables[index].name else "<unknown>";
            return std.fmt.bufPrint(buf, "non_terminal:{d}({s})", .{ index, name }) catch "format_error";
        },
        .terminal => |index| {
            const name = if (index < variables.len) variables[index].name else "<unknown>";
            return std.fmt.bufPrint(buf, "terminal:{d}({s})", .{ index, name }) catch "format_error";
        },
        .external => |index| {
            return std.fmt.bufPrint(buf, "external:{d}", .{index}) catch "format_error";
        },
    }
}

fn setCurrentTransitionContext(context: ?TransitionContext) void {
    current_transition_context = context;
}

fn shouldTraceCurrentClosure() bool {
    if (!shouldTraceHotspot()) return false;
    const context = current_transition_context orelse return false;
    return context.source_state_id == 0 and switch (context.symbol) {
        .non_terminal => |index| index == 23,
        else => false,
    };
}

fn shouldTraceTransition(source_state_id: state.StateId, symbol: syntax_ir.SymbolRef) bool {
    if (!shouldTraceHotspot()) return false;
    return source_state_id == 0 and switch (symbol) {
        .non_terminal => |index| index == 23,
        else => false,
    };
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
        if (value.merge_identity != item.unset_structural_identity) {
            hasher.update(std.mem.asBytes(&value.variable_index));
            hasher.update(std.mem.asBytes(&value.merge_identity));
        } else if (value.structural_identity != item.unset_structural_identity) {
            hasher.update(std.mem.asBytes(&value.variable_index));
            hasher.update(std.mem.asBytes(&value.structural_identity));
        } else {
            hasher.update(std.mem.asBytes(&value.variable_index));
            hasher.update(std.mem.asBytes(&value.production_id));
            hasher.update(std.mem.asBytes(&value.step_index));
        }
        return hasher.final();
    }

    pub fn eql(_: @This(), a: item.ParseItem, b: item.ParseItem) bool {
        return parseItemMergeEql(a, b);
    }
};

fn parseItemMergeEql(a: item.ParseItem, b: item.ParseItem) bool {
    if (a.merge_identity != item.unset_structural_identity and
        b.merge_identity != item.unset_structural_identity)
    {
        return a.variable_index == b.variable_index and a.merge_identity == b.merge_identity;
    }
    return a.variable_index == b.variable_index and a.production_id == b.production_id and a.step_index == b.step_index;
}

const SymbolRefContext = struct {
    pub fn hash(_: @This(), value: syntax_ir.SymbolRef) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag: u8 = switch (value) {
            .end => 3,
            .non_terminal => 0,
            .terminal => 1,
            .external => 2,
        };
        hasher.update(std.mem.asBytes(&tag));
        switch (value) {
            .end => {},
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
        if (construct_profile_enabled) {
            construct_profile.item_set_hash_calls += 1;
            construct_profile.item_set_hash_entries += values.len;
        }
        return hashParseItemSetEntries(values);
    }

    pub fn eql(_: @This(), a: []const item.ParseItemSetEntry, b: []const item.ParseItemSetEntry) bool {
        if (construct_profile_enabled) {
            construct_profile.item_set_eql_calls += 1;
            construct_profile.item_set_eql_entries += @max(a.len, b.len);
        }
        return itemsEql(a, b);
    }
};

fn hashParseItemSetEntries(values: []const item.ParseItemSetEntry) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (values) |value| {
        if (value.item.structural_identity != item.unset_structural_identity) {
            hasher.update(std.mem.asBytes(&value.item.variable_index));
            hasher.update(std.mem.asBytes(&value.item.structural_identity));
        } else {
            hasher.update(std.mem.asBytes(&value.item.variable_index));
            hasher.update(std.mem.asBytes(&value.item.production_id));
            hasher.update(std.mem.asBytes(&value.item.step_index));
        }
        hasher.update(std.mem.asBytes(&value.item.has_preceding_inherited_fields));
        hasher.update(std.mem.asBytes(&value.following_reserved_word_set_id));
        hasher.update(value.lookaheads.terminals.maskBytes());
        hasher.update(value.lookaheads.externals.maskBytes());
        hasher.update(std.mem.asBytes(&value.lookaheads.includes_end));
        hasher.update(std.mem.asBytes(&value.lookaheads.includes_epsilon));
    }
    return hasher.final();
}

const ParseItemSetKey = struct {
    entries: []const item.ParseItemSetEntry,
    hash: u64,

    fn fromEntries(entries: []const item.ParseItemSetEntry) ParseItemSetKey {
        return .{
            .entries = entries,
            .hash = ParseItemSliceContext.hash(ParseItemSliceContext{}, entries),
        };
    }
};

const ParseItemSetKeyContext = struct {
    pub fn hash(_: @This(), value: ParseItemSetKey) u64 {
        return value.hash;
    }

    pub fn eql(_: @This(), a: ParseItemSetKey, b: ParseItemSetKey) bool {
        if (construct_profile_enabled) {
            construct_profile.item_set_eql_calls += 1;
            construct_profile.item_set_eql_entries += @max(a.entries.len, b.entries.len);
        }
        if (a.hash != b.hash) return false;
        return itemsEql(a.entries, b.entries);
    }
};

const ParseItemSetContext = struct {
    pub fn hash(_: @This(), value: item.ParseItemSet) u64 {
        return ParseItemSliceContext.hash(ParseItemSliceContext{}, value.entries);
    }

    pub fn eql(_: @This(), a: item.ParseItemSet, b: item.ParseItemSet) bool {
        if (construct_profile_enabled) {
            construct_profile.item_set_eql_calls += 1;
            construct_profile.item_set_eql_entries += @max(a.entries.len, b.entries.len);
        }
        return itemsEql(a.entries, b.entries);
    }
};

const ParseItemSetCoreContext = struct {
    pub fn hash(_: @This(), value: item.ParseItemSetCore) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (value.items) |core_item| {
            if (core_item.structural_identity != item.unset_structural_identity) {
                hasher.update(std.mem.asBytes(&core_item.variable_index));
                hasher.update(std.mem.asBytes(&core_item.structural_identity));
            } else {
                hasher.update(std.mem.asBytes(&core_item.variable_index));
                hasher.update(std.mem.asBytes(&core_item.production_id));
                hasher.update(std.mem.asBytes(&core_item.step_index));
            }
            hasher.update(std.mem.asBytes(&core_item.has_preceding_inherited_fields));
        }
        return hasher.final();
    }

    pub fn eql(_: @This(), a: item.ParseItemSetCore, b: item.ParseItemSetCore) bool {
        return item.ParseItemSetCore.eql(a, b);
    }
};

const BoolSliceContext = struct {
    pub fn hash(_: @This(), values: []const bool) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(values));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: []const bool, b: []const bool) bool {
        return std.mem.eql(bool, a, b);
    }
};

const StateIdByItemSet = std.HashMap(ParseItemSetKey, state.StateId, ParseItemSetKeyContext, std.hash_map.default_max_load_percentage);
const CoreIdByItemSetCore = std.HashMap(item.ParseItemSetCore, usize, ParseItemSetCoreContext, std.hash_map.default_max_load_percentage);
const SymbolIndexMap = std.HashMap(syntax_ir.SymbolRef, usize, SymbolRefContext, std.hash_map.default_max_load_percentage);
const ClosureItemIndexMap = std.HashMap(item.ParseItem, usize, ParseItemCoreContext, std.hash_map.default_max_load_percentage);
const LexStateIdByTerminalSet = std.HashMap([]const bool, state.LexStateId, BoolSliceContext, std.hash_map.default_max_load_percentage);

const SuccessorGroup = struct {
    symbol: syntax_ir.SymbolRef,
    items: std.array_list.Managed(item.ParseItemSetEntry),

    fn init(allocator: std.mem.Allocator, symbol: syntax_ir.SymbolRef) SuccessorGroup {
        return .{
            .symbol = symbol,
            .items = std.array_list.Managed(item.ParseItemSetEntry).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        self.items.deinit();
    }

    fn findItemIndex(self: @This(), parse_item: item.ParseItem) ?usize {
        for (self.items.items, 0..) |entry, index| {
            if (parseItemMergeEql(entry.item, parse_item)) return index;
        }
        return null;
    }
};

const SuccessorGroups = struct {
    allocator: std.mem.Allocator,
    group_indexes: SymbolIndexMap,
    groups: std.array_list.Managed(SuccessorGroup),

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .group_indexes = SymbolIndexMap.init(allocator),
            .groups = std.array_list.Managed(SuccessorGroup).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        for (self.groups.items) |*group| group.deinit();
        self.groups.deinit();
        self.group_indexes.deinit();
    }

    fn buildFromStateItems(
        self: *@This(),
        state_items: []const item.ParseItemSetEntry,
        productions: []const ProductionInfo,
        item_identity_ids: []const []const u32,
        item_merge_identity_ids: []const []const u32,
        variable_has_fields: []const bool,
        variables_to_inline: []const syntax_ir.SymbolRef,
        inline_map: process_inlines.InlinedProductionMap,
    ) !void {
        for (state_items) |entry| {
            try self.appendSuccessorForEntry(
                entry,
                productions,
                item_identity_ids,
                item_merge_identity_ids,
                variable_has_fields,
                variables_to_inline,
                inline_map,
                0,
            );
        }

        for (self.groups.items) |*group| {
            state.sortItems(group.items.items);
        }
        std.mem.sort(SuccessorGroup, self.groups.items, {}, successorGroupLessThan);
    }

    fn appendSuccessorForEntry(
        self: *@This(),
        entry: item.ParseItemSetEntry,
        productions: []const ProductionInfo,
        item_identity_ids: []const []const u32,
        item_merge_identity_ids: []const []const u32,
        variable_has_fields: []const bool,
        variables_to_inline: []const syntax_ir.SymbolRef,
        inline_map: process_inlines.InlinedProductionMap,
        depth: usize,
    ) !void {
        const parse_item = entry.item;
        const production = productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) return;
        const symbol = production.steps[parse_item.step_index].symbol;

        switch (symbol) {
            .non_terminal => |non_terminal| {
                if (isNonTerminalInline(variables_to_inline, non_terminal)) {
                    if (depth > productions.len) return;
                    if (inline_map.inlinedProductions(parse_item.production_id, parse_item.step_index)) |inlined_ids| {
                        for (inlined_ids) |inlined_id| {
                            var expanded_entry = entry;
                            expanded_entry.item = .{
                                .variable_index = parse_item.variable_index,
                                .production_id = inlined_id,
                                .step_index = parse_item.step_index,
                                .has_preceding_inherited_fields = parse_item.has_preceding_inherited_fields,
                                .structural_identity = itemIdentityId(
                                    item_identity_ids,
                                    inlined_id,
                                    parse_item.step_index,
                                ),
                                .merge_identity = itemIdentityId(
                                    item_merge_identity_ids,
                                    inlined_id,
                                    parse_item.step_index,
                                ),
                            };
                            try self.appendSuccessorForEntry(
                                expanded_entry,
                                productions,
                                item_identity_ids,
                                item_merge_identity_ids,
                                variable_has_fields,
                                variables_to_inline,
                                inline_map,
                                depth + 1,
                            );
                        }
                    }
                    return;
                }
            },
            else => {},
        }

        const group_index = blk: {
            const result = try self.group_indexes.getOrPut(symbol);
            if (result.found_existing) break :blk result.value_ptr.*;
            const new_index = self.groups.items.len;
            try self.groups.append(SuccessorGroup.init(self.allocator, symbol));
            if (construct_profile_enabled) construct_profile.successor_group_new += 1;
            result.value_ptr.* = @intCast(new_index);
            break :blk new_index;
        };

        const successor_entry = item.ParseItemSetEntry{
            .item = .{
                .variable_index = parse_item.variable_index,
                .production_id = parse_item.production_id,
                .step_index = parse_item.step_index + 1,
                .has_preceding_inherited_fields = parse_item.has_preceding_inherited_fields or
                    symbolAddsPrecedingInheritedFields(productions, variable_has_fields, symbol),
                .structural_identity = itemIdentityId(
                    item_identity_ids,
                    parse_item.production_id,
                    parse_item.step_index + 1,
                ),
                .merge_identity = itemIdentityId(
                    item_merge_identity_ids,
                    parse_item.production_id,
                    parse_item.step_index + 1,
                ),
            },
            .lookaheads = try cloneSymbolSet(self.allocator, entry.lookaheads),
            .following_reserved_word_set_id = entry.following_reserved_word_set_id,
        };

        const group = &self.groups.items[group_index];
        if (group.findItemIndex(successor_entry.item)) |item_index| {
            if (construct_profile_enabled) construct_profile.successor_item_merges += 1;
            _ = mergeSymbolSetLookaheads(&group.items.items[item_index].lookaheads, successor_entry.lookaheads);
            group.items.items[item_index].following_reserved_word_set_id = @max(
                group.items.items[item_index].following_reserved_word_set_id,
                successor_entry.following_reserved_word_set_id,
            );
            freeSymbolSet(self.allocator, successor_entry.lookaheads);
        } else {
            if (construct_profile_enabled) construct_profile.successor_item_appends += 1;
            try group.items.append(successor_entry);
        }
    }
};

fn successorGroupLessThan(_: void, left: SuccessorGroup, right: SuccessorGroup) bool {
    return symbolRefLessThan(left.symbol, right.symbol);
}

fn symbolAddsPrecedingInheritedFields(
    productions: []const ProductionInfo,
    variable_has_fields: []const bool,
    symbol: syntax_ir.SymbolRef,
) bool {
    const non_terminal = switch (symbol) {
        .non_terminal => |index| index,
        else => return false,
    };
    if (!variableIsHiddenForItemIdentity(productions, non_terminal)) return false;
    return non_terminal < variable_has_fields.len and variable_has_fields[non_terminal];
}

const ClosureExpansionCacheEntry = struct {
    non_terminal: u32,
    closure_lookahead_mode: ClosureLookaheadMode,
    context_follow: first.SymbolSet,
    following_reserved_word_set_id: u16 = 0,
    production_end_reserved_word_set_id: u16 = 0,
    generated_items: []const item.ParseItemSetEntry,
};

const ClosureExpansionCache = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(ClosureExpansionCacheEntry),

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(ClosureExpansionCacheEntry).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        for (self.entries.items) |entry| {
            freeSymbolSet(self.allocator, entry.context_follow);
            for (entry.generated_items) |generated| {
                freeSymbolSet(self.allocator, generated.lookaheads);
            }
            self.allocator.free(entry.generated_items);
        }
        self.entries.deinit();
    }

    fn find(
        self: @This(),
        non_terminal: u32,
        closure_lookahead_mode: ClosureLookaheadMode,
        context_follow: first.SymbolSet,
        following_reserved_word_set_id: u16,
        production_end_reserved_word_set_id: u16,
    ) ?[]const item.ParseItemSetEntry {
        for (self.entries.items) |entry| {
            if (construct_profile_enabled) construct_profile.closure_expansion_cache_scanned += 1;
            if (entry.non_terminal != non_terminal) continue;
            if (entry.closure_lookahead_mode != closure_lookahead_mode) continue;
            if (closure_lookahead_mode == .none) return entry.generated_items;
            if (!first.SymbolSet.eql(entry.context_follow, context_follow)) continue;
            if (entry.following_reserved_word_set_id != following_reserved_word_set_id) continue;
            if (entry.production_end_reserved_word_set_id != production_end_reserved_word_set_id) continue;
            return entry.generated_items;
        }
        return null;
    }

    fn append(
        self: *@This(),
        non_terminal: u32,
        closure_lookahead_mode: ClosureLookaheadMode,
        context_follow: first.SymbolSet,
        following_reserved_word_set_id: u16,
        production_end_reserved_word_set_id: u16,
        generated_items: []const item.ParseItemSetEntry,
    ) !void {
        try self.entries.append(.{
            .non_terminal = non_terminal,
            .closure_lookahead_mode = closure_lookahead_mode,
            .context_follow = try cloneSymbolSet(self.allocator, context_follow),
            .following_reserved_word_set_id = following_reserved_word_set_id,
            .production_end_reserved_word_set_id = production_end_reserved_word_set_id,
            .generated_items = generated_items,
        });
        if (construct_profile_enabled) construct_profile.closure_expansion_cache_entries = self.entries.items.len;
    }
};

const ClosureFollowInfo = struct {
    lookaheads: first.SymbolSet,
    reserved_lookaheads: u16 = 0,
    propagates_lookaheads: bool = false,
};

const FollowSets = struct {
    values: []first.SymbolSet,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        for (self.values) |set| freeSymbolSet(allocator, set);
        if (self.values.len != 0) allocator.free(self.values);
    }
};

const TransitiveClosureAddition = struct {
    variable_index: u32,
    production_id: item.ProductionId,
    info: ClosureFollowInfo,
};

const ParseItemSetBuilder = struct {
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    reserved_first_set_ids: []const u16,
    additions_per_non_terminal: [][]const TransitiveClosureAddition,
    reserved_word_context_names: []const []const u8,
    word_token: ?syntax_ir.SymbolRef,
    variables_to_inline: []const syntax_ir.SymbolRef,
    inline_map: process_inlines.InlinedProductionMap,
    original_productions_len: u32,
    item_identity_ids: []const []const u32,
    item_merge_identity_ids: []const []const u32,

    fn init(
        allocator: std.mem.Allocator,
        productions: []const ProductionInfo,
        first_sets: first.FirstSets,
        reserved_word_context_names: []const []const u8,
        word_token: ?syntax_ir.SymbolRef,
        variables_to_inline: []const syntax_ir.SymbolRef,
        grammar_variables: []const syntax_ir.SyntaxVariable,
    ) !@This() {
        const original_productions_len: u32 = @intCast(productions.len);

        // Build inline expansion map from original productions.
        const inlined_src = try allocator.alloc(process_inlines.InlinedProduction, productions.len);
        defer allocator.free(inlined_src);
        for (inlined_src, productions) |*dst, src| {
            dst.* = .{
                .lhs = src.lhs,
                .lhs_kind = src.lhs_kind,
                .steps = src.steps,
                .lhs_is_repeat_auxiliary = src.lhs_is_repeat_auxiliary,
                .augmented = src.augmented,
                .dynamic_precedence = src.dynamic_precedence,
            };
        }
        var inline_map = try process_inlines.buildInlinedProductionMapAlloc(
            allocator,
            inlined_src,
            variables_to_inline,
            grammar_variables,
        );
        errdefer inline_map.deinit();

        // Extend productions slice with inlined extras. Clone steps so lifetime is
        // independent of inline_map (BuildResult takes ownership of extended_productions).
        const extended_productions = if (inline_map.extra_productions.len > 0) blk: {
            const combined = try allocator.alloc(ProductionInfo, productions.len + inline_map.extra_productions.len);
            @memcpy(combined[0..productions.len], productions);
            var cloned: usize = 0;
            errdefer {
                for (combined[productions.len..][0..cloned]) |p| allocator.free(p.steps);
                allocator.free(combined);
            }
            for (combined[productions.len..], inline_map.extra_productions) |*dst, src| {
                const steps_copy = try allocator.dupe(syntax_ir.ProductionStep, src.steps);
                dst.* = .{
                    .lhs = src.lhs,
                    .lhs_kind = src.lhs_kind,
                    .steps = steps_copy,
                    .lhs_is_repeat_auxiliary = src.lhs_is_repeat_auxiliary,
                    .augmented = src.augmented,
                    .dynamic_precedence = src.dynamic_precedence,
                    .production_metadata_eligible = productionMetadataEligible(
                        variables_to_inline,
                        src.lhs,
                        steps_copy,
                    ),
                };
                cloned += 1;
            }
            break :blk combined;
        } else productions;

        const variable_count = variableCountFromProductions(extended_productions);
        const item_identity_ids = try computeItemIdentityIdsAlloc(
            allocator,
            extended_productions,
            extended_productions[0..original_productions_len],
            true,
        );
        errdefer freeItemIdentityIds(allocator, item_identity_ids);
        const item_merge_identity_ids = try computeItemIdentityIdsAlloc(
            allocator,
            extended_productions,
            extended_productions[0..original_productions_len],
            false,
        );
        errdefer freeItemIdentityIds(allocator, item_merge_identity_ids);
        const reserved_first_set_ids = try computeReservedFirstSetIdsAlloc(
            allocator,
            extended_productions,
            reserved_word_context_names,
            variable_count,
        );
        errdefer allocator.free(reserved_first_set_ids);
        const additions_per_non_terminal = try allocator.alloc([]const TransitiveClosureAddition, variable_count);
        var additions_count: usize = 0;
        errdefer {
            for (additions_per_non_terminal[0..additions_count]) |items| {
                for (items) |addition| freeSymbolSet(allocator, addition.info.lookaheads);
                allocator.free(items);
            }
            allocator.free(additions_per_non_terminal);
        }

        for (0..variable_count) |non_terminal| {
            additions_per_non_terminal[non_terminal] = try computeTransitiveClosureAdditionsAlloc(
                allocator,
                extended_productions,
                first_sets,
                reserved_first_set_ids,
                @intCast(non_terminal),
                variables_to_inline,
                inline_map,
                original_productions_len,
            );
            additions_count += 1;
        }

        return .{
            .allocator = allocator,
            .productions = extended_productions,
            .first_sets = first_sets,
            .reserved_first_set_ids = reserved_first_set_ids,
            .additions_per_non_terminal = additions_per_non_terminal,
            .reserved_word_context_names = reserved_word_context_names,
            .word_token = word_token,
            .variables_to_inline = variables_to_inline,
            .inline_map = inline_map,
            .original_productions_len = original_productions_len,
            .item_identity_ids = item_identity_ids,
            .item_merge_identity_ids = item_merge_identity_ids,
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
        self.allocator.free(self.reserved_first_set_ids);
        freeItemIdentityIds(self.allocator, self.item_identity_ids);
        freeItemIdentityIds(self.allocator, self.item_merge_identity_ids);
        // The extended productions slice (and its cloned steps) are returned as
        // BuildResult.productions and owned by the caller — do not free them here.
        self.inline_map.deinit();
    }

    fn additionsForNonTerminal(self: @This(), non_terminal: u32) []const TransitiveClosureAddition {
        return self.additions_per_non_terminal[non_terminal];
    }

    fn reservedFirstSetIdForSymbol(self: @This(), symbol: syntax_ir.SymbolRef) u16 {
        return reservedFirstSetIdForSymbolRef(symbol, self.reserved_first_set_ids);
    }

    fn makeParseItem(self: @This(), production_id: item.ProductionId, step_index: u16) item.ParseItem {
        const variable_index = if (production_id < self.productions.len and !self.productions[production_id].augmented)
            self.productions[production_id].lhs
        else
            item.unset_variable_index;
        return self.makeParseItemForVariable(variable_index, production_id, step_index);
    }

    fn makeParseItemForVariable(
        self: @This(),
        variable_index: u32,
        production_id: item.ProductionId,
        step_index: u16,
    ) item.ParseItem {
        return .{
            .variable_index = variable_index,
            .production_id = production_id,
            .step_index = step_index,
            .structural_identity = itemIdentityId(self.item_identity_ids, production_id, step_index),
            .merge_identity = itemIdentityId(self.item_merge_identity_ids, production_id, step_index),
        };
    }

    fn transitiveClosure(
        self: @This(),
        allocator: std.mem.Allocator,
        variables: []const syntax_ir.SyntaxVariable,
        item_set: item.ParseItemSet,
        options: BuildOptions,
    ) BuildError!item.ParseItemSet {
        return try self.transitiveClosureWithExpansionCache(
            allocator,
            variables,
            item_set,
            options,
            null,
        );
    }

    fn transitiveClosureWithExpansionCache(
        self: @This(),
        allocator: std.mem.Allocator,
        variables: []const syntax_ir.SyntaxVariable,
        item_set: item.ParseItemSet,
        options: BuildOptions,
        expansion_cache: ?*ClosureExpansionCache,
    ) BuildError!item.ParseItemSet {
        return .{
            .entries = try closure(allocator, variables, self, item_set.entries, options, expansion_cache),
        };
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

fn itemIdentityId(identity_ids: []const []const u32, production_id: item.ProductionId, step_index: u16) u32 {
    if (production_id >= identity_ids.len) return item.unset_structural_identity;
    const steps = identity_ids[production_id];
    if (step_index >= steps.len) return item.unset_structural_identity;
    return steps[step_index];
}

fn freeItemIdentityIds(allocator: std.mem.Allocator, identity_ids: []const []const u32) void {
    for (identity_ids) |ids| allocator.free(ids);
    allocator.free(identity_ids);
}

fn computeItemIdentityIdsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    field_productions: []const ProductionInfo,
    compare_consumed_symbols: bool,
) ![]const []const u32 {
    const variable_count = variableCountFromProductions(productions);
    const variable_has_fields = try computeVariableHasFieldsAlloc(allocator, field_productions, variable_count);
    defer allocator.free(variable_has_fields);

    const ids = try allocator.alloc([]u32, productions.len);
    errdefer allocator.free(ids);

    var initialized: usize = 0;
    errdefer {
        for (ids[0..initialized]) |slice| allocator.free(slice);
    }

    for (productions, 0..) |production, production_id| {
        const per_step = try allocator.alloc(u32, production.steps.len + 1);
        ids[production_id] = per_step;
        initialized += 1;
    }

    var candidate_count: usize = 0;
    for (productions) |production| candidate_count += production.steps.len + 1;

    const candidates = try allocator.alloc(ItemIdentityCandidate, candidate_count);
    defer allocator.free(candidates);

    var candidate_index: usize = 0;
    for (productions, 0..) |production, production_id| {
        for (0..production.steps.len + 1) |step_index| {
            candidates[candidate_index] = .{
                .production_id = @intCast(production_id),
                .step_index = @intCast(step_index),
            };
            candidate_index += 1;
        }
    }
    std.mem.sort(ItemIdentityCandidate, candidates, ItemIdentitySortContext{
        .productions = productions,
        .variable_has_fields = variable_has_fields,
        .compare_consumed_symbols = compare_consumed_symbols,
    }, itemIdentityCandidateLessThan);

    var next_identity: u32 = 0;
    var current_identity: u32 = 0;
    var previous: ?ItemIdentityCandidate = null;
    for (candidates) |candidate| {
        if (previous) |prior| {
            if (!parseItemStructuralEql(
                productions,
                variable_has_fields,
                prior.production_id,
                prior.step_index,
                candidate.production_id,
                candidate.step_index,
                compare_consumed_symbols,
            )) {
                next_identity += 1;
                current_identity = next_identity;
            }
        }
        ids[candidate.production_id][candidate.step_index] = current_identity;
        previous = candidate;
    }

    return ids;
}

const ItemIdentityCandidate = struct {
    production_id: item.ProductionId,
    step_index: u16,
};

const ItemIdentitySortContext = struct {
    productions: []const ProductionInfo,
    variable_has_fields: []const bool,
    compare_consumed_symbols: bool,
};

fn itemIdentityCandidateLessThan(
    context: ItemIdentitySortContext,
    left: ItemIdentityCandidate,
    right: ItemIdentityCandidate,
) bool {
    return parseItemStructuralCompare(
        context.productions,
        context.variable_has_fields,
        left.production_id,
        left.step_index,
        right.production_id,
        right.step_index,
        context.compare_consumed_symbols,
    ) == .lt;
}

fn parseItemStructuralEql(
    productions: []const ProductionInfo,
    variable_has_fields: []const bool,
    left_id: item.ProductionId,
    left_step_index: u16,
    right_id: item.ProductionId,
    right_step_index: u16,
    compare_consumed_symbols: bool,
) bool {
    if (left_id >= productions.len or right_id >= productions.len) return false;
    const left = productions[left_id];
    const right = productions[right_id];
    if (left_step_index != right_step_index) return false;
    if (left.dynamic_precedence != right.dynamic_precedence) return false;
    if (left.steps.len != right.steps.len) return false;
    if (left.augmented != right.augmented) return false;

    const step_index: usize = left_step_index;
    const left_has_preceding_inherited_fields = itemHasPrecedingInheritedFields(productions, left, variable_has_fields, step_index);
    const right_has_preceding_inherited_fields = itemHasPrecedingInheritedFields(productions, right, variable_has_fields, step_index);
    if (left_has_preceding_inherited_fields != right_has_preceding_inherited_fields) return false;
    if (!precedenceValueEql(prevStepPrecedence(left.steps, step_index), prevStepPrecedence(right.steps, step_index))) return false;
    if (prevStepAssociativity(left.steps, step_index) != prevStepAssociativity(right.steps, step_index)) return false;

    for (left.steps, right.steps, 0..) |left_step, right_step, index| {
        if (index < step_index) {
            if (!aliasEql(left_step.alias, right_step.alias)) return false;
            if (!optionalStringEql(left_step.field_name, right_step.field_name)) return false;
            if (compare_consumed_symbols and
                left_has_preceding_inherited_fields and
                !symbolRefEql(left_step.symbol, right_step.symbol))
            {
                return false;
            }
        } else if (!productionStepEqlForItemIdentity(left_step, right_step)) {
            return false;
        }
    }
    return true;
}

fn parseItemStructuralCompare(
    productions: []const ProductionInfo,
    variable_has_fields: []const bool,
    left_id: item.ProductionId,
    left_step_index: u16,
    right_id: item.ProductionId,
    right_step_index: u16,
    compare_consumed_symbols: bool,
) std.math.Order {
    if (left_id >= productions.len or right_id >= productions.len) return compareScalar(left_id, right_id);
    const left = productions[left_id];
    const right = productions[right_id];

    const step_order = compareScalar(left_step_index, right_step_index);
    if (step_order != .eq) return step_order;

    const dynamic_order = compareScalar(left.dynamic_precedence, right.dynamic_precedence);
    if (dynamic_order != .eq) return dynamic_order;

    const len_order = compareScalar(left.steps.len, right.steps.len);
    if (len_order != .eq) return len_order;

    const precedence_order = precedenceValueCompare(prevStepPrecedence(left.steps, left_step_index), prevStepPrecedence(right.steps, right_step_index));
    if (precedence_order != .eq) return precedence_order;

    const associativity_order = assocCompare(prevStepAssociativity(left.steps, left_step_index), prevStepAssociativity(right.steps, right_step_index));
    if (associativity_order != .eq) return associativity_order;

    const left_has_preceding_inherited_fields = itemHasPrecedingInheritedFields(productions, left, variable_has_fields, left_step_index);
    const right_has_preceding_inherited_fields = itemHasPrecedingInheritedFields(productions, right, variable_has_fields, right_step_index);
    const inherited_order = compareScalar(@intFromBool(left_has_preceding_inherited_fields), @intFromBool(right_has_preceding_inherited_fields));
    if (inherited_order != .eq) return inherited_order;

    const step_index: usize = left_step_index;
    for (left.steps, right.steps, 0..) |left_step, right_step, index| {
        const order = if (index < step_index)
            consumedProductionStepCompare(
                left_step,
                right_step,
                compare_consumed_symbols and left_has_preceding_inherited_fields,
            )
        else
            productionStepCompareForItemIdentity(left_step, right_step);
        if (order != .eq) return order;
    }

    return compareScalar(left_id, right_id);
}

fn itemHasPrecedingInheritedFields(
    productions: []const ProductionInfo,
    production: ProductionInfo,
    variable_has_fields: []const bool,
    step_index: usize,
) bool {
    const limit = @min(step_index, production.steps.len);
    for (production.steps[0..limit]) |step| {
        const non_terminal = switch (step.symbol) {
            .non_terminal => |index| index,
            else => continue,
        };
        if (!variableIsHiddenForItemIdentity(productions, non_terminal)) continue;
        if (non_terminal < variable_has_fields.len and variable_has_fields[non_terminal]) return true;
    }
    return false;
}

fn variableIsHiddenForItemIdentity(productions: []const ProductionInfo, variable_index: u32) bool {
    const kind = variableKindFromProductions(productions, variable_index);
    return kind == .hidden or kind == .auxiliary;
}

test "item identities keep consumed hidden field symbols distinct" {
    const allocator = std.testing.allocator;

    var left_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 1 } },
    };
    var right_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .terminal = 1 } },
    };
    var hidden_left_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 2 }, .field_name = "value" },
    };
    var hidden_right_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 3 }, .field_name = "value" },
    };
    const productions = [_]ProductionInfo{
        .{ .lhs = 0, .lhs_kind = .named, .steps = left_steps[0..] },
        .{ .lhs = 0, .lhs_kind = .named, .steps = right_steps[0..] },
        .{ .lhs = 1, .lhs_kind = .hidden, .steps = hidden_left_steps[0..] },
        .{ .lhs = 2, .lhs_kind = .hidden, .steps = hidden_right_steps[0..] },
    };

    const ids = try computeItemIdentityIdsAlloc(allocator, productions[0..], productions[0..], true);
    defer freeItemIdentityIds(allocator, ids);

    try std.testing.expect(ids[0][1] != ids[1][1]);

    const merge_ids = try computeItemIdentityIdsAlloc(allocator, productions[0..], productions[0..], false);
    defer freeItemIdentityIds(allocator, merge_ids);

    try std.testing.expectEqual(merge_ids[0][1], merge_ids[1][1]);
}

fn prevStepPrecedence(steps: []const syntax_ir.ProductionStep, step_index: usize) rules.PrecedenceValue {
    if (step_index == 0 or step_index > steps.len) return .none;
    return steps[step_index - 1].precedence;
}

fn prevStepAssociativity(steps: []const syntax_ir.ProductionStep, step_index: usize) rules.Assoc {
    if (step_index == 0 or step_index > steps.len) return .none;
    return steps[step_index - 1].associativity;
}

fn productionStepEqlForItemIdentity(left: syntax_ir.ProductionStep, right: syntax_ir.ProductionStep) bool {
    return symbolRefEql(left.symbol, right.symbol) and
        aliasEql(left.alias, right.alias) and
        optionalStringEql(left.field_name, right.field_name) and
        left.field_inherited == right.field_inherited and
        precedenceValueEql(left.precedence, right.precedence) and
        left.associativity == right.associativity and
        optionalStringEql(left.reserved_context_name, right.reserved_context_name);
}

fn consumedProductionStepCompare(
    left: syntax_ir.ProductionStep,
    right: syntax_ir.ProductionStep,
    compare_symbol: bool,
) std.math.Order {
    const alias_order = aliasCompare(left.alias, right.alias);
    if (alias_order != .eq) return alias_order;
    const field_order = optionalStringCompare(left.field_name, right.field_name);
    if (field_order != .eq) return field_order;
    if (compare_symbol) {
        const symbol_order = symbolRefCompare(left.symbol, right.symbol);
        if (symbol_order != .eq) return symbol_order;
    }
    return .eq;
}

fn productionStepCompareForItemIdentity(left: syntax_ir.ProductionStep, right: syntax_ir.ProductionStep) std.math.Order {
    const symbol_order = symbolRefCompare(left.symbol, right.symbol);
    if (symbol_order != .eq) return symbol_order;
    const precedence_order = precedenceValueCompare(left.precedence, right.precedence);
    if (precedence_order != .eq) return precedence_order;
    const assoc_order = assocCompare(left.associativity, right.associativity);
    if (assoc_order != .eq) return assoc_order;
    const alias_order = aliasCompare(left.alias, right.alias);
    if (alias_order != .eq) return alias_order;
    const field_order = optionalStringCompare(left.field_name, right.field_name);
    if (field_order != .eq) return field_order;
    return optionalStringCompare(left.reserved_context_name, right.reserved_context_name);
}

fn precedenceValueEql(left: rules.PrecedenceValue, right: rules.PrecedenceValue) bool {
    return switch (left) {
        .none => right == .none,
        .integer => |left_value| switch (right) {
            .integer => |right_value| left_value == right_value,
            else => false,
        },
        .name => |left_name| switch (right) {
            .name => |right_name| std.mem.eql(u8, left_name, right_name),
            else => false,
        },
    };
}

fn precedenceValueCompare(left: rules.PrecedenceValue, right: rules.PrecedenceValue) std.math.Order {
    const left_tag = precedenceValueOrder(left);
    const right_tag = precedenceValueOrder(right);
    const tag_order = compareScalar(left_tag, right_tag);
    if (tag_order != .eq) return tag_order;
    return switch (left) {
        .none => .eq,
        .integer => |left_value| switch (right) {
            .integer => |right_value| compareScalar(left_value, right_value),
            else => .eq,
        },
        .name => |left_name| switch (right) {
            .name => |right_name| std.mem.order(u8, left_name, right_name),
            else => .eq,
        },
    };
}

fn precedenceValueOrder(value: rules.PrecedenceValue) u8 {
    return switch (value) {
        .none => 0,
        .integer => 1,
        .name => 2,
    };
}

fn assocCompare(left: rules.Assoc, right: rules.Assoc) std.math.Order {
    return compareScalar(assocOrder(left), assocOrder(right));
}

fn assocOrder(value: rules.Assoc) u8 {
    return switch (value) {
        .none => 0,
        .left => 1,
        .right => 2,
    };
}

fn aliasCompare(left: ?rules.Alias, right: ?rules.Alias) std.math.Order {
    if (left) |left_value| {
        const right_value = right orelse return .gt;
        const value_order = std.mem.order(u8, left_value.value, right_value.value);
        if (value_order != .eq) return value_order;
        return compareScalar(@intFromBool(left_value.named), @intFromBool(right_value.named));
    }
    return if (right == null) .eq else .lt;
}

fn aliasEql(left: ?rules.Alias, right: ?rules.Alias) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return left_value.named == right_value.named and std.mem.eql(u8, left_value.value, right_value.value);
    }
    return right == null;
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

fn optionalStringCompare(left: ?[]const u8, right: ?[]const u8) std.math.Order {
    if (left) |left_value| {
        const right_value = right orelse return .gt;
        return std.mem.order(u8, left_value, right_value);
    }
    return if (right == null) .eq else .lt;
}

fn symbolRefCompare(left: syntax_ir.SymbolRef, right: syntax_ir.SymbolRef) std.math.Order {
    const left_key = symbolRefSortKey(left);
    const right_key = symbolRefSortKey(right);
    return compareScalar(left_key, right_key);
}

fn compareScalar(left: anytype, right: @TypeOf(left)) std.math.Order {
    if (left < right) return .lt;
    if (left > right) return .gt;
    return .eq;
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
            "closure contributor rank={d} non_terminal={d} name={s} productions={d} visits={d} contexts={d} cache_hits={d} unique_context_lookaheads={d} unique_context_first_sets={d} added={d} duplicate_hits={d}",
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
    return try item.cloneSymbolSet(allocator, set);
}

fn initEmptySymbolSet(allocator: std.mem.Allocator, terminals_len: usize, externals_len: usize) !first.SymbolSet {
    return try item.initEmptyLookaheadSet(allocator, terminals_len, externals_len);
}

fn freeSymbolSet(allocator: std.mem.Allocator, set: first.SymbolSet) void {
    item.freeSymbolSet(allocator, set);
}

fn cloneParseItemSetEntries(
    allocator: std.mem.Allocator,
    entries: []const item.ParseItemSetEntry,
) ![]const item.ParseItemSetEntry {
    const cloned = try allocator.alloc(item.ParseItemSetEntry, entries.len);
    errdefer allocator.free(cloned);

    var cloned_count: usize = 0;
    errdefer {
        for (cloned[0..cloned_count]) |entry| {
            freeSymbolSet(allocator, entry.lookaheads);
        }
    }

    for (entries, 0..) |entry, index| {
        cloned[index] = .{
            .item = entry.item,
            .lookaheads = try cloneSymbolSet(allocator, entry.lookaheads),
            .following_reserved_word_set_id = entry.following_reserved_word_set_id,
        };
        cloned_count += 1;
    }

    return cloned;
}

fn freeParseItemSetEntries(allocator: std.mem.Allocator, entries: []const item.ParseItemSetEntry) void {
    for (entries) |entry| {
        freeSymbolSet(allocator, entry.lookaheads);
    }
    allocator.free(entries);
}

fn mergeSymbolSetLookaheads(target: *first.SymbolSet, incoming: first.SymbolSet) bool {
    return item.mergeSymbolSetLookaheads(target, incoming);
}

fn mergeFollowWithoutEpsilon(target: *first.SymbolSet, incoming: first.SymbolSet) bool {
    var changed = false;
    if (incoming.includes_end and !target.includes_end) {
        target.includes_end = true;
        changed = true;
    }
    changed = first.SymbolBits.merge(&target.terminals, incoming.terminals) or changed;
    changed = first.SymbolBits.merge(&target.externals, incoming.externals) or changed;
    return changed;
}

fn addSymbolToSet(target: *first.SymbolSet, symbol: syntax_ir.SymbolRef) void {
    switch (symbol) {
        .end => target.includes_end = true,
        .terminal => |index| target.terminals.set(index),
        .external => |index| target.externals.set(index),
        .non_terminal => {},
    }
}

fn closureContextProductionEndFollowSet(
    allocator: std.mem.Allocator,
    inherited_lookaheads: first.SymbolSet,
) !first.SymbolSet {
    return try cloneSymbolSet(allocator, inherited_lookaheads);
}

const ClosureContext = struct {
    following_tokens: first.SymbolSet,
    production_end_follow: first.SymbolSet,
    following_reserved_word_set_id: u16 = 0,
    production_end_reserved_word_set_id: u16 = 0,

    fn init(
        allocator: std.mem.Allocator,
        following_tokens: first.SymbolSet,
        following_reserved_word_set_id: u16,
        inherited_lookaheads: first.SymbolSet,
        inherited_reserved_word_set_id: u16,
    ) !@This() {
        return .{
            .following_tokens = try cloneSymbolSet(allocator, following_tokens),
            .production_end_follow = try closureContextProductionEndFollowSet(allocator, inherited_lookaheads),
            .following_reserved_word_set_id = following_reserved_word_set_id,
            .production_end_reserved_word_set_id = inherited_reserved_word_set_id,
        };
    }

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        freeSymbolSet(allocator, self.following_tokens);
        freeSymbolSet(allocator, self.production_end_follow);
    }
};

fn immediateFollowingFirstSetAlloc(
    allocator: std.mem.Allocator,
    first_sets: first.FirstSets,
    symbol: syntax_ir.SymbolRef,
) !first.SymbolSet {
    var result = try initEmptySymbolSet(allocator, first_sets.terminals_len, first_sets.externals_len);
    switch (symbol) {
        .end => result.includes_end = true,
        .terminal => |index| result.terminals.set(index),
        .external => |index| result.externals.set(index),
        .non_terminal => |index| {
            freeSymbolSet(allocator, result);
            result = try cloneSymbolSet(allocator, first_sets.firstOfVariable(index));
        },
    }
    return result;
}

fn optionalSymbolRefEql(a: ?syntax_ir.SymbolRef, b: ?syntax_ir.SymbolRef) bool {
    if (a) |left| {
        if (b) |right| return symbolRefEql(left, right);
        return false;
    }
    return b == null;
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
            if (first.SymbolSet.eql(prior.context_follow, entry.context_follow)) {
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
            if (first.SymbolSet.eql(prior.context_follow, entry.context_follow)) {
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
    reserved_lookaheads: u16 = 0,
    propagates_lookaheads: bool = false,
};

fn findFollowInfoIndex(items: []const ?ClosureFollowInfo, non_terminal: u32) ?usize {
    if (non_terminal >= items.len) return null;
    return if (items[non_terminal] != null) non_terminal else null;
}

fn mergeFollowInfo(
    allocator: std.mem.Allocator,
    target: *?ClosureFollowInfo,
    incoming: FollowWorkEntry,
) !bool {
    if (target.* == null) {
        target.* = .{
            .lookaheads = try cloneSymbolSet(allocator, incoming.lookaheads),
            .reserved_lookaheads = incoming.reserved_lookaheads,
            .propagates_lookaheads = incoming.propagates_lookaheads,
        };
        return true;
    }

    var changed = false;
    changed = mergeSymbolSetLookaheads(&target.*.?.lookaheads, incoming.lookaheads) or changed;
    if (incoming.reserved_lookaheads > target.*.?.reserved_lookaheads) {
        target.*.?.reserved_lookaheads = incoming.reserved_lookaheads;
        changed = true;
    }
    if (incoming.propagates_lookaheads and !target.*.?.propagates_lookaheads) {
        target.*.?.propagates_lookaheads = true;
        changed = true;
    }
    return changed;
}

fn isNonTerminalInline(variables_to_inline: []const syntax_ir.SymbolRef, nt: u32) bool {
    for (variables_to_inline) |sym| {
        switch (sym) {
            .non_terminal => |n| if (n == nt) return true,
            else => {},
        }
    }
    return false;
}

fn computeTransitiveClosureAdditionsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    reserved_first_set_ids: []const u16,
    root_non_terminal: u32,
    variables_to_inline: []const syntax_ir.SymbolRef,
    inline_map: process_inlines.InlinedProductionMap,
    original_productions_len: u32,
) ![]const TransitiveClosureAddition {
    const variable_count = variableCountFromProductions(productions);
    var infos = try allocator.alloc(?ClosureFollowInfo, variable_count);
    defer {
        for (infos) |maybe_info| {
            if (maybe_info) |info| {
                freeSymbolSet(allocator, info.lookaheads);
            }
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
        .reserved_lookaheads = 0,
        .propagates_lookaheads = true,
    });

    while (stack.items.len > 0) {
        const entry = stack.pop().?;
        const changed = try mergeFollowInfo(allocator, &infos[entry.non_terminal], entry);
        freeSymbolSet(allocator, entry.lookaheads);
        if (!changed) continue;

        for (productions[0..original_productions_len]) |production| {
            if (production.augmented) continue;
            if (production.lhs != entry.non_terminal) continue;
            if (production.steps.len == 0) continue;

            switch (production.steps[0].symbol) {
                .non_terminal => |next_non_terminal| {
                    const remainder = production.steps[1..];
                    if (remainder.len == 0) {
                        const info = infos[entry.non_terminal].?;
                        try stack.append(.{
                            .non_terminal = next_non_terminal,
                            .lookaheads = try cloneSymbolSet(allocator, info.lookaheads),
                            .reserved_lookaheads = info.reserved_lookaheads,
                            .propagates_lookaheads = info.propagates_lookaheads,
                        });
                    } else {
                        try stack.append(.{
                            .non_terminal = next_non_terminal,
                            .lookaheads = try first_sets.firstOfSequence(allocator, remainder[0..1]),
                            .reserved_lookaheads = reservedFirstSetIdForSymbolRef(remainder[0].symbol, reserved_first_set_ids),
                            .propagates_lookaheads = false,
                        });
                    }
                },
                else => {},
            }
        }
    }

    var additions = std.array_list.Managed(TransitiveClosureAddition).init(allocator);
    defer additions.deinit();

    for (infos, 0..) |maybe_info, non_terminal| {
        const info = maybe_info orelse continue;
        // Upstream still walks inline variables while computing follow info, but
        // inline variables do not contribute their own closure additions. Their
        // productions are substituted from the InlinedProductionMap instead.
        if (isNonTerminalInline(variables_to_inline, @intCast(non_terminal))) continue;
        // Only iterate original productions; extra productions are added via inlinedProductions().
        for (productions[0..original_productions_len], 0..) |production, production_id| {
            if (production.augmented) continue;
            if (production.lhs != non_terminal) continue;
            // If step[0] is an inline variable, substitute with inlined alternatives.
            if (production.steps.len > 0) {
                switch (production.steps[0].symbol) {
                    .non_terminal => |nt| if (isNonTerminalInline(variables_to_inline, nt)) {
                        if (inline_map.inlinedProductions(@intCast(production_id), 0)) |exp_ids| {
                            for (exp_ids) |exp_id| {
                                try appendTransitiveClosureAdditionDedup(allocator, &additions, .{
                                    .variable_index = @intCast(non_terminal),
                                    .production_id = exp_id,
                                    .info = .{
                                        .lookaheads = try cloneSymbolSet(allocator, info.lookaheads),
                                        .reserved_lookaheads = info.reserved_lookaheads,
                                        .propagates_lookaheads = info.propagates_lookaheads,
                                    },
                                });
                            }
                        }
                        continue;
                    },
                    else => {},
                }
            }
            try appendTransitiveClosureAdditionDedup(allocator, &additions, .{
                .variable_index = @intCast(non_terminal),
                .production_id = @intCast(production_id),
                .info = .{
                    .lookaheads = try cloneSymbolSet(allocator, info.lookaheads),
                    .reserved_lookaheads = info.reserved_lookaheads,
                    .propagates_lookaheads = info.propagates_lookaheads,
                },
            });
        }
    }

    return try additions.toOwnedSlice();
}

fn appendTransitiveClosureAdditionDedup(
    allocator: std.mem.Allocator,
    additions: *std.array_list.Managed(TransitiveClosureAddition),
    candidate: TransitiveClosureAddition,
) !void {
    for (additions.items) |existing| {
        if (transitiveClosureAdditionEql(existing, candidate)) {
            freeSymbolSet(allocator, candidate.info.lookaheads);
            return;
        }
    }
    try additions.append(candidate);
}

fn transitiveClosureAdditionEql(left: TransitiveClosureAddition, right: TransitiveClosureAddition) bool {
    return left.variable_index == right.variable_index and
        left.production_id == right.production_id and
        first.SymbolSet.eql(left.info.lookaheads, right.info.lookaheads) and
        left.info.reserved_lookaheads == right.info.reserved_lookaheads and
        left.info.propagates_lookaheads == right.info.propagates_lookaheads;
}

fn buildClosureExpansionItemsAlloc(
    allocator: std.mem.Allocator,
    item_set_builder: ParseItemSetBuilder,
    non_terminal: u32,
    context: ClosureContext,
    options: BuildOptions,
) ![]const item.ParseItemSetEntry {
    var generated = std.array_list.Managed(item.ParseItemSetEntry).init(allocator);
    defer generated.deinit();
    var item_indexes = ClosureItemIndexMap.init(allocator);
    defer item_indexes.deinit();

    for (item_set_builder.additionsForNonTerminal(non_terminal)) |addition| {
        try appendGeneratedItems(
            allocator,
            &generated,
            &item_indexes,
            addition.variable_index,
            addition.production_id,
            item_set_builder.item_identity_ids,
            item_set_builder.item_merge_identity_ids,
            addition.info.lookaheads,
            addition.info.reserved_lookaheads,
            addition.info.propagates_lookaheads,
            context,
            item_set_builder.first_sets,
            item_set_builder.word_token,
            options,
        );
    }

    return try generated.toOwnedSlice();
}

fn appendGeneratedItems(
    allocator: std.mem.Allocator,
    generated: *std.array_list.Managed(item.ParseItemSetEntry),
    item_indexes: *ClosureItemIndexMap,
    variable_index: u32,
    production_id: item.ProductionId,
    item_identity_ids: []const []const u32,
    item_merge_identity_ids: []const []const u32,
    lookaheads: first.SymbolSet,
    reserved_lookaheads: u16,
    propagates_lookaheads: bool,
    context: ClosureContext,
    first_sets: first.FirstSets,
    word_token: ?syntax_ir.SymbolRef,
    options: BuildOptions,
) !void {
    if (options.closure_lookahead_mode == .none) {
        try appendOrMergeClosureEntry(
            allocator,
            generated,
            item_indexes,
            try item.ParseItemSetEntry.initEmpty(
                allocator,
                first_sets.terminals_len,
                first_sets.externals_len,
                .{
                    .variable_index = variable_index,
                    .production_id = production_id,
                    .step_index = 0,
                    .structural_identity = itemIdentityId(item_identity_ids, production_id, 0),
                    .merge_identity = itemIdentityId(item_merge_identity_ids, production_id, 0),
                },
            ),
            true,
        );
        return;
    }

    var generated_entry = try item.ParseItemSetEntry.initEmpty(
        allocator,
        first_sets.terminals_len,
        first_sets.externals_len,
        .{
            .variable_index = variable_index,
            .production_id = production_id,
            .step_index = 0,
            .structural_identity = itemIdentityId(item_identity_ids, production_id, 0),
            .merge_identity = itemIdentityId(item_merge_identity_ids, production_id, 0),
        },
    );
    if (lookaheads.includes_end) {
        item.addLookahead(&generated_entry.lookaheads, .{ .end = {} });
    }

    var effective_terminal_iter = lookaheads.terminals.bits.iterator(.{});
    while (effective_terminal_iter.next()) |index| {
        item.addLookahead(&generated_entry.lookaheads, .{ .terminal = @intCast(index) });
    }

    var effective_external_iter = lookaheads.externals.bits.iterator(.{});
    while (effective_external_iter.next()) |index| {
        item.addLookahead(&generated_entry.lookaheads, .{ .external = @intCast(index) });
    }

    if (propagates_lookaheads) {
        if (context.following_tokens.includes_end and !item.containsLookahead(generated_entry.lookaheads, .{ .end = {} })) {
            item.addLookahead(&generated_entry.lookaheads, .{ .end = {} });
        }
        var following_terminal_iter = context.following_tokens.terminals.bits.iterator(.{});
        while (following_terminal_iter.next()) |index| {
            const lookahead: syntax_ir.SymbolRef = .{ .terminal = @intCast(index) };
            if (!item.containsLookahead(generated_entry.lookaheads, lookahead)) item.addLookahead(&generated_entry.lookaheads, lookahead);
        }
        var following_external_iter = context.following_tokens.externals.bits.iterator(.{});
        while (following_external_iter.next()) |index| {
            const lookahead: syntax_ir.SymbolRef = .{ .external = @intCast(index) };
            if (!item.containsLookahead(generated_entry.lookaheads, lookahead)) item.addLookahead(&generated_entry.lookaheads, lookahead);
        }
    }

    if (word_token) |token| {
        if (item.containsLookahead(generated_entry.lookaheads, token)) {
            if (item.containsLookahead(lookaheads, token)) {
                generated_entry.following_reserved_word_set_id = @max(
                    generated_entry.following_reserved_word_set_id,
                    reserved_lookaheads,
                );
            }
            if (propagates_lookaheads and item.containsLookahead(context.following_tokens, token)) {
                generated_entry.following_reserved_word_set_id = @max(
                    generated_entry.following_reserved_word_set_id,
                    context.following_reserved_word_set_id,
                );
            }
        }
    }

    try appendOrMergeClosureEntry(allocator, generated, item_indexes, generated_entry, true);
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

pub const LexStateTerminalConflictMap = struct {
    terminal_count: usize,
    conflicts: []const bool,
    match_shorter_or_longer: []const bool = &.{},
    conflict_or_prefixes: []const bool = &.{},
    overlaps: []const bool = &.{},
    merge_overlaps: []const bool = &.{},
    keyword_tokens: []const bool = &.{},
    external_internal_tokens: []const bool = &.{},
    terminal_names: []const []const u8 = &.{},

    pub fn conflictsWith(self: LexStateTerminalConflictMap, left: usize, right: usize) bool {
        if (left >= self.terminal_count or right >= self.terminal_count) return true;
        return self.conflicts[left * self.terminal_count + right];
    }

    pub fn matchesShorterOrLonger(self: LexStateTerminalConflictMap, left: usize, right: usize) bool {
        if (left >= self.terminal_count or right >= self.terminal_count) return true;
        if (self.match_shorter_or_longer.len == self.terminal_count * self.terminal_count) {
            return self.match_shorter_or_longer[left * self.terminal_count + right];
        }
        return self.conflictsWith(left, right);
    }

    pub fn isKeyword(self: LexStateTerminalConflictMap, token: usize) bool {
        return token < self.keyword_tokens.len and self.keyword_tokens[token];
    }

    pub fn conflictsOrPrefixesWith(self: LexStateTerminalConflictMap, left: usize, right: usize) bool {
        if (left >= self.terminal_count or right >= self.terminal_count) return true;
        if (self.conflict_or_prefixes.len == self.terminal_count * self.terminal_count) {
            return self.conflict_or_prefixes[left * self.terminal_count + right];
        }
        return self.conflictsWith(left, right);
    }

    pub fn overlapsWith(self: LexStateTerminalConflictMap, left: usize, right: usize) bool {
        if (left >= self.terminal_count or right >= self.terminal_count) return true;
        if (self.overlaps.len == self.terminal_count * self.terminal_count) {
            return self.overlaps[left * self.terminal_count + right];
        }
        return self.conflictsWith(left, right);
    }

    pub fn mergeOverlapsWith(self: LexStateTerminalConflictMap, left: usize, right: usize) bool {
        if (left >= self.terminal_count or right >= self.terminal_count) return true;
        if (self.merge_overlaps.len == self.terminal_count * self.terminal_count) {
            return self.merge_overlaps[left * self.terminal_count + right];
        }
        return self.overlapsWith(left, right);
    }

    fn toMinimizeMap(
        self: LexStateTerminalConflictMap,
        reserved_word_sets: []const []const syntax_ir.SymbolRef,
    ) minimize.TerminalConflictMap {
        return .{
            .terminal_count = self.terminal_count,
            .conflicts = self.conflicts,
            .keyword_tokens = self.keyword_tokens,
            .external_internal_tokens = self.external_internal_tokens,
            .reserved_word_sets = reserved_word_sets,
            .terminal_names = self.terminal_names,
        };
    }
};

pub const BuildOptions = struct {
    closure_lookahead_mode: ClosureLookaheadMode = .full,
    coarse_follow_lookaheads: bool = false,
    closure_pressure_mode: ClosurePressureMode = .none,
    closure_pressure_thresholds: ClosurePressureThresholds = .{},
    coarse_transitions: []const CoarseTransitionSpec = &.{},
    reserved_word_context_names: []const []const u8 = &.{},
    non_terminal_extra_symbols: []const syntax_ir.SymbolRef = &.{},
    terminal_extra_symbols: []const syntax_ir.SymbolRef = &.{},
    state_zero_error_recovery: bool = false,
    lex_state_terminal_conflicts: ?LexStateTerminalConflictMap = null,
    minimize_states: bool = false,
    strict_expected_conflicts: bool = false,
    include_unresolved_parse_actions: bool = true,
    construct_profile: ?*ConstructProfile = null,
    simple_alias_symbols: []const syntax_ir.SymbolRef = &.{},
    reserved_word_sets: []const []const syntax_ir.SymbolRef = &.{},
};

fn shouldUseCoarseTransition(options: BuildOptions, source_state_id: state.StateId, symbol: syntax_ir.SymbolRef) bool {
    for (options.coarse_transitions) |spec| {
        if (spec.source_state_id != source_state_id) continue;
        if (!symbolRefEql(spec.symbol, symbol)) continue;
        return true;
    }
    return false;
}

fn canUseSuccessorSeedStateCache(options: BuildOptions) bool {
    _ = options;
    return false;
}

pub fn minimizeWordToken(grammar: syntax_ir.SyntaxGrammar) ?syntax_ir.SymbolRef {
    const word_token = grammar.word_token orelse return null;
    switch (word_token) {
        .terminal => return word_token,
        .non_terminal => |index| {
            if (index >= grammar.variables.len) return null;
            const variable = grammar.variables[index];
            if (variable.productions.len != 1) return null;
            const steps = variable.productions[0].steps;
            if (steps.len != 1) return null;
            return switch (steps[0].symbol) {
                .terminal => steps[0].symbol,
                else => null,
            };
        },
        else => return null,
    }
}

fn unitReductionOptionsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    field_productions: []const ProductionInfo,
    grammar: syntax_ir.SyntaxGrammar,
    simple_alias_symbols: []const syntax_ir.SymbolRef,
    production_info_ids: []const ?u16,
) !minimize.UnitReductionOptions {
    const variable_count = variableCountFromProductions(productions);
    const variable_has_fields = try computeVariableHasFieldsAlloc(allocator, field_productions, variable_count);
    defer allocator.free(variable_has_fields);

    const production_infos = try allocator.alloc(minimize.UnitReductionProduction, productions.len);
    errdefer allocator.free(production_infos);
    for (productions, 0..) |production, production_id| {
        production_infos[production_id] = .{
            .lhs = production.lhs,
            .child_count = @intCast(@min(production.steps.len, std.math.maxInt(u16))),
            .dynamic_precedence = production.dynamic_precedence,
            .metadata_empty = productionMetadataEmptyForUnitReduction(productions, variable_has_fields, production),
            .production_info_id = if (production_id < production_info_ids.len) production_info_ids[production_id] else null,
        };
    }

    const symbol_infos = try allocator.alloc(minimize.UnitReductionSymbol, variable_count);
    errdefer allocator.free(symbol_infos);
    for (symbol_infos, 0..) |*info, index| {
        info.* = .{
            .kind = if (index < grammar.variables.len) grammar.variables[index].kind else variableKindFromProductions(productions, @intCast(index)),
            .simple_alias = symbolRefIn(simple_alias_symbols, .{ .non_terminal = @intCast(index) }),
            .supertype = symbolRefIn(grammar.supertype_symbols, .{ .non_terminal = @intCast(index) }),
            .extra = symbolRefIn(grammar.extra_symbols, .{ .non_terminal = @intCast(index) }),
            .aliased = symbolIsAliasedInGrammar(grammar, .{ .non_terminal = @intCast(index) }),
        };
    }

    return .{
        .productions = production_infos,
        .symbols = symbol_infos,
    };
}

fn freeUnitReductionOptions(allocator: std.mem.Allocator, options: minimize.UnitReductionOptions) void {
    allocator.free(options.productions);
    allocator.free(options.symbols);
}

const ReduceProductionMetadata = struct {
    aliases: []const ReduceProductionAlias,
    fields: []const ReduceProductionField,

    fn deinit(self: ReduceProductionMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.aliases);
        allocator.free(self.fields);
    }
};

const ReduceProductionAlias = struct {
    step_index: u16,
    name: []const u8,
    named: bool,
};

const ReduceProductionField = struct {
    name: []const u8,
    child_index: u8,
    inherited: bool,
};

const ReduceMetadataVisitState = enum { pending, visiting, done };

fn productionInfoIdsForCompletedItemsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    field_productions: []const ProductionInfo,
    parse_states: []const state.ParseState,
) ![]const ?u16 {
    const ids = try allocator.alloc(?u16, productions.len);
    errdefer allocator.free(ids);
    @memset(ids, null);

    const variable_fields = try buildInheritedFieldNamesForReduceMetadataAlloc(allocator, productions, field_productions);
    defer {
        for (variable_fields) |fields| allocator.free(fields);
        allocator.free(variable_fields);
    }

    var metadata = std.ArrayListUnmanaged(ReduceProductionMetadata).empty;
    defer {
        for (metadata.items) |entry| entry.deinit(allocator);
        metadata.deinit(allocator);
    }

    for (parse_states) |parse_state| {
        for (parse_state.items) |entry| {
            if (entry.item.production_id >= productions.len) continue;
            const production = productions[entry.item.production_id];
            if (production.augmented or entry.item.step_index != production.steps.len) continue;
            try ensureProductionInfoIdForProduction(
                allocator,
                productions,
                variable_fields,
                &metadata,
                ids,
                entry.item.production_id,
            );
        }
    }

    return ids;
}

fn ensureProductionInfoIdForProduction(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    variable_fields: []const []const []const u8,
    metadata: *std.ArrayListUnmanaged(ReduceProductionMetadata),
    ids: []?u16,
    production_id: item.ProductionId,
) !void {
    if (production_id >= productions.len or ids[production_id] != null) return;

    var current = try reduceProductionMetadataAlloc(allocator, productions, variable_fields, productions[production_id]);
    errdefer current.deinit(allocator);
    if (findReduceProductionMetadata(metadata.items, current)) |existing| {
        current.deinit(allocator);
        ids[production_id] = @intCast(@min(existing, std.math.maxInt(u16)));
    } else {
        const new_id = metadata.items.len;
        try metadata.append(allocator, current);
        ids[production_id] = @intCast(@min(new_id, std.math.maxInt(u16)));
    }
}

fn reduceProductionMetadataAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    variable_fields: []const []const []const u8,
    production: ProductionInfo,
) !ReduceProductionMetadata {
    var aliases = std.ArrayListUnmanaged(ReduceProductionAlias).empty;
    errdefer aliases.deinit(allocator);
    var fields = std.ArrayListUnmanaged(ReduceProductionField).empty;
    errdefer fields.deinit(allocator);

    for (production.steps, 0..) |step, step_index| {
        if (step.alias) |alias| {
            try aliases.append(allocator, .{
                .step_index = @intCast(@min(step_index, std.math.maxInt(u16))),
                .name = alias.value,
                .named = alias.named,
            });
        }

        const child_index: u8 = @intCast(@min(step_index, std.math.maxInt(u8)));
        if (step.field_name) |field_name| {
            try fields.append(allocator, .{
                .name = field_name,
                .child_index = child_index,
                .inherited = false,
            });
        }
        switch (step.symbol) {
            .non_terminal => |variable_index| {
                if (variable_index >= variable_fields.len) continue;
                if (variableIsVisibleForUnitReduction(productions, variable_index)) continue;
                for (variable_fields[variable_index]) |field_name| {
                    try fields.append(allocator, .{
                        .name = field_name,
                        .child_index = child_index,
                        .inherited = true,
                    });
                }
            },
            else => {},
        }
    }

    std.mem.sort(ReduceProductionField, fields.items, {}, reduceProductionFieldLessThan);
    return .{
        .aliases = try aliases.toOwnedSlice(allocator),
        .fields = try fields.toOwnedSlice(allocator),
    };
}

fn findReduceProductionMetadata(entries: []const ReduceProductionMetadata, candidate: ReduceProductionMetadata) ?usize {
    for (entries, 0..) |entry, index| {
        if (reduceProductionMetadataEql(entry, candidate)) return index;
    }
    return null;
}

fn reduceProductionMetadataEql(left: ReduceProductionMetadata, right: ReduceProductionMetadata) bool {
    return reduceProductionAliasSlicesEql(left.aliases, right.aliases) and
        reduceProductionFieldSlicesEql(left.fields, right.fields);
}

fn reduceProductionAliasSlicesEql(left: []const ReduceProductionAlias, right: []const ReduceProductionAlias) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (left_entry.step_index != right_entry.step_index) return false;
        if (left_entry.named != right_entry.named) return false;
        if (!std.mem.eql(u8, left_entry.name, right_entry.name)) return false;
    }
    return true;
}

fn reduceProductionFieldSlicesEql(left: []const ReduceProductionField, right: []const ReduceProductionField) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_entry, right_entry| {
        if (!std.mem.eql(u8, left_entry.name, right_entry.name)) return false;
        if (left_entry.child_index != right_entry.child_index) return false;
        if (left_entry.inherited != right_entry.inherited) return false;
    }
    return true;
}

fn reduceProductionFieldLessThan(_: void, left: ReduceProductionField, right: ReduceProductionField) bool {
    const name_order = std.mem.order(u8, left.name, right.name);
    if (name_order != .eq) return name_order == .lt;
    if (left.child_index != right.child_index) return left.child_index < right.child_index;
    return @intFromBool(left.inherited) < @intFromBool(right.inherited);
}

fn buildInheritedFieldNamesForReduceMetadataAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    field_productions: []const ProductionInfo,
) ![]const []const []const u8 {
    const variable_count = variableCountFromProductions(productions);
    const fields = try allocator.alloc([]const []const u8, variable_count);
    errdefer allocator.free(fields);
    for (fields) |*entry| entry.* = &.{};

    const states = try allocator.alloc(ReduceMetadataVisitState, variable_count);
    defer allocator.free(states);
    @memset(states, .pending);

    for (0..variable_count) |variable_index| {
        try collectInheritedFieldNamesForReduceMetadata(allocator, field_productions, fields, states, @intCast(variable_index));
    }

    return fields;
}

fn collectInheritedFieldNamesForReduceMetadata(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    fields: [][]const []const u8,
    states: []ReduceMetadataVisitState,
    variable_index: u32,
) !void {
    const index: usize = @intCast(variable_index);
    switch (states[index]) {
        .done, .visiting => return,
        .pending => {},
    }

    states[index] = .visiting;
    var names = std.ArrayListUnmanaged([]const u8).empty;
    defer names.deinit(allocator);

    for (productions) |production| {
        if (production.augmented or production.lhs != variable_index) continue;
        for (production.steps) |step| {
            if (step.field_name) |field_name| {
                if (!step.field_inherited) try appendUniqueReduceFieldName(allocator, &names, field_name);
            }
            switch (step.symbol) {
                .non_terminal => |child_index| {
                    if (child_index >= fields.len) continue;
                    if (variableIsVisibleForUnitReduction(productions, child_index)) continue;
                    try collectInheritedFieldNamesForReduceMetadata(allocator, productions, fields, states, child_index);
                    for (fields[child_index]) |field_name| {
                        try appendUniqueReduceFieldName(allocator, &names, field_name);
                    }
                },
                else => {},
            }
        }
    }

    fields[index] = try names.toOwnedSlice(allocator);
    states[index] = .done;
}

fn appendUniqueReduceFieldName(
    allocator: std.mem.Allocator,
    names: *std.ArrayListUnmanaged([]const u8),
    field_name: []const u8,
) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, field_name)) return;
    }
    try names.append(allocator, field_name);
}

fn productionMetadataEmptyForUnitReduction(
    productions: []const ProductionInfo,
    variable_has_fields: []const bool,
    production: ProductionInfo,
) bool {
    for (production.steps) |step| {
        if (step.alias != null) return false;
        if (step.field_name != null) return false;
        switch (step.symbol) {
            .non_terminal => |child| {
                if (variableIsVisibleForUnitReduction(productions, child)) continue;
                if (child < variable_has_fields.len and variable_has_fields[child]) return false;
            },
            else => {},
        }
    }
    return true;
}

const UnitReductionFieldVisitState = enum { pending, visiting, done };

fn computeVariableHasFieldsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    variable_count: usize,
) ![]const bool {
    const result = try allocator.alloc(bool, variable_count);
    @memset(result, false);
    const visit_states = try allocator.alloc(UnitReductionFieldVisitState, variable_count);
    defer allocator.free(visit_states);
    @memset(visit_states, .pending);

    for (0..variable_count) |variable_index| {
        result[variable_index] = try variableHasFields(
            productions,
            result,
            visit_states,
            @intCast(variable_index),
        );
    }
    return result;
}

fn variableHasFields(
    productions: []const ProductionInfo,
    result: []bool,
    visit_states: []UnitReductionFieldVisitState,
    variable_index: u32,
) !bool {
    const index: usize = @intCast(variable_index);
    switch (visit_states[index]) {
        .done => return result[index],
        .visiting => return result[index],
        .pending => {},
    }

    visit_states[index] = .visiting;
    var has_fields = false;
    for (productions) |production| {
        if (production.augmented or production.lhs != variable_index) continue;
        for (production.steps) |step| {
            if (step.field_name != null and !step.field_inherited) {
                has_fields = true;
                break;
            }
            switch (step.symbol) {
                .non_terminal => |child| {
                    if (child >= result.len) continue;
                    if (variableIsVisibleForUnitReduction(productions, child)) continue;
                    if (try variableHasFields(productions, result, visit_states, child)) {
                        has_fields = true;
                        break;
                    }
                },
                else => {},
            }
        }
        if (has_fields) break;
    }

    result[index] = has_fields;
    visit_states[index] = .done;
    return has_fields;
}

fn variableKindFromProductions(productions: []const ProductionInfo, variable_index: u32) syntax_ir.VariableKind {
    for (productions) |production| {
        if (!production.augmented and production.lhs == variable_index) return production.lhs_kind;
    }
    return .named;
}

fn variableIsVisibleForUnitReduction(productions: []const ProductionInfo, variable_index: u32) bool {
    const kind = variableKindFromProductions(productions, variable_index);
    return kind == .named or kind == .anonymous;
}

fn symbolIsAliasedInGrammar(grammar: syntax_ir.SyntaxGrammar, symbol: syntax_ir.SymbolRef) bool {
    for (grammar.variables) |variable| {
        for (variable.productions) |production| {
            for (production.steps) |step| {
                if (step.alias == null) continue;
                if (symbolRefEql(step.symbol, symbol)) return true;
            }
        }
    }
    return false;
}

fn collectReservedWordContextNamesAlloc(
    allocator: std.mem.Allocator,
    grammar: syntax_ir.SyntaxGrammar,
) std.mem.Allocator.Error![]const []const u8 {
    var names = std.array_list.Managed([]const u8).init(allocator);
    defer names.deinit();

    for (grammar.variables) |variable| {
        for (variable.productions) |production| {
            for (production.steps) |step| {
                const name = step.reserved_context_name orelse continue;
                if (reservedContextIndex(names.items, name) == null) {
                    try names.append(name);
                }
            }
        }
    }

    return try names.toOwnedSlice();
}

fn reservedContextIndex(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, target)) return index;
    }
    return null;
}

fn reservedWordSetIdForStep(step: syntax_ir.ProductionStep, names: []const []const u8) u16 {
    const context_name = step.reserved_context_name orelse {
        return if (names.len == 0) 0 else 1;
    };
    const index = reservedContextIndex(names, context_name) orelse return 0;
    return @intCast(@min(index + 1, std.math.maxInt(u16)));
}

fn reservedFirstSetIdForSymbolRef(symbol: syntax_ir.SymbolRef, ids: []const u16) u16 {
    return switch (symbol) {
        .non_terminal => |index| if (index < ids.len) ids[index] else 0,
        else => 0,
    };
}

fn computeReservedFirstSetIdsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    reserved_word_context_names: []const []const u8,
    variable_count: usize,
) ![]const u16 {
    const result = try allocator.alloc(u16, variable_count);
    @memset(result, 0);

    var processed = try allocator.alloc(bool, variable_count);
    defer allocator.free(processed);
    var stack = std.array_list.Managed(u32).init(allocator);
    defer stack.deinit();

    for (0..variable_count) |root_index| {
        @memset(processed, false);
        stack.clearRetainingCapacity();
        try stack.append(@intCast(root_index));
        while (stack.items.len > 0) {
            const current = stack.pop().?;
            if (current >= variable_count) continue;

            for (productions) |production| {
                if (production.augmented) continue;
                if (production.lhs != current) continue;
                if (production.steps.len == 0) continue;

                const step = production.steps[0];
                result[root_index] = @max(
                    result[root_index],
                    reservedWordSetIdForStep(step, reserved_word_context_names),
                );
                switch (step.symbol) {
                    .non_terminal => |next| {
                        if (next >= variable_count) continue;
                        if (processed[next]) continue;
                        processed[next] = true;
                        try stack.append(next);
                    },
                    else => {},
                }
            }
        }
    }

    return result;
}

fn reservedWordSetIdForParseState(
    parse_state: state.ParseState,
    productions: []const ProductionInfo,
    word_token: ?syntax_ir.SymbolRef,
    reserved_word_context_names: []const []const u8,
) u16 {
    const token = word_token orelse return 0;
    var result: u16 = 0;
    for (parse_state.items) |entry| {
        if (entry.item.production_id >= productions.len) continue;
        const production = productions[entry.item.production_id];
        if (entry.item.step_index < production.steps.len) {
            const step = production.steps[entry.item.step_index];
            if (symbolRefEql(step.symbol, token)) {
                result = @max(result, reservedWordSetIdForStep(step, reserved_word_context_names));
            }
        } else if (item.containsLookahead(entry.lookaheads, token)) {
            result = @max(result, entry.following_reserved_word_set_id);
        }
    }
    return result;
}

pub const ProductionInfo = struct {
    lhs: u32,
    lhs_kind: syntax_ir.VariableKind = .named,
    steps: []const syntax_ir.ProductionStep,
    lhs_is_repeat_auxiliary: bool = false,
    augmented: bool = false,
    dynamic_precedence: i32 = 0,
    production_metadata_eligible: bool = true,
};

pub const BuildResult = struct {
    productions: []const ProductionInfo,
    reduce_production_info_ids: []const ?u16 = &.{},
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    expected_conflicts: []const []const syntax_ir.SymbolRef = &.{},
    states: []const state.ParseState,
    lex_state_count: usize,
    lex_state_terminal_sets: []const []const bool = &.{},
    fragile_token_sets: []const []const bool = &.{},
    external_internal_tokens: []const bool = &.{},
    recovery_coincident_tokens: []const bool = &.{},
    recovery_coincident_terminal_count: usize = 0,
    actions: actions.ActionTable,
    resolved_actions: resolution.ResolvedActionTable,

    pub fn hasUnresolvedDecisions(self: BuildResult) bool {
        return self.resolved_actions.hasUnresolvedDecisions();
    }

    pub fn hasBlockingUnresolvedDecisions(self: BuildResult) bool {
        return self.resolved_actions.hasBlockingUnresolvedDecisions();
    }

    pub fn isSerializationReady(self: BuildResult) bool {
        return self.resolved_actions.isSerializationReady();
    }

    pub fn validateBlockingConflictPolicy(self: BuildResult) error{UnresolvedDecisions}!void {
        if (self.hasBlockingUnresolvedDecisions()) return error.UnresolvedDecisions;
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

    pub fn expectedConflictCandidatesAlloc(
        self: BuildResult,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const conflict_resolution.ConflictCandidate {
        return self.resolved_actions.expectedConflictCandidatesAlloc(allocator, self.productions, self.states);
    }

    pub fn unusedExpectedConflictIndexesAlloc(
        self: BuildResult,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const usize {
        return self.resolved_actions.unusedExpectedConflictIndexesAlloc(
            allocator,
            self.expected_conflicts,
            self.productions,
            self.states,
        );
    }
};

const AssignedLexStates = struct {
    states: []const state.ParseState,
    count: usize,
    terminal_sets: []const []const bool,
};

fn terminalCountForResolvedActions(resolved_actions: resolution.ResolvedActionTable) usize {
    var count: usize = 0;
    for (resolved_actions.states) |resolved_state| {
        for (resolved_state.groups) |group| {
            switch (group.symbol) {
                .terminal => |index| count = @max(count, index + 1),
                .end, .non_terminal, .external => {},
            }
        }
    }
    return count;
}

const LexStateAssignmentOptions = struct {
    word_token: ?syntax_ir.SymbolRef = null,
    reserved_word_sets: []const []const syntax_ir.SymbolRef = &.{},
    coincident_tokens: []const bool = &.{},
    state_zero_error_recovery: bool = false,
};

fn assignLexStateIdsAlloc(
    allocator: std.mem.Allocator,
    parse_states: []const state.ParseState,
    resolved_actions: resolution.ResolvedActionTable,
    terminal_conflicts: ?LexStateTerminalConflictMap,
    options: LexStateAssignmentOptions,
) std.mem.Allocator.Error!AssignedLexStates {
    if (parse_states.len == 0) {
        return .{
            .states = &.{},
            .count = 0,
            .terminal_sets = &.{},
        };
    }

    const terminal_count = if (terminal_conflicts) |terminal_conflict_map|
        @max(terminalCountForResolvedActions(resolved_actions), terminal_conflict_map.terminal_count)
    else
        terminalCountForResolvedActions(resolved_actions);
    const assigned_states = try allocator.dupe(state.ParseState, parse_states);
    errdefer allocator.free(assigned_states);
    var terminal_sets = std.array_list.Managed([]bool).init(allocator);
    errdefer {
        for (terminal_sets.items) |terminal_set| allocator.free(terminal_set);
        terminal_sets.deinit();
    }
    var lex_state_ids = LexStateIdByTerminalSet.init(allocator);
    defer lex_state_ids.deinit();

    const trace_merges = shouldTraceLexStateMerges();
    const trace_limit = envUsizeRaw("GEN_Z_SITTER_LEX_STATE_MERGE_TRACE_LIMIT", 128);
    var trace_printed: usize = 0;
    var trace_union_merges: usize = 0;
    var owner_counts: []usize = &.{};
    if (trace_merges) {
        owner_counts = try allocator.alloc(usize, parse_states.len);
        @memset(owner_counts, 0);
    }
    defer if (trace_merges) allocator.free(owner_counts);

    var allocated_coincident_tokens: []bool = &.{};
    const coincident_tokens: []const bool = if (options.coincident_tokens.len == terminal_count * terminal_count)
        options.coincident_tokens
    else blk: {
        if (terminal_conflicts == null or terminal_count == 0) break :blk &.{};
        allocated_coincident_tokens = try buildCoincidentTerminalMapAlloc(allocator, resolved_actions, terminal_count);
        break :blk allocated_coincident_tokens;
    };
    defer {
        if (allocated_coincident_tokens.len != 0) allocator.free(allocated_coincident_tokens);
    }

    var next_id: state.LexStateId = 0;
    for (assigned_states) |*parse_state| {
        const terminal_set = try allocator.alloc(bool, terminal_count);
        @memset(terminal_set, false);
        errdefer allocator.free(terminal_set);

        if (options.state_zero_error_recovery and parse_state.id == 0) {
            if (terminal_conflicts) |terminal_conflict_map| {
                populateStateZeroRecoveryTerminalSet(terminal_set, terminal_conflict_map, coincident_tokens, options.word_token);
            } else {
                for (resolved_actions.groupsForState(parse_state.id)) |group| {
                    switch (group.symbol) {
                        .terminal => |index| terminal_set[index] = true,
                        .end, .non_terminal, .external => {},
                    }
                }
            }
        } else {
            for (resolved_actions.groupsForState(parse_state.id)) |group| {
                switch (group.symbol) {
                    .terminal => |index| terminal_set[index] = true,
                    .end, .non_terminal, .external => {},
                }
            }
        }
        addReservedWordTokensToLexSet(terminal_set, parse_state.reserved_word_set_id, options.reserved_word_sets);
        normalizeKeywordTokensInLexSet(terminal_set, terminal_conflicts, options.word_token);

        if (terminal_conflicts) |terminal_conflict_map| {
            if (assignMergedLexStateId(terminal_sets.items, terminal_set, terminal_conflict_map, coincident_tokens)) |merge| {
                parse_state.lex_state_id = merge.id;
                if (trace_merges) {
                    owner_counts[merge.id] += 1;
                    if (merge.candidate_only_count != 0 or merge.existing_only_count != 0) {
                        trace_union_merges += 1;
                        if (trace_printed < trace_limit) {
                            traceLexStateMerge(
                                parse_state.id,
                                merge,
                                terminal_sets.items[merge.id],
                                terminal_set,
                                terminal_conflict_map,
                                owner_counts[merge.id],
                            );
                            trace_printed += 1;
                        }
                    }
                }
                mergeTerminalSet(terminal_sets.items[merge.id], terminal_set);
                allocator.free(terminal_set);
                continue;
            }

            try terminal_sets.append(terminal_set);
            parse_state.lex_state_id = next_id;
            if (trace_merges) {
                owner_counts[next_id] = 1;
                if (trace_printed < trace_limit) {
                    traceLexStateNewGroup(parse_state.id, next_id, terminal_set, terminal_conflict_map);
                    trace_printed += 1;
                }
            }
            next_id += 1;
            continue;
        }

        const gop = try lex_state_ids.getOrPut(terminal_set);
        if (gop.found_existing) {
            allocator.free(terminal_set);
            parse_state.lex_state_id = gop.value_ptr.*;
            if (trace_merges) owner_counts[gop.value_ptr.*] += 1;
            continue;
        }

        gop.key_ptr.* = terminal_set;
        gop.value_ptr.* = next_id;
        try terminal_sets.append(terminal_set);
        parse_state.lex_state_id = next_id;
        if (trace_merges) {
            owner_counts[next_id] = 1;
        }
        next_id += 1;
    }

    if (trace_merges) {
        std.debug.print(
            "[lex-state-merge-summary] states={d} lex_states={d} union_merges={d} printed={d} terminal_count={d}\n",
            .{ assigned_states.len, next_id, trace_union_merges, trace_printed, terminal_count },
        );
        if (terminal_conflicts) |terminal_conflict_map| {
            traceLexStateGroups(terminal_sets.items, owner_counts[0..next_id], terminal_conflict_map, trace_limit);
        }
    }

    return .{
        .states = assigned_states,
        .count = next_id,
        .terminal_sets = try terminal_sets.toOwnedSlice(),
    };
}

const LexStateMerge = struct {
    id: state.LexStateId,
    existing_count: usize,
    candidate_count: usize,
    shared_count: usize,
    existing_only_count: usize,
    candidate_only_count: usize,
    union_count: usize,
};

fn assignMergedLexStateId(
    terminal_sets: []const []bool,
    candidate: []const bool,
    terminal_conflict_map: LexStateTerminalConflictMap,
    coincident_tokens: []const bool,
) ?LexStateMerge {
    for (terminal_sets, 0..) |terminal_set, index| {
        if (!terminalSetsCanMerge(terminal_set, candidate, terminal_conflict_map, coincident_tokens)) continue;
        const merge = lexStateMergeStats(@intCast(index), terminal_set, candidate);
        return merge;
    }
    return null;
}

fn addReservedWordTokensToLexSet(
    terminal_set: []bool,
    reserved_word_set_id: u16,
    reserved_word_sets: []const []const syntax_ir.SymbolRef,
) void {
    if (reserved_word_set_id >= reserved_word_sets.len) return;
    for (reserved_word_sets[reserved_word_set_id]) |reserved_word| {
        switch (reserved_word) {
            .terminal => |index| {
                if (index < terminal_set.len) terminal_set[index] = true;
            },
            .end, .non_terminal, .external => {},
        }
    }
}

fn normalizeKeywordTokensInLexSet(
    terminal_set: []bool,
    terminal_conflicts: ?LexStateTerminalConflictMap,
    word_token: ?syntax_ir.SymbolRef,
) void {
    const word_index = switch (word_token orelse syntax_ir.SymbolRef{ .end = {} }) {
        .terminal => |index| index,
        .end, .non_terminal, .external => return,
    };
    if (word_index >= terminal_set.len) return;
    const conflict_map = terminal_conflicts orelse return;

    var saw_keyword = false;
    for (conflict_map.keyword_tokens, 0..) |is_keyword, token_index| {
        if (!is_keyword or token_index >= terminal_set.len or !terminal_set[token_index]) continue;
        terminal_set[token_index] = false;
        saw_keyword = true;
    }
    if (saw_keyword) terminal_set[word_index] = true;
}

fn populateStateZeroRecoveryTerminalSet(
    terminal_set: []bool,
    terminal_conflict_map: LexStateTerminalConflictMap,
    coincident_tokens: []const bool,
    word_token: ?syntax_ir.SymbolRef,
) void {
    const terminal_count = @min(terminal_set.len, terminal_conflict_map.terminal_count);
    for (0..terminal_count) |index| {
        const conflict_free = stateZeroRecoveryTokenIsConflictFree(index, terminal_conflict_map, coincident_tokens);
        const include = conflict_free or
            terminal_conflict_map.isKeyword(index) or
            symbolRefEql(word_token orelse .{ .end = {} }, .{ .terminal = @intCast(index) }) or
            !stateZeroRecoveryTokenConflictsWithConflictFree(index, terminal_conflict_map, coincident_tokens);
        terminal_set[index] = include;
    }
}

fn stateZeroRecoveryTokenIsConflictFree(
    token: usize,
    terminal_conflict_map: LexStateTerminalConflictMap,
    coincident_tokens: []const bool,
) bool {
    for (0..terminal_conflict_map.terminal_count) |other| {
        if (token == other) continue;
        if (coincidentTokenContains(coincident_tokens, terminal_conflict_map.terminal_count, token, other)) continue;
        if (terminal_conflict_map.matchesShorterOrLonger(token, other)) return false;
    }
    return true;
}

fn stateZeroRecoveryTokenConflictsWithConflictFree(
    token: usize,
    terminal_conflict_map: LexStateTerminalConflictMap,
    coincident_tokens: []const bool,
) bool {
    for (0..terminal_conflict_map.terminal_count) |other| {
        if (!stateZeroRecoveryTokenIsConflictFree(other, terminal_conflict_map, coincident_tokens)) continue;
        if (coincidentTokenContains(coincident_tokens, terminal_conflict_map.terminal_count, token, other)) continue;
        if (terminal_conflict_map.conflictsWith(token, other)) return true;
    }
    return false;
}

fn lexStateMergeStats(
    id: state.LexStateId,
    existing: []const bool,
    candidate: []const bool,
) LexStateMerge {
    var existing_count: usize = 0;
    var candidate_count: usize = 0;
    var shared_count: usize = 0;
    var existing_only_count: usize = 0;
    var candidate_only_count: usize = 0;
    for (existing, 0..) |existing_present, index| {
        const candidate_present = index < candidate.len and candidate[index];
        if (existing_present) existing_count += 1;
        if (candidate_present) candidate_count += 1;
        if (existing_present and candidate_present) {
            shared_count += 1;
        } else if (existing_present) {
            existing_only_count += 1;
        } else if (candidate_present) {
            candidate_only_count += 1;
        }
    }
    return .{
        .id = id,
        .existing_count = existing_count,
        .candidate_count = candidate_count,
        .shared_count = shared_count,
        .existing_only_count = existing_only_count,
        .candidate_only_count = candidate_only_count,
        .union_count = existing_count + candidate_only_count,
    };
}

fn terminalSetsCanMerge(
    existing: []const bool,
    candidate: []const bool,
    terminal_conflict_map: LexStateTerminalConflictMap,
    coincident_tokens: []const bool,
) bool {
    for (existing, 0..) |existing_present, existing_index| {
        if (!existing_present or candidate[existing_index]) continue;
        if (tokenConflictsWithSet(existing_index, candidate, terminal_conflict_map, coincident_tokens)) return false;
    }
    for (candidate, 0..) |candidate_present, candidate_index| {
        if (!candidate_present or existing[candidate_index]) continue;
        if (tokenConflictsWithSet(candidate_index, existing, terminal_conflict_map, coincident_tokens)) return false;
    }
    return true;
}

fn tokenConflictsWithSet(
    token: usize,
    other_set: []const bool,
    terminal_conflict_map: LexStateTerminalConflictMap,
    coincident_tokens: []const bool,
) bool {
    for (other_set, 0..) |other_present, other| {
        if (!other_present) continue;
        if (terminal_conflict_map.conflictsOrPrefixesWith(token, other)) return true;
        if (terminal_conflict_map.mergeOverlapsWith(token, other) or terminal_conflict_map.mergeOverlapsWith(other, token)) {
            if (!coincidentTokenContains(coincident_tokens, terminal_conflict_map.terminal_count, token, other)) {
                return true;
            }
        }
    }
    return false;
}

fn buildCoincidentTerminalMapAlloc(
    allocator: std.mem.Allocator,
    resolved_actions: resolution.ResolvedActionTable,
    terminal_count: usize,
) std.mem.Allocator.Error![]bool {
    const values = try allocator.alloc(bool, terminal_count * terminal_count);
    @memset(values, false);

    var terminals = std.array_list.Managed(usize).init(allocator);
    defer terminals.deinit();

    for (resolved_actions.states) |resolved_state| {
        terminals.clearRetainingCapacity();
        for (resolved_state.groups) |group| {
            const terminal = switch (group.symbol) {
                .terminal => |index| index,
                .end, .non_terminal, .external => continue,
            };
            if (terminal >= terminal_count) continue;

            var seen = false;
            for (terminals.items) |existing| {
                if (existing == terminal) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try terminals.append(terminal);
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
    if (left >= terminal_count or right >= terminal_count) return false;
    if (values.len != terminal_count * terminal_count) return false;
    return values[left * terminal_count + right];
}

fn mergeTerminalSet(existing: []bool, candidate: []const bool) void {
    for (candidate, 0..) |present, index| {
        if (present) existing[index] = true;
    }
}

fn traceLexStateMerge(
    parse_state_id: state.StateId,
    merge: LexStateMerge,
    existing_set: []const bool,
    candidate_set: []const bool,
    terminal_conflict_map: LexStateTerminalConflictMap,
    owner_count: usize,
) void {
    std.debug.print(
        "[lex-state-merge] state={d} into={d} owners={d} existing={d} candidate={d} shared={d} existing_only={d} candidate_only={d} union={d} candidate_only_tokens=",
        .{
            parse_state_id,
            merge.id,
            owner_count,
            merge.existing_count,
            merge.candidate_count,
            merge.shared_count,
            merge.existing_only_count,
            merge.candidate_only_count,
            merge.union_count,
        },
    );
    traceTerminalSetDiffTokens(existing_set, candidate_set, terminal_conflict_map, .candidate_only, 24);
    std.debug.print(" existing_only_tokens=", .{});
    traceTerminalSetDiffTokens(existing_set, candidate_set, terminal_conflict_map, .existing_only, 24);
    std.debug.print("\n", .{});
}

fn traceLexStateNewGroup(
    parse_state_id: state.StateId,
    lex_state_id: state.LexStateId,
    terminal_set: []const bool,
    terminal_conflict_map: LexStateTerminalConflictMap,
) void {
    std.debug.print(
        "[lex-state-new-group] state={d} id={d} terminals={d} tokens=",
        .{ parse_state_id, lex_state_id, countTerminalSet(terminal_set) },
    );
    traceTerminalSetTokens(terminal_set, terminal_conflict_map, 64);
    std.debug.print("\n", .{});
}

const TerminalDiffKind = enum {
    candidate_only,
    existing_only,
};

fn traceTerminalSetTokens(
    terminal_set: []const bool,
    terminal_conflict_map: LexStateTerminalConflictMap,
    limit: usize,
) void {
    std.debug.print("[", .{});
    var printed: usize = 0;
    for (terminal_set, 0..) |present, index| {
        if (!present) continue;
        if (printed != 0) std.debug.print(",", .{});
        traceTerminalName(index, terminal_conflict_map);
        printed += 1;
        if (printed >= limit) break;
    }
    if (printed >= limit) std.debug.print(",...", .{});
    std.debug.print("]", .{});
}

fn traceTerminalSetDiffTokens(
    existing_set: []const bool,
    candidate_set: []const bool,
    terminal_conflict_map: LexStateTerminalConflictMap,
    kind: TerminalDiffKind,
    limit: usize,
) void {
    std.debug.print("[", .{});
    var printed: usize = 0;
    for (existing_set, 0..) |existing_present, index| {
        const candidate_present = index < candidate_set.len and candidate_set[index];
        const include = switch (kind) {
            .candidate_only => candidate_present and !existing_present,
            .existing_only => existing_present and !candidate_present,
        };
        if (!include) continue;
        if (printed != 0) std.debug.print(",", .{});
        traceTerminalName(index, terminal_conflict_map);
        printed += 1;
        if (printed >= limit) break;
    }
    if (printed >= limit) std.debug.print(",...", .{});
    std.debug.print("]", .{});
}

fn traceLexStateGroups(
    terminal_sets: []const []bool,
    owner_counts: []const usize,
    terminal_conflict_map: LexStateTerminalConflictMap,
    limit: usize,
) void {
    for (terminal_sets, 0..) |terminal_set, index| {
        if (index >= limit) break;
        std.debug.print(
            "[lex-state-group] id={d} owners={d} terminals={d} tokens=",
            .{ index, if (index < owner_counts.len) owner_counts[index] else 0, countTerminalSet(terminal_set) },
        );
        traceTerminalSetTokens(terminal_set, terminal_conflict_map, 64);
        std.debug.print("\n", .{});
    }
}

fn countTerminalSet(terminal_set: []const bool) usize {
    var count: usize = 0;
    for (terminal_set) |present| {
        if (present) count += 1;
    }
    return count;
}

fn traceTerminalName(index: usize, terminal_conflict_map: LexStateTerminalConflictMap) void {
    if (index < terminal_conflict_map.terminal_names.len and terminal_conflict_map.terminal_names[index].len != 0) {
        std.debug.print("{d}:{s}", .{ index, terminal_conflict_map.terminal_names[index] });
    } else {
        std.debug.print("{d}", .{index});
    }
}

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
    const profile_log = shouldProfileBuild();
    const profile_capture = options.construct_profile != null;
    const profile_enabled = profile_log or profile_capture;
    const build_profile_timer = profileTimer(profile_log);
    if (profile_enabled) {
        item.resetSymbolSetProfile();
        item.setSymbolSetProfileEnabled(true);
        resetConstructProfile();
        construct_profile_enabled = true;
    }
    defer if (profile_enabled) {
        if (profile_log) {
            logProfileDone("build_states_total", build_profile_timer);
            logSymbolSetProfile();
            logConstructProfile();
        }
        if (options.construct_profile) |profile| {
            const symbol_set_profile = item.symbolSetProfile();
            construct_profile.symbol_set_init_empty_count = symbol_set_profile.init_empty_count;
            construct_profile.symbol_set_clone_count = symbol_set_profile.clone_count;
            construct_profile.symbol_set_free_count = symbol_set_profile.free_count;
            construct_profile.symbol_set_alloc_bytes = symbol_set_profile.bool_alloc_bytes;
            construct_profile.symbol_set_free_bytes = symbol_set_profile.bool_free_bytes;
            profile.* = construct_profile;
        }
        item.setSymbolSetProfileEnabled(false);
        construct_profile_enabled = false;
    };
    if (progress_log) std.debug.print("[parse_table/build] buildStatesWithOptions enter\n", .{});
    try validateSupportedSubset(grammar);

    var timer = maybeStartTimer(progress_log);
    var stage_profile_timer = profileTimer(profile_log);
    if (progress_log) std.debug.print("[parse_table/build] stage compute_first_sets\n", .{});
    if (progress_log) logBuildStart("compute_first_sets");
    const first_sets = try first.computeFirstSets(allocator, grammar);
    logProfileDone("compute_first_sets", stage_profile_timer);
    if (progress_log) maybeLogBuildDone("compute_first_sets", timer);

    timer = maybeStartTimer(progress_log);
    stage_profile_timer = profileTimer(profile_log);
    if (progress_log) std.debug.print("[parse_table/build] stage collect_productions\n", .{});
    if (progress_log) logBuildStart("collect_productions");
    const productions = try collectProductions(allocator, grammar);
    logProfileDone("collect_productions", stage_profile_timer);
    if (progress_log) {
        maybeLogBuildDone("collect_productions", timer);
        logBuildSummary("collect_productions summary productions={d}", .{productions.len});
    }

    const uses_option_reserved_contexts = options.reserved_word_context_names.len != 0;
    const reserved_word_context_names = if (uses_option_reserved_contexts)
        options.reserved_word_context_names
    else
        try collectReservedWordContextNamesAlloc(allocator, grammar);
    defer if (!uses_option_reserved_contexts) allocator.free(reserved_word_context_names);

    stage_profile_timer = profileTimer(profile_log);
    var item_set_builder = try ParseItemSetBuilder.init(
        allocator,
        productions,
        first_sets,
        reserved_word_context_names,
        grammar.word_token,
        grammar.variables_to_inline,
        grammar.variables,
    );
    logProfileDone("item_set_builder_init", stage_profile_timer);
    defer item_set_builder.deinit();

    timer = maybeStartTimer(progress_log);
    stage_profile_timer = profileTimer(profile_log);
    if (progress_log) std.debug.print("[parse_table/build] stage construct_states\n", .{});
    if (progress_log) logBuildStart("construct_states");
    const constructed = try constructStates(allocator, grammar.variables, productions, first_sets, item_set_builder, options);
    logProfileDone("construct_states", stage_profile_timer);
    if (progress_log) {
        maybeLogBuildDone("construct_states", timer);
        logBuildSummary(
            "construct_states summary states={d} action_states={d}",
            .{ constructed.states.len, constructed.grouped_actions.states.len },
        );
    }
    timer = maybeStartTimer(progress_log);
    stage_profile_timer = profileTimer(profile_log);
    if (progress_log) std.debug.print("[parse_table/build] stage resolve_action_table\n", .{});
    if (progress_log) logBuildStart("resolve_action_table");
    const resolved_actions = try resolution.resolveActionTableWithFirstSetsContext(
        allocator,
        item_set_builder.productions,
        grammar.precedence_orderings,
        grammar.expected_conflicts,
        constructed.states,
        first_sets,
        constructed.grouped_actions,
    );
    const resolved_actions_with_extras = try addTerminalExtraActionsAlloc(
        allocator,
        constructed.states,
        item_set_builder.productions,
        resolved_actions,
        options.terminal_extra_symbols,
        options.non_terminal_extra_symbols,
    );
    logProfileDone("resolve_action_table", stage_profile_timer);
    if (progress_log) {
        maybeLogBuildDone("resolve_action_table", timer);
        logBuildSummary(
            "resolve_action_table summary unresolved_decisions={} serialization_ready={}",
            .{ resolved_actions_with_extras.hasUnresolvedDecisions(), resolved_actions_with_extras.isSerializationReady() },
        );
    }

    var pre_minimize_coincident_tokens: []bool = &.{};
    var pre_minimize_coincident_terminal_count: usize = 0;
    if (options.lex_state_terminal_conflicts) |terminal_conflict_map| {
        const terminal_count = @max(
            terminalCountForResolvedActions(resolved_actions_with_extras),
            terminal_conflict_map.terminal_count,
        );
        if (terminal_count != 0) {
            pre_minimize_coincident_terminal_count = terminal_count;
            pre_minimize_coincident_tokens = try buildCoincidentTerminalMapAlloc(
                allocator,
                resolved_actions_with_extras,
                terminal_count,
            );
        }
    }

    const field_productions = item_set_builder.productions[0..item_set_builder.original_productions_len];
    const production_info_ids = try productionInfoIdsForCompletedItemsAlloc(
        allocator,
        item_set_builder.productions,
        field_productions,
        constructed.states,
    );

    const unit_reduction_options = try unitReductionOptionsAlloc(
        allocator,
        item_set_builder.productions,
        field_productions,
        grammar,
        options.simple_alias_symbols,
        production_info_ids,
    );
    defer freeUnitReductionOptions(allocator, unit_reduction_options);

    if (options.minimize_states) {
        timer = maybeStartTimer(progress_log);
        stage_profile_timer = profileTimer(profile_log);
        if (progress_log) logBuildStart("minimize_states");
        const minimized = try minimize.minimizeAllocWithOptions(
            allocator,
            constructed.states,
            resolved_actions_with_extras,
            if (options.lex_state_terminal_conflicts) |terminal_conflicts| terminal_conflicts.toMinimizeMap(options.reserved_word_sets) else null,
            minimizeWordToken(grammar),
            unit_reduction_options,
        );
        logProfileDone("minimize_states", stage_profile_timer);
        if (progress_log) {
            maybeLogBuildDone("minimize_states", timer);
            logBuildSummary(
                "minimize_states summary states_before={d} states_after={d} merged={d}",
                .{ constructed.states.len, minimized.states.len, minimized.merged_count },
            );
        }
        stage_profile_timer = profileTimer(profile_log);
        const minimized_lex_states = try assignLexStateIdsAlloc(
            allocator,
            minimized.states,
            minimized.resolved_actions,
            options.lex_state_terminal_conflicts,
            .{
                .word_token = minimizeWordToken(grammar),
                .reserved_word_sets = options.reserved_word_sets,
                .coincident_tokens = pre_minimize_coincident_tokens,
                .state_zero_error_recovery = options.state_zero_error_recovery,
            },
        );
        const fragile_token_sets = try buildFragileTokenSetsAlloc(
            allocator,
            minimized_lex_states.states,
            minimized.resolved_actions,
            options.lex_state_terminal_conflicts,
        );
        const external_internal_tokens = try externalInternalTokensAlloc(allocator, options.lex_state_terminal_conflicts);
        const minimized_action_projection = try actionTableFromResolvedAlloc(allocator, minimized.resolved_actions);
        logProfileDone("assign_lex_state_ids", stage_profile_timer);
        return .{
            .productions = item_set_builder.productions,
            .reduce_production_info_ids = production_info_ids,
            .precedence_orderings = grammar.precedence_orderings,
            .expected_conflicts = grammar.expected_conflicts,
            .states = minimized_lex_states.states,
            .lex_state_count = minimized_lex_states.count,
            .lex_state_terminal_sets = minimized_lex_states.terminal_sets,
            .fragile_token_sets = fragile_token_sets,
            .external_internal_tokens = external_internal_tokens,
            .recovery_coincident_tokens = pre_minimize_coincident_tokens,
            .recovery_coincident_terminal_count = pre_minimize_coincident_terminal_count,
            .actions = minimized_action_projection,
            .resolved_actions = minimized.resolved_actions,
        };
    }

    stage_profile_timer = profileTimer(profile_log);
    const lex_states = try assignLexStateIdsAlloc(
        allocator,
        constructed.states,
        resolved_actions_with_extras,
        options.lex_state_terminal_conflicts,
        .{
            .word_token = minimizeWordToken(grammar),
            .reserved_word_sets = options.reserved_word_sets,
            .coincident_tokens = pre_minimize_coincident_tokens,
            .state_zero_error_recovery = options.state_zero_error_recovery,
        },
    );
    const fragile_token_sets = try buildFragileTokenSetsAlloc(
        allocator,
        lex_states.states,
        resolved_actions_with_extras,
        options.lex_state_terminal_conflicts,
    );
    const external_internal_tokens = try externalInternalTokensAlloc(allocator, options.lex_state_terminal_conflicts);
    const constructed_action_projection = try actionTableFromResolvedAlloc(allocator, resolved_actions_with_extras);
    logProfileDone("assign_lex_state_ids", stage_profile_timer);

    return .{
        .productions = item_set_builder.productions,
        .reduce_production_info_ids = production_info_ids,
        .precedence_orderings = grammar.precedence_orderings,
        .expected_conflicts = grammar.expected_conflicts,
        .states = lex_states.states,
        .lex_state_count = lex_states.count,
        .lex_state_terminal_sets = lex_states.terminal_sets,
        .fragile_token_sets = fragile_token_sets,
        .external_internal_tokens = external_internal_tokens,
        .recovery_coincident_tokens = pre_minimize_coincident_tokens,
        .recovery_coincident_terminal_count = pre_minimize_coincident_terminal_count,
        .actions = constructed_action_projection,
        .resolved_actions = resolved_actions_with_extras,
    };
}

fn actionTableFromResolvedAlloc(
    allocator: std.mem.Allocator,
    resolved_actions: resolution.ResolvedActionTable,
) std.mem.Allocator.Error!actions.ActionTable {
    const states = try allocator.alloc(actions.StateActions, resolved_actions.states.len);
    errdefer allocator.free(states);

    for (resolved_actions.states, 0..) |resolved_state, state_index| {
        var entry_count: usize = 0;
        for (resolved_state.groups) |group| {
            entry_count += switch (group.decision) {
                .chosen => 1,
                .unresolved => group.candidate_actions.len,
            };
        }

        const entries = try allocator.alloc(actions.ActionEntry, entry_count);
        errdefer allocator.free(entries);
        var entry_index: usize = 0;
        for (resolved_state.groups) |group| {
            switch (group.decision) {
                .chosen => |action| {
                    entries[entry_index] = .{ .symbol = group.symbol, .action = action };
                    entry_index += 1;
                },
                .unresolved => {
                    for (group.candidate_actions) |action| {
                        entries[entry_index] = .{ .symbol = group.symbol, .action = action };
                        entry_index += 1;
                    }
                },
            }
        }

        states[state_index] = .{
            .state_id = resolved_state.state_id,
            .entries = entries,
        };
    }

    return .{ .states = states };
}

fn buildFragileTokenSetsAlloc(
    allocator: std.mem.Allocator,
    parse_states: []const state.ParseState,
    resolved_actions: resolution.ResolvedActionTable,
    terminal_conflicts: ?LexStateTerminalConflictMap,
) std.mem.Allocator.Error![]const []const bool {
    const conflict_map = terminal_conflicts orelse return &.{};
    if (parse_states.len == 0 or conflict_map.terminal_count == 0) return &.{};

    const result = try allocator.alloc([]const bool, parse_states.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |set| allocator.free(set);
        allocator.free(result);
    }

    var valid_terminals = std.array_list.Managed(usize).init(allocator);
    defer valid_terminals.deinit();

    for (parse_states, 0..) |parse_state, state_index| {
        const fragile = try allocator.alloc(bool, conflict_map.terminal_count);
        errdefer allocator.free(fragile);
        @memset(fragile, false);

        valid_terminals.clearRetainingCapacity();
        for (resolved_actions.groupsForState(parse_state.id)) |group| {
            const terminal = switch (group.symbol) {
                .terminal => |index| index,
                .end, .non_terminal, .external => continue,
            };
            if (terminal >= conflict_map.terminal_count) continue;
            try valid_terminals.append(terminal);
        }

        for (valid_terminals.items) |token| {
            for (valid_terminals.items) |other| {
                if (conflict_map.overlapsWith(other, token)) {
                    fragile[token] = true;
                    break;
                }
            }
        }

        result[state_index] = fragile;
        initialized += 1;
    }

    return result;
}

fn externalInternalTokensAlloc(
    allocator: std.mem.Allocator,
    terminal_conflicts: ?LexStateTerminalConflictMap,
) std.mem.Allocator.Error![]const bool {
    const conflicts_value = terminal_conflicts orelse return &.{};
    if (conflicts_value.external_internal_tokens.len == 0) return &.{};
    return try allocator.dupe(bool, conflicts_value.external_internal_tokens);
}

fn addTerminalExtraActionsAlloc(
    allocator: std.mem.Allocator,
    parse_states: []const state.ParseState,
    productions: []const ProductionInfo,
    resolved_actions: resolution.ResolvedActionTable,
    terminal_extra_symbols: []const syntax_ir.SymbolRef,
    non_terminal_extra_symbols: []const syntax_ir.SymbolRef,
) std.mem.Allocator.Error!resolution.ResolvedActionTable {
    if (terminal_extra_symbols.len == 0) return resolved_actions;

    const states = try allocator.alloc(resolution.ResolvedStateActions, resolved_actions.states.len);
    for (resolved_actions.states, 0..) |resolved_state, state_index| {
        const parse_state = if (state_index < parse_states.len) parse_states[state_index] else null;
        const add_extras = if (parse_state) |candidate|
            !isNonTerminalExtraEndStateForExtras(candidate, productions, non_terminal_extra_symbols)
        else
            true;
        var extra_count: usize = 0;
        if (add_extras) {
            for (terminal_extra_symbols) |extra_symbol| {
                switch (extra_symbol) {
                    .terminal, .external => {},
                    .end, .non_terminal => continue,
                }
                if (hasResolvedGroup(resolved_state.groups, extra_symbol)) continue;
                extra_count += 1;
            }
        }

        const groups = try allocator.alloc(resolution.ResolvedActionGroup, resolved_state.groups.len + extra_count);
        @memcpy(groups[0..resolved_state.groups.len], resolved_state.groups);
        var group_index = resolved_state.groups.len;
        if (add_extras) {
            for (terminal_extra_symbols) |extra_symbol| {
                switch (extra_symbol) {
                    .terminal, .external => {},
                    .end, .non_terminal => continue,
                }
                if (hasResolvedGroup(resolved_state.groups, extra_symbol)) continue;
                groups[group_index] = .{
                    .symbol = extra_symbol,
                    .candidate_actions = &[_]actions.ParseAction{.{ .shift_extra = {} }},
                    .decision = .{ .chosen = .{ .shift_extra = {} } },
                };
                group_index += 1;
            }
        }
        std.mem.sort(resolution.ResolvedActionGroup, groups, {}, resolvedActionGroupLessThan);
        states[state_index] = .{
            .state_id = resolved_state.state_id,
            .groups = groups,
        };
    }

    return .{ .states = states };
}

fn hasResolvedGroup(groups: []const resolution.ResolvedActionGroup, symbol: syntax_ir.SymbolRef) bool {
    for (groups) |group| {
        if (symbolRefEql(group.symbol, symbol)) return true;
    }
    return false;
}

fn resolvedActionGroupLessThan(_: void, left: resolution.ResolvedActionGroup, right: resolution.ResolvedActionGroup) bool {
    return symbolRefLessThan(left.symbol, right.symbol);
}

fn symbolRefLessThan(left: syntax_ir.SymbolRef, right: syntax_ir.SymbolRef) bool {
    return symbolRefSortKey(left) < symbolRefSortKey(right);
}

fn symbolRefSortKey(symbol: syntax_ir.SymbolRef) u64 {
    return switch (symbol) {
        .external => |index| index,
        .end => @as(u64, 1) << 32,
        .terminal => |index| (@as(u64, 3) << 32) | index,
        .non_terminal => |index| (@as(u64, 4) << 32) | index,
    };
}

fn isNonTerminalExtraEndStateForExtras(
    parse_state: state.ParseState,
    productions: []const ProductionInfo,
    non_terminal_extra_symbols: []const syntax_ir.SymbolRef,
) bool {
    for (parse_state.items) |entry| {
        if (!item.containsLookahead(entry.lookaheads, .{ .end = {} })) continue;
        if (entry.item.production_id >= productions.len) continue;
        const production = productions[entry.item.production_id];
        if (entry.item.step_index != production.steps.len) continue;
        if (symbolRefIn(non_terminal_extra_symbols, .{ .non_terminal = production.lhs })) return true;
    }
    return false;
}

const ConstructedStates = struct {
    states: []const state.ParseState,
    grouped_actions: actions.GroupedActionTable,
};

fn countGroupedActions(groups: []const actions.ActionGroup) usize {
    var count: usize = 0;
    for (groups) |group| count += group.actions.len;
    return count;
}

const NonTerminalExtraStart = struct {
    symbol: syntax_ir.SymbolRef,
    state_id: state.StateId,
};

const CoreKeyStore = struct {
    allocator: std.mem.Allocator,
    keys: std.array_list.Managed(item.ParseItemSetCore),

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .keys = std.array_list.Managed(item.ParseItemSetCore).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        for (self.keys.items) |key| {
            self.allocator.free(key.items);
        }
        self.keys.deinit();
    }

    fn internFromEntries(
        self: *@This(),
        core_ids_by_core: *CoreIdByItemSetCore,
        entries: []const item.ParseItemSetEntry,
    ) !usize {
        const core = try item.ParseItemSetCore.fromEntriesAlloc(self.allocator, entries);
        errdefer self.allocator.free(core.items);
        const result = try core_ids_by_core.getOrPut(core);
        if (result.found_existing) {
            self.allocator.free(core.items);
            return result.value_ptr.*;
        }

        const new_id = self.keys.items.len;
        result.value_ptr.* = new_id;
        try self.keys.append(core);
        return new_id;
    }
};

const StateRegistry = struct {
    allocator: std.mem.Allocator,
    states: std.array_list.Managed(state.ParseState),
    state_ids_by_item_set: StateIdByItemSet,
    item_set_keys: std.array_list.Managed([]const item.ParseItemSetEntry),
    core_ids_by_core: CoreIdByItemSetCore,
    core_key_store: CoreKeyStore,

    const InternResult = struct {
        state_id: state.StateId,
        reused: bool,
    };

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .states = std.array_list.Managed(state.ParseState).init(allocator),
            .state_ids_by_item_set = StateIdByItemSet.init(allocator),
            .item_set_keys = std.array_list.Managed([]const item.ParseItemSetEntry).init(allocator),
            .core_ids_by_core = CoreIdByItemSetCore.init(allocator),
            .core_key_store = CoreKeyStore.init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        for (self.item_set_keys.items) |entries| freeParseItemSetEntries(self.allocator, entries);
        self.item_set_keys.deinit();
        self.core_key_store.deinit();
        self.core_ids_by_core.deinit();
        self.state_ids_by_item_set.deinit();
        self.states.deinit();
    }

    fn items(self: *@This()) []state.ParseState {
        return self.states.items;
    }

    fn appendErrorState(self: *@This()) !void {
        const key_entries = try cloneParseItemSetEntries(self.allocator, &.{});
        errdefer freeParseItemSetEntries(self.allocator, key_entries);
        const core_id = try self.core_key_store.internFromEntries(&self.core_ids_by_core, key_entries);
        try self.states.append(.{
            .id = 0,
            .core_id = @intCast(core_id),
            .items = &.{},
            .transitions = &.{},
            .conflicts = &.{},
            .auxiliary_symbols = &.{},
        });
        try self.state_ids_by_item_set.put(ParseItemSetKey.fromEntries(key_entries), 0);
        try self.item_set_keys.append(key_entries);
    }

    fn appendInitialState(
        self: *@This(),
        key_item_set: item.ParseItemSet,
        stored_item_set: item.ParseItemSet,
    ) !void {
        const key_entries = try cloneParseItemSetEntries(self.allocator, key_item_set.entries);
        errdefer freeParseItemSetEntries(self.allocator, key_entries);
        const core_id = try self.core_key_store.internFromEntries(&self.core_ids_by_core, key_entries);
        try self.states.append(.{
            .id = 1,
            .core_id = @intCast(core_id),
            .items = stored_item_set.entries,
            .transitions = &.{},
            .conflicts = &.{},
            .auxiliary_symbols = &.{},
        });
        try self.state_ids_by_item_set.put(ParseItemSetKey.fromEntries(key_entries), 1);
        try self.item_set_keys.append(key_entries);
    }

    fn intern(
        self: *@This(),
        key_item_set: item.ParseItemSet,
        stored_item_set: item.ParseItemSet,
        auxiliary_symbols: []const state.AuxiliarySymbolInfo,
    ) !InternResult {
        if (construct_profile_enabled) construct_profile.state_intern_calls += 1;
        const key = ParseItemSetKey.fromEntries(key_item_set.entries);
        if (self.state_ids_by_item_set.get(key)) |existing_id| {
            freeParseItemSetEntries(self.allocator, stored_item_set.entries);
            if (construct_profile_enabled) construct_profile.state_intern_reused += 1;
            return .{
                .state_id = existing_id,
                .reused = true,
            };
        }

        const new_id: state.StateId = @intCast(self.states.items.len);
        const key_entries = try cloneParseItemSetEntries(self.allocator, key_item_set.entries);
        errdefer freeParseItemSetEntries(self.allocator, key_entries);
        const core_id = try self.core_key_store.internFromEntries(&self.core_ids_by_core, key_entries);
        try self.states.append(.{
            .id = new_id,
            .core_id = @intCast(core_id),
            .items = stored_item_set.entries,
            .transitions = &.{},
            .conflicts = &.{},
            .auxiliary_symbols = try cloneAuxiliarySymbolInfos(self.allocator, auxiliary_symbols),
        });
        try self.state_ids_by_item_set.put(ParseItemSetKey.fromEntries(key_entries), new_id);
        try self.item_set_keys.append(key_entries);
        if (construct_profile_enabled) {
            construct_profile.state_intern_new += 1;
            construct_profile.state_items_stored += stored_item_set.entries.len;
        }
        return .{
            .state_id = new_id,
            .reused = false,
        };
    }

    fn intoOwnedSlice(self: *@This()) ![]const state.ParseState {
        return try self.states.toOwnedSlice();
    }
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

fn cloneAuxiliarySymbolInfos(
    allocator: std.mem.Allocator,
    infos: []const state.AuxiliarySymbolInfo,
) ![]const state.AuxiliarySymbolInfo {
    if (infos.len == 0) return &.{};
    const cloned = try allocator.alloc(state.AuxiliarySymbolInfo, infos.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |info| allocator.free(info.parent_symbols);
        allocator.free(cloned);
    }

    for (infos, 0..) |info, index| {
        cloned[index] = .{
            .auxiliary_symbol = info.auxiliary_symbol,
            .parent_symbols = try allocator.dupe(syntax_ir.SymbolRef, info.parent_symbols),
        };
        initialized += 1;
    }
    return cloned;
}

fn freeAuxiliarySymbolInfos(
    allocator: std.mem.Allocator,
    infos: []const state.AuxiliarySymbolInfo,
) void {
    for (infos) |info| allocator.free(info.parent_symbols);
    if (infos.len != 0) allocator.free(infos);
}

fn auxiliarySymbolSequenceForSuccessorsAlloc(
    allocator: std.mem.Allocator,
    existing: []const state.AuxiliarySymbolInfo,
    state_items: []const item.ParseItemSetEntry,
    productions: []const ProductionInfo,
    item_identity_ids: []const []const u32,
    item_merge_identity_ids: []const []const u32,
    variables_to_inline: []const syntax_ir.SymbolRef,
    inline_map: process_inlines.InlinedProductionMap,
) ![]const state.AuxiliarySymbolInfo {
    var result = std.array_list.Managed(state.AuxiliarySymbolInfo).init(allocator);
    defer result.deinit();
    errdefer {
        for (result.items) |info| allocator.free(info.parent_symbols);
    }

    for (existing) |info| {
        try appendAuxiliaryInfoDedup(
            allocator,
            &result,
            .{
                .auxiliary_symbol = info.auxiliary_symbol,
                .parent_symbols = try allocator.dupe(syntax_ir.SymbolRef, info.parent_symbols),
            },
        );
    }

    for (state_items) |entry| {
        try appendAuxiliaryInfosForEntry(
            allocator,
            &result,
            entry,
            state_items,
            productions,
            item_identity_ids,
            item_merge_identity_ids,
            variables_to_inline,
            inline_map,
            0,
        );
    }

    return try result.toOwnedSlice();
}

fn appendAuxiliaryInfosForEntry(
    allocator: std.mem.Allocator,
    result: *std.array_list.Managed(state.AuxiliarySymbolInfo),
    entry: item.ParseItemSetEntry,
    state_items: []const item.ParseItemSetEntry,
    productions: []const ProductionInfo,
    item_identity_ids: []const []const u32,
    item_merge_identity_ids: []const []const u32,
    variables_to_inline: []const syntax_ir.SymbolRef,
    inline_map: process_inlines.InlinedProductionMap,
    depth: usize,
) !void {
    const parse_item = entry.item;
    if (parse_item.production_id >= productions.len) return;
    const production = productions[parse_item.production_id];
    if (parse_item.step_index >= production.steps.len) return;
    const symbol = production.steps[parse_item.step_index].symbol;
    const non_terminal = switch (symbol) {
        .non_terminal => |index| index,
        else => return,
    };

    if (isNonTerminalInline(variables_to_inline, non_terminal)) {
        if (depth > productions.len) return;
        if (inline_map.inlinedProductions(parse_item.production_id, parse_item.step_index)) |inlined_ids| {
            for (inlined_ids) |inlined_id| {
                var expanded_entry = entry;
                expanded_entry.item = .{
                    .variable_index = parse_item.variable_index,
                    .production_id = inlined_id,
                    .step_index = parse_item.step_index,
                    .has_preceding_inherited_fields = parse_item.has_preceding_inherited_fields,
                    .structural_identity = itemIdentityId(
                        item_identity_ids,
                        inlined_id,
                        parse_item.step_index,
                    ),
                    .merge_identity = itemIdentityId(
                        item_merge_identity_ids,
                        inlined_id,
                        parse_item.step_index,
                    ),
                };
                try appendAuxiliaryInfosForEntry(
                    allocator,
                    result,
                    expanded_entry,
                    state_items,
                    productions,
                    item_identity_ids,
                    item_merge_identity_ids,
                    variables_to_inline,
                    inline_map,
                    depth + 1,
                );
            }
        }
        return;
    }

    if (!symbolIsAuxiliaryLhs(productions, non_terminal)) return;
    try appendAuxiliaryInfoDedup(
        allocator,
        result,
        .{
            .auxiliary_symbol = symbol,
            .parent_symbols = try parentSymbolsForAuxiliaryExpandedAlloc(
                allocator,
                state_items,
                productions,
                item_identity_ids,
                item_merge_identity_ids,
                variables_to_inline,
                inline_map,
                symbol,
            ),
        },
    );
}

fn appendAuxiliaryInfoDedup(
    allocator: std.mem.Allocator,
    result: *std.array_list.Managed(state.AuxiliarySymbolInfo),
    info: state.AuxiliarySymbolInfo,
) !void {
    if (result.items.len != 0 and auxiliaryInfoEql(result.items[result.items.len - 1], info)) {
        allocator.free(info.parent_symbols);
        return;
    }
    try result.append(info);
}

fn parentSymbolsForAuxiliaryAlloc(
    allocator: std.mem.Allocator,
    state_items: []const item.ParseItemSetEntry,
    productions: []const ProductionInfo,
    auxiliary_symbol: syntax_ir.SymbolRef,
) ![]const syntax_ir.SymbolRef {
    var parents = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
    defer parents.deinit();

    for (state_items) |entry| {
        if (entry.item.production_id >= productions.len) continue;
        const production = productions[entry.item.production_id];
        if (production.augmented or production.lhs_kind == .auxiliary) continue;
        if (entry.item.step_index >= production.steps.len) continue;
        if (!symbolRefEql(production.steps[entry.item.step_index].symbol, auxiliary_symbol)) continue;
        try parents.append(.{ .non_terminal = production.lhs });
    }

    return try parents.toOwnedSlice();
}

fn parentSymbolsForAuxiliaryExpandedAlloc(
    allocator: std.mem.Allocator,
    state_items: []const item.ParseItemSetEntry,
    productions: []const ProductionInfo,
    item_identity_ids: []const []const u32,
    item_merge_identity_ids: []const []const u32,
    variables_to_inline: []const syntax_ir.SymbolRef,
    inline_map: process_inlines.InlinedProductionMap,
    auxiliary_symbol: syntax_ir.SymbolRef,
) ![]const syntax_ir.SymbolRef {
    var parents = std.array_list.Managed(syntax_ir.SymbolRef).init(allocator);
    defer parents.deinit();

    for (state_items) |entry| {
        try appendParentSymbolsForAuxiliaryEntry(
            allocator,
            &parents,
            entry,
            productions,
            item_identity_ids,
            item_merge_identity_ids,
            variables_to_inline,
            inline_map,
            auxiliary_symbol,
            0,
        );
    }

    return try parents.toOwnedSlice();
}

fn appendParentSymbolsForAuxiliaryEntry(
    allocator: std.mem.Allocator,
    parents: *std.array_list.Managed(syntax_ir.SymbolRef),
    entry: item.ParseItemSetEntry,
    productions: []const ProductionInfo,
    item_identity_ids: []const []const u32,
    item_merge_identity_ids: []const []const u32,
    variables_to_inline: []const syntax_ir.SymbolRef,
    inline_map: process_inlines.InlinedProductionMap,
    auxiliary_symbol: syntax_ir.SymbolRef,
    depth: usize,
) !void {
    const parse_item = entry.item;
    if (parse_item.production_id >= productions.len) return;
    const production = productions[parse_item.production_id];
    if (production.augmented or production.lhs_kind == .auxiliary) return;
    if (parse_item.step_index >= production.steps.len) return;
    const symbol = production.steps[parse_item.step_index].symbol;
    switch (symbol) {
        .non_terminal => |non_terminal| {
            if (isNonTerminalInline(variables_to_inline, non_terminal)) {
                if (depth > productions.len) return;
                if (inline_map.inlinedProductions(parse_item.production_id, parse_item.step_index)) |inlined_ids| {
                    for (inlined_ids) |inlined_id| {
                        var expanded_entry = entry;
                        expanded_entry.item = .{
                            .variable_index = parse_item.variable_index,
                            .production_id = inlined_id,
                            .step_index = parse_item.step_index,
                            .has_preceding_inherited_fields = parse_item.has_preceding_inherited_fields,
                            .structural_identity = itemIdentityId(
                                item_identity_ids,
                                inlined_id,
                                parse_item.step_index,
                            ),
                            .merge_identity = itemIdentityId(
                                item_merge_identity_ids,
                                inlined_id,
                                parse_item.step_index,
                            ),
                        };
                        try appendParentSymbolsForAuxiliaryEntry(
                            allocator,
                            parents,
                            expanded_entry,
                            productions,
                            item_identity_ids,
                            item_merge_identity_ids,
                            variables_to_inline,
                            inline_map,
                            auxiliary_symbol,
                            depth + 1,
                        );
                    }
                }
                return;
            }
        },
        else => {},
    }

    if (!symbolRefEql(symbol, auxiliary_symbol)) return;
    try parents.append(.{ .non_terminal = production.lhs });
}

fn auxiliaryInfoEql(left: state.AuxiliarySymbolInfo, right: state.AuxiliarySymbolInfo) bool {
    if (!symbolRefEql(left.auxiliary_symbol, right.auxiliary_symbol)) return false;
    if (left.parent_symbols.len != right.parent_symbols.len) return false;
    for (left.parent_symbols, right.parent_symbols) |left_parent, right_parent| {
        if (!symbolRefEql(left_parent, right_parent)) return false;
    }
    return true;
}

fn symbolIsAuxiliaryLhs(productions: []const ProductionInfo, non_terminal: u32) bool {
    for (productions) |production| {
        if (production.lhs == non_terminal and production.lhs_kind == .auxiliary) return true;
    }
    return false;
}

const TransitionReporter = struct {
    variables: []const syntax_ir.SyntaxVariable,
    progress_log: bool,

    fn init(variables: []const syntax_ir.SyntaxVariable) @This() {
        return .{
            .variables = variables,
            .progress_log = shouldLogBuildProgress(),
        };
    }

    fn logCollectEnter(self: @This(), source_state_id: state.StateId, state_item_count: usize) void {
        if (!self.progress_log) return;
        std.debug.print(
            "[parse_table/build] collectTransitionsForState enter source_state={d} state_items={d}\n",
            .{ source_state_id, state_item_count },
        );
    }

    fn logGrouped(self: @This(), source_state_id: state.StateId, successor_group_count: usize) void {
        if (!self.progress_log) return;
        std.debug.print(
            "[parse_table/build] collectTransitionsForState grouped source_state={d} successor_groups={d}\n",
            .{ source_state_id, successor_group_count },
        );
    }

    fn logTransitionBegin(
        self: @This(),
        source_state_id: state.StateId,
        group_index: usize,
        group_count: usize,
        symbol: syntax_ir.SymbolRef,
        seed_item_count: usize,
    ) void {
        const trace_transition = shouldTraceTransition(source_state_id, symbol);
        if (!(self.progress_log or trace_transition)) return;

        var symbol_buf: [128]u8 = undefined;
        const symbol_text = symbolDisplayText(&symbol_buf, self.variables, symbol);
        std.debug.print(
            "[parse_table/build] construct_states transition_begin source_state={d} group={d}/{d} symbol={s} seed_items={d}\n",
            .{ source_state_id, group_index + 1, group_count, symbol_text, seed_item_count },
        );
    }

    fn logTransitionClosed(
        self: @This(),
        source_state_id: state.StateId,
        group_index: usize,
        group_count: usize,
        symbol: syntax_ir.SymbolRef,
        advanced_item_count: usize,
    ) void {
        const trace_transition = shouldTraceTransition(source_state_id, symbol);
        if (!(self.progress_log or trace_transition)) return;

        var symbol_buf: [128]u8 = undefined;
        const symbol_text = symbolDisplayText(&symbol_buf, self.variables, symbol);
        std.debug.print(
            "[parse_table/build] construct_states transition_closed source_state={d} group={d}/{d} symbol={s} advanced_items={d}\n",
            .{ source_state_id, group_index + 1, group_count, symbol_text, advanced_item_count },
        );
    }

    fn maybeLogLargestSuccessor(self: @This(), label: []const u8, diagnostic: SuccessorDiagnostic) void {
        if (!self.progress_log) return;
        logSuccessorDiagnostic(label, self.variables, diagnostic);
    }
};

const ConstructStatesReporter = struct {
    variables: []const syntax_ir.SyntaxVariable,
    progress_log: bool,
    next_progress_report: usize = 10,

    fn init(variables: []const syntax_ir.SyntaxVariable) @This() {
        return .{
            .variables = variables,
            .progress_log = shouldLogBuildProgress(),
        };
    }

    fn logEnter(self: @This()) void {
        if (!self.progress_log) return;
        std.debug.print("[parse_table/build] constructStates enter\n", .{});
    }

    fn startInitialClosure(self: @This()) bool {
        const timer = maybeStartTimer(self.progress_log);
        if (self.progress_log) logBuildStart("construct_states.initial_closure");
        return timer;
    }

    fn logInitialClosureDone(self: @This(), start_timer: bool, item_count: usize) void {
        if (!self.progress_log) return;
        std.debug.print("[parse_table/build] constructStates initial_closure_done items={d}\n", .{item_count});
        if (self.progress_log) {
            maybeLogBuildDone("construct_states.initial_closure", start_timer);
            logBuildSummary("construct_states initial_closure items={d}", .{item_count});
        }
    }

    fn logStateBegin(self: *@This(), state_index: usize, parse_state: state.ParseState, discovered_count: usize) void {
        if (!self.progress_log) return;
        if (state_index < 5 or (state_index + 1) % 100 == 0) {
            std.debug.print(
                "[parse_table/build] constructStates state_begin index={d} state_id={d} items={d} discovered={d}\n",
                .{
                    state_index,
                    parse_state.id,
                    parse_state.items.len,
                    discovered_count,
                },
            );
        }
        if (self.progress_log and (state_index < 5 or state_index + 1 == self.next_progress_report)) {
            logBuildSummary(
                "construct_states entering state_index={d} state_id={d} items={d} discovered={d}",
                .{
                    state_index,
                    parse_state.id,
                    parse_state.items.len,
                    discovered_count,
                },
            );
        }
    }

    fn logStateAfterTransitions(self: @This(), state_index: usize, transition_count: usize, discovered_count: usize) void {
        if (!self.progress_log) return;
        if (state_index < 5 or (state_index + 1) % 100 == 0) {
            std.debug.print(
                "[parse_table/build] constructStates state_after_transitions index={d} transitions={d} discovered={d}\n",
                .{ state_index, transition_count, discovered_count },
            );
        }
    }

    fn logStateDone(
        self: *@This(),
        state_index: usize,
        parse_state: state.ParseState,
        action_entry_count: usize,
        discovered_count: usize,
        detected_conflict_count: usize,
        transition_stats: TransitionBuildStats,
    ) void {
        if (!self.progress_log) return;
        if (state_index < 5 or (state_index + 1) % 100 == 0) {
            std.debug.print(
                "[parse_table/build] constructStates state_done index={d} conflicts={d} action_entries={d} discovered={d}\n",
                .{ state_index, detected_conflict_count, action_entry_count, discovered_count },
            );
        }

        if (self.progress_log and state_index + 1 >= self.next_progress_report) {
            logBuildSummary(
                "construct_states progress processed={d} discovered={d}",
                .{
                    state_index + 1,
                    discovered_count,
                },
            );
            self.next_progress_report += if (self.next_progress_report < 100) 10 else 100;
        }

        if (self.progress_log and (transition_stats.new_state_count > 0 or transition_stats.transition_count >= 16)) {
            var largest_new_symbol_buf: [64]u8 = undefined;
            var largest_reused_symbol_buf: [64]u8 = undefined;
            const largest_new_symbol = optionalSymbolRefText(&largest_new_symbol_buf, transition_stats.largest_new_state_symbol);
            const largest_reused_symbol = optionalSymbolRefText(&largest_reused_symbol_buf, transition_stats.largest_reused_state_symbol);
            logBuildSummary(
                "construct_states state_id={d} transitions={d} new_states={d} reused_states={d} largest_new_items={d} largest_new_symbol={s} largest_reused_items={d} largest_reused_symbol={s}",
                .{
                    parse_state.id,
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

    fn logComplete(
        self: @This(),
        state_count: usize,
        largest_new_successor: ?SuccessorDiagnostic,
        largest_reused_successor: ?SuccessorDiagnostic,
    ) void {
        if (!self.progress_log) return;
        std.debug.print("[parse_table/build] constructStates complete states={d}\n", .{state_count});
        if (!self.progress_log) return;

        if (largest_new_successor) |diagnostic| {
            logSuccessorDiagnostic("construct_states largest_new_successor", self.variables, diagnostic);
        }
        if (largest_reused_successor) |diagnostic| {
            logSuccessorDiagnostic("construct_states largest_reused_successor", self.variables, diagnostic);
        }
    }
};

const StateConstructionEngine = struct {
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    follow_sets: []const first.SymbolSet,
    variable_has_fields: []const bool,
    item_set_builder: ParseItemSetBuilder,
    closure_expansion_cache: *ClosureExpansionCache,
    successor_seed_state_cache: *SuccessorSeedStateCache,
    state_registry: *StateRegistry,
    grouped_action_states: *std.array_list.Managed(actions.GroupedStateActions),
    largest_new_successor: *?SuccessorDiagnostic,
    largest_reused_successor: *?SuccessorDiagnostic,
    non_terminal_extra_starts: []const NonTerminalExtraStart,
    options: BuildOptions,

    fn processState(
        self: *@This(),
        reporter: *ConstructStatesReporter,
        state_index: usize,
    ) BuildError!void {
        reporter.logStateBegin(
            state_index,
            self.state_registry.items()[state_index],
            self.state_registry.items().len,
        );

        var transition_stats = TransitionBuildStats{};
        const collect_timer = profileTimer(construct_profile_enabled);
        const transitions = try self.collectTransitionsForState(
            self.state_registry.items()[state_index].items,
            self.state_registry.items()[state_index].id,
            &transition_stats,
        );
        addProfileDuration(&construct_profile.collect_transitions_ns, collect_timer);
        reporter.logStateAfterTransitions(state_index, transitions.len, self.state_registry.items().len);

        const mutable_states = self.state_registry.items();
        const extra_timer = profileTimer(construct_profile_enabled);
        mutable_states[state_index].transitions = try self.withExtraTransitions(transitions, mutable_states[state_index]);
        addProfileDuration(&construct_profile.extra_transitions_ns, extra_timer);
        if (self.options.closure_lookahead_mode == .none and self.options.coarse_follow_lookaheads) {
            self.applyCoarseFollowLookaheads(&mutable_states[state_index]);
        }
        const reserved_timer = profileTimer(construct_profile_enabled);
        mutable_states[state_index].reserved_word_set_id = reservedWordSetIdForParseState(
            mutable_states[state_index],
            self.productions,
            self.item_set_builder.word_token,
            self.item_set_builder.reserved_word_context_names,
        );
        addProfileDuration(&construct_profile.reserved_word_ns, reserved_timer);

        const actions_timer = profileTimer(construct_profile_enabled);
        const grouped_state_actions = try actions.buildGroupedActionsForState(
            self.allocator,
            self.productions,
            mutable_states[state_index],
        );
        addProfileDuration(&construct_profile.build_actions_ns, actions_timer);
        const conflicts_timer = profileTimer(construct_profile_enabled);
        const detected_conflicts = try conflicts.detectConflictsFromActionGroups(
            self.allocator,
            self.productions,
            mutable_states[state_index],
            grouped_state_actions.groups,
            self.first_sets,
        );
        addProfileDuration(&construct_profile.detect_conflicts_ns, conflicts_timer);
        mutable_states[state_index].conflicts = detected_conflicts;
        try self.grouped_action_states.append(grouped_state_actions);

        reporter.logStateDone(
            state_index,
            mutable_states[state_index],
            countGroupedActions(grouped_state_actions.groups),
            self.state_registry.items().len,
            detected_conflicts.len,
            transition_stats,
        );
    }

    fn applyCoarseFollowLookaheads(self: @This(), parse_state: *state.ParseState) void {
        const mutable_items = @constCast(parse_state.items);
        for (mutable_items) |*entry| {
            if (!entry.lookaheads.isEmpty()) continue;
            if (entry.item.production_id >= self.productions.len) continue;
            const production = self.productions[entry.item.production_id];
            if (entry.item.step_index != production.steps.len) continue;
            if (production.lhs >= self.follow_sets.len) continue;
            _ = mergeFollowWithoutEpsilon(&entry.lookaheads, self.follow_sets[production.lhs]);
        }
    }

    fn withExtraTransitions(
        self: *@This(),
        transitions: []const state.Transition,
        parse_state: state.ParseState,
    ) BuildError![]const state.Transition {
        if (self.non_terminal_extra_starts.len == 0 or self.isNonTerminalExtraEndState(parse_state)) return transitions;

        var result = std.array_list.Managed(state.Transition).init(self.allocator);
        defer result.deinit();
        try result.appendSlice(transitions);

        for (self.non_terminal_extra_starts) |extra_start| {
            if (hasTransitionForSymbol(result.items, extra_start.symbol)) continue;
            try result.append(.{
                .symbol = extra_start.symbol,
                .state = extra_start.state_id,
                .extra = true,
            });
        }

        state.sortTransitions(result.items);
        if (construct_profile_enabled) {
            construct_profile.extra_transition_slices += 1;
            construct_profile.extra_transition_slice_items += result.items.len;
            construct_profile.extra_transition_slice_bytes += result.items.len * @sizeOf(state.Transition);
        }
        return try result.toOwnedSlice();
    }

    fn isNonTerminalExtraEndState(self: @This(), parse_state: state.ParseState) bool {
        for (parse_state.items) |entry| {
            if (!item.containsLookahead(entry.lookaheads, .{ .end = {} })) continue;
            if (entry.item.production_id >= self.productions.len) continue;
            const production = self.productions[entry.item.production_id];
            if (entry.item.step_index != production.steps.len) continue;
            if (symbolRefIn(self.options.non_terminal_extra_symbols, .{ .non_terminal = production.lhs })) return true;
        }
        return false;
    }

    fn collectTransitionsForState(
        self: *@This(),
        state_items: []const item.ParseItemSetEntry,
        source_state_id: state.StateId,
        stats: *TransitionBuildStats,
    ) BuildError![]const state.Transition {
        const reporter = TransitionReporter.init(self.variables);
        reporter.logCollectEnter(source_state_id, state_items.len);

        var transitions = std.array_list.Managed(state.Transition).init(self.allocator);
        defer transitions.deinit();
        var successor_groups = SuccessorGroups.init(self.allocator);
        defer successor_groups.deinit();
        try successor_groups.buildFromStateItems(
            state_items,
            self.productions,
            self.item_set_builder.item_identity_ids,
            self.item_set_builder.item_merge_identity_ids,
            self.variable_has_fields,
            self.item_set_builder.variables_to_inline,
            self.item_set_builder.inline_map,
        );
        const successor_auxiliary_symbols = try auxiliarySymbolSequenceForSuccessorsAlloc(
            self.allocator,
            self.state_registry.items()[@intCast(source_state_id)].auxiliary_symbols,
            state_items,
            self.productions,
            self.item_set_builder.item_identity_ids,
            self.item_set_builder.item_merge_identity_ids,
            self.item_set_builder.variables_to_inline,
            self.item_set_builder.inline_map,
        );
        defer freeAuxiliarySymbolInfos(self.allocator, successor_auxiliary_symbols);
        if (construct_profile_enabled) {
            construct_profile.states_processed += 1;
            construct_profile.successor_groups += successor_groups.groups.items.len;
            for (successor_groups.groups.items) |group| {
                construct_profile.successor_seed_items += group.items.items.len;
            }
        }
        reporter.logGrouped(source_state_id, successor_groups.groups.items.len);

        for (successor_groups.groups.items, 0..) |*group, group_index| {
            const symbol = group.symbol;
            reporter.logTransitionBegin(
                source_state_id,
                group_index,
                successor_groups.groups.items.len,
                symbol,
                group.items.items.len,
            );

            const advanced_item_set = blk: {
                const prior_transition_context = current_transition_context;
                setCurrentTransitionContext(.{
                    .source_state_id = source_state_id,
                    .symbol = symbol,
                });
                defer setCurrentTransitionContext(prior_transition_context);
                var transition_options = self.options;
                if (shouldUseCoarseTransition(self.options, source_state_id, symbol)) {
                    transition_options.closure_lookahead_mode = .none;
                    if (reporter.progress_log) {
                        var coarse_symbol_buf: [128]u8 = undefined;
                        const coarse_symbol_text = symbolDisplayText(&coarse_symbol_buf, self.variables, symbol);
                        logBuildSummary(
                            "construct_states applying coarse_transition source_state={d} symbol={s}",
                            .{ source_state_id, coarse_symbol_text },
                        );
                    }
                }
                const use_successor_seed_cache = canUseSuccessorSeedStateCache(transition_options);
                if (use_successor_seed_cache) {
                    if (self.successor_seed_state_cache.get(group.items.items)) |cached_state_id| {
                        stats.transition_count += 1;
                        stats.reused_state_count += 1;
                        const cached_item_count = self.state_registry.items()[@intCast(cached_state_id)].items.len;
                        if (cached_item_count > stats.largest_reused_state_items) {
                            stats.largest_reused_state_items = cached_item_count;
                            stats.largest_reused_state_symbol = symbol;
                        }
                        if (self.largest_reused_successor.* == null or cached_item_count > self.largest_reused_successor.*.?.item_count) {
                            self.largest_reused_successor.* = .{
                                .source_state_id = source_state_id,
                                .symbol = symbol,
                                .item_count = cached_item_count,
                                .reused = true,
                            };
                            reporter.maybeLogLargestSuccessor("construct_states update largest_reused_successor", self.largest_reused_successor.*.?);
                        }
                        try transitions.append(.{ .symbol = symbol, .state = cached_state_id });
                        continue;
                    }
                }
                if (construct_profile_enabled) {
                    construct_profile.closure_cache_misses += 1;
                    construct_profile.closure_seed_items += group.items.items.len;
                    construct_profile.closure_seed_bytes += group.items.items.len * @sizeOf(item.ParseItemSetEntry);
                }
                if (shouldLogBuildProgress() or shouldTraceCurrentClosure()) {
                    std.debug.print("[parse_table/build] gotoItems closure_start seed_items={d}\n", .{group.items.items.len});
                }
                const closed_item_set = try self.item_set_builder.transitiveClosureWithExpansionCache(
                    self.allocator,
                    self.variables,
                    .{ .entries = group.items.items },
                    transition_options,
                    self.closure_expansion_cache,
                );
                if (construct_profile_enabled) construct_profile.closure_items_returned += closed_item_set.entries.len;
                if (shouldLogBuildProgress() or shouldTraceCurrentClosure()) {
                    std.debug.print(
                        "[parse_table/build] gotoItems closure_done seed_items={d} closed_items={d}\n",
                        .{ group.items.items.len, closed_item_set.entries.len },
                    );
                }
                break :blk closed_item_set;
            };
            reporter.logTransitionClosed(
                source_state_id,
                group_index,
                successor_groups.groups.items.len,
                symbol,
                advanced_item_set.entries.len,
            );
            stats.transition_count += 1;
            const interned = try self.state_registry.intern(
                .{ .entries = group.items.items },
                advanced_item_set,
                successor_auxiliary_symbols,
            );
            if (canUseSuccessorSeedStateCache(self.options)) {
                try self.successor_seed_state_cache.put(group.items.items, interned.state_id);
            }
            if (interned.reused) {
                stats.reused_state_count += 1;
                if (advanced_item_set.entries.len > stats.largest_reused_state_items) {
                    stats.largest_reused_state_items = advanced_item_set.entries.len;
                    stats.largest_reused_state_symbol = symbol;
                }
                if (self.largest_reused_successor.* == null or advanced_item_set.entries.len > self.largest_reused_successor.*.?.item_count) {
                    self.largest_reused_successor.* = .{
                        .source_state_id = source_state_id,
                        .symbol = symbol,
                        .item_count = advanced_item_set.entries.len,
                        .reused = true,
                    };
                    reporter.maybeLogLargestSuccessor("construct_states update largest_reused_successor", self.largest_reused_successor.*.?);
                }
                try transitions.append(.{ .symbol = symbol, .state = interned.state_id });
                continue;
            }

            stats.new_state_count += 1;
            if (advanced_item_set.entries.len > stats.largest_new_state_items) {
                stats.largest_new_state_items = advanced_item_set.entries.len;
                stats.largest_new_state_symbol = symbol;
            }
            if (self.largest_new_successor.* == null or advanced_item_set.entries.len > self.largest_new_successor.*.?.item_count) {
                self.largest_new_successor.* = .{
                    .source_state_id = source_state_id,
                    .symbol = symbol,
                    .item_count = advanced_item_set.entries.len,
                    .reused = false,
                };
                reporter.maybeLogLargestSuccessor("construct_states update largest_new_successor", self.largest_new_successor.*.?);
            }
            try transitions.append(.{ .symbol = symbol, .state = interned.state_id });
        }

        state.sortTransitions(transitions.items);
        if (construct_profile_enabled) {
            construct_profile.transition_slices += 1;
            construct_profile.transition_slice_items += transitions.items.len;
            construct_profile.transition_slice_bytes += transitions.items.len * @sizeOf(state.Transition);
        }
        return try transitions.toOwnedSlice();
    }
};

const SuccessorSeedStateCache = struct {
    allocator: std.mem.Allocator,
    state_ids_by_seed: StateIdByItemSet,
    keys: std.array_list.Managed(ParseItemSetKey),

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .state_ids_by_seed = StateIdByItemSet.init(allocator),
            .keys = std.array_list.Managed(ParseItemSetKey).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        for (self.keys.items) |key| {
            freeParseItemSetEntries(self.allocator, key.entries);
        }
        self.keys.deinit();
        self.state_ids_by_seed.deinit();
    }

    fn get(self: @This(), seed_items: []const item.ParseItemSetEntry) ?state.StateId {
        if (self.state_ids_by_seed.get(ParseItemSetKey.fromEntries(seed_items))) |state_id| {
            if (construct_profile_enabled) construct_profile.successor_seed_cache_hits += 1;
            return state_id;
        }
        if (construct_profile_enabled) construct_profile.successor_seed_cache_misses += 1;
        return null;
    }

    fn put(
        self: *@This(),
        seed_items: []const item.ParseItemSetEntry,
        state_id: state.StateId,
    ) !void {
        const seed_copy = try cloneParseItemSetEntries(self.allocator, seed_items);
        errdefer freeParseItemSetEntries(self.allocator, seed_copy);
        const key = ParseItemSetKey.fromEntries(seed_copy);
        try self.state_ids_by_seed.put(key, state_id);
        try self.keys.append(key);
        if (construct_profile_enabled) construct_profile.successor_seed_cache_entries = self.keys.items.len;
    }
};

const ClosureStats = struct {
    allocator: std.mem.Allocator,
    progress_log: bool,
    expansion_visits: []usize = &.{},
    production_counts: []usize = &.{},
    added_items: []usize = &.{},
    duplicate_hits: []usize = &.{},
    cache_hits: []usize = &.{},
    cache_misses: []usize = &.{},
    unique_lookaheads: []usize = &.{},
    unique_first_sets: []usize = &.{},
    next_added_report: []usize = &.{},

    fn init(
        allocator: std.mem.Allocator,
        progress_log: bool,
        productions: []const ProductionInfo,
    ) !@This() {
        var self = @This(){
            .allocator = allocator,
            .progress_log = progress_log,
        };
        if (!progress_log) return self;

        const variable_count = variableCountFromProductions(productions);
        if (variable_count == 0) return self;

        self.expansion_visits = try allocator.alloc(usize, variable_count);
        self.production_counts = try productionCountsFromProductions(allocator, productions, variable_count);
        self.added_items = try allocator.alloc(usize, variable_count);
        self.duplicate_hits = try allocator.alloc(usize, variable_count);
        self.cache_hits = try allocator.alloc(usize, variable_count);
        self.cache_misses = try allocator.alloc(usize, variable_count);
        self.unique_lookaheads = try allocator.alloc(usize, variable_count);
        self.unique_first_sets = try allocator.alloc(usize, variable_count);
        self.next_added_report = try allocator.alloc(usize, variable_count);
        @memset(self.expansion_visits, 0);
        @memset(self.added_items, 0);
        @memset(self.duplicate_hits, 0);
        @memset(self.cache_hits, 0);
        @memset(self.cache_misses, 0);
        @memset(self.unique_lookaheads, 0);
        @memset(self.unique_first_sets, 0);
        @memset(self.next_added_report, 250);
        return self;
    }

    fn deinit(self: *@This()) void {
        if (!self.progress_log) return;
        if (self.expansion_visits.len == 0) return;
        self.allocator.free(self.expansion_visits);
        self.allocator.free(self.production_counts);
        self.allocator.free(self.added_items);
        self.allocator.free(self.duplicate_hits);
        self.allocator.free(self.cache_hits);
        self.allocator.free(self.cache_misses);
        self.allocator.free(self.unique_lookaheads);
        self.allocator.free(self.unique_first_sets);
        self.allocator.free(self.next_added_report);
    }
};

const ClosureReporter = struct {
    progress_log: bool,
    trace_current_closure: bool,

    fn init(progress_log: bool, trace_current_closure: bool) @This() {
        return .{
            .progress_log = progress_log,
            .trace_current_closure = trace_current_closure,
        };
    }

    fn logStart(self: @This(), seed_item_count: usize) void {
        if (self.progress_log) {
            logBuildSummary("closure start seed_items={d}", .{seed_item_count});
        }
        if (self.trace_current_closure) {
            std.debug.print(
                "[parse_table/build] traced_closure start seed_items={d} context_source_state={d}\n",
                .{ seed_item_count, current_transition_context.?.source_state_id },
            );
        }
    }

    fn logRoundStart(self: @This(), round: usize, item_count: usize) void {
        if (self.progress_log) {
            logBuildSummary("closure round={d} start items={d}", .{ round, item_count });
        }
        if (self.trace_current_closure) {
            std.debug.print(
                "[parse_table/build] traced_closure round_start round={d} items={d}\n",
                .{ round, item_count },
            );
        }
    }

    fn logCursorProgress(self: @This(), round: usize, cursor: usize, item_count: usize) void {
        if (!self.progress_log) return;
        if (!(cursor < 5 or (cursor + 1) % 100 == 0)) return;
        logBuildSummary(
            "closure round={d} cursor={d}/{d}",
            .{ round, cursor + 1, item_count },
        );
    }

    fn logRoundDone(
        self: @This(),
        variables: []const syntax_ir.SyntaxVariable,
        stats: *const ClosureStats,
        round: usize,
        item_count: usize,
        added_count: usize,
        changed: bool,
    ) void {
        if (self.progress_log) {
            logBuildSummary(
                "closure round={d} done items={d} added={d} changed={}",
                .{ round, item_count, added_count, changed },
            );
            if (round == 1 or added_count > 0) {
                logTopClosureContributors(
                    variables,
                    stats.production_counts,
                    stats.expansion_visits,
                    stats.added_items,
                    stats.duplicate_hits,
                    stats.cache_hits,
                    stats.cache_misses,
                    stats.unique_lookaheads,
                    stats.unique_first_sets,
                );
            }
        }
        if (self.trace_current_closure) {
            std.debug.print(
                "[parse_table/build] traced_closure round_done round={d} items={d} added={d} changed={}\n",
                .{ round, item_count, added_count, changed },
            );
        }
    }

    fn logComplete(self: @This(), round_count: usize, item_count: usize, closure_lookahead_mode: ClosureLookaheadMode) void {
        if (self.progress_log) {
            logBuildSummary(
                "closure complete rounds={d} items={d} closure_lookahead_mode={s}",
                .{
                    round_count,
                    item_count,
                    if (closure_lookahead_mode == .full) "full" else "none",
                },
            );
        }
        if (self.trace_current_closure) {
            std.debug.print(
                "[parse_table/build] traced_closure complete rounds={d} items={d}\n",
                .{ round_count, item_count },
            );
        }
    }
};

const ClosureRun = struct {
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    item_set_builder: ParseItemSetBuilder,
    options: BuildOptions,
    progress_log: bool,
    context_log: bool,
    trace_current_closure: bool,
    effective_closure_lookahead_mode: ClosureLookaheadMode,
    pressure_triggered: bool = false,
    items: std.array_list.Managed(item.ParseItemSetEntry),
    item_indexes: ClosureItemIndexMap,
    local_expansion_cache: ClosureExpansionCache,
    shared_expansion_cache: ?*ClosureExpansionCache,

    fn init(
        allocator: std.mem.Allocator,
        variables: []const syntax_ir.SyntaxVariable,
        item_set_builder: ParseItemSetBuilder,
        options: BuildOptions,
        expansion_cache: ?*ClosureExpansionCache,
    ) @This() {
        return .{
            .allocator = allocator,
            .variables = variables,
            .item_set_builder = item_set_builder,
            .options = options,
            .progress_log = shouldLogBuildProgress(),
            .context_log = shouldLogBuildContexts(),
            .trace_current_closure = shouldTraceCurrentClosure(),
            .effective_closure_lookahead_mode = options.closure_lookahead_mode,
            .items = std.array_list.Managed(item.ParseItemSetEntry).init(allocator),
            .item_indexes = ClosureItemIndexMap.init(allocator),
            .local_expansion_cache = ClosureExpansionCache.init(allocator),
            .shared_expansion_cache = expansion_cache,
        };
    }

    fn deinit(self: *@This()) void {
        self.local_expansion_cache.deinit();
        self.item_indexes.deinit();
        self.items.deinit();
    }

    fn expansionCache(self: *@This()) *ClosureExpansionCache {
        return self.shared_expansion_cache orelse &self.local_expansion_cache;
    }

    fn seed(self: *@This(), seed_items: []const item.ParseItemSetEntry) !void {
        // Substitute inline variables at the current step of each seed item and
        // attach upstream-style structural item identities before insertion.
        var expanded = std.array_list.Managed(item.ParseItemSetEntry).init(self.allocator);
        defer expanded.deinit();
        for (seed_items) |entry| {
            const parse_item = entry.item;
            const production = self.item_set_builder.productions[parse_item.production_id];
            const step_idx: u16 = @intCast(parse_item.step_index);
            if (parse_item.step_index < production.steps.len) {
                if (self.item_set_builder.inline_map.inlinedProductions(parse_item.production_id, step_idx)) |inlined_ids| {
                    for (inlined_ids) |inlined_id| {
                        var new_entry = entry;
                        new_entry.item = self.item_set_builder.makeParseItemForVariable(
                            parse_item.variable_index,
                            inlined_id,
                            step_idx,
                        );
                        try expanded.append(new_entry);
                    }
                    continue;
                }
            }
            var canonical_entry = entry;
            canonical_entry.item = self.item_set_builder.makeParseItemForVariable(
                parse_item.variable_index,
                parse_item.production_id,
                step_idx,
            );
            try expanded.append(canonical_entry);
        }
        _ = try appendGeneratedItemsToClosure(self.allocator, &self.items, &self.item_indexes, expanded.items, false);
        state.sortItems(self.items.items);
    }

    fn toOwnedSlice(self: *@This()) ![]const item.ParseItemSetEntry {
        return try self.items.toOwnedSlice();
    }

    fn expandCursor(
        self: *@This(),
        stats: *ClosureStats,
        round: usize,
        cursor: usize,
        options: BuildOptions,
    ) BuildError!bool {
        const parse_entry = self.items.items[cursor];
        const parse_item = parse_entry.item;
        const production = self.item_set_builder.productions[parse_item.production_id];
        if (parse_item.step_index >= production.steps.len) return false;
        switch (production.steps[parse_item.step_index].symbol) {
            .non_terminal => |non_terminal| {
                if (self.trace_current_closure and (cursor < 10 or (cursor + 1) % 25 == 0)) {
                    std.debug.print(
                        "[parse_table/build] traced_closure expand round={d} cursor={d}/{d} non_terminal={d} name={s}\n",
                        .{
                            round,
                            cursor + 1,
                            self.items.items.len,
                            non_terminal,
                            if (non_terminal < self.variables.len) self.variables[non_terminal].name else "<unknown>",
                        },
                    );
                }
                if (self.progress_log and non_terminal < stats.expansion_visits.len) {
                    stats.expansion_visits[non_terminal] += 1;
                }
                const suffix = production.steps[parse_item.step_index + 1 ..];
                const following_tokens = if (suffix.len == 0)
                    try cloneSymbolSet(self.allocator, parse_entry.lookaheads)
                else
                    try immediateFollowingFirstSetAlloc(
                        self.allocator,
                        self.item_set_builder.first_sets,
                        suffix[0].symbol,
                    );
                defer freeSymbolSet(self.allocator, following_tokens);
                const following_reserved_word_set_id = if (suffix.len == 0)
                    parse_entry.following_reserved_word_set_id
                else
                    self.item_set_builder.reservedFirstSetIdForSymbol(suffix[0].symbol);
                const context = try ClosureContext.init(
                    self.allocator,
                    following_tokens,
                    following_reserved_word_set_id,
                    parse_entry.lookaheads,
                    parse_entry.following_reserved_word_set_id,
                );
                defer context.deinit(self.allocator);
                const generated_items = try self.lookupGeneratedItems(
                    stats,
                    round,
                    cursor,
                    non_terminal,
                    context,
                );

                const append_profile_timer = profileTimer(construct_profile_enabled);
                const append_timer = maybeStartTimer(self.progress_log);
                const append_stats = try appendGeneratedItemsToClosure(
                    self.allocator,
                    &self.items,
                    &self.item_indexes,
                    generated_items,
                    false,
                );
                addProfileDuration(&construct_profile.closure_append_ns, append_profile_timer);
                if (construct_profile_enabled) {
                    construct_profile.closure_append_added += append_stats.added;
                    construct_profile.closure_append_duplicate_checks += append_stats.duplicate_checks;
                    construct_profile.closure_append_duplicate_hits += append_stats.duplicate_hits;
                }
                if (self.trace_current_closure and append_stats.added > 0) {
                    std.debug.print(
                        "[parse_table/build] traced_closure append round={d} cursor={d}/{d} non_terminal={d} added={d} duplicate_hits={d} total_items={d}\n",
                        .{
                            round,
                            cursor + 1,
                            self.items.items.len,
                            non_terminal,
                            append_stats.added,
                            append_stats.duplicate_hits,
                            self.items.items.len,
                        },
                    );
                }
                if (append_timer) {
                    logBuildSummary(
                        "closure append non_terminal={d} name={s} generated_items={d} existing_items={d} added={d} duplicate_checks={d} duplicate_hits={d}",
                        .{
                            non_terminal,
                            if (non_terminal < self.variables.len) self.variables[non_terminal].name else "<unknown>",
                            generated_items.len,
                            self.items.items.len,
                            append_stats.added,
                            append_stats.duplicate_checks,
                            append_stats.duplicate_hits,
                        },
                    );
                }
                if (self.progress_log and non_terminal < stats.added_items.len) {
                    stats.added_items[non_terminal] += append_stats.added;
                    stats.duplicate_hits[non_terminal] += append_stats.duplicate_hits;
                    if (stats.added_items[non_terminal] >= stats.next_added_report[non_terminal]) {
                        logBuildSummary(
                            "closure hot non_terminal={d} name={s} productions={d} visits={d} contexts={d} cache_hits={d} unique_context_lookaheads={d} unique_context_first_sets={d} added={d} duplicate_hits={d}",
                            .{
                                non_terminal,
                                if (non_terminal < self.variables.len) self.variables[non_terminal].name else "<unknown>",
                                if (non_terminal < stats.production_counts.len) stats.production_counts[non_terminal] else 0,
                                stats.expansion_visits[non_terminal],
                                if (non_terminal < stats.cache_misses.len) stats.cache_misses[non_terminal] else 0,
                                if (non_terminal < stats.cache_hits.len) stats.cache_hits[non_terminal] else 0,
                                if (non_terminal < stats.unique_lookaheads.len) stats.unique_lookaheads[non_terminal] else 0,
                                if (non_terminal < stats.unique_first_sets.len) stats.unique_first_sets[non_terminal] else 0,
                                stats.added_items[non_terminal],
                                stats.duplicate_hits[non_terminal],
                            },
                        );
                        stats.next_added_report[non_terminal] += 250;
                    }
                }
                if (!self.pressure_triggered and self.effective_closure_lookahead_mode == .full) {
                    const context_count = if (non_terminal < stats.cache_misses.len) stats.cache_misses[non_terminal] else 0;
                    const duplicate_hit_count = if (non_terminal < stats.duplicate_hits.len) stats.duplicate_hits[non_terminal] else 0;
                    if (closurePressureTrigger(options, self.items.items.len, duplicate_hit_count, context_count)) |trigger| {
                        self.effective_closure_lookahead_mode = .none;
                        self.pressure_triggered = true;
                        if (self.progress_log) {
                            logBuildSummary(
                                "closure pressure_trigger round={d} cursor={d}/{d} non_terminal={d} name={s} reason={s} value={d} threshold={d} items={d}",
                                .{
                                    round,
                                    cursor + 1,
                                    self.items.items.len,
                                    non_terminal,
                                    if (non_terminal < self.variables.len) self.variables[non_terminal].name else "<unknown>",
                                    trigger.reason,
                                    trigger.current_value,
                                    trigger.threshold,
                                    self.items.items.len,
                                },
                            );
                        }
                    }
                }
                return append_stats.changed;
            },
            else => return false,
        }
    }

    fn lookupGeneratedItems(
        self: *@This(),
        stats: *ClosureStats,
        round: usize,
        cursor: usize,
        non_terminal: u32,
        context: ClosureContext,
    ) ![]const item.ParseItemSetEntry {
        const cache = self.expansionCache();
        if (cache.find(
            non_terminal,
            self.effective_closure_lookahead_mode,
            context.following_tokens,
            context.following_reserved_word_set_id,
            context.production_end_reserved_word_set_id,
        )) |cached| {
            if (construct_profile_enabled) construct_profile.closure_expansion_cache_hits += 1;
            if (self.trace_current_closure and (cursor < 10 or (cursor + 1) % 25 == 0)) {
                std.debug.print(
                    "[parse_table/build] traced_closure cache_hit round={d} cursor={d}/{d} non_terminal={d} generated_items={d}\n",
                    .{ round, cursor + 1, self.items.items.len, non_terminal, cached.len },
                );
            }
            if (self.progress_log and non_terminal < stats.cache_hits.len) {
                stats.cache_hits[non_terminal] += 1;
            }
            return cached;
        }

        if (construct_profile_enabled) construct_profile.closure_expansion_cache_misses += 1;
        if (self.trace_current_closure and (cursor < 10 or (cursor + 1) % 25 == 0)) {
            std.debug.print(
                "[parse_table/build] traced_closure cache_miss round={d} cursor={d}/{d} non_terminal={d}\n",
                .{ round, cursor + 1, self.items.items.len, non_terminal },
            );
        }
        if (self.progress_log and non_terminal < stats.cache_misses.len) {
            stats.cache_misses[non_terminal] += 1;
        }
        const generated = try buildClosureExpansionItemsAlloc(
            self.allocator,
            self.item_set_builder,
            non_terminal,
            context,
            .{
                .closure_lookahead_mode = self.effective_closure_lookahead_mode,
            },
        );
        try cache.append(
            non_terminal,
            self.effective_closure_lookahead_mode,
            context.following_tokens,
            context.following_reserved_word_set_id,
            context.production_end_reserved_word_set_id,
            generated,
        );
        if (self.progress_log and non_terminal < stats.unique_lookaheads.len) {
            stats.unique_lookaheads[non_terminal] = countDistinctLookaheadsForNonTerminal(
                cache.entries.items,
                non_terminal,
            );
            stats.unique_first_sets[non_terminal] = countDistinctFirstSetsForNonTerminal(
                cache.entries.items,
                non_terminal,
            );
            if (self.context_log and (stats.cache_misses[non_terminal] <= 3 or stats.cache_misses[non_terminal] % 25 == 0)) {
                std.debug.print(
                    "[parse_table_build] closure context non_terminal={d} name={s} contexts={d} unique_context_lookaheads={d} unique_context_first_sets={d} merged_follow(terminals={d}, externals={d}, epsilon={}) production_end_follow(terminals={d}, externals={d})\n",
                    .{
                        non_terminal,
                        if (non_terminal < self.variables.len) self.variables[non_terminal].name else "<unknown>",
                        stats.cache_misses[non_terminal],
                        stats.unique_lookaheads[non_terminal],
                        stats.unique_first_sets[non_terminal],
                        countPresent(context.following_tokens.terminals),
                        countPresent(context.following_tokens.externals),
                        context.following_tokens.includes_epsilon,
                        countPresent(context.production_end_follow.terminals),
                        countPresent(context.production_end_follow.externals),
                    },
                );
            }
        }
        return generated;
    }
};

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
                .lhs_kind = variable.kind,
                .steps = production.steps,
                .lhs_is_repeat_auxiliary = variable.kind == .auxiliary and std.mem.indexOf(u8, variable.name, "_repeat") != null,
                .dynamic_precedence = production.dynamic_precedence,
                .production_metadata_eligible = productionMetadataEligible(
                    grammar.variables_to_inline,
                    @intCast(variable_index),
                    production.steps,
                ),
            });
        }
    }

    return try productions.toOwnedSlice();
}

fn productionMetadataEligible(
    variables_to_inline: []const syntax_ir.SymbolRef,
    lhs: u32,
    steps: []const syntax_ir.ProductionStep,
) bool {
    if (isNonTerminalInline(variables_to_inline, lhs)) return false;
    for (steps) |step| {
        switch (step.symbol) {
            .non_terminal => |index| if (isNonTerminalInline(variables_to_inline, index)) return false,
            else => {},
        }
    }
    return true;
}

test "SuccessorGroups substitutes inline cursor symbols before grouping transitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var wrapper_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .terminal = 2 } },
    };
    var inline_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "wrapper", .kind = .named, .productions = &.{.{ .steps = wrapper_steps[0..] }} },
            .{ .name = "inline_part", .kind = .auxiliary, .productions = &.{.{ .steps = inline_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{.{ .non_terminal = 2 }},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const first_sets = try first.computeFirstSets(arena.allocator(), grammar);
    const productions = try collectProductions(arena.allocator(), grammar);
    var item_set_builder = try ParseItemSetBuilder.init(
        arena.allocator(),
        productions,
        first_sets,
        &.{},
        null,
        grammar.variables_to_inline,
        grammar.variables,
    );
    defer item_set_builder.deinit();

    const wrapper_production_id: item.ProductionId = 2;
    const inline_step: u16 = 1;
    const inlined_ids = item_set_builder.inline_map.inlinedProductions(wrapper_production_id, inline_step) orelse return error.ExpectedInlineExpansion;

    var successor_groups = SuccessorGroups.init(arena.allocator());
    defer successor_groups.deinit();
    const state_items = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.initEmpty(
            arena.allocator(),
            first_sets.terminals_len,
            first_sets.externals_len,
            item_set_builder.makeParseItem(wrapper_production_id, inline_step),
        ),
    };

    try successor_groups.buildFromStateItems(
        state_items[0..],
        item_set_builder.productions,
        item_set_builder.item_identity_ids,
        item_set_builder.item_merge_identity_ids,
        &.{},
        item_set_builder.variables_to_inline,
        item_set_builder.inline_map,
    );

    try std.testing.expectEqual(@as(usize, 1), successor_groups.groups.items.len);
    const group = successor_groups.groups.items[0];
    try std.testing.expectEqual(syntax_ir.SymbolRef{ .terminal = 1 }, group.symbol);
    try std.testing.expectEqual(@as(usize, 1), group.items.items.len);
    try std.testing.expectEqual(inlined_ids[0], group.items.items[0].item.production_id);
    try std.testing.expectEqual(@as(u16, 2), group.items.items[0].item.step_index);
}

test "ParseItemSetBuilder precomputes transitive closure additions with propagated follow sets" {
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null, &.{}, &.{});
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
                try std.testing.expect(addition.info.propagates_lookaheads);
                try std.testing.expect(!addition.info.lookaheads.containsTerminal(2));
            },
            3 => {
                saw_a_to_d = true;
                try std.testing.expect(addition.info.propagates_lookaheads);
                try std.testing.expect(!addition.info.lookaheads.containsTerminal(2));
            },
            4 => {
                saw_b_to_e = true;
                try std.testing.expect(!addition.info.propagates_lookaheads);
                try std.testing.expect(addition.info.lookaheads.containsTerminal(2));
            },
            else => return error.UnexpectedProductionId,
        }
    }

    try std.testing.expect(saw_a_to_b_c);
    try std.testing.expect(saw_a_to_d);
    try std.testing.expect(saw_b_to_e);
}

test "ParseItemSetBuilder continues scanning productions after inline first steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var a_to_inline_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var a_to_b_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 3 } },
    };
    var inline_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };
    var b_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{
                .name = "A",
                .kind = .named,
                .productions = &.{
                    .{ .steps = a_to_inline_steps[0..] },
                    .{ .steps = a_to_b_steps[0..] },
                },
            },
            .{ .name = "inline_part", .kind = .hidden, .productions = &.{.{ .steps = inline_steps[0..] }} },
            .{ .name = "B", .kind = .named, .productions = &.{.{ .steps = b_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{.{ .non_terminal = 2 }},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const first_sets = try first.computeFirstSets(arena.allocator(), grammar);
    const productions = try collectProductions(arena.allocator(), grammar);
    var item_set_builder = try ParseItemSetBuilder.init(
        arena.allocator(),
        productions,
        first_sets,
        &.{},
        null,
        grammar.variables_to_inline,
        grammar.variables,
    );
    defer item_set_builder.deinit();

    var saw_b_descendant = false;
    for (item_set_builder.additionsForNonTerminal(1)) |addition| {
        if (addition.production_id == 5) saw_b_descendant = true;
    }

    try std.testing.expect(saw_b_descendant);
}

test "ParseItemSetBuilder carries upstream-style transitive lookahead propagation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var a_to_b_c_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .non_terminal = 3 } },
    };
    var b_to_d_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 4 } },
    };
    var c_to_epsilon_steps = [_]syntax_ir.ProductionStep{};
    var c_to_token_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 2 } },
    };
    var d_to_token_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 0 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "A", .kind = .named, .productions = &.{.{ .steps = a_to_b_c_steps[0..] }} },
            .{ .name = "B", .kind = .named, .productions = &.{.{ .steps = b_to_d_steps[0..] }} },
            .{
                .name = "C",
                .kind = .named,
                .productions = &.{
                    .{ .steps = c_to_epsilon_steps[0..] },
                    .{ .steps = c_to_token_steps[0..] },
                },
            },
            .{ .name = "D", .kind = .named, .productions = &.{.{ .steps = d_to_token_steps[0..] }} },
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null, &.{}, &.{});
    defer item_set_builder.deinit();

    const additions = item_set_builder.additionsForNonTerminal(1);

    var saw_b_production = false;
    var saw_d_production = false;
    for (additions) |addition| {
        switch (addition.production_id) {
            3 => {
                saw_b_production = true;
                try std.testing.expect(addition.info.lookaheads.containsTerminal(2));
                try std.testing.expect(!addition.info.propagates_lookaheads);
            },
            6 => {
                saw_d_production = true;
                try std.testing.expect(addition.info.lookaheads.containsTerminal(2));
                try std.testing.expect(!addition.info.propagates_lookaheads);
            },
            else => {},
        }
    }

    try std.testing.expect(saw_b_production);
    try std.testing.expect(saw_d_production);
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null, &.{}, &.{});
    defer item_set_builder.deinit();

    const seed = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(arena.allocator(), first_sets.terminals_len, first_sets.externals_len, item.ParseItem.init(1, 0), .{ .terminal = 0 }),
    };
    const items = try closure(
        arena.allocator(),
        grammar.variables,
        item_set_builder,
        seed[0..],
        .{},
        null,
    );

    try std.testing.expect(findParseItem(items, item.ParseItem.init(1, 0), .{ .terminal = 0 }) != null);
    try std.testing.expect(findParseItem(items, item.ParseItem.init(2, 0), .{ .terminal = 0 }) != null);
    try std.testing.expect(findParseItem(items, item.ParseItem.init(3, 0), .{ .terminal = 0 }) != null);
    try std.testing.expect(findParseItem(items, item.ParseItem.init(4, 0), .{ .terminal = 2 }) != null);
}

test "buildClosureExpansionItemsAlloc preserves inherited and propagated follow signals" {
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null, &.{}, &.{});
    defer item_set_builder.deinit();

    const generated = try buildClosureExpansionItemsAlloc(arena.allocator(), item_set_builder, 1, blk: {
        var context_follow = try initEmptySymbolSet(arena.allocator(), first_sets.terminals_len, first_sets.externals_len);
        context_follow.includes_epsilon = true;
        context_follow.terminals.set(0);
        break :blk ClosureContext{
            .following_tokens = context_follow,
            .production_end_follow = production_end: {
                var production_end_follow = try initEmptySymbolSet(arena.allocator(), first_sets.terminals_len, first_sets.externals_len);
                production_end_follow.terminals.set(0);
                break :production_end production_end_follow;
            },
            .following_reserved_word_set_id = 0,
            .production_end_reserved_word_set_id = 0,
        };
    }, .{});

    try std.testing.expect(findParseItem(generated, item.ParseItem.init(2, 0), .{ .terminal = 0 }) != null);
    try std.testing.expect(findParseItem(generated, item.ParseItem.init(3, 0), .{ .terminal = 0 }) != null);
    try std.testing.expect(findParseItem(generated, item.ParseItem.init(4, 0), .{ .terminal = 2 }) != null);
    try std.testing.expect(findParseItem(generated, item.ParseItem.init(4, 0), .{ .terminal = 0 }) == null);
}

test "closure preserves named-precedence plus lookahead through recursive context when nullable-suffix projection is empty at the immediate boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var expr_recursive_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .precedence = .{ .name = "sum" },
            .associativity = .left,
        },
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var expr_atom_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .terminal = 0 },
            .precedence = .{ .name = "atom" },
        },
    };
    var plus_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };
    const precedence_ordering = [_]syntax_ir.PrecedenceEntry{
        .{ .name = "atom" },
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .name = "sum" },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{
                .name = "expr",
                .kind = .named,
                .productions = &.{
                    .{ .steps = expr_recursive_steps[0..] },
                    .{ .steps = expr_atom_steps[0..] },
                },
            },
            .{
                .name = "plus",
                .kind = .named,
                .productions = &.{.{ .steps = plus_steps[0..] }},
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{precedence_ordering[0..]},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const first_sets = try first.computeFirstSets(arena.allocator(), grammar);
    const productions = try collectProductions(arena.allocator(), grammar);
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null, &.{}, &.{});
    defer item_set_builder.deinit();

    const seed = [_]item.ParseItemSetEntry{
        try item.ParseItemSetEntry.withLookahead(
            arena.allocator(),
            first_sets.terminals_len,
            first_sets.externals_len,
            item.ParseItem.init(2, 1),
            .{ .terminal = 1 },
        ),
    };

    const items = try closure(
        arena.allocator(),
        grammar.variables,
        item_set_builder,
        seed[0..],
        .{},
        null,
    );

    try std.testing.expect(findParseItem(items, item.ParseItem.init(4, 0), .{ .terminal = 0 }) != null);
}

test "ClosureContext keeps upstream immediate following tokens separate from production-end follow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var inherited = try initEmptySymbolSet(arena.allocator(), 3, 0);
    inherited.terminals.set(2);
    var following = try initEmptySymbolSet(arena.allocator(), 3, 0);
    following.terminals.set(1);
    following.includes_epsilon = true;

    const context = try ClosureContext.init(arena.allocator(), following, 7, inherited, 11);
    defer context.deinit(arena.allocator());

    try std.testing.expect(context.following_tokens.terminals.get(1));
    try std.testing.expect(!context.following_tokens.terminals.get(2));
    try std.testing.expect(context.following_tokens.includes_epsilon);
    try std.testing.expectEqual(@as(u16, 7), context.following_reserved_word_set_id);
    try std.testing.expect(context.production_end_follow.terminals.get(2));
    try std.testing.expect(!context.production_end_follow.terminals.get(1));
    try std.testing.expectEqual(@as(u16, 11), context.production_end_reserved_word_set_id);
}

fn findParseItem(items: []const item.ParseItemSetEntry, needle: item.ParseItem, lookahead: syntax_ir.SymbolRef) ?usize {
    for (items, 0..) |candidate, index| {
        if (parseItemMatchesTestNeedle(candidate.item, needle) and item.containsLookahead(candidate.lookaheads, lookahead)) return index;
    }
    return null;
}

fn parseItemMatchesTestNeedle(candidate: item.ParseItem, needle: item.ParseItem) bool {
    if (needle.variable_index != item.unset_variable_index and candidate.variable_index != needle.variable_index) return false;
    var normalized_candidate = candidate;
    normalized_candidate.variable_index = needle.variable_index;
    return item.ParseItem.eql(normalized_candidate, needle);
}

const ExtraSeedGroup = struct {
    symbol: syntax_ir.SymbolRef,
    items: std.array_list.Managed(item.ParseItemSetEntry),

    fn init(allocator: std.mem.Allocator, symbol: syntax_ir.SymbolRef) @This() {
        return .{
            .symbol = symbol,
            .items = std.array_list.Managed(item.ParseItemSetEntry).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        self.items.deinit();
    }
};

fn addNonTerminalExtraStatesAlloc(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    item_set_builder: ParseItemSetBuilder,
    options: BuildOptions,
    state_registry: *StateRegistry,
) BuildError![]const NonTerminalExtraStart {
    if (options.non_terminal_extra_symbols.len == 0) return &.{};

    var groups = std.array_list.Managed(ExtraSeedGroup).init(allocator);
    defer {
        for (groups.items) |*group| group.deinit();
        groups.deinit();
    }

    for (options.non_terminal_extra_symbols) |extra_symbol| {
        const variable_index = switch (extra_symbol) {
            .non_terminal => |index| index,
            else => continue,
        };
        for (productions, 0..) |production, production_id| {
            if (production.augmented or production.lhs != variable_index) continue;
            if (production.steps.len == 0) continue;
            const first_symbol = production.steps[0].symbol;
            switch (first_symbol) {
                .terminal, .external => {},
                .end, .non_terminal => return error.UnsupportedFeature,
            }

            const group_index = try extraSeedGroupIndex(allocator, &groups, first_symbol);
            var entry = try item.ParseItemSetEntry.initEmpty(
                allocator,
                first_sets.terminals_len,
                first_sets.externals_len,
                item_set_builder.makeParseItem(@intCast(production_id), 1),
            );
            item.addLookahead(&entry.lookaheads, .{ .end = {} });
            try groups.items[group_index].items.append(entry);
        }
    }

    const starts = try allocator.alloc(NonTerminalExtraStart, groups.items.len);
    for (groups.items, 0..) |*group, index| {
        const item_set = try item_set_builder.transitiveClosure(
            allocator,
            variables,
            .{ .entries = group.items.items },
            options,
        );
        state.sortItems(group.items.items);
        const interned = try state_registry.intern(
            .{ .entries = group.items.items },
            item_set,
            &.{},
        );
        starts[index] = .{
            .symbol = group.symbol,
            .state_id = interned.state_id,
        };
    }
    return starts;
}

fn computeFollowSetsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    variable_count: usize,
) BuildError!FollowSets {
    const values = try allocator.alloc(first.SymbolSet, variable_count);
    errdefer allocator.free(values);

    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |set| freeSymbolSet(allocator, set);
    for (values) |*set| {
        set.* = try initEmptySymbolSet(allocator, first_sets.terminals_len, first_sets.externals_len);
        initialized += 1;
    }
    if (values.len != 0) item.addLookahead(&values[0], .{ .end = {} });

    var changed = true;
    while (changed) {
        changed = false;
        for (productions) |production| {
            if (production.augmented) continue;
            if (production.lhs >= values.len) continue;
            for (production.steps, 0..) |step, step_index| {
                const non_terminal = switch (step.symbol) {
                    .non_terminal => |index| index,
                    else => continue,
                };
                if (non_terminal >= values.len) continue;

                const suffix = production.steps[step_index + 1 ..];
                const suffix_first = try first_sets.firstOfSequence(allocator, suffix);
                defer freeSymbolSet(allocator, suffix_first);

                changed = mergeFollowWithoutEpsilon(&values[non_terminal], suffix_first) or changed;
                if (suffix_first.includes_epsilon) {
                    changed = mergeFollowWithoutEpsilon(&values[non_terminal], values[production.lhs]) or changed;
                }
            }
        }
    }

    return .{ .values = values };
}

fn extraSeedGroupIndex(
    allocator: std.mem.Allocator,
    groups: *std.array_list.Managed(ExtraSeedGroup),
    symbol: syntax_ir.SymbolRef,
) std.mem.Allocator.Error!usize {
    for (groups.items, 0..) |group, index| {
        if (symbolRefEql(group.symbol, symbol)) return index;
    }
    const index = groups.items.len;
    try groups.append(ExtraSeedGroup.init(allocator, symbol));
    return index;
}

fn constructStates(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    _: []const ProductionInfo,
    first_sets: first.FirstSets,
    item_set_builder: ParseItemSetBuilder,
    options: BuildOptions,
) BuildError!ConstructedStates {
    var reporter = ConstructStatesReporter.init(variables);
    reporter.logEnter();
    var state_registry = StateRegistry.init(allocator);
    defer state_registry.deinit();
    var grouped_action_states = std.array_list.Managed(actions.GroupedStateActions).init(allocator);
    defer grouped_action_states.deinit();
    var largest_new_successor: ?SuccessorDiagnostic = null;
    var largest_reused_successor: ?SuccessorDiagnostic = null;

    const start_timer = reporter.startInitialClosure();
    const start_seed = [_]item.ParseItemSetEntry{
        blk: {
            var entry = try item.ParseItemSetEntry.initEmpty(
                allocator,
                first_sets.terminals_len,
                first_sets.externals_len,
                item_set_builder.makeParseItem(0, 0),
            );
            item.addLookahead(&entry.lookaheads, .{ .end = {} });
            break :blk entry;
        },
    };
    const start_item_set = try item_set_builder.transitiveClosure(
        allocator,
        variables,
        .{ .entries = start_seed[0..] },
        options,
    );
    reporter.logInitialClosureDone(start_timer, start_item_set.entries.len);
    try state_registry.appendErrorState();
    try state_registry.appendInitialState(.{ .entries = start_seed[0..] }, start_item_set);
    var closure_expansion_cache = ClosureExpansionCache.init(allocator);
    defer closure_expansion_cache.deinit();
    var successor_seed_state_cache = SuccessorSeedStateCache.init(allocator);
    defer successor_seed_state_cache.deinit();
    const all_productions = item_set_builder.productions;
    const non_terminal_extra_starts = try addNonTerminalExtraStatesAlloc(
        allocator,
        variables,
        all_productions,
        first_sets,
        item_set_builder,
        options,
        &state_registry,
    );
    const follow_sets = if (options.closure_lookahead_mode == .none and options.coarse_follow_lookaheads)
        try computeFollowSetsAlloc(allocator, all_productions, first_sets, variables.len)
    else
        FollowSets{ .values = &.{} };
    defer follow_sets.deinit(allocator);
    const field_productions = all_productions[0..item_set_builder.original_productions_len];
    const variable_has_fields = try computeVariableHasFieldsAlloc(
        allocator,
        field_productions,
        variableCountFromProductions(all_productions),
    );
    defer allocator.free(variable_has_fields);

    var state_engine = StateConstructionEngine{
        .allocator = allocator,
        .variables = variables,
        .productions = all_productions,
        .first_sets = first_sets,
        .follow_sets = follow_sets.values,
        .variable_has_fields = variable_has_fields,
        .item_set_builder = item_set_builder,
        .closure_expansion_cache = &closure_expansion_cache,
        .successor_seed_state_cache = &successor_seed_state_cache,
        .state_registry = &state_registry,
        .grouped_action_states = &grouped_action_states,
        .largest_new_successor = &largest_new_successor,
        .largest_reused_successor = &largest_reused_successor,
        .non_terminal_extra_starts = non_terminal_extra_starts,
        .options = options,
    };

    var next_state_index: usize = 0;
    while (next_state_index < state_registry.items().len) : (next_state_index += 1) {
        try state_engine.processState(&reporter, next_state_index);
    }

    state.sortStates(state_registry.items());
    reporter.logComplete(
        state_registry.items().len,
        largest_new_successor,
        largest_reused_successor,
    );
    return .{
        .states = try state_registry.intoOwnedSlice(),
        .grouped_actions = .{
            .states = try grouped_action_states.toOwnedSlice(),
        },
    };
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
    try std.testing.expect(result.actions.entriesForState(1).len > 0);
}

fn closure(
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    item_set_builder: ParseItemSetBuilder,
    seed_items: []const item.ParseItemSetEntry,
    options: BuildOptions,
    expansion_cache: ?*ClosureExpansionCache,
) BuildError![]const item.ParseItemSetEntry {
    if (construct_profile_enabled) construct_profile.closure_runs += 1;
    var run = ClosureRun.init(allocator, variables, item_set_builder, options, expansion_cache);
    defer run.deinit();
    try run.seed(seed_items);

    var stats = try ClosureStats.init(allocator, run.progress_log, item_set_builder.productions);
    defer stats.deinit();
    const reporter = ClosureReporter.init(run.progress_log, run.trace_current_closure);
    reporter.logStart(seed_items.len);

    const seed_count = run.items.items.len;
    const round: usize = 1;
    const round_start_len = run.items.items.len;
    reporter.logRoundStart(round, round_start_len);
    var cursor: usize = 0;
    while (cursor < seed_count) : (cursor += 1) {
        reporter.logCursorProgress(round, cursor, seed_count);
        _ = try run.expandCursor(&stats, round, cursor, options);
    }
    state.sortItems(run.items.items);
    reporter.logRoundDone(
        variables,
        &stats,
        round,
        run.items.items.len,
        run.items.items.len - round_start_len,
        false,
    );

    reporter.logComplete(1, run.items.items.len, run.effective_closure_lookahead_mode);

    return try run.toOwnedSlice();
}

fn appendGeneratedItemsToClosure(
    allocator: std.mem.Allocator,
    items: *std.array_list.Managed(item.ParseItemSetEntry),
    item_indexes: *ClosureItemIndexMap,
    generated_items: []const item.ParseItemSetEntry,
    take_ownership: bool,
) BuildError!AppendStats {
    var stats = AppendStats{
        .changed = false,
        .added = 0,
        .duplicate_checks = 0,
        .duplicate_hits = 0,
    };

    for (generated_items) |new_item| {
        stats.duplicate_checks += 1;
        if (item_indexes.get(new_item.item)) |existing_index| {
            stats.duplicate_hits += 1;
            stats.changed = mergeSymbolSetLookaheads(&items.items[existing_index].lookaheads, new_item.lookaheads) or stats.changed;
            if (new_item.following_reserved_word_set_id > items.items[existing_index].following_reserved_word_set_id) {
                items.items[existing_index].following_reserved_word_set_id = new_item.following_reserved_word_set_id;
                stats.changed = true;
            }
            if (take_ownership) {
                freeSymbolSet(allocator, new_item.lookaheads);
            }
        } else {
            const owned_item = if (take_ownership)
                new_item
            else
                item.ParseItemSetEntry{
                    .item = new_item.item,
                    .lookaheads = try cloneSymbolSet(allocator, new_item.lookaheads),
                    .following_reserved_word_set_id = new_item.following_reserved_word_set_id,
                };
            const new_index = items.items.len;
            try items.append(owned_item);
            try item_indexes.put(owned_item.item, new_index);
            stats.changed = true;
            stats.added += 1;
        }
    }

    return stats;
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

fn symbolRefIn(symbols: []const syntax_ir.SymbolRef, symbol: syntax_ir.SymbolRef) bool {
    return for (symbols) |candidate| {
        if (symbolRefEql(candidate, symbol)) break true;
    } else false;
}

fn hasTransitionForSymbol(transitions: []const state.Transition, symbol: syntax_ir.SymbolRef) bool {
    return for (transitions) |transition| {
        if (symbolRefEql(transition.symbol, symbol)) break true;
    } else false;
}

fn appendOrMergeClosureEntry(
    allocator: std.mem.Allocator,
    entries: *std.array_list.Managed(item.ParseItemSetEntry),
    item_indexes: *ClosureItemIndexMap,
    incoming: item.ParseItemSetEntry,
    take_ownership: bool,
) !void {
    if (item_indexes.get(incoming.item)) |index| {
        _ = mergeSymbolSetLookaheads(&entries.items[index].lookaheads, incoming.lookaheads);
        entries.items[index].following_reserved_word_set_id = @max(
            entries.items[index].following_reserved_word_set_id,
            incoming.following_reserved_word_set_id,
        );
        if (take_ownership) {
            freeSymbolSet(allocator, incoming.lookaheads);
        }
        return;
    }

    const owned_entry = if (take_ownership)
        incoming
    else
        item.ParseItemSetEntry{
            .item = incoming.item,
            .lookaheads = try cloneSymbolSet(allocator, incoming.lookaheads),
            .following_reserved_word_set_id = incoming.following_reserved_word_set_id,
        };
    const new_index = entries.items.len;
    try entries.append(owned_entry);
    try item_indexes.put(owned_entry.item, new_index);
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
    try std.testing.expectEqual(@as(usize, 5), result.states.len);
    try std.testing.expectEqual(@as(state.StateId, 0), result.states[0].id);
    try std.testing.expectEqual(@as(usize, 0), result.states[0].items.len);
    try std.testing.expectEqual(@as(usize, 0), result.states[0].transitions.len);
    try std.testing.expectEqual(@as(state.StateId, 1), result.states[1].id);
    try std.testing.expectEqual(@as(usize, 3), result.states[1].items.len);
    try std.testing.expectEqual(@as(usize, 3), result.states[1].transitions.len);
}

test "buildStates seeds parser EOF lookahead and accepts on EOF" {
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

    const result = try buildStates(arena.allocator(), grammar);

    try std.testing.expect(findParseItem(result.states[1].items, item.ParseItem.init(0, 0), .{ .end = {} }) != null);

    var saw_accept_on_end = false;
    var saw_real_terminal_in_lex_state = false;
    for (result.actions.states) |state_actions| {
        for (state_actions.entries) |entry| {
            if (symbolRefEql(entry.symbol, .{ .end = {} }) and entry.action == .accept) {
                saw_accept_on_end = true;
            }
        }
    }
    for (result.lex_state_terminal_sets) |terminal_set| {
        try std.testing.expect(terminal_set.len <= 1);
        if (terminal_set.len != 0 and terminal_set[0]) saw_real_terminal_in_lex_state = true;
    }

    try std.testing.expect(saw_accept_on_end);
    try std.testing.expect(saw_real_terminal_in_lex_state);
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
    for (result.states[1].items) |parse_item| {
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

test "buildStates reduces nested JSON-like values before separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lbrace: u32 = 0;
    const comma: u32 = 1;
    const rbrace: u32 = 2;
    const lbracket: u32 = 3;
    const rbracket: u32 = 4;
    const colon: u32 = 5;
    const string_token: u32 = 6;
    const number_token: u32 = 7;

    var document_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var value_object_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var value_array_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 5 } },
    };
    var value_number_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = number_token } },
    };
    var object_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = lbrace } },
        .{ .symbol = .{ .non_terminal = 3 } },
        .{ .symbol = .{ .terminal = rbrace } },
    };
    var pair_list_single_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 4 } },
    };
    var pair_list_repeat_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 3 } },
        .{ .symbol = .{ .terminal = comma } },
        .{ .symbol = .{ .non_terminal = 4 } },
    };
    var pair_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = string_token } },
        .{ .symbol = .{ .terminal = colon } },
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var array_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = lbracket } },
        .{ .symbol = .{ .non_terminal = 6 } },
        .{ .symbol = .{ .terminal = rbracket } },
    };
    var value_list_single_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var value_list_repeat_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 6 } },
        .{ .symbol = .{ .terminal = comma } },
        .{ .symbol = .{ .non_terminal = 1 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "document", .kind = .named, .productions = &.{.{ .steps = document_steps[0..] }} },
            .{ .name = "_value", .kind = .hidden, .productions = &.{
                .{ .steps = value_object_steps[0..] },
                .{ .steps = value_array_steps[0..] },
                .{ .steps = value_number_steps[0..] },
            } },
            .{ .name = "object", .kind = .named, .productions = &.{.{ .steps = object_steps[0..] }} },
            .{ .name = "pair_list", .kind = .auxiliary, .productions = &.{
                .{ .steps = pair_list_single_steps[0..] },
                .{ .steps = pair_list_repeat_steps[0..] },
            } },
            .{ .name = "pair", .kind = .named, .productions = &.{.{ .steps = pair_steps[0..] }} },
            .{ .name = "array", .kind = .named, .productions = &.{.{ .steps = array_steps[0..] }} },
            .{ .name = "value_list", .kind = .auxiliary, .productions = &.{
                .{ .steps = value_list_single_steps[0..] },
                .{ .steps = value_list_repeat_steps[0..] },
            } },
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
    const value_number_production = for (result.productions, 0..) |production, production_id| {
        if (production.augmented) continue;
        if (production.lhs != 1) continue;
        if (production.steps.len != 1) continue;
        switch (production.steps[0].symbol) {
            .terminal => |terminal| if (terminal == number_token) break @as(u32, @intCast(production_id)),
            else => {},
        }
    } else return error.TestUnexpectedResult;

    _ = value_number_production;
    const raw_actions = try actions.buildActionTable(arena.allocator(), result.productions, result.states);
    try std.testing.expect(hasReduceActionForLhsInActionTable(raw_actions, result.productions, 5, .{ .terminal = rbracket }));
    try std.testing.expect(hasReduceActionForLhsInActionTable(raw_actions, result.productions, 2, .{ .terminal = rbrace }));
}

test "buildStates uses SLR follow lookaheads for completed coarse closure items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const const_token: u32 = 0;
    const var_token: u32 = 1;
    const identifier: u32 = 2;
    const eq: u32 = 3;
    const number: u32 = 4;
    const semicolon: u32 = 5;

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var decl_with_value_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .terminal = eq } },
        .{ .symbol = .{ .non_terminal = 3 } },
        .{ .symbol = .{ .terminal = semicolon } },
    };
    var decl_without_value_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .terminal = semicolon } },
    };
    var const_header_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = const_token } },
        .{ .symbol = .{ .terminal = identifier } },
    };
    var var_header_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = var_token } },
        .{ .symbol = .{ .terminal = identifier } },
    };
    var expr_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = number } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "variable_declaration", .kind = .named, .productions = &.{
                .{ .steps = decl_with_value_steps[0..] },
                .{ .steps = decl_without_value_steps[0..] },
            } },
            .{ .name = "_variable_declaration_header", .kind = .hidden, .productions = &.{
                .{ .steps = const_header_steps[0..] },
                .{ .steps = var_header_steps[0..] },
            } },
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

    const result = try buildStatesWithOptions(arena.allocator(), grammar, .{
        .closure_lookahead_mode = .none,
        .coarse_follow_lookaheads = true,
    });
    const header_production = for (result.productions, 0..) |production, production_id| {
        if (production.augmented) continue;
        if (production.lhs != 2) continue;
        if (production.steps.len != 2) continue;
        switch (production.steps[0].symbol) {
            .terminal => |terminal| if (terminal == const_token) break @as(u32, @intCast(production_id)),
            else => {},
        }
    } else return error.TestUnexpectedResult;

    try std.testing.expect(hasReduceAction(result.actions, header_production, .{ .terminal = eq }));
    try std.testing.expect(hasReduceAction(result.actions, header_production, .{ .terminal = semicolon }));
}

fn hasReduceAction(
    action_table: actions.ActionTable,
    production_id: item.ProductionId,
    lookahead: syntax_ir.SymbolRef,
) bool {
    for (action_table.states) |state_actions| {
        for (state_actions.entries) |entry| {
            if (!symbolRefEql(entry.symbol, lookahead)) continue;
            switch (entry.action) {
                .reduce => |reduced| if (reduced == production_id) return true,
                else => {},
            }
        }
    }
    return false;
}

fn hasReduceActionForLhs(
    result: BuildResult,
    lhs: u32,
    lookahead: syntax_ir.SymbolRef,
) bool {
    return hasReduceActionForLhsInActionTable(result.actions, result.productions, lhs, lookahead);
}

fn hasReduceActionForLhsInActionTable(
    action_table: actions.ActionTable,
    productions: []const ProductionInfo,
    lhs: u32,
    lookahead: syntax_ir.SymbolRef,
) bool {
    for (action_table.states) |state_actions| {
        for (state_actions.entries) |entry| {
            if (!symbolRefEql(entry.symbol, lookahead)) continue;
            switch (entry.action) {
                .reduce => |reduced| {
                    if (reduced < productions.len and productions[reduced].lhs == lhs) return true;
                },
                else => {},
            }
        }
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

    try std.testing.expectEqual(@as(usize, 4), result.states.len);
    try std.testing.expectEqual(@as(state.StateId, 3), result.states[1].transitions[1].state);
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

test "buildStates assigns reserved-word set id for direct word-token context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .terminal = 0 },
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
        .word_token = .{ .terminal = 0 },
    };

    const result = try buildStatesWithOptions(arena.allocator(), grammar, .{
        .reserved_word_context_names = &.{"global"},
    });

    try std.testing.expectEqual(@as(u16, 1), result.states[1].reserved_word_set_id);
}

test "buildStates does not propagate immediate reserved-word context through closure suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{
            .symbol = .{ .terminal = 0 },
            .reserved_context_name = "global",
        },
    };
    var wrapper_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var leaf_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "wrapper", .kind = .named, .productions = &.{.{ .steps = wrapper_steps[0..] }} },
            .{ .name = "leaf", .kind = .named, .productions = &.{.{ .steps = leaf_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = .{ .terminal = 0 },
    };

    const result = try buildStatesWithOptions(arena.allocator(), grammar, .{
        .reserved_word_context_names = &.{"global"},
    });

    var saw_leaf_with_word_lookahead = false;
    for (result.states[1].items) |entry| {
        if (entry.item.production_id == 3 and
            item.containsLookahead(entry.lookaheads, .{ .terminal = 0 }))
        {
            saw_leaf_with_word_lookahead = true;
            try std.testing.expectEqual(@as(u16, 0), entry.following_reserved_word_set_id);
        }
    }

    try std.testing.expect(saw_leaf_with_word_lookahead);
}

test "buildStates propagates following reserved-word set through nested first symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .non_terminal = 2 } },
    };
    var target_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };
    var reserved_wrapper_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 3 } },
    };
    var reserved_leaf_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .terminal = 0 },
            .reserved_context_name = "global",
        },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{ .name = "target", .kind = .named, .productions = &.{.{ .steps = target_steps[0..] }} },
            .{ .name = "reserved_wrapper", .kind = .named, .productions = &.{.{ .steps = reserved_wrapper_steps[0..] }} },
            .{ .name = "reserved_leaf", .kind = .named, .productions = &.{.{ .steps = reserved_leaf_steps[0..] }} },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = .{ .terminal = 0 },
    };

    const result = try buildStatesWithOptions(arena.allocator(), grammar, .{
        .reserved_word_context_names = &.{"global"},
    });

    var saw_propagated = false;
    for (result.states[1].items) |entry| {
        if (entry.item.production_id == 2 and
            item.containsLookahead(entry.lookaheads, .{ .terminal = 0 }) and
            entry.following_reserved_word_set_id == 1)
        {
            saw_propagated = true;
        }
    }

    try std.testing.expect(saw_propagated);
}

test "buildStates carries named-precedence reductions to following and outer tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var expr_recursive_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .non_terminal = 1 },
            .precedence = .{ .name = "sum" },
            .associativity = .left,
        },
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .symbol = .{ .non_terminal = 1 } },
    };
    var expr_atom_steps = [_]syntax_ir.ProductionStep{
        .{
            .symbol = .{ .terminal = 0 },
            .precedence = .{ .name = "atom" },
        },
    };
    var plus_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 1 } },
    };
    const precedence_ordering = [_]syntax_ir.PrecedenceEntry{
        .{ .name = "atom" },
        .{ .symbol = .{ .non_terminal = 2 } },
        .{ .name = "sum" },
    };

    const grammar = syntax_ir.SyntaxGrammar{
        .variables = &.{
            .{ .name = "source_file", .kind = .named, .productions = &.{.{ .steps = source_steps[0..] }} },
            .{
                .name = "expr",
                .kind = .named,
                .productions = &.{
                    .{ .steps = expr_recursive_steps[0..] },
                    .{ .steps = expr_atom_steps[0..] },
                },
            },
            .{
                .name = "plus",
                .kind = .named,
                .productions = &.{.{ .steps = plus_steps[0..] }},
            },
        },
        .external_tokens = &.{},
        .extra_symbols = &.{},
        .expected_conflicts = &.{},
        .precedence_orderings = &.{precedence_ordering[0..]},
        .variables_to_inline = &.{},
        .supertype_symbols = &.{},
        .word_token = null,
    };

    const result = try buildStates(arena.allocator(), grammar);

    var saw_reduce_on_following_terminal = false;
    var saw_reduce_on_outer_terminal = false;
    for (result.resolved_actions.states) |resolved_state| {
        for (resolved_state.groups) |group| {
            const chosen = group.chosenAction() orelse continue;
            switch (chosen) {
                .reduce => {
                    if (symbolRefEql(group.symbol, .{ .terminal = 0 })) saw_reduce_on_following_terminal = true;
                    if (symbolRefEql(group.symbol, .{ .terminal = 1 })) saw_reduce_on_outer_terminal = true;
                },
                else => {},
            }
        }
    }

    try std.testing.expect(saw_reduce_on_following_terminal);
    try std.testing.expect(saw_reduce_on_outer_terminal);
}

test "assignLexStateIdsAlloc reuses ids for equivalent terminal sets deterministically" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 2, .items = &.{}, .transitions = &.{} },
    };

    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .shift = 1 }},
                        .decision = .{ .chosen = .{ .shift = 1 } },
                    },
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .shift = 2 }},
                        .decision = .{ .chosen = .{ .shift = 2 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .shift = 3 }},
                        .decision = .{ .chosen = .{ .shift = 3 } },
                    },
                },
            },
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .shift = 4 }},
                        .decision = .{ .chosen = .{ .shift = 4 } },
                    },
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .shift = 5 }},
                        .decision = .{ .chosen = .{ .shift = 5 } },
                    },
                },
            },
        },
    };

    const assigned = try assignLexStateIdsAlloc(allocator, parse_states[0..], resolved_actions, null, .{});
    defer allocator.free(assigned.states);
    defer {
        for (assigned.terminal_sets) |terminal_set| allocator.free(terminal_set);
        allocator.free(assigned.terminal_sets);
    }

    try std.testing.expectEqual(@as(usize, 2), assigned.count);
    try std.testing.expectEqual(@as(state.LexStateId, 0), assigned.states[0].lex_state_id);
    try std.testing.expectEqual(@as(state.LexStateId, 1), assigned.states[1].lex_state_id);
    try std.testing.expectEqual(assigned.states[0].lex_state_id, assigned.states[2].lex_state_id);
    try std.testing.expectEqual(@as(usize, 2), assigned.terminal_sets.len);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, assigned.terminal_sets[0]);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, assigned.terminal_sets[1]);
}

test "assignLexStateIdsAlloc merges non-conflicting terminal sets" {
    const allocator = std.testing.allocator;

    const parse_states = [_]state.ParseState{
        .{ .id = 0, .items = &.{}, .transitions = &.{} },
        .{ .id = 1, .items = &.{}, .transitions = &.{} },
        .{ .id = 2, .items = &.{}, .transitions = &.{} },
    };
    const resolved_actions = resolution.ResolvedActionTable{
        .states = &[_]resolution.ResolvedStateActions{
            .{
                .state_id = 0,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 0 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .shift = 1 }},
                        .decision = .{ .chosen = .{ .shift = 1 } },
                    },
                },
            },
            .{
                .state_id = 1,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 1 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .shift = 2 }},
                        .decision = .{ .chosen = .{ .shift = 2 } },
                    },
                },
            },
            .{
                .state_id = 2,
                .groups = &[_]resolution.ResolvedActionGroup{
                    .{
                        .symbol = .{ .terminal = 2 },
                        .candidate_actions = &[_]actions.ParseAction{.{ .shift = 3 }},
                        .decision = .{ .chosen = .{ .shift = 3 } },
                    },
                },
            },
        },
    };
    var conflict_bits = [_]bool{
        false, true,  false,
        true,  false, false,
        false, false, false,
    };
    const terminal_conflict_map = LexStateTerminalConflictMap{
        .terminal_count = 3,
        .conflicts = conflict_bits[0..],
    };

    const assigned = try assignLexStateIdsAlloc(allocator, parse_states[0..], resolved_actions, terminal_conflict_map, .{});
    defer allocator.free(assigned.states);
    defer {
        for (assigned.terminal_sets) |terminal_set| allocator.free(terminal_set);
        allocator.free(assigned.terminal_sets);
    }

    try std.testing.expectEqual(@as(usize, 2), assigned.count);
    try std.testing.expectEqual(@as(state.LexStateId, 0), assigned.states[0].lex_state_id);
    try std.testing.expectEqual(@as(state.LexStateId, 1), assigned.states[1].lex_state_id);
    try std.testing.expectEqual(@as(state.LexStateId, 0), assigned.states[2].lex_state_id);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, assigned.terminal_sets[0]);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false }, assigned.terminal_sets[1]);
}

test "BuildResult exposes unused expected conflict indexes" {
    const allocator = std.testing.allocator;
    const expected_used = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 2 },
        .{ .non_terminal = 1 },
    };
    const expected_unused = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 1 },
        .{ .non_terminal = 9 },
    };
    const reduce_actions = [_]actions.ParseAction{
        .{ .reduce = 1 },
        .{ .reduce = 2 },
    };
    const result = BuildResult{
        .productions = &[_]ProductionInfo{
            .{ .lhs = 0, .steps = &.{} },
            .{ .lhs = 1, .steps = &.{} },
            .{ .lhs = 2, .steps = &.{} },
        },
        .precedence_orderings = &.{},
        .expected_conflicts = &.{ &expected_used, &expected_unused },
        .states = &.{},
        .lex_state_count = 0,
        .actions = .{ .states = &.{} },
        .resolved_actions = .{ .states = &[_]resolution.ResolvedStateActions{.{
            .state_id = 4,
            .groups = &[_]resolution.ResolvedActionGroup{.{
                .symbol = .{ .terminal = 0 },
                .candidate_actions = &reduce_actions,
                .decision = .{ .unresolved = .reduce_reduce_expected },
            }},
        }} },
    };

    const unused = try result.unusedExpectedConflictIndexesAlloc(allocator);
    defer allocator.free(unused);
    try std.testing.expectEqual(@as(usize, 1), unused.len);
    try std.testing.expectEqual(@as(usize, 1), unused[0]);

    const candidates = try result.expectedConflictCandidatesAlloc(allocator);
    defer conflict_resolution.freeConflictCandidates(allocator, candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqual(@as(u32, 1), candidates[0].members[0].non_terminal);
    try std.testing.expectEqual(@as(u32, 2), candidates[0].members[1].non_terminal);
}

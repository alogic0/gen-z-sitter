const std = @import("std");
const actions = @import("actions.zig");
const syntax_ir = @import("../ir/syntax_grammar.zig");
const first = @import("first.zig");
const item = @import("item.zig");
const state = @import("state.zig");
const conflicts = @import("conflicts.zig");
const resolution = @import("resolution.zig");
const minimize = @import("minimize.zig");
const rules = @import("../ir/rules.zig");
const runtime_io = @import("../support/runtime_io.zig");

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

const ConstructProfile = struct {
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

fn ensureBuildEnvFlags() void {
    if (build_env_flags_loaded) return;
    build_env_flags = .{
        .trace_top_comment = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_TRACE_TOP_COMMENT"),
        .build_progress = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_BUILD_PROGRESS"),
        .progress = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_PROGRESS"),
        .global_progress = envFlagEnabledRaw("GEN_Z_SITTER_PROGRESS"),
        .context_log = envFlagEnabledRaw("GEN_Z_SITTER_PARSE_TABLE_CONTEXT_LOG"),
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
        "[parse_table_profile] symbol_sets init_empty={d} clone={d} free={d} bool_alloc_mb={d:.2} bool_free_mb={d:.2}\n",
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
        hasher.update(std.mem.asBytes(&value.production_id));
        hasher.update(std.mem.asBytes(&value.step_index));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: item.ParseItem, b: item.ParseItem) bool {
        return item.ParseItem.eql(a, b);
    }
};

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
        var hasher = std.hash.Wyhash.init(0);
        for (values) |value| {
            hasher.update(std.mem.asBytes(&value.item.production_id));
            hasher.update(std.mem.asBytes(&value.item.step_index));
            hasher.update(std.mem.asBytes(&value.following_reserved_word_set_id));
            hasher.update(value.lookaheads.terminals.maskBytes());
            hasher.update(value.lookaheads.externals.maskBytes());
            hasher.update(std.mem.asBytes(&value.lookaheads.includes_end));
            hasher.update(std.mem.asBytes(&value.lookaheads.includes_epsilon));
        }
        return hasher.final();
    }

    pub fn eql(_: @This(), a: []const item.ParseItemSetEntry, b: []const item.ParseItemSetEntry) bool {
        if (construct_profile_enabled) {
            construct_profile.item_set_eql_calls += 1;
            construct_profile.item_set_eql_entries += @max(a.len, b.len);
        }
        return itemsEql(a, b);
    }
};

const ParseItemSetContext = struct {
    pub fn hash(_: @This(), value: item.ParseItemSet) u64 {
        return ParseItemSliceContext.hash(ParseItemSliceContext{}, value.entries);
    }

    pub fn eql(_: @This(), a: item.ParseItemSet, b: item.ParseItemSet) bool {
        return itemsEql(a.entries, b.entries);
    }
};

const ParseItemSetCoreContext = struct {
    pub fn hash(_: @This(), value: item.ParseItemSetCore) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (value.items) |core_item| {
            hasher.update(std.mem.asBytes(&core_item.production_id));
            hasher.update(std.mem.asBytes(&core_item.step_index));
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

const StateIdByItemSet = std.HashMap(item.ParseItemSet, state.StateId, ParseItemSetContext, std.hash_map.default_max_load_percentage);
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
            if (item.ParseItem.eql(entry.item, parse_item)) return index;
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
    ) !void {
        for (state_items) |entry| {
            const parse_item = entry.item;
            const production = productions[parse_item.production_id];
            if (parse_item.step_index >= production.steps.len) continue;
            const symbol = production.steps[parse_item.step_index].symbol;
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
                    .production_id = parse_item.production_id,
                    .step_index = parse_item.step_index + 1,
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

        for (self.groups.items) |*group| {
            state.sortItems(group.items.items);
        }
    }
};

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
    direct_suffix_follow: first.SymbolSet,
    nullable_ancestor_suffix_follow: first.SymbolSet,
    direct_suffix_reserved_word_set_id: u16 = 0,
    nullable_ancestor_reserved_word_set_id: u16 = 0,

    fn needsProductionEndFollow(self: @This()) bool {
        return self.nullable_ancestor_suffix_follow.includes_epsilon;
    }

    fn hasNullableAncestorContextFollow(self: @This()) bool {
        return countPresent(self.nullable_ancestor_suffix_follow.terminals) > 0 or
            countPresent(self.nullable_ancestor_suffix_follow.externals) > 0;
    }

    fn propagatesInheritedContext(self: @This()) bool {
        return self.needsProductionEndFollow() or self.hasNullableAncestorContextFollow();
    }
};

const TransitiveClosureAddition = struct {
    production_id: item.ProductionId,
    info: ClosureFollowInfo,
};

const ParseItemSetBuilder = struct {
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    additions_per_non_terminal: [][]const TransitiveClosureAddition,
    reserved_word_context_names: []const []const u8,
    word_token: ?syntax_ir.SymbolRef,

    fn init(
        allocator: std.mem.Allocator,
        productions: []const ProductionInfo,
        first_sets: first.FirstSets,
        reserved_word_context_names: []const []const u8,
        word_token: ?syntax_ir.SymbolRef,
    ) !@This() {
        const variable_count = variableCountFromProductions(productions);
        const additions_per_non_terminal = try allocator.alloc([]const TransitiveClosureAddition, variable_count);
        errdefer allocator.free(additions_per_non_terminal);

        for (0..variable_count) |non_terminal| {
            additions_per_non_terminal[non_terminal] = try computeTransitiveClosureAdditionsAlloc(
                allocator,
                productions,
                first_sets,
                reserved_word_context_names,
                @intCast(non_terminal),
            );
        }

        return .{
            .allocator = allocator,
            .productions = productions,
            .first_sets = first_sets,
            .additions_per_non_terminal = additions_per_non_terminal,
            .reserved_word_context_names = reserved_word_context_names,
            .word_token = word_token,
        };
    }

    fn deinit(self: *@This()) void {
        for (self.additions_per_non_terminal) |items| {
            for (items) |addition| {
                freeSymbolSet(self.allocator, addition.info.direct_suffix_follow);
                freeSymbolSet(self.allocator, addition.info.nullable_ancestor_suffix_follow);
            }
            self.allocator.free(items);
        }
        self.allocator.free(self.additions_per_non_terminal);
    }

    fn additionsForNonTerminal(self: @This(), non_terminal: u32) []const TransitiveClosureAddition {
        return self.additions_per_non_terminal[non_terminal];
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

fn addSymbolToSet(target: *first.SymbolSet, symbol: syntax_ir.SymbolRef) void {
    switch (symbol) {
        .end => target.includes_end = true,
        .terminal => |index| target.terminals.set(index),
        .external => |index| target.externals.set(index),
        .non_terminal => {},
    }
}

fn closureContextFollowSet(
    allocator: std.mem.Allocator,
    suffix_first: first.SymbolSet,
    inherited_lookaheads: first.SymbolSet,
) !first.SymbolSet {
    var result = try cloneSymbolSet(allocator, suffix_first);
    if (result.includes_epsilon) {
        _ = mergeSymbolSetLookaheads(&result, inherited_lookaheads);
    }
    return result;
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
        suffix_first: first.SymbolSet,
        suffix_reserved_word_set_id: u16,
        inherited_lookaheads: first.SymbolSet,
        inherited_reserved_word_set_id: u16,
    ) !@This() {
        return .{
            .following_tokens = try closureContextFollowSet(allocator, suffix_first, inherited_lookaheads),
            .production_end_follow = try closureContextProductionEndFollowSet(allocator, inherited_lookaheads),
            .following_reserved_word_set_id = if (suffix_first.includes_epsilon)
                @max(suffix_reserved_word_set_id, inherited_reserved_word_set_id)
            else
                suffix_reserved_word_set_id,
            .production_end_reserved_word_set_id = inherited_reserved_word_set_id,
        };
    }

    fn nullableSuffixNeedsContextFollow(self: @This()) bool {
        return self.following_tokens.includes_epsilon;
    }

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        freeSymbolSet(allocator, self.following_tokens);
        freeSymbolSet(allocator, self.production_end_follow);
    }
};

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
    direct_suffix_follow: first.SymbolSet,
    nullable_ancestor_suffix_follow: first.SymbolSet,
    direct_suffix_reserved_word_set_id: u16 = 0,
    nullable_ancestor_reserved_word_set_id: u16 = 0,
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
            .direct_suffix_follow = try cloneSymbolSet(allocator, incoming.direct_suffix_follow),
            .nullable_ancestor_suffix_follow = try cloneSymbolSet(allocator, incoming.nullable_ancestor_suffix_follow),
            .direct_suffix_reserved_word_set_id = incoming.direct_suffix_reserved_word_set_id,
            .nullable_ancestor_reserved_word_set_id = incoming.nullable_ancestor_reserved_word_set_id,
        };
        return true;
    }

    var changed = false;
    changed = mergeSymbolSetLookaheads(&target.*.?.direct_suffix_follow, incoming.direct_suffix_follow) or changed;
    changed = mergeSymbolSetLookaheads(&target.*.?.nullable_ancestor_suffix_follow, incoming.nullable_ancestor_suffix_follow) or changed;
    if (incoming.direct_suffix_reserved_word_set_id > target.*.?.direct_suffix_reserved_word_set_id) {
        target.*.?.direct_suffix_reserved_word_set_id = incoming.direct_suffix_reserved_word_set_id;
        changed = true;
    }
    if (incoming.nullable_ancestor_reserved_word_set_id > target.*.?.nullable_ancestor_reserved_word_set_id) {
        target.*.?.nullable_ancestor_reserved_word_set_id = incoming.nullable_ancestor_reserved_word_set_id;
        changed = true;
    }
    if (incoming.nullable_ancestor_suffix_follow.includes_epsilon and !target.*.?.nullable_ancestor_suffix_follow.includes_epsilon) {
        target.*.?.nullable_ancestor_suffix_follow.includes_epsilon = true;
        changed = true;
    }
    return changed;
}

fn computeTransitiveClosureAdditionsAlloc(
    allocator: std.mem.Allocator,
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    reserved_word_context_names: []const []const u8,
    root_non_terminal: u32,
) ![]const TransitiveClosureAddition {
    const variable_count = variableCountFromProductions(productions);
    var infos = try allocator.alloc(?ClosureFollowInfo, variable_count);
    defer {
        for (infos) |maybe_info| {
            if (maybe_info) |info| {
                freeSymbolSet(allocator, info.direct_suffix_follow);
                freeSymbolSet(allocator, info.nullable_ancestor_suffix_follow);
            }
        }
        allocator.free(infos);
    }
    @memset(infos, null);

    var stack = std.array_list.Managed(FollowWorkEntry).init(allocator);
    defer {
        for (stack.items) |entry| {
            freeSymbolSet(allocator, entry.direct_suffix_follow);
            freeSymbolSet(allocator, entry.nullable_ancestor_suffix_follow);
        }
        stack.deinit();
    }

    try stack.append(.{
        .non_terminal = root_non_terminal,
        .direct_suffix_follow = try initEmptySymbolSet(allocator, first_sets.terminals_len, first_sets.externals_len),
        .direct_suffix_reserved_word_set_id = 0,
        .nullable_ancestor_suffix_follow = blk: {
            var set = try initEmptySymbolSet(allocator, first_sets.terminals_len, first_sets.externals_len);
            set.includes_epsilon = true;
            break :blk set;
        },
        .nullable_ancestor_reserved_word_set_id = 0,
    });

    while (stack.items.len > 0) {
        const entry = stack.pop().?;
        const changed = try mergeFollowInfo(allocator, &infos[entry.non_terminal], entry);
        freeSymbolSet(allocator, entry.direct_suffix_follow);
        freeSymbolSet(allocator, entry.nullable_ancestor_suffix_follow);
        if (!changed) continue;

        for (productions) |production| {
            if (production.augmented) continue;
            if (production.lhs != entry.non_terminal) continue;
            if (production.steps.len == 0) continue;

            switch (production.steps[0].symbol) {
                .non_terminal => |next_non_terminal| {
                    const remainder = production.steps[1..];
                    var direct_suffix_follow = try if (remainder.len == 0)
                        initEmptySymbolSet(allocator, first_sets.terminals_len, first_sets.externals_len)
                    else
                        first_sets.firstOfSequence(allocator, remainder);
                    const direct_suffix_reserved_word_set_id = if (remainder.len == 0)
                        0
                    else
                        reservedWordSetIdForStep(remainder[0], reserved_word_context_names);
                    var nullable_ancestor_suffix_follow = try if (remainder.len == 0)
                        cloneSymbolSet(allocator, infos[entry.non_terminal].?.direct_suffix_follow)
                    else
                        initEmptySymbolSet(allocator, first_sets.terminals_len, first_sets.externals_len);
                    var nullable_ancestor_reserved_word_set_id: u16 = if (remainder.len == 0)
                        infos[entry.non_terminal].?.direct_suffix_reserved_word_set_id
                    else
                        0;
                    if (remainder.len == 0) {
                        _ = mergeSymbolSetLookaheads(
                            &nullable_ancestor_suffix_follow,
                            infos[entry.non_terminal].?.nullable_ancestor_suffix_follow,
                        );
                        nullable_ancestor_reserved_word_set_id = @max(
                            nullable_ancestor_reserved_word_set_id,
                            infos[entry.non_terminal].?.nullable_ancestor_reserved_word_set_id,
                        );
                        if (infos[entry.non_terminal].?.propagatesInheritedContext()) {
                            nullable_ancestor_suffix_follow.includes_epsilon = true;
                        }
                    } else if (direct_suffix_follow.includes_epsilon) {
                        direct_suffix_follow.includes_epsilon = false;
                        _ = mergeSymbolSetLookaheads(
                            &nullable_ancestor_suffix_follow,
                            infos[entry.non_terminal].?.direct_suffix_follow,
                        );
                        _ = mergeSymbolSetLookaheads(
                            &nullable_ancestor_suffix_follow,
                            infos[entry.non_terminal].?.nullable_ancestor_suffix_follow,
                        );
                        nullable_ancestor_reserved_word_set_id = @max(
                            infos[entry.non_terminal].?.direct_suffix_reserved_word_set_id,
                            infos[entry.non_terminal].?.nullable_ancestor_reserved_word_set_id,
                        );
                    }
                    try stack.append(.{
                        .non_terminal = next_non_terminal,
                        .direct_suffix_follow = direct_suffix_follow,
                        .nullable_ancestor_suffix_follow = nullable_ancestor_suffix_follow,
                        .direct_suffix_reserved_word_set_id = direct_suffix_reserved_word_set_id,
                        .nullable_ancestor_reserved_word_set_id = nullable_ancestor_reserved_word_set_id,
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
                    .direct_suffix_follow = try cloneSymbolSet(allocator, info.direct_suffix_follow),
                    .nullable_ancestor_suffix_follow = try cloneSymbolSet(allocator, info.nullable_ancestor_suffix_follow),
                    .direct_suffix_reserved_word_set_id = info.direct_suffix_reserved_word_set_id,
                    .nullable_ancestor_reserved_word_set_id = info.nullable_ancestor_reserved_word_set_id,
                },
            });
        }
    }

    return try additions.toOwnedSlice();
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
            addition.production_id,
            addition.info.direct_suffix_follow,
            addition.info.nullable_ancestor_suffix_follow,
            addition.info.direct_suffix_reserved_word_set_id,
            addition.info.nullable_ancestor_reserved_word_set_id,
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
    production_id: item.ProductionId,
    direct_suffix_follow: first.SymbolSet,
    nullable_ancestor_suffix_follow: first.SymbolSet,
    direct_suffix_reserved_word_set_id: u16,
    nullable_ancestor_reserved_word_set_id: u16,
    context: ClosureContext,
    first_sets: first.FirstSets,
    word_token: ?syntax_ir.SymbolRef,
    options: BuildOptions,
) !void {
    var effective_suffix_follow = try cloneSymbolSet(allocator, direct_suffix_follow);
    defer freeSymbolSet(allocator, effective_suffix_follow);
    _ = mergeSymbolSetLookaheads(&effective_suffix_follow, nullable_ancestor_suffix_follow);

    if (options.closure_lookahead_mode == .none) {
        const has_any_signal = nullable_ancestor_suffix_follow.includes_epsilon or
            effective_suffix_follow.includes_end or
            countPresent(effective_suffix_follow.terminals) > 0 or
            countPresent(effective_suffix_follow.externals) > 0;
        if (has_any_signal) {
            try appendOrMergeClosureEntry(
                allocator,
                generated,
                item_indexes,
                try item.ParseItemSetEntry.initEmpty(
                    allocator,
                    first_sets.terminals_len,
                    first_sets.externals_len,
                    item.ParseItem.init(production_id, 0),
                ),
                true,
            );
        }
        return;
    }

    var generated_entry = try item.ParseItemSetEntry.initEmpty(
        allocator,
        first_sets.terminals_len,
        first_sets.externals_len,
        item.ParseItem.init(production_id, 0),
    );
    var has_any_signal = nullable_ancestor_suffix_follow.includes_epsilon or effective_suffix_follow.includes_end;

    if (effective_suffix_follow.includes_end) {
        item.addLookahead(&generated_entry.lookaheads, .{ .end = {} });
    }

    var effective_terminal_iter = effective_suffix_follow.terminals.bits.iterator(.{});
    while (effective_terminal_iter.next()) |index| {
        item.addLookahead(&generated_entry.lookaheads, .{ .terminal = @intCast(index) });
        has_any_signal = true;
    }

    var effective_external_iter = effective_suffix_follow.externals.bits.iterator(.{});
    while (effective_external_iter.next()) |index| {
        item.addLookahead(&generated_entry.lookaheads, .{ .external = @intCast(index) });
        has_any_signal = true;
    }

    if (nullable_ancestor_suffix_follow.includes_epsilon) {
        if (context.production_end_follow.includes_end and !item.containsLookahead(generated_entry.lookaheads, .{ .end = {} })) {
            item.addLookahead(&generated_entry.lookaheads, .{ .end = {} });
        }
        var production_terminal_iter = context.production_end_follow.terminals.bits.iterator(.{});
        while (production_terminal_iter.next()) |index| {
            const lookahead: syntax_ir.SymbolRef = .{ .terminal = @intCast(index) };
            if (!item.containsLookahead(generated_entry.lookaheads, lookahead)) item.addLookahead(&generated_entry.lookaheads, lookahead);
        }
        var production_external_iter = context.production_end_follow.externals.bits.iterator(.{});
        while (production_external_iter.next()) |index| {
            const lookahead: syntax_ir.SymbolRef = .{ .external = @intCast(index) };
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
            if (item.containsLookahead(effective_suffix_follow, token)) {
                generated_entry.following_reserved_word_set_id = @max(
                    generated_entry.following_reserved_word_set_id,
                    @max(direct_suffix_reserved_word_set_id, nullable_ancestor_reserved_word_set_id),
                );
            }
            if (nullable_ancestor_suffix_follow.includes_epsilon and item.containsLookahead(context.production_end_follow, token)) {
                generated_entry.following_reserved_word_set_id = @max(
                    generated_entry.following_reserved_word_set_id,
                    context.production_end_reserved_word_set_id,
                );
            }
        }
    }

    if (!has_any_signal) {
        freeSymbolSet(allocator, generated_entry.lookaheads);
        return;
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

pub const BuildOptions = struct {
    closure_lookahead_mode: ClosureLookaheadMode = .full,
    closure_pressure_mode: ClosurePressureMode = .none,
    closure_pressure_thresholds: ClosurePressureThresholds = .{},
    coarse_transitions: []const CoarseTransitionSpec = &.{},
    reserved_word_context_names: []const []const u8 = &.{},
    non_terminal_extra_symbols: []const syntax_ir.SymbolRef = &.{},
    minimize_states: bool = false,
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
    return options.closure_pressure_mode == .none and options.coarse_transitions.len == 0;
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
    const context_name = step.reserved_context_name orelse return 0;
    const index = reservedContextIndex(names, context_name) orelse return 0;
    return @intCast(@min(index + 1, std.math.maxInt(u16)));
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
};

pub const BuildResult = struct {
    productions: []const ProductionInfo,
    precedence_orderings: []const []const syntax_ir.PrecedenceEntry,
    states: []const state.ParseState,
    lex_state_count: usize,
    lex_state_terminal_sets: []const []const bool = &.{},
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

fn assignLexStateIdsAlloc(
    allocator: std.mem.Allocator,
    parse_states: []const state.ParseState,
    resolved_actions: resolution.ResolvedActionTable,
) std.mem.Allocator.Error!AssignedLexStates {
    if (parse_states.len == 0) {
        return .{
            .states = &.{},
            .count = 0,
            .terminal_sets = &.{},
        };
    }

    const terminal_count = terminalCountForResolvedActions(resolved_actions);
    const assigned_states = try allocator.dupe(state.ParseState, parse_states);
    errdefer allocator.free(assigned_states);
    var terminal_sets = std.array_list.Managed([]const bool).init(allocator);
    errdefer {
        for (terminal_sets.items) |terminal_set| allocator.free(terminal_set);
        terminal_sets.deinit();
    }
    var lex_state_ids = LexStateIdByTerminalSet.init(allocator);
    defer {
        lex_state_ids.deinit();
    }

    var next_id: state.LexStateId = 0;
    for (assigned_states) |*parse_state| {
        const terminal_set = try allocator.alloc(bool, terminal_count);
        @memset(terminal_set, false);
        errdefer allocator.free(terminal_set);

        for (resolved_actions.groupsForState(parse_state.id)) |group| {
            switch (group.symbol) {
                .terminal => |index| terminal_set[index] = true,
                .end, .non_terminal, .external => {},
            }
        }

        const gop = try lex_state_ids.getOrPut(terminal_set);
        if (gop.found_existing) {
            allocator.free(terminal_set);
            parse_state.lex_state_id = gop.value_ptr.*;
            continue;
        }

        gop.key_ptr.* = terminal_set;
        gop.value_ptr.* = next_id;
        try terminal_sets.append(terminal_set);
        parse_state.lex_state_id = next_id;
        next_id += 1;
    }

    return .{
        .states = assigned_states,
        .count = next_id,
        .terminal_sets = try terminal_sets.toOwnedSlice(),
    };
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
    const build_profile_timer = profileTimer(profile_log);
    if (profile_log) {
        item.resetSymbolSetProfile();
        item.setSymbolSetProfileEnabled(true);
        resetConstructProfile();
        construct_profile_enabled = true;
    }
    defer if (profile_log) {
        logProfileDone("build_states_total", build_profile_timer);
        logSymbolSetProfile();
        logConstructProfile();
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
    var item_set_builder = try ParseItemSetBuilder.init(allocator, productions, first_sets, reserved_word_context_names, grammar.word_token);
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
            .{ constructed.states.len, constructed.actions.states.len },
        );
    }

    timer = maybeStartTimer(progress_log);
    stage_profile_timer = profileTimer(profile_log);
    if (progress_log) std.debug.print("[parse_table/build] stage group_action_table\n", .{});
    if (progress_log) logBuildStart("group_action_table");
    const grouped_actions = try actions.groupActionTable(allocator, constructed.actions);
    logProfileDone("group_action_table", stage_profile_timer);
    if (progress_log) maybeLogBuildDone("group_action_table", timer);

    timer = maybeStartTimer(progress_log);
    stage_profile_timer = profileTimer(profile_log);
    if (progress_log) std.debug.print("[parse_table/build] stage resolve_action_table\n", .{});
    if (progress_log) logBuildStart("resolve_action_table");
    const resolved_actions = try resolution.resolveActionTableWithFirstSetsContext(
        allocator,
        productions,
        grammar.precedence_orderings,
        grammar.expected_conflicts,
        constructed.states,
        first_sets,
        grouped_actions,
    );
    logProfileDone("resolve_action_table", stage_profile_timer);
    if (progress_log) {
        maybeLogBuildDone("resolve_action_table", timer);
        logBuildSummary(
            "resolve_action_table summary unresolved_decisions={} serialization_ready={}",
            .{ resolved_actions.hasUnresolvedDecisions(), resolved_actions.isSerializationReady() },
        );
    }
    stage_profile_timer = profileTimer(profile_log);
    const lex_states = try assignLexStateIdsAlloc(allocator, constructed.states, resolved_actions);
    logProfileDone("assign_lex_state_ids", stage_profile_timer);

    if (options.minimize_states) {
        timer = maybeStartTimer(progress_log);
        stage_profile_timer = profileTimer(profile_log);
        if (progress_log) logBuildStart("minimize_states");
        const minimized = try minimize.minimizeAlloc(allocator, lex_states.states, resolved_actions);
        logProfileDone("minimize_states", stage_profile_timer);
        if (progress_log) {
            maybeLogBuildDone("minimize_states", timer);
            logBuildSummary(
                "minimize_states summary states_before={d} states_after={d} merged={d}",
                .{ lex_states.states.len, minimized.states.len, minimized.merged_count },
            );
        }
        return .{
            .productions = productions,
            .precedence_orderings = grammar.precedence_orderings,
            .states = minimized.states,
            .lex_state_count = lex_states.count,
            .lex_state_terminal_sets = lex_states.terminal_sets,
            .actions = constructed.actions,
            .resolved_actions = minimized.resolved_actions,
        };
    }

    return .{
        .productions = productions,
        .precedence_orderings = grammar.precedence_orderings,
        .states = lex_states.states,
        .lex_state_count = lex_states.count,
        .lex_state_terminal_sets = lex_states.terminal_sets,
        .actions = constructed.actions,
        .resolved_actions = resolved_actions,
    };
}

const ConstructedStates = struct {
    states: []const state.ParseState,
    actions: actions.ActionTable,
};

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
            .core_ids_by_core = CoreIdByItemSetCore.init(allocator),
            .core_key_store = CoreKeyStore.init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        self.core_key_store.deinit();
        self.core_ids_by_core.deinit();
        self.state_ids_by_item_set.deinit();
        self.states.deinit();
    }

    fn items(self: *@This()) []state.ParseState {
        return self.states.items;
    }

    fn appendInitialState(self: *@This(), item_set: item.ParseItemSet) !void {
        const core_id = try self.core_key_store.internFromEntries(&self.core_ids_by_core, item_set.entries);
        try self.states.append(.{
            .id = 0,
            .core_id = @intCast(core_id),
            .items = item_set.entries,
            .transitions = &.{},
            .conflicts = &.{},
        });
        try self.state_ids_by_item_set.put(item_set, 0);
    }

    fn intern(self: *@This(), item_set: item.ParseItemSet) !InternResult {
        if (construct_profile_enabled) construct_profile.state_intern_calls += 1;
        if (self.state_ids_by_item_set.get(item_set)) |existing_id| {
            if (construct_profile_enabled) construct_profile.state_intern_reused += 1;
            return .{
                .state_id = existing_id,
                .reused = true,
            };
        }

        const new_id: state.StateId = @intCast(self.states.items.len);
        const core_id = try self.core_key_store.internFromEntries(&self.core_ids_by_core, item_set.entries);
        try self.states.append(.{
            .id = new_id,
            .core_id = @intCast(core_id),
            .items = item_set.entries,
            .transitions = &.{},
            .conflicts = &.{},
        });
        try self.state_ids_by_item_set.put(item_set, new_id);
        if (construct_profile_enabled) {
            construct_profile.state_intern_new += 1;
            construct_profile.state_items_stored += item_set.entries.len;
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
    item_set_builder: ParseItemSetBuilder,
    closure_expansion_cache: *ClosureExpansionCache,
    successor_seed_state_cache: *SuccessorSeedStateCache,
    state_registry: *StateRegistry,
    action_states: *std.array_list.Managed(actions.StateActions),
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
        const reserved_timer = profileTimer(construct_profile_enabled);
        mutable_states[state_index].reserved_word_set_id = reservedWordSetIdForParseState(
            mutable_states[state_index],
            self.productions,
            self.item_set_builder.word_token,
            self.item_set_builder.reserved_word_context_names,
        );
        addProfileDuration(&construct_profile.reserved_word_ns, reserved_timer);

        const actions_timer = profileTimer(construct_profile_enabled);
        const state_actions = try actions.buildActionsForState(
            self.allocator,
            self.productions,
            mutable_states[state_index],
        );
        addProfileDuration(&construct_profile.build_actions_ns, actions_timer);
        const conflicts_timer = profileTimer(construct_profile_enabled);
        const detected_conflicts = try conflicts.detectConflictsFromActions(
            self.allocator,
            mutable_states[state_index],
            state_actions,
        );
        addProfileDuration(&construct_profile.detect_conflicts_ns, conflicts_timer);
        mutable_states[state_index].conflicts = detected_conflicts;
        try self.action_states.append(.{
            .state_id = mutable_states[state_index].id,
            .entries = state_actions,
        });

        reporter.logStateDone(
            state_index,
            mutable_states[state_index],
            state_actions.len,
            self.state_registry.items().len,
            detected_conflicts.len,
            transition_stats,
        );
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
        try successor_groups.buildFromStateItems(state_items, self.productions);
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
            const interned = try self.state_registry.intern(advanced_item_set);
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
    keys: std.array_list.Managed(item.ParseItemSet),

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .state_ids_by_seed = StateIdByItemSet.init(allocator),
            .keys = std.array_list.Managed(item.ParseItemSet).init(allocator),
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
        if (self.state_ids_by_seed.get(.{ .entries = seed_items })) |state_id| {
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
        const key = item.ParseItemSet{ .entries = seed_copy };
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
        _ = try appendGeneratedItemsToClosure(self.allocator, &self.items, &self.item_indexes, seed_items, false);
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
                const suffix_first = try self.item_set_builder.first_sets.firstOfSequence(self.allocator, suffix);
                const suffix_reserved_word_set_id = if (suffix.len == 0)
                    0
                else
                    reservedWordSetIdForStep(suffix[0], self.item_set_builder.reserved_word_context_names);
                const context = try ClosureContext.init(
                    self.allocator,
                    suffix_first,
                    suffix_reserved_word_set_id,
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
            });
        }
    }

    return try productions.toOwnedSlice();
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null);
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
                try std.testing.expect(addition.info.propagatesInheritedContext());
                try std.testing.expect(addition.info.needsProductionEndFollow());
                try std.testing.expect(!addition.info.direct_suffix_follow.containsTerminal(2));
                try std.testing.expect(!addition.info.nullable_ancestor_suffix_follow.containsTerminal(2));
            },
            3 => {
                saw_a_to_d = true;
                try std.testing.expect(addition.info.propagatesInheritedContext());
                try std.testing.expect(addition.info.needsProductionEndFollow());
                try std.testing.expect(!addition.info.direct_suffix_follow.containsTerminal(2));
                try std.testing.expect(!addition.info.nullable_ancestor_suffix_follow.containsTerminal(2));
            },
            4 => {
                saw_b_to_e = true;
                try std.testing.expect(!addition.info.propagatesInheritedContext());
                try std.testing.expect(!addition.info.needsProductionEndFollow());
                try std.testing.expect(addition.info.direct_suffix_follow.containsTerminal(2));
                try std.testing.expect(!addition.info.nullable_ancestor_suffix_follow.containsTerminal(2));
            },
            else => return error.UnexpectedProductionId,
        }
    }

    try std.testing.expect(saw_a_to_b_c);
    try std.testing.expect(saw_a_to_d);
    try std.testing.expect(saw_b_to_e);
}

test "ParseItemSetBuilder distinguishes direct suffix follow from nullable ancestor suffix follow" {
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null);
    defer item_set_builder.deinit();

    const additions = item_set_builder.additionsForNonTerminal(1);

    var saw_b_production = false;
    var saw_d_production = false;
    for (additions) |addition| {
        switch (addition.production_id) {
            3 => {
                saw_b_production = true;
                try std.testing.expect(addition.info.direct_suffix_follow.containsTerminal(2));
                try std.testing.expect(!addition.info.nullable_ancestor_suffix_follow.containsTerminal(2));
                try std.testing.expect(addition.info.propagatesInheritedContext());
                try std.testing.expect(addition.info.needsProductionEndFollow());
            },
            6 => {
                saw_d_production = true;
                try std.testing.expect(!addition.info.direct_suffix_follow.containsTerminal(2));
                try std.testing.expect(addition.info.nullable_ancestor_suffix_follow.containsTerminal(2));
                try std.testing.expect(addition.info.propagatesInheritedContext());
                try std.testing.expect(addition.info.needsProductionEndFollow());
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null);
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null);
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
    var item_set_builder = try ParseItemSetBuilder.init(arena.allocator(), productions, first_sets, &.{}, null);
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

    try std.testing.expect(findParseItem(items, item.ParseItem.init(4, 0), .{ .terminal = 1 }) != null);
}

test "closureContextFollowSet merges inherited lookahead only through nullable suffixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var inherited = try initEmptySymbolSet(arena.allocator(), 3, 0);
    inherited.terminals.set(2);
    var suffix = try initEmptySymbolSet(arena.allocator(), 3, 0);
    suffix.terminals.set(1);
    suffix.includes_epsilon = true;

    const merged = try closureContextFollowSet(arena.allocator(), suffix, inherited);
    try std.testing.expect(merged.terminals.get(1));
    try std.testing.expect(merged.terminals.get(2));
    try std.testing.expect(merged.includes_epsilon);

    var non_nullable = try initEmptySymbolSet(arena.allocator(), 3, 0);
    non_nullable.terminals.set(1);
    const unchanged = try closureContextFollowSet(arena.allocator(), non_nullable, inherited);
    try std.testing.expect(unchanged.terminals.get(1));
    try std.testing.expect(!unchanged.terminals.get(2));
    try std.testing.expect(!unchanged.includes_epsilon);
}

test "ClosureContext projects nullable-suffix follow from merged follow and production-end follow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var inherited = try initEmptySymbolSet(arena.allocator(), 3, 0);
    inherited.terminals.set(2);
    var suffix = try initEmptySymbolSet(arena.allocator(), 3, 0);
    suffix.terminals.set(1);
    suffix.includes_epsilon = true;

    const context = try ClosureContext.init(arena.allocator(), suffix, 0, inherited, 0);
    defer context.deinit(arena.allocator());

    try std.testing.expect(context.following_tokens.terminals.get(1));
    try std.testing.expect(context.following_tokens.terminals.get(2));
    try std.testing.expect(context.nullableSuffixNeedsContextFollow());
    try std.testing.expect(context.production_end_follow.terminals.get(2));
    try std.testing.expect(!context.production_end_follow.terminals.get(1));

    var non_nullable = try initEmptySymbolSet(arena.allocator(), 3, 0);
    non_nullable.terminals.set(1);
    const non_nullable_context = try ClosureContext.init(arena.allocator(), non_nullable, 0, inherited, 0);
    defer non_nullable_context.deinit(arena.allocator());

    try std.testing.expect(non_nullable_context.following_tokens.terminals.get(1));
    try std.testing.expect(!non_nullable_context.following_tokens.terminals.get(2));
    try std.testing.expect(!non_nullable_context.nullableSuffixNeedsContextFollow());
    try std.testing.expect(non_nullable_context.production_end_follow.terminals.get(2));
}

fn findParseItem(items: []const item.ParseItemSetEntry, needle: item.ParseItem, lookahead: syntax_ir.SymbolRef) ?usize {
    for (items, 0..) |candidate, index| {
        if (item.ParseItem.eql(candidate.item, needle) and item.containsLookahead(candidate.lookaheads, lookahead)) return index;
    }
    return null;
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
                item.ParseItem.init(@intCast(production_id), 1),
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
        const interned = try state_registry.intern(item_set);
        starts[index] = .{
            .symbol = group.symbol,
            .state_id = interned.state_id,
        };
    }
    return starts;
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
    productions: []const ProductionInfo,
    first_sets: first.FirstSets,
    item_set_builder: ParseItemSetBuilder,
    options: BuildOptions,
) BuildError!ConstructedStates {
    var reporter = ConstructStatesReporter.init(variables);
    reporter.logEnter();
    var state_registry = StateRegistry.init(allocator);
    defer state_registry.deinit();
    var action_states = std.array_list.Managed(actions.StateActions).init(allocator);
    defer action_states.deinit();
    var largest_new_successor: ?SuccessorDiagnostic = null;
    var largest_reused_successor: ?SuccessorDiagnostic = null;

    const start_timer = reporter.startInitialClosure();
    const start_seed = [_]item.ParseItemSetEntry{
        blk: {
            var entry = try item.ParseItemSetEntry.initEmpty(
                allocator,
                first_sets.terminals_len,
                first_sets.externals_len,
                item.ParseItem.init(0, 0),
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
    try state_registry.appendInitialState(start_item_set);
    var closure_expansion_cache = ClosureExpansionCache.init(allocator);
    defer closure_expansion_cache.deinit();
    var successor_seed_state_cache = SuccessorSeedStateCache.init(allocator);
    defer successor_seed_state_cache.deinit();
    const non_terminal_extra_starts = try addNonTerminalExtraStatesAlloc(
        allocator,
        variables,
        productions,
        first_sets,
        item_set_builder,
        options,
        &state_registry,
    );

    var state_engine = StateConstructionEngine{
        .allocator = allocator,
        .variables = variables,
        .productions = productions,
        .first_sets = first_sets,
        .item_set_builder = item_set_builder,
        .closure_expansion_cache = &closure_expansion_cache,
        .successor_seed_state_cache = &successor_seed_state_cache,
        .state_registry = &state_registry,
        .action_states = &action_states,
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
        .actions = .{
            .states = try action_states.toOwnedSlice(),
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
    try std.testing.expect(result.actions.entriesForState(0).len > 0);
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
    try std.testing.expectEqual(@as(usize, 4), result.states.len);
    try std.testing.expectEqual(@as(state.StateId, 0), result.states[0].id);
    try std.testing.expectEqual(@as(usize, 3), result.states[0].items.len);
    try std.testing.expectEqual(@as(usize, 3), result.states[0].transitions.len);
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

    try std.testing.expect(findParseItem(result.states[0].items, item.ParseItem.init(0, 0), .{ .end = {} }) != null);

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

    try std.testing.expectEqual(@as(u16, 1), result.states[0].reserved_word_set_id);
}

test "buildStates propagates following reserved-word set through nullable closure lookahead" {
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

    var saw_propagated = false;
    for (result.states[0].items) |entry| {
        if (entry.item.production_id == 3 and
            item.containsLookahead(entry.lookaheads, .{ .terminal = 0 }) and
            entry.following_reserved_word_set_id == 1)
        {
            saw_propagated = true;
        }
    }

    try std.testing.expect(saw_propagated);
}

test "buildStates keeps named-precedence reductions on the suffix symbol, not the inherited terminal" {
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

    var saw_reduce_on_suffix_symbol = false;
    var saw_reduce_on_inherited_terminal = false;
    for (result.resolved_actions.states) |resolved_state| {
        for (resolved_state.groups) |group| {
            const chosen = group.chosenAction() orelse continue;
            switch (chosen) {
                .reduce => {
                    if (symbolRefEql(group.symbol, .{ .terminal = 1 })) saw_reduce_on_suffix_symbol = true;
                    if (symbolRefEql(group.symbol, .{ .terminal = 0 })) saw_reduce_on_inherited_terminal = true;
                },
                else => {},
            }
        }
    }

    try std.testing.expect(saw_reduce_on_suffix_symbol);
    try std.testing.expect(!saw_reduce_on_inherited_terminal);
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

    const assigned = try assignLexStateIdsAlloc(allocator, parse_states[0..], resolved_actions);
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

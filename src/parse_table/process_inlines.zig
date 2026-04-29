const std = @import("std");
const syntax_ir = @import("../ir/syntax_grammar.zig");

/// A Production augmented by inlining: same fields as build.ProductionInfo but defined
/// here to avoid a circular dependency.  build.zig imports this via InlinedProductionMap.
pub const InlinedProduction = struct {
    lhs: u32,
    lhs_kind: syntax_ir.VariableKind = .named,
    steps: []const syntax_ir.ProductionStep,
    lhs_is_repeat_auxiliary: bool = false,
    augmented: bool = false,
    dynamic_precedence: i32 = 0,

    fn eql(self: InlinedProduction, other: InlinedProduction) bool {
        if (self.lhs != other.lhs) return false;
        if (self.dynamic_precedence != other.dynamic_precedence) return false;
        if (self.steps.len != other.steps.len) return false;
        for (self.steps, other.steps) |a, b| {
            if (!productionStepEql(a, b)) return false;
        }
        return true;
    }
};

fn productionStepEql(a: syntax_ir.ProductionStep, b: syntax_ir.ProductionStep) bool {
    if (!symbolRefEql(a.symbol, b.symbol)) return false;
    if (a.field_name == null) {
        if (b.field_name != null) return false;
    } else {
        if (b.field_name == null) return false;
        if (!std.mem.eql(u8, a.field_name.?, b.field_name.?)) return false;
    }
    return true;
}

fn symbolRefEql(a: syntax_ir.SymbolRef, b: syntax_ir.SymbolRef) bool {
    return switch (a) {
        .end => b == .end,
        .non_terminal => |i| switch (b) {
            .non_terminal => |j| i == j,
            else => false,
        },
        .terminal => |i| switch (b) {
            .terminal => |j| i == j,
            else => false,
        },
        .external => |i| switch (b) {
            .external => |j| i == j,
            else => false,
        },
    };
}

/// Maps (production_id, step_index) → []production_id where the inline variable at that
/// step has been substituted with each of its alternatives.  Production IDs in both keys
/// and values index into the COMBINED list: original_count + extra_productions.
pub const InlinedProductionMap = struct {
    const Key = struct {
        production_id: u32,
        step_index: u16,
    };

    const KeyContext = struct {
        pub fn hash(_: @This(), k: Key) u64 {
            return @as(u64, k.production_id) *% 2654435761 +% k.step_index;
        }
        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return a.production_id == b.production_id and a.step_index == b.step_index;
        }
    };

    allocator: std.mem.Allocator,
    original_count: u32,
    extra_productions: []const InlinedProduction,
    /// Owned step slices for each extra production (parallel to extra_productions).
    extra_steps_storage: []const []const syntax_ir.ProductionStep,
    map: std.HashMap(Key, []const u32, KeyContext, std.hash_map.default_max_load_percentage),

    /// Returns the list of production IDs (in combined list) that result from inlining
    /// the inline variable at step_index in production_id.  Returns null if no inline
    /// variable sits at that position.
    pub fn inlinedProductions(self: @This(), production_id: u32, step_index: u16) ?[]const u32 {
        return self.map.get(.{ .production_id = production_id, .step_index = step_index });
    }

    pub fn deinit(self: *@This()) void {
        var it = self.map.valueIterator();
        while (it.next()) |ids| self.allocator.free(ids.*);
        self.map.deinit();
        for (self.extra_steps_storage) |steps| self.allocator.free(steps);
        self.allocator.free(self.extra_steps_storage);
        self.allocator.free(self.extra_productions);
    }
};

/// Build context that accumulates extra productions and the expansion map.
const Builder = struct {
    allocator: std.mem.Allocator,
    variables: []const syntax_ir.SyntaxVariable,
    variables_to_inline: []const syntax_ir.SymbolRef,

    /// All original productions (reference, not owned).
    original: []const InlinedProduction,
    /// Extra (inlined) productions accumulated so far.
    extra: std.array_list.Managed(InlinedProduction),
    /// Owned step slices for each extra production (parallel to extra).
    extra_steps: std.array_list.Managed([]const syntax_ir.ProductionStep),

    map: std.HashMap(InlinedProductionMap.Key, std.array_list.Managed(u32), InlinedProductionMap.KeyContext, std.hash_map.default_max_load_percentage),

    fn init(
        allocator: std.mem.Allocator,
        original: []const InlinedProduction,
        variables: []const syntax_ir.SyntaxVariable,
        variables_to_inline: []const syntax_ir.SymbolRef,
    ) @This() {
        return .{
            .allocator = allocator,
            .variables = variables,
            .variables_to_inline = variables_to_inline,
            .original = original,
            .extra = std.array_list.Managed(InlinedProduction).init(allocator),
            .extra_steps = std.array_list.Managed([]const syntax_ir.ProductionStep).init(allocator),
            .map = std.HashMap(InlinedProductionMap.Key, std.array_list.Managed(u32), InlinedProductionMap.KeyContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit();
        self.map.deinit();
        for (self.extra_steps.items) |steps| self.allocator.free(steps);
        self.extra_steps.deinit();
        self.extra.deinit();
    }

    fn isInline(self: @This(), symbol: syntax_ir.SymbolRef) bool {
        const idx = switch (symbol) {
            .non_terminal => |i| i,
            else => return false,
        };
        for (self.variables_to_inline) |v| {
            switch (v) {
                .non_terminal => |vi| if (vi == idx) return true,
                else => {},
            }
        }
        return false;
    }

    /// Returns the step at (production_id, step_index) in the combined list,
    /// or null if out of range or augmented.
    fn stepAt(self: @This(), production_id: u32, step_index: u16) ?syntax_ir.ProductionStep {
        const prod = self.productionAt(production_id) orelse return null;
        if (prod.augmented) return null;
        if (step_index >= prod.steps.len) return null;
        return prod.steps[step_index];
    }

    fn productionAt(self: @This(), production_id: u32) ?InlinedProduction {
        const orig_len: u32 = @intCast(self.original.len);
        if (production_id < orig_len) return self.original[production_id];
        const extra_id = production_id - orig_len;
        if (extra_id < self.extra.items.len) return self.extra.items[extra_id];
        return null;
    }

    /// Find or create an extra production equal to `candidate`.  Returns its combined ID.
    fn internExtra(self: *@This(), candidate: InlinedProduction, owned_steps: []const syntax_ir.ProductionStep) !u32 {
        const orig_len: u32 = @intCast(self.original.len);
        // Check original productions first.
        for (self.original, 0..) |p, i| {
            if (p.eql(candidate)) {
                self.allocator.free(owned_steps);
                return @intCast(i);
            }
        }
        // Check existing extra productions.
        for (self.extra.items, 0..) |p, i| {
            if (p.eql(candidate)) {
                self.allocator.free(owned_steps);
                return orig_len + @as(u32, @intCast(i));
            }
        }
        // New extra production.
        const new_id = orig_len + @as(u32, @intCast(self.extra.items.len));
        try self.extra.append(candidate);
        try self.extra_steps.append(owned_steps);
        return new_id;
    }

    /// Record mapping (production_id, step_index) → result_id.
    fn recordExpansion(self: *@This(), key: InlinedProductionMap.Key, result_id: u32) !void {
        const result = try self.map.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = std.array_list.Managed(u32).init(self.allocator);
        }
        // Avoid duplicates in result list.
        for (result.value_ptr.items) |existing| {
            if (existing == result_id) return;
        }
        try result.value_ptr.append(result_id);
    }

    /// Create the inlined alternative of `source_prod` where the inline variable at
    /// `step_index` is replaced by `inline_alt` (one production of the inline variable).
    /// Returns the combined production ID of the result.
    fn inlineOneAlternative(
        self: *@This(),
        source_prod_id: u32,
        step_index: u16,
        inline_alt: syntax_ir.Production,
    ) !u32 {
        const source_prod = self.productionAt(source_prod_id).?;
        const removed_step = source_prod.steps[step_index];

        // Build the new step slice: source[0..step] ++ inline_alt.steps ++ source[step+1..]
        const prefix_len = step_index;
        const alt_len: u32 = @intCast(inline_alt.steps.len);
        const suffix_start = step_index + 1;
        const suffix_len: u32 = @intCast(source_prod.steps.len - suffix_start);
        const new_len = prefix_len + alt_len + suffix_len;

        const owned_steps = try self.allocator.alloc(syntax_ir.ProductionStep, new_len);
        errdefer self.allocator.free(owned_steps);

        // Prefix steps (unchanged).
        @memcpy(owned_steps[0..prefix_len], source_prod.steps[0..prefix_len]);

        // Inline alternative steps with metadata propagation.
        for (inline_alt.steps, 0..) |alt_step, i| {
            var new_step = alt_step;
            // Propagate alias from the removed step to all inserted steps.
            if (removed_step.alias != null and new_step.alias == null) {
                new_step.alias = removed_step.alias;
            }
            // Propagate field_name from removed step to all inserted steps.
            if (removed_step.field_name != null and new_step.field_name == null) {
                new_step.field_name = removed_step.field_name;
            }
            owned_steps[prefix_len + i] = new_step;
        }
        // On the last inserted step, inherit precedence/associativity from removed step
        // if the inserted step doesn't have its own.
        if (alt_len > 0) {
            const last_inserted = &owned_steps[prefix_len + alt_len - 1];
            if (last_inserted.precedence == .none) {
                last_inserted.precedence = removed_step.precedence;
            }
            if (last_inserted.associativity == .none) {
                last_inserted.associativity = removed_step.associativity;
            }
        }

        // Suffix steps (unchanged).
        @memcpy(owned_steps[prefix_len + alt_len ..], source_prod.steps[suffix_start..]);

        // Dynamic precedence: take the larger absolute value.
        var dyn_prec = source_prod.dynamic_precedence;
        if (@abs(inline_alt.dynamic_precedence) > @abs(dyn_prec)) {
            dyn_prec = inline_alt.dynamic_precedence;
        }

        const candidate = InlinedProduction{
            .lhs = source_prod.lhs,
            .lhs_kind = source_prod.lhs_kind,
            .steps = owned_steps,
            .lhs_is_repeat_auxiliary = source_prod.lhs_is_repeat_auxiliary,
            .augmented = false,
            .dynamic_precedence = dyn_prec,
        };

        return self.internExtra(candidate, owned_steps);
    }

    /// Process work queue starting from every original production.
    fn process(self: *@This()) !void {
        // Work item: (production_id, step_index) — we need to check this step for inline.
        const WorkItem = struct { production_id: u32, step_index: u16 };
        var queue = std.array_list.Managed(WorkItem).init(self.allocator);
        defer queue.deinit();

        // Seed with all original productions at step 0.
        for (0..self.original.len) |i| {
            const prod = self.original[i];
            if (prod.augmented or prod.steps.len == 0) continue;
            try queue.append(.{ .production_id = @intCast(i), .step_index = 0 });
        }

        var qi: usize = 0;
        while (qi < queue.items.len) {
            const work = queue.items[qi];
            qi += 1;

            const maybe_step = self.stepAt(work.production_id, work.step_index);
            const step = maybe_step orelse {
                // Past end or augmented: nothing to do.
                continue;
            };

            if (self.isInline(step.symbol)) {
                // The symbol at this step is an inline variable — substitute.
                const var_index = step.symbol.non_terminal;
                if (var_index >= self.variables.len) continue;
                const inline_var = self.variables[var_index];

                for (inline_var.productions) |alt| {
                    const new_id = try self.inlineOneAlternative(work.production_id, work.step_index, alt);
                    try self.recordExpansion(.{ .production_id = work.production_id, .step_index = work.step_index }, new_id);
                    // Queue the new production at the SAME step to handle nested inline.
                    try queue.append(.{ .production_id = new_id, .step_index = work.step_index });
                }
            } else {
                // Not inline — advance to next step.
                const next_step: u16 = work.step_index + 1;
                const prod = self.productionAt(work.production_id).?;
                if (next_step < prod.steps.len) {
                    try queue.append(.{ .production_id = work.production_id, .step_index = next_step });
                }
            }
        }
    }

    /// Consume the builder and produce the final InlinedProductionMap.
    fn build(self: *@This()) !InlinedProductionMap {
        try self.process();

        const extra_prods = try self.allocator.dupe(InlinedProduction, self.extra.items);
        errdefer self.allocator.free(extra_prods);

        // Remap step slices: extra_prods[i].steps must point to the owned slice stored in extra_steps.
        for (extra_prods, self.extra_steps.items) |*p, owned| {
            p.steps = owned;
        }

        const extra_steps_storage = try self.allocator.dupe([]const syntax_ir.ProductionStep, self.extra_steps.items);
        errdefer self.allocator.free(extra_steps_storage);

        // Transfer ownership of step slices to extra_steps_storage.
        // Clear the builder's copy so Builder.deinit() doesn't double-free them.
        self.extra_steps.clearRetainingCapacity();

        var final_map = std.HashMap(
            InlinedProductionMap.Key,
            []const u32,
            InlinedProductionMap.KeyContext,
            std.hash_map.default_max_load_percentage,
        ).init(self.allocator);
        errdefer {
            var it = final_map.valueIterator();
            while (it.next()) |ids| self.allocator.free(ids.*);
            final_map.deinit();
        }

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const owned_ids = try self.allocator.dupe(u32, entry.value_ptr.items);
            try final_map.put(entry.key_ptr.*, owned_ids);
        }

        return InlinedProductionMap{
            .allocator = self.allocator,
            .original_count = @intCast(self.original.len),
            .extra_productions = extra_prods,
            .extra_steps_storage = extra_steps_storage,
            .map = final_map,
        };
    }
};

/// Build an InlinedProductionMap from a slice of original productions (cast-compatible with
/// build.ProductionInfo) and the grammar's inline variable list.
///
/// The caller should append inline_map.extra_productions to the productions slice before
/// passing it to ParseItemSetBuilder so that production IDs stay consistent.
pub fn buildInlinedProductionMapAlloc(
    allocator: std.mem.Allocator,
    /// Original productions as []const InlinedProduction (cast from []const ProductionInfo).
    original_productions: []const InlinedProduction,
    variables_to_inline: []const syntax_ir.SymbolRef,
    variables: []const syntax_ir.SyntaxVariable,
) !InlinedProductionMap {
    if (variables_to_inline.len == 0) {
        // Fast path: nothing to inline.
        return InlinedProductionMap{
            .allocator = allocator,
            .original_count = @intCast(original_productions.len),
            .extra_productions = &.{},
            .extra_steps_storage = &.{},
            .map = std.HashMap(
                InlinedProductionMap.Key,
                []const u32,
                InlinedProductionMap.KeyContext,
                std.hash_map.default_max_load_percentage,
            ).init(allocator),
        };
    }

    var builder = Builder.init(allocator, original_productions, variables, variables_to_inline);
    defer builder.deinit();
    return try builder.build();
}

test "basic inline substitution: single alternative" {
    const allocator = std.testing.allocator;

    // Grammar: A → V B, V → x (inline)
    // Expected: inlinedProductions(A→VB, 0) = [A→xB]
    const v_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .terminal = 10 } }, // x
    };
    const a_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } }, // V
        .{ .symbol = .{ .terminal = 11 } },    // B
    };
    const original = [_]InlinedProduction{
        .{ .lhs = 0, .steps = &a_steps }, // P0: A → V B
        .{ .lhs = 1, .steps = &v_steps }, // P1: V → x
    };
    const variables = [_]syntax_ir.SyntaxVariable{
        .{ .name = "A", .kind = .named, .productions = &.{.{ .steps = @constCast(&a_steps) }} },
        .{ .name = "V", .kind = .hidden, .productions = &.{.{ .steps = @constCast(&v_steps) }} },
    };
    const variables_to_inline = [_]syntax_ir.SymbolRef{.{ .non_terminal = 1 }};

    var ipm = try buildInlinedProductionMapAlloc(allocator, &original, &variables_to_inline, &variables);
    defer ipm.deinit();

    // P0 at step 0 (V is inline): should produce one inlined production A→xB
    const expanded = ipm.inlinedProductions(0, 0).?;
    try std.testing.expectEqual(@as(usize, 1), expanded.len);

    // The inlined production should be A → x B
    const inlined_id = expanded[0];
    try std.testing.expect(inlined_id >= ipm.original_count); // it's an extra production
    const extra_idx = inlined_id - ipm.original_count;
    const inlined_prod = ipm.extra_productions[extra_idx];
    try std.testing.expectEqual(@as(u32, 0), inlined_prod.lhs); // lhs = A
    try std.testing.expectEqual(@as(usize, 2), inlined_prod.steps.len); // x, B
    try std.testing.expectEqual(@as(u32, 10), inlined_prod.steps[0].symbol.terminal); // x
    try std.testing.expectEqual(@as(u32, 11), inlined_prod.steps[1].symbol.terminal); // B
}

test "inline substitution: two alternatives" {
    const allocator = std.testing.allocator;

    // Grammar: A → V B, V → x | y (inline)
    const v1_steps = [_]syntax_ir.ProductionStep{.{ .symbol = .{ .terminal = 10 } }};
    const v2_steps = [_]syntax_ir.ProductionStep{.{ .symbol = .{ .terminal = 11 } }};
    const a_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } },
        .{ .symbol = .{ .terminal = 12 } },
    };
    const original = [_]InlinedProduction{
        .{ .lhs = 0, .steps = &a_steps },
        .{ .lhs = 1, .steps = &v1_steps },
        .{ .lhs = 1, .steps = &v2_steps },
    };
    const variables = [_]syntax_ir.SyntaxVariable{
        .{ .name = "A", .kind = .named, .productions = &.{.{ .steps = @constCast(&a_steps) }} },
        .{
            .name = "V",
            .kind = .hidden,
            .productions = &.{
                .{ .steps = @constCast(&v1_steps) },
                .{ .steps = @constCast(&v2_steps) },
            },
        },
    };
    const variables_to_inline = [_]syntax_ir.SymbolRef{.{ .non_terminal = 1 }};

    var ipm = try buildInlinedProductionMapAlloc(allocator, &original, &variables_to_inline, &variables);
    defer ipm.deinit();

    const expanded = ipm.inlinedProductions(0, 0).?;
    try std.testing.expectEqual(@as(usize, 2), expanded.len);

    // No inline at step 1 (terminal) in either extra production.
    for (expanded) |id| {
        try std.testing.expectEqual(@as(?[]const u32, null), ipm.inlinedProductions(id, 1));
    }
}

test "nested inline substitution" {
    const allocator = std.testing.allocator;

    // Grammar: A → V W, V → x (inline), W → a (inline)
    // P0: A → V W
    // P1: V → x
    // P2: W → a
    // Expected: inline map at (P0, 0) = [P3: A→xW], at (P0, 1) = [P4: A→Va]
    // And for P3: at (P3, 1) = [P5: A→xa]
    const v_steps = [_]syntax_ir.ProductionStep{.{ .symbol = .{ .terminal = 10 } }};
    const w_steps = [_]syntax_ir.ProductionStep{.{ .symbol = .{ .terminal = 11 } }};
    const a_steps = [_]syntax_ir.ProductionStep{
        .{ .symbol = .{ .non_terminal = 1 } }, // V
        .{ .symbol = .{ .non_terminal = 2 } }, // W
    };
    const original = [_]InlinedProduction{
        .{ .lhs = 0, .steps = &a_steps },
        .{ .lhs = 1, .steps = &v_steps },
        .{ .lhs = 2, .steps = &w_steps },
    };
    const variables = [_]syntax_ir.SyntaxVariable{
        .{ .name = "A", .kind = .named, .productions = &.{.{ .steps = @constCast(&a_steps) }} },
        .{ .name = "V", .kind = .hidden, .productions = &.{.{ .steps = @constCast(&v_steps) }} },
        .{ .name = "W", .kind = .hidden, .productions = &.{.{ .steps = @constCast(&w_steps) }} },
    };
    const variables_to_inline = [_]syntax_ir.SymbolRef{
        .{ .non_terminal = 1 },
        .{ .non_terminal = 2 },
    };

    var ipm = try buildInlinedProductionMapAlloc(allocator, &original, &variables_to_inline, &variables);
    defer ipm.deinit();

    // A → V W at step 0: V is inline → [A→xW]
    const exp0 = ipm.inlinedProductions(0, 0).?;
    try std.testing.expectEqual(@as(usize, 1), exp0.len); // A→xW

    // A→xW at step 1: W is inline → [A→xa]
    const axw_id = exp0[0];
    const exp1 = ipm.inlinedProductions(axw_id, 1).?;
    try std.testing.expectEqual(@as(usize, 1), exp1.len); // A→xa

    // A→xa at step 1: x is terminal → no inline
    const axa_id = exp1[0];
    try std.testing.expectEqual(@as(?[]const u32, null), ipm.inlinedProductions(axa_id, 1));
}

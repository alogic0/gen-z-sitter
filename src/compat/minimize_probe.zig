const std = @import("std");
const grammar_loader = @import("../grammar/loader.zig");
const parse_grammar = @import("../grammar/parse_grammar.zig");
const parse_table_pipeline = @import("../parse_table/pipeline.zig");
const targets = @import("targets.zig");

pub const MinimizationProbe = struct {
    target_id: []const u8,
    default_state_count: usize,
    minimized_state_count: usize,

    pub fn mergedCount(self: MinimizationProbe) usize {
        return self.default_state_count - self.minimized_state_count;
    }
};

pub fn probeTargetAlloc(
    allocator: std.mem.Allocator,
    target: targets.Target,
) !MinimizationProbe {
    var loaded = try grammar_loader.loadGrammarFile(allocator, target.grammar_path);
    defer loaded.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const prepared = try parse_grammar.parseRawGrammar(parse_arena.allocator(), &loaded.json.grammar);
    const default_result = try parse_table_pipeline.buildStatesFromPreparedWithOptions(
        allocator,
        prepared,
        .{},
    );
    const minimized_result = try parse_table_pipeline.buildStatesFromPreparedWithOptions(
        allocator,
        prepared,
        .{ .minimize_states = true },
    );

    return .{
        .target_id = target.id,
        .default_state_count = default_result.states.len,
        .minimized_state_count = minimized_result.states.len,
    };
}

fn findTarget(target_id: []const u8) ?targets.Target {
    for (targets.shortlistTargets()) |target| {
        if (std.mem.eql(u8, target.id, target_id)) return target;
    }
    return null;
}

fn expectBoundedTargetMinimization(target_id: []const u8) !MinimizationProbe {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const target = findTarget(target_id) orelse return error.UnknownTarget;
    const probe = try probeTargetAlloc(arena.allocator(), target);
    try std.testing.expectEqualStrings(target_id, probe.target_id);
    try std.testing.expect(probe.default_state_count > 0);
    try std.testing.expect(probe.minimized_state_count > 0);
    try std.testing.expect(probe.minimized_state_count <= probe.default_state_count);
    return probe;
}

test "bounded compat minimization probe keeps safe target state counts monotonic" {
    const target_ids = [_][]const u8{
        "parse_table_tiny_json",
        "behavioral_config_json",
        "parse_table_conflict_json",
        "bracket_lang_json",
    };

    for (target_ids) |target_id| {
        _ = try expectBoundedTargetMinimization(target_id);
    }
}

test "bounded compat minimization probe reports merged count from state delta" {
    const probe = try expectBoundedTargetMinimization("parse_table_tiny_json");
    try std.testing.expectEqual(
        probe.default_state_count - probe.minimized_state_count,
        probe.mergedCount(),
    );
}

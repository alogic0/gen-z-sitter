const std = @import("std");
const grammar_loader = @import("grammar/loader.zig");
const parse_grammar = @import("grammar/parse_grammar.zig");
const parse_table_pipeline = @import("parse_table/pipeline.zig");
const parser_c_emit = @import("parser_emit/parser_c.zig");
const runtime_io = @import("support/runtime_io.zig");

const ProfileTarget = struct {
    label: []const u8,
    path: []const u8,
    build_options: @import("parse_table/build.zig").BuildOptions = .{},
};

const profile_targets = [_]ProfileTarget{
    .{ .label = "tree_sitter_c_json", .path = "compat_targets/tree_sitter_c/grammar.json" },
    .{
        .label = "tree_sitter_zig_json",
        .path = "compat_targets/tree_sitter_zig/grammar.json",
        .build_options = .{ .closure_lookahead_mode = .none, .coarse_follow_lookaheads = true },
    },
    .{ .label = "tree_sitter_typescript_json", .path = "compat_targets/tree_sitter_typescript/grammar.json" },
    .{ .label = "tree_sitter_rust_json", .path = "compat_targets/tree_sitter_rust/grammar.json" },
    .{ .label = "tree_sitter_javascript_json", .path = "compat_targets/tree_sitter_javascript/grammar.json" },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    runtime_io.set(init.io, init.minimal.environ);
    const profile_allocator = std.heap.smp_allocator;

    const only = parseOnlyArg(args) orelse null;
    for (profile_targets) |target| {
        if (only) |label| {
            if (!std.mem.eql(u8, label, target.label)) continue;
        }
        try profileTarget(init.gpa, profile_allocator, target);
    }
}

fn parseOnlyArg(args: []const []const u8) ?[]const u8 {
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--target") and index + 1 < args.len) return args[index + 1];
    }
    return null;
}

fn profileTarget(lifetime_allocator: std.mem.Allocator, work_allocator: std.mem.Allocator, target: ProfileTarget) !void {
    std.debug.print("[phase5-profile] target={s} path={s}\n", .{ target.label, target.path });
    const start_rss_kb = selfMaxRssKb();
    const total_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);

    var lifetime_arena = std.heap.ArenaAllocator.init(lifetime_allocator);
    defer lifetime_arena.deinit();
    const arena_allocator = lifetime_arena.allocator();

    const load_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    var loaded = try grammar_loader.loadGrammarFile(arena_allocator, target.path);
    defer loaded.deinit();
    logStage("runtime-serialize-profile", target.label, "load", load_timer);

    const prepare_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const prepared = try parse_grammar.parseRawGrammar(arena_allocator, &loaded.json.grammar);
    logStage("runtime-serialize-profile", target.label, "prepare", prepare_timer);

    const serialize_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const serialized = parse_table_pipeline.serializeRuntimeTableFromPreparedWithBuildOptionsProfile(
        work_allocator,
        prepared,
        .diagnostic,
        target.build_options,
        target.label,
    ) catch |err| {
        const max_rss_kb = selfMaxRssKb();
        std.debug.print(
            "[phase5-profile] summary target={s} failed_stage=serialize error={s} serialize_ms={d:.2} total_ms={d:.2} maxrss_kb={d}\n",
            .{
                target.label,
                @errorName(err),
                elapsedMs(serialize_timer),
                elapsedMs(total_timer),
                @max(start_rss_kb, max_rss_kb),
            },
        );
        return;
    };
    const serialize_ms = elapsedMs(serialize_timer);

    const emit_timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const parser_c = try parser_c_emit.emitParserCAllocWithOptions(work_allocator, serialized, .{
        .compact_duplicate_states = false,
        .glr_loop = true,
    });
    const emit_ms = elapsedMs(emit_timer);
    const max_rss_kb = selfMaxRssKb();

    std.debug.print(
        "[phase5-profile] summary target={s} states={d} blocked={} parser_c_bytes={d} serialize_ms={d:.2} emit_ms={d:.2} total_ms={d:.2} maxrss_kb={d}\n",
        .{
            target.label,
            serialized.states.len,
            serialized.blocked,
            parser_c.len,
            serialize_ms,
            emit_ms,
            elapsedMs(total_timer),
            @max(start_rss_kb, max_rss_kb),
        },
    );
}

fn logStage(prefix: []const u8, label: []const u8, stage: []const u8, start: std.Io.Timestamp) void {
    const duration = start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake));
    const elapsed_ms = @as(f64, @floatFromInt(duration.nanoseconds)) / @as(f64, std.time.ns_per_ms);
    std.debug.print("[{s}] {s} {s}_ms={d:.2}\n", .{ prefix, label, stage, elapsed_ms });
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const duration = start.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake));
    return @as(f64, @floatFromInt(duration.nanoseconds)) / @as(f64, std.time.ns_per_ms);
}

fn selfMaxRssKb() usize {
    const usage = std.posix.getrusage(0);
    if (usage.maxrss <= 0) return 0;
    return @intCast(usage.maxrss);
}

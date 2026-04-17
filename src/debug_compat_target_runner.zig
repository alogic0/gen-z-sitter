const std = @import("std");
const compat_harness = @import("compat/harness.zig");
const targets = @import("compat/targets.zig");
const result_model = @import("compat/result.zig");

fn findTargetById(target_id: []const u8) ?targets.Target {
    for (targets.shortlistTargets()) |target| {
        if (std.mem.eql(u8, target.id, target_id)) return target;
    }
    return null;
}

fn printStepSummary(name: []const u8, step: result_model.StepResult) void {
    std.debug.print("[compat_target_runner] step {s} status={s}\n", .{ name, @tagName(step.status) });
    if (step.detail) |detail| {
        std.debug.print("[compat_target_runner] step_detail {s} {s}\n", .{ name, detail });
    }
}

fn printRunSummary(run: result_model.TargetRunResult) void {
    std.debug.print(
        "[compat_target_runner] result target={s} classification={s} mismatch={s} first_failed_stage={s}\n",
        .{
            run.id,
            @tagName(run.final_classification),
            @tagName(run.mismatch_category),
            if (run.first_failed_stage) |stage| @tagName(stage) else "none",
        },
    );
    printStepSummary("load", run.load);
    printStepSummary("prepare", run.prepare);
    printStepSummary("serialize", run.serialize);
    printStepSummary("emit_parser_tables", run.emit_parser_tables);
    printStepSummary("emit_c_tables", run.emit_c_tables);
    printStepSummary("emit_parser_c", run.emit_parser_c);
    printStepSummary("scanner_boundary_check", run.scanner_boundary_check);
    printStepSummary("compat_check", run.compat_check);
    printStepSummary("compile_smoke", run.compile_smoke);

    if (run.emission) |emission| {
        std.debug.print(
            "[compat_target_runner] emission blocked={} serialized_states={d} emitted_states={d} merged_states={d} unresolved_entries={d} parser_tables_bytes={d} c_tables_bytes={d} parser_c_bytes={d}\n",
            .{
                emission.blocked,
                emission.serialized_state_count,
                emission.emitted_state_count,
                emission.merged_state_count,
                emission.unresolved_entry_count,
                emission.parser_tables_bytes,
                emission.c_tables_bytes,
                emission.parser_c_bytes,
            },
        );
    }

    if (run.blocked_boundary) |blocked_boundary| {
        std.debug.print(
            "[compat_target_runner] blocked_boundary unresolved_states={d} unresolved_entries={d} shift_reduce={d} reduce_reduce_deferred={d} multiple_candidates={d} unsupported_action_mix={d}\n",
            .{
                blocked_boundary.unresolved_state_count,
                blocked_boundary.unresolved_entry_count,
                blocked_boundary.reasons.shift_reduce,
                blocked_boundary.reasons.reduce_reduce_deferred,
                blocked_boundary.reasons.multiple_candidates,
                blocked_boundary.reasons.unsupported_action_mix,
            },
        );
        for (blocked_boundary.samples, 0..) |sample, index| {
            std.debug.print(
                "[compat_target_runner] blocked_sample {d} state={d} symbol={s}:{d} name={s} reason={s} candidates={d} actions={s}\n",
                .{
                    index,
                    sample.state_id,
                    @tagName(sample.symbol_kind),
                    sample.symbol_index,
                    sample.symbol_name,
                    sample.reason,
                    sample.candidate_count,
                    sample.candidate_actions_summary,
                },
            );
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const target_id = args.next() orelse {
        std.debug.print("usage: zig run src/debug_compat_target_runner.zig -- <target-id>\n", .{});
        std.process.exit(1);
    };
    if (args.next() != null) {
        std.debug.print("usage: zig run src/debug_compat_target_runner.zig -- <target-id>\n", .{});
        std.process.exit(1);
    }

    const target = findTargetById(target_id) orelse {
        std.debug.print("[compat_target_runner] unknown target id: {s}\n", .{target_id});
        std.process.exit(1);
    };

    var timer = try std.time.Timer.start();
    var run = try compat_harness.runTarget(allocator, target, .{ .progress_log = true });
    defer run.deinit(allocator);
    const elapsed_ms = @as(f64, @floatFromInt(timer.read())) / @as(f64, std.time.ns_per_ms);

    printRunSummary(run);
    std.debug.print("[compat_target_runner] total_elapsed_ms={d:.2}\n", .{elapsed_ms});
}

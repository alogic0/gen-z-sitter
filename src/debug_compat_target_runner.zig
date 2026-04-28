const std = @import("std");
const compat_harness = @import("compat/harness.zig");
const targets = @import("compat/targets.zig");
const result_model = @import("compat/result.zig");
const runtime_io = @import("support/runtime_io.zig");

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
    printStepSummary("emit_parser_c", run.emit_parser_c);
    printStepSummary("scanner_boundary_check", run.scanner_boundary_check);
    printStepSummary("compat_check", run.compat_check);
    printStepSummary("compile_smoke", run.compile_smoke);

    if (run.emission) |emission| {
        std.debug.print(
            "[compat_target_runner] emission blocked={} serialized_states={d} emitted_states={d} merged_states={d} unresolved_entries={d} parser_tables_bytes={d} parser_c_bytes={d}",
            .{
                emission.blocked,
                emission.serialized_state_count,
                emission.emitted_state_count,
                emission.merged_state_count,
                emission.unresolved_entry_count,
                emission.parser_tables_bytes,
                emission.parser_c_bytes,
            },
        );
        if (emission.emit_parser_c_ms) |value| {
            std.debug.print(" emit_parser_c_ms={d:.2}", .{value});
        }
        if (emission.compile_smoke_ms) |value| {
            std.debug.print(" compile_smoke_ms={d:.2}", .{value});
        }
        std.debug.print("\n", .{});
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

fn parseStage(raw: []const u8) ?result_model.StepName {
    return std.meta.stringToEnum(result_model.StepName, raw);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    runtime_io.set(init.io, init.minimal.environ);
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: zig run src/debug_compat_target_runner.zig -- <target-id> [--stop-after <stage>] [--profile-timings]\n", .{});
        std.process.exit(1);
    }
    const target_id = args[1];
    var stop_after_stage: ?result_model.StepName = null;
    var profile_timings = false;
    var arg_index: usize = 2;
    while (arg_index < args.len) {
        const arg = args[arg_index];
        arg_index += 1;
        if (std.mem.eql(u8, arg, "--stop-after")) {
            if (arg_index >= args.len) {
                std.debug.print("[compat_target_runner] --stop-after requires a stage\n", .{});
                std.process.exit(1);
            }
            const raw_stage = args[arg_index];
            arg_index += 1;
            stop_after_stage = parseStage(raw_stage) orelse {
                std.debug.print("[compat_target_runner] unknown stage: {s}\n", .{raw_stage});
                std.process.exit(1);
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile-timings")) {
            profile_timings = true;
            continue;
        }
        std.debug.print("usage: zig run src/debug_compat_target_runner.zig -- <target-id> [--stop-after <stage>] [--profile-timings]\n", .{});
        std.process.exit(1);
    }

    const target = findTargetById(target_id) orelse {
        std.debug.print("[compat_target_runner] unknown target id: {s}\n", .{target_id});
        std.process.exit(1);
    };

    const start_ts = std.Io.Timestamp.now(runtime_io.get(), .awake);
    var run = try compat_harness.runTarget(allocator, target, .{
        .progress_log = true,
        .profile_timings = profile_timings,
        .stop_after_stage = stop_after_stage,
    });
    defer run.deinit(allocator);
    const elapsed_ms = @as(f64, @floatFromInt(start_ts.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake)).nanoseconds)) / @as(f64, std.time.ns_per_ms);

    printRunSummary(run);
    std.debug.print("[compat_target_runner] total_elapsed_ms={d:.2}\n", .{elapsed_ms});
}

const std = @import("std");
const fs_support = @import("src/support/fs.zig");
const json_support = @import("src/support/json.zig");
const parser_boundary_probe = @import("src/compat/parser_boundary_probe.zig");
const runtime_io = @import("src/support/runtime_io.zig");
const targets = @import("src/compat/targets.zig");

fn logStepStart(name: []const u8) void {
    std.debug.print("[update_parser_boundary_probe] start {s}\n", .{name});
}

fn logStepDone(name: []const u8, start_ts: std.Io.Timestamp) void {
    const elapsed_ns = start_ts.durationTo(std.Io.Timestamp.now(runtime_io.get(), .awake)).nanoseconds;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms);
    std.debug.print("[update_parser_boundary_probe] done  {s} ({d:.2} ms)\n", .{ name, elapsed_ms });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    runtime_io.set(init.io, init.minimal.environ);

    var timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    logStepStart("parser_boundary_probe");
    var report = try parser_boundary_probe.buildParserBoundaryProbeFromTargetsAlloc(allocator, targets.shortlistTargets());
    logStepDone("parser_boundary_probe", timer);
    defer report.deinit(allocator);
    const rendered = try json_support.stringifyAlloc(allocator, report);
    defer allocator.free(rendered);

    timer = std.Io.Timestamp.now(runtime_io.get(), .awake);
    logStepStart("compat_targets/parser_boundary_probe.json");
    try fs_support.writeFile("compat_targets/parser_boundary_probe.json", rendered);
    logStepDone("compat_targets/parser_boundary_probe.json", timer);

    std.debug.print("[update_parser_boundary_probe] complete\n", .{});
}

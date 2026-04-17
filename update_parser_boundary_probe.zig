const std = @import("std");
const fs_support = @import("src/support/fs.zig");
const json_support = @import("src/support/json.zig");
const parser_boundary_probe = @import("src/compat/parser_boundary_probe.zig");
const targets = @import("src/compat/targets.zig");

fn logStepStart(name: []const u8) void {
    std.debug.print("[update_parser_boundary_probe] start {s}\n", .{name});
}

fn logStepDone(name: []const u8, timer: *std.time.Timer) void {
    const elapsed_ms = @as(f64, @floatFromInt(timer.read())) / @as(f64, std.time.ns_per_ms);
    std.debug.print("[update_parser_boundary_probe] done  {s} ({d:.2} ms)\n", .{ name, elapsed_ms });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var timer = try std.time.Timer.start();
    logStepStart("parser_boundary_probe");
    var report = try parser_boundary_probe.buildParserBoundaryProbeFromTargetsAlloc(allocator, targets.shortlistTargets());
    logStepDone("parser_boundary_probe", &timer);
    defer report.deinit(allocator);
    const rendered = try json_support.stringifyAlloc(allocator, report);
    defer allocator.free(rendered);

    timer = try std.time.Timer.start();
    logStepStart("compat_targets/parser_boundary_probe.json");
    try fs_support.writeFile("compat_targets/parser_boundary_probe.json", rendered);
    logStepDone("compat_targets/parser_boundary_probe.json", &timer);

    std.debug.print("[update_parser_boundary_probe] complete\n", .{});
}

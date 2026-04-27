const std = @import("std");
const minimize_probe = @import("compat/minimize_probe.zig");
const runtime_io = @import("support/runtime_io.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    runtime_io.set(init.io, init.minimal.environ);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const report = try minimize_probe.buildBoundedReportAlloc(arena.allocator());
    const json = try minimize_probe.renderReportJsonAlloc(arena.allocator(), report);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
}

const std = @import("std");
const fs_support = @import("src/support/fs.zig");
const harness = @import("src/compat/harness.zig");
const result_model = @import("src/compat/result.zig");
const artifact_manifest = @import("src/compat/artifact_manifest.zig");
const shortlist_json = @import("src/compat/shortlist_json.zig");
const inventory = @import("src/compat/inventory.zig");
const report_json = @import("src/compat/report_json.zig");
const mismatch_inventory = @import("src/compat/mismatch_inventory.zig");
const parser_boundary_profile = @import("src/compat/parser_boundary_profile.zig");
const coverage_decision = @import("src/compat/coverage_decision.zig");
const shift_reduce_profile = @import("src/compat/shift_reduce_profile.zig");
const external_repo_inventory = @import("src/compat/external_repo_inventory.zig");
const external_scanner_repo_inventory = @import("src/compat/external_scanner_repo_inventory.zig");

fn logStepStart(name: []const u8) void {
    std.debug.print("[update_compat_artifacts] start {s}\n", .{name});
}

fn logStepDone(name: []const u8, timer: *std.time.Timer) void {
    const elapsed_ms = @as(f64, @floatFromInt(timer.read())) / @as(f64, std.time.ns_per_ms);
    std.debug.print("[update_compat_artifacts] done  {s} ({d:.2} ms)\n", .{ name, elapsed_ms });
}

fn writeArtifact(path: []const u8, contents: []const u8) !void {
    var timer = try std.time.Timer.start();
    logStepStart(path);
    try fs_support.writeFile(path, contents);
    logStepDone(path, &timer);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var timer = try std.time.Timer.start();
    logStepStart("artifact_manifest");
    const manifest = try artifact_manifest.renderArtifactManifestAlloc(allocator);
    logStepDone("artifact_manifest", &timer);
    defer allocator.free(manifest);

    timer = try std.time.Timer.start();
    logStepStart("shortlist");
    const shortlist = try shortlist_json.renderShortlistArtifactAlloc(allocator);
    logStepDone("shortlist", &timer);
    defer allocator.free(shortlist);

    timer = try std.time.Timer.start();
    logStepStart("run_shortlist_targets");
    const runs = try harness.runShortlistTargetsAlloc(allocator, .{ .progress_log = true });
    logStepDone("run_shortlist_targets", &timer);
    defer result_model.deinitRunResults(allocator, runs);

    timer = try std.time.Timer.start();
    logStepStart("inventory_report");
    const inventory_json = try inventory.renderInventoryReportAlloc(allocator, runs);
    logStepDone("inventory_report", &timer);
    defer allocator.free(inventory_json);

    timer = try std.time.Timer.start();
    logStepStart("run_report");
    const report = try report_json.renderRunReportAlloc(allocator, runs);
    logStepDone("run_report", &timer);
    defer allocator.free(report);

    timer = try std.time.Timer.start();
    logStepStart("mismatch_inventory");
    const mismatch = try mismatch_inventory.renderMismatchInventoryAlloc(allocator, runs);
    logStepDone("mismatch_inventory", &timer);
    defer allocator.free(mismatch);

    timer = try std.time.Timer.start();
    logStepStart("parser_boundary_profile");
    const parser_boundary = try parser_boundary_profile.renderParserBoundaryProfileAlloc(allocator, runs);
    logStepDone("parser_boundary_profile", &timer);
    defer allocator.free(parser_boundary);

    timer = try std.time.Timer.start();
    logStepStart("coverage_decision");
    const decision = try coverage_decision.renderCoverageDecisionAlloc(allocator, runs);
    logStepDone("coverage_decision", &timer);
    defer allocator.free(decision);

    timer = try std.time.Timer.start();
    logStepStart("shift_reduce_profile");
    const shift_reduce = try shift_reduce_profile.renderShiftReduceProfileAlloc(allocator, runs);
    logStepDone("shift_reduce_profile", &timer);
    defer allocator.free(shift_reduce);

    timer = try std.time.Timer.start();
    logStepStart("external_repo_inventory");
    const external_repo = try external_repo_inventory.renderExternalRepoInventoryAlloc(allocator, runs);
    logStepDone("external_repo_inventory", &timer);
    defer allocator.free(external_repo);

    timer = try std.time.Timer.start();
    logStepStart("external_scanner_repo_inventory");
    const external_scanner_repo = try external_scanner_repo_inventory.renderExternalScannerRepoInventoryAlloc(allocator, runs);
    logStepDone("external_scanner_repo_inventory", &timer);
    defer allocator.free(external_scanner_repo);

    try writeArtifact("compat_targets/artifact_manifest.json", manifest);
    try writeArtifact("compat_targets/shortlist.json", shortlist);
    try writeArtifact("compat_targets/shortlist_inventory.json", inventory_json);
    try writeArtifact("compat_targets/shortlist_report.json", report);
    try writeArtifact("compat_targets/shortlist_mismatch_inventory.json", mismatch);
    try writeArtifact("compat_targets/parser_boundary_profile.json", parser_boundary);
    try writeArtifact("compat_targets/coverage_decision.json", decision);
    try writeArtifact("compat_targets/shortlist_shift_reduce_profile.json", shift_reduce);
    try writeArtifact("compat_targets/external_repo_inventory.json", external_repo);
    try writeArtifact("compat_targets/external_scanner_repo_inventory.json", external_scanner_repo);

    std.debug.print("[update_compat_artifacts] complete\n", .{});
}

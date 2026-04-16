const std = @import("std");
const fs_support = @import("src/support/fs.zig");
const harness = @import("src/compat/harness.zig");
const result_model = @import("src/compat/result.zig");
const shortlist_json = @import("src/compat/shortlist_json.zig");
const inventory = @import("src/compat/inventory.zig");
const report_json = @import("src/compat/report_json.zig");
const mismatch_inventory = @import("src/compat/mismatch_inventory.zig");
const coverage_decision = @import("src/compat/coverage_decision.zig");
const shift_reduce_profile = @import("src/compat/shift_reduce_profile.zig");
const external_repo_inventory = @import("src/compat/external_repo_inventory.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const shortlist = try shortlist_json.renderShortlistArtifactAlloc(allocator);
    defer allocator.free(shortlist);

    const runs = try harness.runShortlistTargetsAlloc(allocator, .{});
    defer result_model.deinitRunResults(allocator, runs);

    const inventory_json = try inventory.renderInventoryReportAlloc(allocator, runs);
    defer allocator.free(inventory_json);

    const report = try report_json.renderRunReportAlloc(allocator, runs);
    defer allocator.free(report);

    const mismatch = try mismatch_inventory.renderMismatchInventoryAlloc(allocator, runs);
    defer allocator.free(mismatch);

    const decision = try coverage_decision.renderCoverageDecisionAlloc(allocator, runs);
    defer allocator.free(decision);

    const shift_reduce = try shift_reduce_profile.renderShiftReduceProfileAlloc(allocator, runs);
    defer allocator.free(shift_reduce);

    const external_repo = try external_repo_inventory.renderExternalRepoInventoryAlloc(allocator, runs);
    defer allocator.free(external_repo);

    try fs_support.writeFile("compat_targets/shortlist.json", shortlist);
    try fs_support.writeFile("compat_targets/shortlist_inventory.json", inventory_json);
    try fs_support.writeFile("compat_targets/shortlist_report.json", report);
    try fs_support.writeFile("compat_targets/shortlist_mismatch_inventory.json", mismatch);
    try fs_support.writeFile("compat_targets/coverage_decision.json", decision);
    try fs_support.writeFile("compat_targets/shortlist_shift_reduce_profile.json", shift_reduce);
    try fs_support.writeFile("compat_targets/external_repo_inventory.json", external_repo);
}

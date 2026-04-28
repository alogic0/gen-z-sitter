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
const parser_boundary_hypothesis = @import("src/compat/parser_boundary_hypothesis.zig");
const coverage_decision = @import("src/compat/coverage_decision.zig");
const deferred_real_grammar_classification = @import("src/compat/deferred_real_grammar_classification.zig");
const shift_reduce_profile = @import("src/compat/shift_reduce_profile.zig");
const external_repo_inventory = @import("src/compat/external_repo_inventory.zig");
const external_scanner_repo_inventory = @import("src/compat/external_scanner_repo_inventory.zig");
const release_boundary = @import("src/compat/release_boundary.zig");
const runtime_io = @import("src/support/runtime_io.zig");

fn logStepStart(name: []const u8) void {
    std.debug.print("[update_compat_artifacts] start {s}\n", .{name});
}

fn logStepDone(name: []const u8) void {
    std.debug.print("[update_compat_artifacts] done  {s}\n", .{name});
}

fn writeArtifact(path: []const u8, contents: []const u8) !void {
    logStepStart(path);
    try fs_support.writeFile(path, contents);
    logStepDone(path);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    runtime_io.set(init.io, init.minimal.environ);

    logStepStart("artifact_manifest");
    const manifest = try artifact_manifest.renderArtifactManifestAlloc(allocator);
    logStepDone("artifact_manifest");
    defer allocator.free(manifest);

    logStepStart("shortlist");
    const shortlist = try shortlist_json.renderShortlistArtifactAlloc(allocator);
    logStepDone("shortlist");
    defer allocator.free(shortlist);

    logStepStart("run_shortlist_targets");
    const runs = try harness.runShortlistTargetsAlloc(allocator, .{
        .progress_log = true,
        .profile_timings = true,
    });
    logStepDone("run_shortlist_targets");
    defer result_model.deinitRunResults(allocator, runs);

    logStepStart("inventory_report");
    const inventory_json = try inventory.renderInventoryReportAlloc(allocator, runs);
    logStepDone("inventory_report");
    defer allocator.free(inventory_json);

    logStepStart("run_report");
    const report = try report_json.renderRunReportAlloc(allocator, runs);
    logStepDone("run_report");
    defer allocator.free(report);

    logStepStart("mismatch_inventory");
    const mismatch = try mismatch_inventory.renderMismatchInventoryAlloc(allocator, runs);
    logStepDone("mismatch_inventory");
    defer allocator.free(mismatch);

    logStepStart("parser_boundary_profile");
    const parser_boundary = try parser_boundary_profile.renderParserBoundaryProfileAlloc(allocator, runs);
    logStepDone("parser_boundary_profile");
    defer allocator.free(parser_boundary);

    logStepStart("parser_boundary_hypothesis");
    const parser_boundary_hypothesis_json = try parser_boundary_hypothesis.renderParserBoundaryHypothesisAlloc(allocator, runs);
    logStepDone("parser_boundary_hypothesis");
    defer allocator.free(parser_boundary_hypothesis_json);

    logStepStart("coverage_decision");
    const decision = try coverage_decision.renderCoverageDecisionAlloc(allocator, runs);
    logStepDone("coverage_decision");
    defer allocator.free(decision);

    logStepStart("deferred_real_grammar_classification");
    const deferred_real_grammar = try deferred_real_grammar_classification.renderDeferredRealGrammarClassificationAlloc(allocator);
    logStepDone("deferred_real_grammar_classification");
    defer allocator.free(deferred_real_grammar);

    logStepStart("shift_reduce_profile");
    const shift_reduce = try shift_reduce_profile.renderShiftReduceProfileAlloc(allocator, runs);
    logStepDone("shift_reduce_profile");
    defer allocator.free(shift_reduce);

    logStepStart("external_repo_inventory");
    const external_repo = try external_repo_inventory.renderExternalRepoInventoryAlloc(allocator, runs);
    logStepDone("external_repo_inventory");
    defer allocator.free(external_repo);

    logStepStart("external_scanner_repo_inventory");
    const external_scanner_repo = try external_scanner_repo_inventory.renderExternalScannerRepoInventoryAlloc(allocator, runs);
    logStepDone("external_scanner_repo_inventory");
    defer allocator.free(external_scanner_repo);

    logStepStart("release_boundary");
    const release_boundary_json = try release_boundary.renderReleaseBoundaryAlloc(allocator);
    logStepDone("release_boundary");
    defer allocator.free(release_boundary_json);

    try writeArtifact("compat_targets/artifact_manifest.json", manifest);
    try writeArtifact("compat_targets/shortlist.json", shortlist);
    try writeArtifact("compat_targets/shortlist_inventory.json", inventory_json);
    try writeArtifact("compat_targets/shortlist_report.json", report);
    try writeArtifact("compat_targets/shortlist_mismatch_inventory.json", mismatch);
    try writeArtifact("compat_targets/parser_boundary_profile.json", parser_boundary);
    try writeArtifact("compat_targets/parser_boundary_hypothesis.json", parser_boundary_hypothesis_json);
    try writeArtifact("compat_targets/coverage_decision.json", decision);
    try writeArtifact("compat_targets/deferred_real_grammar_classification.json", deferred_real_grammar);
    try writeArtifact("compat_targets/shortlist_shift_reduce_profile.json", shift_reduce);
    try writeArtifact("compat_targets/external_repo_inventory.json", external_repo);
    try writeArtifact("compat_targets/external_scanner_repo_inventory.json", external_scanner_repo);
    try writeArtifact("compat_targets/release_boundary.json", release_boundary_json);

    std.debug.print("[update_compat_artifacts] complete\n", .{});
}

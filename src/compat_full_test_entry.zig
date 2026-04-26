const std = @import("std");

test {
    _ = @import("compat/artifact_manifest.zig");
    _ = @import("compat/targets.zig");
    _ = @import("compat/result.zig");
    _ = @import("compat/compile_smoke.zig");
    _ = @import("compat/coverage_decision.zig");
    _ = @import("compat/external_repo_inventory.zig");
    _ = @import("compat/external_scanner_repo_inventory.zig");
    _ = @import("compat/harness.zig");
    _ = @import("compat/inventory.zig");
    _ = @import("compat/mismatch_inventory.zig");
    _ = @import("compat/parser_boundary_hypothesis.zig");
    _ = @import("compat/parser_boundary_profile.zig");
    _ = @import("compat/parser_boundary_probe.zig");
    _ = @import("compat/report_json.zig");
    _ = @import("compat/shortlist_json.zig");
    _ = @import("compat/shift_reduce_profile.zig");
}

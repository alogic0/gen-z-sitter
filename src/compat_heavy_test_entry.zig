const std = @import("std");

test {
    _ = @import("compat/artifact_manifest.zig");
    _ = @import("compat/targets.zig");
    _ = @import("compat/result.zig");
    _ = @import("compat/compile_smoke.zig");
    _ = @import("compat/parser_boundary_probe.zig");
    _ = @import("compat/shortlist_json.zig");
}

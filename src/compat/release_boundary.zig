const std = @import("std");
const json_support = @import("../support/json.zig");

pub const GrammarBoundary = struct {
    id: []const u8,
    status: []const u8,
    proof: []const u8,
};

pub const ReleaseBoundaryReport = struct {
    schema_version: u32,
    boundary: []const u8,
    promoted_grammars: []const GrammarBoundary,
    deferred_grammars: []const GrammarBoundary,
    runtime_surface_gaps: []const []const u8,
    bounded_release_gates: []const []const u8,
};

const promoted_grammars = [_]GrammarBoundary{
    .{
        .id = "tree_sitter_json_json",
        .status = "promoted",
        .proof = "full parser emission, compile-smoke, accepted runtime-link samples, and invalid runtime-link sample",
    },
    .{
        .id = "tree_sitter_ziggy_json",
        .status = "promoted",
        .proof = "full parser emission, compile-smoke, and accepted runtime-link sample",
    },
    .{
        .id = "tree_sitter_ziggy_schema_json",
        .status = "promoted",
        .proof = "full parser emission, compile-smoke, and accepted runtime-link sample",
    },
    .{
        .id = "tree_sitter_zig_json",
        .status = "promoted",
        .proof = "bounded parser.c emission, compile-smoke, and focused accepted runtime-link sample",
    },
    .{
        .id = "tree_sitter_bash_json",
        .status = "promoted_scanner_boundary",
        .proof = "regular and generated-GLR runtime-link proofs against the real scanner.c",
    },
    .{
        .id = "tree_sitter_haskell_json",
        .status = "promoted_scanner_boundary",
        .proof = "regular and generated-GLR runtime-link proofs against the real scanner.c",
    },
};

const deferred_grammars = [_]GrammarBoundary{
    .{
        .id = "tree_sitter_javascript_json",
        .status = "deferred_runtime_proof",
        .proof = "bounded coarse serialize-only parser proof plus parser.c compile-smoke; automatic semicolon and regex scanner runtime proof remains separate",
    },
    .{
        .id = "tree_sitter_python_json",
        .status = "deferred_runtime_proof",
        .proof = "bounded coarse serialize-only parser proof plus parser.c compile-smoke; indentation scanner runtime proof remains separate",
    },
    .{
        .id = "tree_sitter_typescript_json",
        .status = "deferred_runtime_proof",
        .proof = "bounded coarse serialize-only parser proof plus parser.c compile-smoke; JavaScript-family scanner runtime proof remains separate",
    },
    .{
        .id = "tree_sitter_rust_json",
        .status = "deferred_runtime_proof",
        .proof = "bounded coarse serialize-only parser proof plus parser.c compile-smoke; string/comment scanner runtime proof remains separate",
    },
    .{
        .id = "parse_table_conflict_json",
        .status = "deferred_control_fixture",
        .proof = "intentional ambiguous control fixture for unresolved conflict handling",
    },
};

const runtime_surface_gaps = [_][]const u8{
    "generated GLR recovery is bounded and visible, but not full tree-sitter runtime recovery parity",
    "generated result/tree output is exposed through the temporary ts_generated_parse_result API",
    "external scanner proofs are focused runtime-link samples, not broad corpus-level runtime equivalence",
    "large JavaScript-family and scanner-heavy grammars have bounded parser proofs but still defer full parser-table parity and real scanner runtime equivalence",
};

const bounded_release_gates = [_][]const u8{
    "zig build test",
    "zig build test-build-config",
    "zig build test-cli-generate",
    "zig build test-pipeline",
    "zig build test-link-runtime",
    "zig build test-compat-heavy",
    "zig build run-generate-smoke",
    "zig build test-release",
};

pub fn renderReleaseBoundaryAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try json_support.stringifyAlloc(allocator, ReleaseBoundaryReport{
        .schema_version = 1,
        .boundary = "staged release readiness, not full upstream tree-sitter generate parity",
        .promoted_grammars = &promoted_grammars,
        .deferred_grammars = &deferred_grammars,
        .runtime_surface_gaps = &runtime_surface_gaps,
        .bounded_release_gates = &bounded_release_gates,
    });
}

test "renderReleaseBoundaryAlloc matches the checked-in release boundary artifact" {
    const allocator = std.testing.allocator;

    const rendered = try renderReleaseBoundaryAlloc(allocator);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "compat_targets/release_boundary.json", allocator, .limited(1024 * 1024));
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimEnd(u8, expected, "\n");
    const normalized_rendered = std.mem.trimEnd(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

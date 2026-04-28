const std = @import("std");
const json_support = @import("../support/json.zig");
const targets = @import("targets.zig");

pub const DeferredScannerToken = struct {
    name: []const u8,
    kind: []const u8,
    role: []const u8,
};

pub const DeferredSample = struct {
    label: []const u8,
    input: []const u8,
    purpose: []const u8,
};

pub const DeferredRealGrammarEntry = struct {
    id: []const u8,
    family: targets.TargetFamily,
    current_parser_boundary_check_mode: targets.ParserBoundaryCheckMode,
    standalone_probe_status: []const u8,
    serialized_state_count: u32,
    serialized_blocked: bool,
    blocked_surface: []const u8,
    external_scanner_symbol_count: u32,
    external_tokens: []const DeferredScannerToken,
    bounded_coarse_proof: []const u8,
    scanner_runtime_plan: []const DeferredSample,
    routine_boundary_decision: []const u8,
    next_action: []const u8,
};

pub const DeferredRealGrammarClassification = struct {
    schema_version: u32,
    source_probe: []const u8,
    target_count: usize,
    gate: []const u8,
    entries: []const DeferredRealGrammarEntry,
};

const javascript_tokens = [_]DeferredScannerToken{
    .{ .name = "_automatic_semicolon", .kind = "symbol", .role = "statement-boundary insertion" },
    .{ .name = "_template_chars", .kind = "symbol", .role = "template literal body scanning" },
    .{ .name = "_ternary_qmark", .kind = "symbol", .role = "ternary ambiguity disambiguation" },
    .{ .name = "html_comment", .kind = "symbol", .role = "HTML-style comment token" },
    .{ .name = "||", .kind = "string", .role = "external string token" },
    .{ .name = "escape_sequence", .kind = "symbol", .role = "string/template escape scanning" },
    .{ .name = "regex_pattern", .kind = "symbol", .role = "regular expression body scanning" },
    .{ .name = "jsx_text", .kind = "symbol", .role = "JSX text scanning" },
};

const javascript_samples = [_]DeferredSample{
    .{ .label = "automatic_semicolon", .input = "let x = 1\nx\n", .purpose = "minimal future scanner proof for semicolon insertion" },
    .{ .label = "regex_pattern", .input = "const r = /x+/;\n", .purpose = "minimal future scanner proof for regex-pattern context" },
};

const python_tokens = [_]DeferredScannerToken{
    .{ .name = "_newline", .kind = "symbol", .role = "logical-line boundary" },
    .{ .name = "_indent", .kind = "symbol", .role = "indent stack push" },
    .{ .name = "_dedent", .kind = "symbol", .role = "indent stack pop" },
    .{ .name = "string_start", .kind = "symbol", .role = "string scanner entry" },
    .{ .name = "_string_content", .kind = "symbol", .role = "string scanner content" },
    .{ .name = "escape_interpolation", .kind = "symbol", .role = "f-string interpolation escape" },
    .{ .name = "string_end", .kind = "symbol", .role = "string scanner exit" },
    .{ .name = "comment", .kind = "symbol", .role = "comment scanning" },
    .{ .name = "]", .kind = "string", .role = "external bracket close in scanner state" },
    .{ .name = ")", .kind = "string", .role = "external paren close in scanner state" },
    .{ .name = "}", .kind = "string", .role = "external brace close in scanner state" },
    .{ .name = "except", .kind = "string", .role = "external exception keyword context" },
};

const python_samples = [_]DeferredSample{
    .{ .label = "shallow_assignment", .input = "x = 1\n", .purpose = "shallow sample for newline-only scanner path" },
    .{ .label = "layout_if_block", .input = "if True:\n    x = 1\n", .purpose = "layout-sensitive sample that requires indent and dedent state" },
};

const typescript_tokens = [_]DeferredScannerToken{
    .{ .name = "_automatic_semicolon", .kind = "symbol", .role = "statement-boundary insertion" },
    .{ .name = "_template_chars", .kind = "symbol", .role = "template literal body scanning" },
    .{ .name = "_ternary_qmark", .kind = "symbol", .role = "ternary ambiguity disambiguation" },
    .{ .name = "html_comment", .kind = "symbol", .role = "HTML-style comment token" },
    .{ .name = "||", .kind = "string", .role = "external string token" },
    .{ .name = "escape_sequence", .kind = "symbol", .role = "string/template escape scanning" },
    .{ .name = "regex_pattern", .kind = "symbol", .role = "regular expression body scanning" },
    .{ .name = "jsx_text", .kind = "symbol", .role = "JSX text scanning" },
    .{ .name = "_function_signature_automatic_semicolon", .kind = "symbol", .role = "function-signature semicolon insertion" },
    .{ .name = "__error_recovery", .kind = "symbol", .role = "scanner-assisted error recovery" },
};

const typescript_samples = [_]DeferredSample{
    .{ .label = "type_annotation", .input = "let x: number = 1;\n", .purpose = "bounded coarse proof sample after scanner boundary support" },
    .{ .label = "tsx_text", .input = "const x = <div>hi</div>;\n", .purpose = "future JSX scanner proof" },
};

const rust_tokens = [_]DeferredScannerToken{
    .{ .name = "string_content", .kind = "symbol", .role = "string body scanning" },
    .{ .name = "string_close", .kind = "symbol", .role = "string close scanning" },
    .{ .name = "_raw_string_literal_start", .kind = "symbol", .role = "raw string delimiter start" },
    .{ .name = "raw_string_literal_content", .kind = "symbol", .role = "raw string content scanning" },
    .{ .name = "_raw_string_literal_end", .kind = "symbol", .role = "raw string delimiter end" },
    .{ .name = "float_literal", .kind = "symbol", .role = "float literal disambiguation" },
    .{ .name = "_outer_block_doc_comment_marker", .kind = "symbol", .role = "outer block doc comment marker" },
    .{ .name = "_inner_block_doc_comment_marker", .kind = "symbol", .role = "inner block doc comment marker" },
    .{ .name = "_block_comment_content", .kind = "symbol", .role = "nested block comment content" },
    .{ .name = "_line_doc_content", .kind = "symbol", .role = "line doc comment content" },
    .{ .name = "_error_sentinel", .kind = "symbol", .role = "scanner-assisted error sentinel" },
};

const rust_samples = [_]DeferredSample{
    .{ .label = "function_item", .input = "fn main() {}\n", .purpose = "bounded coarse proof sample after scanner boundary support" },
    .{ .label = "raw_string", .input = "let s = r#\"x\"#;\n", .purpose = "future raw-string scanner proof" },
};

const entries = [_]DeferredRealGrammarEntry{
    .{
        .id = "tree_sitter_javascript_json",
        .family = .javascript,
        .current_parser_boundary_check_mode = .serialize_only,
        .standalone_probe_status = "passed_coarse_serialize_only",
        .serialized_state_count = 1315,
        .serialized_blocked = true,
        .blocked_surface = "external_scanner_symbols_only",
        .external_scanner_symbol_count = javascript_tokens.len,
        .external_tokens = javascript_tokens[0..],
        .bounded_coarse_proof = "promoted to the bounded routine coarse serialize-only parser proof; blocked=true because scanner callback semantics remain target-specific",
        .scanner_runtime_plan = javascript_samples[0..],
        .routine_boundary_decision = "keep full parser-table parity and runtime-link proof deferred until a minimal scanner runtime proof covers automatic semicolon or regex_pattern",
        .next_action = "build a minimal JavaScript scanner runtime proof for automatic_semicolon or regex_pattern",
    },
    .{
        .id = "tree_sitter_python_json",
        .family = .python,
        .current_parser_boundary_check_mode = .serialize_only,
        .standalone_probe_status = "passed_coarse_serialize_only",
        .serialized_state_count = 1034,
        .serialized_blocked = true,
        .blocked_surface = "external_scanner_symbols_only",
        .external_scanner_symbol_count = python_tokens.len,
        .external_tokens = python_tokens[0..],
        .bounded_coarse_proof = "promoted to the bounded routine coarse serialize-only parser proof; blocked=true because indentation scanner state is not yet proven against generated GLR",
        .scanner_runtime_plan = python_samples[0..],
        .routine_boundary_decision = "keep full parser-table parity and runtime-link proof deferred until both shallow newline and layout indent/dedent samples pass a real scanner proof",
        .next_action = "use shallow_assignment and layout_if_block as the first Python scanner samples",
    },
    .{
        .id = "tree_sitter_typescript_json",
        .family = .typescript,
        .current_parser_boundary_check_mode = .serialize_only,
        .standalone_probe_status = "passed_coarse_serialize_only",
        .serialized_state_count = 5388,
        .serialized_blocked = true,
        .blocked_surface = "external_scanner_symbols_only",
        .external_scanner_symbol_count = typescript_tokens.len,
        .external_tokens = typescript_tokens[0..],
        .bounded_coarse_proof = "promoted to the bounded routine coarse serialize-only parser proof; blocked=true because JavaScript-family scanner symbols are not yet target-classified for runtime proof",
        .scanner_runtime_plan = typescript_samples[0..],
        .routine_boundary_decision = "keep full parser-table parity and runtime-link proof deferred until the scanner boundary is represented",
        .next_action = "reuse JavaScript scanner classification, then add a bounded TypeScript scanner-runtime proof",
    },
    .{
        .id = "tree_sitter_rust_json",
        .family = .rust,
        .current_parser_boundary_check_mode = .serialize_only,
        .standalone_probe_status = "passed_coarse_serialize_only",
        .serialized_state_count = 2660,
        .serialized_blocked = true,
        .blocked_surface = "external_scanner_symbols_only",
        .external_scanner_symbol_count = rust_tokens.len,
        .external_tokens = rust_tokens[0..],
        .bounded_coarse_proof = "promoted to the bounded routine coarse serialize-only parser proof; blocked=true because string/comment external scanner state is not runtime-linked yet",
        .scanner_runtime_plan = rust_samples[0..],
        .routine_boundary_decision = "keep full parser-table parity and runtime-link proof deferred until string/comment scanner samples have a bounded runtime proof",
        .next_action = "add raw_string for scanner coverage after the current coarse parser proof",
    },
};

pub fn buildDeferredRealGrammarClassification() DeferredRealGrammarClassification {
    return .{
        .schema_version = 1,
        .source_probe = "compat_targets/parser_boundary_probe.json",
        .target_count = entries.len,
        .gate = "JavaScript, Python, TypeScript, and Rust all have bounded routine coarse serialize-only parser proofs; all four still defer full parser-table parity and external-scanner runtime proof",
        .entries = entries[0..],
    };
}

pub fn renderDeferredRealGrammarClassificationAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try json_support.stringifyAlloc(allocator, buildDeferredRealGrammarClassification());
}

fn targetById(id: []const u8) ?targets.Target {
    for (targets.shortlistTargets()) |target| {
        if (std.mem.eql(u8, target.id, id)) return target;
    }
    return null;
}

test "deferred real grammar classification keeps routine parser boundaries conservative" {
    for (entries) |entry| {
        const target = targetById(entry.id) orelse return error.MissingTarget;
        try std.testing.expectEqual(entry.current_parser_boundary_check_mode, target.parser_boundary_check_mode);
        try std.testing.expect(entry.serialized_blocked);
        try std.testing.expectEqualStrings("external_scanner_symbols_only", entry.blocked_surface);
        try std.testing.expect(entry.external_scanner_symbol_count == entry.external_tokens.len);
    }
}

test "deferred Python classification names shallow and layout samples" {
    try std.testing.expectEqualStrings("shallow_assignment", python_samples[0].label);
    try std.testing.expectEqualStrings("layout_if_block", python_samples[1].label);
    try std.testing.expect(std.mem.indexOf(u8, python_samples[1].purpose, "indent and dedent") != null);
}

test "renderDeferredRealGrammarClassificationAlloc matches checked-in artifact" {
    const allocator = std.testing.allocator;

    const rendered = try renderDeferredRealGrammarClassificationAlloc(allocator);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "compat_targets/deferred_real_grammar_classification.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(expected);

    const normalized_expected = std.mem.trimEnd(u8, expected, "\n");
    const normalized_rendered = std.mem.trimEnd(u8, rendered, "\n");
    try std.testing.expectEqualStrings(normalized_expected, normalized_rendered);
}

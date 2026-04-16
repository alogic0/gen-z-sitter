const std = @import("std");

pub const SourceKind = enum {
    grammar_json,
    grammar_js,
};

pub const Target = struct {
    id: []const u8,
    display_name: []const u8,
    grammar_path: []const u8,
    source_kind: SourceKind,
    expected_blocked: bool = false,
    notes: []const u8,
};

pub const staged_targets = [_]Target{
    .{
        .id = "parse_table_tiny_json",
        .display_name = "Parse Table Tiny (JSON)",
        .grammar_path = "compat_targets/parse_table_tiny/grammar.json",
        .source_kind = .grammar_json,
        .expected_blocked = false,
        .notes = "smallest staged parser-only JSON target",
    },
    .{
        .id = "behavioral_config_json",
        .display_name = "Behavioral Config (JSON)",
        .grammar_path = "compat_targets/behavioral_config/grammar.json",
        .source_kind = .grammar_json,
        .expected_blocked = false,
        .notes = "richer scanner-free JSON target",
    },
    .{
        .id = "repeat_choice_seq_js",
        .display_name = "Repeat Choice Seq (JS)",
        .grammar_path = "compat_targets/repeat_choice_seq/grammar.js",
        .source_kind = .grammar_js,
        .expected_blocked = true,
        .notes = "parser-only JS target that exercises the staged blocked boundary",
    },
};

pub fn stagedTargets() []const Target {
    return staged_targets[0..];
}

test "stagedTargets exposes a small versioned shortlist" {
    const shortlist = stagedTargets();
    try std.testing.expectEqual(@as(usize, 3), shortlist.len);
    try std.testing.expect(shortlist[0].source_kind == .grammar_json);
    try std.testing.expect(shortlist[2].source_kind == .grammar_js);
}

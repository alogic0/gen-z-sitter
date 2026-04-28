const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const upstream_summary = @import("../compat/upstream_summary.zig");
const diag = @import("../support/diag.zig");
const fs_support = @import("../support/fs.zig");
const runtime_io = @import("../support/runtime_io.zig");
const fixtures = @import("../tests/fixtures.zig");

pub fn runCompareUpstream(allocator: std.mem.Allocator, io: std.Io, opts: args.CompareUpstreamOptions) !void {
    if (opts.grammar_path.len == 0) return error.InvalidArguments;

    const local = try upstream_summary.generateLocalSummaryAlloc(allocator, opts.grammar_path, .{
        .js_runtime = opts.js_runtime orelse "node",
        .minimize_states = opts.minimize_states,
    });
    defer upstream_summary.deinitSummary(allocator, local);

    const reference = try referenceStatusAlloc(allocator, opts.tree_sitter_dir);
    defer reference.deinit(allocator);

    const report = try renderReportAlloc(allocator, local, reference);
    defer allocator.free(report);

    if (opts.output_dir) |output_dir| {
        try fs_support.ensureDir(output_dir);
        const output_path = try std.fs.path.join(allocator, &.{ output_dir, "local-upstream-summary.json" });
        defer allocator.free(output_path);
        try fs_support.writeFile(output_path, report);
        if (!builtin.is_test) {
            try diag.printStdout(io, .{
                .kind = .info,
                .message = "wrote upstream comparison summary",
                .path = output_path,
            });
        }
        return;
    }

    if (!builtin.is_test) {
        try std.Io.File.stdout().writeStreamingAll(io, report);
    }
}

const ReferenceStatus = struct {
    tree_sitter_dir: []const u8,
    available: bool,
    snapshot_status: []const u8,
    note: []const u8,

    fn deinit(self: ReferenceStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.tree_sitter_dir);
        allocator.free(self.snapshot_status);
        allocator.free(self.note);
    }
};

fn referenceStatusAlloc(allocator: std.mem.Allocator, tree_sitter_dir: []const u8) !ReferenceStatus {
    const render_path = try std.fs.path.join(allocator, &.{ tree_sitter_dir, "crates/generate/src/render.rs" });
    defer allocator.free(render_path);
    const runtime_path = try std.fs.path.join(allocator, &.{ tree_sitter_dir, "lib/src/parser.c" });
    defer allocator.free(runtime_path);

    const has_render = pathExists(render_path);
    const has_runtime = pathExists(runtime_path);
    const available = has_render and has_runtime;
    const note = if (available)
        "upstream checkout found; upstream generation is intentionally not run by this bounded summary command yet"
    else
        "upstream checkout not found or incomplete; summary is local-only";

    return .{
        .tree_sitter_dir = try allocator.dupe(u8, tree_sitter_dir),
        .available = available,
        .snapshot_status = try allocator.dupe(u8, "not_run"),
        .note = try allocator.dupe(u8, note),
    };
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime_io.get(), path, .{}) catch return false;
    return true;
}

fn renderReportAlloc(
    allocator: std.mem.Allocator,
    local: upstream_summary.Summary,
    reference: ReferenceStatus,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n");
    try writer.writeAll("  \"local\":\n");
    try upstream_summary.writeSummaryJson(writer, local, 2);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"upstream\": {\n");
    try writer.writeAll("    \"tree_sitter_dir\": ");
    try writeJsonString(writer, reference.tree_sitter_dir);
    try writer.writeAll(",\n");
    try writer.print("    \"available\": {s},\n", .{if (reference.available) "true" else "false"});
    try writer.writeAll("    \"snapshot_status\": ");
    try writeJsonString(writer, reference.snapshot_status);
    try writer.writeAll(",\n");
    try writer.writeAll("    \"note\": ");
    try writeJsonString(writer, reference.note);
    try writer.writeAll("\n");
    try writer.writeAll("  },\n");
    try writer.writeAll("  \"diffs\": []\n");
    try writer.writeAll("}\n");

    return try out.toOwnedSlice();
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

test "runCompareUpstream writes local summary report" {
    var grammar_tmp = std.testing.tmpDir(.{});
    defer grammar_tmp.cleanup();

    try grammar_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "grammar.json",
        .data = fixtures.validBlankGrammarJson().contents,
    });
    const grammar_path = try grammar_tmp.dir.realPathFileAlloc(std.testing.io, "grammar.json", std.testing.allocator);
    defer std.testing.allocator.free(grammar_path);

    var output_tmp = std.testing.tmpDir(.{});
    defer output_tmp.cleanup();
    const output_path = try output_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(output_path);

    try runCompareUpstream(std.testing.allocator, std.testing.io, .{
        .grammar_path = grammar_path,
        .output_dir = output_path,
        .tree_sitter_dir = "/definitely/missing/tree-sitter",
    });

    const report = try output_tmp.dir.readFileAlloc(std.testing.io, "local-upstream-summary.json", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"upstream\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"available\": false") != null);
}

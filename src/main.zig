const std = @import("std");
const cli_args = @import("cli/args.zig");
const command_generate = @import("cli/command_generate.zig");
const grammar_loader = @import("grammar/loader.zig");
const diag = @import("support/diag.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parsed = cli_args.parseArgs(allocator, argv) catch |err| switch (err) {
        error.InvalidArguments => {
            try diag.printStderr(diag.Diagnostic{
                .kind = .usage,
                .message = cli_args.last_error_message orelse "invalid arguments",
            });
            std.process.exit(2);
        },
        else => return err,
    };

    switch (parsed.command) {
        .help => {
            try std.fs.File.stdout().writeAll(cli_args.helpText());
        },
        .generate => |opts| {
            command_generate.runGenerate(allocator, opts) catch |err| switch (err) {
                error.NotImplemented => {
                    std.process.exit(3);
                },
                error.InvalidArguments => {
                    std.process.exit(2);
                },
                else => {
                    try diag.printStderr(diag.Diagnostic{
                        .kind = .internal,
                        .message = @errorName(err),
                    });
                    std.process.exit(1);
                },
            };
        },
    }
}

test {
    _ = @import("cli/args.zig");
    _ = @import("cli/command_generate.zig");
    _ = @import("grammar/raw_grammar.zig");
    _ = @import("grammar/json_loader.zig");
    _ = @import("grammar/js_loader.zig");
    _ = @import("grammar/validate.zig");
    _ = @import("grammar/loader.zig");
    _ = @import("grammar/parse_grammar.zig");
    _ = @import("grammar/debug_dump.zig");
    _ = @import("grammar/normalize.zig");
    _ = @import("grammar/prepare/extract_tokens.zig");
    _ = @import("grammar/prepare/expand_repeats.zig");
    _ = @import("grammar/prepare/flatten_grammar.zig");
    _ = @import("grammar/prepare/extract_default_aliases.zig");
    _ = @import("ir/symbols.zig");
    _ = @import("ir/rules.zig");
    _ = @import("ir/grammar_ir.zig");
    _ = @import("ir/syntax_grammar.zig");
    _ = @import("ir/lexical_grammar.zig");
    _ = @import("ir/aliases.zig");
    _ = @import("node_types/compute.zig");
    _ = @import("node_types/pipeline.zig");
    _ = @import("node_types/render_json.zig");
    _ = @import("parse_table/item.zig");
    _ = @import("parse_table/first.zig");
    _ = @import("parse_table/actions.zig");
    _ = @import("parse_table/state.zig");
    _ = @import("parse_table/conflicts.zig");
    _ = @import("parse_table/debug_dump.zig");
    _ = @import("parse_table/build.zig");
    _ = @import("parse_table/resolution.zig");
    _ = @import("parse_table/serialize.zig");
    _ = @import("parse_table/pipeline.zig");
    _ = @import("parser_emit/common.zig");
    _ = @import("parser_emit/compat.zig");
    _ = @import("parser_emit/compat_checks.zig");
    _ = @import("parser_emit/parser_tables.zig");
    _ = @import("parser_emit/c_tables.zig");
    _ = @import("parser_emit/parser_c.zig");
    _ = @import("support/diag.zig");
    _ = @import("support/fs.zig");
    _ = @import("support/json.zig");
    _ = @import("support/process.zig");
    _ = @import("support/strings.zig");
    _ = @import("tests/fixtures.zig");
    _ = @import("tests/golden.zig");
}

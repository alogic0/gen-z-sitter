const std = @import("std");
const cli_args = @import("cli/args.zig");
const command_generate = @import("cli/command_generate.zig");
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
                    try diag.printStderr(diag.Diagnostic{
                        .kind = .unimplemented,
                        .message = "generate pipeline scaffolded; grammar loading is not implemented yet",
                    });
                    std.process.exit(3);
                },
                error.InvalidArguments => {
                    try diag.printStderr(diag.Diagnostic{
                        .kind = .usage,
                        .message = "invalid generate options",
                    });
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
    _ = @import("support/diag.zig");
    _ = @import("support/fs.zig");
    _ = @import("support/json.zig");
    _ = @import("support/process.zig");
    _ = @import("support/strings.zig");
    _ = @import("tests/fixtures.zig");
    _ = @import("tests/golden.zig");
}

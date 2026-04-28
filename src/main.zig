const std = @import("std");
const cli_args = @import("cli/args.zig");
const command_compare_upstream = @import("cli/command_compare_upstream.zig");
const command_generate = @import("cli/command_generate.zig");
const grammar_loader = @import("grammar/loader.zig");
const diag = @import("support/diag.zig");
const runtime_io = @import("support/runtime_io.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    runtime_io.set(io, init.minimal.environ);
    const argv_z = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, argv_z.len);
    for (argv_z, 0..) |arg, i| {
        argv[i] = arg;
    }

    const parsed = cli_args.parseArgs(allocator, argv) catch |err| switch (err) {
        error.InvalidArguments => {
            try diag.printStderr(io, diag.Diagnostic{
                .kind = .usage,
                .message = cli_args.last_error_message orelse "invalid arguments",
            });
            std.process.exit(2);
        },
    };

    switch (parsed.command) {
        .help => {
            try std.Io.File.stdout().writeStreamingAll(io, cli_args.helpText());
        },
        .generate => |opts| {
            command_generate.runGenerate(allocator, io, opts) catch |err| switch (err) {
                error.InvalidArguments => {
                    std.process.exit(2);
                },
                else => {
                    try diag.printStderr(io, diag.Diagnostic{
                        .kind = .internal,
                        .message = @errorName(err),
                    });
                    std.process.exit(1);
                },
            };
        },
        .compare_upstream => |opts| {
            command_compare_upstream.runCompareUpstream(allocator, io, opts) catch |err| switch (err) {
                error.InvalidArguments => {
                    std.process.exit(2);
                },
                else => {
                    try diag.printStderr(io, diag.Diagnostic{
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
    _ = @import("fast_test_entry.zig");
}

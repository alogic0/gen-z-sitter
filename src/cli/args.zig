const std = @import("std");

pub threadlocal var last_error_message: ?[]const u8 = null;

pub const Cli = struct {
    command: Command,
};

pub const Command = union(enum) {
    help,
    generate: GenerateOptions,
};

pub const GenerateOptions = struct {
    grammar_path: []const u8,
    output_dir: ?[]const u8 = null,
    abi_version: u32 = 15,
    no_parser: bool = false,
    emit_parser_c: bool = false,
    glr_loop: bool = false,
    json_summary: bool = false,
    debug_prepared: bool = false,
    debug_node_types: bool = false,
    report_states_for_rule: ?[]const u8 = null,
    js_runtime: ?[]const u8 = null,
    optimize_merge_states: bool = true,
    minimize_states: bool = false,
    strict_expected_conflicts: bool = false,
};

pub const ParseError = error{
    InvalidArguments,
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Cli {
    _ = allocator;
    last_error_message = null;

    if (argv.len <= 1) {
        return Cli{ .command = .help };
    }

    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return Cli{ .command = .help };
    }
    if (std.mem.eql(u8, cmd, "generate")) {
        return Cli{ .command = .{ .generate = try parseGenerateArgs(argv[2..]) } };
    }

    last_error_message = "unknown command";
    return error.InvalidArguments;
}

fn parseGenerateArgs(args: []const []const u8) ParseError!GenerateOptions {
    var opts = GenerateOptions{
        .grammar_path = "",
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            last_error_message = "help requested for generate; use `zig build run -- help` for now";
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--no-parser")) {
            opts.no_parser = true;
        } else if (std.mem.eql(u8, arg, "--emit-parser-c")) {
            opts.emit_parser_c = true;
        } else if (std.mem.eql(u8, arg, "--glr-loop")) {
            opts.glr_loop = true;
        } else if (std.mem.eql(u8, arg, "--json-summary")) {
            opts.json_summary = true;
        } else if (std.mem.eql(u8, arg, "--debug-prepared")) {
            opts.debug_prepared = true;
        } else if (std.mem.eql(u8, arg, "--debug-node-types")) {
            opts.debug_node_types = true;
        } else if (std.mem.eql(u8, arg, "--no-optimize-merge-states")) {
            opts.optimize_merge_states = false;
        } else if (std.mem.eql(u8, arg, "--minimize")) {
            opts.minimize_states = true;
        } else if (std.mem.eql(u8, arg, "--strict-expected-conflicts")) {
            opts.strict_expected_conflicts = true;
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                last_error_message = "missing value for --output";
                return error.InvalidArguments;
            }
            opts.output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--abi")) {
            i += 1;
            if (i >= args.len) {
                last_error_message = "missing value for --abi";
                return error.InvalidArguments;
            }
            opts.abi_version = std.fmt.parseUnsigned(u32, args[i], 10) catch {
                last_error_message = "invalid integer passed to --abi";
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--report-states-for-rule")) {
            i += 1;
            if (i >= args.len) {
                last_error_message = "missing value for --report-states-for-rule";
                return error.InvalidArguments;
            }
            opts.report_states_for_rule = args[i];
        } else if (std.mem.eql(u8, arg, "--js-runtime")) {
            i += 1;
            if (i >= args.len) {
                last_error_message = "missing value for --js-runtime";
                return error.InvalidArguments;
            }
            opts.js_runtime = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            last_error_message = "unknown generate flag";
            return error.InvalidArguments;
        } else if (opts.grammar_path.len == 0) {
            opts.grammar_path = arg;
        } else {
            last_error_message = "generate accepts only one grammar path";
            return error.InvalidArguments;
        }
    }

    if (opts.grammar_path.len == 0) {
        last_error_message = "missing grammar path";
        return error.InvalidArguments;
    }

    return opts;
}

pub fn helpText() []const u8 {
    return
    \\gen-z-sitter
    \\Zig implementation of the tree-sitter generator pipeline.
    \\
    \\Usage:
    \\  gen-z-sitter help
    \\  gen-z-sitter generate [options] <grammar-path>
    \\
    \\Common examples:
    \\  gen-z-sitter generate grammar.json
    \\  gen-z-sitter generate --output out grammar.json
    \\  gen-z-sitter generate --output out --emit-parser-c grammar.json
    \\  gen-z-sitter generate --json-summary grammar.json
    \\  gen-z-sitter generate --json-summary --minimize grammar.json
    \\  gen-z-sitter generate --output out --emit-parser-c --glr-loop grammar.json
    \\
    \\Generate options:
    \\  --output <dir>                 Write generated artifacts into <dir>.
    \\  --abi <version>                Select the target ABI version; currently only 15 is supported.
    \\  --no-parser                    Skip parser.c output when generating artifacts.
    \\  --emit-parser-c                Write parser.c into --output <dir>.
    \\  --glr-loop                     Enable the experimental generated GLR loop in parser.c.
    \\  --json-summary                 Print parser-emission and optimization statistics as JSON.
    \\  --debug-prepared               Print prepared grammar IR.
    \\  --debug-node-types             Print node-types.json.
    \\  --report-states-for-rule <rule> Reserved parser-table diagnostic flag.
    \\  --js-runtime <runtime>         Runtime command used for grammar.js loading, default: node.
    \\  --no-optimize-merge-states     Disable emitted duplicate-state compaction in summary paths.
    \\  --minimize                     Enable parse-table minimization for summary paths.
    \\  --strict-expected-conflicts    Fail when declared conflicts are unused.
    \\
    \\Current limits:
    \\  emitted grammar.json and compatibility reports are exercised through tests and build/debug targets rather than as stable CLI outputs.
    \\
    ;
}

test "parse help when no subcommand is provided" {
    const cli = try parseArgs(std.testing.allocator, &.{"gen-z-sitter"});
    try std.testing.expect(cli.command == .help);
}

test "parse generate command with required grammar path" {
    const cli = try parseArgs(std.testing.allocator, &.{ "gen-z-sitter", "generate", "grammar.json" });
    try std.testing.expect(cli.command == .generate);
    try std.testing.expectEqualStrings("grammar.json", cli.command.generate.grammar_path);
    try std.testing.expectEqual(@as(u32, 15), cli.command.generate.abi_version);
}

test "parse generate command with debug prepared flag" {
    const cli = try parseArgs(std.testing.allocator, &.{ "gen-z-sitter", "generate", "--debug-prepared", "grammar.json" });
    try std.testing.expect(cli.command == .generate);
    try std.testing.expect(cli.command.generate.debug_prepared);
}

test "parse generate command with debug node types flag" {
    const cli = try parseArgs(std.testing.allocator, &.{ "gen-z-sitter", "generate", "--debug-node-types", "grammar.json" });
    try std.testing.expect(cli.command == .generate);
    try std.testing.expect(cli.command.generate.debug_node_types);
}

test "parse generate command with strict expected conflicts flag" {
    const cli = try parseArgs(std.testing.allocator, &.{ "gen-z-sitter", "generate", "--strict-expected-conflicts", "grammar.json" });
    try std.testing.expect(cli.command == .generate);
    try std.testing.expect(cli.command.generate.strict_expected_conflicts);
}

test "parse generate command with parser C and GLR flags" {
    const cli = try parseArgs(std.testing.allocator, &.{ "gen-z-sitter", "generate", "--output", "out", "--emit-parser-c", "--glr-loop", "grammar.json" });
    try std.testing.expect(cli.command == .generate);
    try std.testing.expectEqualStrings("out", cli.command.generate.output_dir.?);
    try std.testing.expect(cli.command.generate.emit_parser_c);
    try std.testing.expect(cli.command.generate.glr_loop);
}

test "parse generate command with minimize flag" {
    const cli = try parseArgs(std.testing.allocator, &.{ "gen-z-sitter", "generate", "--minimize", "grammar.json" });
    try std.testing.expect(cli.command == .generate);
    try std.testing.expect(cli.command.generate.minimize_states);
}

test "reject missing grammar path" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(std.testing.allocator, &.{ "gen-z-sitter", "generate" }));
    try std.testing.expect(last_error_message != null);
}

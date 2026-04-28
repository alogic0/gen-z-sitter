const std = @import("std");

const custom_step_names = [_][]const u8{
    "run-generate-smoke",
    "run-minimize-report",
    "run-phase5-profile",
    "run-zig-runtime-link-profile",
    "test-build-config",
    "test-release",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name substring");
    const compat_target = b.option([]const u8, "compat-target", "Compatibility target id for run-compat-target");
    const compat_stop_after = b.option([]const u8, "compat-stop-after", "Stop run-compat-target after this stage");
    const upstream_compare_grammar = b.option([]const u8, "upstream-compare-grammar", "Grammar path for run-compare-upstream");
    const upstream_compare_output = b.option([]const u8, "upstream-compare-output", "Output directory for run-compare-upstream");
    const upstream_compare_report_states_for_rule = b.option([]const u8, "upstream-compare-report-states-for-rule", "Rule name for filtered parse-states artifact in run-compare-upstream");
    const tree_sitter_dir = b.option([]const u8, "tree-sitter-dir", "Reference tree-sitter checkout for run-compare-upstream");

    const exe = b.addExecutable(.{
        .name = "gen-z-sitter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the gen-z-sitter executable");
    run_step.dependOn(&run_cmd.step);

    const generate_smoke_cmd = b.addRunArtifact(exe);
    generate_smoke_cmd.addArgs(&.{
        "generate",
        "--json-summary",
        "compat_targets/parse_table_tiny/grammar.json",
    });
    const generate_smoke_step = b.step("run-generate-smoke", "Run a bounded generator smoke check on a tiny grammar");
    generate_smoke_step.dependOn(&generate_smoke_cmd.step);

    const compare_upstream_cmd = b.addRunArtifact(exe);
    compare_upstream_cmd.addArg("compare-upstream");
    compare_upstream_cmd.addArg("--output");
    compare_upstream_cmd.addArg(upstream_compare_output orelse ".zig-cache/upstream-compare");
    compare_upstream_cmd.addArg("--tree-sitter-dir");
    compare_upstream_cmd.addArg(tree_sitter_dir orelse "../tree-sitter");
    if (upstream_compare_report_states_for_rule) |rule_name| {
        compare_upstream_cmd.addArg("--report-states-for-rule");
        compare_upstream_cmd.addArg(rule_name);
    }
    compare_upstream_cmd.addArg(upstream_compare_grammar orelse "compat_targets/tree_sitter_json/grammar.json");
    const compare_upstream_step = b.step("run-compare-upstream", "Write a bounded local/upstream comparison summary for one grammar");
    compare_upstream_step.dependOn(&compare_upstream_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/fast_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_tests = b.addRunArtifact(unit_tests);
    if (b.args) |args| run_tests.addArgs(args);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const build_config_tests = b.addTest(.{
        .root_module = createTestModule(b, "build.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_build_config_tests = b.addRunArtifact(build_config_tests);
    if (b.args) |args| run_build_config_tests.addArgs(args);
    const build_config_test_step = b.step("test-build-config", "Run build configuration tests");
    build_config_test_step.dependOn(&run_build_config_tests.step);

    const pt_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/parse_table_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_pt_tests = b.addRunArtifact(pt_tests);
    if (b.args) |args| run_pt_tests.addArgs(args);
    const pt_test_step = b.step("test-pt", "Run parse_table unit tests only");
    pt_test_step.dependOn(&run_pt_tests.step);

    const pipeline_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/pipeline_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_pipeline_tests = b.addRunArtifact(pipeline_tests);
    if (b.args) |args| run_pipeline_tests.addArgs(args);
    const pipeline_test_step = b.step("test-pipeline", "Run pipeline integration and golden tests");
    pipeline_test_step.dependOn(&run_pipeline_tests.step);

    const cli_generate_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/cli_generate_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_cli_generate_tests = b.addRunArtifact(cli_generate_tests);
    if (b.args) |args| run_cli_generate_tests.addArgs(args);
    const cli_generate_test_step = b.step("test-cli-generate", "Run CLI generate integration tests");
    cli_generate_test_step.dependOn(&run_cli_generate_tests.step);

    const behavioral_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/behavioral_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_behavioral_tests = b.addRunArtifact(behavioral_tests);
    if (b.args) |args| run_behavioral_tests.addArgs(args);
    const behavioral_test_step = b.step("test-behavioral", "Run behavioral harness tests only");
    behavioral_test_step.dependOn(&run_behavioral_tests.step);

    const compat_heavy_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/compat_heavy_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"compat."},
    });

    const run_compat_heavy_tests = b.addRunArtifact(compat_heavy_tests);
    if (b.args) |args| run_compat_heavy_tests.addArgs(args);
    const compat_heavy_test_step = b.step("test-compat-heavy", "Run bounded compatibility metadata and smoke tests");
    compat_heavy_test_step.dependOn(&run_compat_heavy_tests.step);

    const compat_full_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/compat_full_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"compat."},
    });

    const run_compat_full_tests = b.addRunArtifact(compat_full_tests);
    if (b.args) |args| run_compat_full_tests.addArgs(args);
    const compat_full_test_step = b.step("test-compat-full", "Run full compatibility harness and inventory tests");
    compat_full_test_step.dependOn(&run_compat_full_tests.step);

    const default_runtime_link_filters = &.{
        "linkAndRunNoExternalTinyParser",
        "linkAndRunNoExternalTinyGlrParser",
        "linkAndRunNoExternalTinyGlrResultParser",
        "linkAndRunGeneratedStatusAccessors",
        "linkAndRunUnresolvedShiftReduceGlrParser",
        "linkAndRecoverMalformedTinyGlrParser",
        "linkAndRunKeywordReservedParser",
        "linkAndRunExternalScannerParser",
        "linkAndRunExternalScannerGlrParser",
        "linkAndRunMultiTokenExternalScannerParser",
        "linkAndRunMultiTokenExternalScannerGlrParser",
        "linkAndRunStatefulExternalScannerParser",
        "linkAndRunForkedStatefulExternalScannerGlrParser",
        "linkAndRunBracketLangParser",
        "linkAndRunTreeSitterJsonParserAcceptedSample",
        "linkAndRunTreeSitterJsonParserInvalidSample",
        "linkAndRunTreeSitterZiggyParserAcceptedSample",
        "linkAndRunTreeSitterZiggyParserInvalidSample",
        "linkAndRunTreeSitterZiggySchemaParserAcceptedSample",
        "linkAndRunTreeSitterZigParserAcceptedSample",
        "linkAndRunBashParserWithRealExternalScanner",
        "linkAndRunBashGeneratedGlrParserWithRealExternalScanner",
        "linkAndRunJavascriptTernaryParserWithRealExternalScanner",
        "linkAndRunJavascriptTernaryGeneratedGlrParserWithRealExternalScanner",
        "linkAndRunTypescriptTernaryParserWithRealExternalScanner",
        "linkAndRunPythonNewlineParserWithRealExternalScanner",
        "linkAndRunRustFloatLiteralParserWithRealExternalScanner",
        "linkAndRunRustRawStringParserWithRealExternalScanner",
        "linkAndRunHaskellParserWithRealExternalScanner",
        "linkAndRunHaskellGeneratedGlrParserWithRealExternalScanner",
    };
    const no_external_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunNoExternalTinyParser"},
    });

    const run_no_external_link_tests = b.addRunArtifact(no_external_link_tests);
    if (b.args) |args| run_no_external_link_tests.addArgs(args);
    const no_external_link_step = b.step("test-link-no-external", "Link and run a generated no-external parser with tree-sitter runtime");
    no_external_link_step.dependOn(&run_no_external_link_tests.step);

    const keyword_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunKeywordReservedParser"},
    });

    const run_keyword_link_tests = b.addRunArtifact(keyword_link_tests);
    if (b.args) |args| run_keyword_link_tests.addArgs(args);
    const keyword_link_step = b.step("test-link-keywords", "Link and run a generated keyword/reserved-word parser with tree-sitter runtime");
    keyword_link_step.dependOn(&run_keyword_link_tests.step);

    const external_scanner_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunExternalScannerParser"},
    });

    const run_external_scanner_link_tests = b.addRunArtifact(external_scanner_link_tests);
    if (b.args) |args| run_external_scanner_link_tests.addArgs(args);
    const external_scanner_link_step = b.step("test-link-external-scanner", "Link and run a generated external-scanner parser with tree-sitter runtime");
    external_scanner_link_step.dependOn(&run_external_scanner_link_tests.step);

    const multi_token_scanner_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunMultiTokenExternalScannerParser"},
    });

    const run_multi_token_scanner_link_tests = b.addRunArtifact(multi_token_scanner_link_tests);
    if (b.args) |args| run_multi_token_scanner_link_tests.addArgs(args);
    const multi_token_scanner_link_step = b.step("test-link-multi-token-scanner", "Link and run a generated multi-token external-scanner parser with tree-sitter runtime");
    multi_token_scanner_link_step.dependOn(&run_multi_token_scanner_link_tests.step);

    const stateful_scanner_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunStatefulExternalScannerParser"},
    });

    const run_stateful_scanner_link_tests = b.addRunArtifact(stateful_scanner_link_tests);
    if (b.args) |args| run_stateful_scanner_link_tests.addArgs(args);
    const stateful_scanner_link_step = b.step("test-link-stateful-scanner", "Link and run a generated stateful external-scanner parser with tree-sitter runtime");
    stateful_scanner_link_step.dependOn(&run_stateful_scanner_link_tests.step);

    const bracket_lang_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunBracketLangParser"},
    });

    const run_bracket_lang_link_tests = b.addRunArtifact(bracket_lang_link_tests);
    if (b.args) |args| run_bracket_lang_link_tests.addArgs(args);
    const bracket_lang_link_step = b.step("test-link-bracket-lang", "Link and run generated bracket-lang parser with tree-sitter runtime");
    bracket_lang_link_step.dependOn(&run_bracket_lang_link_tests.step);

    const bash_real_scanner_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunBashParserWithRealExternalScanner"},
    });

    const run_bash_real_scanner_link_tests = b.addRunArtifact(bash_real_scanner_link_tests);
    if (b.args) |args| run_bash_real_scanner_link_tests.addArgs(args);
    const bash_real_scanner_link_step = b.step("test-link-bash-real-scanner", "Link and run a generated Bash parser with the real external scanner");
    bash_real_scanner_link_step.dependOn(&run_bash_real_scanner_link_tests.step);

    const haskell_real_scanner_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunHaskellParserWithRealExternalScanner"},
    });

    const run_haskell_real_scanner_link_tests = b.addRunArtifact(haskell_real_scanner_link_tests);
    if (b.args) |args| run_haskell_real_scanner_link_tests.addArgs(args);
    const haskell_real_scanner_link_step = b.step("test-link-haskell-real-scanner", "Link and run a generated Haskell parser with the real external scanner");
    haskell_real_scanner_link_step.dependOn(&run_haskell_real_scanner_link_tests.step);

    const runtime_link_tests = b.addTest(.{
        .root_module = createTestModule(b, "src/runtime_link_test_entry.zig", target, optimize),
        .filters = if (test_filter) |f| &.{f} else default_runtime_link_filters,
    });

    const run_runtime_link_tests = b.addRunArtifact(runtime_link_tests);
    if (b.args) |args| run_runtime_link_tests.addArgs(args);
    const runtime_link_step = b.step("test-link-runtime", "Link and run generated parser fixtures with tree-sitter runtime");
    runtime_link_step.dependOn(&run_runtime_link_tests.step);

    const compat_target_runner = b.addExecutable(.{
        .name = "compat-target-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/debug_compat_target_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_compat_target = b.addRunArtifact(compat_target_runner);
    run_compat_target.addArg(compat_target orelse "parse_table_tiny_json");
    if (compat_stop_after) |stage| {
        run_compat_target.addArg("--stop-after");
        run_compat_target.addArg(stage);
    }
    if (b.args) |args| run_compat_target.addArgs(args);
    const compat_target_step = b.step("run-compat-target", "Run one compatibility target through the harness");
    compat_target_step.dependOn(&run_compat_target.step);

    const zig_runtime_profile_runner = b.addExecutable(.{
        .name = "zig-runtime-link-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/debug_zig_runtime_link_profile.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zig_runtime_profile = b.addRunArtifact(zig_runtime_profile_runner);
    const zig_runtime_profile_step = b.step("run-zig-runtime-link-profile", "Profile the tree_sitter_zig_json runtime-link path");
    zig_runtime_profile_step.dependOn(&run_zig_runtime_profile.step);

    const phase5_profile_runner = b.addExecutable(.{
        .name = "phase5-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/debug_phase5_profile.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_phase5_profile = b.addRunArtifact(phase5_profile_runner);
    if (b.args) |args| run_phase5_profile.addArgs(args);
    const phase5_profile_step = b.step("run-phase5-profile", "Profile Phase 5 real grammar construction, serialization, emission, and MaxRSS");
    phase5_profile_step.dependOn(&run_phase5_profile.step);

    const minimize_report_runner = b.addExecutable(.{
        .name = "minimize-report-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/debug_minimize_report.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_minimize_report = b.addRunArtifact(minimize_report_runner);
    if (b.args) |args| run_minimize_report.addArgs(args);
    const minimize_report_step = b.step("run-minimize-report", "Print bounded parse-table minimization JSON report");
    minimize_report_step.dependOn(&run_minimize_report.step);

    const release_test_step = b.step("test-release", "Run accepted bounded release-readiness gates");
    release_test_step.dependOn(&run_tests.step);
    release_test_step.dependOn(&run_build_config_tests.step);
    release_test_step.dependOn(&run_cli_generate_tests.step);
    release_test_step.dependOn(&run_pipeline_tests.step);
    release_test_step.dependOn(&run_runtime_link_tests.step);
    release_test_step.dependOn(&run_compat_heavy_tests.step);
    release_test_step.dependOn(&generate_smoke_cmd.step);
}

test "custom build steps stay documented" {
    try std.testing.expect(std.mem.eql(u8, custom_step_names[0], "run-generate-smoke"));
    try std.testing.expect(std.mem.eql(u8, custom_step_names[1], "run-minimize-report"));
    try std.testing.expect(std.mem.eql(u8, custom_step_names[2], "run-phase5-profile"));
    try std.testing.expect(std.mem.eql(u8, custom_step_names[3], "run-zig-runtime-link-profile"));
    try std.testing.expect(std.mem.eql(u8, custom_step_names[4], "test-build-config"));
    try std.testing.expect(std.mem.eql(u8, custom_step_names[5], "test-release"));
}

fn createTestModule(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
    return module;
}

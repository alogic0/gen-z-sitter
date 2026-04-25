const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name substring");

    const exe = b.addExecutable(.{
        .name = "zig-tree-sit",
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

    const run_step = b.step("run", "Run the zig-tree-sit executable");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_tests = b.addRunArtifact(unit_tests);
    if (b.args) |args| run_tests.addArgs(args);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const pt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parse_table_test_entry.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_pt_tests = b.addRunArtifact(pt_tests);
    if (b.args) |args| run_pt_tests.addArgs(args);
    const pt_test_step = b.step("test-pt", "Run parse_table unit tests only");
    pt_test_step.dependOn(&run_pt_tests.step);

    const behavioral_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/behavioral_test_entry.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_behavioral_tests = b.addRunArtifact(behavioral_tests);
    if (b.args) |args| run_behavioral_tests.addArgs(args);
    const behavioral_test_step = b.step("test-behavioral", "Run behavioral harness tests only");
    behavioral_test_step.dependOn(&run_behavioral_tests.step);

    const default_runtime_link_filters = &.{
        "linkAndRunNoExternalTinyParser",
        "linkAndRunKeywordReservedParser",
        "linkAndRunExternalScannerParser",
    };
    const no_external_link_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_link_test_entry.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |f| &.{f} else &.{"linkAndRunNoExternalTinyParser"},
    });

    const run_no_external_link_tests = b.addRunArtifact(no_external_link_tests);
    if (b.args) |args| run_no_external_link_tests.addArgs(args);
    const no_external_link_step = b.step("test-link-no-external", "Link and run a generated no-external parser with tree-sitter runtime");
    no_external_link_step.dependOn(&run_no_external_link_tests.step);

    const runtime_link_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_link_test_entry.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |f| &.{f} else default_runtime_link_filters,
    });

    const run_runtime_link_tests = b.addRunArtifact(runtime_link_tests);
    if (b.args) |args| run_runtime_link_tests.addArgs(args);
    const runtime_link_step = b.step("test-link-runtime", "Link and run generated parser fixtures with tree-sitter runtime");
    runtime_link_step.dependOn(&run_runtime_link_tests.step);
}

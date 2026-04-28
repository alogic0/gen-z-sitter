const std = @import("std");
const process_support = @import("../support/process.zig");
const runtime_io = @import("../support/runtime_io.zig");

pub const CompileSmokeError = anyerror;

pub const CompileSmokeSuccess = struct {
    max_rss_bytes: ?usize = null,
};

pub const CompileSmokeResult = union(enum) {
    success: CompileSmokeSuccess,
    compiler_error: []u8,

    pub fn deinit(self: *CompileSmokeResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => {},
            .compiler_error => |stderr| allocator.free(stderr),
        }
        self.* = undefined;
    }
};

pub fn compileParserC(allocator: std.mem.Allocator, contents: []const u8) CompileSmokeError!CompileSmokeResult {
    const timestamp = std.Io.Timestamp.now(runtime_io.get(), .awake);
    const tmp_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/compat-smoke-{d}",
        .{timestamp.nanoseconds},
    );
    defer allocator.free(tmp_path);
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), tmp_path);
    defer std.Io.Dir.cwd().deleteTree(runtime_io.get(), tmp_path) catch {};

    var tmp_dir = try std.Io.Dir.cwd().openDir(runtime_io.get(), tmp_path, .{});
    defer tmp_dir.close(runtime_io.get());

    try tmp_dir.writeFile(runtime_io.get(), .{
        .sub_path = "parser.c",
        .data = contents,
    });

    const source_path = try tmp_dir.realPathFileAlloc(runtime_io.get(), "parser.c", allocator);
    defer allocator.free(source_path);

    const dir_path = try tmp_dir.realPathFileAlloc(runtime_io.get(), ".", allocator);
    defer allocator.free(dir_path);

    const object_path = try std.fs.path.join(allocator, &.{ dir_path, "parser.o" });
    defer allocator.free(object_path);

    var child_result = try process_support.runCaptureWithOptions(
        allocator,
        &.{ "zig", "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-c", source_path, "-o", object_path },
        .{ .request_resource_usage_statistics = true },
    );
    defer child_result.deinit(allocator);

    return switch (child_result.term) {
        .exited => |code| if (code == 0)
            .{ .success = .{ .max_rss_bytes = child_result.max_rss_bytes } }
        else
            .{ .compiler_error = try allocator.dupe(u8, child_result.stderr) },
        else => error.UnexpectedCompilerTermination,
    };
}

test "compileParserC compiles a minimal C translation unit" {
    const allocator = std.testing.allocator;
    var result = try compileParserC(allocator,
        \\int main(void) { return 0; }
    );
    defer result.deinit(allocator);

    switch (result) {
        .success => |success| try std.testing.expect(success.max_rss_bytes != null),
        else => return error.TestUnexpectedCompileSmokeFailure,
    }
}

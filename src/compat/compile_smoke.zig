const std = @import("std");
const process_support = @import("../support/process.zig");

pub const CompileSmokeError = anyerror;

pub const CompileSmokeResult = union(enum) {
    success,
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "parser.c",
        .data = contents,
    });

    const source_path = try tmp.dir.realpathAlloc(allocator, "parser.c");
    defer allocator.free(source_path);

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const object_path = try std.fs.path.join(allocator, &.{ dir_path, "parser.o" });
    defer allocator.free(object_path);

    var child_result = try process_support.runCapture(
        allocator,
        &.{ "zig", "cc", "-std=c11", "-c", source_path, "-o", object_path },
    );
    defer child_result.deinit(allocator);

    return switch (child_result.term) {
        .Exited => |code| if (code == 0)
            .success
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

    try std.testing.expect(result == .success);
}

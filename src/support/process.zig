const std = @import("std");
const runtime_io = @import("runtime_io.zig");

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    const result = try std.process.run(allocator, runtime_io.get(), .{
        .argv = argv,
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

test "runCapture can execute a simple process" {
    const allocator = std.testing.allocator;
    var result = try runCapture(allocator, &.{"sh", "-c", "printf ok"});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("ok", result.stdout);
}

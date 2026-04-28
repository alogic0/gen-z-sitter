const std = @import("std");
const runtime_io = @import("runtime_io.zig");

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    max_rss_bytes: ?usize = null,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const RunCaptureOptions = struct {
    request_resource_usage_statistics: bool = false,
};

pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    return runCaptureWithOptions(allocator, argv, .{});
}

pub fn runCaptureWithOptions(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: RunCaptureOptions,
) !RunResult {
    const io = runtime_io.get();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .request_resource_usage_statistics = options.request_resource_usage_statistics,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);

    const max_rss_bytes = if (options.request_resource_usage_statistics)
        child.resource_usage_statistics.getMaxRss()
    else
        null;

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .term = term,
        .max_rss_bytes = max_rss_bytes,
    };
}

test "runCapture can execute a simple process" {
    const allocator = std.testing.allocator;
    var result = try runCapture(allocator, &.{ "sh", "-c", "printf ok" });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("ok", result.stdout);
}

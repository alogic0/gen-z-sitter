const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    info,
    usage,
    io,
    unimplemented,
    internal,
};

pub const Diagnostic = struct {
    kind: Kind,
    message: []const u8,
    path: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub fn printStdout(io: std.Io, d: Diagnostic) !void {
    if (builtin.is_test) return;
    try printToFile(std.Io.File.stdout(), io, d);
}

pub fn printStderr(io: std.Io, d: Diagnostic) !void {
    if (builtin.is_test) return;
    try printToFile(std.Io.File.stderr(), io, d);
}

pub fn print(writer: anytype, d: Diagnostic) !void {
    try writer.print("{s}: {s}\n", .{ kindLabel(d.kind), d.message });
    if (d.path) |path| {
        try writer.print("path: {s}\n", .{path});
    }
    if (d.note) |note| {
        try writer.print("note: {s}\n", .{note});
    }
}

fn printToFile(file: std.Io.File, io: std.Io, d: Diagnostic) !void {
    var buffer: [256]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try print(&file_writer.interface, d);
    try file_writer.interface.flush();
}

fn kindLabel(kind: Kind) []const u8 {
    return switch (kind) {
        .info => "info",
        .usage => "usage",
        .io => "io",
        .unimplemented => "unimplemented",
        .internal => "internal",
    };
}

test "diagnostic rendering includes message and note" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try print(&buffer.writer, .{
        .kind = .info,
        .message = "hello",
        .note = "world",
    });

    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "world") != null);
}

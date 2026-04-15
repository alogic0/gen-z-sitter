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

pub fn printStdout(d: Diagnostic) !void {
    if (builtin.is_test) return;
    try printToFile(std.fs.File.stdout(), d);
}

pub fn printStderr(d: Diagnostic) !void {
    if (builtin.is_test) return;
    try printToFile(std.fs.File.stderr(), d);
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

fn printToFile(file: std.fs.File, d: Diagnostic) !void {
    try file.writeAll(kindLabel(d.kind));
    try file.writeAll(": ");
    try file.writeAll(d.message);
    try file.writeAll("\n");
    if (d.path) |path| {
        try file.writeAll("path: ");
        try file.writeAll(path);
        try file.writeAll("\n");
    }
    if (d.note) |note| {
        try file.writeAll("note: ");
        try file.writeAll(note);
        try file.writeAll("\n");
    }
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

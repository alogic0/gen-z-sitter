const std = @import("std");
const builtin = @import("builtin");

var current_io: ?std.Io = null;
var current_environ: ?std.process.Environ = null;

pub fn set(io: std.Io, process_environ: std.process.Environ) void {
    current_io = io;
    current_environ = process_environ;
}

pub fn get() std.Io {
    if (builtin.is_test) return std.testing.io;
    return current_io orelse @panic("runtime io not initialized");
}

pub fn environ() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return current_environ orelse @panic("runtime environ not initialized");
}

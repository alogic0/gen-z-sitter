const std = @import("std");
const runtime_link = @import("compat/runtime_link.zig");
const runtime_io = @import("support/runtime_io.zig");

pub fn main(init: std.process.Init) !void {
    runtime_io.set(init.io, init.minimal.environ);
    try runtime_link.profileTreeSitterZigRuntimeLinkCandidate(init.gpa);
}

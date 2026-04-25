const std = @import("std");

test {
    _ = @import("parse_table/pipeline.zig");
    _ = @import("lexer/pipeline.zig");
    _ = @import("scanner/pipeline.zig");
    _ = @import("node_types/pipeline.zig");
}

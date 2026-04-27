const std = @import("std");

test {
    _ = @import("parse_table/item.zig");
    _ = @import("parse_table/first.zig");
    _ = @import("parse_table/actions.zig");
    _ = @import("parse_table/state.zig");
    _ = @import("parse_table/conflicts.zig");
    _ = @import("parse_table/conflict_resolution.zig");
    _ = @import("parse_table/resolution.zig");
    _ = @import("parse_table/serialize.zig");
    _ = @import("parse_table/minimize.zig");
}

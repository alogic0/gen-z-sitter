const std = @import("std");
const compute = @import("compute.zig");

pub const RenderJsonError = error{
    OutOfMemory,
} || std.fs.File.WriteError;

pub fn renderNodeTypesJson(
    writer: anytype,
    nodes: []const compute.NodeType,
) RenderJsonError!void {
    try writer.writeAll("[\n");
    for (nodes, 0..) |node, i| {
        try writer.writeAll("  {\n");
        try writeJsonField(writer, "type", node.kind, true);
        try writer.print("    \"named\": {}", .{node.named});

        if (node.root) {
            try writer.writeAll(",\n");
            try writer.print("    \"root\": {}", .{node.root});
        }

        if (node.extra) {
            try writer.writeAll(",\n");
            try writer.print("    \"extra\": {}", .{node.extra});
        }

        if (node.fields.len > 0) {
            try writer.writeAll(",\n");
            try renderFields(writer, node.fields);
        }

        if (node.children) |children| {
            if (children.types.len > 0) {
                try writer.writeAll(",\n");
                try renderChildInfoField(writer, "children", children);
            }
        }

        if (node.subtypes.len > 0) {
            try writer.writeAll(",\n");
            try renderSubtypes(writer, node.subtypes);
        }

        try writer.writeAll("\n  }");
        if (i + 1 != nodes.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("]\n");
}

pub fn renderNodeTypesJsonAlloc(
    allocator: std.mem.Allocator,
    nodes: []const compute.NodeType,
) RenderJsonError![]const u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    try renderNodeTypesJson(list.writer(), nodes);
    return try list.toOwnedSlice();
}

fn renderFields(writer: anytype, fields: []const compute.Field) RenderJsonError!void {
    try writer.writeAll("    \"fields\": {\n");
    for (fields, 0..) |field, i| {
        try writer.print("      \"{s}\": ", .{field.name});
        try renderChildInfo(writer, field.info, 6);
        if (i + 1 != fields.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("    }");
}

fn renderChildInfoField(
    writer: anytype,
    name: []const u8,
    info: compute.ChildInfo,
) RenderJsonError!void {
    try writer.print("    \"{s}\": ", .{name});
    try renderChildInfo(writer, info, 4);
}

fn renderChildInfo(writer: anytype, info: compute.ChildInfo, indent: usize) RenderJsonError!void {
    _ = indent;
    try writer.writeAll("{\n");
    try writer.print("      \"multiple\": {},\n", .{info.quantity.multiple});
    try writer.print("      \"required\": {},\n", .{info.quantity.required});
    try writer.writeAll("      \"types\": [\n");
    for (info.types, 0..) |ty, i| {
        try writer.writeAll("        {\n");
        try writeJsonField(writer, "type", ty.kind, false);
        try writer.writeAll(",\n");
        try writer.print("          \"named\": {}\n", .{ty.named});
        try writer.writeAll("        }");
        if (i + 1 != info.types.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("      ]\n");
    try writer.writeAll("    }");
}

fn renderSubtypes(writer: anytype, subtypes: []const compute.NodeTypeRef) RenderJsonError!void {
    try writer.writeAll("    \"subtypes\": [\n");
    for (subtypes, 0..) |subtype, i| {
        try writer.writeAll("      {\n");
        try writeJsonField(writer, "type", subtype.kind, false);
        try writer.writeAll(",\n");
        try writer.print("        \"named\": {}\n", .{subtype.named});
        try writer.writeAll("      }");
        if (i + 1 != subtypes.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("    ]");
}

fn writeJsonField(writer: anytype, name: []const u8, value: []const u8, comma_after: bool) RenderJsonError!void {
    try writer.print("    \"{s}\": ", .{name});
    try writeJsonString(writer, value);
    if (comma_after) try writer.writeAll(",");
    if (comma_after) {
        try writer.writeAll("\n");
    }
}

fn writeJsonString(writer: anytype, value: []const u8) RenderJsonError!void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

test "renderNodeTypesJson renders deterministic node type JSON" {
    const nodes = [_]compute.NodeType{
        .{
            .kind = "binary_expression",
            .named = true,
            .fields = &.{
                .{
                    .name = "left",
                    .info = .{
                        .quantity = .{ .required = true, .multiple = false },
                        .types = &.{.{ .kind = "expression", .named = true }},
                    },
                },
            },
            .children = .{
                .quantity = .{ .required = true, .multiple = true },
                .types = &.{
                    .{ .kind = "expression", .named = true },
                    .{ .kind = "+", .named = false },
                },
            },
            .subtypes = &.{},
        },
        .{
            .kind = "expression",
            .named = true,
            .root = true,
            .subtypes = &.{
                .{ .kind = "binary_expression", .named = true },
                .{ .kind = "identifier", .named = true },
            },
        },
    };

    const json = try renderNodeTypesJsonAlloc(std.testing.allocator, &nodes);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\": \"binary_expression\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fields\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"children\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"subtypes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"root\": true") != null);
}

test "renderNodeTypesJson omits empty optional sections" {
    const nodes = [_]compute.NodeType{
        .{
            .kind = "identifier",
            .named = true,
        },
    };

    const json = try renderNodeTypesJsonAlloc(std.testing.allocator, &nodes);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"fields\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"children\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"subtypes\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extra\"") == null);
}

const std = @import("std");
const compute = @import("compute.zig");

pub const RenderJsonError = error{
    OutOfMemory,
} || std.Io.Writer.Error;

pub fn renderNodeTypesJson(
    writer: anytype,
    nodes: []const compute.NodeType,
) RenderJsonError!void {
    try writer.writeAll("[\n");
    for (nodes, 0..) |node, i| {
        try writeIndent(writer, 1);
        try writer.writeAll("{\n");
        try writeStringField(writer, 2, "type", node.kind, true);
        try writeBoolField(writer, 2, "named", node.named, false, false);

        if (node.root) {
            try writer.writeAll(",\n");
            try writeBoolField(writer, 2, "root", node.root, false, false);
        }

        if (node.extra) {
            try writer.writeAll(",\n");
            try writeBoolField(writer, 2, "extra", node.extra, false, false);
        }

        if (hasRenderableFields(node.fields) or node.children != null or node.render_empty_fields) {
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

        try writer.writeAll("\n");
        try writeIndent(writer, 1);
        try writer.writeAll("}");
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
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderNodeTypesJson(&out.writer, nodes);
    return try out.toOwnedSlice();
}

fn renderFields(writer: anytype, fields: []const compute.Field) RenderJsonError!void {
    try writeIndent(writer, 2);
    if (!hasRenderableFields(fields)) {
        try writer.writeAll("\"fields\": {}");
        return;
    }

    try writer.writeAll("\"fields\": {\n");

    var rendered_count: usize = 0;
    for (fields) |field| {
        if (field.info.types.len == 0) continue;
        if (rendered_count > 0) {
            try writer.writeAll(",\n");
        }
        try writeIndent(writer, 3);
        try writeJsonString(writer, field.name);
        try writer.writeAll(": ");
        try renderChildInfo(writer, field.info, 3);
        rendered_count += 1;
    }
    try writer.writeAll("\n");
    try writeIndent(writer, 2);
    try writer.writeAll("}");
}

fn renderChildInfoField(
    writer: anytype,
    name: []const u8,
    info: compute.ChildInfo,
) RenderJsonError!void {
    try writeIndent(writer, 2);
    try writeJsonString(writer, name);
    try writer.writeAll(": ");
    try renderChildInfo(writer, info, 2);
}

fn renderChildInfo(writer: anytype, info: compute.ChildInfo, indent: usize) RenderJsonError!void {
    try writer.writeAll("{\n");
    try writeBoolField(writer, indent + 1, "multiple", info.quantity.multiple, true, true);
    try writeBoolField(writer, indent + 1, "required", info.quantity.required, true, true);
    try writeIndent(writer, indent + 1);
    try writer.writeAll("\"types\": [\n");
    for (info.types, 0..) |ty, i| {
        try writeIndent(writer, indent + 2);
        try writer.writeAll("{\n");
        try writeStringField(writer, indent + 3, "type", ty.kind, false);
        try writer.writeAll(",\n");
        try writeBoolField(writer, indent + 3, "named", ty.named, false, false);
        try writer.writeAll("\n");
        try writeIndent(writer, indent + 2);
        try writer.writeAll("}");
        if (i + 1 != info.types.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writeIndent(writer, indent + 1);
    try writer.writeAll("]\n");
    try writeIndent(writer, indent);
    try writer.writeAll("}");
}

fn renderSubtypes(writer: anytype, subtypes: []const compute.NodeTypeRef) RenderJsonError!void {
    try writeIndent(writer, 2);
    try writer.writeAll("\"subtypes\": [\n");
    for (subtypes, 0..) |subtype, i| {
        try writeIndent(writer, 3);
        try writer.writeAll("{\n");
        try writeStringField(writer, 4, "type", subtype.kind, false);
        try writer.writeAll(",\n");
        try writeBoolField(writer, 4, "named", subtype.named, false, false);
        try writer.writeAll("\n");
        try writeIndent(writer, 3);
        try writer.writeAll("}");
        if (i + 1 != subtypes.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writeIndent(writer, 2);
    try writer.writeAll("]");
}

fn writeStringField(writer: anytype, indent: usize, name: []const u8, value: []const u8, newline_after: bool) RenderJsonError!void {
    try writeIndent(writer, indent);
    try writeJsonString(writer, name);
    try writer.writeAll(": ");
    try writeJsonString(writer, value);
    if (newline_after) {
        try writer.writeAll(",");
        try writer.writeAll("\n");
    }
}

fn writeBoolField(writer: anytype, indent: usize, name: []const u8, value: bool, comma_after: bool, newline_after: bool) RenderJsonError!void {
    try writeIndent(writer, indent);
    try writeJsonString(writer, name);
    try writer.writeAll(": ");
    try writer.print("{}", .{value});
    if (comma_after) try writer.writeAll(",");
    if (newline_after) try writer.writeAll("\n");
}

fn writeIndent(writer: anytype, level: usize) RenderJsonError!void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll("  ");
    }
}

fn hasRenderableFields(fields: []const compute.Field) bool {
    for (fields) |field| {
        if (field.info.types.len > 0) return true;
    }
    return false;
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

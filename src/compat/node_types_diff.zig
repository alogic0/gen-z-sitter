const std = @import("std");

pub const NodeTypeKey = struct {
    type_name: []const u8,
    named: bool,

    fn deinit(self: NodeTypeKey, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
    }
};

pub const NodeTypesDiff = struct {
    status: []const u8,
    local_count: usize,
    upstream_count: usize,
    missing_in_local: []const NodeTypeKey,
    extra_in_local: []const NodeTypeKey,

    pub fn deinit(self: NodeTypesDiff, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        for (self.missing_in_local) |key| key.deinit(allocator);
        allocator.free(self.missing_in_local);
        for (self.extra_in_local) |key| key.deinit(allocator);
        allocator.free(self.extra_in_local);
    }
};

pub fn compareNodeTypesJsonAlloc(
    allocator: std.mem.Allocator,
    local_json: []const u8,
    upstream_json: []const u8,
) !NodeTypesDiff {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const local_keys = try parseKeysAlloc(arena.allocator(), local_json);
    const upstream_keys = try parseKeysAlloc(arena.allocator(), upstream_json);

    var missing: std.ArrayList(NodeTypeKey) = .empty;
    errdefer deinitKeys(allocator, missing.items);
    for (upstream_keys) |upstream_key| {
        if (!containsKey(local_keys, upstream_key)) {
            try missing.append(allocator, try cloneKey(allocator, upstream_key));
        }
    }

    var extra: std.ArrayList(NodeTypeKey) = .empty;
    errdefer deinitKeys(allocator, extra.items);
    for (local_keys) |local_key| {
        if (!containsKey(upstream_keys, local_key)) {
            try extra.append(allocator, try cloneKey(allocator, local_key));
        }
    }

    const missing_items = try missing.toOwnedSlice(allocator);
    errdefer deinitKeys(allocator, missing_items);
    const extra_items = try extra.toOwnedSlice(allocator);
    errdefer deinitKeys(allocator, extra_items);
    const matched = missing_items.len == 0 and extra_items.len == 0;

    return .{
        .status = try allocator.dupe(u8, if (matched) "matched" else "different"),
        .local_count = local_keys.len,
        .upstream_count = upstream_keys.len,
        .missing_in_local = missing_items,
        .extra_in_local = extra_items,
    };
}

pub fn writeJson(writer: anytype, diff: NodeTypesDiff, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.writeAll("{\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"status\": ");
    try writeJsonString(writer, diff.status);
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.print("\"local_count\": {d},\n", .{diff.local_count});
    try writeIndent(writer, indent + 2);
    try writer.print("\"upstream_count\": {d},\n", .{diff.upstream_count});
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"missing_in_local\": ");
    try writeKeyArrayJson(writer, diff.missing_in_local, indent + 2);
    try writer.writeAll(",\n");
    try writeIndent(writer, indent + 2);
    try writer.writeAll("\"extra_in_local\": ");
    try writeKeyArrayJson(writer, diff.extra_in_local, indent + 2);
    try writer.writeByte('\n');
    try writeIndent(writer, indent);
    try writer.writeByte('}');
}

fn parseKeysAlloc(allocator: std.mem.Allocator, source: []const u8) ![]const NodeTypeKey {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();

    const array = switch (parsed.value) {
        .array => |items| items,
        else => return error.InvalidNodeTypesJson,
    };
    const keys = try allocator.alloc(NodeTypeKey, array.items.len);
    for (array.items, 0..) |item, index| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.InvalidNodeTypesJson,
        };
        const type_value = object.get("type") orelse return error.InvalidNodeTypesJson;
        const named_value = object.get("named") orelse return error.InvalidNodeTypesJson;
        keys[index] = .{
            .type_name = try allocator.dupe(u8, switch (type_value) {
                .string => |value| value,
                else => return error.InvalidNodeTypesJson,
            }),
            .named = switch (named_value) {
                .bool => |value| value,
                else => return error.InvalidNodeTypesJson,
            },
        };
    }
    sortKeys(keys);
    return keys;
}

fn cloneKey(allocator: std.mem.Allocator, key: NodeTypeKey) !NodeTypeKey {
    return .{
        .type_name = try allocator.dupe(u8, key.type_name),
        .named = key.named,
    };
}

fn containsKey(keys: []const NodeTypeKey, needle: NodeTypeKey) bool {
    for (keys) |key| {
        if (key.named == needle.named and std.mem.eql(u8, key.type_name, needle.type_name)) return true;
    }
    return false;
}

fn sortKeys(keys: []NodeTypeKey) void {
    std.mem.sort(NodeTypeKey, keys, {}, struct {
        fn lessThan(_: void, left: NodeTypeKey, right: NodeTypeKey) bool {
            const order = std.mem.order(u8, left.type_name, right.type_name);
            if (order != .eq) return order == .lt;
            return @intFromBool(left.named) < @intFromBool(right.named);
        }
    }.lessThan);
}

fn deinitKeys(allocator: std.mem.Allocator, keys: []const NodeTypeKey) void {
    for (keys) |key| key.deinit(allocator);
    allocator.free(keys);
}

fn writeKeyArrayJson(writer: anytype, keys: []const NodeTypeKey, indent: usize) !void {
    try writer.writeAll("[");
    if (keys.len != 0) try writer.writeByte('\n');
    for (keys, 0..) |key, index| {
        try writeIndent(writer, indent + 2);
        try writer.writeAll("{ \"type\": ");
        try writeJsonString(writer, key.type_name);
        try writer.writeAll(", \"named\": ");
        try writer.writeAll(if (key.named) "true" else "false");
        try writer.writeAll(" }");
        if (index + 1 != keys.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    if (keys.len != 0) try writeIndent(writer, indent);
    try writer.writeByte(']');
}

fn writeIndent(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
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

test "compareNodeTypesJsonAlloc reports missing and extra node types" {
    const local =
        \\[
        \\  { "type": "source_file", "named": true },
        \\  { "type": "local_only", "named": true }
        \\]
    ;
    const upstream =
        \\[
        \\  { "type": "source_file", "named": true },
        \\  { "type": "upstream_only", "named": false }
        \\]
    ;
    const diff = try compareNodeTypesJsonAlloc(std.testing.allocator, local, upstream);
    defer diff.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("different", diff.status);
    try std.testing.expectEqual(@as(usize, 2), diff.local_count);
    try std.testing.expectEqual(@as(usize, 2), diff.upstream_count);
    try std.testing.expectEqual(@as(usize, 1), diff.missing_in_local.len);
    try std.testing.expectEqualStrings("upstream_only", diff.missing_in_local[0].type_name);
    try std.testing.expectEqual(@as(usize, 1), diff.extra_in_local.len);
    try std.testing.expectEqualStrings("local_only", diff.extra_in_local[0].type_name);
}

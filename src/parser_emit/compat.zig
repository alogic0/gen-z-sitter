const std = @import("std");

pub const CompatibilityTarget = enum {
    tree_sitter_runtime_surface,
};

pub const CompatibilityLayer = enum {
    intermediate,
};

pub const language_version: u16 = 15;
pub const min_compatible_language_version: u16 = 13;

pub fn targetName(target: CompatibilityTarget) []const u8 {
    return switch (target) {
        .tree_sitter_runtime_surface => "tree-sitter-runtime-surface",
    };
}

pub fn layerName(layer: CompatibilityLayer) []const u8 {
    return switch (layer) {
        .intermediate => "intermediate",
    };
}

pub const RuntimeCompatibilityInfo = struct {
    target: CompatibilityTarget,
    layer: CompatibilityLayer,
    language_version: u16,
    min_compatible_language_version: u16,
};

pub fn currentRuntimeCompatibility() RuntimeCompatibilityInfo {
    return .{
        .target = .tree_sitter_runtime_surface,
        .layer = .intermediate,
        .language_version = language_version,
        .min_compatible_language_version = min_compatible_language_version,
    };
}

test "current runtime compatibility exposes the Milestone 15 target" {
    const info = currentRuntimeCompatibility();

    try std.testing.expectEqual(CompatibilityTarget.tree_sitter_runtime_surface, info.target);
    try std.testing.expectEqual(CompatibilityLayer.intermediate, info.layer);
    try std.testing.expectEqual(@as(u16, 15), info.language_version);
    try std.testing.expectEqual(@as(u16, 13), info.min_compatible_language_version);
    try std.testing.expectEqualStrings("tree-sitter-runtime-surface", targetName(info.target));
    try std.testing.expectEqualStrings("intermediate", layerName(info.layer));
}

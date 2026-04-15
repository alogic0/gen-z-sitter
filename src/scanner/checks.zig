const std = @import("std");
const scanner_serialize = @import("serialize.zig");

pub const ExternalScannerCheckError = error{
    MissingExternalTokens,
    MissingExternalUses,
    BlockedWithoutReason,
    ReadyWithUnsupportedFeatures,
    InvalidExternalUseIndex,
    EmptyExternalTokenName,
    EmptyExternalVariableName,
};

pub fn validateSerializedExternalScannerBoundary(
    serialized: scanner_serialize.SerializedExternalScannerBoundary,
) ExternalScannerCheckError!void {
    if (serialized.tokens.len == 0) return error.MissingExternalTokens;
    if (serialized.uses.len == 0) return error.MissingExternalUses;

    if (serialized.blocked) {
        if (serialized.unsupported_features.len == 0) {
            return error.BlockedWithoutReason;
        }
    } else {
        if (serialized.unsupported_features.len != 0) {
            return error.ReadyWithUnsupportedFeatures;
        }
    }

    for (serialized.tokens) |token| {
        if (token.name.len == 0) return error.EmptyExternalTokenName;
    }

    for (serialized.uses) |use| {
        if (use.external_index >= serialized.tokens.len) {
            return error.InvalidExternalUseIndex;
        }
        if (use.variable_name.len == 0) {
            return error.EmptyExternalVariableName;
        }
    }
}

test "validateSerializedExternalScannerBoundary accepts a ready external scanner surface" {
    try validateSerializedExternalScannerBoundary(.{
        .tokens = &.{.{
            .index = 0,
            .name = "indent",
            .kind = .named,
        }},
        .uses = &.{.{
            .external_index = 0,
            .variable_name = "_with_indent",
            .production_index = 0,
            .step_index = 0,
            .field_name = "lead",
        }},
        .unsupported_features = &.{},
        .blocked = false,
    });
}

test "validateSerializedExternalScannerBoundary rejects blocked surfaces without explicit blockers" {
    try std.testing.expectError(
        error.BlockedWithoutReason,
        validateSerializedExternalScannerBoundary(.{
            .tokens = &.{.{
                .index = 0,
                .name = "indent",
                .kind = .named,
            }},
            .uses = &.{.{
                .external_index = 0,
                .variable_name = "_with_indent",
                .production_index = 0,
                .step_index = 0,
                .field_name = "lead",
            }},
            .unsupported_features = &.{},
            .blocked = true,
        }),
    );
}

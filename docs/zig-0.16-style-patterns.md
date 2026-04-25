# Zig 0.16 Style Patterns

These are the local coding patterns to apply while continuing RW-1 work. They are based on a comparison with representative Zig 0.16 standard library files under `~/.zig/zig-x86_64-linux-0.16.0/lib/std`.

## Public API Shape

- Keep imports explicit at the top of each file:
  - `const std = @import("std");`
  - local modules as `const name = @import("path.zig");`
- Prefer small public structs/enums for durable model boundaries.
- Add short doc comments to exported model types and exported functions when they define a stable internal boundary.
- Keep helper functions private unless another module already needs them.
- Use narrow error sets for public API edges where practical, usually combining allocator and writer errors explicitly:
  - `pub const EmitError = std.mem.Allocator.Error || std.Io.Writer.Error;`

## Allocation and Ownership

- Pass allocators explicitly into functions that allocate.
- Name allocating functions with an `Alloc` suffix when the caller owns returned memory.
- Pair owned aggregate outputs with clear `deinit` helpers when the ownership is non-trivial.
- Use `defer` for normal cleanup and `errdefer` for partially initialized allocations.
- Prefer arena allocation for short-lived, whole-operation intermediate data.
- Avoid hidden ownership transfer. If a returned slice is owned by the caller, make that obvious from the function name or surrounding API.

## Collections

- Zig 0.16 stdlib marks managed `ArrayList` compatibility APIs as deprecated. Avoid adding new `std.array_list.Managed(...)` use when touching code.
- Prefer allocator-explicit list APIs and unmanaged-style collection ownership for new code.
- Keep existing managed-list use in unrelated code until the file is already being edited for a focused reason.

## Writer and Emitter Code

- Emit generated output through `std.Io.Writer` APIs:
  - `writer.writeAll(...)` for fixed text.
  - `writer.print(...)` for formatted values.
  - `std.Io.Writer.Allocating` for `emit...Alloc` helpers that return bytes.
- Keep generated ABI fragments centralized instead of duplicating C definitions across emitters.
- Keep string escaping helpers local to the emitter unless they become shared by multiple emitters.
- Prefer deterministic output order and explicit index designators in generated tables.

## Diagnostics and Logging

- Core library functions should be quiet by default.
- Avoid unconditional `std.debug.print` in serialization, parse-table construction, and emit paths.
- If progress output is needed, gate it behind explicit options or existing environment-controlled diagnostics.
- Keep test-only logging out of normal production paths.

## Control Flow

- Use early returns for simple guard cases.
- Use `switch` expressions for tagged unions and enums.
- Use `std.debug.assert` for internal invariants that should never be recoverable runtime errors.
- Use `unreachable` only where the local invariant is proven nearby.
- Avoid broad rewrites when a focused change can preserve behavior and test scope.

## Tests

- Keep focused tests close to the code they verify.
- Prefer small tests that exercise local behavior over broad compatibility harness tests for each incremental RW-1 step.
- Use broad staged compatibility tests only when the touched code changes cross-module behavior or when explicitly validating a milestone.
- Skip or defer heavy tests when they do not cover the current local change.

## Formatting

- Use the local Zig formatter for source files:
  - `~/.zig/zig-x86_64-linux-0.16.0/zig fmt src`
- Do not include Markdown files in `zig fmt`.
- Before committing formatting-only churn, verify it is either requested or limited to files already being changed.

## Formatter Baseline

The source tree should pass:

```sh
~/.zig/zig-x86_64-linux-0.16.0/zig fmt --check src
```

Keep formatting-only changes in focused cleanup commits, or limit them to files already being changed for implementation work.

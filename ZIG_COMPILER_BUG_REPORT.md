# Zig Compiler Bug Report Draft

## Summary

While extending the Milestone 6 parser-table work to include explicit parse-action dumps, the Zig compiler started failing with an internal panic:

- `thread <pid> panic: TODO`

This appears to be a compiler issue rather than a normal user-code type error, because:

- narrower parser-table tests passed earlier in the same work stream
- the failure happens during compilation of broader test/build entrypoints
- the panic output does not point at a semantic source-level error

There is also a separate environment issue:

- the repo filesystem became full and `zig build` / `zig build test` began failing with `NoSpaceLeft`

That second issue is real, but it is distinct from the earlier compiler panic.

## Environment

- project: `gen_z_sitter`
- cwd: `/home/alogic0/prog/gen_z_sitter`
- shell: `bash`
- Zig binary path observed in build output:
  - `/home/alogic0/.zig/zig-x86_64-linux-0.15.2/zig`
- date: `2026-04-15`

## Code Being Added When The Panic Appeared

The panic began after adding explicit parse-action artifact wiring on top of already-working Milestone 6 lookahead groundwork.

New/modified files in the triggering change set:

- `src/parse_table/debug_dump.zig`
  - added `dumpStatesWithActionsAlloc`
  - added `writeStatesWithActions`
  - added action rendering in the parser-state dump
- `src/parse_table/pipeline.zig`
  - added `generateStateActionDumpFromPrepared`
  - added `buildActionsForStates`
  - added an exact golden test for action-aware parser-state output

Related supporting code already committed before this point:

- `src/parse_table/actions.zig`
- `src/parse_table/first.zig`
- lookahead-aware changes in `src/parse_table/build.zig`
- lookahead-aware conflict filtering in `src/parse_table/conflicts.zig`

## Symptoms

### 1. Compiler internal panic

Observed on:

- `zig test src/main.zig`
- `zig test src/main.zig --test-filter "tiny parser-state action golden fixture"`

Observed output:

```text
thread <pid> panic: TODO
Unable to dump stack trace: debug info stripped
```

No source-level Zig error was reported before the panic.

### 2. Separate disk-space issue

Later, after repeated test/build attempts:

- `zig build`
- `zig build test`

began failing with:

```text
error: NoSpaceLeft
```

Filesystem state at that point:

```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/vdc         10G  9.8G     0 100% /home/alogic0/prog/gen_z_sitter
```

and `.zig-cache` was about:

```text
4.8G .zig-cache
```

This is likely unrelated to the original compiler `panic: TODO`, but it blocks further local repro work until the cache is cleaned.

## Narrowed Trigger Surface

Before the latest action-artifact integration, these were passing:

- `zig build`
- `zig build test`
- parser-table focused tests
- action IR tests in `src/parse_table/actions.zig`

The panic started after wiring actions into the debug artifact path:

- action-aware dump functions in `src/parse_table/debug_dump.zig`
- action-aware pipeline helper and golden test in `src/parse_table/pipeline.zig`

That suggests the likely trigger is one of:

1. the action-aware dump formatting path
2. the combination of nested slices like `[]const []const ActionEntry`
3. the action-dump golden test through the full `src/main.zig` test graph
4. a broader Zig compiler bug triggered by this module graph and constant data layout

## Relevant Commands

Commands that succeeded earlier in the same work stream:

```text
zig test src/main.zig --test-filter "action"
zig test src/main.zig --test-filter "tiny parser-state action golden fixture"
```

Commands that later failed with compiler panic:

```text
zig test src/main.zig
zig test src/main.zig --test-filter "tiny parser-state action golden fixture"
```

Commands that later failed due to disk exhaustion:

```text
zig build
zig build test
```

## Suggested Next Reduction

To turn this into a clean upstream repro:

1. clear `.zig-cache`
2. reduce the test graph to only:
   - `src/parse_table/actions.zig`
   - `src/parse_table/debug_dump.zig`
   - `src/parse_table/pipeline.zig`
3. if needed, replace the full grammar pipeline with a smaller synthetic state/action input
4. isolate whether the compiler panic is caused by:
   - nested slice constants
   - generic writer formatting
   - union formatting/switching
   - the action-aware golden string

## Current Repo State

At the time of writing, the uncommitted Milestone 6 action-artifact changes are:

- `src/parse_table/debug_dump.zig`
- `src/parse_table/pipeline.zig`

These should be preserved before further reduction or cleanup.

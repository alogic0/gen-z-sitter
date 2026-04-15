# Milestone 10 Implementation Checklist

## Goal

Implement the first real serialization/code-emission milestone after Milestone 9:

- turn the current build-time parser-decision boundary into a stable serialized table shape
- define the first emitter-facing IR for parser tables
- establish deterministic artifacts for serialized parser data
- prepare the repository for later `parser.c`-style code emission without trying to finish full generator parity yet

Milestone 10 is the bridge between:

- “the build layer owns a stable pre-serialization parser-decision snapshot”

and

- “the generator can serialize parser tables into a deterministic form that later code emission can consume directly”.

## Current Status

Milestone 10 is complete.

Implemented now:

- dedicated serialized parse-table IR in `src/parse_table/serialize.zig`
- explicit serialization policy:
  - `strict` mode rejects unresolved snapshots
  - `diagnostic` mode preserves unresolved entries
- deterministic serialized-table dump artifacts for:
  - a ready metadata-rich grammar
  - a blocked conflict grammar
- the first emitter-facing consumers of serialized tables:
  - `src/parser_emit/parser_tables.zig`
  - `src/parser_emit/c_tables.zig`
- exact end-to-end artifacts proving both emitters consume serialized tables through the real preparation path

Final Milestone 10 decision:

- the current serializer/emitter boundary is sufficient for Milestone 10 closeout

What this means:

- Milestone 10 is no longer waiting on serialization-boundary work
- the next milestone can focus on broader code emission instead of reworking the initial serialized-table handoff

## What Milestone 10 Includes

- a serialization-facing parse-table IR
- explicit serialized representation for:
  - states
  - shift/reduce/accept actions
  - goto transitions
  - unresolved decision markers when present
- deterministic serialization/debug artifacts for that IR
- the first narrow emitter boundary that consumes serialized parser data
- focused tests proving the serialized form is stable and derived from the Milestone 9 decision boundary

## What Milestone 10 Does Not Include

- full `parser.c` parity
- lexer/scanner code emission
- parse-table compression/minimization
- runtime ABI compatibility work
- broad codegen formatting polish
- full generator parity

Those should follow only after the serialized table boundary is stable.

## Starting Point

Milestone 9 already provides:

- build-owned resolved actions in `BuildResult`
- explicit serialization readiness checks
- structured chosen decision refs
- structured unresolved decision refs
- `DecisionSnapshot` as the pre-serialization handoff
- real-path tests for both serialization-ready and blocked grammars

What still remains after Milestone 9:

- define the actual serialized parse-table shape
- decide how unresolved entries are represented in serialized output
- establish the first emitter-facing contract from serialized parser data
- prove the serialized output is deterministic and stable enough for later codegen

Most of those items are now implemented in Milestone 10.

## Main Targets

### 1. Serialized parse-table IR

Current state:

- implemented
- parse tables now have a dedicated serialized boundary in `src/parse_table/serialize.zig`

Target state:

- introduce a stable IR specifically for serialized parser tables
- keep it separate from the build-time algorithm structures where that separation adds clarity

Acceptance criteria:

- met

### 2. State/action/goto serialization

Current state:

- implemented
- state/action/goto data now has a canonical serialized layout and exact artifact coverage

Target state:

- serialize:
  - state ids
  - terminal/external actions
  - non-terminal goto edges
  - accept entries
  - unresolved entries if the build result is not serialization-ready

Acceptance criteria:

- met

### 3. Unresolved-entry policy at serialization time

Current state:

- `DecisionSnapshot` exposes unresolved entries explicitly
- Milestone 9 leaves `reduce_reduce_deferred` as an intentional unresolved boundary

Result:

- explicit dual-mode policy implemented:
  - `strict` rejects unresolved snapshots
  - `diagnostic` preserves unresolved entries in serialized output

Acceptance criteria:

- met

### 4. First emitter-facing boundary

Current state:

- implemented
- serialized tables now have two emitter-facing consumers:
  - a narrow textual parser-table skeleton
  - a C-like table skeleton

Result:

- the first emitter-facing boundary exists and is artifact-tested
- later code-emission work no longer needs to start from the build algorithm layer

Acceptance criteria:

- met

## File-by-File Plan

### 1. `src/parse_table/serialize.zig`

Purpose:

- turn the current build result into a dedicated serialized parser-table IR

Implement:

- serialization IR types
- serializer entry points from `BuildResult` / `DecisionSnapshot`
- explicit handling for ready vs blocked snapshots

Acceptance criteria:

- serialized output is deterministic and stable for the supported subset

### 2. `src/parse_table/build.zig`

Purpose:

- keep the build/serialization boundary explicit

Implement:

- any small convenience helpers needed so serialization can consume `BuildResult` directly
- avoid pushing serialization-specific layout choices back into the builder unless necessary

Acceptance criteria:

- build output remains the clean source of truth for serialization

### 3. `src/parse_table/debug_dump.zig`

Purpose:

- keep serialized tables inspectable

Implement:

- serialized-table dump helpers
- exact deterministic dump formatting for the new IR

Acceptance criteria:

- serialized tables are pinned by exact artifacts, not only by structural assertions

### 4. `src/parse_table/pipeline.zig`

Purpose:

- pin the first real serialized-table path through the existing grammar preparation pipeline

Implement:

- helper functions that run:
  - raw grammar
  - prepared grammar
  - extract/flatten
  - build
  - serialize
  - dump
- exact golden tests for ready and blocked cases

Acceptance criteria:

- serialized-table behavior is proven end to end through the real preparation path

### 5. `src/tests/fixtures.zig`

Purpose:

- hold only the focused fixtures needed for the first serialization boundary

Implement:

- serialized-table goldens for:
  - a ready grammar
  - a blocked grammar with unresolved decisions
  - optionally one metadata-rich grammar if it adds real coverage

Acceptance criteria:

- fixture growth stays tied to real serialization-boundary coverage

### 6. `src/parser_emit/` or equivalent emitter module

Purpose:

- establish the first narrow code-emission consumer of serialized parser tables

Implement:

- minimal emitter-facing IR adapter or skeleton emitter
- keep this intentionally small and deterministic

Acceptance criteria:

- code-emission work no longer needs to start from the build algorithm layer

## Closeout Result

Milestone 10 closes with these explicit decisions:

1. the current serialized parse-table IR is the stable serialization boundary
2. strict vs diagnostic serialization behavior is accepted as the Milestone 10 unresolved-entry policy
3. the existing textual and C-like emitter skeletons are sufficient as the first emitter-facing consumers

## Review Result

After the current implementation work, Milestone 10 splits into:

### Implemented boundary work

- serialized parse-table IR
- explicit strict vs diagnostic serialization policy
- deterministic serialized-table dump artifacts
- exact real-path goldens for ready and blocked serialization
- first emitter-facing parser-table skeleton
- first C-like codegen-oriented table skeleton

### Deferred to the next milestone

- broader parser code emission beyond the current skeleton consumers
- any richer emitted representation or runtime-facing layout work
- later codegen polish beyond the Milestone 10 boundary

### Closeout/polish work

- completed in this checklist update
- the next milestone can now focus on broader code emission rather than serialization-boundary redesign

## Risks

- over-designing the serialized IR can create churn before the first real emitter exists
- under-designing it can push algorithm-layer assumptions into later code emission
- mixing debug-only and real serialized shapes can blur the boundary Milestone 10 is supposed to establish

## Exit Criteria

Milestone 10 is complete when:

- parser tables can be serialized from the current build boundary into a stable deterministic IR
- serialization behavior for blocked/unresolved snapshots is explicit
- serialized-table artifacts are pinned through the real pipeline
- a first emitter-facing boundary exists on top of serialized parser data
- the next milestone can focus on broader code emission rather than reworking serialization

Status:

- complete

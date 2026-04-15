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

## Main Targets

### 1. Serialized parse-table IR

Current state:

- parse tables exist as build-layer structures and decision snapshots
- there is not yet a dedicated serialized-table boundary

Target state:

- introduce a stable IR specifically for serialized parser tables
- keep it separate from the build-time algorithm structures where that separation adds clarity

Acceptance criteria:

- later code-emission work can consume serialized tables without re-deriving parser decisions

### 2. State/action/goto serialization

Current state:

- state/action data is inspectable through debug dumps
- there is no canonical serialized layout yet

Target state:

- serialize:
  - state ids
  - terminal/external actions
  - non-terminal goto edges
  - accept entries
  - unresolved entries if the build result is not serialization-ready

Acceptance criteria:

- the serialized layout is deterministic and covers the current supported parser subset

### 3. Unresolved-entry policy at serialization time

Current state:

- `DecisionSnapshot` exposes unresolved entries explicitly
- Milestone 9 leaves `reduce_reduce_deferred` as an intentional unresolved boundary

Target state:

- explicitly decide whether serialization:
  - rejects unresolved snapshots, or
  - preserves unresolved entries in a debug/diagnostic serialization mode

Acceptance criteria:

- serialization behavior is explicit and tested for both ready and blocked inputs

### 4. First emitter-facing boundary

Current state:

- there is no dedicated code-emission input yet

Target state:

- define the first narrow emitter-facing contract that consumes serialized parser tables
- keep this focused on table/code skeleton emission, not full runtime output

Acceptance criteria:

- later `parser.c` work can begin from serialized tables rather than the build algorithm layer

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

## Recommended Implementation Order

1. Define the serialized parse-table IR and serializer entry point.
2. Decide the blocked-snapshot serialization policy.
3. Add deterministic serialized-table dump helpers.
4. Add real pipeline goldens for ready and blocked serialization paths.
5. Add the first narrow emitter-facing consumer of serialized parser tables.
6. Do a closeout review documenting what remains for broader code emission.

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

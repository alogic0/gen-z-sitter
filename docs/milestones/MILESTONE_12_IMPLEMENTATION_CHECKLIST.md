# Milestone 12 Implementation Checklist

## Goal

Implement the next parser-generation milestone after Milestone 11:

- move from a broader parser.c-like skeleton toward deeper parser output
- define the first runtime-facing parser-emission boundary
- keep emitted output deterministic and exact-testable
- avoid jumping directly to full Tree-sitter `parser.c` parity

Milestone 12 is the bridge between:

- “the generator can emit a broader parser-oriented translation unit from serialized tables”

and

- “the generator can emit a more runtime-shaped parser output with a clearer public boundary for later compatibility work”.

## What Milestone 12 Includes

- deeper parser output on top of the existing `SerializedTable` and parser.c-like emitter work
- a clearer runtime-facing emitted API boundary
- exact artifact coverage for the richer emitted output
- explicit policy for blocked output at that richer boundary
- emitter cleanup only where needed to support the new runtime-facing layer

## What Milestone 12 Does Not Include

- full Tree-sitter `parser.c` parity
- runtime ABI compatibility with upstream
- lexer/scanner code emission
- external scanner integration
- parse-table compression/minimization
- full end-to-end generator parity

## Starting Point

Milestone 11 already provides:

- `SerializedTable` as the stable input boundary for parser emission
- explicit ready vs blocked serialization behavior
- deterministic serialized-table and emitter artifacts
- `src/parser_emit/common.zig` for shared emitter formatting
- `src/parser_emit/parser_c.zig` with:
  - per-state arrays
  - `TSStateTable`
  - `ts_states`
  - `TSParser`
  - `ts_parser`
  - basic accessor/query helpers

What still remains after Milestone 11:

- a more runtime-shaped emitted parser surface
- a clearer parser-facing emitted API beyond simple data accessors
- a better-defined boundary for later runtime/compatibility work

## Main Targets

### 1. Richer parser translation unit

Current state:

- the emitted parser artifact is broader than a skeleton, but still mostly data declarations plus simple accessors

Target state:

- emit a richer parser translation unit with more parser-oriented structure and helper surface
- stay intentionally simpler than full upstream `parser.c`

Acceptance criteria:

- the emitted artifact is materially more runtime-shaped than Milestone 11’s boundary

### 2. Runtime-facing emitted API boundary

Current state:

- the emitted API surface is limited to simple access/query helpers

Target state:

- define a small but explicit runtime-facing parser API in emitted output
- keep it deterministic and easy to pin with exact artifacts

Acceptance criteria:

- later runtime-oriented work has a clearer emitted boundary to build on

### 3. Exact goldens for richer output

Current state:

- Milestone 11 already has exact parser.c-like emitter goldens

Target state:

- keep richer output pinned by exact end-to-end fixtures for:
  - one ready grammar
  - one blocked grammar

Acceptance criteria:

- richer output remains deterministic and regression-resistant

### 4. Clear blocked-output policy

Current state:

- blocked behavior is already explicit through diagnostic serialization

Target state:

- ensure the richer emitted API and translation unit still make blocked state explicit and inspectable

Acceptance criteria:

- blocked richer output behavior is explicit and tested

## File-by-File Plan

### 1. `src/parser_emit/parser_c.zig`

Purpose:

- remain the primary broader parser emitter

Implement:

- deepen the emitted translation unit with one or two runtime-facing parser surfaces
- keep output intentionally narrow enough to avoid false claims of upstream parity

Acceptance criteria:

- the emitted artifact clearly advances beyond the Milestone 11 boundary

### 2. `src/parser_emit/common.zig`

Purpose:

- keep emitter formatting/helpers shared as parser output grows

Implement:

- only the helper extensions needed to support deeper parser emission

Acceptance criteria:

- parser emitter growth does not reintroduce duplicated formatting logic

### 3. `src/parse_table/pipeline.zig`

Purpose:

- pin the richer emitted output through the real preparation path

Implement:

- keep exact real-path goldens for ready and blocked richer output

Acceptance criteria:

- richer parser output is still proven through the real pipeline

### 4. `src/tests/fixtures.zig`

Purpose:

- store the exact broader output artifacts

Implement:

- update/add only the fixtures needed to pin the richer translation-unit boundary

Acceptance criteria:

- fixture growth stays justified by real emitter-boundary coverage

## Recommended Implementation Order

1. Decide the next small runtime-facing API layer to add to `parser_c.zig`.
2. Implement that richer emitted surface without reopening serialization.
3. Update exact ready/blocked parser.c-like goldens.
4. Review whether the richer emitted boundary is enough to close the milestone.
5. Document what remains for runtime compatibility and fuller parser parity.

## Risks

- broadening parser output too aggressively can blur the line between “richer emitted boundary” and “claimed parser.c parity”
- introducing runtime-shaped helpers too early can imply ABI commitments the project is not ready to support
- growing emitter logic without discipline can undo the cleanup achieved in Milestone 11

## Exit Criteria

Milestone 12 is complete when:

- the repo emits a richer parser-oriented translation unit than Milestone 11
- the emitted parser artifact exposes a clearer runtime-facing API boundary
- ready and blocked richer outputs are pinned by exact real-path goldens
- the next milestone can focus on runtime compatibility or fuller parser output instead of first emitter-boundary shaping

## Current Status

Implemented now:

- `src/parser_emit/parser_c.zig` has moved beyond the Milestone 11 parser.c-like boundary
- the emitted parser artifact now exposes:
  - parser-level access
  - per-state access
  - indexed entry access
  - field-level entry access
  - symbol-based lookup
  - boolean predicate helpers
- blocked output remains explicit through the richer emitted boundary
- exact real-path parser.c-like goldens remain in place for:
  - one ready grammar
  - one blocked grammar

## Review Result

Implemented boundary work:

- the emitted translation unit is materially more runtime-shaped than Milestone 11
- the runtime-facing emitted API is now clear enough to serve as a handoff to later compatibility work
- blocked behavior remains explicit and inspectable in both emitted data and emitted helpers
- the richer emitted output remains deterministic and pinned by exact real-path artifacts

Remaining gaps, intentionally deferred beyond Milestone 12:

- upstream runtime ABI compatibility work
- fuller parser output closer to real Tree-sitter `parser.c`
- lexer/scanner emission
- external scanner integration
- parse-table compression/minimization

## Completion State

Milestone 12 is complete.

Completed in this milestone:

- richer parser output on top of the Milestone 11 boundary
- a clearer runtime-facing emitted API boundary
- explicit blocked behavior at the richer emitted boundary
- exact ready/blocked parser.c-like goldens for the richer emitted surface

Deferred to the next milestone:

- runtime-facing compatibility targets
- fuller parser output and ABI-oriented work

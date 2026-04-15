# Milestone 11 Implementation Checklist

## Goal

Implement the next parser-generation milestone after Milestone 10:

- expand from serialized parser-table skeletons into broader parser code emission
- turn the current serialized-table boundary into a more realistic `parser.c`-style output path
- keep code emission deterministic and inspectable
- prepare the repository for later runtime-compatibility and broader generator-parity work

Milestone 11 is the bridge between:

- “the generator can serialize parser tables and emit narrow skeleton consumers”

and

- “the generator can emit a broader parser implementation surface from serialized tables without reworking serialization again”.

## What Milestone 11 Includes

- broader parser code-emission output on top of `SerializedTable`
- a more realistic emitted parser artifact than the current skeleton emitters
- deterministic emission artifacts pinned through exact tests
- explicit policy for how blocked serialized tables affect emitted output
- a cleaner emitter structure for later expansion toward `parser.c` parity

## What Milestone 11 Does Not Include

- full `parser.c` parity
- lexer/scanner code emission
- runtime ABI compatibility work
- parse-table compression/minimization
- full Tree-sitter generator parity
- external scanner/runtime integration

Those should follow after the broader parser-emission surface is stable.

## Starting Point

Milestone 10 already provides:

- `src/parse_table/serialize.zig` as the serialized parse-table boundary
- strict vs diagnostic serialization policy
- deterministic serialized-table dump artifacts
- a first textual emitter-facing parser-table skeleton
- a first C-like table skeleton consumer
- exact real-path artifacts for ready and blocked serialization/emission cases

What still remains after Milestone 10:

- emit a broader parser artifact than the current skeletons
- decide how much parser-structure realism is needed before claiming a real code-emission milestone
- define the next emitter-facing organization so later `parser.c` work scales cleanly

## Main Targets

### 1. Broader parser-emission artifact

Current state:

- emitters exist, but they are still intentionally narrow skeletons

Target state:

- emit a broader parser artifact that includes more realistic parser tables and surrounding structure
- still keep the output intentionally simpler than full Tree-sitter `parser.c`

Acceptance criteria:

- the repo can emit a recognizable parser-oriented artifact that is materially beyond a skeleton dump

### 2. Deterministic emitted layout

Current state:

- serialized tables are deterministic
- emitted skeletons are deterministic

Target state:

- keep broader emitted output deterministic, stable, and exact-testable

Acceptance criteria:

- emitted parser artifacts are pinned by exact goldens for both ready and blocked cases

### 3. Blocked-emission policy

Current state:

- strict serialization rejects blocked tables
- diagnostic serialization preserves unresolved entries

Target state:

- explicitly decide how broader code emission treats blocked tables:
  - reject them, or
  - emit diagnostic-only code stubs/markers

Acceptance criteria:

- blocked-emission behavior is explicit and tested

### 4. Emitter architecture cleanup

Current state:

- two emitter modules exist:
  - textual parser-table skeleton
  - C-like table skeleton

Target state:

- confirm or refactor the emitter layering so later code-emission work does not fork awkwardly across ad hoc modules

Acceptance criteria:

- later parser-emission expansion has a clear module boundary

## File-by-File Plan

### 1. `src/parser_emit/`

Purpose:

- expand the emitter surface beyond the current narrow skeletons

Implement:

- either extend `c_tables.zig` into a broader emitted parser artifact, or
- introduce a new emitter module for a more complete parser-oriented output
- keep the current skeleton emitters only if they still provide useful debug value

Acceptance criteria:

- emitted parser output is materially broader than a table skeleton

### 2. `src/parse_table/serialize.zig`

Purpose:

- remain the stable input boundary for code emission

Implement:

- only the refinements needed if the broader emitter reveals a missing serialized-table field or awkward layout
- avoid reopening the serialization boundary unless clearly necessary

Acceptance criteria:

- code emission still starts from serialized tables, not the build algorithm layer

### 3. `src/parse_table/pipeline.zig`

Purpose:

- pin broader emitted artifacts through the real grammar-preparation path

Implement:

- end-to-end emission helpers for the broader parser artifact
- exact goldens for ready and blocked emission paths

Acceptance criteria:

- broader parser-emission behavior is proven through the real pipeline

### 4. `src/tests/fixtures.zig`

Purpose:

- hold only the fixtures needed to pin the broader code-emission boundary

Implement:

- emitter goldens for:
  - one ready grammar
  - one blocked grammar
  - optionally one richer metadata grammar if needed

Acceptance criteria:

- fixture growth remains tied to real emitter-boundary coverage

## Recommended Implementation Order

1. Decide whether to extend `c_tables.zig` or add a new broader parser emitter module.
2. Define the broader emitted parser artifact.
3. Decide blocked-emission behavior for that artifact.
4. Add exact real-path goldens for ready and blocked emission.
5. Review whether the emitter module structure is sufficient for later `parser.c`-style expansion.
6. Do a closeout review documenting what remains for fuller parser code emission and runtime compatibility.

## Risks

- broadening code emission too aggressively can blur the boundary between “first real emitter” and “full parser.c parity”
- reopening serialization unnecessarily can stall progress by re-litigating Milestone 10 decisions
- carrying too many parallel emitter styles can create architectural drift

## Exit Criteria

Milestone 11 is complete when:

- the repo emits a broader parser-oriented artifact from `SerializedTable`
- blocked-emission behavior is explicit and tested
- emitted artifacts are deterministic and pinned by exact goldens
- the emitter architecture is clear enough for later expansion toward fuller parser code emission
- the next milestone can focus on deeper parser output and runtime-oriented work rather than reworking the first broader emitter

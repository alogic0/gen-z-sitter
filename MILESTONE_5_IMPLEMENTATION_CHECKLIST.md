# Milestone 5 Implementation Checklist

## Goal

Implement the first parser-generation milestone after the Milestone 4 `node-types.json` parity work:

- introduce the IR and algorithms needed for parse-table construction
- move the project from front-end normalization and artifact rendering into real parser-generation state
- keep the scope below full `parser.c` emission so table construction can be stabilized independently

Milestone 5 is the bridge between the prepared grammar pipeline and later generated parser output.

## What Milestone 5 Includes

- parser-state and item-set IR
- FIRST-set and closure support as needed for table construction
- deterministic syntax table construction for a limited supported subset
- explicit conflict representation and diagnostics at the table-building layer
- debug-visible table dumps and small-grammar golden tests

## What Milestone 5 Does Not Include

- final `parser.c` rendering
- lexer table code emission
- scanner code emission
- wasm output
- full CLI parity for `tree-sitter generate`

Those belong to later milestones once parser tables are stable.

## Upstream Reference Points

Milestone 5 should be guided primarily by the upstream generator code that builds parse states and tables:

- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/build_parse_table.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/item.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/item_set_builder.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/parse_item_set.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/token_conflicts.rs`

The main upstream concepts to preserve are:

- deterministic item-set construction
- explicit representation of parse items and lookahead behavior
- stable state numbering only after canonical state construction
- conflict information recorded as data, not only as ad hoc strings

## Deliverables

By the end of Milestone 5, the repository should have:

- parser-table IR modules in `src/parse_table/` or equivalent
- a first state-construction pipeline from `PreparedGrammar`
- table/debug dump output for small grammars
- small focused fixtures proving state construction and conflict reporting
- a milestone closeout note describing the supported subset and what remains before `parser.c`

## Current Status

Milestone 5 now has the core parser-table foundation in place:

- `src/parse_table/item.zig`
  - parser item identity, deterministic comparison, and debug formatting
- `src/parse_table/state.zig`
  - parser states, transitions, conflict storage, and stable ordering helpers
- `src/parse_table/debug_dump.zig`
  - deterministic textual dump format for states, items, transitions, and conflicts
- `src/parse_table/build.zig`
  - first narrow LR(0)-style canonical state construction over `SyntaxGrammar`
  - explicit supported-subset rejection for metadata-heavy productions
  - deterministic state interning and numbering
- `src/parse_table/conflicts.zig`
  - structured narrow LR(0)-style shift/reduce and reduce/reduce conflict detection
- `src/parse_table/pipeline.zig`
  - real path from `PreparedGrammar` through extraction, flattening, state construction, and dump generation
- `src/tests/fixtures.zig`
  - focused parser-table fixtures for:
    - a tiny non-conflicting grammar
    - an intentional conflict grammar
    - a deterministic state-reuse grammar

The artifact layer is also in place:

- exact parser-state dump golden for a minimal grammar
- exact parser-state dump golden for a conflict grammar
- focused state-reuse proof for deterministic interning

So the remaining Milestone 5 work is no longer “build parser-table foundations”.
It is mostly:

- review and document the current supported subset explicitly
- decide whether Milestone 5 is complete enough to close now, or whether one more focused fixture is needed
- record the deferrals for later milestones, especially:
  - broader grammar support
  - richer lookahead/FIRST-set behavior
  - conflict resolution instead of only conflict representation
  - eventual parse-table serialization / `parser.c` emission

## Main Targets

### 1. Parse item and state IR

Current state:

- implemented

Target state:

- represent productions, dots/items, item sets, parser states, and transitions explicitly
- keep the IR deterministic and inspectable
- make it possible to compare state graphs on small grammars

Expected impact:

- the generator will have a real parser-construction boundary for the first time
- later codegen can build on stable table data instead of mixing algorithms and rendering

### 2. Deterministic state construction

Current state:

- implemented for a deliberately narrow LR(0)-style supported subset

Target state:

- closure and transition expansion for a supported subset of grammars
- deterministic state de-duplication
- stable state ordering after canonicalization

Expected impact:

- the project will be able to compute parser states for simple grammars
- table dumps can become the next exact artifact/golden layer

### 3. Conflict representation

Current state:

- implemented for the current narrow LR(0)-style builder

Target state:

- represent shift/reduce and reduce/reduce style conflicts as structured data
- keep enough context to debug state construction failures later
- expose conflict data in debug dumps and tests

Expected impact:

- later milestones can improve conflict resolution/reporting without redesigning the table layer

## File-by-File Plan

### 1. `src/parse_table/item.zig`

Purpose:

- define parser items and item identity

Implement:

- production reference
- dot position
- lookahead or other required subset state for the chosen construction model
- stable ordering and hashing helpers

Acceptance criteria:

- items are value-comparable and can be stored in deterministic sets/maps

### 2. `src/parse_table/state.zig`

Purpose:

- define parser states and transitions

Implement:

- item-set storage
- transition map keyed by grammar symbols
- optional conflict list on each state

Acceptance criteria:

- states can be dumped deterministically and compared in tests

### 3. `src/parse_table/build.zig`

Purpose:

- build canonical parser states from the prepared grammar

Implement:

- closure expansion
- goto/transition construction
- state interning/de-duplication
- deterministic numbering of final states

Acceptance criteria:

- small prepared grammars produce stable state graphs

### 4. `src/parse_table/conflicts.zig`

Purpose:

- model parser-table conflicts explicitly

Implement:

- conflict kinds
- involved symbols/items/rules
- helper formatting for debug and tests

Acceptance criteria:

- conflicts are structured and testable, not only surfaced as generic errors

Status:

- implemented

### 5. `src/parse_table/debug_dump.zig`

Purpose:

- provide a stable debug artifact before code generation exists

Implement:

- textual dump for items, states, transitions, and conflicts
- deterministic ordering everywhere

Acceptance criteria:

- fixture-based exact goldens can pin parser-state output for small grammars

Status:

- implemented with both minimal and conflict-state exact goldens

### 6. `src/tests/fixtures.zig`

Purpose:

- add small grammars for parser-state construction

Implement:

- a minimal expression grammar
- a grammar with one intentional table-layer conflict
- a grammar that stresses deterministic state reuse

Acceptance criteria:

- each fixture exists to prove one concrete table-building behavior

Status:

- implemented for minimal state construction, conflict reporting, and deterministic state reuse

## Recommended Implementation Sequence

Completed:

1. Add `src/parse_table/item.zig` and `src/parse_table/state.zig`.
2. Add a tiny debug dump format before full construction so the IR shape is inspectable early.
3. Implement a first `build.zig` path for a deliberately narrow supported subset.
4. Add one exact golden dump for a minimal grammar.
5. Add structured conflict representation in `conflicts.zig`.
6. Add one conflict fixture and exact dump or focused assertion.
7. Add explicit deterministic state-reuse coverage.

Remaining:

1. Review the supported subset and document it in milestone closeout terms.
2. Decide whether Milestone 5 should close now or after one more focused proof fixture.
3. Record the main Milestone 6+ deferrals:
   - richer lookahead/FIRST-set behavior
   - broader grammar support
   - conflict resolution
   - parse-table serialization and `parser.c` emission

## Risks

- parser-state construction can expand scope very quickly if the supported subset is not kept narrow
- deterministic ordering is easy to lose if item/state interning is not designed carefully up front
- conflict handling can become entangled with resolution too early; Milestone 5 should represent conflicts first, not fully solve them

## Exit Criteria

Milestone 5 is complete when:

- parser items and parser states have stable IR
- a first canonical state-construction pipeline exists for a defined supported subset
- conflicts are represented as structured data
- at least one exact parser-state/debug-dump golden exists
- `zig build` passes
- `zig build test` passes
- the remaining gap to `parser.c` generation is mostly code emission and broader grammar support, not missing parser-state foundations

Current closeout assessment:

- all core parser-table foundations in this checklist are implemented
- exact artifact coverage exists for both non-conflicting and conflicting state graphs
- deterministic state reuse is explicitly covered
- `zig build` passes
- `zig build test` passes

So Milestone 5 is close to completion. The remaining work is a supported-subset closeout decision, not a missing core subsystem.

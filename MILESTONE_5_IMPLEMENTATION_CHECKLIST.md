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

## Main Targets

### 1. Parse item and state IR

Current state:

- the project stops at `PreparedGrammar`, extraction, flattening, aliases, and `node-types.json`

Target state:

- represent productions, dots/items, item sets, parser states, and transitions explicitly
- keep the IR deterministic and inspectable
- make it possible to compare state graphs on small grammars

Expected impact:

- the generator will have a real parser-construction boundary for the first time
- later codegen can build on stable table data instead of mixing algorithms and rendering

### 2. Deterministic state construction

Current state:

- no canonical parse-state construction exists yet

Target state:

- closure and transition expansion for a supported subset of grammars
- deterministic state de-duplication
- stable state ordering after canonicalization

Expected impact:

- the project will be able to compute parser states for simple grammars
- table dumps can become the next exact artifact/golden layer

### 3. Conflict representation

Current state:

- conflicts are validated earlier in the front-end, but there is no table-layer conflict model yet

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

### 5. `src/parse_table/debug_dump.zig`

Purpose:

- provide a stable debug artifact before code generation exists

Implement:

- textual dump for items, states, transitions, and conflicts
- deterministic ordering everywhere

Acceptance criteria:

- fixture-based exact goldens can pin parser-state output for small grammars

### 6. `src/tests/fixtures.zig`

Purpose:

- add small grammars for parser-state construction

Implement:

- a minimal expression grammar
- a grammar with one intentional table-layer conflict
- a grammar that stresses deterministic state reuse

Acceptance criteria:

- each fixture exists to prove one concrete table-building behavior

## Recommended Implementation Sequence

1. Add `src/parse_table/item.zig` and `src/parse_table/state.zig`.
2. Add a tiny debug dump format before full construction so the IR shape is inspectable early.
3. Implement a first `build.zig` path for a deliberately narrow supported subset.
4. Add one exact golden dump for a minimal grammar.
5. Add structured conflict representation in `conflicts.zig`.
6. Add one conflict fixture and exact dump or focused assertion.
7. Review the supported subset and decide what must expand before Milestone 6.

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

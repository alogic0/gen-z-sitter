# Milestone 6 Implementation Checklist

## Goal

Implement the second parser-generation milestone after the Milestone 5 parser-state foundation:

- move from the current narrow LR(0)-style state builder toward richer parse-table behavior
- introduce explicit lookahead/FIRST-set support needed for realistic parse actions
- broaden the supported grammar subset beyond the current metadata-rejecting path
- keep the scope below final `parser.c` emission so parse-table semantics can stabilize first

Milestone 6 is the bridge between “state graphs exist” and “real parse tables are semantically useful”.

## What Milestone 6 Includes

- FIRST-set / lookahead support for parser-state construction
- a richer parse item / item-set model where lookahead is meaningful
- parse-action representation, not just states and transitions
- broader supported syntax-grammar subset in table construction
- explicit unresolved-conflict reporting at the action-table layer
- stable debug-visible artifacts for parse states and parse actions

## What Milestone 6 Does Not Include

- final `parser.c` rendering
- lexer table code emission
- scanner code emission
- wasm output
- full CLI parity for `tree-sitter generate`
- parse-table minimization

Those still belong to later milestones once parse actions and richer conflict handling are stable.

## Upstream Reference Points

Milestone 6 should continue to follow the upstream table-building code, especially the parts that go beyond raw LR(0)-style closure:

- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/build_parse_table.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/item.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/item_set_builder.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/parse_item_set.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/token_conflicts.rs`

The main upstream concepts to preserve here are:

- lookahead-aware item propagation
- parse actions as stable data, not inferred ad hoc from states
- conflicts detected at the action-table layer, not only from local LR(0)-style shapes
- deterministic output despite richer state/action construction

## Deliverables

By the end of Milestone 6, the repository should have:

- a lookahead/FIRST-set layer in `src/parse_table/` or equivalent
- richer parser items and state construction that use lookahead meaningfully
- explicit parse-action table IR
- a stable debug dump for parse actions as well as states
- focused fixtures proving:
  - lookahead-sensitive state/action behavior
  - broadened supported subset behavior
  - conflict reporting at the action-table layer
- a milestone closeout note describing the supported subset and what still remains before code emission

## Current Starting Point

Milestone 5 already provides:

- parser item/state IR
- deterministic narrow LR(0)-style state construction
- structured shift/reduce and reduce/reduce conflict representation
- exact state-dump goldens for minimal and conflicting grammars
- focused proofs for deterministic state reuse and reduce/reduce reporting

What Milestone 5 deliberately does not provide:

- meaningful lookahead propagation
- parse-action tables
- broader grammar support during table construction
- conflict detection based on true parse actions instead of narrow LR(0)-style local shapes

So Milestone 6 should extend the existing parser-table layer rather than replace it.

## Main Targets

### 1. Lookahead and FIRST-set support

Current state:

- `ParseItem.lookahead` exists structurally, but the builder does not populate it meaningfully
- closure/goto logic is effectively LR(0)-style

Target state:

- compute enough FIRST-set / next-symbol information to propagate lookaheads through item expansion
- represent lookahead on parse items as real construction data, not placeholder state
- keep the implementation deterministic and inspectable

Expected impact:

- conflicts and actions can become more realistic
- the parser-table layer can start supporting grammars that LR(0)-style construction over-reports or misclassifies

### 2. Parse-action table IR

Current state:

- states and transitions exist, but there is no explicit parse-action table

Target state:

- represent shift, reduce, accept, and conflict-bearing action entries explicitly
- keep actions separate from state transitions
- make actions dumpable and testable

Expected impact:

- later milestones can serialize or emit real parser tables
- conflict handling can move from “state contains conflicts” to “action entries conflict”

### 3. Broader supported subset

Current state:

- metadata-heavy productions are rejected during parser-state building

Target state:

- identify which metadata should be honored in Milestone 6 versus deferred
- support a practical next subset, likely starting with:
  - precedence metadata
  - associativity metadata
  - selected field/alias-preserving shapes where table construction can ignore node-type-specific concerns safely

Expected impact:

- the parser-table layer becomes useful for more than the minimal subset proven in Milestone 5
- fewer grammars stop at `UnsupportedFeature`

### 4. Action-table conflict reporting

Current state:

- conflicts are currently detected from narrow LR(0)-style completed/advanced item shapes

Target state:

- detect and report unresolved conflicts from actual action sets
- preserve structured conflict data and stable dumps
- keep resolution out of scope, but make the unresolved conflict surface more semantically correct

Expected impact:

- later resolution logic will have the right boundary
- debug artifacts will better match the real parse-table problem

## File-by-File Plan

### 1. `src/parse_table/item.zig`

Purpose:

- evolve parse items from mostly LR(0)-style identity to lookahead-aware construction data

Implement:

- stable comparison helpers that include meaningful lookahead state
- helpers for item advancement and lookahead propagation

Acceptance criteria:

- items remain deterministic and testable while carrying real lookahead information

### 2. `src/parse_table/first.zig`

Purpose:

- compute the FIRST-set or equivalent next-symbol support needed by the chosen construction model

Implement:

- symbol-set helpers
- sequence FIRST-set logic
- grammar-level FIRST-set queries needed by closure/item expansion

Acceptance criteria:

- focused tests prove deterministic FIRST behavior on small grammars

### 3. `src/parse_table/build.zig`

Purpose:

- upgrade state construction from narrow LR(0)-style expansion to lookahead-aware construction

Implement:

- closure expansion that uses FIRST/lookahead information
- broader supported-subset handling
- deterministic state interning with richer item identity

Acceptance criteria:

- small lookahead-sensitive grammars produce stable richer state graphs

### 4. `src/parse_table/actions.zig`

Purpose:

- define parse-action table IR

Implement:

- action kinds:
  - shift
  - reduce
  - accept
  - conflict-bearing grouped action entries if needed
- per-state action maps keyed by terminals/lookaheads
- deterministic ordering helpers

Acceptance criteria:

- actions can be compared, dumped, and asserted in tests

### 5. `src/parse_table/conflicts.zig`

Purpose:

- move conflict detection up to the action-table layer

Implement:

- conflict extraction from competing action entries
- structured conflict payloads that reference actions/items/symbols

Acceptance criteria:

- focused tests prove conflicts are derived from action-table state, not only LR(0)-style local item shapes

### 6. `src/parse_table/debug_dump.zig`

Purpose:

- extend the debug artifact layer to include parse actions

Implement:

- stable textual dump for:
  - states
  - transitions
  - items with lookaheads
  - parse actions
  - unresolved conflicts

Acceptance criteria:

- exact goldens can pin both state graphs and action tables

### 7. `src/parse_table/pipeline.zig`

Purpose:

- expose the richer parser-table pipeline from `PreparedGrammar`

Implement:

- helper path that returns or dumps:
  - states
  - action tables
  - unresolved conflicts

Acceptance criteria:

- end-to-end grammar fixtures can exercise the whole Milestone 6 parser-table path

### 8. `src/tests/fixtures.zig`

Purpose:

- add small focused grammars for lookahead and broader-support proof

Implement:

- one grammar where LR(0)-style state information is insufficient and lookahead matters
- one grammar that exercises newly-supported precedence/associativity behavior
- one grammar that isolates action-table conflict reporting

Acceptance criteria:

- each fixture proves one concrete Milestone 6 behavior

## Recommended Implementation Sequence

1. Add `src/parse_table/first.zig`.
2. Upgrade `src/parse_table/item.zig` and `src/parse_table/build.zig` for meaningful lookahead propagation.
3. Add `src/parse_table/actions.zig`.
4. Extend `src/parse_table/conflicts.zig` so conflicts can be derived from action tables.
5. Extend `src/parse_table/debug_dump.zig` to render actions and unresolved conflicts.
6. Add one exact golden for a lookahead-sensitive grammar.
7. Add one focused broader-subset grammar proving newly-supported metadata handling.
8. Review the supported subset and decide what must still wait for Milestone 7.

## Risks

- lookahead support can expand complexity quickly if the target construction model is not kept narrow
- supporting too much metadata too early can entangle parse-table semantics with later code-emission concerns
- action-table representation can drift if ordering and comparison rules are not kept explicit
- conflict handling can slip into premature resolution logic unless Milestone 6 stays focused on representation and detection first

## Exit Criteria

Milestone 6 is complete when:

- parser items carry meaningful lookahead information
- a FIRST-set / lookahead support layer exists and is tested
- parse actions are represented explicitly as data
- unresolved conflicts are detected from action-table state
- at least one exact debug artifact covers actions as well as states
- the supported grammar subset is broader than the Milestone 5 subset
- `zig build` passes
- `zig build test` passes
- the remaining gap to later milestones is mainly table refinement, resolution, minimization, and code emission rather than missing parse-action foundations

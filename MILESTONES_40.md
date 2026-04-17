# MILESTONES 40 (Upstream-Shape Item-Set Refactor)

This milestone follows [MILESTONES_39.md](./MILESTONES_39.md).

Milestone 39 clarified the algorithmic target: upstream tree-sitter does not treat lookahead as a property of one duplicated LR item at a time. It treats parser states as item sets whose entries carry aggregated lookahead sets, and it applies precomputed transitive closure additions into that representation. `gen-z-sitter` already contains part of that direction, but it still keeps closure and state identity centered on `ParseItem { production_id, step_index, lookahead:?SymbolRef }`.

That is the next implementation barrier. It keeps closure expansion too close to the old live-recursive shape, duplicates items across lookaheads, and prevents the state builder from matching the upstream item-set/core split cleanly.

This is not a Haskell workaround milestone. It is not a threshold-tuning milestone. It is the representation and integration milestone needed to make the M39 algorithm real in this codebase.

## Goal

- replace the current per-item optional-lookahead representation with an upstream-style item-set-entry representation
- move closure application onto `ParseItemSetEntry { item, lookaheads }` rather than duplicated parse items
- make state construction track full item-set identity and LR(0)-style core identity separately
- preserve current parser-table correctness on small grammars while reducing closure duplication pressure on hard grammars
- leave diagnostics and threshold controls as secondary tooling, not the primary algorithm

## Current Gap

The important current facts are:

- [src/parse_table/first.zig](./src/parse_table/first.zig) already computes `FIRST` sets
- [src/parse_table/build.zig](./src/parse_table/build.zig) already has:
  - `ParseItemSetBuilder`
  - `FollowSetInfo`
  - `TransitiveClosureAddition`
  - `computeTransitiveClosureAdditionsAlloc(...)`
- `buildStatesWithOptions(...)` already constructs the builder and threads it into state construction

But the current builder still uses:

- [src/parse_table/item.zig](./src/parse_table/item.zig) `ParseItem.lookahead: ?SymbolRef`
- closure output as flat duplicated `[]ParseItem`
- state identity based on full arrays of duplicated parse items
- closure caching keyed by seed items that still carry one lookahead at a time

That means the current code has some upstream ingredients, but not the upstream algorithmic shape.

## Target Shape

The target model should look much closer to upstream tree-sitter:

- `ParseItem`
  - only identifies the LR item core:
    - `production_id`
    - `step_index`
- `ParseItemSetEntry`
  - stores:
    - `item`
    - `lookaheads: first.SymbolSet`
    - any extra follow/reserved metadata if needed later
- `ParseItemSet`
  - ordered collection of entries
- `ParseItemSetCore`
  - ordered collection of only `ParseItem`
- `ParseItemSetBuilder`
  - owns:
    - `FIRST`
    - `LAST` if retained
    - transitive closure additions
  - exposes:
    - `transitiveClosure(...)`
    - helpers for merging additions into an item set

The key behavior change is:

- closure should merge lookahead sets into an existing item-set entry
- not create one separate `ParseItem` per lookahead token

## Files Expected To Change

Primary files:

- [src/parse_table/item.zig](./src/parse_table/item.zig)
- [src/parse_table/state.zig](./src/parse_table/state.zig)
- [src/parse_table/build.zig](./src/parse_table/build.zig)
- [src/parse_table/conflicts.zig](./src/parse_table/conflicts.zig)
- [src/parse_table/actions.zig](./src/parse_table/actions.zig)
- [src/parse_table/resolution.zig](./src/parse_table/resolution.zig)

Likely supporting files:

- [src/parse_table/first.zig](./src/parse_table/first.zig)
- parser-table tests under `src/parse_table`

## PR-Sized Slices

### PR 1: Introduce Item-Set Entry Types

Implement:

- refactor [src/parse_table/item.zig](./src/parse_table/item.zig):
  - remove lookahead from `ParseItem`
  - add `ParseItemSetEntry`
  - add `ParseItemSet`
  - add `ParseItemSetCore`
  - add deterministic sort/compare helpers for:
    - items
    - item-set entries
    - item-set cores
- update [src/parse_table/state.zig](./src/parse_table/state.zig) to store item sets rather than flat parse-item arrays

Notes:

- keep the types minimal first
- do not fold in reserved-word handling unless a concrete caller needs it
- if preserving extension space is useful, put extra follow metadata on `ParseItemSetEntry`, not on `ParseItem`

Verification:

- unit tests for:
  - item ordering
  - entry ordering
  - core extraction
  - lookahead-set merge behavior

Success signal:

- the codebase compiles with the new representations stubbed in
- `ParseItem` no longer encodes lookahead directly

### PR 2: Move Closure To Item-Set Entries

Implement:

- rewrite closure logic in [src/parse_table/build.zig](./src/parse_table/build.zig) so that:
  - seed input is a `ParseItemSet`
  - closure result is a `ParseItemSet`
  - additions are merged into entries by item identity
  - lookahead sets are unioned
  - propagated suffix follow information is unioned only when `propagates_lookahead` is true
- keep `computeTransitiveClosureAdditionsAlloc(...)`, but adapt it to produce additions suitable for entry-based merging
- add a builder method with an explicit upstream-style boundary:
  - `transitiveClosure(...)`
  - or equivalent naming

Important implementation rule:

- the suffix follow set for the current item must be computed once per source entry and merged into closure additions when propagation is allowed
- do not convert that follow set into duplicated one-lookahead items

Verification:

- closure tests on tiny grammars for:
  - direct non-terminal expansion
  - recursive leading non-terminals
  - nullable suffix propagation
  - external-token propagation
- compare expected closure entries by:
  - item identity
  - lookahead-set contents

Success signal:

- closure no longer produces duplicate items purely to represent multiple lookaheads
- hand-checkable grammars produce the expected merged entry sets

### PR 3: Rewrite Goto And State Construction Around Item Sets

Implement:

- rewrite `gotoItems(...)` in [src/parse_table/build.zig](./src/parse_table/build.zig) into item-set form
  - advance matching entries by symbol
  - preserve each entry’s lookahead set
  - close the advanced item set through the builder
- rewrite `constructStates(...)` so that:
  - full state identity uses `ParseItemSet`
  - merge candidates or reuse checks can also observe `ParseItemSetCore`
- replace the current `findState(...)` flat-item-array lookup with explicit maps:
  - full item set -> state id
  - core -> core id or equivalent diagnostic grouping

Notes:

- M40 does not require parse-state merging beyond the current semantics unless that is already implied by the existing builder behavior
- the immediate requirement is to separate exact item-set identity from core identity so the implementation matches the M39 algorithm shape

Verification:

- existing deterministic tiny-grammar state tests still pass
- state counts for current small fixtures remain stable unless the representation intentionally narrows duplication
- transition construction remains deterministic

Success signal:

- no live closure path depends on duplicated one-lookahead parse items
- state reuse is based on item sets, with core identity tracked separately

### PR 4: Adapt Action/Conflict Consumers

Implement:

- update [src/parse_table/actions.zig](./src/parse_table/actions.zig) to consume state entries with lookahead sets
- update [src/parse_table/conflicts.zig](./src/parse_table/conflicts.zig) so conflict checks ask:
  - whether an entry applies to a candidate lookahead
  - whether a reduction entry’s lookahead set includes that symbol
- update [src/parse_table/resolution.zig](./src/parse_table/resolution.zig) only as needed for the new item/state representations

Notes:

- this PR should be narrower than it sounds
- the semantic behavior should stay the same where possible; the main change is how lookahead availability is represented

Verification:

- existing shift/reduce fixture tests still pass
- nullable-lookahead propagation tests still pass after representation conversion

Success signal:

- action generation and conflict detection consume item-set entries directly
- there is no compatibility shim rebuilding fake single-lookahead items in the hot path

### PR 5: Simplify Old Closure Caches And Diagnostics

Implement:

- remove or rewrite caches in [src/parse_table/build.zig](./src/parse_table/build.zig) that were designed around:
  - per-item inherited lookahead
  - duplicated closure outputs
  - cache keys containing optional single lookahead symbols
- keep progress logging, but change the reported units to match the new model:
  - item-set entries
  - aggregate lookahead sizes
  - exact item-set cache hits
  - core matches

Notes:

- do not keep legacy cache structures if they force the new builder back into the old shape
- a smaller, simpler cache is better than a rich cache keyed on the wrong abstraction

Verification:

- `zig build test`
- focused parse-table tests if split out

Success signal:

- closure diagnostics describe entry-set growth rather than duplicated parse-item growth
- the remaining caches align with the new representation instead of fighting it

### PR 6: Stress Validation On Haskell

Implement:

- no new code required unless diagnostics need small additions
- run the targeted Haskell stress scenario from M39:
  - `GEN_Z_SITTER_COMPAT_EXCLUDE_TARGETS=tree_sitter_c_json`
  - `GEN_Z_SITTER_COMPAT_DETAIL_PROGRESS=1`
  - `GEN_Z_SITTER_PARSE_TABLE_PROGRESS=1`
  - `GEN_Z_SITTER_PARSE_TABLE_TARGET_FILTER=tree_sitter_haskell_json`
  - `zig run update_compat_artifacts.zig`

Compare against the old path for:

- closure growth shape
- repeated hotspot chains
- whether threshold fallback still dominates early
- whether exact item-set reuse improves before fallback logic matters

Success signal:

- Haskell still acts as a stress case, but closure/state construction pressure is lower in the general algorithmic path
- threshold controls become secondary protection, not the primary survival mechanism

## Implementation Order

Recommended implementation order:

1. land the representation split in `item.zig` and `state.zig`
2. port closure to item-set-entry semantics
3. port goto/state construction to item-set semantics
4. update actions/conflicts/resolution consumers
5. delete legacy cache assumptions
6. run full verification and Haskell stress validation

This order matters because trying to preserve the old `ParseItem.lookahead` representation while “improving” closure will create a hybrid design that still duplicates the same logical item across many lookahead contexts.

## Specific Design Rules

- `ParseItem` should be core-only
- lookahead aggregation belongs on item-set entries
- closure should merge entries by core item identity
- exact state identity and core identity should be separate concepts
- caches should be keyed on item sets or entry sets, not single inherited lookahead symbols unless that is still demonstrably required after the refactor
- threshold fallbacks should remain optional safety valves, not part of the normal algorithmic explanation

## Exit Criteria

- [ ] `ParseItem.lookahead` is removed from the hot parse-table builder path
- [ ] parser states store or are derived from item-set entries with aggregated lookahead sets
- [ ] closure uses precomputed transitive additions and merges lookahead sets into entries
- [ ] state construction distinguishes exact item-set identity from LR(0)-style core identity
- [ ] existing tiny-grammar parse-table tests pass after the representation change
- [ ] `zig build test` passes
- [ ] targeted Haskell stress validation shows lower general closure/state pressure before threshold fallback dominates

## Progress

- [ ] PR 1 completed
- [ ] PR 2 completed
- [ ] PR 3 completed
- [ ] PR 4 completed
- [ ] PR 5 completed
- [ ] PR 6 completed
- [ ] M40 ready for closeout

## Current Focus

The first implementation step should be the representation split, not another closure micro-optimization.

Current recommended first code move:

- refactor `src/parse_table/item.zig` so that `ParseItem` becomes core-only
- introduce `ParseItemSetEntry` and `ParseItemSetCore`
- then let `build.zig` fail to compile in obvious places and port callers one layer at a time

That will force the builder onto the right abstraction and prevent another round of partial fixes on top of the wrong representation.

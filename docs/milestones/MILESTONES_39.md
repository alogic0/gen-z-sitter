# MILESTONES 39 (Tree-Sitter Item-Set Builder Algorithm)

This milestone follows [MILESTONES_38.md](./MILESTONES_38.md).

Milestone 38 closed by fully promoting `tree_sitter_c_json` into the routine parser-only boundary. After that, Haskell debugging exposed heavy closure and state-construction pressure in our parse-table builder. The earlier response in this repo was to add diagnostics, targeted experiments, and threshold-based controls. Those were useful for locating the cost, but they are not the upstream algorithm.

This milestone resets the focus. The first thing M39 should record is the actual tree-sitter algorithm we want to adopt, how it differs from our current builder, and how we will verify whether we implemented it correctly.

It is not a runtime-parity milestone. It is not a Haskell-specific workaround milestone. It is a parser-generator algorithm milestone.

## Goal

- describe the upstream tree-sitter parse-table construction algorithm in enough detail that implementation work is testable
- replace our current live recursive closure-expansion bias with an upstream-style item-set-builder strategy
- use Haskell as a stress test for the general algorithm, not as the source of permanent grammar-specific rules
- define concrete checks for proving that our implementation matches the intended algorithmic shape

## Tree-Sitter Algorithm

Upstream tree-sitter organizes parser generation as an explicit pipeline:

1. parse grammar input
2. prepare grammar
3. build parse and lex tables
4. minimize parse tables
5. render emitted artifacts

The part that matters for this milestone is step 3.

### Core Components

The relevant upstream files are:

- [/home/oleg/prog/tree-sitter/crates/generate/src/build_tables/build_parse_table.rs](/home/oleg/prog/tree-sitter/crates/generate/src/build_tables/build_parse_table.rs)
- [/home/oleg/prog/tree-sitter/crates/generate/src/build_tables/item_set_builder.rs](/home/oleg/prog/tree-sitter/crates/generate/src/build_tables/item_set_builder.rs)

Upstream does not repeatedly rediscover closure expansions from scratch for every state. Instead it introduces an explicit item-set builder that precomputes reusable closure additions.

### FIRST And LAST Sets

`ParseItemSetBuilder::new(...)` computes:

- `FIRST` sets for symbols
- `LAST` sets for symbols
- reserved-first information where relevant

This is not special to Haskell. It is generic grammar preparation for table building.

### Transitive Closure Additions

The key upstream idea is `transitive_closure_additions`.

For each non-terminal, tree-sitter precomputes the items that must be added when that non-terminal appears next in a parse item. These additions are not just raw productions; they also carry follow-set information:

- which terminals can appear after the added item
- which external tokens can appear after the added item
- whether lookaheads propagate through the addition

So instead of recursively rediscovering:

- the first symbol of each production
- then the first symbol of the leading non-terminal in those productions
- then the next layer again

tree-sitter computes that transitive closure structure once and reuses it.

### Closure Application

When tree-sitter applies transitive closure to an item set, it:

- inspects items whose next symbol is a non-terminal
- looks up the precomputed additions for that non-terminal
- merges those additions into the current item set with the correct follow/lookahead propagation

So closure becomes primarily:

- merge precomputed additions
- deduplicate items
- propagate lookahead information

not:

- recursively rediscover the same leading expansion tree again and again

### State Construction

In `build_parse_table.rs`, tree-sitter also separates:

- exact item-set identity
- LR(0)-style core identity

It keeps explicit maps for:

- full item sets
- item-set cores

This means state construction is not only about building closures, but also about reusing and comparing them at the right abstraction level.

### What This Means For Our Builder

Our current builder has already added:

- duplicate-check improvements
- closure-result caching
- diagnostics
- experimental threshold controls

Those are useful, but they are still reactive controls around a builder that does too much live recursive closure work.

The upstream algorithm says the stronger step is:

- build an explicit item-set builder
- precompute transitive closure additions per non-terminal
- apply those additions during closure construction
- then let state deduplication operate on the resulting item sets and cores

That is the algorithmic center of this milestone.

## How To Check The Implementation

The implementation should not be considered correct just because it compiles or because one Haskell run looks smaller. It should be checked at several levels.

### Structural Checks

The code should clearly contain:

- an explicit item-set-builder layer in [src/parse_table](/home/oleg/prog/gen-z-sitter/src/parse_table)
- precomputed transitive closure additions per non-terminal
- reuse of those additions during closure construction
- a call path where `buildStatesWithOptions(...)` uses that builder instead of reconstructing all closure expansions live

### Stage-By-Stage Checks

Each implementation stage should have its own explicit verification target. The milestone should not rely only on one final full-suite run.

#### Stage 1: FIRST / LAST / Follow-Set Preparation

What is being implemented:

- reusable set computation needed by the item-set builder
- enough follow-set information to support precomputed closure additions

How to test it:

- unit tests for:
  - `FIRST` set behavior on small synthetic grammars
  - nullable sequence behavior
  - terminal vs external-token propagation
- synthetic tests where the expected follow/lookahead propagation is easy to state by hand
- no Haskell needed yet; this stage should be testable with tiny grammars

Success signal:

- the prepared sets match expected small-grammar results
- no regression in existing `first.zig` behavior

#### Stage 2: Transitive Closure Additions

What is being implemented:

- precomputed closure additions for each non-terminal
- storage of the associated lookahead/follow propagation info

How to test it:

- unit tests for one or two small recursive grammars where the transitive additions are manually enumerable
- verify:
  - which productions are included in the additions
  - whether lookahead propagation is preserved correctly
  - that recursive leading non-terminals are included once at the right abstraction

Success signal:

- additions match the expected expansion graph for the synthetic grammar
- repeated rediscovery is not required to explain the result

#### Stage 3: Closure Application Through The Item-Set Builder

What is being implemented:

- closure uses precomputed additions rather than depending primarily on live recursive discovery

How to test it:

- targeted tests comparing:
  - old-style expected closure content
  - new builder-produced closure content
- use small grammars first
- verify:
  - same resulting items
  - same or narrower lookahead behavior where intended
  - no lost items in closure

Success signal:

- closure correctness stays intact on hand-checkable grammars
- diagnostics show that precomputed additions are actually being used

#### Stage 4: State Construction Integration

What is being implemented:

- `constructStates(...)`, `gotoItems(...)`, and the state queue use the item-set builder path

How to test it:

- parser-state count tests on existing small fixtures
- state-transition stability tests on current parse-table fixtures
- run:
  - `zig build test`
  - focused tests for parse-table construction if split out

Success signal:

- existing passing parser-only fixtures still pass
- no obvious state explosion regression on small or medium grammars

#### Stage 5: Haskell Stress Validation

What is being implemented:

- not new functionality by itself
- this stage checks whether the general algorithm actually improves the known hard case

How to test it:

- targeted run:
  - `GEN_Z_SITTER_COMPAT_EXCLUDE_TARGETS=tree_sitter_c_json`
  - `GEN_Z_SITTER_COMPAT_DETAIL_PROGRESS=1`
  - `GEN_Z_SITTER_PARSE_TABLE_PROGRESS=1`
  - `GEN_Z_SITTER_PARSE_TABLE_TARGET_FILTER=tree_sitter_haskell_json`
  - `zig run update_compat_artifacts.zig`
- compare against the old path for:
  - first large closure size
  - repeated hotspot chain
  - whether thresholds still fire first or whether the upstream algorithm reduces pressure earlier

Success signal:

- Haskell closure/state pressure is lower before threshold fallback becomes dominant
- the hotspot chain is flatter without needing a growing table of Haskell-specific overrides

#### Stage 6: Full Repo Compatibility Verification

What is being implemented:

- the algorithm is now part of the real builder path

How to test it:

- `zig run update_compat_artifacts.zig`
- `zig build test`
- checked-in JSON diffs inspected for:
  - unintended target regressions
  - unintended claim widening

Success signal:

- current promoted targets still pass
- compatibility reporting stays honest
- algorithm change is visible as a builder improvement, not as a silent scope expansion

### Behavioral Checks

The builder should still produce valid parser states for the current passing targets:

- parser-only targets
- scanner-wave targets
- external scanner targets already in the shortlist

So the normal compatibility surfaces must remain correct:

- `zig run update_compat_artifacts.zig`
- `zig build test`

### Algorithmic Checks

The implementation should show that closure work moved in the right direction:

- fewer repeated live recursive expansion paths
- reduced reliance on point-specific Haskell overrides
- reduced need for threshold-based emergency coarsening in the early hotspot chain

For Haskell specifically, we should compare:

- old path:
  - live recursive closure plus threshold/override experiments
- new path:
  - upstream-style precomputed closure additions

The implementation is stronger if:

- large early Haskell closures shrink before thresholds fire
- the hotspot chain is flatter without adding more grammar-specific overrides
- the resulting state construction is explainable through the item-set-builder model, not just “different numbers”

### Scope Boundary Checks

This milestone is not complete if we merely tune thresholds again.

M39 is successful only if the repo can say:

- we adopted the tree-sitter-style closure-addition approach
- we validated it on our current compatibility surfaces
- any remaining thresholds are secondary controls, not the primary algorithm

## Starting Point

- [x] the routine parser-only boundary is stable after M38
- [x] upstream tree-sitter inspection confirmed that parser generation and external-scanner handling are generic rather than Haskell-specific
- [x] upstream tree-sitter inspection identified the relevant algorithmic pieces:
  - `ParseItemSetBuilder`
  - `transitive_closure_additions`
  - separation of item-set identity and core identity
- [x] our current builder already has diagnostics and experimental pressure controls, which are useful for comparison but should not define the final algorithmic direction

## Scope

In scope:

- implementing an upstream-style item-set-builder layer in our parse-table builder
- precomputing transitive closure additions per non-terminal
- reusing those additions during closure construction
- validating the algorithm against current compatibility targets
- using Haskell as a stress case for the general algorithm

Out of scope:

- Haskell-specific permanent builder rules
- runtime scanner parity
- broad new grammar onboarding
- parse-table minimization beyond what is needed to land the item-set-builder algorithm

## Exit Criteria

- [ ] the repo contains an explicit item-set-builder layer for parse-table construction
- [ ] closure construction reuses precomputed transitive closure additions instead of depending primarily on live recursive rediscovery
- [ ] the implementation is verified against `zig run update_compat_artifacts.zig` and `zig build test`
- [ ] Haskell debug runs show that the upstream-style algorithm reduces closure pressure before threshold controls become the primary mechanism
- [ ] the milestone closes with a clear note describing which parts of tree-sitter's algorithm were adopted and which still remain separate future work

## PR-Sized Slices

### PR 1: Capture The Upstream Algorithm

- [ ] document the tree-sitter item-set-builder algorithm in this milestone
- [ ] identify the exact upstream files and concepts we are copying
- [ ] define how implementation success will be checked
- [ ] define the stage-by-stage verification plan for implementation

### PR 2: Implement The Item-Set Builder

- [ ] add an explicit item-set-builder layer in [src/parse_table](/home/oleg/prog/gen-z-sitter/src/parse_table)
- [ ] precompute transitive closure additions per non-terminal
- [ ] thread the builder through the current state-construction path

### PR 3: Validate Against Current Builder Behavior

- [ ] compare the new algorithm against the old live recursive closure path on the current compatibility targets
- [ ] keep or demote existing threshold controls only as secondary mechanisms
- [ ] confirm that Haskell remains a validation case, not a source of permanent product logic

### PR 4: Close Out The Algorithm Shift

- [ ] update milestone notes and docs to describe the adopted algorithmic change
- [ ] state explicitly what remains future work:
  - parse-table minimization
  - emitted-surface compaction
  - runtime scanner parity
- [ ] close the milestone on the checked-in implementation state

## Progress

- [ ] PR 1 completed
- [ ] PR 2 completed
- [ ] PR 3 completed
- [ ] PR 4 completed
- [ ] M39 ready for closeout

## Current Focus

- stop treating thresholds as the main strategy
- implement the upstream item-set-builder algorithm first
- use current diagnostics and Haskell only to verify whether that algorithm is actually reducing live closure pressure

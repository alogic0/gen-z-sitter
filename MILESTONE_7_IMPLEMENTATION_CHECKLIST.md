# Milestone 7 Implementation Checklist

## Goal

Implement the next parser-generation milestone after Milestone 6:

- move from unresolved action tables to precedence-aware conflict handling
- honor associativity and dynamic precedence semantics where they affect parser decisions
- broaden the parser-table subset from “report conflicts correctly” to “resolve supported conflicts correctly”
- keep final table serialization and `parser.c` emission out of scope until the conflict-resolution model is stable

Milestone 7 is the bridge between “the parser-table layer can expose unresolved problems” and “the parser-table layer can make the same supported decisions as upstream Tree-sitter”.

## Current Status

Milestone 7 is complete.

Implemented now:

- resolved-action table IR in `src/parse_table/resolution.zig`
- exact resolved-action dump artifacts in `src/parse_table/debug_dump.zig` and `src/parse_table/pipeline.zig`
- structured unresolved classification:
  - `shift_reduce`
  - `reduce_reduce`
  - `multiple_candidates`
  - `unsupported_action_mix`
- integer precedence resolution:
  - positive => `reduce`
  - negative => `shift`
- named precedence resolution in both directions when a grammar precedence ordering directly compares:
  - the conflicted shift symbol
  - the reduce production's named precedence
- dynamic precedence resolution in both directions:
  - positive => `reduce`
  - negative => `shift`
- explicit priority that dynamic precedence currently outranks named precedence on the reduce side
- associativity resolution for equal integer precedence:
  - left => `reduce`
  - right => `shift`
  - none => unresolved
- exact resolved-action goldens for:
  - precedence-sensitive grammar
  - named-precedence reduce case
  - named-precedence shift case
  - dynamic-precedence reduce case
  - dynamic-precedence shift case
  - dynamic-vs-named priority case
  - negative integer precedence shift case
  - unresolved shift/reduce case
  - unresolved reduce/reduce case
  - associativity-sensitive left/right cases
  - equal-precedence non-associative unresolved case

What this means:

- Milestone 7 is no longer blocked on infrastructure
- the supported shift/reduce resolution subset is real, implemented, and artifact-tested
- the remaining work belongs to the next milestone rather than to Milestone 7 closeout

## What Milestone 7 Includes

- precedence- and associativity-aware action resolution
- dynamic precedence handling at the action/conflict layer
- explicit resolved-action table IR or equivalent resolved-action view
- stable artifacts that show both unresolved and resolved action outcomes where appropriate
- broader supported grammar subset for grammars that currently stop at unresolved precedence-like conflicts
- milestone closeout notes that define what remains before parse-table serialization and code emission

## What Milestone 7 Does Not Include

- final `parser.c` rendering
- lexer table code emission
- scanner code emission
- wasm output
- parse-table minimization
- full `tree-sitter generate` parity

Those belong to later milestones once resolved action semantics are stable.

## Upstream Reference Points

Milestone 7 should continue to follow the upstream table-building and conflict-resolution code, especially the parts that decide actions rather than merely exposing conflicts:

- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/build_parse_table.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/parse_item_set.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/token_conflicts.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/build_tables/item_set_builder.rs`

The upstream concepts to preserve here are:

- precedence and associativity affecting conflict outcomes
- dynamic precedence participating in conflict decisions
- deterministic action resolution
- clear separation between:
  - unresolved conflicts that remain
  - supported conflicts that are resolved by parser-table rules

## Deliverables

By the end of Milestone 7, the repository should have:

- explicit precedence-aware resolution logic in `src/parse_table/`
- action-table IR that can represent resolved actions cleanly
- focused fixtures proving:
  - precedence resolves shift/reduce conflicts
  - associativity resolves equal-precedence conflicts
  - dynamic precedence affects supported conflict outcomes
  - unresolved cases remain explicit when the current semantics still cannot decide
- stable debug-visible artifacts for resolved action tables
- a milestone closeout note describing:
  - the supported conflict-resolution subset
  - what still remains before parse-table serialization and code emission

## Current Starting Point

Milestone 6 already provides:

- FIRST-set computation
- lookahead-aware closure propagation
- explicit action-table IR
- builder-owned action tables
- action-derived shift/reduce and reduce/reduce conflict detection
- stable state, action-table, and grouped-action-table artifacts
- broadened support for inert parser-step metadata

What Milestone 6 deliberately does not provide:

- precedence-aware conflict resolution
- associativity-aware conflict resolution
- dynamic precedence semantics
- resolved action tables as the main parser-decision artifact

So Milestone 7 should extend the existing action/conflict layer rather than replace it.

## Remaining Work For The Next Milestone

These are the real remaining semantic gaps after Milestone 7, ordered by importance.

### 1. Shift-side precedence is still simplified

Current behavior:

- the resolver compares reduce-side metadata against:
  - the default shift precedence of `0`
  - or a conflicted shift symbol through grammar precedence orderings

What is still missing:

- a richer notion of shift-side precedence derived from the shifted item's own production context rather than only the lookahead/action symbol

Why it matters:

- this is the biggest remaining semantic simplification versus upstream conflict resolution
- more complex grammars may need shift-side production precedence, not just symbol ordering

### 2. Reduce/reduce remains intentionally unresolved

Current behavior:

- reduce/reduce conflicts are classified and preserved explicitly

What is still missing:

- any resolution policy for reduce/reduce based on precedence or other parser-table semantics

Why it matters:

- this is a real semantic boundary, not a bug
- it is intentionally deferred beyond Milestone 7

### 3. Builder output still exposes raw actions, not builder-owned resolved actions

Current behavior:

- `BuildResult` includes:
  - productions
  - precedence orderings
  - raw states
  - raw actions
- resolution is applied in the pipeline layer

What is still missing:

- builder-owned resolved actions in `BuildResult`, or an equivalent first-class resolved surface at build time

Why it matters:

- this is a clean boundary improvement before later table serialization work

### 4. Combined-priority policy is still intentionally narrow

Current behavior:

- dynamic precedence currently outranks named precedence on the reduce side

What is still missing:

- a broader documented priority policy across:
  - integer precedence
  - named precedence
  - dynamic precedence
  - associativity

Why it matters:

- the current subset is useful and test-covered
- but the remaining precedence-combination matrix is not yet exhaustively modeled or documented

## Closeout Notes

Milestone 7 intentionally stops at a supported, well-tested shift/reduce resolution subset.

Implemented and stable in this milestone:

- integer precedence in both directions
- named precedence in both directions when directly ordered against the conflicted symbol
- dynamic precedence in both directions
- dynamic precedence outranking named precedence on the reduce side in the current supported subset
- equal-precedence associativity handling
- explicit unresolved classification for shift/reduce and reduce/reduce cases
- exact resolved-action goldens for resolved and unresolved cases through the real preparation pipeline

Deferred to the next milestone:

- richer shift-side precedence semantics
- any reduce/reduce resolution policy
- builder-owned resolved actions as a build-time boundary
- broader precedence-priority policy beyond the currently tested subset

## Main Targets

### 1. Precedence / associativity semantics

Current state:

- precedence and associativity metadata can survive into syntax grammar preparation
- parser-state construction can accept inert metadata
- action/conflict logic does not yet use that metadata to choose winning actions

Target state:

- use precedence and associativity when supported conflicts can be resolved deterministically
- make the winning action visible in resolved-action artifacts
- preserve unresolved conflicts where semantics still do not decide

Expected impact:

- the parser-table layer becomes useful for real expression-style grammars
- some currently reported conflicts disappear because they are resolved, not ignored

### 2. Dynamic precedence handling

Current state:

- implemented for the current supported shift/reduce subset
- positive and negative dynamic precedence both affect resolution
- dynamic precedence currently outranks named precedence on the reduce side

Target state:

- completed for the current supported subset

Expected impact:

- the old “accepted-but-unsupported” boundary is gone for the current shift/reduce subset
- the remaining work is now policy refinement, not first-time support

### 3. Resolved-action IR

Current state:

- implemented
- resolved-action IR exists
- resolved and unresolved outcomes are dumped explicitly
- unresolved groups now carry structured reasons

Target state:

- completed for the current milestone at the pipeline/debug-artifact layer

Expected impact:

- later serialization/code emission has a clearer input boundary
- debug artifacts become closer to the actual parser decisions we intend to emit later

### 4. Broader grammar subset

Current state:

- the broadened supported subset is now real for the current expression-style conflict cases
- inert metadata is accepted
- precedence-like semantics are honored in the supported subset

Target state:

- completed for the intended Milestone 7 subset
- remaining broadening work is deferred

Expected impact:

- parser-table generation becomes credible for more than small LR-like fixtures

## File-by-File Plan

### 1. `src/parse_table/actions.zig`

Purpose:

- extend action IR from “candidate actions” to “candidate plus resolved decision views”

Implement:

- resolved-action representation or helper layer
- grouping/lookup helpers needed by resolution logic
- deterministic ordering helpers for resolved outcomes

Acceptance criteria:

- actions can be queried in both raw and resolved form
- tests prove deterministic resolution ordering

### 2. `src/parse_table/conflicts.zig`

Purpose:

- separate unresolved conflicts from resolvable conflicts

Implement:

- helpers that classify conflicts before and after precedence/associativity resolution
- structured payloads that can explain why a conflict remains unresolved

Acceptance criteria:

- focused tests prove:
  - supported conflicts disappear after resolution
  - unsupported conflicts remain explicit

### 3. `src/parse_table/build.zig`

Purpose:

- integrate resolution into the builder output

Implement:

- precedence-aware resolution pass over action tables
- dynamic-precedence support if included in Milestone 7 scope
- builder-owned resolved-action view in `BuildResult`

Acceptance criteria:

- builder output includes both raw action data and resolved parser decisions, or an equivalent resolved surface

### 4. `src/parse_table/debug_dump.zig`

Purpose:

- expose resolved parser decisions clearly

Implement:

- stable textual dump for resolved actions
- optional combined view showing:
  - raw action candidates
  - resolved decisions
  - remaining unresolved conflicts

Acceptance criteria:

- exact goldens can pin resolved outcomes for precedence-sensitive grammars

### 5. `src/parse_table/pipeline.zig`

Purpose:

- expose the new resolved-action artifact path through the real preparation pipeline

Implement:

- helpers that produce resolved-action dumps from `PreparedGrammar`
- focused exact-golden tests for precedence/associativity fixtures

Acceptance criteria:

- the real end-to-end path can prove resolved parser behavior, not just unresolved candidate actions

### 6. `src/tests/fixtures.zig`

Purpose:

- provide focused grammars that isolate conflict-resolution semantics

Implement:

- fixtures for:
  - precedence-resolved shift/reduce
  - associativity-resolved same-precedence conflicts
  - dynamic-precedence-sensitive conflicts
  - intentionally unresolved conflicts that should remain after Milestone 7

Acceptance criteria:

- exact goldens distinguish resolved from unresolved cases clearly

## Recommended Implementation Order

1. Milestone 7 is complete.
2. The next step is Milestone 8 planning and implementation for the remaining parser-decision semantics and build-time resolved-action boundary work.

## Risks

- precedence semantics can easily become half-implemented in a way that looks plausible but diverges from upstream in edge cases
- dynamic precedence can expand scope quickly if it is introduced before the plain precedence / associativity layer is stable
- resolved-action artifacts can become hard to read if they mix too much raw and resolved information without a clear format boundary

## Exit Criteria

Milestone 7 is complete when:

- precedence-, named-precedence-, dynamic-precedence-, and associativity-sensitive shift/reduce conflicts are resolved in the intended supported subset
- the parser-table layer distinguishes raw candidate actions from resolved parser decisions cleanly at the resolved-artifact layer
- unresolved groups carry explicit reason classification
- exact goldens prove resolved and unresolved outcomes through the full preparation pipeline
- remaining unsupported conflict-resolution semantics are explicitly documented for the next milestone

# Milestone 7 Implementation Checklist

## Goal

Implement the next parser-generation milestone after Milestone 6:

- move from unresolved action tables to precedence-aware conflict handling
- honor associativity and dynamic precedence semantics where they affect parser decisions
- broaden the parser-table subset from “report conflicts correctly” to “resolve supported conflicts correctly”
- keep final table serialization and `parser.c` emission out of scope until the conflict-resolution model is stable

Milestone 7 is the bridge between “the parser-table layer can expose unresolved problems” and “the parser-table layer can make the same supported decisions as upstream Tree-sitter”.

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

- `dynamic_precedence` is still rejected

Target state:

- decide whether Milestone 7 supports the full intended dynamic-precedence subset or a narrower first slice
- route dynamic precedence into the same decision layer as other conflict-resolution rules

Expected impact:

- removes the last explicit “accepted-but-unsupported” metadata boundary from the parser-table layer
- aligns the parser front-end more closely with real Tree-sitter grammar semantics

### 3. Resolved-action IR

Current state:

- actions exist
- conflicts exist
- grouped actions exist
- but the main artifact still represents unresolved action sets

Target state:

- add a resolved-action representation, or an equivalent resolved view layered over the current action table
- distinguish:
  - raw candidate actions
  - resolved action decisions
  - remaining unresolved conflicts

Expected impact:

- later serialization/code emission has a clearer input boundary
- debug artifacts become closer to the actual parser decisions we intend to emit later

### 4. Broader grammar subset

Current state:

- inert metadata is accepted
- precedence-like semantics are not honored yet

Target state:

- support practical grammar families that depend on precedence/associativity to avoid ambiguity
- keep unsupported areas explicit instead of silently behaving incorrectly

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

1. Add one precedence-sensitive grammar fixture and define the intended resolved outcome.
2. Add resolved-action IR/helpers in `src/parse_table/actions.zig`.
3. Add a resolution pass in `src/parse_table/conflicts.zig` and/or `src/parse_table/build.zig`.
4. Expose a resolved-action dump in `src/parse_table/debug_dump.zig`.
5. Add end-to-end golden tests in `src/parse_table/pipeline.zig`.
6. Add associativity and dynamic-precedence fixtures only after the first precedence case is stable.
7. Do a closeout review documenting what conflict-resolution semantics are implemented and what still remains.

## Risks

- precedence semantics can easily become half-implemented in a way that looks plausible but diverges from upstream in edge cases
- dynamic precedence can expand scope quickly if it is introduced before the plain precedence / associativity layer is stable
- resolved-action artifacts can become hard to read if they mix too much raw and resolved information without a clear format boundary

## Exit Criteria

Milestone 7 is complete when:

- precedence- and associativity-sensitive conflicts can be resolved in at least the intended supported subset
- the parser-table layer distinguishes raw candidate actions from resolved parser decisions cleanly
- exact goldens prove resolved outcomes through the full preparation pipeline
- remaining unsupported conflict-resolution semantics are explicitly documented for the next milestone

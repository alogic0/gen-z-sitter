# MILESTONES 36 (Second-Wave Parser-Only Repo Coverage)

This milestone follows [MILESTONES_35.md](./MILESTONES_35.md).

Milestone 35 closed as a compatibility-polish pass. The current proof surfaces are clearer now, which means the next useful step is no longer more polish. It is a targeted revisit of the deferred parser-wave singleton `tree_sitter_c_json`.

It is not a scanner milestone. It is not a runtime-parity milestone. It is not a broad onboarding milestone.

## Goal

- narrow the deferred parser-only proof boundary on `tree_sitter_c_json`
- test one smaller promotion hypothesis instead of a broad full-pipeline jump
- either promote `tree_sitter_c_json` one step further or keep it explicitly bounded with a tighter rationale
- keep the existing promoted parser-only and scanner boundaries stable

## Starting Point

- [x] `tree_sitter_c_json` is the only active deferred parser-wave target
- [x] `tree_sitter_c_json` is explicitly classified as `deferred_for_parser_boundary`
- [x] the current mismatch category is `parser_proof_boundary`
- [x] the routine refresh path and standalone probe tooling are now clearly separated
- [x] the checked-in coverage decision points back to second-wave parser-only repo coverage

## Scope

In scope:

- profiling a narrower promotion hypothesis for `tree_sitter_c_json`
- implementing that hypothesis in stable code or standalone probe tooling
- promoting the parser-only proof ladder by one step only if the resulting boundary is stable
- tightening the machine-readable artifacts if the deferred boundary remains unchanged

Out of scope:

- scanner/runtime work
- broad new parser-wave targets
- runtime parity
- large parser refactors without direct payoff on `tree_sitter_c_json`

## Exit Criteria

- [x] the next promotion hypothesis for `tree_sitter_c_json` is explicit and measured
- [x] `tree_sitter_c_json` is either promoted one step further or left deferred with a tighter rationale than M35
- [x] routine artifact refreshes and standalone probe tooling remain stable and clearly separated
- [x] the checked-in coverage decision and docs reflect the final M36 boundary accurately

## PR-Sized Slices

### PR 1: Choose The Narrower Promotion Hypothesis

- [x] define one smaller promotion hypothesis for `tree_sitter_c_json`
- [x] measure that hypothesis with the existing shortlist/probe tooling split
- [x] keep the normal artifact refresh path stable

### PR 2: Implement Or Bound The Hypothesis

- [x] implement the chosen narrower parser-only proof step or bound it explicitly in tooling
- [x] keep `zig run update_compat_artifacts.zig` fast and routine
- [x] keep `zig build test` clean

### PR 3: Promote Or Freeze tree_sitter_c_json

- [x] either promote `tree_sitter_c_json` one step beyond the current deferred boundary or freeze it with a tighter rationale
- [x] regenerate any affected checked-in artifacts
- [x] avoid broadening the deferred parser-wave set

### PR 4: Closeout

- [x] update coverage decision and milestone notes from the final checked-in evidence
- [x] tighten `README.md`, `compatibility-matrix.md`, and `compat_targets/README.md`
- [x] mark the final M36 parser-only boundary and remaining limitations explicitly

## Progress

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] PR 4 completed
- [x] M36 ready for closeout

## Current Focus

- current promoted real external parser-only snapshots:
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
- current promoted sampled real external scanner snapshots:
  - `tree_sitter_haskell_json`
  - `tree_sitter_bash_json`
- current deferred parser-wave singleton:
  - `tree_sitter_c_json`
- current frozen control fixture:
  - `parse_table_conflict_json`
- current constraint:
  - the next parser-only step should be narrower than a blind full-pipeline promotion attempt
- current M36 hypothesis surface:
  - `compat_targets/parser_boundary_hypothesis.json` now records the current narrower promotion hypothesis machine-readably
  - current hypothesis:
    - keep `tree_sitter_c_json` at `prepare_only` in the routine shortlist
    - treat `serialize_only` as the next named proof step
    - evaluate that step on the `standalone_probe` surface rather than in the routine refresh path
- current standalone probe result:
  - `compat_targets/parser_boundary_probe.json` now records a passing coarse `serialize_only` probe for `tree_sitter_c_json`
  - the standalone probe uses lookahead-insensitive closure expansion to avoid the full LR-style lookahead fanout that made the earlier serialize probe too expensive
  - current standalone proof:
    - `probe_status = passed`
    - `serialized_state_count = 2336`
    - `serialized_blocked = false`
  - this is intentionally narrower than a full lookahead-sensitive parser proof and does not yet change the routine shortlist boundary
  - `compat_targets/parser_boundary_hypothesis.json` and `compat_targets/coverage_decision.json` now record that standalone coarse proof machine-readably while keeping the routine shortlist boundary unchanged

## Closeout

M36 closes with `tree_sitter_c_json` still deferred in the routine shortlist boundary, but no longer with only a vague next-step hypothesis.

- the routine parser-only boundary remains:
  - `prepare_only` in the routine shortlist
  - explicitly classified as `deferred_for_parser_boundary`
  - still described by `parser_proof_boundary`
- the narrower standalone proof is now real and checked in:
  - `compat_targets/parser_boundary_probe.json` records a passing coarse `serialize_only` probe
  - current result is `serialized_state_count = 2336`
  - current result is `serialized_blocked = false`
- the central decision surfaces now reflect that split:
  - `compat_targets/parser_boundary_hypothesis.json` records the standalone coarse probe as implemented and passing
  - `compat_targets/coverage_decision.json` records one deferred parser-wave target with a passing standalone coarse serialize-only probe outside the routine shortlist boundary

That is enough to close M36 without overstating the routine parser-only proof. The next milestone can decide whether to promote the routine boundary further or keep this standalone coarse proof as the stable stopping point for `tree_sitter_c_json`.

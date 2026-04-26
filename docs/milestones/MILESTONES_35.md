# MILESTONES 35 (Broader Compatibility Polish)

This milestone follows [MILESTONES_34.md](./MILESTONES_34.md).

Milestone 34 closed with `tree_sitter_c_json` still deferred, but with a measured and explicit `parser_proof_boundary` rather than a vague parser-gap label. Milestone 35 is about polishing that broader compatibility story so the repo’s proof surfaces, deferred boundaries, and standalone probe tooling read as one coherent contract.

It is not a runtime-parity milestone. It is not a broad onboarding milestone. It is not a large parser-refactor milestone.

## Goal

- tighten the compatibility story across checked-in artifacts, docs, and decision surfaces
- make the relationship between default artifact refreshes and standalone probe tooling explicit
- keep the current promoted parser-only and scanner boundaries stable
- improve one additional evidence-quality surface only if it is low-risk and clarifies the contract

## Starting Point

- [x] `tree_sitter_c_json` is deferred with `deferred_for_parser_boundary`
- [x] the deferred parser-only C snapshot now carries `parser_proof_boundary`
- [x] the default `update_compat_artifacts.zig` path has visible shortlist progress logging
- [x] standalone parser-boundary probe tooling exists outside the default artifact refresh path
- [x] the checked-in coverage decision still points to parser-only follow-up work rather than runtime parity

## Scope

In scope:

- tightening proof-boundary language and aggregate reporting
- clarifying which checked-in artifacts are routine versus probe-driven
- refining one remaining coarse compatibility surface if it improves clarity
- keeping milestone closeout tied to clean `zig run update_compat_artifacts.zig` and `zig build test`

Out of scope:

- full runtime-parity claims
- broad new scanner or parser target waves
- large parser or scanner refactors without immediate compatibility payoff
- CLI productization

## Exit Criteria

- [x] proof-boundary wording is consistent across milestone docs, repo docs, and checked-in artifacts
- [x] the distinction between routine artifact refreshes and standalone probe tooling is explicit and stable
- [x] one additional compatibility-reporting surface is clarified or tightened without widening scope
- [x] the checked-in coverage decision and docs reflect the final M35 boundary accurately

## PR-Sized Slices

### PR 1: Clarify Proof Surfaces

- [x] tighten the wording around promoted proof, frozen controls, deferred proof boundaries, and probe tooling
- [x] make the routine-artifact versus standalone-probe split explicit
- [x] keep the current promoted boundary unchanged

### PR 2: Tighten One Aggregate Surface

- [x] refine one remaining coarse machine-readable compatibility surface
- [x] regenerate the affected checked-in artifacts
- [x] keep the default artifact path fast and stable

### PR 3: Evidence-Quality Checkpoint

- [x] either add one low-risk evidence-quality improvement or explicitly keep the current deferred parser-wave singleton unchanged
- [x] avoid broadening the active target set without a concrete payoff
- [x] keep clean `zig run update_compat_artifacts.zig` and `zig build test` runs

### PR 4: Closeout

- [x] update coverage decision and milestone notes from the final checked-in evidence
- [x] tighten `README.md`, `compatibility-matrix.md`, and `compat_targets/README.md`
- [x] mark the final M35 compatibility boundary and remaining limitations explicitly

## Progress

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] PR 4 completed
- [x] M35 ready for closeout

## Current Focus

- keep the current promoted boundary stable:
  - real external parser-only promoted snapshots:
    - `tree_sitter_ziggy_json`
    - `tree_sitter_ziggy_schema_json`
  - real external sampled scanner snapshots:
    - `tree_sitter_haskell_json`
    - `tree_sitter_bash_json`
  - deferred parser-only snapshot:
    - `tree_sitter_c_json`
  - frozen control fixture:
    - `parse_table_conflict_json`
- keep the parser-boundary story honest:
  - default artifact refresh path remains routine
  - standalone parser-boundary probe tooling remains explicit and optional
  - `tree_sitter_c_json` remains deferred with `parser_proof_boundary` unless a smaller promotion hypothesis emerges
- current M35 polish additions:
  - `compat_targets/artifact_manifest.json` now records routine refresh artifacts and standalone probe artifacts machine-readably
  - the routine refresh / standalone probe split is now explicit in:
    - `README.md`
    - `compatibility-matrix.md`
    - `compat_targets/README.md`
  - `coverage_decision.json` now makes the deferred parser-wave singleton explicit
  - the current low-risk M35 decision is to keep that singleton unchanged rather than widen the active parser-wave set without a concrete payoff

## Closeout

- M35 does not widen the promoted boundary
- it closes by making the current compatibility contract easier to read and harder to overstate:
  - routine compatibility refreshes are now separated explicitly from standalone probe tooling
  - deferred parser-only work is now represented as an explicit singleton parser-wave decision
  - `tree_sitter_c_json` remains deferred with `parser_proof_boundary`
- current stable boundary after M35:
  - promoted real external parser-only snapshots:
    - `tree_sitter_ziggy_json`
    - `tree_sitter_ziggy_schema_json`
  - promoted sampled real external scanner snapshots:
    - `tree_sitter_haskell_json`
    - `tree_sitter_bash_json`
  - deferred parser-wave singleton:
    - `tree_sitter_c_json`
  - frozen parser-only control fixture:
    - `parse_table_conflict_json`
- recommended next step after M35:
  - return to `second_wave_parser_only_repo_coverage` only when there is a narrower promotion hypothesis for `tree_sitter_c_json`

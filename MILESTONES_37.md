# MILESTONES 37 (Broader Compatibility Polish)

This milestone follows [MILESTONES_36.md](./MILESTONES_36.md).

Milestone 36 closed with a clearer split between the routine shortlist boundary and the standalone coarse parser proof for `tree_sitter_c_json`. Milestone 37 is about making that split visible and defensible in the main compatibility surfaces instead of leaving it isolated in sidecar probe artifacts.

It is not a new parser-wave onboarding milestone. It is not a scanner expansion milestone. It is not a runtime-parity milestone.

## Goal

- tighten the relationship between routine shortlist proof and standalone probe proof
- make the standalone coarse parser proof visible in the main inventories and summaries
- keep the current promoted parser-only and scanner boundaries stable
- reduce remaining coarse wording around the deferred parser-wave singleton

## Starting Point

- [x] the routine shortlist still keeps `tree_sitter_c_json` at `prepare_only`
- [x] the standalone coarse `serialize_only` probe for `tree_sitter_c_json` passes
- [x] `parser_boundary_hypothesis.json` and `parser_boundary_probe.json` already encode that split
- [x] the main shortlist and external inventories still underexpose that standalone proof
- [x] the checked-in coverage decision still points to parser-only follow-up work rather than runtime parity

## Scope

In scope:

- polishing the main compatibility surfaces so standalone parser proof is visible without reading sidecar artifacts first
- tightening aggregate counts and summaries around the deferred parser-wave singleton
- keeping the routine-refresh versus standalone-probe contract explicit
- closing the milestone only after clean `zig run update_compat_artifacts.zig` and `zig build test`

Out of scope:

- promoting `tree_sitter_c_json` into the routine shortlist boundary
- onboarding additional parser or scanner targets
- large parse-table or scanner refactors
- runtime parity claims

## Exit Criteria

- [x] the main shortlist and external inventories expose the standalone coarse parser proof explicitly
- [x] aggregate compatibility summaries distinguish routine proof from standalone parser proof cleanly
- [x] docs describe the current `tree_sitter_c_json` split without relying on probe-only artifacts
- [ ] the checked-in coverage decision and milestone notes reflect the final M37 boundary accurately

## PR-Sized Slices

### PR 1: Expose Standalone Parser Proof In Main Inventories

- [x] add explicit standalone parser-proof metadata to the main shortlist/external compatibility surfaces
- [x] regenerate the affected checked-in artifacts
- [x] keep the routine shortlist classification unchanged

### PR 2: Tighten Aggregate Reporting

- [x] add aggregate counts that distinguish standalone parser proof from routine shortlist proof
- [x] keep the existing parser-only, scanner, and control-fixture counts stable
- [x] avoid inventing parser-only promotion language that the routine boundary still does not justify

### PR 3: Tighten Repo-Level Wording

- [x] update `README.md`, `compatibility-matrix.md`, and `compat_targets/README.md`
- [x] make the standalone coarse parser-proof split easier to see from the main docs
- [x] keep milestone wording aligned with the checked-in JSON

### PR 4: Closeout

- [ ] update milestone notes and next-step wording from the final checked-in evidence
- [ ] mark the final M37 compatibility boundary and remaining limitations explicitly
- [ ] keep the next-step recommendation narrow and honest

## Progress

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [ ] PR 4 completed
- [ ] M37 ready for closeout

## Current Focus

- stable routine shortlist proof:
  - 5 intended first-wave parser-only targets pass
  - 6 intended scanner-wave targets pass
- stable deferred singleton:
  - `tree_sitter_c_json` remains `deferred_for_parser_boundary`
  - routine boundary remains `prepare_only`
- stable standalone proof:
  - `tree_sitter_c_json` also has a passing standalone coarse `serialize_only` probe
  - that proof is intentionally narrower than a routine promotion
- current M37 reporting additions:
  - the target model now carries explicit standalone parser-proof scope
  - the main shortlist and external inventories can now expose that scope directly instead of forcing readers into `parser_boundary_probe.json`
  - `shortlist_inventory.json` now exposes `standalone_parser_proof_targets = 1`
  - `external_repo_inventory.json` now exposes:
    - `standalone_parser_proof_targets = 1`
    - `tree_sitter_c_json` with `standalone_parser_proof_scope = coarse_serialize_only`
